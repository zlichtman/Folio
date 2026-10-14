import Foundation
import CSQLite

/// What a listing shows. Every scope except `trash` covers items that aren't in the trash.
public enum Scope: Hashable, Sendable, Codable {
    case all
    /// Items that aren't in any collection.
    case inbox
    case liked, trash, untagged, missing
    /// A regular collection (optionally with its subcollections), or a smart collection's results.
    case collection(String, includeDescendants: Bool = true)
    /// A tag the user added.
    case tag(String)
    case recent(days: Int)
    /// image, video, gif, link, color, svg, pdf, raw, or a file extension.
    case kind(String)
    case smart(SmartRules)
    /// A connected folder.
    case folder(String)
    /// Everything inside a directory of a connected folder, at any depth.
    case folderPath(String)
}

public enum Sort: Hashable, Sendable, Codable {
    case added, fileDate, name, size
    /// The collection's arrangement, or the library's outside a collection. Ignores `ascending`.
    case custom
    /// Stable for a given seed. Ignores `ascending`.
    case random(seed: Int64)
}

struct Condition {
    var sql: String
    var args: [SQLValue]
    init(_ sql: String, _ args: [SQLValue] = []) { self.sql = sql; self.args = args }
    static func join(_ parts: [Condition], _ op: String) -> Condition {
        if parts.isEmpty { return Condition(op == "AND" ? "1" : "0") }
        return Condition("(" + parts.map(\.sql).joined(separator:" \(op) ") + ")",parts.flatMap(\.args))
    }
}

/// Turns scopes, searches and smart rules into parameterized SQL over `items i`.
struct Compiler {
    let byID: [String:ShelfCollection]
    let children: [String:[ShelfCollection]]
    let roots: [ShelfCollection]
    let now: Double
    static let raw = Set(SmartRules.raw.split(separator:",").map(String.init))

    init(_ collections: [ShelfCollection], now: Double = Date().timeIntervalSince1970) {
        byID = Dictionary(collections.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        let ordered = collections.sorted { ($0.position,$0.name) < ($1.position,$1.name) }
        var children: [String:[ShelfCollection]] = [:], roots: [ShelfCollection] = []
        for c in ordered {
            if let parent = c.parent, byID[parent] != nil { children[parent,default:[]].append(c) } else { roots.append(c) }
        }
        self.children = children; self.roots = roots; self.now = now
    }
    func subtree(_ id: String) -> [String] {
        var out = [id], seen: Set = [id], i = 0
        while i < out.count {
            for child in children[out[i]] ?? [] where seen.insert(child.id).inserted { out.append(child.id) }
            i += 1
        }
        return out
    }
    func kind(_ k: String) -> Condition {
        switch k {
        case "image", "video", "link", "color": Condition("i.kind=?",[.text(k)])
        case "raw": Condition("i.ext IN (\(Self.raw.map { "'\($0)'" }.sorted().joined(separator:",")))")
        case "jpg", "jpeg": Condition("i.ext IN ('jpg','jpeg')")
        case "tif", "tiff": Condition("i.ext IN ('tif','tiff')")
        default: Condition("i.ext=?",[.text(k)])
        }
    }
    func tag(_ t: String, machine: Bool) -> Condition {
        let key = Tags.key(t)
        return machine ? Condition("(instr(lower(i.tags),?)>0 OR instr(lower(i.auto_tags),?)>0)",[.text(key),.text(key)])
            : Condition("instr(lower(i.tags),?)>0",[.text(key)])
    }
    func color(_ value: String) -> Condition {
        guard let target = ColorMath.target(value) else { return Condition("0") }
        return Condition("color_near(i.colors,?)",[.text(target)])
    }
    func collection(_ id: String, descendants: Bool, visiting: Set<String>) -> Condition {
        guard let c = byID[id] else { return Condition("0") }
        if c.isSmart {
            guard !visiting.contains(id), let rules = c.rules else { return Condition("0") }
            return self.rules(rules,visiting:visiting.union([id]))
        }
        let ids = descendants ? subtree(id).filter { byID[$0]?.isSmart == false } : [id]
        if ids.count == 1 { return Condition("i.id IN (SELECT item FROM item_collections WHERE collection=?)",[.text(id)]) }
        return Condition("i.id IN (SELECT item FROM item_collections WHERE collection IN \(LibraryDatabase.each))",[LibraryDatabase.jsonList(ids)])
    }
    func named(_ name: String) -> Condition {
        let matches = byID.values.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.sorted { $0.created < $1.created }
        return Condition.join(matches.map { collection($0.id,descendants:true,visiting:[]) },"OR")
    }

    /// `colorRank`: the first colour searched for, so results can come most-that-colour first.
    struct Plan { var conditions: [Condition] = []; var match: String?; var trashed = false; var colorRank: String? }
    func plan(_ scope: Scope, _ query: SearchQuery) -> Plan {
        var p = Plan()
        switch scope {
        case .all: break
        case .inbox: p.conditions.append(Condition("NOT EXISTS(SELECT 1 FROM item_collections m WHERE m.item=i.id)"))
        case .liked: p.conditions.append(Condition("i.liked=1"))
        case .trash: p.trashed = true
        case .untagged: p.conditions.append(Condition("i.tags=''"))
        case .missing: p.conditions.append(Condition("i.missing=1"))
        case .collection(let id, let descendants): p.conditions.append(collection(id,descendants:descendants,visiting:[]))
        case .tag(let t): p.conditions.append(tag(t,machine:false))
        case .recent(let days): p.conditions.append(Condition("i.added>=?",[.real(now - Double(days) * 86400)]))
        case .kind(let k): p.conditions.append(kind(SearchQuery.kind(k)))
        case .smart(let rules): p.conditions.append(self.rules(rules))
        case .folder(let id): p.conditions.append(Condition("i.folder=?",[.text(id)]))
        case .folderPath(let dir):
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            p.conditions.append(Condition("substr(i.path,1,?)=?",[.int(Int64(prefix.utf8.count)),.text(prefix)]))
        }
        var kinds: [Condition] = []
        for clause in query.clauses {
            let c: Condition
            switch clause.filter {
            case .flag(.trashed): if !clause.negated { p.trashed = true }; continue
            case .kind(let k):
                if !clause.negated { kinds.append(kind(k)); continue }
                c = kind(k)
            case .tag(let t): c = tag(t,machine:true)
            case .color(let value):
                c = color(value)
                if !clause.negated, p.colorRank == nil, let target = ColorMath.target(value) { p.colorRank = target }
            case .collection(let name): c = named(name)
            case .flag(.liked): c = Condition("i.liked=1")
            case .flag(.untagged): c = Condition("i.tags=''")
            case .flag(.missing): c = Condition("i.missing=1")
            case .flag(.landscape): c = Condition("i.width>i.height*1.05")
            case .flag(.portrait): c = Condition("i.height>i.width*1.05")
            case .flag(.square): c = Condition("(i.width>0 AND abs(i.width-i.height)<=0.05*max(i.width,i.height))")
            case .before(let time): c = Condition("i.added<?",[.real(time)])
            case .after(let time): c = Condition("i.added>=?",[.real(time)])
            }
            p.conditions.append(clause.negated ? Condition("NOT (\(c.sql))",c.args) : c)
        }
        if !kinds.isEmpty { p.conditions.append(Condition.join(kinds,"OR")) }
        p.match = query.match
        for excluded in query.exclusions {
            p.conditions.append(Condition("i.rowid NOT IN (SELECT rowid FROM search WHERE search MATCH ?)",[.text(excluded)]))
        }
        p.conditions.insert(Condition(p.trashed ? "i.trashed IS NOT NULL" : "i.trashed IS NULL"),at:0)
        return p
    }
    func order(_ sort: Sort, ascending: Bool, scope: Scope) -> Condition {
        let d = ascending ? "ASC" : "DESC"
        switch sort {
        case .added: return Condition("i.added \(d),i.rowid \(d)")
        case .fileDate: return Condition("i.file_date \(d),i.added \(d),i.rowid \(d)")
        case .name: return Condition("i.title COLLATE natural_name \(d),i.rowid \(d)")
        case .size: return Condition("i.file_size \(d),i.rowid \(d)")
        case .custom:
            if case .collection(let id,_) = scope, byID[id]?.kind == .collection {
                return Condition("(SELECT position FROM item_collections WHERE item=i.id AND collection=?) NULLS LAST,i.added DESC,i.rowid DESC",[.text(id)])
            }
            return Condition("i.position,i.added DESC,i.rowid DESC")
        case .random(let seed): return Condition("shuffle(i.rowid,?)",[.int(seed)])
        }
    }
}

extension ShelfItem {
    init(row p: OpaquePointer, full: Bool) {
        id = text(p,0); path = text(p,1); title = text(p,2); kind = text(p,3); ext = text(p,4)
        source = text(p,5); url = text(p,6); site = text(p,7); author = text(p,8)
        tags = split(p,9); autoTags = split(p,10); note = text(p,11); hasText = sqlite3_column_int(p,12) != 0
        colors = split(p,13,0x20); added = sqlite3_column_double(p,14); fileDate = sqlite3_column_double(p,15)
        fileSize = sqlite3_column_int64(p,16); width = sqlite3_column_double(p,17); height = sqlite3_column_double(p,18)
        duration = sqlite3_column_double(p,19); liked = sqlite3_column_int(p,20) != 0; trashed = optionalDouble(p,21)
        missing = sqlite3_column_int(p,22) != 0; folder = optionalText(p,23); position = sqlite3_column_double(p,24)
        collections = split(p,25); ocr = full ? text(p,26) : ""; seen = full ? text(p,27) : ""
    }
}

extension LibraryDatabase {
    static let listColumns = """
        i.id,i.path,i.title,i.kind,i.ext,i.source,i.url,i.site,i.author,i.tags,i.auto_tags,i.note,i.has_text,i.colors,\
        i.added,i.file_date,i.file_size,i.width,i.height,i.duration,i.liked,i.trashed,i.missing,i.folder,i.position,\
        (SELECT group_concat(collection,char(31)) FROM item_collections WHERE item=i.id)
        """
    /// bm25 weights in `searchColumns` order.
    static let weights = "10.0,6.0,3.0,4.0,2.0,1.0,1.0,1.0,2.0,2.0,1.5"
    func compiler() throws -> Compiler { Compiler(try loadCollections()) }

    /// Items for a sidebar scope and search text, without recognized text (use `item(id:)` for that).
    /// Free text is ranked by relevance unless `rankText` is false.
    /// `rules` narrows further, as a filter on top of the place and the search.
    public func items(scope: Scope = .all, query: String = "", rules: SmartRules? = nil, sort: Sort = .added, ascending: Bool = false,
                      rankText: Bool = true, limit: Int? = nil) throws -> [ShelfItem] {
        try items(scope:scope,search:SearchQuery(query),rules:rules,sort:sort,ascending:ascending,rankText:rankText,limit:limit)
    }
    public func items(scope: Scope = .all, search: SearchQuery, rules: SmartRules? = nil, sort: Sort = .added, ascending: Bool = false,
                      rankText: Bool = true, limit: Int? = nil) throws -> [ShelfItem] {
        try sync {
            let c = try compiler(), plan = c.plan(scope,search)
            var sql = "SELECT \(Self.listColumns) FROM items i", conditions = plan.conditions
            if let rules { conditions.append(c.rules(rules)) }
            if let match = plan.match {
                sql += " JOIN search ON search.rowid=i.rowid"
                conditions.insert(Condition("search MATCH ?",[.text(match)]),at:0)
            }
            let filter = Condition.join(conditions,"AND")
            var order = plan.match != nil && rankText ? Condition("bm25(search,\(Self.weights)),i.added DESC") : c.order(sort,ascending:ascending,scope:scope)
            // A colour search with no words puts the pictures that are most that colour first.
            if plan.match == nil, rankText, let target = plan.colorRank {
                order = Condition("color_rank(i.colors,?),\(order.sql)",[.text(target)] + order.args)
            }
            sql += " WHERE \(filter.sql) ORDER BY \(order.sql)"
            if let limit { sql += " LIMIT \(max(0,limit))" }
            var out: [ShelfItem] = []
            try rows(sql,filter.args + order.args) { out.append(ShelfItem(row:$0,full:false)) }
            return out
        }
    }
    /// One item with everything, including recognized text.
    public func item(id: String) throws -> ShelfItem? {
        try sync {
            var out: ShelfItem?
            try rows("SELECT \(Self.listColumns),i.ocr,coalesce(i.seen,'') FROM items i WHERE i.id=?",[.text(id)]) { out = ShelfItem(row:$0,full:true) }
            return out
        }
    }
    public func count(_ scope: Scope = .all, query: String = "") throws -> Int {
        try sync {
            let plan = try compiler().plan(scope,SearchQuery(query))
            var conditions = plan.conditions, sql = "SELECT count(*) FROM items i"
            if let match = plan.match { sql += " JOIN search ON search.rowid=i.rowid"; conditions.insert(Condition("search MATCH ?",[.text(match)]),at:0) }
            let filter = Condition.join(conditions,"AND")
            return try integer(sql + " WHERE " + filter.sql,filter.args)
        }
    }
    /// How many items rules would gather, for a smart folder being edited.
    public func count(rules: SmartRules, in scope: Scope = .all) throws -> Int {
        try sync {
            let c = try compiler()
            let filter = Condition.join(c.plan(scope,SearchQuery()).conditions + [c.rules(rules)],"AND")
            return try integer("SELECT count(*) FROM items i WHERE " + filter.sql,filter.args)
        }
    }
    /// Counts for many sidebar rows in a single pass over the library.
    public func counts(for scopes: [Scope]) throws -> [Int] {
        guard !scopes.isEmpty else { return [] }
        return try sync {
            let c = try compiler()
            var parts: [String] = [], args: [SQLValue] = []
            for scope in scopes {
                let filter = Condition.join(c.plan(scope,SearchQuery()).conditions,"AND")
                parts.append("count(*) FILTER (WHERE \(filter.sql))"); args += filter.args
            }
            var out = [Int](repeating:0,count:scopes.count)
            try rows("SELECT \(parts.joined(separator:",")) FROM items i",args) { p in
                for k in out.indices { out[k] = Int(sqlite3_column_int64(p,Int32(k))) }
            }
            return out
        }
    }
    /// Tags users added to items outside the trash, by name.
    public func allTags() throws -> [(name: String, count: Int)] {
        try sync {
            var counts: [String:(name: String, count: Int)] = [:]
            try rows("SELECT tags FROM items WHERE trashed IS NULL AND tags<>''") { p in
                for tag in split(p,0) { counts[Tags.key(tag),default:(tag,0)].count += 1 }
            }
            return counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    /// Every tag on items outside the trash, the user's and the automatic ones, most used first.
    /// `automatic` is true when no item carries the tag as one the user added.
    public func tagCounts() throws -> [(name: String, count: Int, automatic: Bool)] {
        try sync {
            var counts: [String:(name: String, count: Int, automatic: Bool)] = [:]
            try rows("SELECT tags,auto_tags FROM items WHERE trashed IS NULL AND (tags<>'' OR auto_tags<>'')") { p in
                var keys = Set<String>()
                for tag in split(p,0) {
                    let key = Tags.key(tag); keys.insert(key)
                    var entry = counts[key] ?? (tag,0,false)
                    if entry.automatic { entry.name = tag; entry.automatic = false }
                    counts[key] = entry
                }
                for tag in split(p,1) where keys.insert(Tags.key(tag)).inserted {
                    if counts[Tags.key(tag)] == nil { counts[Tags.key(tag)] = (tag,0,true) }
                }
                for key in keys { counts[key]?.count += 1 }
            }
            return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    /// The sidebar tree. Regular collections count their own and their subcollections' items once each.
    public func collectionTree() throws -> [CollectionNode] {
        try sync {
            let c = try compiler()
            var members: [String:Set<Int64>] = [:]
            try rows("SELECT m.collection,i.rowid FROM item_collections m JOIN items i ON i.id=m.item WHERE i.trashed IS NULL") { p in
                members[text(p,0),default:[]].insert(sqlite3_column_int64(p,1))
            }
            let smart = c.byID.values.filter(\.isSmart).map(\.id)
            let smartCounts = Dictionary(uniqueKeysWithValues:zip(smart,try counts(for:smart.map { .collection($0) })))
            func node(_ collection: ShelfCollection) -> (CollectionNode,Set<Int64>) {
                var set = members[collection.id] ?? [], children: [CollectionNode] = []
                for child in c.children[collection.id] ?? [] {
                    let (n,s) = node(child); children.append(n)
                    if !child.isSmart { set.formUnion(s) }
                }
                return (CollectionNode(collection:collection,count:collection.isSmart ? smartCounts[collection.id] ?? 0 : set.count,children:children),set)
            }
            return c.roots.map { node($0).0 }
        }
    }
}
