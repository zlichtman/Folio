import Foundation

/// What a web page says about itself: its title, site name, description and preview image, read from the
/// page's head (Open Graph and Twitter tags first, then <title> and the first icon).
public struct LinkMetadata: Equatable, Sendable {
    public var title = ""
    public var site = ""
    public var summary = ""
    public var image: URL?
    public var icon: URL?

    public init(title: String = "", site: String = "", summary: String = "", image: URL? = nil, icon: URL? = nil) {
        self.title = title; self.site = site; self.summary = summary; self.image = image; self.icon = icon
    }
    /// Reads a page's HTML. Relative image links resolve against `base`.
    public static func parse(html: String, base: URL) -> LinkMetadata {
        // Only the head matters, and pages can be huge.
        let head = String(html.prefix(400_000))
        var meta: [String:String] = [:]
        for tag in matches(#"<meta\s[^>]*>"#,head) {
            let key = (attribute("property",tag) ?? attribute("name",tag) ?? attribute("itemprop",tag))?.lowercased()
            if let key, let content = attribute("content",tag), meta[key] == nil { meta[key] = decode(content) }
        }
        var out = LinkMetadata()
        let titleTag = matches(#"<title[^>]*>([\s\S]*?)</title>"#,head,group:1).first.map(decode)
        out.title = clean(meta["og:title"] ?? meta["twitter:title"] ?? titleTag ?? "")
        out.site = clean(meta["og:site_name"] ?? meta["application-name"] ?? "")
        out.summary = clean(meta["og:description"] ?? meta["twitter:description"] ?? meta["description"] ?? "")
        if let raw = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"] ?? meta["image"] {
            out.image = URL(string:raw.trimmingCharacters(in:.whitespaces),relativeTo:base)?.absoluteURL
        }
        for tag in matches(#"<link\s[^>]*>"#,head) {
            guard let rel = attribute("rel",tag)?.lowercased(), rel.contains("icon"), let href = attribute("href",tag) else { continue }
            if out.icon == nil || rel.contains("apple-touch") { out.icon = URL(string:decode(href),relativeTo:base)?.absoluteURL }
        }
        return out
    }
    /// Every URL in pasted text, one per line or separated by spaces, web addresses only, without repeats.
    public static func urls(in text: String) -> [URL] {
        var seen = Set<String>()
        return text.components(separatedBy:.whitespacesAndNewlines).compactMap { word -> URL? in
            let trimmed = word.trimmingCharacters(in:CharacterSet(charactersIn:"<>\"'()[],"))
            guard let url = URL(string:trimmed), let scheme = url.scheme?.lowercased(), ["http","https"].contains(scheme),
                  url.host?.contains(".") == true, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
    /// Whether a URL points straight at a picture or video, which is saved as media rather than as a link.
    public static func isMedia(_ url: URL) -> Bool {
        ["jpg","jpeg","png","gif","webp","heic","avif","svg","mp4","mov","webm","m4v"].contains(url.pathExtension.lowercased())
    }

    private static func matches(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]) else { return [] }
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match in
            Range(match.range(at:group),in:text).map { String(text[$0]) }
        }
    }
    private static func attribute(_ name: String, _ tag: String) -> String? {
        let pattern = "\\b" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]),
              let match = regex.firstMatch(in:tag,range:NSRange(tag.startIndex...,in:tag)) else { return nil }
        for group in 1...3 { if let range = Range(match.range(at:group),in:tag) { return String(tag[range]) } }
        return nil
    }
    private static func clean(_ text: String) -> String {
        text.split(whereSeparator:\.isWhitespace).joined(separator:" ")
    }
    static func decode(_ text: String) -> String {
        var out = text
        for (entity,value) in [("&amp;","&"),("&quot;","\""),("&#39;","'"),("&#x27;","'"),("&apos;","'"),("&lt;","<"),("&gt;",">"),("&nbsp;"," "),("&#8217;","’"),("&#8211;","–"),("&#8212;","—")] {
            out = out.replacingOccurrences(of:entity,with:value)
        }
        return out
    }
}
