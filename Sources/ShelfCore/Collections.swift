import Foundation
import CSQLite

extension LibraryDatabase {
    func loadCollections() throws -> [ShelfCollection] {
        if let collectionCache { return collectionCache }
        var out: [ShelfCollection] = []
        try rows("SELECT id,name,parent,kind,rules,position,created,archived FROM collections ORDER BY position,name") { p in
            let rules = text(p,4)
            out.append(ShelfCollection(id:text(p,0),name:text(p,1),parent:optionalText(p,2),kind:ShelfCollection.Kind(rawValue:text(p,3)) ?? .collection,
                                       rules:rules.isEmpty ? nil : try? JSONDecoder().decode(SmartRules.self,from:Data(rules.utf8)),
                                       position:sqlite3_column_double(p,5),created:sqlite3_column_double(p,6),archived:sqlite3_column_int(p,7) != 0))
        }
        collectionCache = out
        return out
    }
    func requireRegular(_ id: String) throws {
        guard let c = try loadCollections().first(where:{ $0.id == id }) else { throw LibraryError.collectionNotFound }
        if c.isSmart { throw LibraryError.smartCollection }
    }
    func write(_ c: ShelfCollection, upsert: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let rules = try c.rules.map { String(decoding:try encoder.encode($0),as:UTF8.self) } ?? ""
        try run("INSERT INTO collections(id,name,parent,kind,rules,position,created,archived) VALUES(?,?,?,?,?,?,?,?)" + (upsert
                ? " ON CONFLICT(id) DO UPDATE SET name=excluded.name,parent=excluded.parent,kind=excluded.kind,rules=excluded.rules,position=excluded.position,archived=excluded.archived" : ""),
                [.text(c.id),.text(c.name),c.parent.map { .text($0) } ?? .null,.text(c.kind.rawValue),.text(rules),.real(c.position),.real(c.created),.int(c.archived ? 1 : 0)])
        collectionCache = nil
    }
    /// Rewrites the searchable collection names (each collection plus its parents) for the given items.
    func refreshNames(items: [String]) throws {
        guard !items.isEmpty else { return }
        let c = try compiler()
        var chains: [String:[String]] = [:], memberships: [String:[String]] = [:]
        func chain(_ id: String) -> [String] {
            if let known = chains[id] { return known }
            var names: [String] = [], current: String? = id, seen = Set<String>()
            while let x = current, let col = c.byID[x], seen.insert(x).inserted { names.append(col.name); current = col.parent }
            chains[id] = names
            return names
        }
        try rows("SELECT item,collection FROM item_collections WHERE item IN \(Self.each)",[list(items)]) { p in
            memberships[text(p,0),default:[]].append(text(p,1))
        }
        let update = try statement("UPDATE items SET collection_names=? WHERE id=? AND collection_names<>?")
        defer { sqlite3_finalize(update) }
        for item in Set(items) {
            var seen = Set<String>(), names: [String] = []
            for collection in memberships[item] ?? [] { for name in chain(collection) where seen.insert(name.lowercased()).inserted { names.append(name) } }
            let value = names.joined(separator:Tags.separator)
            bind([.text(value),.text(item),.text(value)],to:update); try step(update)
        }
    }
    func refreshNames(inCollections ids: [String]) throws {
        try refreshNames(items:try strings("SELECT DISTINCT item FROM item_collections WHERE collection IN \(Self.each)",[list(ids)]))
    }

    // MARK: Reading

    /// Every collection, ordered by position. Build the tree from `parent`, or use `collectionTree()`.
    public func collections() throws -> [ShelfCollection] { try sync { try loadCollections() } }
    public func collection(id: String) throws -> ShelfCollection? { try sync { try loadCollections().first { $0.id == id } } }
    /// Finds a regular collection by name, ignoring case and preferring top-level ones. "Inbox" means no collection.
    public func collection(named name: String, createIfMissing: Bool = false) throws -> ShelfCollection? {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Inbox") != .orderedSame else { return nil }
        return try sync {
            let match = try loadCollections().filter { !$0.isSmart && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
                .min { ($0.parent == nil ? 0 : 1,$0.position) < ($1.parent == nil ? 0 : 1,$1.position) }
            if let match { return match }
            return createIfMissing ? try createCollection(name:trimmed) : nil
        }
    }

    // MARK: Editing collections

    @discardableResult
    public func createCollection(name: String, parent: String? = nil, kind: ShelfCollection.Kind = .collection, rules: SmartRules? = nil) throws -> ShelfCollection {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        return try transaction {
            if let parent, try !loadCollections().contains(where:{ $0.id == parent }) { throw LibraryError.collectionNotFound }
            let position = try double("SELECT coalesce(max(position),0)+1 FROM collections WHERE parent IS ?",[parent.map { .text($0) } ?? .null])
            let c = ShelfCollection(name:trimmed,parent:parent,kind:kind,rules:kind == .smart ? rules ?? SmartRules() : nil,position:position)
            try write(c)
            return c
        }
    }
    @discardableResult public func renameCollection(_ id: String, to name: String) throws -> CollectionArchive {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        return try edit(id) { $0.name = trimmed }
    }
    @discardableResult public func updateRules(_ id: String, _ rules: SmartRules) throws -> CollectionArchive {
        try edit(id) { if $0.isSmart { $0.rules = rules } }
    }
    @discardableResult public func setArchived(_ id: String, _ archived: Bool) throws -> CollectionArchive {
        try edit(id) { $0.archived = archived }
    }
    private func edit(_ id: String, _ change: (inout ShelfCollection) -> Void) throws -> CollectionArchive {
        try transaction {
            guard let old = try loadCollections().first(where:{ $0.id == id }) else { throw LibraryError.collectionNotFound }
            var new = old; change(&new)
            try write(new,upsert:true)
            if new.name != old.name { try refreshNames(inCollections:try compiler().subtree(id)) }
            return CollectionArchive(collections:[old])
        }
    }
    /// Deletes a collection and its subcollections. Items stay in the library.
    @discardableResult public func deleteCollection(_ id: String) throws -> CollectionArchive {
        try transaction {
            let c = try compiler()
            guard c.byID[id] != nil else { throw LibraryError.collectionNotFound }
            let ids = c.subtree(id)
            var archive = CollectionArchive(collections:ids.compactMap { c.byID[$0] })
            try rows("SELECT item,collection,position,added FROM item_collections WHERE collection IN \(Self.each)",[list(ids)]) { p in
                archive.memberships.append(Membership(item:text(p,0),collection:text(p,1),position:sqlite3_column_double(p,2),added:sqlite3_column_double(p,3)))
            }
            try rows("SELECT id,collection FROM connected_folders WHERE collection IN \(Self.each)",[list(ids)]) { archive.folders[text($0,0)] = text($0,1) }
            try run("DELETE FROM collections WHERE id=?",[.text(id)])
            collectionCache = nil
            try refreshNames(items:archive.memberships.map(\.item))
            return archive
        }
    }
    /// Puts collections back as they were in `archive`, with their items when those still exist.
    public func restore(_ archive: CollectionArchive) throws {
        try transaction {
            var known = Set(try loadCollections().map(\.id))
            for var c in archive.collections {
                if let parent = c.parent, !known.contains(parent) { c.parent = nil }
                try write(c,upsert:true); known.insert(c.id)
            }
            let insert = try statement("""
                INSERT OR IGNORE INTO item_collections(item,collection,position,added)
                SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM items WHERE id=?) AND EXISTS(SELECT 1 FROM collections WHERE id=? AND kind='collection')
                """)
            defer { sqlite3_finalize(insert) }
            for m in archive.memberships {
                bind([.text(m.item),.text(m.collection),.real(m.position),.real(m.added),.text(m.item),.text(m.collection)],to:insert); try step(insert)
            }
            for (folder,collection) in archive.folders { try run("UPDATE connected_folders SET collection=? WHERE id=?",[.text(collection),.text(folder)]) }
            let c = try compiler()
            try refreshNames(inCollections:Array(Set(archive.collections.flatMap { c.subtree($0.id) })))
        }
    }
    /// Re-parents a collection (nil for top level) and places it before `sibling`, or last.
    @discardableResult public func moveCollection(_ id: String, to parent: String?, before sibling: String? = nil) throws -> CollectionArchive {
        try transaction {
            let c = try compiler()
            guard let moving = c.byID[id] else { throw LibraryError.collectionNotFound }
            if let parent {
                guard c.byID[parent] != nil else { throw LibraryError.collectionNotFound }
                if c.subtree(id).contains(parent) { throw LibraryError.invalidMove }
            }
            var siblings = (parent.map { c.children[$0] ?? [] } ?? c.roots).filter { $0.id != id }
            siblings.insert(moving,at:sibling.flatMap { s in siblings.firstIndex { $0.id == s } } ?? siblings.count)
            var archive = CollectionArchive(collections:[moving])
            for (index,var s) in siblings.enumerated() {
                let position = Double(index + 1)
                guard s.id == id || s.position != position else { continue }
                if s.id != id { archive.collections.append(s) }
                s.position = position; if s.id == id { s.parent = parent }
                try write(s,upsert:true)
            }
            if moving.parent != parent { try refreshNames(inCollections:c.subtree(id)) }
            return archive
        }
    }
    /// Copies a collection, its subcollections and their items. The copy sits right after the original.
    @discardableResult public func duplicateCollection(_ id: String) throws -> ShelfCollection {
        try transaction {
            let c = try compiler()
            guard let original = c.byID[id] else { throw LibraryError.collectionNotFound }
            var mapping: [String:String] = [:], root = original
            for old in c.subtree(id) {
                guard var copy = c.byID[old] else { continue }
                copy.id = UUID().uuidString; copy.created = Date().timeIntervalSince1970
                if old == id { copy.name = original.name + " copy"; copy.position = original.position + 0.5; root = copy }
                else { copy.parent = copy.parent.flatMap { mapping[$0] } }
                mapping[old] = copy.id
                try write(copy)
                try run("INSERT INTO item_collections(item,collection,position,added) SELECT item,?,position,added FROM item_collections WHERE collection=?",[.text(copy.id),.text(old)])
            }
            try refreshNames(inCollections:Array(mapping.values))
            return root
        }
    }

    // MARK: Membership

    func addMembers(_ ids: [String], to collection: String) throws {
        try requireRegular(collection)
        var position = try double("SELECT coalesce(max(position),0) FROM item_collections WHERE collection=?",[.text(collection)])
        let insert = try statement("INSERT OR IGNORE INTO item_collections(item,collection,position,added) SELECT id,?,?,? FROM items WHERE id=?")
        defer { sqlite3_finalize(insert) }
        let now = Date().timeIntervalSince1970
        for id in ids { position += 1; bind([.text(collection),.real(position),.real(now),.text(id)],to:insert); try step(insert) }
        try refreshNames(items:ids)
    }
    /// Adds items to the end of a regular collection. Items can be in many collections.
    @discardableResult public func addItems(_ ids: [String], to collection: String) throws -> [ItemState] {
        try mutate(ids) { try addMembers(ids,to:collection) }
    }
    @discardableResult public func removeItems(_ ids: [String], from collection: String) throws -> [ItemState] {
        try mutate(ids) {
            try run("DELETE FROM item_collections WHERE collection=? AND item IN \(Self.each)",[.text(collection),list(ids)])
            try refreshNames(items:ids)
        }
    }
    /// Takes items out of `source` (every collection when nil) and puts them in `target` (none, the Inbox, when nil).
    @discardableResult public func moveItems(_ ids: [String], from source: String?, to target: String?) throws -> [ItemState] {
        try mutate(ids) {
            if let target { try requireRegular(target) }
            if let source { try run("DELETE FROM item_collections WHERE collection=? AND item IN \(Self.each)",[.text(source),list(ids)]) }
            else { try run("DELETE FROM item_collections WHERE item IN \(Self.each)",[list(ids)]) }
            if let target { try addMembers(ids,to:target) } else { try refreshNames(items:ids) }
        }
    }
    /// Moves items to just before `target` (or the end) in a collection's custom order, or the library's when `collection` is nil.
    /// Returns the prior state of every item whose position changed.
    @discardableResult public func reorder(_ ids: [String], before target: String?, in collection: String? = nil) throws -> [ItemState] {
        try transaction {
            if let collection { try requireRegular(collection) }
            var order = collection == nil
                ? try strings("SELECT id FROM items ORDER BY position,added DESC,rowid DESC")
                : try strings("SELECT m.item FROM item_collections m JOIN items i ON i.id=m.item WHERE m.collection=? ORDER BY m.position,i.added DESC,i.rowid DESC",[.text(collection!)])
            let present = Set(order), moving = ids.filter { present.contains($0) }, set = Set(moving)
            guard !moving.isEmpty else { return [] }
            order.removeAll { set.contains($0) }
            order.insert(contentsOf:moving,at:target.flatMap { order.firstIndex(of:$0) } ?? order.count)
            var current: [String:Double] = [:]
            if let collection {
                try rows("SELECT item,position FROM item_collections WHERE collection=?",[.text(collection)]) { current[text($0,0)] = sqlite3_column_double($0,1) }
            } else {
                try rows("SELECT id,position FROM items") { current[text($0,0)] = sqlite3_column_double($0,1) }
            }
            let changed = order.enumerated().filter { current[$0.element] != Double($0.offset + 1) }
            let before = try states(changed.map(\.element))
            let update = try statement(collection == nil ? "UPDATE items SET position=? WHERE id=?" : "UPDATE item_collections SET position=? WHERE item=? AND collection=?")
            defer { sqlite3_finalize(update) }
            for (offset,id) in changed {
                bind([.real(Double(offset + 1)),.text(id)] + (collection.map { [.text($0)] } ?? []),to:update); try step(update)
            }
            return before
        }
    }
}
