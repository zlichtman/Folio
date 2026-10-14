import Foundation
import CoreServices
import ImageIO
import UniformTypeIdentifiers

/// Wire format and trust checks for the browser capture service, kept free of sockets so they can be tested.
public enum CaptureProtocol {
    public static let port: UInt16 = 53187
    public static let maxHeader = 16 * 1024
    public static let maxBody = 12 * 1024 * 1024
    public static let maxSnapshot = 8 * 1024 * 1024
    public static let maxMedia = 100 * 1024 * 1024

    public struct Failure: LocalizedError, Equatable, Sendable {
        public let status: Int
        public let message: String
        public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String:String]
        public var body: Data
    }

    public enum Parse: Equatable, Sendable { case incomplete, complete(Request), invalid(Failure) }

    private static let singular: Set<String> = ["host","authorization","origin","content-length","content-type"]

    /// Parses one HTTP/1.x request from the bytes received so far. Chunked bodies are refused.
    public static func parse(_ data: Data) -> Parse {
        let bytes = data.startIndex == 0 ? data : Data(data)
        switch head(of:bytes) {
        case nil: return .incomplete
        case .failure(let failure)?: return .invalid(failure)
        case .success(let (request,start,length))?:
            guard bytes.count >= start + length else { return .incomplete }
            var request = request
            request.body = bytes.subdata(in:start..<start + length)
            return .complete(request)
        }
    }

    /// The request line and headers once they have all arrived, with an empty body, so a caller can
    /// refuse an unauthorized request before buffering its body.
    public static func headers(_ data: Data) -> Request? {
        if case .success(let (request,_,_))? = head(of:data.startIndex == 0 ? data : Data(data)) { return request }
        return nil
    }

    private static func head(of bytes: Data) -> Result<(Request,Int,Int),Failure>? {
        let separator = Data("\r\n\r\n".utf8)
        guard let marker = bytes.range(of:separator,in:0..<min(bytes.count,maxHeader + separator.count)) else {
            return bytes.count > maxHeader ? .failure(Failure(431,"Headers too large")) : nil
        }
        guard let head = String(data:bytes[..<marker.lowerBound],encoding:.utf8) else { return .failure(Failure(400,"Invalid headers")) }
        let lines = head.components(separatedBy:"\r\n")
        let parts = lines[0].split(separator:" ",omittingEmptySubsequences:false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0 >= "A" && $0 <= "Z" }),
              parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .failure(Failure(400,"Invalid request"))
        }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":"), colon != line.startIndex,
                  !line[..<colon].contains(where:{ $0 == " " || $0 == "\t" }) else { return .failure(Failure(400,"Invalid headers")) }
            let name = line[..<colon].lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            if headers[name] != nil {
                guard !singular.contains(name) else { return .failure(Failure(400,"Repeated \(name) header")) }
                headers[name]! += ", " + value
            } else { headers[name] = value }
        }
        guard headers["transfer-encoding"] == nil else { return .failure(Failure(501,"Chunked requests unsupported")) }
        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 9, raw.allSatisfy(\.isASCIIDigit), let value = Int(raw) else { return .failure(Failure(400,"Invalid content length")) }
            guard value <= maxBody else { return .failure(Failure(413,"Capture exceeds 12 MB")) }
            length = value
        }
        let path = String(parts[1].prefix { $0 != "?" && $0 != "#" })
        return .success((Request(method:String(parts[0]),path:path,headers:headers,body:Data()),marker.upperBound,length))
    }

    /// Host, origin and key checks, in that order. Returns nil when the request may proceed.
    public static func authorize(_ request: Request, token: String) -> Failure? {
        guard validHost(request.headers["host"]) else { return Failure(421,"Connect to Folio at 127.0.0.1") }
        guard allowedOrigin(request.headers["origin"]) else { return Failure(403,"Web pages cannot use Folio") }
        guard let supplied = bearer(request.headers["authorization"]), tokensMatch(supplied,token) else {
            return Failure(401,"Connect the extension with the key from Folio")
        }
        return nil
    }

    /// Rejects DNS-rebinding names: only the loopback literal or localhost on the capture port.
    public static func validHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Browsers attach an Origin to page requests; only extension pages may call the service.
    public static func allowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return ["moz-extension://","chrome-extension://"].contains { origin.hasPrefix($0) && origin.count > $0.count }
    }

    public static func bearer(_ header: String?) -> String? {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return nil }
        return String(header.dropFirst(7)).trimmingCharacters(in:.whitespaces)
    }

    /// Time depends only on the expected token's length.
    public static func tokensMatch(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for i in b.indices { difference |= Int((i < a.count ? a[i] : 0) ^ b[i]) }
        return difference == 0 && !b.isEmpty
    }

    /// Only plain http(s) URLs with a host and no embedded credentials.
    public static func webURL(_ string: String?) -> URL? {
        guard let string, !string.isEmpty, string.count <= 8192, let url = URL(string:string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func response(status: Int, body: [String:Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject:body,options:[.sortedKeys])) ?? Data("{}".utf8)
        let reasons = [200:"OK",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",
                       413:"Payload Too Large",421:"Misdirected Request",422:"Unprocessable Content",431:"Request Header Fields Too Large",
                       501:"Not Implemented",503:"Service Unavailable"]
        var out = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        return out
    }
}

// MARK: - Capture requests

public struct CaptureRequest: Decodable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public var kind: String?
    public var collection: String?
    public var source: String?
    public var snapshot: String?
    public init(url: String, title: String? = nil, kind: String? = nil, collection: String? = nil, source: String? = nil, snapshot: String? = nil) {
        self.url = url; self.title = title; self.kind = kind; self.collection = collection; self.source = source; self.snapshot = snapshot
    }
}

/// A validated capture: `url` is what gets saved (media, link target or page) and `source` is the page it came from.
public struct CaptureJob: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video, link, page }
    public var kind: Kind
    public var url: URL
    public var source: String
    public var title: String
    public var collection: String
    public var snapshot: Data?

    public static func decode(_ body: Data) throws -> CaptureJob {
        guard let request = try? JSONDecoder().decode(CaptureRequest.self,from:body) else { throw CaptureProtocol.Failure(400,"Invalid capture") }
        return try CaptureJob(request)
    }

    public init(_ request: CaptureRequest) throws {
        guard let url = CaptureProtocol.webURL(request.url) else { throw CaptureProtocol.Failure(400,"Only web addresses that start with http or https can be saved") }
        switch request.kind ?? "link" {
        case "image": kind = .image
        case "video": kind = .video
        case "page": kind = .page
        case "link": kind = request.snapshot == nil ? .link : .page // Earlier extensions sent pages as links.
        default: throw CaptureProtocol.Failure(400,"Unknown capture type")
        }
        self.url = url
        snapshot = kind == .page ? request.snapshot.flatMap(Self.snapshot) : nil
        source = kind == .page ? url.absoluteString : CaptureProtocol.webURL(request.source)?.absoluteString ?? url.absoluteString
        let name = Self.clean(request.collection ?? "",limit:120)
        collection = name.isEmpty ? "Inbox" : name
        var title = Self.clean(request.title ?? "",limit:500)
        if title.isEmpty {
            switch kind {
            case .image, .video: title = url.lastPathComponent
            case .link: title = Self.clean((url.host ?? "") + (url.path == "/" ? "" : url.path),limit:500)
            case .page: title = url.host ?? ""
            }
            if title.isEmpty || title == "/" { title = url.host ?? url.absoluteString }
        }
        self.title = title
    }

    /// Trims, drops control characters and collapses runs of whitespace.
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0) }
        return String(String(scalars).split(whereSeparator:\.isWhitespace).joined(separator:" ").prefix(limit))
    }

    /// Page snapshots arrive as base64, optionally as a data URL. Anything but a real image is dropped.
    static func snapshot(_ text: String) -> Data? {
        let payload = text.hasPrefix("data:") ? String(text.drop { $0 != "," }.dropFirst()) : text
        guard payload.count <= CaptureProtocol.maxSnapshot * 4 / 3 + 4, let data = Data(base64Encoded:payload),
              data.count <= CaptureProtocol.maxSnapshot, CaptureMedia.sniff(data)?.kind == "image" else { return nil }
        return data
    }
}

// MARK: - Downloaded media

/// Decides what a downloaded file really is from its bytes; server-declared types are ignored.
public enum CaptureMedia {
    public struct Sniffed: Equatable, Sendable {
        public let kind: String
        public let fileExtension: String
    }

    public static func sniff(_ head: Data) -> Sniffed? {
        let b = [UInt8](head.prefix(64))
        func at(_ offset: Int, _ text: String) -> Bool {
            let s = Array(text.utf8); return b.count >= offset + s.count && Array(b[offset..<offset + s.count]) == s
        }
        func starts(_ bytes: [UInt8]) -> Bool { b.count >= bytes.count && Array(b.prefix(bytes.count)) == bytes }
        let found: (String,String)?
        if starts([0xFF,0xD8,0xFF]) { found = ("image","jpg") }
        else if starts([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]) { found = ("image","png") }
        else if at(0,"GIF87a") || at(0,"GIF89a") { found = ("image","gif") }
        else if at(0,"RIFF") && at(8,"WEBP") { found = ("image","webp") }
        else if at(0,"RIFF") && at(8,"AVI ") { found = ("video","avi") }
        else if starts([0x49,0x49,0x2A,0x00]) || starts([0x4D,0x4D,0x00,0x2A]) { found = ("image","tiff") }
        else if at(0,"BM") && b.count >= 26 && b[14] >= 12 && b[6...9].allSatisfy({ $0 == 0 }) { found = ("image","bmp") }
        else if starts([0x1A,0x45,0xDF,0xA3]) { found = head.prefix(4096).range(of:Data("webm".utf8)) != nil ? ("video","webm") : nil }
        else if at(4,"ftyp") && b.count >= 12 {
            let brand = String(decoding:b[8..<12],as:UTF8.self)
            switch brand {
            case "avif","avis": found = ("image","avif")
            case "heic","heix","heim","heis","mif1","msf1": found = ("image","heic")
            case "hevc","hevx": found = ("image","heic")
            case "qt  ": found = ("video","mov")
            case "M4V ","M4VH","M4VP": found = ("video","m4v")
            case "isom","iso2","iso4","iso5","iso6","mp41","mp42","avc1","dash","mmp4","MSNV","3gp4","3gp5","3g2a","f4v ": found = ("video","mp4")
            default: found = nil
            }
        }
        else if ["moov","mdat","wide","free","pnot"].contains(where:{ at(4,$0) }) { found = ("video","mov") }
        else if starts([0x00,0x00,0x01,0xBA]) || starts([0x00,0x00,0x01,0xB3]) { found = ("video","mpg") }
        else { found = nil }
        guard let found, let type = UTType(filenameExtension:found.1),
              found.0 == "image" ? type.conforms(to:.image) : type.conforms(to:.audiovisualContent) else { return nil }
        return Sniffed(kind:found.0,fileExtension:found.1)
    }

    /// Disk images and zip archives keep their signatures at the end, so a valid image header alone is not enough.
    public static func hasArchiveTrailer(_ tail: Data) -> Bool {
        let t = [UInt8](tail)
        if t.count >= 512, Array(t[(t.count - 512)..<(t.count - 508)]) == Array("koly".utf8) { return true }
        guard t.count >= 22 else { return false }
        for p in stride(from:t.count - 22,through:max(0,t.count - 22 - 65535),by:-1)
        where t[p] == 0x50 && t[p+1] == 0x4B && t[p+2] == 0x05 && t[p+3] == 0x06 {
            if p + 22 + Int(t[p+20]) + Int(t[p+21]) << 8 == t.count { return true }
        }
        return false
    }

    /// Checks a downloaded file's bytes, refusing executables, archives and anything that is not an image or video.
    public static func inspect(_ file: URL) throws -> Sniffed {
        let handle = try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { throw CaptureProtocol.Failure(422,"The download was empty") }
        guard size <= UInt64(CaptureProtocol.maxMedia) else { throw CaptureProtocol.Failure(413,"Media exceeds the 100 MB capture limit") }
        try handle.seek(toOffset:0)
        let head = try handle.read(upToCount:4096) ?? Data()
        try handle.seek(toOffset:size - min(size,65_557))
        let tail = try handle.readToEnd() ?? Data()
        guard let sniffed = sniff(head), !hasArchiveTrailer(tail) else { throw CaptureProtocol.Failure(422,"That link is not an image or video") }
        if sniffed.kind == "image" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0 > 0 else {
                throw CaptureProtocol.Failure(422,"The image could not be read")
            }
        }
        return sniffed
    }

    /// Marks a saved file as downloaded from the web, like browser downloads.
    public static func quarantine(_ file: URL, from url: URL, page: String) {
        var values = URLResourceValues(), target = file
        var properties: [String:Any] = [kLSQuarantineAgentNameKey as String:"Folio",kLSQuarantineTypeKey as String:kLSQuarantineTypeWebDownload as String,
                                        kLSQuarantineDataURLKey as String:url]
        if let page = URL(string:page) { properties[kLSQuarantineOriginURLKey as String] = page }
        values.quarantineProperties = properties
        if (try? target.setResourceValues(values)) == nil {
            let value = String(format:"0081;%08x;Folio;",Int(Date().timeIntervalSince1970))
            _ = value.withCString { setxattr(file.path,"com.apple.quarantine",$0,strlen($0),0,0) }
        }
    }
}

// MARK: - Network ranges

/// Media downloads may only reach the public internet, never this Mac or the local network.
public enum CaptureNetwork {
    /// Parses an IPv4 or IPv6 literal (brackets and zone suffixes allowed) into its bytes.
    public static func address(_ text: String) -> [UInt8]? {
        var literal = text.trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        if let zone = literal.firstIndex(of:"%") { literal = String(literal[..<zone]) }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET,literal,&v4) == 1 { return withUnsafeBytes(of:&v4) { Array($0) } }
        if inet_pton(AF_INET6,literal,&v6) == 1 { return withUnsafeBytes(of:&v6) { Array($0) } }
        return nil
    }

    public static func isPublic(_ a: [UInt8]) -> Bool {
        if a.count == 4 {
            switch (a[0],a[1]) {
            case (0,_),(10,_),(127,_),(169,254),(192,168),(198,18),(198,19): return false
            case (100,64...127),(172,16...31): return false
            case (192,0) where a[2] == 0 || a[2] == 2: return false
            case (198,51) where a[2] == 100: return false
            case (203,0) where a[2] == 113: return false
            default: return a[0] < 224
            }
        }
        guard a.count == 16 else { return false }
        let embedded = Array(a[12..<16])
        if a[0..<10].allSatisfy({ $0 == 0 }) && a[10] == 0xFF && a[11] == 0xFF { return isPublic(embedded) }
        if a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xFF && a[3] == 0x9B && a[4..<12].allSatisfy({ $0 == 0 }) { return isPublic(embedded) }
        if a[0] == 0x20 && a[1] == 0x02 { return isPublic(Array(a[2..<6])) }
        if a[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if a[0] == 0xFF || a[0] & 0xFE == 0xFC || (a[0] == 0xFE && a[1] & 0x80 == 0x80) { return false }
        if a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0D && a[3] == 0xB8 { return false }
        if a[0] == 0x01 && a[1] == 0x00 && a[2..<8].allSatisfy({ $0 == 0 }) { return false }
        return a[0] & 0xE0 == 0x20
    }

    /// Resolves a host and returns its addresses; an empty result means it did not resolve.
    public static func resolve(_ host: String) -> [[UInt8]] {
        if let literal = address(host) { return [literal] }
        var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host,nil,&hints,&list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var out: [[UInt8]] = [], node: UnsafeMutablePointer<addrinfo>? = list
        while let entry = node?.pointee {
            if let sa = entry.ai_addr {
                if entry.ai_family == AF_INET {
                    out.append(sa.withMemoryRebound(to:sockaddr_in.self,capacity:1) { p in var a = p.pointee.sin_addr; return withUnsafeBytes(of:&a) { Array($0) } })
                } else if entry.ai_family == AF_INET6 {
                    out.append(sa.withMemoryRebound(to:sockaddr_in6.self,capacity:1) { p in var a = p.pointee.sin6_addr; return withUnsafeBytes(of:&a) { Array($0) } })
                }
            }
            node = entry.ai_next
        }
        return out
    }

    /// Throws unless every address the host resolves to is public.
    public static func checkPublic(_ url: URL) throws {
        guard CaptureProtocol.webURL(url.absoluteString) != nil, let host = url.host else {
            throw CaptureProtocol.Failure(422,"Only web addresses that start with http or https can be saved")
        }
        let addresses = resolve(host)
        guard !addresses.isEmpty else { throw CaptureProtocol.Failure(422,"Could not find \(host)") }
        guard addresses.allSatisfy(isPublic) else { throw CaptureProtocol.Failure(422,"Folio only saves media from the public web") }
    }
}

// MARK: - Connection key

/// The per-library secret shared with paired browser extensions. Stored owner-only.
public enum CaptureKey {
    public static func load(in root: URL) throws -> String {
        let file = root.appendingPathComponent("capture-key")
        if let saved = try? String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines), isValid(saved) {
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            return saved
        }
        return try reset(in:root)
    }

    @discardableResult
    public static func reset(in root: URL) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let key = (0..<32).map { _ in String(format:"%02x",UInt8.random(in:0...255,using:&generator)) }.joined()
        try write(Data(key.utf8),to:root.appendingPathComponent("capture-key"))
        return key
    }

    public static func isValid(_ key: String) -> Bool { key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// Created 0600 under a temporary name, then renamed, so the key is never briefly readable by others.
    static func write(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".capture-key-\(UUID().uuidString)")
        let fd = open(temp.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw CaptureProtocol.Failure(500,"Could not save the connection key") }
        let written = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,data.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temp.path,file.path) == 0 else {
            unlink(temp.path); throw CaptureProtocol.Failure(500,"Could not save the connection key")
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
