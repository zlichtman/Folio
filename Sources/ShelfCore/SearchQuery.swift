import Foundation

/// The search field language. Words prefix-match and must all match; "quoted phrases" match exactly; a leading
/// `-` excludes. Filters: `tag:`, `type:`/`kind:`, `color:`, `in:`, `is:` (liked, untagged, wide, tall, square…), `before:`, `after:`; values may be quoted.
/// Anything that doesn't parse as a filter is searched as text.
public struct SearchQuery: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public var text: String
        public var phrase: Bool
        public var negated: Bool
        public init(_ text: String, phrase: Bool = false, negated: Bool = false) { self.text = text; self.phrase = phrase; self.negated = negated }
    }
    public enum Flag: String, Sendable { case liked, untagged, missing, trashed, landscape, portrait, square }
    public enum Filter: Equatable, Sendable {
        case tag(String)
        /// image, video, gif, link, color, svg, pdf, raw, or a file extension.
        case kind(String)
        /// `#rrggbb` or a colour bucket name; anything else matches nothing.
        case color(String)
        /// A collection name.
        case collection(String)
        case flag(Flag)
        /// Added before this time.
        case before(Double)
        /// Added at or after this time.
        case after(Double)
    }
    public struct Clause: Equatable, Sendable {
        public var filter: Filter
        public var negated: Bool
        public init(_ filter: Filter, negated: Bool = false) { self.filter = filter; self.negated = negated }
    }
    public var terms: [Term] = []
    public var clauses: [Clause] = []

    public init(terms: [Term] = [], clauses: [Clause] = []) { self.terms = terms; self.clauses = clauses }
    public init(_ text: String, now: Date = Date(), calendar: Calendar = .current) {
        let chars = Array(text)
        var i = 0
        func isQuote(_ c: Character) -> Bool { c == "\"" || c == "\u{201C}" || c == "\u{201D}" }
        func quoted() -> String {
            i += 1; var s = ""
            while i < chars.count, !isQuote(chars[i]) { s.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 }
            return s
        }
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negated = false
            if chars[i] == "-", i + 1 < chars.count, !chars[i+1].isWhitespace { negated = true; i += 1 }
            if isQuote(chars[i]) { add(quoted(), phrase:true, negated:negated); continue }
            var token = "", value: String?
            while i < chars.count, !chars[i].isWhitespace {
                if isQuote(chars[i]), token.hasSuffix(":") { value = quoted(); break }
                token.append(chars[i]); i += 1
            }
            if let colon = token.firstIndex(of:":") {
                let key = token[..<colon].lowercased(), raw = (value ?? String(token[token.index(after:colon)...])).trimmingCharacters(in:.whitespaces)
                // A filter still being typed narrows nothing yet.
                if raw.isEmpty, Self.keys.contains(key) { continue }
                if let filter = Self.filter(key, raw, now:now, calendar:calendar) { clauses.append(Clause(filter,negated:negated)); continue }
            }
            // A bare hex code, like #3a5ad9 or #f60, searches by colour.
            if value == nil, token.hasPrefix("#"), [4,7].contains(token.count), token.dropFirst().allSatisfy(\.isHexDigit),
               let target = ColorMath.target(token) { clauses.append(Clause(.color(target),negated:negated)); continue }
            add(token + (value ?? ""), phrase:value != nil, negated:negated)
        }
    }
    private mutating func add(_ text: String, phrase: Bool, negated: Bool) {
        guard text.contains(where:{ $0.isLetter || $0.isNumber }) else { return }
        terms.append(Term(text,phrase:phrase,negated:negated))
    }
    public var isEmpty: Bool { terms.isEmpty && clauses.isEmpty }
    /// True when there is positive free text to rank by.
    public var hasText: Bool { terms.contains { !$0.negated } }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
    /// FTS5 expression for the positive terms; user text never becomes FTS syntax.
    var match: String? {
        let parts = terms.filter { !$0.negated }.map { $0.phrase ? Self.quote($0.text) : Self.quote($0.text) + "*" }
        return parts.isEmpty ? nil : parts.joined(separator:" AND ")
    }
    var exclusions: [String] { terms.filter(\.negated).map { Self.quote($0.text) } }

    static let keys: Set = ["tag","tags","type","kind","color","colour","in","collection","is","has","before","after","since"]
    static func filter(_ key: String, _ value: String, now: Date, calendar: Calendar) -> Filter? {
        guard !value.isEmpty else { return nil }
        switch key {
        case "tag", "tags": return Tags.clean([value]).first.map(Filter.tag)
        case "type", "kind": return .kind(kind(value))
        case "color", "colour": return .color(ColorMath.target(value) ?? value.lowercased())
        case "in", "collection": return .collection(value)
        case "is", "has":
            switch value.lowercased() {
            case "liked", "favorite", "favourite", "loved": return .flag(.liked)
            case "untagged": return .flag(.untagged)
            case "missing": return .flag(.missing)
            case "trashed", "trash", "deleted": return .flag(.trashed)
            case "wide", "landscape", "horizontal": return .flag(.landscape)
            case "tall", "portrait", "vertical": return .flag(.portrait)
            case "square": return .flag(.square)
            default: return nil
            }
        case "before": return date(value, now:now, calendar:calendar).map(Filter.before)
        case "after", "since": return date(value, now:now, calendar:calendar).map(Filter.after)
        default: return nil
        }
    }
    static func kind(_ value: String) -> String {
        var v = value.lowercased()
        if v.count > 3, v.hasSuffix("s") { v.removeLast() }
        let aliases = ["photo":"image","picture":"image","pic":"image","img":"image","movie":"video","clip":"video",
                       "colour":"color","swatch":"color","url":"link","bookmark":"link","jpeg":"jpg"]
        return aliases[v] ?? v
    }
    /// today, yesterday, 7d/2w/3m/1y ago, or yyyy, yyyy-mm, yyyy-mm-dd (also with / or .), at local midnight.
    static func date(_ value: String, now: Date, calendar: Calendar) -> Double? {
        let s = value.lowercased(), today = calendar.startOfDay(for:now)
        if s == "today" { return today.timeIntervalSince1970 }
        if s == "yesterday" { return calendar.date(byAdding:.day,value:-1,to:today)?.timeIntervalSince1970 }
        if let unit = s.last, "dwmy".contains(unit), let n = Int(s.dropLast()), n >= 0 {
            let component: Calendar.Component = unit == "d" ? .day : unit == "w" ? .weekOfYear : unit == "m" ? .month : .year
            return calendar.date(byAdding:component,value:-n,to:today)?.timeIntervalSince1970
        }
        let parts = s.split(whereSeparator:{ $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == s.split(whereSeparator:{ $0 == "-" || $0 == "/" || $0 == "." }).count,
              (1900...2999).contains(parts[0]) else { return nil }
        var c = DateComponents(); c.year = parts[0]; c.month = parts.count > 1 ? parts[1] : 1; c.day = parts.count > 2 ? parts[2] : 1
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return calendar.date(from:c)?.timeIntervalSince1970
    }
}
