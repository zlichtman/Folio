import XCTest
import ImageIO
@testable import ShelfCore

final class ImportTests: XCTestCase {
    func png(_ url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let context = CGContext(data:nil,width:64,height:48,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red:0.2,green:0.4,blue:0.9,alpha:1); context.fill(CGRect(x:0,y:0,width:64,height:48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:object).write(to:url)
    }

    func testEagleLibraryArrivesAsNestedCollectionsAndUpdatesInPlace() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Moodboards-\(UUID().uuidString.prefix(6)).library")
        defer { try? FileManager.default.removeItem(at:source) }
        try write(["folders":[["id":"F1","name":"Posters","children":[["id":"F2","name":"Swiss","children":[]]]],["id":"F3","name":"UI","children":[]]]],
                  to:source.appendingPathComponent("metadata.json"))
        func add(_ id: String, _ name: String, folders: [String], tags: [String], deleted: Bool = false) throws {
            let info = source.appendingPathComponent("images/\(id).info")
            try png(info.appendingPathComponent("\(name).png")); try png(info.appendingPathComponent("\(name)_thumbnail.png"))
            try write(["id":id,"name":name,"ext":"png","tags":tags,"folders":folders,"isDeleted":deleted,"url":"https://example.com/\(id)",
                       "annotation":"note \(id)","btime":1_700_000_000_000.0],to:info.appendingPathComponent("metadata.json"))
        }
        try add("A","Grid poster",folders:["F2"],tags:["swiss","grid"])
        try add("B","Login screen",folders:["F3"],tags:["ui"])
        try add("C","Loose",folders:[],tags:[])
        try add("D","Deleted",folders:["F3"],tags:[],deleted:true)

        XCTAssertTrue(LibraryImport.isEagle(source))
        let library = try LibraryImport.read(source)
        XCTAssertEqual(library.items.count,3)
        let db = try LibraryDatabase(root:temporaryLibrary(self))
        let first = try db.importLibrary(library)
        XCTAssertEqual(first.added,3); XCTAssertEqual(first.updated,0)

        let collections = try db.collections()
        let root = try XCTUnwrap(collections.first { $0.name == library.name && $0.parent == nil })
        let posters = try XCTUnwrap(collections.first { $0.name == "Posters" }), swiss = try XCTUnwrap(collections.first { $0.name == "Swiss" })
        XCTAssertEqual(posters.parent,root.id); XCTAssertEqual(swiss.parent,posters.id)
        let poster = try XCTUnwrap(try db.items(scope:.collection(swiss.id)).first)
        XCTAssertEqual(poster.title,"Grid poster"); XCTAssertEqual(Set(poster.tags),["swiss","grid"])
        XCTAssertEqual(poster.source,"https://example.com/A"); XCTAssertEqual(poster.note,"note A"); XCTAssertEqual(poster.added,1_700_000_000)
        XCTAssertTrue(poster.path.hasPrefix(db.mediaFolder.path),"Eagle's files are copied in")
        XCTAssertTrue(try db.items(scope:.collection(root.id)).contains { $0.title == "Loose" })

        // Again, with a new tag on one item: nothing doubles, the tag joins.
        var again = library; again.items[0].tags.append("print")
        let second = try db.importLibrary(again)
        XCTAssertEqual(second.added,0); XCTAssertEqual(second.updated,3)
        XCTAssertEqual(try db.count(),3)
        XCTAssertEqual(try db.collections().filter { $0.name == "Posters" }.count,1)
        XCTAssertTrue(try db.item(id:poster.id)?.tags.contains("print") == true)
    }

    func testFolderTreeKeepsFilesInPlace() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Refs-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at:source) }
        try png(source.appendingPathComponent("top.png"))
        try png(source.appendingPathComponent("Type/serif.png"))
        try png(source.appendingPathComponent("Type/Display/big.png"))
        let library = try LibraryImport.read(source)
        XCTAssertFalse(LibraryImport.isEagle(source)); XCTAssertEqual(library.items.count,3)
        let db = try LibraryDatabase(root:temporaryLibrary(self))
        let result = try db.importLibrary(library,tags:false,sources:false)
        XCTAssertEqual(result.added,3)
        let display = try XCTUnwrap(try db.collections().first { $0.name == "Display" })
        let big = try XCTUnwrap(try db.items(scope:.collection(display.id)).first)
        XCTAssertEqual(URL(fileURLWithPath:big.path).resolvingSymlinksInPath(),source.appendingPathComponent("Type/Display/big.png").resolvingSymlinksInPath())
    }
}

final class CrossLibraryTests: XCTestCase {
    func testCopiesItemsWithTheirDetailsAndOwnFiles() throws {
        let here = try LibraryDatabase(root:temporaryLibrary(self)), there = try LibraryDatabase(root:temporaryLibrary(self))
        try FileManager.default.createDirectory(at:here.mediaFolder,withIntermediateDirectories:true)
        let kept = here.mediaFolder.appendingPathComponent("pasted.png"); try Data("png".utf8).write(to:kept)
        try here.insert([ShelfItem(id:"own",path:kept.path,note:"mine",liked:true),ShelfItem(id:"shared",path:"/Users/x/Pictures/a.jpg",tags:["blue"])])
        let arrived = try here.copy(["own","shared"],to:there)
        XCTAssertEqual(arrived.count,2)
        let copied = try there.items()
        let own = try XCTUnwrap(copied.first { $0.note == "mine" })
        XCTAssertTrue(own.liked); XCTAssertTrue(own.path.hasPrefix(there.mediaFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:own.path))
        XCTAssertEqual(copied.first { $0.path == "/Users/x/Pictures/a.jpg" }?.tags,["blue"])
        XCTAssertEqual(try here.count(),2,"copying leaves this library as it was")
    }
}
