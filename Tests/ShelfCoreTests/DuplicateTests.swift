import XCTest
@testable import ShelfCore

final class DuplicateTests: XCTestCase {
    func testFindsExactCopiesAndKeepsTheOldest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dups-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        func file(_ name: String, _ bytes: String) throws -> ShelfItem {
            let url = folder.appendingPathComponent(name); try Data(bytes.utf8).write(to:url)
            return ShelfItem(id:name,path:url.path,fileSize:Int64(bytes.utf8.count))
        }
        var a = try file("a.png","same picture"), b = try file("b.png","same picture"), c = try file("c.png","same-picture")
        let d = try file("d.png","other"); var e = try file("e.png","same picture")
        a.added = 30; b.added = 10; e.added = 20
        // c has the same size as a but different bytes; d is alone.
        XCTAssertEqual(Duplicates.groups([a,b,c,d,e]),[["b.png","e.png","a.png"]])
        var trashed = e; trashed.trashed = 1
        XCTAssertEqual(Duplicates.groups([a,b,trashed]),[["b.png","a.png"]])
        XCTAssertEqual(Duplicates.groups([a,c,d]),[])
    }
}

final class BackupTests: XCTestCase {
    func testRestoresASnapshotAtTheNextOpen() throws {
        let root = temporaryLibrary(self)
        var db: LibraryDatabase? = try LibraryDatabase(root:root)
        try db!.insert([ShelfItem(id:"a",path:"/a.png")])
        let saved = try db!.snapshot(before:"Empty Trash")
        XCTAssertTrue(saved.lastPathComponent.hasSuffix("-before-empty-trash.sqlite"))
        try db!.insert([ShelfItem(id:"b",path:"/b.png")])
        XCTAssertEqual(try db!.count(),2)
        try LibraryDatabase.scheduleRestore(saved,root:root)
        db = nil
        XCTAssertTrue(LibraryDatabase.applyPendingRestore(root:root))
        XCTAssertFalse(LibraryDatabase.applyPendingRestore(root:root),"a restore happens once")
        let reopened = try LibraryDatabase(root:root)
        XCTAssertEqual(try reopened.count(),1)
        // Only the library's own snapshots can be put back.
        try LibraryDatabase.scheduleRestore(URL(fileURLWithPath:"/etc/hosts"),root:root)
        XCTAssertFalse(LibraryDatabase.applyPendingRestore(root:root))
    }
}
