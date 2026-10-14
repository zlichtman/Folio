import Foundation
import CryptoKit

public struct ShelfItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var title: String
    public var kind: String
    public var ext: String
    /// The page an item was saved from.
    public var source: String
    /// A link's target, or where downloaded media came from.
    public var url: String
    public var site: String
    public var author: String
    public var tags: [String]
    /// Machine tags, kept apart from `tags`.
    public var autoTags: [String]
    public var note: String
    /// Recognized text. Listings leave it empty; `LibraryDatabase.item(id:)` loads it.
    public var ocr: String
    /// What the Mac's own model sees in the picture: a sentence, then keywords. Searchable; `item(id:)` loads it.
    public var seen = ""
    public var hasText: Bool
    public var colors: [String]
    public var added: Double
    public var fileDate: Double
    public var fileSize: Int64
    public var width: Double
    public var height: Double
    public var duration: Double
    public var liked: Bool
    public var trashed: Double?
    public var missing: Bool
    public var folder: String?
    public var position: Double
    /// Ids of the collections the item is directly in.
    public var collections: [String]

    public init(id: String? = nil, path: String, title: String? = nil, kind: String = "image", ext: String? = nil,
                source: String = "", url: String = "", site: String? = nil, author: String = "",
                tags: [String] = [], autoTags: [String] = [], note: String = "", ocr: String = "", colors: [String] = [],
                added: Double = Date().timeIntervalSince1970, fileDate: Double = 0, fileSize: Int64 = 0,
                width: Double = 0, height: Double = 0, duration: Double = 0, liked: Bool = false, trashed: Double? = nil,
                missing: Bool = false, folder: String? = nil, position: Double = 0, collections: [String] = []) {
        let file = path.hasPrefix("/")
        self.path = path
        self.id = id ?? Self.digest(path)
        self.title = title ?? (file ? URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent : path)
        self.kind = kind
        self.ext = ext ?? (file ? URL(fileURLWithPath:path).pathExtension.lowercased() : "")
        self.source = source; self.url = url
        self.site = site ?? Self.site(url.isEmpty ? source : url)
        self.author = author
        self.tags = Tags.clean(tags); self.autoTags = Tags.clean(autoTags)
        self.note = note; self.ocr = ocr; self.hasText = !ocr.isEmpty
        self.colors = colors; self.added = added; self.fileDate = fileDate; self.fileSize = fileSize
        self.width = width; self.height = height; self.duration = duration
        self.liked = liked; self.trashed = trashed; self.missing = missing; self.folder = folder
        self.position = position; self.collections = collections
    }
    /// A saved web link. `preview` is a local image of the page, when there is one.
    public static func link(url: String, title: String = "", site: String? = nil, preview: String? = nil, source: String = "",
                            added: Double = Date().timeIntervalSince1970) -> ShelfItem {
        let host = site ?? Self.site(url)
        return ShelfItem(id:digest("link|" + url), path:preview ?? url, title:title.isEmpty ? (host.isEmpty ? url : host) : title,
                         kind:"link", ext:"", source:source, url:url, site:host, added:added)
    }
    /// A saved colour swatch; nil when `hex` isn't a colour.
    public static func color(_ hex: String, title: String? = nil, added: Double = Date().timeIntervalSince1970) -> ShelfItem? {
        guard let value = ColorMath.hex(hex) else { return nil }
        return ShelfItem(id:digest("color|" + value), path:"color:" + value, title:title ?? value, kind:"color", ext:"",
                         colors:[value], added:added)
    }
    public var isTrashed: Bool { trashed != nil }
    /// Has a picture Find Similar can compare: an image, a video's frame, a GIF or a link's preview.
    public var hasLook: Bool { ["image","video","gif","link"].contains(kind) && path.hasPrefix("/") }
    public static func site(_ url: String) -> String {
        guard let host = URL(string:url)?.host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    public static func digest(_ string: String) -> String {
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding:SHA256.hash(data:Data(string.utf8)).flatMap { [hex[Int($0 >> 4)],hex[Int($0 & 15)]] },as:UTF8.self)
    }
}

/// Tags are free text and may contain spaces. Stored unit-separator delimited, with a separator at each end.
public enum Tags {
    static let separator = "\u{1F}"
    /// Trims, collapses inner whitespace and drops case-insensitive duplicates, keeping the first spelling.
    public static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for tag in tags {
            let value = tag.split(whereSeparator:{ $0.isWhitespace || $0 == "\u{1F}" }).joined(separator:" ")
            if !value.isEmpty, seen.insert(value.lowercased()).inserted { out.append(value) }
        }
        return out
    }
    /// Splits typed input on commas and line breaks; spaces stay inside a tag.
    public static func parse(_ text: String) -> [String] {
        clean(text.components(separatedBy:CharacterSet(charactersIn:",\n")))
    }
    static func encode(_ tags: [String]) -> String { tags.isEmpty ? "" : separator + tags.joined(separator:separator) + separator }
    static func decode(_ value: String) -> [String] { value.split(separator:"\u{1F}").map(String.init) }
    static func contains(_ tags: [String], _ tag: String) -> Bool { tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    /// SQLite's lower() folds ASCII only, so match keys fold the same way.
    static func key(_ tag: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in tag.unicodeScalars { scalars.append(s.value >= 65 && s.value <= 90 ? Unicode.Scalar(s.value + 32)! : s) }
        return separator + String(scalars) + separator
    }
}

public struct ShelfCollection: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case collection, smart }
    public var id: String
    public var name: String
    public var parent: String?
    public var kind: Kind
    public var rules: SmartRules?
    public var position: Double
    public var created: Double
    public var archived: Bool
    public var isSmart: Bool { kind == .smart }
    public init(id: String = UUID().uuidString, name: String, parent: String? = nil, kind: Kind = .collection, rules: SmartRules? = nil,
                position: Double = 0, created: Double = Date().timeIntervalSince1970, archived: Bool = false) {
        self.id = id; self.name = name; self.parent = parent; self.kind = kind; self.rules = rules
        self.position = position; self.created = created; self.archived = archived
    }
}

/// A sidebar row. `count` covers live items, including those in child collections.
public struct CollectionNode: Equatable, Sendable, Identifiable {
    public var collection: ShelfCollection
    public var count: Int
    public var children: [CollectionNode]
    public var id: String { collection.id }
}

public struct Membership: Codable, Equatable, Sendable {
    public var item: String
    public var collection: String
    public var position: Double
    public var added: Double
}

/// Everything a user can edit on an item; `LibraryDatabase.restore(_:)` puts it back.
public struct ItemState: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var note: String
    public var author: String
    public var tags: [String]
    public var autoTags: [String]
    public var rejectedTags: [String]
    public var liked: Bool
    public var trashed: Double?
    public var position: Double
    public var memberships: [Membership]
    /// The page the item came from.
    public var source = ""
}

/// Prior state of collections touched by an edit, for undo via `LibraryDatabase.restore(_:)`.
public struct CollectionArchive: Codable, Equatable, Sendable {
    /// Parents come before their children.
    public var collections: [ShelfCollection] = []
    public var memberships: [Membership] = []
    /// Connected folder id to the collection it filed into.
    public var folders: [String:String] = [:]
}

public struct ConnectedFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var collection: String?
    public var added: Double
    public var lastScan: Double?
}

/// Item ids changed by `LibraryDatabase.applyScan(folderID:found:)`.
public struct ScanChanges: Equatable, Sendable {
    public var added: [String] = []
    public var updated: [String] = []
    /// Files that were renamed or moved inside the folder; their tags and notes are kept.
    public var moved: [String] = []
    /// Files no longer in the folder. They are marked missing and moved to the trash, or only marked missing while
    /// the folder can't be reached.
    public var removed: [String] = []
}
