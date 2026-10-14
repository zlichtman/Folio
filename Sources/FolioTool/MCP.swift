import Foundation
import AppKit
import ShelfCore

/// A Model Context Protocol server over standard input and output (newline-delimited JSON-RPC 2.0), so an
/// assistant can search and organise the library. It can add, tag, file and note items, but never deletes.
final class MCPServer {
    private var library: Library?
    /// The library is backed up once, before an assistant's first change in a session (Settings ▸ General ▸ Backups).
    private var backedUp = false
    private static let readOnly: Set = ["search_library","get_item","view_item","list_collections","list_tags","find_similar","show_in_folio","show_search_in_folio","show_in_folio_as"]
    /// A tool result that is more than JSON text, such as a picture.
    private struct Content { let blocks: [[String:Any]] }
    private struct Tool { let name: String; let description: String; let properties: [String:Any]; let required: [String]; let run: (Library,[String:Any]) throws -> Any }
    private let tools: [Tool]

    init() {
        func strings(_ value: Any?) -> [String] { (value as? [String]) ?? (value as? String).map { [$0] } ?? [] }
        let ids: [String:Any] = ["type":"array","items":["type":"string"],"description":"Item ids (from search_library) or file paths"]
        tools = [
            Tool(name:"search_library",description:"Search the Folio library: names, tags, notes, links and text inside images. Supports filters like tag:poster, type:video, color:blue or #3a5ad9, in:\"Collection\", is:liked.",
                 properties:["query":["type":"string"],"limit":["type":"integer","description":"At most this many (default 30)"]],required:["query"]) { library, a in
                try library.search(a["query"] as? String ?? "",limit:a["limit"] as? Int ?? 30).map { library.json($0) } },
            Tool(name:"get_item",description:"Everything about one item, including the text Folio read in it.",properties:["id":["type":"string"]],required:["id"]) { library, a in
                library.json(try library.item(a["id"] as? String ?? ""),full:true) },
            Tool(name:"view_item",description:"See an item: its picture (or a video's frame, or a link's preview) as an image, with its name. Use it to look at what's in the library.",
                 properties:["id":["type":"string"],"size":["type":"integer","description":"Longest side in pixels (default 768, at most 1568)"]],required:["id"]) { library, a in
                let item = try library.item(a["id"] as? String ?? "")
                let pixels = min(1568,max(128,a["size"] as? Int ?? 768))
                guard item.path.hasPrefix("/"), let image = MediaFiles.thumbnail(url:URL(fileURLWithPath:item.path),pixels:pixels),
                      let jpeg = NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.82]) else {
                    throw NSError(domain:"Folio",code:1,userInfo:[NSLocalizedDescriptionKey:item.kind == "color" ? "A color has no picture; its value is \(item.colors.first ?? "")." : "This item has no picture to show yet."])
                }
                return Content(blocks:[["type":"image","data":jpeg.base64EncodedString(),"mimeType":"image/jpeg"],
                                       ["type":"text","text":"\(item.title) (\(item.kind), \(Int(item.width))×\(Int(item.height)))"]]) },
            Tool(name:"list_collections",description:"Collections and smart folders with their item counts.",properties:[:],required:[]) { library, _ in try library.collections() },
            Tool(name:"list_tags",description:"Tags in the library, most used first; automatic ones come from on-device image analysis.",properties:[:],required:[]) { library, _ in
                try library.db.tagCounts().prefix(300).map { ["name":$0.name,"items":$0.count,"automatic":$0.automatic] } },
            Tool(name:"add_files",description:"Add image, video, PDF or SVG files or folders to the library. Originals stay where they are.",
                 properties:["paths":["type":"array","items":["type":"string"]],"collection":["type":"string","description":"Collection to file them in (made if needed)"]],required:["paths"]) { library, a in
                ["added":try library.add(strings(a["paths"]),collection:a["collection"] as? String).count] },
            Tool(name:"add_tags",description:"Add tags to items.",properties:["ids":ids,"tags":["type":"array","items":["type":"string"]]],required:["ids","tags"]) { library, a in
                try library.tag(strings(a["ids"]),strings(a["tags"]),remove:false); return ["ok":true] },
            Tool(name:"remove_tags",description:"Remove tags from items. Automatic tags removed this way stay removed.",properties:["ids":ids,"tags":["type":"array","items":["type":"string"]]],required:["ids","tags"]) { library, a in
                try library.tag(strings(a["ids"]),strings(a["tags"]),remove:true); return ["ok":true] },
            Tool(name:"add_to_collection",description:"File items in a collection by name, making the collection if it doesn't exist.",
                 properties:["ids":ids,"collection":["type":"string"]],required:["ids","collection"]) { library, a in
                try library.collect(strings(a["ids"]),a["collection"] as? String ?? ""); return ["ok":true] },
            Tool(name:"set_note",description:"Write the note on an item (replaces the old one).",properties:["id":["type":"string"],"note":["type":"string"]],required:["id","note"]) { library, a in
                try library.db.setNote(a["note"] as? String ?? "",for:[try library.item(a["id"] as? String ?? "").id]); announceChange(); return ["ok":true] },
            Tool(name:"set_liked",description:"Like or unlike items.",properties:["ids":ids,"liked":["type":"boolean"]],required:["ids","liked"]) { library, a in
                try library.db.setLiked(try strings(a["ids"]).map { try library.item($0).id },a["liked"] as? Bool ?? true); announceChange(); return ["ok":true] },
            Tool(name:"find_similar",description:"Images that look like this one (palette, composition and style), closest first.",
                 properties:["id":["type":"string"],"limit":["type":"integer"]],required:["id"]) { library, a in
                try library.similar(a["id"] as? String ?? "",limit:a["limit"] as? Int ?? 20).map { library.json($0) } },
            Tool(name:"set_title",description:"Rename an item (its name in Folio; the file itself keeps its name).",
                 properties:["id":["type":"string"],"title":["type":"string"]],required:["id","title"]) { library, a in
                let title = (a["title"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard !title.isEmpty else { throw ToolError(message:"A name can't be empty") }
                try library.db.setTitle(title,for:[try library.item(a["id"] as? String ?? "").id]); announceChange(); return ["ok":true] },
            Tool(name:"rename_collection",description:"Rename a collection or smart folder.",
                 properties:["collection":["type":"string","description":"Its current name or id"],"name":["type":"string"]],required:["collection","name"]) { library, a in
                let key = a["collection"] as? String ?? "", name = (a["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard let found = try library.db.collections().first(where:{ $0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame }) else { throw ToolError(message:"No collection called \(key)") }
                try library.db.renameCollection(found.id,to:name); announceChange(); return ["id":found.id,"name":name] },
            Tool(name:"rename_tag",description:"Rename a tag on every item that has it (merging into an existing tag of that name).",
                 properties:["tag":["type":"string"],"name":["type":"string"]],required:["tag","name"]) { library, a in
                let states = try library.db.renameTag(a["tag"] as? String ?? "",to:a["name"] as? String ?? "")
                announceChange(); return ["items":states.count] },
            Tool(name:"show_in_folio",description:"Bring Folio to the front with this item selected.",properties:["id":["type":"string"]],required:["id"]) { library, a in
                try library.open(a["id"] as? String ?? ""); return ["ok":true] },
            Tool(name:"show_search_in_folio",description:"Bring Folio to the front showing a search (same syntax as search_library).",
                 properties:["query":["type":"string"]],required:["query"]) { _, a in
                var parts = URLComponents(string:"folio://search")!; parts.queryItems = [URLQueryItem(name:"q",value:a["query"] as? String ?? "")]
                if let url = parts.url { NSWorkspace.shared.open(url) }; return ["ok":true] },
            Tool(name:"show_in_folio_as",description:"Bring Folio to the front showing a place from its sidebar (a collection, smart folder, tag or watched folder, by name) in a layout: rows, columns, board, list or infinity. Either may be left out.",
                 properties:["place":["type":"string"],"layout":["type":"string","enum":["rows","columns","board","list","infinity"]]],required:[]) { _, a in
                var parts = URLComponents(string:"folio://show")!
                parts.queryItems = [("place",a["place"] as? String),("layout",a["layout"] as? String)].compactMap { name, value in value.map { URLQueryItem(name:name,value:$0) } }
                if let url = parts.url { NSWorkspace.shared.open(url) }; return ["ok":true] },
            Tool(name:"save_link",description:"Save a web address as a link card; Folio fills in its title and preview when it's open.",
                 properties:["url":["type":"string"],"title":["type":"string"],"collection":["type":"string","description":"Collection to file it in (made if needed)"]],required:["url"]) { library, a in
                guard let raw = a["url"] as? String, let url = URL(string:raw), url.scheme?.hasPrefix("http") == true else { throw ToolError(message:"That isn't a web address") }
                let link = ShelfItem.link(url:url.absoluteString,title:a["title"] as? String ?? "",source:url.absoluteString)
                let into = try (a["collection"] as? String).flatMap { try library.db.collection(named:$0,createIfMissing:true)?.id }
                let ids = try library.db.insert([link],into:into); announceChange(); return ["saved":ids.count,"id":ids.first ?? link.id] },
            Tool(name:"save_color",description:"Keep a color as a swatch in Colors.",
                 properties:["hex":["type":"string","description":"#rrggbb or #rgb"],"title":["type":"string"],"collection":["type":"string"]],required:["hex"]) { library, a in
                guard let swatch = ShelfItem.color(a["hex"] as? String ?? "",title:a["title"] as? String) else { throw ToolError(message:"That isn't a color") }
                let into = try (a["collection"] as? String).flatMap { try library.db.collection(named:$0,createIfMissing:true)?.id }
                try library.db.insert([swatch],into:into); announceChange(); return ["id":swatch.id] },
            Tool(name:"create_collection",description:"Make a collection, optionally inside another (by name).",
                 properties:["name":["type":"string"],"parent":["type":"string"]],required:["name"]) { library, a in
                let parent = try (a["parent"] as? String).flatMap { try library.db.collection(named:$0)?.id }
                let made = try library.db.createCollection(name:a["name"] as? String ?? "",parent:parent); announceChange(); return ["id":made.id,"name":made.name] },
            Tool(name:"create_smart_folder",description:"""
                Make a smart folder that fills itself. rules: [{field, op, value}]. Fields: kind (image, video, gif, link, color), ext, tag, name, text,                 color, added (days), created (days), width, height, size (MB), duration (seconds), orientation (landscape, portrait, square), liked,                 untagged, hasText (true/false), domain, collection (id), folder (id). Ops: is, isNot, contains, notContains, begins, greater, less,                 within, notWithin. match: all (default) or any.
                """,
                 properties:["name":["type":"string"],"match":["type":"string"],"rules":["type":"array","items":["type":"object"]]],required:["name","rules"]) { library, a in
                let rules = try ((a["rules"] as? [[String:Any]]) ?? []).map { rule -> SmartRule in
                    guard let field = SmartRule.Field(rawValue:rule["field"] as? String ?? ""), let op = SmartRule.Op(rawValue:rule["op"] as? String ?? "is") else {
                        throw ToolError(message:"Unknown field or op in \(rule)") }
                    return SmartRule(field,op,"\(rule["value"] ?? "true")")
                }
                guard !rules.isEmpty else { throw ToolError(message:"A smart folder needs at least one rule") }
                let match = SmartRules.Match(rawValue:a["match"] as? String ?? "all") ?? .all
                let made = try library.db.createCollection(name:a["name"] as? String ?? "",kind:.smart,rules:SmartRules(match:match,rules:rules))
                announceChange(); return ["id":made.id,"items":try library.db.count(rules:SmartRules(match:match,rules:rules))] },
            Tool(name:"remove_from_collection",description:"Take items out of a collection (by name). The items stay in the library.",
                 properties:["ids":ids,"collection":["type":"string"]],required:["ids","collection"]) { library, a in
                guard let collection = try library.db.collection(named:a["collection"] as? String ?? "") else { throw ToolError(message:"No collection by that name") }
                try library.db.removeItems(try strings(a["ids"]).map { try library.item($0).id },from:collection.id); announceChange(); return ["ok":true] },
            Tool(name:"set_author",description:"Credit who made items.",properties:["ids":ids,"author":["type":"string"]],required:["ids","author"]) { library, a in
                try library.db.setAuthor(a["author"] as? String ?? "",for:try strings(a["ids"]).map { try library.item($0).id }); announceChange(); return ["ok":true] },
            Tool(name:"set_source",description:"Set the web page items came from.",properties:["ids":ids,"url":["type":"string"]],required:["ids","url"]) { library, a in
                try library.db.setSource(a["url"] as? String ?? "",for:try strings(a["ids"]).map { try library.item($0).id }); announceChange(); return ["ok":true] },
        ]
    }

    func run() {
        while let line = readLine(strippingNewline:true) {
            guard let data = line.data(using:.utf8), let message = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { continue }
            let id = message["id"], method = message["method"] as? String ?? ""
            guard id != nil else { continue } // notifications need no answer
            do { send(["jsonrpc":"2.0","id":id!,"result":try handle(method,message["params"] as? [String:Any] ?? [:])]) }
            catch let error as RPCError { send(["jsonrpc":"2.0","id":id!,"error":["code":error.code,"message":error.message]]) }
            catch { send(["jsonrpc":"2.0","id":id!,"error":["code":-32603,"message":error.localizedDescription]]) }
        }
    }
    private struct RPCError: Error { let code: Int; let message: String }
    private func handle(_ method: String, _ params: [String:Any]) throws -> Any {
        switch method {
        case "initialize":
            return ["protocolVersion":params["protocolVersion"] as? String ?? "2025-06-18","capabilities":["tools":["listChanged":false]],
                    "serverInfo":["name":"folio","version":"1"],
                    "instructions":"Folio is the user's visual library on this Mac. Search it, look at and read items, tag them and file them in collections. Changes show in the Folio app right away, and the library is backed up before the first one. Nothing here deletes anything."]
        case "ping": return [String:Any]()
        case "tools/list":
            return ["tools":tools.map { ["name":$0.name,"description":$0.description,
                                         "inputSchema":["type":"object","properties":$0.properties,"required":$0.required]] }]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where:{ $0.name == name }) else { throw RPCError(code:-32602,message:"Unknown tool") }
            do {
                if library == nil { library = try Library() }
                if !backedUp, !Self.readOnly.contains(name) { _ = try? library!.db.snapshot(before:"Assistant changes"); backedUp = true }
                let value = try tool.run(library!,params["arguments"] as? [String:Any] ?? [:])
                if let content = value as? Content { return ["content":content.blocks] }
                let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
                return ["content":[["type":"text","text":String(decoding:data,as:UTF8.self)]]]
            } catch {
                return ["content":[["type":"text","text":error.localizedDescription]],"isError":true]
            }
        default: throw RPCError(code:-32601,message:"Method not found: \(method)")
        }
    }
    private func send(_ value: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:value,options:[.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
