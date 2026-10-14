import AppKit
import WebKit
import ImageIO
import ShelfCore

/// Saves web addresses: a link card appears at once, then its title and preview fill in from the page (its
/// preview image, or a snapshot of the page when it has none). Addresses of pictures and videos are saved as media.
final class LinkSaver: NSObject, WKNavigationDelegate {
    private let database: LibraryDatabase
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        return URLSession(configuration:configuration)
    }()
    private var snapshots: [(id: String, url: URL)] = []
    private var webView: WKWebView?
    private var current: (id: String, url: URL)?
    private var timeout: DispatchWorkItem?
    /// A link changed (title or preview), or new media arrived; reload what's shown.
    var didChange: (() -> Void)?
    /// Downloaded pictures and videos to add like dropped files.
    var importFiles: (([URL]) -> Void)?
    init(database: LibraryDatabase) { self.database = database }

    /// Saves addresses. With `asLinks`, picture addresses are kept as links too. Returns the new link ids.
    @discardableResult func save(_ urls: [URL], into collection: String?, asLinks: Bool = false) throws -> [String] {
        var links: [ShelfItem] = []
        for url in urls {
            if !asLinks, LinkMetadata.isMedia(url) { download(url); continue }
            links.append(ShelfItem.link(url:url.absoluteString,source:url.absoluteString))
        }
        let ids = try database.insert(links,into:collection)
        for item in links where ids.contains(item.id) { dress(item) }
        return ids
    }
    /// Links saved from outside Folio (the folio command, an assistant) have no preview yet; read their pages.
    func fillIn(_ items: [ShelfItem]) {
        for item in items where item.kind == "link" && !item.path.hasPrefix("/") && !item.path.hasPrefix("card:") && !pending.contains(item.id) {
            pending.insert(item.id); dress(item)
        }
    }
    private var pending = Set<String>()
    /// Reads the page again and replaces the link's preview.
    func refresh(_ item: ShelfItem) {
        guard let url = URL(string:item.url.isEmpty ? item.source : item.url) else { return }
        fetch(item.id,url,force:true)
    }

    /// Gives a new link the look chosen in Settings ▸ General ▸ Links.
    private func dress(_ item: ShelfItem) {
        guard let url = URL(string:item.url.isEmpty ? item.source : item.url) else { return }
        switch UserDefaults.standard.string(forKey:"linkLook") {
        case "snapshot": snapshot(item.id,url,title:nil)
        case "title": showTitleCard(item); fetchTitle(item.id,url)
        default: fetch(item.id,url)
        }
    }
    /// Shows the page itself rather than its preview image.
    func snapshotPage(_ item: ShelfItem) {
        guard let url = URL(string:item.url.isEmpty ? item.source : item.url) else { return }
        snapshot(item.id,url,title:nil)
    }
    /// Shows the link as its title on a plain card, with no picture. The `card:` mark keeps it that way: links
    /// without a preview are otherwise read again.
    func showTitleCard(_ item: ShelfItem) {
        try? database.setLinkPreview(id:item.id,path:"card:" + (item.url.isEmpty ? item.source : item.url),title:nil,size:.zero)
        didChange?()
    }

    /// Just the page's title, for a link shown as a title card.
    private func fetchTitle(_ id: String, _ url: URL) {
        session.dataTask(with:url) { [weak self] data, response, _ in
            guard let self, let data else { return }
            let html = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) ?? ""
            let title = LinkMetadata.parse(html:html,base:response?.url ?? url).title
            guard !title.isEmpty else { return }
            try? self.database.setLinkPreview(id:id,path:"card:" + url.absoluteString,title:title,size:.zero)
            DispatchQueue.main.async { self.didChange?() }
        }.resume()
    }
    private func fetch(_ id: String, _ url: URL, force: Bool = false) {
        session.dataTask(with:url) { [weak self] data, response, _ in
            guard let self else { return }
            let html = data.flatMap { String(data:$0,encoding:.utf8) ?? String(data:$0,encoding:.isoLatin1) } ?? ""
            let meta = LinkMetadata.parse(html:html,base:response?.url ?? url)
            let title = meta.title.isEmpty ? nil : meta.title
            if let image = meta.image {
                self.session.dataTask(with:image) { data, _, _ in
                    if let data, data.count < 15_000_000, let saved = self.store(data,for:id) {
                        try? self.database.setLinkPreview(id:id,path:saved.path,title:title,size:saved.size)
                        DispatchQueue.main.async { self.didChange?() }
                    } else { DispatchQueue.main.async { self.snapshot(id,url,title:title) } }
                }.resume()
            } else { DispatchQueue.main.async { self.snapshot(id,url,title:title) } }
        }.resume()
    }
    /// Keeps a downloaded preview in the library's media folder, once it decodes as a picture.
    private func store(_ data: Data, for id: String) -> (path: String, size: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width >= 120, height >= 80 else { return nil }
        let type = (CGImageSourceGetType(source) as String?) ?? "public.jpeg"
        let ext = type.contains("png") ? "png" : type.contains("gif") ? "gif" : type.contains("webp") ? "webp" : "jpg"
        let file = database.mediaFolder.appendingPathComponent("link-\(id.prefix(16)).\(ext)")
        do {
            try FileManager.default.createDirectory(at:database.mediaFolder,withIntermediateDirectories:true)
            try data.write(to:file,options:.atomic)
            return (file.path,CGSize(width:width,height:height))
        } catch { return nil }
    }

    // MARK: Snapshots

    /// Captures the page itself when it offers no preview image. One page at a time, in a view never shown on screen.
    private func snapshot(_ id: String, _ url: URL, title: String?) {
        if let title { try? database.setLinkPreview(id:id,path:url.absoluteString,title:title,size:.zero); didChange?() }
        snapshots.append((id,url))
        if current == nil { next() }
    }
    private func next() {
        guard !snapshots.isEmpty else { current = nil; webView = nil; return }
        current = snapshots.removeFirst()
        let view = WKWebView(frame:CGRect(x:0,y:0,width:1280,height:960),configuration:{
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); return configuration
        }())
        view.navigationDelegate = self; webView = view
        view.load(URLRequest(url:current!.url,timeoutInterval:20))
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work; DispatchQueue.main.asyncAfter(deadline:.now() + 25,execute:work)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give late images and fonts a moment, then take the picture.
        DispatchQueue.main.asyncAfter(deadline:.now() + 1.2) { [weak self] in
            guard let self, self.webView === webView else { return }
            let configuration = WKSnapshotConfiguration(); configuration.rect = CGRect(x:0,y:0,width:1280,height:960)
            webView.takeSnapshot(with:configuration) { image, _ in self.finish(image) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    private func finish(_ image: NSImage?) {
        timeout?.cancel(); timeout = nil
        if let current, let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]),
           let saved = store(png,for:current.id) {
            try? database.setLinkPreview(id:current.id,path:saved.path,title:nil,size:saved.size)
            didChange?()
        }
        webView?.stopLoading(); webView = nil
        next()
    }

    // MARK: Media addresses

    private func download(_ url: URL) {
        session.downloadTask(with:url) { [weak self] file, response, _ in
            guard let self, let file else { return }
            let name = (response?.suggestedFilename ?? url.lastPathComponent).replacingOccurrences(of:"/",with:"-")
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("Saved-\(UUID().uuidString.prefix(6))-\(name)")
            guard (try? FileManager.default.moveItem(at:file,to:target)) != nil, MediaFiles.kind(target) != nil else { return }
            DispatchQueue.main.async { self.importFiles?([target]) }
        }.resume()
    }
}
