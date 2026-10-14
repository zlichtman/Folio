import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShelfCore

final class CaptureProtocolTests: XCTestCase {
    let token = String(repeating:"ab",count:32)

    func raw(_ text: String) -> Data { Data(text.utf8) }
    func request(_ method: String = "GET", _ path: String = "/health", headers: [String:String] = [:], body: String = "") -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (name,value) in headers.sorted(by:{ $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
        return raw(head + "\r\n" + body)
    }
    func complete(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> CaptureProtocol.Request? {
        guard case .complete(let request) = CaptureProtocol.parse(data) else { XCTFail("Expected a complete request",file:file,line:line); return nil }
        return request
    }
    func status(_ data: Data) -> Int? {
        if case .invalid(let failure) = CaptureProtocol.parse(data) { return failure.status }
        return nil
    }
    var good: [String:String] { ["Host":"127.0.0.1:53187","Authorization":"Bearer \(token)"] }

    func testParsesRequestsIncrementally() throws {
        let full = request("POST","/save?x=1",headers:good,body:"{\"url\":\"https://example.com\"}")
        for cut in [0,5,full.count / 2,full.count - 1] { XCTAssertEqual(CaptureProtocol.parse(full.prefix(cut)),.incomplete) }
        let parsed = try XCTUnwrap(complete(full))
        XCTAssertEqual(parsed.method,"POST"); XCTAssertEqual(parsed.path,"/save")
        XCTAssertEqual(parsed.headers["host"],"127.0.0.1:53187")
        XCTAssertEqual(String(decoding:parsed.body,as:UTF8.self),"{\"url\":\"https://example.com\"}")
        XCTAssertEqual(complete(full + raw("GET / HTTP/1.1\r\n\r\n"))?.body.count,29)
        XCTAssertEqual(complete(Data(full.dropFirst(0)).subdata(in:0..<full.count))?.path,"/save")
    }

    func testHeadersArriveBeforeTheBody() throws {
        let full = request("POST","/save",headers:good,body:String(repeating:"x",count:1000))
        let cut = full.prefix(full.count - 500)
        XCTAssertEqual(CaptureProtocol.parse(cut),.incomplete)
        let head = try XCTUnwrap(CaptureProtocol.headers(cut))
        XCTAssertEqual(head.path,"/save"); XCTAssertTrue(head.body.isEmpty)
        XCTAssertNil(CaptureProtocol.authorize(head,token:token))
        XCTAssertNil(CaptureProtocol.headers(full.prefix(10)))
        XCTAssertNil(CaptureProtocol.headers(raw("GARBAGE\r\n\r\n")))
    }

    func testMalformedRequestsAreRejected() {
        XCTAssertEqual(status(raw("GARBAGE\r\n\r\n")),400)
        XCTAssertEqual(status(raw("get /health HTTP/1.1\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET health HTTP/1.1\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET /health HTTP/2\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET  /health HTTP/1.1\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET /health HTTP/1.1\r\nNoColon\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET /health HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET /health HTTP/1.1\r\nBad Name: a\r\n\r\n")),400)
        XCTAssertEqual(status(Data([0x47,0x45,0x54,0x20,0xFF,0xFE,0x0D,0x0A,0x0D,0x0A])),400)
        XCTAssertEqual(status(raw("POST /save HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")),501)
        XCTAssertEqual(status(raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:53187\r\nHost: evil.test\r\n\r\n")),400)
        XCTAssertEqual(status(raw("GET / HTTP/1.1\r\nAuthorization: a\r\nauthorization: b\r\n\r\n")),400)
        for length in ["+5","-1","5 5","0x10","","１"] {
            XCTAssertEqual(status(raw("POST /save HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n")),400,length)
        }
        XCTAssertEqual(complete(raw("GET / HTTP/1.1\r\nAccept: a\r\nAccept: b\r\n\r\n"))?.headers["accept"],"a, b")
    }

    func testSizeLimits() {
        XCTAssertEqual(status(raw("POST /save HTTP/1.1\r\nContent-Length: \(CaptureProtocol.maxBody + 1)\r\n\r\n")),413)
        XCTAssertEqual(status(raw("POST /save HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n")),413)
        XCTAssertEqual(status(raw("POST /save HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\n")),400)
        XCTAssertEqual(CaptureProtocol.parse(raw("POST /save HTTP/1.1\r\nContent-Length: \(CaptureProtocol.maxBody)\r\n\r\n")),.incomplete)
        let longHeader = raw("GET / HTTP/1.1\r\nX: " + String(repeating:"a",count:CaptureProtocol.maxHeader) + "\r\n\r\n")
        XCTAssertEqual(status(longHeader),431)
        XCTAssertEqual(status(raw(String(repeating:"a",count:CaptureProtocol.maxHeader + 1))),431)
        XCTAssertEqual(CaptureProtocol.parse(raw(String(repeating:"a",count:CaptureProtocol.maxHeader))),.incomplete)
    }

    func testHostOriginAndKeyChecks() throws {
        func check(_ headers: [String:String]) throws -> Int? {
            CaptureProtocol.authorize(try XCTUnwrap(complete(request(headers:headers))),token:token)?.status
        }
        XCTAssertNil(try check(good))
        XCTAssertNil(try check(good.merging(["Host":"localhost:53187"]) { $1 }))
        XCTAssertNil(try check(good.merging(["Host":"LocalHost:53187"]) { $1 }))
        XCTAssertNil(try check(good.merging(["Origin":"moz-extension://8c3a5f"]) { $1 }))
        XCTAssertNil(try check(good.merging(["Origin":"chrome-extension://abcdefghijklmnop"]) { $1 }))
        XCTAssertNil(try check(good.merging(["Authorization":"bearer \(token)"]) { $1 }))
        for host in ["evil.test:53187","127.0.0.1","127.0.0.1:80","localhost","attacker.localhost:53187","[::1]:53187","127.0.0.1:53187.evil.test"] {
            XCTAssertEqual(try check(good.merging(["Host":host]) { $1 }),421,host)
        }
        var noHost = good; noHost["Host"] = nil
        XCTAssertEqual(try check(noHost),421)
        for origin in ["https://example.com","null","http://127.0.0.1:53187","moz-extension://","file://","chrome-extension:/x"] {
            XCTAssertEqual(try check(good.merging(["Origin":origin]) { $1 }),403,origin)
        }
        var noKey = good; noKey["Authorization"] = nil
        XCTAssertEqual(try check(noKey),401)
        for value in ["Bearer","Bearer ","Basic \(token)","Bearer \(token.dropLast())","Bearer \(token)00","Bearer \(token.uppercased())",token] {
            XCTAssertEqual(try check(good.merging(["Authorization":value]) { $1 }),401,value)
        }
    }

    func testTokenComparison() {
        XCTAssertTrue(CaptureProtocol.tokensMatch(token,token))
        XCTAssertFalse(CaptureProtocol.tokensMatch("",token))
        XCTAssertFalse(CaptureProtocol.tokensMatch(token + "a",token))
        XCTAssertFalse(CaptureProtocol.tokensMatch(String(token.dropLast()) + "c",token))
        XCTAssertFalse(CaptureProtocol.tokensMatch("",""))
    }

    func testOnlyWebURLs() {
        for good in ["https://example.com/a.jpg","http://example.com","HTTPS://EXAMPLE.COM/x?y=1#z"] { XCTAssertNotNil(CaptureProtocol.webURL(good),good) }
        for bad in ["file:///etc/hosts","javascript:alert(1)","data:image/png;base64,AAAA","ftp://example.com/a","blob:https://example.com/x",
                    "https://user:pass@example.com/","https://user@example.com/","http:///nohost","example.com/a.jpg","",
                    "https://example.com/" + String(repeating:"a",count:9000)] {
            XCTAssertNil(CaptureProtocol.webURL(bad),bad)
        }
    }

    func testCaptureRequestsNormalize() throws {
        let link = try CaptureJob(CaptureRequest(url:"https://example.com/article",title:"  Read\nthis  ",kind:"link",collection:" Ideas ",source:"https://news.example/"))
        XCTAssertEqual(link.kind,.link); XCTAssertEqual(link.url.absoluteString,"https://example.com/article")
        XCTAssertEqual(link.source,"https://news.example/"); XCTAssertEqual(link.title,"Read this"); XCTAssertEqual(link.collection,"Ideas")
        let untitled = try CaptureJob(CaptureRequest(url:"https://example.com/a/b",kind:"link",collection:"\n\t",source:"javascript:alert(1)"))
        XCTAssertEqual(untitled.title,"example.com/a/b"); XCTAssertEqual(untitled.collection,"Inbox"); XCTAssertEqual(untitled.source,"https://example.com/a/b")
        let image = try CaptureJob(CaptureRequest(url:"https://cdn.example/photo%20one.jpg",kind:"image",source:"https://example.com/gallery"))
        XCTAssertEqual(image.kind,.image); XCTAssertEqual(image.title,"photo one.jpg"); XCTAssertEqual(image.source,"https://example.com/gallery")
        XCTAssertNil(image.snapshot)

        let jpeg = try XCTUnwrap(Self.imageData(.jpeg))
        let page = try CaptureJob(CaptureRequest(url:"https://example.com/",title:"Home",kind:"page",source:"https://other.example/",snapshot:"data:image/jpeg;base64," + jpeg.base64EncodedString()))
        XCTAssertEqual(page.kind,.page); XCTAssertEqual(page.snapshot,jpeg); XCTAssertEqual(page.source,"https://example.com/")
        let legacy = try CaptureJob(CaptureRequest(url:"https://example.com/",kind:"link",snapshot:jpeg.base64EncodedString()))
        XCTAssertEqual(legacy.kind,.page); XCTAssertEqual(legacy.snapshot,jpeg); XCTAssertEqual(legacy.title,"example.com")
        let fake = try CaptureJob(CaptureRequest(url:"https://example.com/",kind:"page",snapshot:Data("#!/bin/sh\necho hi".utf8).base64EncodedString()))
        XCTAssertNil(fake.snapshot)
        XCTAssertNil(try CaptureJob(CaptureRequest(url:"https://example.com/",kind:"page",snapshot:"not base64!")).snapshot)
        XCTAssertEqual(try CaptureJob(CaptureRequest(url:"https://example.com/",collection:String(repeating:"x",count:500))).collection.count,120)

        XCTAssertThrowsError(try CaptureJob(CaptureRequest(url:"file:///etc/passwd",kind:"image")))
        XCTAssertThrowsError(try CaptureJob(CaptureRequest(url:"https://example.com/",kind:"executable")))
        XCTAssertThrowsError(try CaptureJob.decode(Data("{".utf8)))
        XCTAssertThrowsError(try CaptureJob.decode(Data("{\"title\":\"no url\"}".utf8)))
        XCTAssertEqual(try CaptureJob.decode(Data("{\"url\":\"https://example.com/\"}".utf8)).kind,.link)
    }

    // MARK: Media

    static func imageData(_ type: UTType, size: Int = 8) -> Data? {
        guard let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size * 4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.8,alpha:1)); context.fill(CGRect(x:0,y:0,width:size,height:size))
        let data = NSMutableData()
        guard let image = context.makeImage(), let out = CGImageDestinationCreateWithData(data,type.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(out,image,nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    func bytes(_ prefix: [UInt8], _ text: String = "", pad: Int = 32) -> Data {
        Data(prefix) + Data(text.utf8) + Data(repeating:0,count:pad)
    }
    func ftyp(_ brand: String) -> Data { Data([0,0,0,0x18]) + Data("ftyp\(brand)".utf8) + Data(repeating:0,count:32) }

    func testSniffingUsesContentNotNames() throws {
        let expected: [(Data,String,String)] = [
            (try XCTUnwrap(Self.imageData(.jpeg)),"image","jpg"),(try XCTUnwrap(Self.imageData(.png)),"image","png"),
            (try XCTUnwrap(Self.imageData(.gif)),"image","gif"),(try XCTUnwrap(Self.imageData(.tiff)),"image","tiff"),
            (bytes([],"RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 "),"image","webp"),(ftyp("heic"),"image","heic"),(ftyp("avif"),"image","avif"),
            (ftyp("isom"),"video","mp4"),(ftyp("qt  "),"video","mov"),(ftyp("M4V "),"video","m4v"),
            (bytes([0,0,0,8],"moov"),"video","mov"),(bytes([0x1A,0x45,0xDF,0xA3],"\u{42}\u{82}\u{84}webm"),"video","webm"),(bytes([],"RIFF\u{0}\u{0}\u{0}\u{0}AVI LIST"),"video","avi")
        ]
        for (data,kind,ext) in expected {
            XCTAssertEqual(CaptureMedia.sniff(data),CaptureMedia.Sniffed(kind:kind,fileExtension:ext),ext)
        }
        let refused: [(String,Data)] = [
            ("Mach-O",bytes([0xCF,0xFA,0xED,0xFE])),("Universal",bytes([0xCA,0xFE,0xBA,0xBE])),("ELF",bytes([0x7F],"ELF")),
            ("PE",bytes([],"MZ\u{90}\u{0}")),("Script",bytes([],"#!/bin/sh\n")),("Zip",bytes([0x50,0x4B,0x03,0x04])),
            ("Pkg",bytes([],"xar!")),("Gzip",bytes([0x1F,0x8B,0x08])),("7z",bytes([0x37,0x7A,0xBC,0xAF,0x27,0x1C])),
            ("HTML",bytes([],"<!doctype html><html>")),("SVG",bytes([],"<svg xmlns=\"http://www.w3.org/2000/svg\">")),
            ("PDF",bytes([],"%PDF-1.7")),("Matroska",bytes([0x1A,0x45,0xDF,0xA3],"matroska")),("Unknown ftyp",ftyp("abcd")),("Empty",Data()),("Short JPEG",Data([0xFF,0xD8]))
        ]
        for (name,data) in refused { XCTAssertNil(CaptureMedia.sniff(data),name) }
    }

    func testArchiveTrailers() throws {
        let png = try XCTUnwrap(Self.imageData(.png))
        XCTAssertFalse(CaptureMedia.hasArchiveTrailer(png))
        var dmg = png + Data(repeating:7,count:1000); let koly = Data("koly".utf8) + Data(repeating:0,count:508)
        dmg.append(koly)
        XCTAssertTrue(CaptureMedia.hasArchiveTrailer(dmg))
        var zip = png + Data([0x50,0x4B,0x05,0x06]) + Data(repeating:0,count:16) + Data([3,0]) + Data("abc".utf8)
        XCTAssertTrue(CaptureMedia.hasArchiveTrailer(zip))
        zip.append(1)
        XCTAssertFalse(CaptureMedia.hasArchiveTrailer(zip))
    }

    func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        try body(folder)
    }

    func testInspectRefusesFakesArchivesAndOversizedFiles() throws {
        try withFolder { folder in
            let png = try XCTUnwrap(Self.imageData(.png)), file = folder.appendingPathComponent("download")
            try png.write(to:file)
            XCTAssertEqual(try CaptureMedia.inspect(file),CaptureMedia.Sniffed(kind:"image",fileExtension:"png"))
            try (Data([0xFF,0xD8,0xFF,0xE0]) + Data(repeating:0x41,count:2000)).write(to:file)
            XCTAssertThrowsError(try CaptureMedia.inspect(file))
            try (png + Data([0x50,0x4B,0x05,0x06]) + Data(repeating:0,count:18)).write(to:file)
            XCTAssertThrowsError(try CaptureMedia.inspect(file))
            try Data().write(to:file)
            XCTAssertThrowsError(try CaptureMedia.inspect(file))
            try png.write(to:file)
            let handle = try FileHandle(forWritingTo:file)
            try handle.truncate(atOffset:UInt64(CaptureProtocol.maxMedia + 1)); try handle.close()
            XCTAssertEqual((try? CaptureMedia.inspect(file)) == nil,true)
            do { _ = try CaptureMedia.inspect(file) } catch let failure as CaptureProtocol.Failure { XCTAssertEqual(failure.status,413) }
            try ftyp("isom").write(to:file)
            XCTAssertEqual(try CaptureMedia.inspect(file).kind,"video")
        }
    }

    func testQuarantineIsApplied() throws {
        try withFolder { folder in
            let file = folder.appendingPathComponent("saved.png")
            try XCTUnwrap(Self.imageData(.png)).write(to:file)
            CaptureMedia.quarantine(file,from:URL(string:"https://cdn.example/a.png")!,page:"https://example.com/")
            let size = getxattr(file.path,"com.apple.quarantine",nil,0,0,0)
            XCTAssertGreaterThan(size,0)
        }
    }

    // MARK: Network

    func testPublicAddressRanges() {
        for address in ["8.8.8.8","93.184.216.34","1.1.1.1","2606:4700:4700::1111","2a00:1450:4001::200e","64:ff9b::808:808","::ffff:8.8.8.8","2002:0808:0808::1"] {
            XCTAssertTrue(CaptureNetwork.isPublic(CaptureNetwork.address(address)!),address)
        }
        for address in ["127.0.0.1","127.255.0.9","10.1.2.3","172.16.0.1","172.31.255.255","192.168.1.1","169.254.169.254","0.0.0.0","100.64.0.1",
                        "192.0.0.8","192.0.2.1","198.18.0.1","198.51.100.2","203.0.113.9","224.0.0.1","239.1.1.1","240.0.0.1","255.255.255.255",
                        "::","::1","[::1]","fe80::1%en0","fec0::1","fc00::1","fd12:3456::1","ff02::1","::ffff:127.0.0.1","::ffff:192.168.0.1",
                        "64:ff9b::7f00:1","2002:7f00:0001::1","2001:db8::1","::127.0.0.1","100::1"] {
            XCTAssertFalse(CaptureNetwork.isPublic(CaptureNetwork.address(address)!),address)
        }
        XCTAssertTrue(CaptureNetwork.isPublic(CaptureNetwork.address("172.32.0.1")!))
        XCTAssertTrue(CaptureNetwork.isPublic(CaptureNetwork.address("100.128.0.1")!))
        XCTAssertNil(CaptureNetwork.address("example.com"))
        XCTAssertNil(CaptureNetwork.address("999.1.1.1"))
        XCTAssertFalse(CaptureNetwork.isPublic([1,2,3]))
    }

    func testDownloadsRefuseThisMacAndTheLocalNetwork() throws {
        for url in ["http://127.0.0.1/a.jpg","http://localhost:8080/a.jpg","http://[::1]/a.jpg","http://2130706433/a.jpg","http://0x7f000001/a.jpg",
                    "http://10.0.0.1/a.jpg","http://169.254.169.254/latest/meta-data","http://192.168.1.1/","http://[fe80::1]/"] {
            XCTAssertThrowsError(try CaptureNetwork.checkPublic(URL(string:url)!),url)
        }
        XCTAssertNoThrow(try CaptureNetwork.checkPublic(URL(string:"https://93.184.216.34/a.jpg")!))
        XCTAssertThrowsError(try CaptureNetwork.checkPublic(URL(string:"file:///etc/hosts")!))
    }

    // MARK: Key

    func testKeyIsOwnerOnlyAndStable() throws {
        try withFolder { folder in
            let file = folder.appendingPathComponent("capture-key")
            func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
            let first = try CaptureKey.load(in:folder)
            XCTAssertTrue(CaptureKey.isValid(first)); XCTAssertEqual(try mode(),0o600)
            XCTAssertEqual(try CaptureKey.load(in:folder),first)
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
            XCTAssertEqual(try CaptureKey.load(in:folder),first); XCTAssertEqual(try mode(),0o600)
            let second = try CaptureKey.reset(in:folder)
            XCTAssertNotEqual(first,second); XCTAssertEqual(try CaptureKey.load(in:folder),second); XCTAssertEqual(try mode(),0o600)
            try "not a key".write(to:file,atomically:true,encoding:.utf8)
            let third = try CaptureKey.load(in:folder)
            XCTAssertTrue(CaptureKey.isValid(third)); XCTAssertNotEqual(third,second); XCTAssertEqual(try mode(),0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["capture-key"])
            XCTAssertFalse(CaptureKey.isValid(String(repeating:"A",count:64)))
        }
    }

    func testResponsesAreJSONWithoutCORS() {
        let text = String(decoding:CaptureProtocol.response(status:401,body:["error":"No"]),as:UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 14\r\n")); XCTAssertTrue(text.hasSuffix("{\"error\":\"No\"}"))
        XCTAssertFalse(text.lowercased().contains("access-control"))
    }
}
