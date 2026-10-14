import Foundation
import CSQLite

extension LibraryDatabase {
    // MARK: Adding

    /// Adds items, skipping ones already in the library (those come back out of the trash).
    /// Returns the library id for each input, in order. `into` and each item's `collections` add memberships.
    @discardableResult public func insert(_ items: [ShelfItem], into collection: String? = nil) throws -> [String] {
        try transaction {
            if let collection { try requireRegular(collection) }
            var position = try double("SELECT coalesce(max(position),0) FROM items")
            let insert = try statement("""
                INSERT INTO items(id,path,title,kind,ext,added,file_date,file_size,width,height,duration,liked,trashed,missing,position,
                  folder,source,url,site,author,colors,tags,auto_tags,note,ocr)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING
                """)
            defer { sqlite3_finalize(insert) }
            var ids: [String] = [], extra: [(String,String)] = []
            for var item in items {
                position += 1
                // A renamed file keeps the id derived from its old path, so a new file at that old path needs a fresh id.
                if item.id == ShelfItem.digest(item.path),
                   try strings("SELECT path FROM items WHERE id=?",[.text(item.id)]).first.map({ $0 != item.path }) == true,
                   try integer("SELECT count(*) FROM items WHERE path=?",[.text(item.path)]) == 0 {
                    item.id = ShelfItem.digest(item.path + "|" + UUID().uuidString)
                }
                bind([.text(item.id),.text(item.path),.text(item.title),.text(item.kind),.text(item.ext),.real(item.added),.real(item.fileDate),
                      .int(item.fileSize),.real(item.width),.real(item.height),.real(item.duration),.int(item.liked ? 1 : 0),
                      item.trashed.map { .real($0) } ?? .null,.int(item.missing ? 1 : 0),.real(position),item.folder.map { .text($0) } ?? .null,
                      .text(item.source),.text(item.url),.text(item.site),.text(item.author),.text(item.colors.joined(separator:" ")),
                      .text(Tags.encode(Tags.clean(item.tags))),.text(Tags.encode(Tags.clean(item.autoTags))),.text(item.note),.text(item.ocr)],to:insert)
                try step(insert)
                var id = item.id
                if changes == 0 {
                    id = try strings("SELECT id FROM items WHERE path=? UNION ALL SELECT id FROM items WHERE id=? LIMIT 1",[.text(item.path),.text(item.id)]).first ?? item.id
                    try run("UPDATE items SET trashed=NULL WHERE id=? AND trashed IS NOT NULL",[.text(id)])
                }
                ids.append(id)
                for c in item.collections { extra.append((id,c)) }
            }
            if let collection { try addMembers(ids,to:collection) }
            let regular = Set(try loadCollections().filter { !$0.isSmart }.map(\.id))
            for (c,members) in Dictionary(grouping:extra.filter { regular.contains($0.1) },by:\.1) { try addMembers(members.map(\.0),to:c) }
            return ids
        }
    }

    // MARK: Undo

    func states(_ ids: [String]) throws -> [ItemState] {
        var byID: [String:ItemState] = [:]
        try rows("SELECT id,title,note,author,tags,auto_tags,rejected_tags,liked,trashed,position,source FROM items WHERE id IN \(Self.each)",[list(ids)]) { p in
            byID[text(p,0)] = ItemState(id:text(p,0),title:text(p,1),note:text(p,2),author:text(p,3),tags:split(p,4),autoTags:split(p,5),
                                        rejectedTags:split(p,6),liked:sqlite3_column_int(p,7) != 0,trashed:optionalDouble(p,8),
                                        position:sqlite3_column_double(p,9),memberships:[],source:text(p,10))
        }
        try rows("SELECT item,collection,position,added FROM item_collections WHERE item IN \(Self.each) ORDER BY collection",[list(ids)]) { p in
            byID[text(p,0)]?.memberships.append(Membership(item:text(p,0),collection:text(p,1),position:sqlite3_column_double(p,2),added:sqlite3_column_double(p,3)))
        }
        var seen = Set<String>()
        return ids.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }
    func mutate(_ ids: [String], _ body: () throws -> Void) throws -> [ItemState] {
        try transaction { let before = try states(ids); try body(); return before }
    }
    /// The editable state of items, to hand back to `restore(_:)` for undo.
    public func snapshot(ids: [String]) throws -> [ItemState] { try sync { try states(ids) } }
    /// Puts items back to an earlier state and returns the state it replaced, for redo. Deleted items are skipped.
    @discardableResult public func restore(_ states: [ItemState]) throws -> [ItemState] {
        try transaction {
            let current = try self.states(states.map(\.id))
            let update = try statement("UPDATE items SET title=?,note=?,author=?,tags=?,auto_tags=?,rejected_tags=?,liked=?,trashed=?,position=?,source=?,site=CASE WHEN url='' THEN ? ELSE site END WHERE id=?")
            defer { sqlite3_finalize(update) }
            let insert = try statement("""
                INSERT OR IGNORE INTO item_collections(item,collection,position,added)
                SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM collections WHERE id=? AND kind='collection')
                """)
            defer { sqlite3_finalize(insert) }
            for s in states {
                bind([.text(s.title),.text(s.note),.text(s.author),.text(Tags.encode(s.tags)),.text(Tags.encode(s.autoTags)),.text(Tags.encode(s.rejectedTags)),
                      .int(s.liked ? 1 : 0),s.trashed.map { .real($0) } ?? .null,.real(s.position),.text(s.source),.text(ShelfItem.site(s.source)),.text(s.id)],to:update)
                try step(update)
                guard changes > 0 else { continue }
                try run("DELETE FROM item_collections WHERE item=?",[.text(s.id)])
                for m in s.memberships {
                    bind([.text(s.id),.text(m.collection),.real(m.position),.real(m.added),.text(m.collection)],to:insert); try step(insert)
                }
            }
            try refreshNames(items:states.map(\.id))
            return current
        }
    }

    // MARK: Trash

    @discardableResult public func moveToTrash(_ ids: [String]) throws -> [ItemState] {
        try mutate(ids) { try run("UPDATE items SET trashed=? WHERE trashed IS NULL AND id IN \(Self.each)",[.real(Date().timeIntervalSince1970),list(ids)]) }
    }
    @discardableResult public func putBack(_ ids: [String]) throws -> [ItemState] {
        try mutate(ids) { try run("UPDATE items SET trashed=NULL WHERE id IN \(Self.each)",[list(ids)]) }
    }
    /// Removes items for good, with the files the library owns under `mediaFolder`. Returns the files deleted.
    /// Originals elsewhere on disk are never touched. This can't be undone.
    @discardableResult public func deletePermanently(_ ids: [String]) throws -> [String] {
        let paths: [String] = try transaction {
            let paths = try strings("SELECT path FROM items WHERE id IN \(Self.each)",[list(ids)])
            try run("DELETE FROM items WHERE id IN \(Self.each)",[list(ids)])
            return paths
        }
        let media = mediaFolder.resolvingSymlinksInPath().path + "/"
        return paths.filter { path in
            path.hasPrefix("/") && URL(fileURLWithPath:path).resolvingSymlinksInPath().path.hasPrefix(media)
                && (try? FileManager.default.removeItem(atPath:path)) != nil
        }
    }
    @discardableResult public func emptyTrash() throws -> [String] {
        try deletePermanently(try sync { try strings("SELECT id FROM items WHERE trashed IS NOT NULL") })
    }
    /// Deletes items that have been in the trash longer than `days`. Runs when the library opens.
    @discardableResult public func purgeTrash(olderThan days: Double = trashDays) throws -> [String] {
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        return try deletePermanently(try sync { try strings("SELECT id FROM items WHERE trashed<?",[.real(cutoff)]) })
    }

    // MARK: Metadata

    @discardableResult public func setLiked(_ ids: [String], _ liked: Bool) throws -> [ItemState] {
        try mutate(ids) { try run("UPDATE items SET liked=? WHERE id IN \(Self.each)",[.int(liked ? 1 : 0),list(ids)]) }
    }
    @discardableResult public func setNote(_ note: String, for ids: [String]) throws -> [ItemState] {
        try mutate(ids) { try run("UPDATE items SET note=? WHERE id IN \(Self.each)",[.text(note),list(ids)]) }
    }
    @discardableResult public func setTitle(_ title: String, for ids: [String]) throws -> [ItemState] {
        let trimmed = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        return try mutate(ids) { try run("UPDATE items SET title=? WHERE id IN \(Self.each)",[.text(trimmed),list(ids)]) }
    }
    @discardableResult public func setAuthor(_ author: String, for ids: [String]) throws -> [ItemState] {
        try mutate(ids) { try run("UPDATE items SET author=? WHERE id IN \(Self.each)",[.text(author.trimmingCharacters(in:.whitespacesAndNewlines)),list(ids)]) }
    }
    /// Where items came from: a web address, or empty to clear it.
    @discardableResult public func setSource(_ source: String, for ids: [String]) throws -> [ItemState] {
        let value = source.trimmingCharacters(in:.whitespacesAndNewlines)
        return try mutate(ids) { try run("UPDATE items SET source=?,site=CASE WHEN url='' THEN ? ELSE site END WHERE id IN \(Self.each)",[.text(value),.text(ShelfItem.site(value)),list(ids)]) }
    }
    public func setMissing(_ ids: [String], _ missing: Bool) throws {
        try sync { try run("UPDATE items SET missing=? WHERE id IN \(Self.each)",[.int(missing ? 1 : 0),list(ids)]) }
    }
    public func updateOCR(id: String, text: String) throws {
        try sync { try run("UPDATE items SET ocr=? WHERE id=?",[.text(text),.text(id)]) }
    }

    // MARK: Tags

    private func editTags(_ ids: [String], _ edit: (inout [String], inout [String], inout [String]) -> Void) throws {
        var found: [(String,[String],[String],[String])] = []
        try rows("SELECT id,tags,auto_tags,rejected_tags FROM items WHERE id IN \(Self.each)",[list(ids)]) { found.append((text($0,0),split($0,1),split($0,2),split($0,3))) }
        let update = try statement("UPDATE items SET tags=?,auto_tags=?,rejected_tags=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        for (id,oldTags,oldAuto,oldRejected) in found {
            var tags = oldTags, auto = oldAuto, rejected = oldRejected
            edit(&tags,&auto,&rejected)
            tags = Tags.clean(tags); auto = Tags.clean(auto); rejected = Tags.clean(rejected)
            guard tags != oldTags || auto != oldAuto || rejected != oldRejected else { continue }
            bind([.text(Tags.encode(tags)),.text(Tags.encode(auto)),.text(Tags.encode(rejected)),.text(id)],to:update); try step(update)
        }
    }
    @discardableResult public func addTags(_ tags: [String], to ids: [String]) throws -> [ItemState] {
        let new = Tags.clean(tags)
        return try mutate(ids) { try editTags(ids) { manual,_,rejected in manual += new; rejected.removeAll { Tags.contains(new,$0) } } }
    }
    /// Removes tags. Machine tags removed this way are remembered so analysis never adds them back.
    @discardableResult public func removeTags(_ tags: [String], from ids: [String]) throws -> [ItemState] {
        try mutate(ids) {
            try editTags(ids) { manual,auto,rejected in
                manual.removeAll { Tags.contains(tags,$0) }
                rejected += auto.filter { Tags.contains(tags,$0) }
                auto.removeAll { Tags.contains(tags,$0) }
            }
        }
    }
    /// Replaces the tags the user added.
    @discardableResult public func setTags(_ tags: [String], for ids: [String]) throws -> [ItemState] {
        let new = Tags.clean(tags)
        return try mutate(ids) { try editTags(ids) { manual,_,rejected in manual = new; rejected.removeAll { Tags.contains(new,$0) } } }
    }
    /// Renames a tag on every item, merging with `name` where both exist.
    @discardableResult public func renameTag(_ old: String, to name: String) throws -> [ItemState] {
        guard let new = Tags.clean([name]).first else { throw LibraryError.emptyName }
        return try transaction {
            let ids = try strings("SELECT id FROM items WHERE instr(lower(tags),?)>0",[.text(Tags.key(old))])
            let before = try states(ids)
            try editTags(ids) { tags,_,_ in tags = tags.map { Tags.key($0) == Tags.key(old) ? new : $0 } }
            return before
        }
    }
    @discardableResult public func deleteTag(_ tag: String) throws -> [ItemState] {
        try transaction {
            let ids = try strings("SELECT id FROM items WHERE instr(lower(tags),?)>0",[.text(Tags.key(tag))])
            let before = try states(ids)
            try editTags(ids) { tags,_,_ in tags.removeAll { Tags.key($0) == Tags.key(tag) } }
            return before
        }
    }

    // MARK: Analysis

    public func analysisSignatures() throws -> [String:String] {
        try sync {
            var result: [String:String] = [:]
            try rows("SELECT id,signature FROM analysis") { result[text($0,0)] = text($0,1) }
            return result
        }
    }
    public func analysis(id: String) throws -> ImageAnalysis? {
        try sync {
            var payload: String?
            try rows("SELECT payload FROM analysis WHERE id=?",[.text(id)]) { payload = text($0,0) }
            return payload.flatMap { try? JSONDecoder().decode(ImageAnalysis.self,from:Data($0.utf8)) }
        }
    }
    /// Stores analysis: machine tags (minus ones the user removed), palette, recognized text and size.
    public func saveAnalysis(id: String, signature: String, value: ImageAnalysis, dimensions: CGSize, applyTags: Bool) throws {
        let payload = String(decoding:try JSONEncoder().encode(value),as:UTF8.self)
        try transaction {
            var current: (auto: [String],rejected: [String])?
            try rows("SELECT auto_tags,rejected_tags FROM items WHERE id=?",[.text(id)]) { current = (split($0,0),split($0,1)) }
            guard let current else { return }
            try run("INSERT OR REPLACE INTO analysis(id,signature,payload) VALUES(?,?,?)",[.text(id),.text(signature),.text(payload)])
            let auto = applyTags ? Tags.clean(value.automaticTags.filter { !Tags.contains(current.rejected,$0) }) : current.auto
            try run("""
                UPDATE items SET auto_tags=?,colors=?,ocr=CASE WHEN ?='' THEN ocr ELSE ? END,
                  width=CASE WHEN ?>0 THEN ? ELSE width END,height=CASE WHEN ?>0 THEN ? ELSE height END WHERE id=?
                """,[.text(Tags.encode(auto)),.text(value.colors.joined(separator:" ")),.text(value.text),.text(value.text),
                     .real(dimensions.width),.real(dimensions.width),.real(dimensions.height),.real(dimensions.height),.text(id)])
        }
    }
    /// Stores an image feature print for visual similarity. One per item; a new version replaces the old.
    public func saveFeaturePrint(id: String, version: Int, data: Data) throws {
        try sync {
            try run("INSERT OR REPLACE INTO feature_prints(id,version,data) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM items WHERE id=?)",
                    [.text(id),.int(Int64(version)),.blob(data),.text(id)])
        }
    }
    /// Feature prints of the given version for items outside the trash.
    public func featurePrints(version: Int) throws -> [(id: String, data: Data)] {
        try sync {
            var out: [(id: String, data: Data)] = []
            try rows("SELECT f.id,f.data FROM feature_prints f JOIN items i ON i.id=f.id WHERE f.version=? AND i.trashed IS NULL",[.int(Int64(version))]) { p in
                let count = Int(sqlite3_column_bytes(p,1))
                out.append((text(p,0),count == 0 ? Data() : Data(bytes:sqlite3_column_blob(p,1),count:count)))
            }
            return out
        }
    }

    /// Sets a link's preview picture (a local file), its title when it had none, and its size.
    public func setLinkPreview(id: String, path: String, title: String?, size: CGSize) throws {
        try sync {
            try run("""
                UPDATE items SET path=?,width=?,height=?,title=CASE WHEN ? IS NOT NULL AND (title='' OR title=site OR title=url) THEN ? ELSE title END
                WHERE id=? AND kind='link'
                """,[.text(path),.real(size.width),.real(size.height),title.map { .text($0) } ?? .null,title.map { .text($0) } ?? .null,.text(id)])
        }
    }
    /// Pictures (and videos' and links' previews) the Mac hasn't described yet, newest first.
    public func itemsToDescribe(limit: Int = 20) throws -> [(id: String, path: String, kind: String)] {
        try sync {
            var out: [(id: String, path: String, kind: String)] = []
            try rows("""
                SELECT id,path,kind FROM items WHERE seen IS NULL AND kind IN ('image','gif','video','link') AND path LIKE '/%'
                AND trashed IS NULL AND missing=0 ORDER BY added DESC LIMIT ?
                """,[.int(Int64(limit))]) { p in out.append((text(p,0),text(p,1),text(p,2))) }
            return out
        }
    }
    /// Keeps what the Mac saw in a picture; an empty string marks one it couldn't describe, so it isn't tried again.
    public func setSeen(_ text: String, id: String) throws {
        try sync { try run("UPDATE items SET seen=? WHERE id=?",[.text(text),.text(id)]) }
    }
    /// Images outside the trash that have no feature print of this version yet.
    public func itemsMissingFeaturePrint(version: Int, limit: Int = 200) throws -> [(id: String, path: String)] {
        try sync {
            var out: [(id: String, path: String)] = []
            try rows("""
                SELECT i.id,i.path FROM items i WHERE i.kind IN ('image','video','gif','link') AND i.path LIKE '/%' AND i.trashed IS NULL AND i.missing=0
                AND NOT EXISTS(SELECT 1 FROM feature_prints f WHERE f.id=i.id AND f.version=?) LIMIT ?
                """,[.int(Int64(version)),.int(Int64(limit))]) { p in out.append((text(p,0),text(p,1))) }
            return out
        }
    }

    // MARK: Files

    /// Points items stored under one folder at another, after the library folder itself moved. Returns how many changed.
    @discardableResult public func rebasePaths(from old: String, to new: String) throws -> Int {
        let from = old.hasSuffix("/") ? old : old + "/", to = new.hasSuffix("/") ? new : new + "/"
        return try transaction {
            let ids = try strings("SELECT id FROM items WHERE substr(path,1,?)=?",[.int(Int64(from.count)),.text(from)])
            try run("UPDATE items SET path=?||substr(path,?) WHERE substr(path,1,?)=?",[.text(to),.int(Int64(from.count + 1)),.int(Int64(from.count)),.text(from)])
            return ids.count
        }
    }
    /// Fills in file size and date, and flags missing files, a batch at a time.
    /// Returns how many items it checked; 0 once it has been through the whole library.
    @discardableResult public func backfillFileInfo(limit: Int = 500) throws -> Int {
        let batch: [(rowid: Int64, id: String, path: String)] = try sync {
            var out: [(Int64,String,String)] = []
            try rows("SELECT rowid,id,path FROM items WHERE rowid>? AND file_size=0 AND missing=0 AND substr(path,1,1)='/' ORDER BY rowid LIMIT ?",
                     [.int(backfillCursor),.int(Int64(max(1,limit)))]) { out.append((sqlite3_column_int64($0,0),text($0,1),text($0,2))) }
            return out
        }
        guard let last = batch.last else { return 0 }
        let found = batch.map { entry -> (String,URLResourceValues?) in
            (entry.id,try? URL(fileURLWithPath:entry.path).resourceValues(forKeys:[.fileSizeKey,.creationDateKey,.contentModificationDateKey,.isRegularFileKey]))
        }
        try transaction {
            let update = try statement("UPDATE items SET file_size=?,file_date=CASE WHEN file_date=0 THEN ? ELSE file_date END,missing=? WHERE id=?")
            defer { sqlite3_finalize(update) }
            for (id,values) in found {
                let exists = values?.isRegularFile == true
                bind([.int(Int64(values?.fileSize ?? 0)),.real((values?.creationDate ?? values?.contentModificationDate)?.timeIntervalSince1970 ?? 0),
                      .int(exists ? 0 : 1),.text(id)],to:update)
                try step(update)
            }
            backfillCursor = last.rowid
        }
        return batch.count
    }

    // MARK: Export

    /// Writes items (with recognized text), collections, memberships, tags and connected folders as JSON.
    public func exportJSON(to url: URL) throws {
        struct Tag: Encodable { var name: String; var count: Int }
        struct Export: Encodable {
            var format = "folio-library", version: Int, exported: Double
            var items: [ShelfItem], collections: [ShelfCollection], memberships: [Membership], tags: [Tag], connectedFolders: [ConnectedFolder]
        }
        let export: Export = try sync {
            var items: [ShelfItem] = [], memberships: [Membership] = []
            try rows("SELECT \(Self.listColumns),i.ocr FROM items i ORDER BY i.added,i.rowid") { items.append(ShelfItem(row:$0,full:true)) }
            try rows("SELECT item,collection,position,added FROM item_collections ORDER BY collection,position") { p in
                memberships.append(Membership(item:text(p,0),collection:text(p,1),position:sqlite3_column_double(p,2),added:sqlite3_column_double(p,3)))
            }
            return Export(version:Self.schemaVersion,exported:Date().timeIntervalSince1970,items:items,collections:try loadCollections(),
                          memberships:memberships,tags:try allTags().map { Tag(name:$0.name,count:$0.count) },connectedFolders:try connectedFolders())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(export).write(to:url,options:.atomic)
    }
}
