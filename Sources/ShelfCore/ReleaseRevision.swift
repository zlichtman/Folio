import Foundation

/// Releases carry a public version in their tag (v1.2) and a hidden build marker in
/// their notes (<!-- folio-build:N -->). The build decides whether an update is newer,
/// so a replacement installer for the same version still reaches existing installs.
public enum ReleaseRevision {
    public static let marker = "<!-- folio-build:"
    public static let assetName = "Folio.dmg"
    public static let downloadHosts: Set<String> = ["github.com","objects.githubusercontent.com","release-assets.githubusercontent.com"]

    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
    }
    public struct Release: Decodable, Equatable, Sendable {
        public let tag: String
        public let name: String?
        public let body: String?
        public let draft: Bool
        public let prerelease: Bool
        public let page: URL?
        public let assets: [Asset]
        public init(tag: String, name: String? = nil, body: String?, draft: Bool = false, prerelease: Bool = false, page: URL? = nil, assets: [Asset] = []) {
            self.tag = tag; self.name = name; self.body = body; self.draft = draft; self.prerelease = prerelease; self.page = page; self.assets = assets
        }
        enum CodingKeys: String, CodingKey { case tag = "tag_name", name, body, draft, prerelease, page = "html_url", assets }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            tag = try c.decode(String.self,forKey:.tag); name = try c.decodeIfPresent(String.self,forKey:.name)
            body = try c.decodeIfPresent(String.self,forKey:.body)
            draft = try c.decodeIfPresent(Bool.self,forKey:.draft) ?? false; prerelease = try c.decodeIfPresent(Bool.self,forKey:.prerelease) ?? false
            page = try? c.decodeIfPresent(URL.self,forKey:.page); assets = (try? c.decodeIfPresent([Asset].self,forKey:.assets)) ?? []
        }
    }
    public struct Choice: Equatable, Sendable {
        public let release: Release
        public let version: String
        public let build: Int
    }

    /// "v1.2" or "1.2.3" become "1.2" and "1.2.3"; anything else is rejected.
    public static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = version.split(separator:".",omittingEmptySubsequences:false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return version
    }

    /// Exactly one well-formed marker line; ambiguous metadata never offers a build.
    /// A release's notes as sections of plain points ("New", "Improvements", "Fixes"), without the version line or the
    /// hidden build marker, for showing in the app.
    public static func sections(in body: String?) -> [(title: String, points: [String])] {
        var out: [(title: String, points: [String])] = []
        for raw in (body ?? "").components(separatedBy:.newlines) {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("## ") { out.append((String(line.dropFirst(3)),[])) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if out.isEmpty { out.append(("",[])) }
                out[out.count - 1].points.append(String(line.dropFirst(2)).replacingOccurrences(of:"**",with:""))
            }
        }
        return out.filter { !$0.points.isEmpty }
    }
    public static func build(in body: String?) -> Int? {
        guard let body else { return nil }
        let markers = body.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { $0.hasPrefix(marker) }
        guard markers.count == 1, let line = markers.first, line.hasSuffix(" -->") else { return nil }
        let digits = line.dropFirst(marker.count).dropLast(" -->".count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let build = Int(digits), build > 0 else { return nil }
        return build
    }

    public static func isNewer(_ candidate: Int, than installed: Int) -> Bool { candidate > 0 && candidate > installed }

    /// Numeric, component-wise ("1.10" is newer than "1.9"; "1.2" equals "1.2.0").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator:".").map { Int($0) ?? 0 }, y = b.split(separator:".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count,y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The release GitHub marks Latest, as a version and build Folio may install. Drafts,
    /// prereleases and releases without a valid tag or a single build marker never qualify.
    public static func latest(from data: Data) -> Choice? {
        guard let release = try? JSONDecoder().decode(Release.self,from:data), !release.draft, !release.prerelease,
              let version = version(fromTag:release.tag), let build = build(in:release.body) else { return nil }
        return Choice(release:release,version:version,build:build)
    }

    public static func asset(in release: Release, named name: String = assetName) -> Asset? {
        release.assets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Downloads are pinned to HTTPS on GitHub's own hosts, wherever the feed points.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return downloadHosts.contains(host)
    }

    /// Release notes without the build marker.
    public static func notes(_ body: String?) -> String {
        (body ?? "").replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
            .filter { !$0.trimmingCharacters(in:.whitespaces).hasPrefix(marker) }
            .joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    }

    /// Folio replaces itself only inside /Applications, where Homebrew installs it too. Disk
    /// images, Downloads and translocated copies must be moved there first.
    public static func canReplaceApp(at path: String) -> Bool {
        let path = (path as NSString).standardizingPath
        guard path.hasPrefix("/Applications/"), path.hasSuffix(".app"), !path.contains("/AppTranslocation/") else { return false }
        return path.count > "/Applications/.app".count
    }
}
