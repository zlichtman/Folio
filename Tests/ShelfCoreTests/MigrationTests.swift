import XCTest
import CSQLite
@testable import ShelfCore

func temporaryLibrary(_ test: XCTestCase) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-tests-" + UUID().uuidString)
    test.addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    return root
}

func sqlite(_ path: String, _ sql: String) {
    var handle: OpaquePointer?
    precondition(sqlite3_open(path,&handle) == SQLITE_OK)
    let result = sqlite3_exec(handle,sql,nil,nil,nil)
    precondition(result == SQLITE_OK,String(cString:sqlite3_errmsg(handle)))
    sqlite3_close(handle)
}

func userVersion(_ path: String) -> Int {
    var handle: OpaquePointer?, p: OpaquePointer?
    sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil); defer { sqlite3_close(handle) }
    sqlite3_prepare_v2(handle,"PRAGMA user_version",-1,&p,nil); defer { sqlite3_finalize(p) }
    return sqlite3_step(p) == SQLITE_ROW ? Int(sqlite3_column_int(p,0)) : -1
}

final class MigrationTests: XCTestCase {
    /// The exact schema version 2 of Folio wrote.
    static let versionTwo = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS items(
          id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT NOT NULL,
          source TEXT NOT NULL, collection TEXT NOT NULL, tags TEXT NOT NULL,
          note TEXT NOT NULL, ocr TEXT NOT NULL, kind TEXT NOT NULL, added REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS items_collection ON items(collection, added DESC, id);
        CREATE INDEX IF NOT EXISTS items_added ON items(added DESC, id);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(title, tags, note, ocr, source,
          content='items', content_rowid='rowid', tokenize='unicode61', prefix='2 3');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO search(rowid,title,tags,note,ocr,source)
          VALUES(new.rowid,new.title,new.tags,new.note,new.ocr,new.source); END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO search(search,rowid,title,tags,note,ocr,source)
          VALUES('delete',old.rowid,old.title,old.tags,old.note,old.ocr,old.source); END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
          INSERT INTO search(search,rowid,title,tags,note,ocr,source)
          VALUES('delete',old.rowid,old.title,old.tags,old.note,old.ocr,old.source);
          INSERT INTO search(rowid,title,tags,note,ocr,source)
          VALUES(new.rowid,new.title,new.tags,new.note,new.ocr,new.source); END;
        CREATE TABLE IF NOT EXISTS analysis(id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
          signature TEXT NOT NULL, payload TEXT NOT NULL);
        ALTER TABLE items ADD COLUMN width REAL NOT NULL DEFAULT 0;
        ALTER TABLE items ADD COLUMN height REAL NOT NULL DEFAULT 0;
        PRAGMA user_version=2;
        """

    func makeVersionTwo(_ root: URL) throws -> String {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let path = root.appendingPathComponent("index.sqlite").path
        let analysis = ImageAnalysis(suggestions:[.init(label:"cat",confidence:0.8),.init(label:"blue",confidence:0.4,evidence:"color")],
                                     colors:["#1030c0","#ffffff"],text:"",engine:"test",elapsedMS:1)
        let payload = String(decoding:try JSONEncoder().encode(analysis),as:UTF8.self).replacingOccurrences(of:"'",with:"''")
        sqlite(path,Self.versionTwo + """
            INSERT INTO items(id,path,title,source,collection,tags,note,ocr,kind,added,width,height) VALUES
              ('a','/lib/a.jpg','Cat on sofa','','Inbox','manual  cat blue','sleepy','','image',100,800,600),
              ('b','/lib/b.PNG','Poster','','Design','poster swiss','','','image',200,1000,1500),
              ('c','https://www.example.com/page','Example page','https://www.example.com/page','Design','','','','link',300,0,0),
              ('d','/lib/d.jpg','Ticket','','Travel','','','boarding pass gate 12','image',400,600,400),
              ('e','/lib/e.jpg','Loose','','','','','','image',500,10,10);
            INSERT INTO analysis VALUES('a','sig','\(payload)');
            INSERT INTO analysis VALUES('orphan','sig','{}');
            """)
        return path
    }

    func testMigratesVersionTwoLibrary() throws {
        let root = temporaryLibrary(self); _ = try makeVersionTwo(root)
        let db = try LibraryDatabase(root:root)
        XCTAssertEqual(try db.integer("PRAGMA user_version"),LibraryDatabase.schemaVersion)
        let snapshots = db.snapshots()
        XCTAssertEqual(snapshots.count,1)
        XCTAssertTrue(snapshots[0].lastPathComponent.hasSuffix("-v2.sqlite"))
        XCTAssertEqual(userVersion(snapshots[0].path),2,"The snapshot is the untouched old database")

        let collections = try db.collections()
        let regular = collections.filter { !$0.isSmart }
        XCTAssertEqual(regular.map(\.name),["Design","Travel"])
        XCTAssertEqual(collections.filter(\.isSmart).map(\.name),SmartRules.autoSort.map(\.name))
        let design = try XCTUnwrap(regular.first), travel = try XCTUnwrap(regular.last)

        XCTAssertEqual(Set(try db.items(scope:.inbox).map(\.id)),["a","e"])
        XCTAssertEqual(try db.items(scope:.collection(design.id),sort:.added,ascending:true).map(\.id),["b","c"])
        XCTAssertEqual(try db.items(scope:.collection(travel.id)).map(\.id),["d"])

        let a = try XCTUnwrap(db.item(id:"a"))
        XCTAssertEqual(a.tags,["manual"]); XCTAssertEqual(a.autoTags,["cat","blue"]); XCTAssertEqual(a.colors,["#1030c0","#ffffff"])
        XCTAssertEqual(a.note,"sleepy"); XCTAssertEqual(a.width,800)
        XCTAssertNotNil(try db.analysis(id:"a"))
        XCTAssertEqual(try db.analysisSignatures().keys.sorted(),["a"],"Analysis of long-gone items doesn't block migration")
        let b = try XCTUnwrap(db.item(id:"b"))
        XCTAssertEqual(b.ext,"png"); XCTAssertEqual(b.tags,["poster","swiss"]); XCTAssertEqual(b.fileDate,200); XCTAssertEqual(b.collections,[design.id])
        let c = try XCTUnwrap(db.item(id:"c"))
        XCTAssertEqual(c.url,"https://www.example.com/page"); XCTAssertEqual(c.site,"example.com"); XCTAssertEqual(c.ext,"")
        let d = try XCTUnwrap(db.item(id:"d"))
        XCTAssertEqual(d.ocr,"boarding pass gate 12"); XCTAssertTrue(d.hasText)

        XCTAssertEqual(Set(try db.items(query:"design").map(\.id)),["b","c"],"Collection names are searchable")
        XCTAssertEqual(try db.items(query:"boarding").map(\.id),["d"])
        XCTAssertEqual(try db.items(query:"sleepy").map(\.id),["a"])
        XCTAssertEqual(try db.items(query:"example").map(\.id),["c"])
        XCTAssertEqual(try db.items(scope:.tag("Manual")).map(\.id),["a"])
        XCTAssertEqual(try db.count(),5)
        XCTAssertEqual(try db.integer("SELECT count(*) FROM pragma_foreign_key_check"),0)

        let reopened = try LibraryDatabase(root:root)
        XCTAssertEqual(reopened.snapshots().count,1,"No second migration")
        XCTAssertEqual(try reopened.collections().count,collections.count,"Built-ins are seeded once")
    }

    func testNewerLibraryIsLeftUntouched() throws {
        let root = temporaryLibrary(self)
        do { let db = try LibraryDatabase(root:root); try db.insert([ShelfItem(path:"/x.jpg")]) }
        let file = root.appendingPathComponent("index.sqlite")
        sqlite(file.path,"PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; PRAGMA user_version=99;")
        let before = try Data(contentsOf:file)
        XCTAssertThrowsError(try LibraryDatabase(root:root)) { error in
            XCTAssertEqual(error as? LibraryError,.newerLibrary(version:99))
            XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion)
        }
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertEqual(userVersion(file.path),99)
    }

    func testErrorsReadLikeSentences() {
        let errors: [LocalizedError] = [LibraryError.newerLibrary(version:4),LibraryError.collectionNotFound,LibraryError.smartCollection,
                                        LibraryError.invalidMove,LibraryError.emptyName,LibraryError.folderNotFound,
                                        DatabaseError("disk I/O error",code:SQLITE_FULL),DatabaseError("database is locked",code:SQLITE_BUSY)]
        for error in errors {
            let description = error.errorDescription ?? "", suggestion = error.recoverySuggestion ?? ""
            XCTAssertTrue(description.hasSuffix(".") && suggestion.hasSuffix("."),"\(error)")
            XCTAssertFalse(description.contains("SQLite") || description.contains("SQL"))
        }
        XCTAssertEqual(DatabaseError("x",code:SQLITE_FULL).errorDescription,"There isn't enough disk space to save changes to your library.")
    }

    func testSnapshotsKeepTheNewestAutomaticCopies() throws {
        let root = temporaryLibrary(self), db = try LibraryDatabase(root:root)
        try db.insert([ShelfItem(path:"/x.jpg")])
        XCTAssertNotNil(try db.snapshotIfDue())
        XCTAssertNil(try db.snapshotIfDue(),"One a day")
        for _ in 0..<9 { try db.snapshot() }
        let autos = db.snapshots().filter { $0.lastPathComponent.hasSuffix("-auto.sqlite") }
        XCTAssertEqual(autos.count,LibraryDatabase.keptSnapshots)
        XCTAssertEqual(userVersion(autos[0].path),LibraryDatabase.schemaVersion)
    }

    func testFreshLibrarySeedsAutoSortOnce() throws {
        let root = temporaryLibrary(self)
        let db = try LibraryDatabase(root:root)
        XCTAssertEqual(try db.collections().filter(\.isSmart).count,SmartRules.autoSort.count)
        XCTAssertTrue(db.snapshots().isEmpty)
        let id = try XCTUnwrap(db.collections().first { $0.name == "GIFs" }?.id)
        try db.deleteCollection(id)
        XCTAssertNil(try LibraryDatabase(root:root).collections().first { $0.name == "GIFs" },"Deleted built-ins stay deleted")
    }
}
