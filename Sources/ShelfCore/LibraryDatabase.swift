import Foundation
import CSQLite

public struct DatabaseError: LocalizedError, CustomStringConvertible {
    public let message: String
    /// The SQLite result code.
    public let code: Int32
    init(_ message: String, code: Int32 = SQLITE_ERROR) { self.message = message; self.code = code }
    public var description: String { message }
    public var errorDescription: String? {
        switch code & 0xff {
        case SQLITE_FULL: "There isn't enough disk space to save changes to your library."
        case SQLITE_BUSY, SQLITE_LOCKED: "Your library is busy."
        case SQLITE_CORRUPT, SQLITE_NOTADB: "Your library file is damaged."
        case SQLITE_CANTOPEN: "Folio can't open your library."
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH: "Folio can't save to your library."
        case SQLITE_IOERR: "Your library couldn't be read from the disk."
        default: "Folio couldn't finish that change to your library."
        }
    }
    public var recoverySuggestion: String? {
        switch code & 0xff {
        case SQLITE_FULL: "Free up some space on this Mac, then try again."
        case SQLITE_BUSY, SQLITE_LOCKED: "If Folio is open in another window or account, quit it and try again."
        case SQLITE_CORRUPT, SQLITE_NOTADB: "Quit Folio and restore a recent copy from the Snapshots folder inside your library."
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_CANTOPEN, SQLITE_AUTH: "Check that you can write to your library folder, then try again."
        case SQLITE_IOERR: "Check that the disk is connected and working, then try again."
        default: "Try again. If it keeps happening, restart Folio."
        }
    }
}

public enum LibraryError: LocalizedError, Equatable {
    /// The file was written by a newer Folio. It has not been modified.
    case newerLibrary(version: Int)
    case collectionNotFound
    case smartCollection
    case invalidMove
    case emptyName
    case folderNotFound
    public var errorDescription: String? {
        switch self {
        case .newerLibrary: "This library was made with a newer version of Folio."
        case .collectionNotFound: "That collection no longer exists."
        case .smartCollection: "Smart collections fill themselves."
        case .invalidMove: "A collection can't go inside itself."
        case .emptyName: "A name is required."
        case .folderNotFound: "That folder is no longer connected."
        }
    }
    public var recoverySuggestion: String? {
        switch self {
        case .newerLibrary: "Update Folio to open it. Your library hasn't been changed."
        case .collectionNotFound: "It may have been deleted. Choose another collection."
        case .smartCollection: "Change the collection's rules, or add the items to a regular collection."
        case .invalidMove: "Choose a different place for it."
        case .emptyName: "Type a name, then try again."
        case .folderNotFound: "Connect the folder again."
        }
    }
}

enum SQLValue { case text(String), int(Int64), real(Double), blob(Data), null }

/// All SQLite access is confined to one serial queue. Every public method may be called from any thread.
public final class LibraryDatabase: @unchecked Sendable {
    public static let schemaVersion = 4
    /// Automatic snapshots kept; snapshots taken before a migration are never pruned.
    public static let keptSnapshots = 7
    public static let trashDays = 30.0
    var db: OpaquePointer?
    let queue = DispatchQueue(label:"org.lumashelf.database", qos:.userInitiated)
    private let onQueue = DispatchSpecificKey<Bool>()
    let transient = unsafeBitCast(-1, to:sqlite3_destructor_type.self)
    var depth = 0
    var collectionCache: [ShelfCollection]?
    var backfillCursor: Int64 = 0
    public let root: URL
    public var snapshotsFolder: URL { root.appendingPathComponent("snapshots",isDirectory:true) }
    /// Files in here belong to the library and are deleted with their items.
    public var mediaFolder: URL { root.appendingPathComponent("media",isDirectory:true) }

    public init(root: URL) throws {
        self.root = root
        queue.setSpecific(key:onQueue,value:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let result = sqlite3_open_v2(root.appendingPathComponent("index.sqlite").path,&db,
                                     SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil)
        guard result == SQLITE_OK, let handle = db else {
            let failure = DatabaseError("Cannot open library database",code:result); sqlite3_close(db); db = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(handle,5000)
            // Read before anything that could write, so a newer library is left untouched.
            let version = try integer("PRAGMA user_version")
            if version > Self.schemaVersion { throw LibraryError.newerLibrary(version:version) }
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
            Self.register(handle)
            if try integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='items'") == 0 {
                try transaction {
                    try execute(Self.itemsTable("items") + Self.schema)
                    try seedSmartCollections()
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                }
            } else if version < Self.schemaVersion {
                try snapshot(suffix:"v\(max(1,version))")
                try migrate(from:version)
            } else {
                try execute(Self.schema)
            }
            // 1.6 shortened a built-in smart folder's name; rename it in libraries made earlier.
            try execute("UPDATE collections SET name='Graphics' WHERE kind='smart' AND name='Illustrations & Graphics'")
        } catch { sqlite3_close(db); db = nil; throw error }
        _ = try? purgeTrash()
    }
    deinit { sqlite3_close(db) }

    // MARK: Schema

    // OCR stays the last column so listings that skip it never walk its overflow pages.
    static func itemsTable(_ name: String) -> String { """
        CREATE TABLE IF NOT EXISTS \(name)(
          id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
          added REAL NOT NULL, file_date REAL NOT NULL DEFAULT 0, file_size INTEGER NOT NULL DEFAULT 0,
          width REAL NOT NULL DEFAULT 0, height REAL NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0,
          liked INTEGER NOT NULL DEFAULT 0, trashed REAL, missing INTEGER NOT NULL DEFAULT 0, position REAL NOT NULL DEFAULT 0,
          folder TEXT REFERENCES connected_folders(id) ON DELETE SET NULL,
          source TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', site TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '',
          colors TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', auto_tags TEXT NOT NULL DEFAULT '',
          rejected_tags TEXT NOT NULL DEFAULT '', collection_names TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
          seen TEXT,
          has_text INTEGER GENERATED ALWAYS AS (ocr <> '') STORED,
          ocr TEXT NOT NULL DEFAULT '');
        """ }
    /// `seen`: NULL until the picture is described, '' when it can't be.
    static let searchColumns = "title,tags,auto_tags,collection_names,note,ocr,source,url,site,author,seen"
    static var schema: String {
        let new = searchColumns.split(separator:",").map { "new.\($0)" }.joined(separator:","),
            old = searchColumns.split(separator:",").map { "old.\($0)" }.joined(separator:",")
        return """
        CREATE INDEX IF NOT EXISTS items_added ON items(added);
        CREATE INDEX IF NOT EXISTS items_trashed ON items(trashed) WHERE trashed IS NOT NULL;
        CREATE INDEX IF NOT EXISTS items_folder ON items(folder) WHERE folder IS NOT NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(\(searchColumns),
          content='items', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2', prefix='2 3');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO search(rowid,\(searchColumns)) VALUES(new.rowid,\(new)); END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO search(search,rowid,\(searchColumns)) VALUES('delete',old.rowid,\(old)); END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF \(searchColumns) ON items BEGIN
          INSERT INTO search(search,rowid,\(searchColumns)) VALUES('delete',old.rowid,\(old));
          INSERT INTO search(rowid,\(searchColumns)) VALUES(new.rowid,\(new)); END;
        CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY, name TEXT NOT NULL,
          parent TEXT REFERENCES collections(id) ON DELETE CASCADE,
          kind TEXT NOT NULL DEFAULT 'collection' CHECK(kind IN ('collection','smart')), rules TEXT NOT NULL DEFAULT '',
          position REAL NOT NULL DEFAULT 0, created REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS collections_parent ON collections(parent, position);
        CREATE TABLE IF NOT EXISTS item_collections(item TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          collection TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          position REAL NOT NULL DEFAULT 0, added REAL NOT NULL, PRIMARY KEY(item, collection)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS item_collections_collection ON item_collections(collection, position);
        CREATE TABLE IF NOT EXISTS connected_folders(id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL,
          collection TEXT REFERENCES collections(id) ON DELETE SET NULL, added REAL NOT NULL, last_scan REAL);
        CREATE TABLE IF NOT EXISTS analysis(id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
          signature TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS feature_prints(id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
          version INTEGER NOT NULL, data BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS board_items(collection TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          item TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL,
          z REAL NOT NULL DEFAULT 0, PRIMARY KEY(collection,item));
        CREATE TABLE IF NOT EXISTS board_spaces(board TEXT NOT NULL,
          item TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL,
          z REAL NOT NULL DEFAULT 0, PRIMARY KEY(board,item));
        """
    }

    // MARK: Migration

    /// Each step runs inside one transaction with foreign keys off, as SQLite's table-rebuild procedure requires.
    private func migrate(from version: Int) throws {
        try sync {
            try execute("PRAGMA foreign_keys=OFF")
            defer { try? execute("PRAGMA foreign_keys=ON") }
            try transaction {
                let columns = try self.columns("items")
                if !columns.contains("width") { try execute("ALTER TABLE items ADD COLUMN width REAL NOT NULL DEFAULT 0") }
                if !columns.contains("height") { try execute("ALTER TABLE items ADD COLUMN height REAL NOT NULL DEFAULT 0") }
                if version < 3 { try migrateToV3() }
                if version < 4 { try migrateToV4() }
                try execute("PRAGMA user_version=\(Self.schemaVersion)")
                // Older files may hold analysis for items deleted while foreign keys were off; drop it rather than refuse to open.
                try execute("DELETE FROM analysis WHERE id NOT IN (SELECT id FROM items)")
                if try integer("SELECT count(*) FROM pragma_foreign_key_check") > 0 {
                    throw DatabaseError("Some items point at records that no longer exist.",code:SQLITE_CONSTRAINT)
                }
            }
        }
    }
    /// Version 4 describes pictures: a `seen` column, searched with the rest, so the index is rebuilt to include it.
    private func migrateToV4() throws {
        if !(try columns("items")).contains("seen") { try execute("ALTER TABLE items ADD COLUMN seen TEXT") }
        try execute("DROP TRIGGER IF EXISTS items_ai; DROP TRIGGER IF EXISTS items_ad; DROP TRIGGER IF EXISTS items_au; DROP TABLE IF EXISTS search;")
        try execute(Self.schema + "INSERT INTO search(search) VALUES('rebuild');")
    }
    private func migrateToV3() throws {
        try execute("""
        DROP TRIGGER IF EXISTS items_ai; DROP TRIGGER IF EXISTS items_ad; DROP TRIGGER IF EXISTS items_au;
        DROP TABLE IF EXISTS search; DROP INDEX IF EXISTS items_collection; DROP INDEX IF EXISTS items_added;
        """ + Self.itemsTable("items_v3"))
        var machine: [String:ImageAnalysis] = [:]
        if try integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='analysis'") > 0 {
            try rows("SELECT id,payload FROM analysis") { p in
                machine[text(p,0)] = try? JSONDecoder().decode(ImageAnalysis.self,from:Data(text(p,1).utf8))
            }
        }
        var groups: [String:[(id: String, added: Double)]] = [:]
        let write = try statement("""
            INSERT INTO items_v3(rowid,id,path,title,kind,ext,added,file_date,width,height,source,url,site,colors,tags,auto_tags,collection_names,note,ocr)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        defer { sqlite3_finalize(write) }
        try rows("SELECT rowid,id,path,title,source,collection,tags,note,ocr,kind,added,width,height FROM items ORDER BY added,rowid") { p in
            let id = text(p,1), path = text(p,2), source = text(p,4), kind = text(p,9), added = sqlite3_column_double(p,10)
            let words = text(p,6).split(whereSeparator:{ $0.isWhitespace }).map(String.init)
            let suggested = machine[id]?.automaticTags ?? []
            let auto = words.filter { Tags.contains(suggested,$0) }, manual = words.filter { !Tags.contains(suggested,$0) }
            let file = path.hasPrefix("/"), url = kind == "link" ? path : ""
            let group = text(p,5).trimmingCharacters(in:.whitespacesAndNewlines)
            let named = group.isEmpty || group == "Inbox" ? "" : group
            // Version 2 stored a scanned file's creation date as `added`.
            bind([.int(sqlite3_column_int64(p,0)),.text(id),.text(path),.text(text(p,3)),.text(kind),
                  .text(file ? URL(fileURLWithPath:path).pathExtension.lowercased() : ""),.real(added),.real(file ? added : 0),
                  .real(sqlite3_column_double(p,11)),.real(sqlite3_column_double(p,12)),.text(source),.text(url),
                  .text(ShelfItem.site(url.isEmpty ? source : url)),.text(machine[id]?.colors.joined(separator:" ") ?? ""),
                  .text(Tags.encode(Tags.clean(manual))),.text(Tags.encode(Tags.clean(auto))),.text(named),.text(text(p,7)),.text(text(p,8))],to:write)
            try step(write)
            if !named.isEmpty { groups[named,default:[]].append((id,added)) }
        }
        try execute("DROP TABLE items; ALTER TABLE items_v3 RENAME TO items;" + Self.schema)
        let created = Date().timeIntervalSince1970
        for (index,name) in groups.keys.sorted(by:{ $0.localizedStandardCompare($1) == .orderedAscending }).enumerated() {
            let id = UUID().uuidString
            try run("INSERT INTO collections(id,name,kind,position,created) VALUES(?,?,'collection',?,?)",[.text(id),.text(name),.real(Double(index+1)),.real(created)])
            for (position,member) in groups[name]!.enumerated() {
                try run("INSERT INTO item_collections(item,collection,position,added) VALUES(?,?,?,?)",[.text(member.id),.text(id),.real(Double(position+1)),.real(member.added)])
            }
        }
        try execute("INSERT INTO search(search) VALUES('rebuild')")
        collectionCache = nil
        try seedSmartCollections()
    }
    func seedSmartCollections() throws {
        var position = try double("SELECT coalesce(max(position),0) FROM collections WHERE parent IS NULL") + 1
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (name,rules) in SmartRules.autoSort {
            try run("INSERT INTO collections(id,name,kind,rules,position,created) VALUES(?,?,'smart',?,?,?)",
                    [.text(UUID().uuidString),.text(name),.text(String(decoding:try encoder.encode(rules),as:UTF8.self)),.real(position),.real(Date().timeIntervalSince1970)])
            position += 1
        }
        collectionCache = nil
    }

    // MARK: Snapshots

    /// Copies the database to `snapshots/` and keeps the newest automatic copies.
    @discardableResult public func snapshot() throws -> URL {
        let url = try snapshot(suffix:"auto")
        let autos = snapshots().filter { $0.lastPathComponent.hasSuffix("-auto.sqlite") }
        for old in autos.dropFirst(Self.keptSnapshots) { try? FileManager.default.removeItem(at:old) }
        return url
    }
    /// Takes an automatic snapshot when the newest one is older than `interval`. Call at launch.
    @discardableResult public func snapshotIfDue(interval: TimeInterval = 86400) throws -> URL? {
        let newest = snapshots().first { $0.lastPathComponent.hasSuffix("-auto.sqlite") }
        if let newest, let date = (try? newest.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < interval { return nil }
        return try snapshot()
    }
    /// A copy taken right before something that can't be undone (emptying the Trash, an import), named for it.
    @discardableResult public func snapshot(before reason: String) throws -> URL {
        let slug = reason.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into:"") { $0.append($1) }
        let url = try snapshot(suffix:"before-" + slug)
        let befores = snapshots().filter { $0.lastPathComponent.contains("-before-") }
        for old in befores.dropFirst(Self.keptSnapshots) { try? FileManager.default.removeItem(at:old) }
        return url
    }
    /// Puts a snapshot back the next time the library opens: the swap happens before the database is in use.
    public static func scheduleRestore(_ snapshot: URL, root: URL) throws {
        try Data(snapshot.path.utf8).write(to:root.appendingPathComponent("restore-pending"),options:.atomic)
    }
    /// Swaps in a scheduled snapshot. Call before opening the library; returns whether one was restored.
    @discardableResult public static func applyPendingRestore(root: URL) -> Bool {
        let marker = root.appendingPathComponent("restore-pending"), manager = FileManager.default
        guard let path = (try? String(contentsOf:marker,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) else { return false }
        try? manager.removeItem(at:marker)
        let source = URL(fileURLWithPath:path), database = root.appendingPathComponent("index.sqlite")
        guard source.path.hasPrefix(root.appendingPathComponent("snapshots").path + "/"), manager.fileExists(atPath:source.path) else { return false }
        let staged = root.appendingPathComponent("index-restoring.sqlite")
        try? manager.removeItem(at:staged)
        guard (try? manager.copyItem(at:source,to:staged)) != nil else { return false }
        for suffix in ["-wal","-shm"] { try? manager.removeItem(atPath:database.path + suffix) }
        return (try? manager.replaceItemAt(database,withItemAt:staged)) != nil
    }
    /// All snapshots, newest first.
    public func snapshots() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at:snapshotsFolder,includingPropertiesForKeys:nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("index-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    @discardableResult private func snapshot(suffix: String) throws -> URL {
        try FileManager.default.createDirectory(at:snapshotsFolder,withIntermediateDirectories:true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var url = snapshotsFolder.appendingPathComponent("index-\(formatter.string(from:Date()))-\(suffix).sqlite")
        var attempt = 1
        while FileManager.default.fileExists(atPath:url.path) {
            attempt += 1; url = url.deletingLastPathComponent().appendingPathComponent("index-\(formatter.string(from:Date()))-\(attempt)-\(suffix).sqlite")
        }
        try sync { try run("VACUUM INTO ?",[.text(url.path)]) }
        return url
    }

    // MARK: SQLite plumbing

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:onQueue) == true { return try body() }
        return try queue.sync(execute:body)
    }
    /// Nested calls become savepoints, so helpers compose inside one outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            let outer = depth == 0
            try execute(outer ? "BEGIN IMMEDIATE" : "SAVEPOINT nested")
            depth += 1
            defer { depth -= 1 }
            do {
                let result = try body()
                try execute(outer ? "COMMIT" : "RELEASE nested")
                return result
            } catch {
                try? execute(outer ? "ROLLBACK" : "ROLLBACK TO nested; RELEASE nested")
                collectionCache = nil
                throw error
            }
        }
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw error() }
    }
    func error() -> DatabaseError { DatabaseError(String(cString:sqlite3_errmsg(db)),code:sqlite3_extended_errcode(db)) }
    func statement(_ sql: String) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&p,nil) == SQLITE_OK, let p else { throw error() }
        return p
    }
    func bind(_ values: [SQLValue], to p: OpaquePointer) {
        sqlite3_reset(p); sqlite3_clear_bindings(p)
        for (offset,value) in values.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(p,i,s,-1,transient)
            case .int(let n): sqlite3_bind_int64(p,i,n)
            case .real(let d): sqlite3_bind_double(p,i,d)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(p,i,$0.baseAddress,Int32(data.count),transient) }
            case .null: sqlite3_bind_null(p,i)
            }
        }
    }
    func step(_ p: OpaquePointer) throws {
        guard sqlite3_step(p) == SQLITE_DONE else { throw error() }
    }
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let p = try statement(sql); defer { sqlite3_finalize(p) }
        bind(values,to:p); try step(p)
    }
    func rows(_ sql: String, _ values: [SQLValue] = [], _ body: (OpaquePointer) throws -> Void) throws {
        let p = try statement(sql); defer { sqlite3_finalize(p) }
        bind(values,to:p)
        while true {
            let result = sqlite3_step(p)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw error() }
            try body(p)
        }
    }
    func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        var value = 0
        try rows(sql,values) { value = Int(sqlite3_column_int64($0,0)) }
        return value
    }
    func double(_ sql: String, _ values: [SQLValue] = []) throws -> Double {
        var value = 0.0
        try rows(sql,values) { value = sqlite3_column_double($0,0) }
        return value
    }
    func strings(_ sql: String, _ values: [SQLValue] = []) throws -> [String] {
        var out: [String] = []
        try rows(sql,values) { out.append(text($0,0)) }
        return out
    }
    func columns(_ table: String) throws -> Set<String> { Set(try strings("SELECT name FROM pragma_table_info(?)",[.text(table)])) }
    var changes: Int { Int(sqlite3_changes(db)) }
    /// Binds a list as a JSON array; read it with `(SELECT value FROM json_each(?))`.
    static func jsonList(_ values: [String]) -> SQLValue {
        .text(String(decoding:(try? JSONSerialization.data(withJSONObject:values)) ?? Data("[]".utf8),as:UTF8.self))
    }
    func list(_ values: [String]) -> SQLValue { Self.jsonList(values) }
    static let each = "(SELECT value FROM json_each(?))"

    // MARK: Functions

    private static func register(_ db: OpaquePointer) {
        sqlite3_create_collation_v2(db,"natural_name",SQLITE_UTF8,nil,{ _,n1,p1,n2,p2 in
            Natural.compare(UnsafeRawBufferPointer(start:p1,count:Int(n1)),UnsafeRawBufferPointer(start:p2,count:Int(n2)))
        },nil)
        sqlite3_create_function_v2(db,"color_near",2,SQLITE_UTF8 | SQLITE_DETERMINISTIC,nil,{ context,_,values in
            guard let values, let palette = values[0].flatMap(valueText), let target = values[1].flatMap(valueText) else {
                sqlite3_result_int(context,0); return
            }
            sqlite3_result_int(context,ColorMath.matches(palette:palette,target:target) ? 1 : 0)
        },nil,nil,nil)
        sqlite3_create_function_v2(db,"color_rank",2,SQLITE_UTF8 | SQLITE_DETERMINISTIC,nil,{ context,_,values in
            guard let values, let palette = values[0].flatMap(valueText), let target = values[1].flatMap(valueText) else {
                sqlite3_result_double(context,1_000_000); return
            }
            sqlite3_result_double(context,ColorMath.rank(palette:palette,target:target))
        },nil,nil,nil)
        sqlite3_create_function_v2(db,"shuffle",2,SQLITE_UTF8 | SQLITE_DETERMINISTIC,nil,{ context,_,values in
            guard let values else { return }
            var x = UInt64(bitPattern:sqlite3_value_int64(values[0])) &+ UInt64(bitPattern:sqlite3_value_int64(values[1])) &* 0x9E3779B97F4A7C15
            x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9; x = (x ^ (x >> 27)) &* 0x94D049BB133111EB; x ^= x >> 31
            sqlite3_result_int64(context,Int64(bitPattern:x))
        },nil,nil,nil)
    }
}

private func valueText(_ value: OpaquePointer) -> String? {
    guard let bytes = sqlite3_value_text(value) else { return nil }
    return String(decoding:UnsafeBufferPointer(start:bytes,count:Int(sqlite3_value_bytes(value))),as:UTF8.self)
}

func text(_ p: OpaquePointer, _ column: Int32) -> String {
    guard let bytes = sqlite3_column_text(p,column), bytes.pointee != 0 else { return "" }
    return String(cString:bytes)
}
func optionalText(_ p: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_type(p,column) == SQLITE_NULL ? nil : text(p,column)
}
func optionalDouble(_ p: OpaquePointer, _ column: Int32) -> Double? {
    sqlite3_column_type(p,column) == SQLITE_NULL ? nil : sqlite3_column_double(p,column)
}
/// Splits a text column on a single-byte separator without building the whole string first.
func split(_ p: OpaquePointer, _ column: Int32, _ separator: UInt8 = 0x1F) -> [String] {
    guard let bytes = sqlite3_column_text(p,column) else { return [] }
    var start = UnsafeRawPointer(bytes), out: [String] = []
    let end = start + Int(sqlite3_column_bytes(p,column))
    while start < end {
        let hit = memchr(start,Int32(separator),end - start).map { UnsafeRawPointer($0) } ?? end
        if hit > start { out.append(String(decoding:UnsafeRawBufferPointer(start:start,count:hit - start),as:UTF8.self)) }
        start = hit + 1
    }
    return out
}

/// Finder-style ordering: case- and accent-insensitive, digit runs compared by value.
enum Natural {
    /// Compares UTF-8 bytes, folding ASCII case inline. Folding the full strings is only needed once a
    /// non-ASCII byte is reached before the order is decided, and gives the same answer on ASCII prefixes.
    static func compare(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, folded: Bool = false) -> Int32 {
        func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            var x = a[i], y = b[j]
            if !folded, x >= 0x80 || y >= 0x80 {
                let fa = Array(fold(a).utf8), fb = Array(fold(b).utf8)
                return fa.withUnsafeBytes { ra in fb.withUnsafeBytes { rb in compare(ra,rb,folded:true) } }
            }
            if digit(x), digit(y) {
                var si = i, sj = j
                while si < a.count, a[si] == 48 { si += 1 }
                while sj < b.count, b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < a.count, digit(a[ei]) { ei += 1 }
                while ej < b.count, digit(b[ej]) { ej += 1 }
                if ei - si != ej - sj { return ei - si < ej - sj ? -1 : 1 }
                var k = 0
                while k < ei - si { if a[si+k] != b[sj+k] { return a[si+k] < b[sj+k] ? -1 : 1 }; k += 1 }
                i = ei; j = ej; continue
            }
            if x >= 65 && x <= 90 { x += 32 }
            if y >= 65 && y <= 90 { y += 32 }
            if x != y { return x < y ? -1 : 1 }
            i += 1; j += 1
        }
        let restA = a.count - i, restB = b.count - j
        return restA == restB ? 0 : restA < restB ? -1 : 1
    }
    static func fold(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding:bytes,as:UTF8.self).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
    }
}
