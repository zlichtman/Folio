import Foundation
import AppKit
import Vision
import ShelfCore

// `folio`: the library from Terminal and scripts, and `folio mcp`, a Model Context Protocol server for assistants.
// It opens the same library as the app (SQLite in WAL mode, so both can run at once) and tells the app to reload
// after every change.

let usage = """
folio: your Folio library from the command line.

  folio search <words> [--limit N] [--json]    find items (same search as the app, filters like tag: and type: work)
  folio show <id>                               everything about one item, as JSON
  folio add <files or folders…> [--collection NAME]
  folio tag <id…> --tags "a, b"                 add tags     (folio untag <id…> --tags "a" removes them)
  folio collections                             list collections with their item counts
  folio collect <id…> --collection NAME         add items to a collection, making it if needed
  folio similar <id> [--limit N]                images that look like this one
  folio open <id>                               show the item in Folio
  folio mcp                                     run as an MCP server on standard input and output

The library is the one open in Folio (File ▸ Library); FOLIO_LIBRARY points elsewhere.
"""

func libraryRoot() -> URL {
    if let custom = ProcessInfo.processInfo.environment["FOLIO_LIBRARY"] { return URL(fileURLWithPath:custom,isDirectory:true) }
    // Follow the library Folio has open.
    if let chosen = UserDefaults(suiteName:"org.lumashelf.app")?.string(forKey:"library.current"), FileManager.default.fileExists(atPath:chosen) {
        return URL(fileURLWithPath:chosen,isDirectory:true)
    }
    let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    let folio = support.appendingPathComponent("Folio",isDirectory:true), legacy = support.appendingPathComponent("LumaShelf",isDirectory:true)
    return FileManager.default.fileExists(atPath:folio.path) || !FileManager.default.fileExists(atPath:legacy.path) ? folio : legacy
}
/// Tells a running Folio to reload.
func announceChange() {
    DistributedNotificationCenter.default().postNotificationName(.init("org.lumashelf.library-changed"),object:nil,userInfo:nil,deliverImmediately:true)
}
struct ToolError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class Library {
    let db: LibraryDatabase
    init() throws { db = try LibraryDatabase(root:libraryRoot()) }
    lazy var names: [String:String] = Dictionary(((try? db.collections()) ?? []).map { ($0.id,$0.name) },uniquingKeysWith:{ a,_ in a })
    func json(_ item: ShelfItem, full: Bool = false) -> [String:Any] {
        var out: [String:Any] = ["id":item.id,"title":item.title,"kind":item.kind,"tags":item.tags,"automaticTags":item.autoTags,
                                 "collections":item.collections.compactMap { names[$0] },"liked":item.liked,
                                 "added":ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:item.added))]
        if item.path.hasPrefix("/") { out["path"] = item.path }
        if !item.url.isEmpty { out["url"] = item.url }
        if !item.note.isEmpty { out["note"] = item.note }
        if item.width > 0 { out["width"] = Int(item.width); out["height"] = Int(item.height) }
        if !item.colors.isEmpty { out["colors"] = item.colors }
        if full, let detail = try? db.item(id:item.id), !detail.ocr.isEmpty { out["textInImage"] = detail.ocr }
        return out
    }
    func item(_ id: String) throws -> ShelfItem {
        if let found = try db.item(id:id) { return found }
        // A file path works too.
        let path = URL(fileURLWithPath:id).standardizedFileURL.resolvingSymlinksInPath().path
        if let found = try db.items(query:"").first(where:{ $0.path == path }) { return found }
        throw ToolError(message:"No item \(id)")
    }
    func search(_ query: String, limit: Int) throws -> [ShelfItem] { try db.items(query:query,limit:limit) }
    func add(_ paths: [String], collection: String?) throws -> [String] {
        let urls = paths.map { URL(fileURLWithPath:($0 as NSString).expandingTildeInPath) }
        let target = try collection.flatMap { try db.collection(named:$0,createIfMissing:true)?.id }
        var added: [String] = []
        for group in MediaFiles.scanGroups(urls) {
            let into = try target ?? group.group.flatMap { try db.collection(named:$0,createIfMissing:true)?.id }
            added += try db.insert(group.items,into:into)
        }
        announceChange(); return added
    }
    func tag(_ ids: [String], _ tags: [String], remove: Bool) throws {
        let resolved = try ids.map { try item($0).id }
        if remove { try db.removeTags(tags,from:resolved) } else { try db.addTags(tags,to:resolved) }
        announceChange()
    }
    func collect(_ ids: [String], _ name: String) throws {
        guard let collection = try db.collection(named:name,createIfMissing:true) else { throw ToolError(message:"Can't use \(name) as a collection") }
        try db.addItems(try ids.map { try item($0).id },to:collection.id)
        announceChange()
    }
    func collections() throws -> [[String:Any]] {
        var out: [[String:Any]] = []
        func walk(_ nodes: [CollectionNode], _ path: String) {
            for node in nodes where !node.collection.archived {
                let name = path.isEmpty ? node.collection.name : path + " / " + node.collection.name
                out.append(["id":node.id,"name":name,"items":node.count,"smart":node.collection.isSmart])
                walk(node.children,name)
            }
        }
        walk(try db.collectionTree(),"")
        return out
    }
    func similar(_ id: String, limit: Int) throws -> [ShelfItem] {
        let target = try item(id)
        var prints = Dictionary(uniqueKeysWithValues:try db.featurePrints(version:VisualSimilarity.version).compactMap { entry in
            VisualSimilarity.observation(entry.data).map { (entry.id,$0) } })
        if prints[target.id] == nil, target.path.hasPrefix("/") {
            let data = try VisualSimilarity.featurePrint(url:URL(fileURLWithPath:target.path))
            try db.saveFeaturePrint(id:target.id,version:VisualSimilarity.version,data:data); prints[target.id] = VisualSimilarity.observation(data)
        }
        return try VisualSimilarity.nearest(to:target.id,in:prints,limit:limit).compactMap { try db.item(id:$0.id) }
    }
    func open(_ id: String) throws {
        let target = try item(id)
        guard let url = URL(string:"folio://item/\(target.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: Command line

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of:name), i + 1 < args.count else { return nil }
    let value = args[i+1]; args.removeSubrange(i...(i+1)); return value
}
func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])) ?? Data()
    print(String(decoding:data,as:UTF8.self))
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
if command == "mcp" { MCPServer().run(); exit(0) }
do {
    let library = try Library()
    let asJSON = args.contains("--json"); args.removeAll { $0 == "--json" }
    let limit = Int(option("--limit",in:&args) ?? "") ?? 50
    switch command {
    case "search":
        let found = try library.search(args.joined(separator:" "),limit:limit)
        if asJSON { printJSON(found.map { library.json($0) }) }
        else { for item in found { print("\(item.id.prefix(12))  \(item.title)\(item.tags.isEmpty ? "" : "  #" + item.tags.joined(separator:" #"))") } }
    case "show": printJSON(library.json(try library.item(args.first ?? ""),full:true))
    case "add":
        let collection = option("--collection",in:&args)
        let added = try library.add(args,collection:collection)
        print(added.count == 1 ? "Added 1 item" : "Added \(added.count) items")
    case "tag", "untag":
        let tags = Tags.parse(option("--tags",in:&args) ?? "")
        guard !tags.isEmpty, !args.isEmpty else { throw ToolError(message:"Usage: folio \(command) <id…> --tags \"a, b\"") }
        try library.tag(args,tags,remove:command == "untag"); print(command == "tag" ? "Tagged \(args.count)" : "Untagged \(args.count)")
    case "collections":
        let list = try library.collections()
        if asJSON { printJSON(list) } else { for c in list { print("\(c["name"]!)  (\(c["items"]!))") } }
    case "collect":
        guard let name = option("--collection",in:&args), !args.isEmpty else { throw ToolError(message:"Usage: folio collect <id…> --collection NAME") }
        try library.collect(args,name); print("Added \(args.count) to \(name)")
    case "similar":
        let found = try library.similar(args.first ?? "",limit:limit)
        if found.isEmpty, !asJSON { print("Nothing looks like this yet. Folio works out look-alikes in the background as it sorts your images.") }
        if asJSON { printJSON(found.map { library.json($0) }) } else { for item in found { print("\(item.id.prefix(12))  \(item.title)") } }
    case "open": try library.open(args.first ?? "")
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("folio: \(error.localizedDescription)\n".utf8)); exit(1)
}
