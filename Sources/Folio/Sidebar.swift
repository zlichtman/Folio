import AppKit
import ShelfCore

/// One sidebar line: a section header or a place in the library.
struct SidebarRow {
    enum Kind { case header, library, smart, collection, folder, tag, prompt }
    var kind: Kind
    var title: String
    var symbol = ""
    var count = 0
    var scope: Scope = .all
    var id: String?
    var depth = 0
    var archived = false
    /// The collection this one sits inside.
    var parent: String?
    static func header(_ title: String) -> Self { .init(kind:.header,title:title) }
}

extension AppController {
    /// Builds the rows: the library, smart folders that have items, collections (nested), then watched folders.
    /// `subfolders` holds the directories shown open, by the directory they sit in.
    func sidebarRows(tree: [CollectionNode], folders: [ConnectedFolder], counts: [Scope:Int], tags: [(name: String, count: Int, automatic: Bool)],
                     subfolders: [String:[(path: String, count: Int)]] = [:]) -> [SidebarRow] {
        // Another library than the main one is named at the top, so it's clear which one is open.
        var rows: [SidebarRow] = database.root.standardizedFileURL == LibraryLocation.folder.standardizedFileURL || argument("--library") != nil ? [] :
            [.init(kind:.header,title:LibraryLocation.name(database.root),id:"library")]
        rows += [
            .init(kind:.library,title:"All Items",symbol:"square.grid.2x2",count:counts[.all] ?? 0,scope:.all),
            .init(kind:.library,title:"Inbox",symbol:"tray",count:counts[.inbox] ?? 0,scope:.inbox),
            .init(kind:.library,title:"Liked",symbol:"heart",count:counts[.liked] ?? 0,scope:.liked),
            .init(kind:.library,title:"Trash",symbol:"trash",count:counts[.trash] ?? 0,scope:.trash)]
        let smart = ordered(tree.filter { $0.collection.isSmart && !$0.collection.archived && ($0.count > 0 || showsEmptySmartFolders) },"Smart Folders")
        if !smart.isEmpty {
            rows.append(.header("Smart Folders"))
            rows += smart.map { .init(kind:.smart,title:$0.collection.name,symbol:Self.smartSymbol($0.collection.name),count:$0.count,scope:.collection($0.id),id:$0.id) }
        }
        var collections: [SidebarRow] = []
        func add(_ node: CollectionNode, _ depth: Int) {
            guard !node.collection.archived || showsArchived else { return }
            collections.append(.init(kind:node.collection.isSmart ? .smart : .collection,title:node.collection.name,
                                     symbol:node.collection.archived ? "archivebox" : node.collection.isSmart ? Self.smartSymbol(node.collection.name) : "rectangle.stack",
                                     count:node.count,scope:.collection(node.id),id:node.id,depth:depth,archived:node.collection.archived,parent:node.collection.parent))
            ordered(node.children,"Collections").forEach { add($0,depth+1) }
        }
        ordered(tree.filter { !$0.collection.isSmart },"Collections").forEach { add($0,0) }
        rows.append(.header("Collections"))
        rows += collections
        // A first collection is one click away rather than a header over nothing.
        if collections.isEmpty { rows.append(.init(kind:.prompt,title:"New Collection",symbol:"plus")) }
        if !folders.isEmpty {
            rows.append(.header("Folders"))
            let saved = UserDefaults.standard.stringArray(forKey:"sidebar.order.Folders") ?? []
            let sortedFolders = sidebarSort("Folders") == "name"
                ? folders.sorted { FolderWatcher.displayName($0.path).localizedStandardCompare(FolderWatcher.displayName($1.path)) == .orderedAscending }
                : folders.sorted { (saved.firstIndex(of:$0.id) ?? Int.max) < (saved.firstIndex(of:$1.id) ?? Int.max) }
            for folder in sortedFolders {
                // A folder on a drive that isn't plugged in says so; its items wait, marked missing, until it's back.
                let offline = !FileManager.default.fileExists(atPath:folder.path)
                rows.append(.init(kind:.folder,title:FolderWatcher.displayName(folder.path),symbol:offline ? "externaldrive.badge.xmark" : "folder",
                                  count:counts[.folder(folder.id)] ?? 0,scope:.folder(folder.id),id:folder.id))
                // Subfolder rows name their watched folder as `parent`, and carry their own path as `id`.
                func inside(_ dir: String, _ depth: Int) {
                    for sub in subfolders[dir] ?? [] {
                        rows.append(.init(kind:.folder,title:(sub.path as NSString).lastPathComponent,symbol:"folder",count:sub.count,
                                          scope:.folderPath(sub.path),id:sub.path,depth:depth,parent:folder.id))
                        inside(sub.path,depth + 1)
                    }
                }
                inside(folder.path,1)
            }
        }
        // Your own tags, then the automatic ones that sort the most items, unless every tag is asked for.
        var shown = showsAllTags ? tags : tags.filter { !$0.automatic } + tags.filter { $0.automatic && $0.count >= 2 }.prefix(max(0,12 - tags.filter { !$0.automatic }.count))
        if sidebarSort("Tags") == "name" { shown.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if sidebarSort("Tags") == "manual" {
            let saved = UserDefaults.standard.stringArray(forKey:"sidebar.order.Tags") ?? []
            // Tags you've placed keep their places; new ones follow, busiest first.
            shown = shown.enumerated().sorted { a, b in
                let x = saved.firstIndex(of:a.element.name) ?? Int.max, y = saved.firstIndex(of:b.element.name) ?? Int.max
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        if !shown.isEmpty {
            rows.append(.header("Tags"))
            rows += shown.map { .init(kind:.tag,title:tagTitle($0.name,automatic:$0.automatic),symbol:"circle.fill",count:$0.count,scope:Self.tagScope($0.name),id:$0.name) }
        }
        // A collapsed section keeps its header and hides the rest; a section taken out of the sidebar goes entirely.
        var section = ""
        let collapsed = collapsedSections, hidden = hiddenSections
        return rows.filter { row in
            if row.kind == .header { section = row.id == "library" ? "" : row.title; return !hidden.contains(section) }
            return !collapsed.contains(section) && !hidden.contains(section)
        }
    }
    /// How a section is ordered: Collections and Smart Folders by hand (the default), by name or by size; Tags by
    /// how many items they have (the default) or by name.
    func sidebarSort(_ section: String) -> String { UserDefaults.standard.string(forKey:"sidebar.sort." + section) ?? (section == "Tags" ? "count" : "manual") }
    func ordered(_ nodes: [CollectionNode], _ section: String) -> [CollectionNode] {
        switch sidebarSort(section) {
        case "name": return nodes.sorted { $0.collection.name.localizedStandardCompare($1.collection.name) == .orderedAscending }
        case "count": return nodes.sorted { $0.count != $1.count ? $0.count > $1.count : $0.collection.name.localizedStandardCompare($1.collection.name) == .orderedAscending }
        case "created": return nodes.sorted { $0.collection.created > $1.collection.created }
        default: return nodes
        }
    }
    @objc func chooseSidebarSort(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        UserDefaults.standard.set(pair[1],forKey:"sidebar.sort." + pair[0]); reload()
    }
    var collapsedSections: Set<String> { Set(UserDefaults.standard.stringArray(forKey:"sidebar.collapsed") ?? []) }
    /// The sections that can leave the sidebar; View ▸ Sidebar brings them back.
    static let sections = ["Smart Folders","Collections","Folders","Tags"]
    var hiddenSections: Set<String> { Set(UserDefaults.standard.stringArray(forKey:"sidebar.hidden") ?? []) }
    @objc func toggleSidebarSection(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        var hidden = hiddenSections
        if hidden.remove(title) == nil { hidden.insert(title) }
        UserDefaults.standard.set(hidden.sorted(),forKey:"sidebar.hidden"); reload()
    }
    @objc func toggleSectionItem(_ sender: NSMenuItem) { if let title = sender.representedObject as? String { toggleSection(title) } }
    func toggleSection(_ title: String) {
        var collapsed = collapsedSections
        if collapsed.remove(title) == nil { collapsed.insert(title) }
        UserDefaults.standard.set(collapsed.sorted(),forKey:"sidebar.collapsed"); reload()
    }
    /// Each built-in smart folder gets a symbol for what it gathers; others a generic one.
    static func smartSymbol(_ name: String) -> String {
        ["Screenshots":"camera.viewfinder","Photos":"photo","Graphics":"scribble.variable","With Text":"text.alignleft","Videos":"play.rectangle",
         "GIFs":"square.stack.3d.forward.dottedline","Links":"link","Colors":"paintpalette","Recently Added":"clock"][name] ?? "folder.badge.gearshape"
    }
    var showsEmptySmartFolders: Bool { UserDefaults.standard.bool(forKey:"showEmptySmartFolders") }
    var showsAllTags: Bool { UserDefaults.standard.bool(forKey:"showAllTags") }
    var showsArchived: Bool { UserDefaults.standard.bool(forKey:"showArchivedCollections") }
    @objc func toggleArchived() { UserDefaults.standard.set(!showsArchived,forKey:"showArchivedCollections"); reload() }
    @objc func duplicateCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform("Duplicate Collection") { db in let copy = try db.duplicateCollection(id); DispatchQueue.main.async { self.pendingScope = .collection(copy.id) }; return nil }
    }
    @objc func archiveCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = rows.first(where:{ $0.id == id }) else { return }
        let archive = !row.archived
        perform(archive ? "Archive Collection" : "Unarchive Collection") { db in try db.setArchived(id,archive) }
        if archive { notify("Archived “\(row.title)”. Its items stay in your library.",undo:"Archive Collection"); if scope == row.scope { pendingScope = .all } }
    }
    /// ⌃⌘↑ and ⌃⌘↓: the place above or below in the sidebar, from anywhere in the window.
    @objc func previousPlace() { stepPlace(-1) }
    @objc func nextPlace() { stepPlace(1) }
    private func stepPlace(_ step: Int) {
        var row = sidebar.selectedRow
        repeat { row += step } while rows.indices.contains(row) && [.header,.prompt].contains(rows[row].kind)
        guard rows.indices.contains(row) else { NSSound.beep(); return }
        sidebar.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); sidebar.scrollRowToVisible(row)
    }
    @objc func toggleAllTags() { UserDefaults.standard.set(!showsAllTags,forKey:"showAllTags"); reload() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].kind == .header }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if rows[row].kind == .prompt { DispatchQueue.main.async { self.newCollection(nil) }; return false }
        return rows[row].kind != .header
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].kind == .header ? 34 : 28 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        guard entry.kind == .header else { return SidebarCell(row:entry) }
        // With no collections yet, the row below the header offers the first one instead.
        let offersFirst = rows.indices.contains(row + 1) && rows[row + 1].kind == .prompt
        let header = entry.title == "Collections" && !offersFirst ? SidebarHeader(title:entry.title,target:self,action:#selector(newCollection(_:)),tip:"New Collection · ⇧⌘N")
            : entry.title == "Smart Folders" ? SidebarHeader(title:entry.title,target:self,action:#selector(newSmartFolder(_:)),tip:"New Smart Folder · ⌥⌘N") : SidebarHeader(title:entry.title)
        guard entry.id != "library" else { return header }
        header.collapsed = collapsedSections.contains(entry.title)
        header.toggle = { [weak self] in self?.toggleSection(entry.title) }
        return header
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSidebar else { return }
        let row = sidebar.selectedRow
        guard rows.indices.contains(row) else { return }
        let before = scope
        scope = rows[row].scope; collectionTitle = rows[row].title; results = nil
        grid.select([],focus:nil)
        // Going into or out of a watched folder opens or closes its subfolders, so the sidebar is rebuilt too.
        func inFolder(_ scope: Scope) -> Bool { switch scope { case .folder, .folderPath: return true; default: return false } }
        if inFolder(before) || inFolder(scope) { reload() } else { loadItems() }
        if case .folder = scope, rows[row].symbol == "externaldrive.badge.xmark" {
            notify("“\(rows[row].title)” is on a drive that isn’t connected. Its items come back when you plug it in.")
        }
    }

    // MARK: Drops

    /// Collections and smart folders drag to reorder, or onto a collection to go inside it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Top-level watched folders and tags drag into an order of your own.
        if rows[row].kind == .folder, rows[row].parent == nil, let id = rows[row].id {
            let item = NSPasteboardItem(); item.setString("folder:" + id,forType:.folioSidebarRow); return item
        }
        if rows[row].kind == .tag, let id = rows[row].id {
            let item = NSPasteboardItem(); item.setString("tag:" + id,forType:.folioSidebarRow); return item
        }
        guard [.collection,.smart].contains(rows[row].kind), let id = rows[row].id else { return nil }
        let item = NSPasteboardItem(); item.setString(id,forType:.folioCollection); return item
    }
    /// The new order of a watched-folder or tag section after dropping `moving` above `row`, or nil if the row
    /// isn't in that section.
    private func rowDrop(_ moving: String, row: Int) -> [String]? {
        let folders = moving.hasPrefix("folder:"), id = String(moving.drop { $0 != ":" }.dropFirst())
        let kind: SidebarRow.Kind = folders ? .folder : .tag
        let section = rows.indices.filter { rows[$0].kind == kind && (!folders || rows[$0].parent == nil) }
        guard let first = section.first, let last = section.last, row >= first, row <= last + 1 else { return nil }
        var order = section.compactMap { rows[$0].id }
        guard let from = order.firstIndex(of:id) else { return nil }
        let before = row <= last ? rows[row].id : nil
        order.remove(at:from)
        // Dropping between subfolder rows lands before the next watched folder below.
        let target = before.flatMap { b in order.firstIndex(of:b) } ?? section.filter { $0 >= row }.compactMap { rows[$0].id }.compactMap { order.firstIndex(of:$0) }.first ?? order.count
        order.insert(id,at:target)
        return order
    }
    /// Where a dragged collection would go: its new parent and the sibling it goes in front of.
    private func collectionDrop(_ id: String, row: Int, operation: NSTableView.DropOperation) -> (parent: String?, before: String?)? {
        if operation == .on {
            guard rows.indices.contains(row), rows[row].kind == .collection, let target = rows[row].id, target != id else { return nil }
            return (target,nil)
        }
        guard let moving = rows.first(where:{ $0.id == id }) else { return nil }
        if rows.indices.contains(row), [.collection,.smart].contains(rows[row].kind), let target = rows[row].id {
            return target == id ? nil : (rows[row].parent,target)
        }
        // Past the last row of its section: the end of the top level.
        let previous = rows.indices.contains(row - 1) ? rows[row - 1] : nil
        guard let previous, [.collection,.smart].contains(previous.kind), previous.kind == moving.kind || moving.kind == .collection else { return nil }
        return (nil,nil)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if let id = info.draggingPasteboard.string(forType:.folioCollection) {
            return collectionDrop(id,row:row,operation:operation) == nil ? [] : .move
        }
        if let moving = info.draggingPasteboard.string(forType:.folioSidebarRow) {
            return operation == .above && rowDrop(moving,row:row) != nil ? .move : []
        }
        guard operation == .on, rows.indices.contains(row) else { return [] }
        let inside = info.draggingPasteboard.types?.contains(.folioItems) == true
        switch (rows[row].kind,rows[row].scope) {
        case (.collection,_): return inside ? .generic : .copy
        case (.tag,_), (.prompt,_): return inside ? .generic : []
        case (.library,.trash),(.library,.liked): return inside ? .generic : []
        case (.library,.inbox),(.library,.all): return inside ? [] : .copy
        case (.folder,_): return inside ? [] : .copy
        default: return []
        }
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if let moving = info.draggingPasteboard.string(forType:.folioSidebarRow) {
            guard dropOperation == .above, let order = rowDrop(moving,row:row) else { return false }
            let section = moving.hasPrefix("folder:") ? "Folders" : "Tags"
            UserDefaults.standard.set(order,forKey:"sidebar.order." + section)
            UserDefaults.standard.set("manual",forKey:"sidebar.sort." + section); reload()
            return true
        }
        if let id = info.draggingPasteboard.string(forType:.folioCollection) {
            guard let place = collectionDrop(id,row:row,operation:dropOperation) else { return false }
            // Arranging by hand means your own order again.
            for section in ["Collections","Smart Folders"] where sidebarSort(section) != "manual" { UserDefaults.standard.set("manual",forKey:"sidebar.sort." + section) }
            perform("Move Collection") { db in try db.moveCollection(id,to:place.parent,before:place.before) }
            return true
        }
        guard rows.indices.contains(row) else { return false }
        let target = rows[row], pasteboard = info.draggingPasteboard
        let ids = pasteboard.pasteboardItems?.compactMap { $0.string(forType:.folioItems) } ?? []
        if ids.isEmpty {
            guard let urls = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty else { return false }
            if target.kind == .folder, let place = watchedDirectory(target.scope) { copyIntoWatchedFolder(urls,place); return true }
            importURLs(urls,into:target.kind == .collection ? target.id : nil); return true
        }
        let chosen = grid.items.filter { ids.contains($0.id) }
        switch (target.kind,target.scope) {
        case (.collection,_): if let id = target.id { addToCollection(chosen,id:id,name:target.title) }
        case (.tag,_): let tag = target.id ?? target.title; edit("Add Tag",notice:"Tagged \(Self.count(chosen)) “\(target.title)”") { try $0.addTags([tag],to:chosen.map(\.id)) }
        case (.library,.trash): remove(chosen)
        case (.library,.liked): setLiked(chosen,true)
        case (.prompt,_): createCollection(with:chosen)
        default: return false
        }
        return true
    }

    // MARK: Menus

    func sidebarMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ value: Any? = nil) {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; entry.representedObject = value; menu.addItem(entry)
        }
        if rows.indices.contains(row) {
            let entry = rows[row]
            switch entry.kind {
            case .collection, .smart:
                if entry.kind == .smart { item("Edit Smart Folder…",#selector(editSmartFolderItem(_:)),entry.id) }
                item("Rename…",#selector(renameCollection(_:)),entry.id)
                if entry.kind == .collection {
                    item("New Collection Inside…",#selector(newCollection(_:)),entry.id)
                    item("Duplicate",#selector(duplicateCollection(_:)),entry.id)
                    item(entry.archived ? "Unarchive" : "Archive",#selector(archiveCollection(_:)),entry.id)
                    if let id = entry.id, !otherLibraries.isEmpty {
                        for (title,move) in [("Copy to Library",false),("Move to Library",true)] {
                            let sub = NSMenuItem(title:title,action:nil,keyEquivalent:""); sub.submenu = collectionLibraryMenu(id,move:move); menu.addItem(sub)
                        }
                    }
                }
                item("Delete \(entry.kind == .smart ? "Smart Folder" : "Collection")…",#selector(deleteCollection(_:)),entry.id)
            case .folder where entry.parent != nil:
                item("Show in Finder",#selector(revealSubfolder(_:)),entry.id)
            case .folder:
                item("Show in Finder",#selector(revealFolder(_:)),entry.id)
                item("Check for New Files",#selector(rescanFolder(_:)),entry.id)
                item("Stop Watching…",#selector(stopWatching(_:)),entry.id)
            case .tag:
                item("Rename Tag…",#selector(renameTag(_:)),entry.id ?? entry.title)
                item("Remove Tag from Every Item…",#selector(deleteTag(_:)),entry.id ?? entry.title)
            case .library where entry.scope == .trash:
                item("Empty Trash…",#selector(emptyTrash))
            case .header where Self.sections.contains(entry.title):
                do {
                    let sort = NSMenuItem(title:"Sort \(entry.title) By",action:nil,keyEquivalent:""), choices = NSMenu()
                    let options = entry.title == "Tags" ? [("count","Number of Items"),("name","Name"),("manual","Your Order")]
                        : entry.title == "Folders" ? [("manual","Order Added"),("name","Name")]
                        : [("manual","Your Order"),("name","Name"),("count","Number of Items"),("created","Newest First")]
                    for (value,title) in options {
                        let choice = NSMenuItem(title:title,action:#selector(chooseSidebarSort(_:)),keyEquivalent:""); choice.target = self
                        choice.representedObject = [entry.title,value]; choice.state = sidebarSort(entry.title) == value ? .on : .off; choices.addItem(choice)
                    }
                    sort.submenu = choices; menu.addItem(sort)
                }
                item(collapsedSections.contains(entry.title) ? "Show \(entry.title)" : "Hide \(entry.title)",#selector(toggleSectionItem(_:)),entry.title)
                item("Remove from Sidebar",#selector(toggleSidebarSection(_:)),entry.title)
            default: break
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        item("New Collection…",#selector(newCollection(_:)))
        item("New Smart Folder…",#selector(newSmartFolder(_:)))
        item("Watch a Folder…",#selector(watchFolderPanel))
        item("Import Library…",#selector(importLibraryPanel))
        let archived = NSMenuItem(title:"Show Archived Collections",action:#selector(toggleArchived),keyEquivalent:"")
        archived.target = self; archived.state = showsArchived ? .on : .off; menu.addItem(archived)
        let allTags = NSMenuItem(title:"Show All Tags",action:#selector(toggleAllTags),keyEquivalent:"")
        allTags.target = self; allTags.state = showsAllTags ? .on : .off; menu.addItem(allTags)
        let empty = NSMenuItem(title:"Show Empty Smart Folders",action:#selector(toggleEmptySmartFolders),keyEquivalent:"")
        empty.target = self; empty.state = showsEmptySmartFolders ? .on : .off; menu.addItem(empty)
        return menu
    }
    @objc func renameTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        askName("Rename tag “\(tag)”",button:"Rename",initial:tag) { [weak self] name in
            self?.edit("Rename Tag") { try $0.renameTag(tag,to:name) }
        }
    }
    @objc func deleteTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let alert = NSAlert(); alert.messageText = "Remove the tag “\(tag)” from every item?"
        alert.informativeText = "Items keep everything else. You can undo this."
        alert.addButton(withTitle:"Remove Tag"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.edit("Remove Tag") { db in
                let ids = try db.items(scope:Self.tagScope(tag)).map(\.id)
                return try db.removeTags([tag],from:ids)
            }
        }
    }
    @objc func toggleEmptySmartFolders() { UserDefaults.standard.set(!showsEmptySmartFolders,forKey:"showEmptySmartFolders"); reload() }
    /// Asks for a name in a sheet; `done` gets the trimmed text.
    func askName(_ message: String, button: String, initial: String = "", done: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = message
        let field = NSTextField(string:initial); field.frame = NSRect(x:0,y:0,width:260,height:24); field.placeholderString = "Name"
        alert.accessoryView = field; alert.addButton(withTitle:button); alert.addButton(withTitle:"Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for:window) { response in
            let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { done(name) }
        }
    }
    @objc func newCollection(_ sender: Any?) {
        let parent = (sender as? NSMenuItem)?.representedObject as? String
        let chosen = parent == nil && (sender as? NSMenuItem)?.identifier?.rawValue == "withSelection" ? grid.selectedItems : []
        createCollection(with:chosen,parent:parent)
    }
    /// Asks for a name, then makes the collection with these items in it and shows it.
    func createCollection(with chosen: [ShelfItem], parent: String? = nil) {
        askName(chosen.isEmpty ? "New collection" : "New collection with \(chosen.count == 1 ? "this item" : "\(chosen.count) items")",button:"Create") { [weak self] name in
            self?.perform("New Collection") { db in
                let collection = try db.createCollection(name:name,parent:parent)
                if !chosen.isEmpty { try db.addItems(chosen.map(\.id),to:collection.id) }
                DispatchQueue.main.async { self?.pendingScope = .collection(collection.id) }
                return nil
            }
        }
    }
    @objc func renameCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = rows.first(where:{ $0.id == id }) else { return }
        askName("Rename “\(row.title)”",button:"Rename",initial:row.title) { [weak self] name in
            self?.perform("Rename") { db in try db.renameCollection(id,to:name) }
        }
    }
    @objc func deleteCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = rows.first(where:{ $0.id == id }) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete “\(row.title)”?"
        alert.informativeText = row.kind == .smart ? "Its items stay in your library." : "Its items stay in your library unless you choose otherwise. You can undo this."
        // A regular collection can take its items with it, to the Trash; ones another collection holds stay.
        let alsoItems = NSButton(checkboxWithTitle:"Also move its items to the Trash",target:nil,action:nil)
        if row.kind != .smart { alert.accessoryView = alsoItems }
        alert.addButton(withTitle:"Delete"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if alsoItems.state == .on, let leaving = try? self.database.itemsOnly(in:id), !leaving.isEmpty {
                self.edit("Move to Trash") { try $0.moveToTrash(leaving) }
            }
            self.perform("Delete Collection") { db in try db.deleteCollection(id) }
        }
    }
    /// Runs a collection edit off the main thread, registers its undo and reloads.
    func perform(_ name: String, _ work: @escaping (LibraryDatabase) throws -> CollectionArchive?) {
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let archive = try work(self.database)
                DispatchQueue.main.async {
                    if let archive { self.registerUndo(name,archive) }
                    self.reload()
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    /// The same collection edit for several collections, undone as one step; `done` runs once the library has them.
    func performMany(_ name: String, _ ids: [String], _ work: @escaping (LibraryDatabase,String) throws -> CollectionArchive, done: @escaping () -> Void) {
        guard !ids.isEmpty else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            var archives: [CollectionArchive] = [], failure: Error?
            for id in ids { do { archives.append(try work(self.database,id)) } catch { failure = error } }
            DispatchQueue.main.async {
                if !archives.isEmpty {
                    self.registerUndo(name) { target in
                        target.workQueue.async {
                            for archive in archives.reversed() { try? target.database.restore(archive) }
                            DispatchQueue.main.async { target.reload() }
                        }
                    }
                }
                if let failure { self.showError(failure) }
                self.reload(); done()
            }
        }
    }
    private func registerUndo(_ name: String, _ archive: CollectionArchive) {
        registerUndo(name) { target in
            target.workQueue.async { try? target.database.restore(archive); DispatchQueue.main.async { target.reload() } }
        }
    }
}

final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:10,dy:1),xRadius:6,yRadius:6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:10,dy:1),xRadius:6,yRadius:6).fill()
    }
}

/// A section title. Clicking it folds the section away; a chevron shows on hover, and stays while it's folded.
final class SidebarHeader: NSTableCellView {
    private let chevron = NSImageView()
    var toggle: (() -> Void)?
    var collapsed = false { didSet { chevron.image = Self.chevron(collapsed); chevron.alphaValue = collapsed ? 1 : 0; setAccessibilityExpanded(!collapsed) } }
    private static func chevron(_ collapsed: Bool) -> NSImage? {
        NSImage(systemSymbolName:collapsed ? "chevron.right" : "chevron.down",accessibilityDescription:collapsed ? "Show" : "Hide")
    }
    init(title: String, target: AnyObject? = nil, action: Selector? = nil, tip: String = "") {
        super.init(frame:.zero)
        let text = label(title,size:11,weight:.bold,color:.secondaryLabelColor)
        chevron.image = Self.chevron(false); chevron.symbolConfiguration = .init(pointSize:8,weight:.bold); chevron.contentTintColor = Theme.muted; chevron.alphaValue = 0
        for view in [text,chevron] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),text.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-5),
                                     chevron.leadingAnchor.constraint(equalTo:text.trailingAnchor,constant:5),chevron.centerYAnchor.constraint(equalTo:text.centerYAnchor)])
        setAccessibilityRole(.disclosureTriangle); setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))
        if let target, let action {
            let add = NSButton(image:NSImage(systemSymbolName:"plus",accessibilityDescription:tip)!,target:target,action:action)
            add.isBordered = false; add.contentTintColor = Theme.muted; add.toolTip = tip
            add.symbolConfiguration = .init(pointSize:11,weight:.semibold); add.translatesAutoresizingMaskIntoConstraints = false; addSubview(add)
            NSLayoutConstraint.activate([add.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),add.centerYAnchor.constraint(equalTo:text.centerYAnchor)])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { chevron.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { chevron.animator().alphaValue = collapsed ? 1 : 0 }
    override func mouseDown(with event: NSEvent) { toggle?() }
    override func accessibilityPerformPress() -> Bool { toggle?(); return true }
}

final class SidebarCell: NSTableCellView {
    init(row: SidebarRow) {
        super.init(frame:.zero)
        let icon = NSImageView(image:NSImage(systemSymbolName:row.symbol,accessibilityDescription:nil) ?? NSImage())
        // Tags are a quiet list: a small dot instead of the same icon on every row.
        icon.symbolConfiguration = .init(pointSize:row.kind == .tag ? 5 : 13,weight:.regular); icon.contentTintColor = Theme.muted
        let name = label(row.title,size:13,color:row.kind == .prompt ? Theme.muted : Theme.ink)
        let number = label(row.count > 0 ? row.count.formatted() : "",size:11,color:Theme.muted)
        number.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); number.alignment = .right
        imageView = icon; textField = name
        for view in [icon,name,number] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        number.setContentCompressionResistancePriority(.required,for:.horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10 + CGFloat(row.depth) * 14),icon.centerYAnchor.constraint(equalTo:centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant:18),
            name.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:7),name.centerYAnchor.constraint(equalTo:centerYAnchor),
            number.leadingAnchor.constraint(greaterThanOrEqualTo:name.trailingAnchor,constant:6),number.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),
            number.centerYAnchor.constraint(equalTo:centerYAnchor)])
        setAccessibilityLabel(row.kind == .prompt ? row.title : "\(row.title), \(row.count) items")
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Right-clicks on the sidebar ask the controller for a menu for that row.
final class SidebarTable: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(row(at:convert(event.locationInWindow,from:nil))) }
}
