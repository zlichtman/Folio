import Foundation

/// A library from another app, read into folders and items before it joins Folio.
public struct ImportedLibrary: Sendable {
    public struct Folder: Sendable { public var id: String; public var name: String; public var children: [Folder] }
    public struct Item: Sendable {
        public var file: URL
        public var title: String
        public var tags: [String]
        public var note: String
        public var source: String
        public var added: Double
        public var folders: [String]
    }
    public enum Format: Sendable { case eagle, folders }
    public var name: String
    public var format: Format
    public var folders: [Folder]
    public var items: [Item]
    /// Files the other app manages are copied into Folio; a plain folder's files stay where they are.
    public var copiesFiles: Bool { format == .eagle }
}

public enum LibraryImport {
    /// An Eagle library: a `.library` folder with `metadata.json` and an `images` folder of `.info` folders.
    public static func isEagle(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath:url.appendingPathComponent("metadata.json").path)
            && manager.fileExists(atPath:url.appendingPathComponent("images").path)
    }
    public static func read(_ url: URL) throws -> ImportedLibrary {
        isEagle(url) ? try readEagle(url) : readFolders(url)
    }

    static func readEagle(_ url: URL) throws -> ImportedLibrary {
        func json(_ file: URL) -> [String:Any]? {
            (try? Data(contentsOf:file)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        }
        func folders(_ list: Any?) -> [ImportedLibrary.Folder] {
            ((list as? [[String:Any]]) ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, let name = (entry["name"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines), !name.isEmpty else { return nil }
                return .init(id:id,name:name,children:folders(entry["children"]))
            }
        }
        guard let root = json(url.appendingPathComponent("metadata.json")) else { throw CocoaError(.fileReadCorruptFile) }
        var items: [ImportedLibrary.Item] = []
        let images = url.appendingPathComponent("images")
        let entries = (try? FileManager.default.contentsOfDirectory(at:images,includingPropertiesForKeys:nil)) ?? []
        for info in entries.sorted(by:{ $0.lastPathComponent < $1.lastPathComponent }) where info.pathExtension == "info" {
            guard let meta = json(info.appendingPathComponent("metadata.json")), meta["isDeleted"] as? Bool != true,
                  let ext = (meta["ext"] as? String)?.lowercased(), !ext.isEmpty else { continue }
            let name = meta["name"] as? String ?? ""
            // The original sits beside Eagle's own `_thumbnail.png`.
            let files = (try? FileManager.default.contentsOfDirectory(at:info,includingPropertiesForKeys:nil)) ?? []
            let expected = info.appendingPathComponent("\(name).\(ext)")
            guard let file = files.first(where:{ $0.lastPathComponent == expected.lastPathComponent })
                    ?? files.first(where:{ $0.pathExtension.lowercased() == ext && !$0.deletingPathExtension().lastPathComponent.hasSuffix("_thumbnail") }),
                  MediaFiles.kind(file) != nil else { continue }
            let added = (meta["btime"] as? Double ?? meta["modificationTime"] as? Double).map { $0 / 1000 } ?? Date().timeIntervalSince1970
            items.append(.init(file:file,title:name.isEmpty ? file.deletingPathExtension().lastPathComponent : name,
                               tags:meta["tags"] as? [String] ?? [],note:meta["annotation"] as? String ?? "",
                               source:meta["url"] as? String ?? "",added:added,folders:meta["folders"] as? [String] ?? []))
        }
        return ImportedLibrary(name:url.deletingPathExtension().lastPathComponent,format:.eagle,folders:folders(root["folders"]),items:items)
    }

    /// Any folder: each folder inside becomes a collection, nested the same way.
    static func readFolders(_ url: URL) -> ImportedLibrary {
        var items: [ImportedLibrary.Item] = []
        func walk(_ folder: URL, id: String?) -> [ImportedLibrary.Folder] {
            let entries = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants])) ?? []
            var children: [ImportedLibrary.Folder] = []
            for entry in entries.sorted(by:{ $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? entry.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    let childID = entry.standardizedFileURL.path
                    children.append(.init(id:childID,name:entry.lastPathComponent,children:walk(entry,id:childID)))
                } else if MediaFiles.kind(entry) != nil {
                    items.append(.init(file:entry,title:entry.deletingPathExtension().lastPathComponent,tags:[],note:"",source:"",
                                       added:Date().timeIntervalSince1970,folders:id.map { [$0] } ?? []))
                }
            }
            return children
        }
        let folders = walk(url,id:nil)
        return ImportedLibrary(name:url.lastPathComponent,format:.folders,folders:folders,items:items)
    }
}

extension LibraryDatabase {
    public struct ImportResult: Sendable { public var collection: String; public var added: Int; public var updated: Int }
    /// Brings a library in as a collection named after it, its folders nested inside. Importing the same library again
    /// fills in that collection rather than making another, and adds tags without taking any away.
    public func importLibrary(_ library: ImportedLibrary, tags keepTags: Bool = true, sources keepSources: Bool = true,
                              progress: ((Int) -> Void)? = nil) throws -> ImportResult {
        let existing = try collections().filter { !$0.isSmart }
        let root = try existing.first { $0.parent == nil && $0.name.caseInsensitiveCompare(library.name) == .orderedSame }
            ?? createCollection(name:library.name)
        var mapped: [String:String] = [:]
        func place(_ folders: [ImportedLibrary.Folder], under parent: String) throws {
            let siblings = try collections().filter { $0.parent == parent && !$0.isSmart }
            for folder in folders {
                let collection = try siblings.first { $0.name.caseInsensitiveCompare(folder.name) == .orderedSame } ?? createCollection(name:folder.name,parent:parent)
                mapped[folder.id] = collection.id
                try place(folder.children,under:collection.id)
            }
        }
        try place(library.folders,under:root.id)

        var copied = mediaFolder.appendingPathComponent("Imported",isDirectory:true)
        copied.appendPathComponent(library.name,isDirectory:true)
        if library.copiesFiles { try FileManager.default.createDirectory(at:copied,withIntermediateDirectories:true) }
        var added = 0, updated = 0
        for (offset,chunk) in stride(from:0,to:library.items.count,by:200).enumerated() {
            let slice = library.items[chunk..<min(chunk + 200,library.items.count)]
            var batch: [ShelfItem] = []
            for entry in slice {
                var file = entry.file
                if library.copiesFiles {
                    // Named after the source's own folder so a second import finds the same copy. On APFS this is a clone.
                    let target = copied.appendingPathComponent(entry.file.deletingLastPathComponent().deletingPathExtension().lastPathComponent + "-" + entry.file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath:target.path) { try FileManager.default.copyItem(at:entry.file,to:target) }
                    file = target
                }
                guard var item = MediaFiles.scan([file]).first else { continue }
                item.title = entry.title; item.added = entry.added
                if keepTags { item.tags = Tags.clean(entry.tags) }
                if keepSources { item.note = entry.note; item.source = entry.source; item.site = ShelfItem.site(entry.source) }
                let homes = entry.folders.compactMap { mapped[$0] }
                item.collections = homes.isEmpty ? [root.id] : homes
                batch.append(item)
            }
            let before = Set(try sync { try strings("SELECT id FROM items WHERE path IN \(Self.each)",[list(batch.map(\.path))]) })
            let ids = try insert(batch)
            for (item,id) in zip(batch,ids) {
                if before.contains(id) {
                    updated += 1
                    if keepTags, !item.tags.isEmpty { try addTags(item.tags,to:[id]) }
                    for collection in item.collections { try addItems([id],to:collection) }
                } else { added += 1 }
            }
            progress?(min(library.items.count,(offset + 1) * 200))
        }
        return ImportResult(collection:root.id,added:added,updated:updated)
    }
}

extension LibraryDatabase {
    /// Puts items into another library with their tags, notes, likes and source. Files this library keeps (in its
    /// media folder) are copied into the other's, so nothing there points back here; other files are shared as they are.
    /// Returns the ids of the items that arrived (existing ones are left as they were).
    @discardableResult public func copy(_ ids: [String], to other: LibraryDatabase) throws -> [String] {
        let media = mediaFolder.standardizedFileURL.path + "/"
        var items: [ShelfItem] = []
        for id in ids {
            guard var item = try item(id:id) else { continue }
            if item.path.hasPrefix(media) {
                try FileManager.default.createDirectory(at:other.mediaFolder,withIntermediateDirectories:true)
                var target = other.mediaFolder.appendingPathComponent(URL(fileURLWithPath:item.path).lastPathComponent)
                if FileManager.default.fileExists(atPath:target.path) { target = other.mediaFolder.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + target.lastPathComponent) }
                try FileManager.default.copyItem(atPath:item.path,toPath:target.path)
                item.path = target.path; item.id = ShelfItem.digest(target.path)
            }
            item.collections = []; item.trashed = nil
            items.append(item)
        }
        return try other.insert(items)
    }
    /// Copies a collection to another library: everything in it (and in collections inside it) lands there in a
    /// collection of the same name. Returns its name, how many items went, and which of them belong to nothing else
    /// here, so a move can take those out of this library.
    @discardableResult public func copyCollection(_ id: String, to other: LibraryDatabase) throws -> (name: String, count: Int, onlyHere: [String]) {
        guard let collection = try collection(id:id) else { throw LibraryError.collectionNotFound }
        guard !collection.isSmart else { throw LibraryError.smartCollection }
        let items = try self.items(scope:.collection(id))
        guard let target = try other.collection(named:collection.name,createIfMissing:true) else { throw LibraryError.collectionNotFound }
        let arrived = try copy(items.map(\.id),to:other)
        if !arrived.isEmpty { try other.addItems(arrived,to:target.id) }
        return (collection.name,items.count,try itemsOnly(in:id))
    }
    /// Items in a collection (or the collections inside it) that no other collection holds.
    public func itemsOnly(in id: String) throws -> [String] {
        var subtree = Set<String>()
        func walk(_ nodes: [CollectionNode], inside: Bool) {
            for node in nodes {
                let here = inside || node.id == id
                if here { subtree.insert(node.id) }
                walk(node.children,inside:here)
            }
        }
        walk(try collectionTree(),inside:false)
        return try items(scope:.collection(id)).filter { Set($0.collections).isSubset(of:subtree) }.map(\.id)
    }
}
