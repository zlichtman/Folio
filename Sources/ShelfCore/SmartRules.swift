import Foundation

public struct SmartRule: Codable, Hashable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case kind, ext, tag, name, text, color, added, width, height, orientation, liked, untagged, hasText, domain, collection
        /// File size in megabytes, video length in seconds, the file's own date (days, like `added`), a watched folder's id.
        case size, duration, created, folder
    }
    public enum Op: String, Codable, Sendable { case `is`, isNot, contains, notContains, begins, greater, less, within, notWithin }
    public var field: Field
    public var op: Op
    /// Text, a number, `true`/`false`, days for `within`, a collection id, or landscape/portrait/square.
    /// For kind, ext and tag, `is`/`isNot` accept a comma-separated list.
    public var value: String
    public init(_ field: Field, _ op: Op = .is, _ value: String = "true") { self.field = field; self.op = op; self.value = value }
}

/// Saved search for a smart collection. Groups nest so `all` and `any` can mix.
public struct SmartRules: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable { case all, any }
    public var match: Match
    public var rules: [SmartRule]
    public var groups: [SmartRules]
    public init(match: Match = .all, rules: [SmartRule] = [], groups: [SmartRules] = []) {
        self.match = match; self.rules = rules; self.groups = groups
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        match = try c.decodeIfPresent(Match.self,forKey:.match) ?? .all
        rules = try c.decodeIfPresent([SmartRule].self,forKey:.rules) ?? []
        groups = try c.decodeIfPresent([SmartRules].self,forKey:.groups) ?? []
    }

    static let raw = "dng,cr2,cr3,nef,arw,raf,orf,rw2,pef"
    static let graphicTags = "illustrations,art,painting,diagram,chart"
    /// Built-in smart collections created with a new library. They are ordinary smart collections afterwards.
    public static let autoSort: [(name: String, rules: SmartRules)] = [
        ("Screenshots", SmartRules(match:.any,rules:[SmartRule(.tag,.is,"screenshot"),SmartRule(.name,.begins,"Screenshot"),
                                                       SmartRule(.name,.begins,"Screen Shot"),SmartRule(.name,.begins,"CleanShot")])),
        ("Photos", SmartRules(rules:[SmartRule(.kind,.is,"image"),SmartRule(.ext,.is,"jpg,jpeg,heic,heif," + raw),
                                     SmartRule(.tag,.isNot,"screenshot," + graphicTags),SmartRule(.width,.greater,"400"),SmartRule(.height,.greater,"400")])),
        ("Graphics", SmartRules(match:.any,rules:[SmartRule(.ext,.is,"svg,ai,eps"),SmartRule(.tag,.is,graphicTags)])),
        ("With Text", SmartRules(rules:[SmartRule(.hasText)])),
        ("Videos", SmartRules(rules:[SmartRule(.kind,.is,"video")])),
        ("GIFs", SmartRules(rules:[SmartRule(.kind,.is,"gif")])),
        ("Links", SmartRules(rules:[SmartRule(.kind,.is,"link")])),
        ("Colors", SmartRules(rules:[SmartRule(.kind,.is,"color")])),
        ("Recently Added", SmartRules(rules:[SmartRule(.added,.within,"7")])),
    ]
}

extension Compiler {
    func rules(_ rules: SmartRules, visiting: Set<String> = []) -> Condition {
        let parts = rules.rules.map { rule($0,visiting:visiting) } + rules.groups.map { self.rules($0,visiting:visiting) }
        guard !parts.isEmpty else { return Condition("1") }
        return Condition.join(parts,rules.match == .all ? "AND" : "OR")
    }
    func rule(_ r: SmartRule, visiting: Set<String>) -> Condition {
        var negate = [.isNot,.notContains,.notWithin].contains(r.op)
        let items = r.value.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let number = Double(r.value.trimmingCharacters(in:.whitespaces)) ?? 0
        let truth = !["false","no","0"].contains(r.value.lowercased())
        let base: Condition
        switch r.field {
        case .kind: base = Condition.join(items.map { kind(SearchQuery.kind($0)) },"OR")
        case .ext:
            let values = items.map { $0.lowercased().hasPrefix(".") ? String($0.lowercased().dropFirst()) : $0.lowercased() }
            base = values.isEmpty ? Condition("0") : Condition("i.ext IN (\(values.map { _ in "?" }.joined(separator:",")))",values.map { .text($0) })
        case .tag:
            if r.op == .contains || r.op == .notContains {
                let key = String(Tags.key(r.value).dropFirst().dropLast())
                base = Condition("(instr(lower(i.tags),?)>0 OR instr(lower(i.auto_tags),?)>0)",[.text(key),.text(key)])
            } else { base = Condition.join(items.map { tag($0,machine:true) },"OR") }
        case .name:
            let escaped = r.value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")
            switch r.op {
            case .is, .isNot: base = Condition("i.title=? COLLATE NOCASE",[.text(r.value)])
            case .begins: base = Condition("i.title LIKE ? ESCAPE '\\'",[.text(escaped + "%")])
            default: base = Condition("i.title LIKE ? ESCAPE '\\'",[.text("%" + escaped + "%")])
            }
        case .text:
            guard let match = SearchQuery(r.value).match else { return Condition("1") }
            base = Condition("i.rowid IN (SELECT rowid FROM search WHERE search MATCH ?)",[.text(match)])
        case .color: base = color(r.value)
        case .added: base = Condition("i.added>=?",[.real(now - number * 86400)])
        case .created: base = Condition("i.file_date>0 AND i.file_date>=?",[.real(now - number * 86400)])
        case .size: base = Condition(r.op == .less ? "i.file_size<?" : "i.file_size>?",[.real(number * 1_000_000)])
        case .duration: base = Condition(r.op == .less ? "(i.kind='video' AND i.duration<?)" : "(i.kind='video' AND i.duration>?)",[.real(number)])
        case .folder: base = Condition("i.folder=?",[.text(r.value)])
        case .width, .height:
            let column = r.field == .width ? "i.width" : "i.height"
            base = Condition(r.op == .greater ? "\(column)>?" : r.op == .less ? "\(column)<?" : "\(column)=?",[.real(number)])
        case .orientation:
            switch r.value.lowercased() {
            case "landscape": base = Condition("i.width>i.height*1.05")
            case "portrait": base = Condition("i.height>i.width*1.05")
            default: base = Condition("(i.width>0 AND abs(i.width-i.height)<=0.05*max(i.width,i.height))")
            }
        case .liked, .untagged, .hasText:
            base = Condition(r.field == .liked ? "i.liked=1" : r.field == .untagged ? "i.tags=''" : "i.has_text=1")
            if !truth { negate.toggle() }
        case .domain:
            let host = ShelfItem.site(r.value.contains("://") ? r.value : "https://" + r.value)
            base = r.op == .contains || r.op == .notContains
                ? Condition("instr(i.site,?)>0",[.text(r.value.lowercased())])
                : Condition("(i.site=? OR i.site LIKE ?)",[.text(host),.text("%." + host)])
        case .collection: base = collection(r.value,descendants:true,visiting:visiting)
        }
        return negate ? Condition("NOT (\(base.sql))",base.args) : base
    }
}
