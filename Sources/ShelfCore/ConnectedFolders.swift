import Foundation
import CSQLite

/// Folders the library mirrors. Files stay where they are; scans keep the library in step with the disk.
extension LibraryDatabase {
    public func connectedFolders() throws -> [ConnectedFolder] {
        try sync {
            var out: [ConnectedFolder] = []
            try rows("SELECT id,path,collection,added,last_scan FROM connected_folders ORDER BY added") { p in
                out.append(ConnectedFolder(id:text(p,0),path:text(p,1),collection:optionalText(p,2),added:sqlite3_column_double(p,3),lastScan:optionalDouble(p,4)))
            }
            return out
        }
    }
    /// The directories directly inside `dir` (a connected folder or a directory in one) that hold items, at any
    /// depth, with how many each holds. In name order, as the Finder lists them.
    public func subfolders(of folder: String, in dir: String) throws -> [(path: String, count: Int)] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var counts: [String:Int] = [:]
        try sync {
            try rows("SELECT path FROM items WHERE folder=? AND trashed IS NULL AND substr(path,1,?)=?",
                     [.text(folder),.int(Int64(prefix.utf8.count)),.text(prefix)]) { p in
                let rest = text(p,0).dropFirst(prefix.count)
                guard let slash = rest.firstIndex(of:"/") else { return }
                counts[prefix + rest[..<slash],default:0] += 1
            }
        }
        return counts.map { ($0.key,$0.value) }.sorted { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
    }
    /// Connects a folder, filing its items into `collection` when given. Connecting the same folder twice returns the first.
    @discardableResult public func addConnectedFolder(path: String, collection: String? = nil) throws -> ConnectedFolder {
        let standardized = URL(fileURLWithPath:path).standardizedFileURL.path
        return try transaction {
            if let existing = try connectedFolders().first(where:{ $0.path == standardized }) { return existing }
            if let collection { try requireRegular(collection) }
            let folder = ConnectedFolder(id:UUID().uuidString,path:standardized,collection:collection,added:Date().timeIntervalSince1970,lastScan:nil)
            try run("INSERT INTO connected_folders(id,path,collection,added) VALUES(?,?,?,?)",
                    [.text(folder.id),.text(folder.path),collection.map { .text($0) } ?? .null,.real(folder.added)])
            return folder
        }
    }
    /// Disconnects a folder. Its items stay as ordinary items unless `keepItems` is false.
    public func removeConnectedFolder(_ id: String, keepItems: Bool = true) throws {
        try transaction {
            if !keepItems { try run("DELETE FROM items WHERE folder=?",[.text(id)]) }
            try run("DELETE FROM connected_folders WHERE id=?",[.text(id)])
        }
    }
    /// Applies a fresh scan of a connected folder (for example `MediaFiles.scan([folderURL])`).
    /// New files are added, changed ones updated, renamed or moved ones keep their metadata, and vanished ones go to the
    /// trash marked missing, so tags and notes survive a mistake. While the folder itself can't be reached (an unplugged
    /// drive), nothing is trashed; vanished items are only marked missing.
    @discardableResult public func applyScan(folderID: String, found: [ShelfItem]) throws -> ScanChanges {
        struct Known { var id: String; var path: String; var size: Int64; var date: Double; var width: Double; var height: Double; var missing: Bool; var trashed: Bool }
        return try transaction {
            guard let folder = try connectedFolders().first(where:{ $0.id == folderID }) else { throw LibraryError.folderNotFound }
            var known: [String:Known] = [:], changes = ScanChanges(), fresh: [ShelfItem] = [], seen = Set<String>()
            try rows("SELECT id,path,file_size,file_date,width,height,missing,trashed IS NOT NULL FROM items WHERE folder=?",[.text(folderID)]) { p in
                known[text(p,1)] = Known(id:text(p,0),path:text(p,1),size:sqlite3_column_int64(p,2),date:sqlite3_column_double(p,3),
                                         width:sqlite3_column_double(p,4),height:sqlite3_column_double(p,5),missing:sqlite3_column_int(p,6) != 0,
                                         trashed:sqlite3_column_int(p,7) != 0)
            }
            var isFolder: ObjCBool = false
            let online = FileManager.default.fileExists(atPath:folder.path,isDirectory:&isFolder) && isFolder.boolValue
            // A file that comes back after a scan trashed it as missing comes back out of the trash.
            let update = try statement("""
                UPDATE items SET file_size=?,file_date=?,width=?,height=?,trashed=CASE WHEN missing=1 THEN NULL ELSE trashed END,missing=0,folder=? WHERE id=?
                """)
            defer { sqlite3_finalize(update) }
            func refresh(_ id: String, _ item: ShelfItem) throws {
                bind([.int(item.fileSize),.real(item.fileDate),.real(item.width),.real(item.height),.text(folderID),.text(id)],to:update)
                try step(update); changes.updated.append(id)
            }
            for item in found where seen.insert(item.path).inserted {
                if let old = known[item.path] {
                    if old.size != item.fileSize || old.date != item.fileDate || old.width != item.width || old.height != item.height || old.missing {
                        try refresh(old.id,item)
                    }
                } else if let other = try strings("SELECT id FROM items WHERE path=?",[.text(item.path)]).first {
                    try refresh(other,item)
                } else { fresh.append(item) }
            }
            var vanished = known.values.filter { !seen.contains($0.path) && !($0.trashed && $0.missing) }.sorted { $0.path < $1.path }
            var added: [ShelfItem] = []
            for item in fresh {
                if item.fileSize > 0, item.fileDate != 0,
                   let match = vanished.firstIndex(where:{ $0.size == item.fileSize && $0.date == item.fileDate }) {
                    let old = vanished.remove(at:match)
                    let oldName = URL(fileURLWithPath:old.path).deletingPathExtension().lastPathComponent
                    try run("UPDATE items SET path=?,ext=?,title=CASE WHEN title=? THEN ? ELSE title END,missing=0 WHERE id=?",
                            [.text(item.path),.text(item.ext),.text(oldName),.text(item.title),.text(old.id)])
                    changes.moved.append(old.id)
                } else { var copy = item; copy.folder = folderID; added.append(copy) }
            }
            if !added.isEmpty { changes.added = try insert(added,into:folder.collection) }
            if !online { vanished.removeAll { $0.missing } }
            if !vanished.isEmpty {
                changes.removed = vanished.map(\.id)
                try run("UPDATE items SET missing=1,trashed=CASE WHEN ? THEN coalesce(trashed,?) ELSE trashed END WHERE id IN \(Self.each)",
                        [.int(online ? 1 : 0),.real(Date().timeIntervalSince1970),list(changes.removed)])
            }
            try run("UPDATE connected_folders SET last_scan=? WHERE id=?",[.real(Date().timeIntervalSince1970),.text(folderID)])
            return changes
        }
    }
}
