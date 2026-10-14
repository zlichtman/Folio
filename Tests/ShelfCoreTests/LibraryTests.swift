import XCTest
import ImageIO
import CoreGraphics
@testable import ShelfCore

final class LibraryTests: XCTestCase {
    func withLibrary(_ body: (LibraryDatabase) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(LibraryDatabase(root:root))
    }
    func testSearchTracksEditsOCRAndDeletion() throws {
        try withLibrary { database in
            let design = try database.createCollection(name:"Design"), photo = try database.createCollection(name:"Photo")
            let item = ShelfItem(path:"/a.jpg",title:"Untitled")
            try database.insert([item],into:design.id)
            XCTAssertTrue(try database.items(query:"typography").isEmpty)
            try database.setTags(["typography"],for:[item.id]); try database.setNote("editorial system",for:[item.id])
            XCTAssertEqual(try database.items(scope:.collection(design.id),query:"typ").map(\.id),[item.id])
            try database.updateOCR(id:item.id,text:"The secret phrase")
            XCTAssertEqual(try database.items(query:"secret phrase").count,1)
            XCTAssertEqual(try database.item(id:item.id)?.ocr,"The secret phrase")
            XCTAssertEqual(try database.items().first?.ocr,"","Listings never load recognized text")
            XCTAssertEqual(try database.items().first?.hasText,true)
            try database.setTags(["photography"],for:[item.id]); try database.setNote("",for:[item.id])
            try database.moveItems([item.id],from:nil,to:photo.id)
            XCTAssertTrue(try database.items(query:"typography").isEmpty)
            XCTAssertTrue(try database.items(scope:.collection(design.id)).isEmpty)
            try database.deletePermanently([item.id])
            XCTAssertTrue(try database.items(query:"secret").isEmpty)
        }
    }
    func testDuplicateImportPreservesUserMetadata() throws {
        try withLibrary { database in
            let item = ShelfItem(path:"/b.jpg",title:"Original")
            try database.insert([item])
            try database.setNote("keep",for:[item.id]); try database.setTags(["favorite"],for:[item.id])
            XCTAssertEqual(try database.insert([item,item]),[item.id,item.id])
            XCTAssertEqual(try database.count(),1)
            XCTAssertEqual(try database.items().first?.note,"keep")
            XCTAssertEqual(try database.items().first?.tags,["favorite"])
        }
    }
    func testUntrustedSearchDoesNotExecuteFTSOperators() throws {
        try withLibrary { database in
            try database.insert([ShelfItem(path:"/c.jpg",title:"warm interior")])
            for query in ["\"", "OR", "NOT", "*", "warm OR interior", "title:warm", "(warm)", "--", "", "-", "tag:", "in:\"", "\"unterminated", "NEAR(a b)", "^warm"] {
                XCTAssertNoThrow(try database.items(query:query),query)
            }
            XCTAssertEqual(try database.items(query:"warm int").count,1)
        }
    }
    func testCollectionIsolation() throws {
        try withLibrary { database in
            let one = try database.createCollection(name:"One"), two = try database.createCollection(name:"Two")
            try database.insert([ShelfItem(path:"/one",title:"blue")],into:one.id)
            try database.insert([ShelfItem(path:"/two",title:"blue")],into:two.id)
            XCTAssertEqual(try database.items(scope:.collection(one.id),query:"blue").count,1)
            XCTAssertEqual(try database.items(query:"blue").count,2)
        }
    }
    func testVisibleWorkDoesNotScaleWithLibrarySize() {
        let small = GridGeometry(count:1000,width:960,tileSize:170)
        let large = GridGeometry(count:100000,width:960,tileSize:170)
        XCTAssertEqual(small.visibleRange(y:400,height:720,marginRows:1),large.visibleRange(y:400,height:720,marginRows:1))
        XCTAssertLessThan(large.visibleRange(y:400,height:720,marginRows:1).count,40)
        XCTAssertTrue(large.visibleRange(y:large.height,height:720).isEmpty)
        XCTAssertNil(large.index(x:0,y:0))
        let frame = large.frame(index:100)
        XCTAssertEqual(large.index(x:frame.midX,y:frame.midY),100)
    }
    func testMissingMediaHasNoThumbnail() { XCTAssertNil(MediaFiles.thumbnail(url:URL(fileURLWithPath:"/missing-image.jpg"),pixels:256)) }
    func testScanAndDecodeRealMedia() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("actual.PNG")
        let context = try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(output,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        try Data("ignored".utf8).write(to:folder.appendingPathComponent("notes.txt"))
        let items = MediaFiles.scan([folder,file])
        XCTAssertEqual(items.count,1)
        XCTAssertEqual(items[0].kind,"image")
        XCTAssertEqual(items[0].ext,"png")
        XCTAssertGreaterThan(items[0].fileSize,0)
        XCTAssertGreaterThan(items[0].fileDate,0)
        XCTAssertEqual(MediaFiles.scanGroups([folder]).first?.group,folder.lastPathComponent)
        XCTAssertNotNil(MediaFiles.thumbnail(url:file,pixels:256))
    }
}
