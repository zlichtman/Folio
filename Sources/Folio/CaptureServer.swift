import Combine
import Foundation
import Network
import ShelfCore

/// What the browser connection is doing, for Settings and the sidebar.
enum CaptureState: Equatable {
    case stopped, starting, running, portInUse, failed(String)

    var title: String {
        switch self {
        case .stopped: "Browser capture is off"
        case .starting: "Starting browser capture…"
        case .running: "Browser capture is on"
        case .portInUse: "Browser capture is waiting"
        case .failed: "Browser capture stopped"
        }
    }
    var detail: String {
        switch self {
        case .stopped: "Turn it on to save from Firefox or Chrome."
        case .starting: "Opening a private connection on this Mac."
        case .running: "Extensions on this Mac can save to this library."
        case .portInUse: "Another copy of Folio or another app is using the connection. Folio will keep trying."
        case .failed(let message): message
        }
    }
}

// Mutable peer state is accessed only on CaptureServer.queue.
final class HTTPPeer: @unchecked Sendable {
    let connection: NWConnection
    var bytes = Data()
    var done = false
    var authorized = false
    var timeout: DispatchWorkItem?
    init(_ connection: NWConnection) { self.connection = connection }
}

/// Loopback-only HTTP for the browser extensions, guarded by a per-library key. Never exposes library paths.
final class CaptureServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var state = CaptureState.stopped
    let port = CaptureProtocol.port
    var didSave: (() -> Void)?
    var didFail: ((String) -> Void)?
    private let queue = DispatchQueue(label:"org.lumashelf.capture")
    private let database: LibraryDatabase
    private let keyLock = NSLock()
    private var key: String
    // The following are touched only on `queue`.
    private var listener: NWListener?
    private var peers: [UUID:HTTPPeer] = [:]
    private var wanted = false
    private var current = CaptureState.stopped
    private var retry: DispatchWorkItem?
    /// Development only: lets scripts/test-capture.mjs download from a fixture server on this Mac.
    private let allowsLocalDownloads = CommandLine.arguments.contains("--allow-local-downloads")

    /// The connection key lives in `keyFolder`, the main library's folder, so extensions stay paired whichever library is open.
    init(database: LibraryDatabase, keyFolder: URL? = nil) throws {
        self.database = database; self.keyFolder = keyFolder ?? database.root
        try FileManager.default.createDirectory(at:self.keyFolder,withIntermediateDirectories:true)
        key = try CaptureKey.load(in:self.keyFolder)
    }
    private let keyFolder: URL

    var token: String { keyLock.withLock { key } }

    /// Issues a new key. Extensions paired with the old one must be connected again.
    @discardableResult
    func resetToken() throws -> String {
        let new = try CaptureKey.reset(in:keyFolder)
        keyLock.withLock { key = new }
        return new
    }

    /// Never throws or quits when the port is taken; `state` reports it and Folio retries.
    func start() { queue.async { self.wanted = true; self.listen() } }

    func stop() {
        queue.async {
            self.wanted = false; self.retry?.cancel(); self.retry = nil
            self.listener?.cancel(); self.listener = nil
            for (id,peer) in self.peers { self.close(peer,id:id) }
            self.publish(.stopped)
        }
    }

    private func listen() {
        guard wanted, listener == nil else { return }
        retry?.cancel(); retry = nil
        if current == .stopped { publish(.starting) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        let listener: NWListener
        do { listener = try NWListener(using:params) } catch { failed(error); return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready: self.publish(.running)
            case .failed(let error), .waiting(let error): listener.cancel(); self.listener = nil; self.failed(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue:queue)
    }

    private func failed(_ error: Error) {
        var inUse = false
        if case .posix(.EADDRINUSE)? = error as? NWError { inUse = true }
        publish(inUse ? .portInUse : .failed("The browser connection could not start: \(error.localizedDescription)"))
        let work = DispatchWorkItem { [weak self] in self?.listen() }
        retry = work
        queue.asyncAfter(deadline:.now() + (inUse ? 5 : 15),execute:work)
    }

    private func publish(_ new: CaptureState) {
        guard new != current else { return }
        current = new
        DispatchQueue.main.async {
            self.state = new
            switch new {
            case .portInUse, .failed: self.didFail?(new.detail)
            default: break
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard peers.count < 16 else { connection.cancel(); return }
        let id = UUID(), peer = HTTPPeer(connection)
        peers[id] = peer
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(peer,id:id)
            default: break
            }
        }
        connection.start(queue:queue)
        // Slow or stalled clients lose their slot; cancelled once the request has fully arrived.
        let timeout = DispatchWorkItem { [weak self, weak peer] in if let peer { self?.close(peer,id:id) } }
        peer.timeout = timeout
        queue.asyncAfter(deadline:.now() + 20,execute:timeout)
        receive(peer,id:id)
    }

    private func close(_ peer: HTTPPeer, id: UUID) {
        peer.done = true; peer.timeout?.cancel(); peer.timeout = nil; peer.connection.cancel(); peers.removeValue(forKey:id)
    }

    private func receive(_ peer: HTTPPeer, id: UUID) {
        peer.connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self, !peer.done else { return }
            if let data { peer.bytes.append(data) }
            switch CaptureProtocol.parse(peer.bytes) {
            case .invalid(let failure): self.respond(peer,id:id,failure)
            case .complete(let request):
                peer.timeout?.cancel(); peer.bytes = Data()
                if let failure = CaptureProtocol.authorize(request,token:self.token) { self.respond(peer,id:id,failure) }
                else { self.route(request,peer:peer,id:id) }
            case .incomplete:
                // Refuse strangers as soon as their headers arrive rather than buffering up to 12 MB of body.
                if !peer.authorized, let head = CaptureProtocol.headers(peer.bytes) {
                    if let failure = CaptureProtocol.authorize(head,token:self.token) { self.respond(peer,id:id,failure); return }
                    peer.authorized = true
                }
                if complete || error != nil { self.close(peer,id:id) } else { self.receive(peer,id:id) }
            }
        }
    }

    private func route(_ request: CaptureProtocol.Request, peer: HTTPPeer, id: UUID) {
        switch (request.method,request.path) {
        case ("GET","/health"):
            respond(peer,id:id,200,["app":AppIdentity.name,"version":AppIdentity.version,"items":(try? database.count()) ?? 0])
        case ("GET","/collections"):
            respond(peer,id:id,200,["collections":collectionNames()])
        case ("POST","/save"):
            let job: CaptureJob
            do { job = try CaptureJob.decode(request.body) } catch { respond(peer,id:id,error); return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let item = try await self.save(job)
                    self.queue.async { self.respond(peer,id:id,200,["ok":true,"id":item.id,"kind":item.kind,"collection":job.collection]) }
                    DispatchQueue.main.async { self.didSave?() }
                } catch {
                    self.queue.async { self.respond(peer,id:id,error) }
                }
            }
        case (_,"/health"),(_,"/collections"),(_,"/save"): respond(peer,id:id,405,["error":"Method not allowed"])
        default: respond(peer,id:id,404,["error":"Unknown route"])
        }
    }

    private func respond(_ peer: HTTPPeer, id: UUID, _ error: Error) {
        let failure = error as? CaptureProtocol.Failure ?? CaptureProtocol.Failure(422,error.localizedDescription)
        respond(peer,id:id,failure.status,["error":failure.message])
    }

    private func respond(_ peer: HTTPPeer, id: UUID, _ status: Int, _ body: [String:Any]) {
        guard !peer.done else { return }
        peer.done = true; peer.timeout?.cancel()
        peer.connection.send(content:CaptureProtocol.response(status:status,body:body),completion:.contentProcessed { [weak self] _ in
            self?.close(peer,id:id)
        })
    }

    // MARK: Saving

    private func save(_ job: CaptureJob) async throws -> ShelfItem {
        let media = database.root.appendingPathComponent("media",isDirectory:true)
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let stem = ShelfItem.digest(job.url.absoluteString)
        var item: ShelfItem
        switch job.kind {
        case .image, .video:
            let (file,sniffed) = try await download(job,into:media,stem:stem)
            let size = MediaFiles.dimensions(file)
            item = ShelfItem(path:file.path,title:job.title,kind:sniffed.kind,source:job.source,url:job.url.absoluteString,
                             width:size.width,height:size.height)
        case .page, .link:
            var preview: URL?
            if let snapshot = job.snapshot, let sniffed = CaptureMedia.sniff(snapshot) {
                let file = media.appendingPathComponent(stem).appendingPathExtension(sniffed.fileExtension)
                // A valid existing file belongs to an item saved earlier, whose stored size must keep matching it.
                if (try? CaptureMedia.inspect(file)) != sniffed {
                    try snapshot.write(to:file,options:.atomic)
                    CaptureMedia.quarantine(file,from:job.url,page:job.source)
                }
                preview = file
            }
            item = ShelfItem.link(url:job.url.absoluteString,title:job.title,preview:preview?.path,source:job.source)
            if let preview {
                let size = MediaFiles.dimensions(preview)
                item.width = size.width; item.height = size.height
            }
        }
        item.id = try store(item,in:job.collection)
        return item
    }

    private func download(_ job: CaptureJob, into media: URL, stem: String) async throws -> (URL,CaptureMedia.Sniffed) {
        let allowsLocal = allowsLocalDownloads
        if !allowsLocal { try await Self.blocking { try CaptureNetwork.checkPublic(job.url) } }
        let part = media.appendingPathComponent(".\(stem)-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at:part) }
        try await MediaDownload(url:job.url,referrer:job.source,file:part,allowsLocal:allowsLocal).run()
        let sniffed = try CaptureMedia.inspect(part)
        let file = media.appendingPathComponent(stem).appendingPathExtension(sniffed.fileExtension)
        // Keep a valid earlier copy, as for page snapshots; replace one that older versions saved unchecked.
        if (try? CaptureMedia.inspect(file)) == sniffed { return (file,sniffed) }
        CaptureMedia.quarantine(part,from:job.url,page:job.source)
        guard rename(part.path,file.path) == 0 else { throw CaptureProtocol.Failure(422,"Folio could not save the download") }
        return (file,sniffed)
    }

    private static func blocking(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            DispatchQueue.global(qos:.userInitiated).async { continuation.resume(with:Result(catching:work)) }
        }
    }
}

// MARK: - Library adapter

// Capture's only contact with the library schema.
extension CaptureServer {
    /// Returns the library id of the saved item, which is the existing one for a repeat capture. "Inbox" means no collection.
    func store(_ item: ShelfItem, in collection: String) throws -> String {
        let id = try database.collection(named:collection,createIfMissing:true)?.id
        return try database.insert([item],into:id).first ?? item.id
    }
    func collectionNames() -> [String] {
        let names = ((try? database.collections()) ?? []).filter { !$0.isSmart }.map(\.name)
        return Array(Set(names + ["Inbox"])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - Download

/// One media download: no cookies, a hard size cap, and every hop checked against local network ranges.
private final class MediaDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL, referrer: String, file: URL, allowsLocal: Bool
    private let delegateQueue = OperationQueue()
    // Touched only on `delegateQueue`.
    private var handle: FileHandle?
    private var written = 0, redirects = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void,Error>?

    init(url: URL, referrer: String, file: URL, allowsLocal: Bool) {
        self.url = url; self.referrer = referrer; self.file = file; self.allowsLocal = allowsLocal
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func run() async throws {
        guard FileManager.default.createFile(atPath:file.path,contents:nil) else { throw CaptureProtocol.Failure(422,"Folio could not save the download") }
        handle = try FileHandle(forWritingTo:file)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration:config,delegate:self,delegateQueue:delegateQueue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url:url)
        request.setValue("image/avif,image/webp,image/*,video/*;q=0.9,*/*;q=0.5",forHTTPHeaderField:"Accept")
        if let page = URL(string:referrer), !(page.scheme == "https" && url.scheme == "http") { request.setValue(referrer,forHTTPHeaderField:"Referer") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            delegateQueue.addOperation {
                self.continuation = continuation
                session.dataTask(with:request).resume()
            }
        }
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        if failure == nil { failure = error }
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if failure != nil { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            failure = CaptureProtocol.Failure(422,"The site refused the download"); completionHandler(.cancel); return
        }
        guard http.expectedContentLength <= Int64(CaptureProtocol.maxMedia) else {
            failure = CaptureProtocol.Failure(413,"Media exceeds the 100 MB capture limit"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        written += data.count
        guard written <= CaptureProtocol.maxMedia else { fail(CaptureProtocol.Failure(413,"Media exceeds the 100 MB capture limit"),dataTask); return }
        do { try handle?.write(contentsOf:data) } catch { fail(error,dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        do {
            guard redirects <= 5, let next = request.url else { throw CaptureProtocol.Failure(422,"The site redirected too many times") }
            guard CaptureProtocol.webURL(next.absoluteString) != nil else { throw CaptureProtocol.Failure(422,"The site redirected to an address Folio cannot save") }
            if !allowsLocal { try CaptureNetwork.checkPublic(next) }
            completionHandler(request)
        } catch {
            completionHandler(nil); fail(error,task)
        }
    }

    // Catches a host that resolved differently at connect time than when it was checked.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard !allowsLocal else { return }
        for transaction in metrics.transactionMetrics where !transaction.isProxyConnection {
            if let remote = transaction.remoteAddress, let address = CaptureNetwork.address(remote), !CaptureNetwork.isPublic(address) {
                failure = failure ?? CaptureProtocol.Failure(422,"Folio only saves media from the public web")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        let result: Result<Void,Error>
        if let failure { result = .failure(failure) }
        else if let error = error as? URLError {
            switch error.code {
            case .timedOut: result = .failure(CaptureProtocol.Failure(422,"The download took too long"))
            case .notConnectedToInternet: result = .failure(CaptureProtocol.Failure(422,"This Mac is offline"))
            case .cannotFindHost: result = .failure(CaptureProtocol.Failure(422,"Could not find \(url.host ?? "the site")"))
            default: result = .failure(CaptureProtocol.Failure(422,"The download failed: \(error.localizedDescription)"))
            }
        }
        else if let error { result = .failure(error) }
        else { result = .success(()) }
        continuation?.resume(with:result); continuation = nil
    }
}
