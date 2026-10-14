import AppKit
import ShelfCore
import QuartzCore
import Vision

let processStart = CACurrentMediaTime()
let args = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = args.firstIndex(of:name), i + 1 < args.count else { return nil }
    return args[i+1]
}

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var database: LibraryDatabase!
    var server: CaptureServer!
    var grid: ShelfGridView!
    var scroll: NSScrollView!
    var sidebar: SidebarTable!
    var inspector: Inspector!
    var folders: FolderWatcher!
    var links: LinkSaver!
    let search = NSSearchField()
    let toast = Toast()
    let hints = ShortcutHints()
    let viewer = ViewerView()
    /// The blurred desktop behind Glass themes.
    let backdrop = NSVisualEffectView()
    let activity = label("",size:11,color:Theme.muted)
    var rows: [SidebarRow] = []
    var scope: Scope = .all
    var collectionTitle = "All Items"
    /// A scope to select once the sidebar next reloads, such as a collection just created.
    var pendingScope: Scope?
    /// The smart folder being edited in a sheet, if any.
    var smartFolderEditing: SmartFolderModel?
    /// Runs once the next load has put its items on screen, for work that needs them there (selecting results).
    var afterLoad: (() -> Void)?
    var restoredBackup = false
    /// The sidebar was folded away for the viewer and comes back when it closes.
    var sidebarHiddenForViewer = false
    var collectionNames: [String:String] = [:]
    var regularCollections: [(id: String, name: String)] = []
    var sort: Sort = .added
    var ascending = false
    let workQueue = DispatchQueue(label:"org.lumashelf.library-work",qos:.userInitiated)
    let ocrQueue = OperationQueue()
    var queryGeneration = 0
    var pendingSearch: DispatchWorkItem?
    var startupMS = 0.0
    var benchmarkTimer: Timer?
    var updatingSidebar = false
    var thumbnails: ThumbnailCache!
    var split: NSSplitViewController!
    var inspectorItem: NSSplitViewItem!
    var searchItem: NSSearchToolbarItem?
    var inspectorDismissed = false
    var emptyState: NSStackView!
    let emptyIcon = NSImageView()
    let emptyTitle = NSTextField(labelWithString:"")
    let emptyBody = NSTextField(wrappingLabelWithString:"")
    let emptyActions = NSStackView()
    var styleSwitch: NSSegmentedControl!
    var zoom: NSSlider!
    var sortButton: NSButton!
    var floating: [NSView] = []
    var classifierJob: BlockOperation?
    let classificationQueue = OperationQueue()
    let classifier = ImageClassifier()
    var preserveNextLoad = false
    var classificationRequestedAgain = false
    var autoTagsEnabled: Bool {
        guard !args.contains("--no-autotag"), argument("--benchmark-json") == nil else { return false }
        return (UserDefaults.standard.object(forKey:"automaticTagging") as? Bool) ?? true
    }
    var qaRun: AnyObject?
    var board: BoardView!
    let boardScroll = NSScrollView()
    var boardShown = false
    var infinity: InfinityView!
    var infinityShown = false
    /// The size and sort bar, hidden on a board.
    weak var zoomBar: NSView?
    /// How many of the shown search results came from search by meaning.
    var relatedCount = 0
    /// A quick filter from the floating bar, added to the search.
    var filter: (title: String, query: String)?
    /// Rules from Advanced Filter, narrowing the place on screen; `filter` names it while it is on.
    var filterRules: SmartRules?
    let filterButton = NSButton()
    /// A list shown instead of a sidebar place (see `showResults`).
    var results: (title: String, items: [ShelfItem])?
    let backButton = NSButton()
    let titleLabel = NSTextField(labelWithString:"All Items")
    let countLabel = NSTextField(labelWithString:"")
    /// Loaded feature prints, kept between Find Similar requests; only touched on `similarityQueue`.
    var printCache: [String:VNFeaturePrintObservation]?
    /// The search as last typed, so clearing it in one go can be undone.
    var searchText = ""
    let similarityQueue = DispatchQueue(label:"org.lumashelf.similarity",qos:.userInitiated)
    let palette = CommandPalette()
    var tagCache: [(name: String, count: Int, automatic: Bool)] = []
    /// An item to select and scroll to once the next listing loads.
    var pendingReveal: String?
    var selection: [ShelfItem] { boardShown ? board.selectedItems : grid.selectedItems }
    var selected: ShelfItem? { selection.count == 1 ? selection[0] : nil }
    var inTrash: Bool { scope == .trash }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let custom = argument("--library").map { URL(fileURLWithPath:$0,isDirectory:true) }
            let location = custom.map { ($0,nil as String?) } ?? LibraryLocation.resolve()
            let root = location.0
            // A backup chosen in Settings is put back before the library opens.
            restoredBackup = LibraryDatabase.applyPendingRestore(root:root)
            database = try LibraryDatabase(root:root)
            if let old = location.1 { _ = try? database.rebasePaths(from:old,to:root.path) }
            server = try CaptureServer(database:database,keyFolder:custom == nil ? LibraryLocation.folder : nil)
            DispatchQueue.global(qos:.utility).async { [database] in
                _ = try? database?.snapshotIfDue()
                while ((try? database?.backfillFileInfo()) ?? 0) > 0 {}
            }
            loadSort()
            applyAppearance(argument("--appearance") ?? UserDefaults.standard.string(forKey:"appearance") ?? "system")
            if let family = argument("--theme").flatMap(ThemeFamily.init(saved:)) { MainActor.assumeIsolated { ThemeStore.shared.override(family) } }
            if args.contains("--headless-capture") {
                NSApp.setActivationPolicy(.accessory)
                server.didFail = { message in fputs("Capture server: \(message)\n",stderr) }
                server.start()
                print("Folio capture service ready on 127.0.0.1:53187")
                return
            }
            thumbnails = ThumbnailCache(disk:custom == nil ? LibraryLocation.previews : root.appendingPathComponent("previews"))
            grid = ShelfGridView(thumbnails:thumbnails)
            if let style = argument("--grid-style").flatMap(GridStyle.init(rawValue:)) { grid.style = style }
            classificationQueue.name = "org.lumashelf.classification"; classificationQueue.maxConcurrentOperationCount = 1
            classificationQueue.qualityOfService = .utility
            buildMenus(); buildDesignedWindow()
            server.didSave = { [weak self] in self?.reload() }
            server.didFail = { [weak self] message in self?.notify("Browser connection: \(message)") }
            if !args.contains("--no-capture") { server.start() }
            ocrQueue.name = "org.lumashelf.ocr"; ocrQueue.maxConcurrentOperationCount = 1; ocrQueue.qualityOfService = .utility
            links = LinkSaver(database:database)
            links.didChange = { [weak self] in self?.preserveNextLoad = true; self?.reload() }
            links.importFiles = { [weak self] urls in self?.importURLs(urls) }
            folders = FolderWatcher(database:database)
            folders.didChange = { [weak self] in self?.preserveNextLoad = true; self?.reload() }
            if !args.contains("--no-folders") { folders.start() }
            // The folio command and the MCP server change the library from outside; show their changes.
            DistributedNotificationCenter.default().addObserver(forName:.init("org.lumashelf.library-changed"),object:nil,queue:.main) { [weak self] _ in
                self?.preserveNextLoad = true; self?.reload(); self?.fillInLinks()
            }
            if args.contains("--background-check") { NSApp.setActivationPolicy(.accessory) }
            else {
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                MainActor.assumeIsolated { MenuBarPin.shared.app = self; MenuBarPin.shared.update() }
            }
            if restoredBackup { afterLoad = { [weak self] in self?.notify("Restored the library from a backup. The version you left is a backup too.") } }
            if let folder = argument("--import-folder") { importURLs([URL(fileURLWithPath:folder)]) }
            else { reload() }
            if let folder = argument("--watch-folder") { watch(URL(fileURLWithPath:folder,isDirectory:true)) }
            if let pane = argument("--settings") { openSettings(SettingsDestination(rawValue:pane)) }
            if !args.contains("--background-check"), argument("--benchmark-json") == nil, argument("--analysis-report") == nil { UpdateService.shared.start() }
        } catch { showError(error); NSApp.terminate(nil) }
    }
    /// folio://item/<id> (from the folio command or an assistant) shows that item; folio://search?q=… shows a search;
    /// folio://show?place=<name>&layout=rows|columns|board|list|infinity opens a sidebar place in a layout.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "folio" && url.host == "search" {
            guard let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "q" })?.value, !query.isEmpty else { continue }
            showLibrary(); if !args.contains("--background-check") { NSApp.activate(ignoringOtherApps:true) }
            if !viewer.isHidden { viewer.closeViewer() }
            search.stringValue = query; loadItems()
        }
        for url in urls where url.scheme == "folio" && url.host == "show" {
            let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value?.trimmingCharacters(in:.whitespaces) }
            showLibrary(); if !args.contains("--background-check") { NSApp.activate(ignoringOtherApps:true) }
            if !viewer.isHidden { viewer.closeViewer() }
            if let place = value("place"), !place.isEmpty {
                guard let row = rows.first(where:{ $0.kind != .header && $0.kind != .prompt && $0.title.caseInsensitiveCompare(place) == .orderedSame }) else {
                    notify("There's no “\(place)” in the sidebar"); continue
                }
                showScope(row.scope)
            }
            if let layout = value("layout")?.lowercased() {
                // After the place has loaded, so the layout belongs to it.
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.3) { [self] in
                    switch layout {
                    case "rows": showRows(); case "columns": showColumns(); case "list": showList()
                    case "infinity": showInfinityStyle(); case "board": showBoard()
                    default: notify("Folio has no “\(layout)” layout")
                    }
                }
            }
        }
        for url in urls where url.scheme == "folio" && url.host == "item" {
            let id = url.lastPathComponent
            guard let item = try? database?.item(id:id) else { continue }
            showLibrary(); if !args.contains("--background-check") { NSApp.activate(ignoringOtherApps:true) }
            if !viewer.isHidden { viewer.closeViewer() }
            reveal(item:item)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if argument("--analysis-report") != nil { fputs("Last window closed\n",stderr) }
        // Without a Dock icon the menu bar pin is the way back, so closing the window only closes the window.
        return !args.contains("--background-check") && !keepsRunning && MainActor.assumeIsolated { MenuBarPin.showsDockIcon }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }
    @objc func showLibrary() { window?.makeKeyAndOrderFront(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        classifierJob?.cancel(); folders?.stop()
        if argument("--analysis-report") != nil { fputs("Application terminating\n",stderr) }
    }

    // MARK: Menus

    func buildMenus() {
        let main = NSMenu(), app = NSMenu(), file = NSMenu(), edit = NSMenu(), item = NSMenu(), view = NSMenu()
        func section(_ title: String, _ submenu: NSMenu) {
            let entry = NSMenuItem(title:title,action:nil,keyEquivalent:""); entry.submenu = submenu; main.addItem(entry)
        }
        @discardableResult func action(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title:title,action:selector,keyEquivalent:key); entry.target = self; entry.keyEquivalentModifierMask = modifiers; menu.addItem(entry); return entry
        }
        section(AppIdentity.name,app); section("File",file); section("Edit",edit); section("Item",item); section("View",view)
        action(app,"About Folio",#selector(showAbout),"")
        app.addItem(.separator())
        action(app,"Settings…",#selector(showSettings),",")
        action(app,"Check for Updates…",#selector(checkForUpdates),"")
        app.addItem(.separator())
        app.addItem(withTitle:"Hide Folio",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        app.addItem(withTitle:"Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h").keyEquivalentModifierMask = [.command,.option]
        app.addItem(withTitle:"Show All",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"")
        app.addItem(.separator())
        app.addItem(withTitle:"Quit Folio",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        action(file,"Add Files or Folder…",#selector(importPanel),"o")
        action(file,"New Collection…",#selector(newCollection(_:)),"n",[.command,.shift])
        action(file,"New Smart Folder…",#selector(newSmartFolder(_:)),"n",[.command,.option])
        action(file,"Watch a Folder…",#selector(watchFolderPanel),"")
        action(file,"Import Library…",#selector(importLibraryPanel),"")
        file.addItem(libraryMenuItem)
        file.addItem(.separator())
        action(file,"Sort Images Automatically",#selector(tagAllImages),"")
        action(file,"Read Text in Images",#selector(indexOCR),"")
        action(file,"Find Duplicates",#selector(findDuplicates),"")
        file.addItem(.separator())
        action(file,"Export Library as JSON…",#selector(exportLibrary),"")
        action(file,"Empty Trash…",#selector(emptyTrash),"\u{8}",[.command,.shift,.option])
        file.addItem(.separator())
        file.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        edit.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(withTitle:"Redo",action:Selector(("redo:")),keyEquivalent:"z").keyEquivalentModifierMask = [.command,.shift]
        edit.addItem(.separator())
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        action(edit,"Paste as Link",#selector(pasteAsLink),"v",[.command,.option])
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        edit.addItem(.separator())
        action(edit,"Find",#selector(focusSearch),"f")
        action(edit,"Command Menu…",#selector(showPalette),"k")
        action(edit,"Go to…",#selector(showGoTo),"j")
        action(item,"Open",#selector(viewSelected),"\u{F701}")
        action(item,"Quick Look",#selector(quickLook),"y")
        action(item,"Find Similar",#selector(findSimilar),"")
        action(item,"Open with Default App",#selector(openSelected),"\u{F701}",[.command,.option])
        action(item,"Open With…",#selector(showOpenWith),"o",[.command,.option])
        action(item,"Show in Finder",#selector(revealSelected),"r",[.command,.shift])
        action(item,"Export…",#selector(exportSelected),"e",[.command,.shift])
        action(item,"Refresh Thumbnail",#selector(refreshThumbnails),"")
        action(item,"Save Frame as Picture",#selector(saveVideoFrame),"s",[.command,.shift])
        action(item,"Set as Desktop Picture",#selector(setDesktopPicture),"")
        item.addItem(.separator())
        action(item,"Like",#selector(toggleLikeSelected),"")
        action(item,"Add Tags…",#selector(showTagPicker),"")
        action(item,"Edit Note",#selector(editNote),"")
        action(item,"Edit Author",#selector(editAuthor),"")
        action(item,"Edit Source",#selector(editSource),"")
        let add = NSMenuItem(title:"Add to Collection",action:nil,keyEquivalent:""); add.submenu = NSMenu(); add.submenu?.delegate = self; add.identifier = .init("addToCollection")
        item.addItem(add)
        action(item,"Add to Collection…",#selector(showCollectionPicker),"")
        action(item,"Move to Collection…",#selector(showMovePicker),"")
        action(item,"New Collection with Selection…",#selector(newCollectionWithSelection),"n",[.command,.control])
        item.addItem(.separator())
        action(item,"Move to Trash",#selector(removeSelected),"\u{8}")
        action(item,"Put Back",#selector(putBackSelected),"")
        view.addItem(withTitle:"Show Sidebar",action:#selector(NSSplitViewController.toggleSidebar(_:)),keyEquivalent:"s").keyEquivalentModifierMask = [.command,.control]
        action(view,"Show Details",#selector(toggleInspector),"i")
        view.addItem(.separator())
        action(view,"as Rows",#selector(showRows),"1")
        action(view,"as Columns",#selector(showColumns),"2")
        action(view,"as Board",#selector(showBoard),"3")
        action(view,"as List",#selector(showList),"4")
        action(view,"as Infinity",#selector(showInfinityStyle),"5")
        action(view,"Show Filenames",#selector(toggleCaptions),"")
        let sidebarSections = NSMenu()
        for title in Self.sections { action(sidebarSections,title,#selector(toggleSidebarSection(_:)),"").representedObject = title }
        let sidebarEntry = NSMenuItem(title:"Sidebar",action:nil,keyEquivalent:""); sidebarEntry.submenu = sidebarSections; view.addItem(sidebarEntry)
        view.addItem(.separator())
        for (index,(title,_)) in Self.places.enumerated() { action(view,title,#selector(goToPlace(_:)),"\(index + 1)",[.command,.option]).tag = index }
        action(view,"Previous Place",#selector(previousPlace),"\u{F700}",[.command,.control])
        action(view,"Next Place",#selector(nextPlace),"\u{F701}",[.command,.control])
        let sortEntry = NSMenuItem(title:"Sort By",action:nil,keyEquivalent:""); sortEntry.submenu = NSMenu(); sortEntry.submenu?.delegate = self; sortEntry.identifier = .init("sortBy")
        view.addItem(sortEntry)
        view.addItem(.separator())
        action(view,"Larger Thumbnails",#selector(zoomIn),"+")
        action(view,"Smaller Thumbnails",#selector(zoomOut),"-")
        view.addItem(.separator())
        let appearance = NSMenu(), appearanceItem = NSMenuItem(title:"Appearance",action:nil,keyEquivalent:"")
        for (title,value) in [("System","system"),("Light","light"),("Dark","dark")] {
            let entry = NSMenuItem(title:title,action:#selector(chooseAppearance(_:)),keyEquivalent:""); entry.target = self; entry.representedObject = value; appearance.addItem(entry)
        }
        appearanceItem.submenu = appearance; view.addItem(appearanceItem)
        action(view,"Reload",#selector(reloadAction),"r")
        let windowMenu = NSMenu(), windowItem = NSMenuItem(title:"Window",action:nil,keyEquivalent:"")
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        windowMenu.addItem(.separator()); action(windowMenu,"Library",#selector(showLibrary),"0")
        windowItem.submenu = windowMenu; main.addItem(windowItem); NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
        Shortcuts.apply()
    }
    /// The library's fixed places, ⌥⌘1 to ⌥⌘4.
    static let places: [(String,Scope)] = [("All Items",.all),("Inbox",.inbox),("Liked",.liked),("Trash",.trash)]
    @objc func goToPlace(_ sender: NSMenuItem) {
        guard Self.places.indices.contains(sender.tag) else { return }
        if !viewer.isHidden { viewer.closeViewer() }
        showScope(Self.places[sender.tag].1)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let gridActive = window?.firstResponder === grid || window?.firstResponder === viewer || window?.firstResponder === window
        switch menuItem.action {
        case #selector(viewSelected), #selector(openSelected), #selector(revealSelected): return selected != nil && gridActive
        case #selector(quickLook), #selector(newCollectionWithSelection), #selector(showTagPicker), #selector(showCollectionPicker), #selector(showMovePicker): return !selection.isEmpty
        case #selector(editNote): return selected != nil
        case #selector(exportSelected), #selector(refreshThumbnails): return !selection.isEmpty
        case #selector(findSimilar): return selected?.hasLook == true
        case #selector(saveVideoFrame): return viewer.showsVideo || grid.playingVideo != nil
        case #selector(setDesktopPicture): return selected?.kind == "image" && selected?.path.hasPrefix("/") == true
        case #selector(removeSelected):
            menuItem.title = inTrash ? "Delete Immediately…" : "Move to Trash"
            return !selection.isEmpty && gridActive
        case #selector(putBackSelected): return inTrash && !selection.isEmpty
        case #selector(toggleLikeSelected):
            menuItem.title = !selection.isEmpty && selection.allSatisfy(\.liked) ? "Unlike" : "Like"
            return !selection.isEmpty && gridActive
        case #selector(toggleInspector): menuItem.title = panelVisible ? "Hide Details" : "Show Details"; return true
        case #selector(showOpenWith): return selection.count == 1 && selection[0].path.hasPrefix("/") && gridActive
        case #selector(toggleCaptions): menuItem.state = grid.showsCaptions ? .on : .off; return true
        case #selector(toggleSidebarSection(_:)):
            // In View ▸ Sidebar a tick means shown; on a section header the item just removes it.
            if menuItem.menu?.supermenu != nil { menuItem.state = hiddenSections.contains(menuItem.representedObject as? String ?? "") ? .off : .on }
            return true
        case #selector(showRows): menuItem.state = !boardShown && grid.style == .rows ? .on : .off; return true
        case #selector(showColumns): menuItem.state = !boardShown && grid.style == .columns ? .on : .off; return true
        case #selector(showBoard): menuItem.state = boardShown ? .on : .off; return currentCollection != nil
        case #selector(emptyTrash): return (rows.first { $0.scope == .trash }?.count ?? 0) > 0
        case #selector(chooseAppearance(_:)):
            menuItem.state = (menuItem.representedObject as? String) == (UserDefaults.standard.string(forKey:"appearance") ?? "system") ? .on : .off; return true
        default: return true
        }
    }
    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value,forKey:"appearance"); applyAppearance(value)
    }
    func applyAppearance(_ value: String) { MainActor.assumeIsolated { ThemeStore.shared.override(AppearanceMode(rawValue:value) ?? .system) } }

    // MARK: Loading

    func windowDidResize(_ notification: Notification) { grid.resizeDocument(); grid.refresh() }
    /// Nothing moves while the window can't be seen: hover playback stops and GIFs in the viewer hold still.
    /// A video playing in the viewer keeps going, as someone may be listening.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window.occlusionState.contains(.visible)
        if !visible { grid.endHover() }
        viewer.zoom.animates = visible
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search {
            if search.stringValue.isEmpty { searchCleared(searchText) }
            searchText = search.stringValue
            pendingSearch?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.loadItems() }
            pendingSearch = work; DispatchQueue.main.asyncAfter(deadline:.now() + 0.025,execute:work)
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSSearchField === search { rememberSearch(search.stringValue) }
    }
    /// Clearing a search all at once (the clear button, Esc, select-all and delete) can be undone with ⌘Z;
    /// deleting it a letter at a time is just typing.
    func searchCleared(_ previous: String) {
        guard previous.count > 1 else { return }
        registerUndo("Clear Search") { target in
            target.search.stringValue = previous; target.searchText = previous
            target.results = nil; target.loadItems()
        }
    }
    /// Single-key shortcuts from the grid and the viewer. They never fire while typing in a field.
    func singleKey(_ key: String) -> Bool {
        switch SingleKeys.action(for:key) {
        case "tags": showTagPicker()
        case "collect": showCollectionPicker()
        case "move": showMovePicker()
        case "note": editNote()
        case "details": toggleInspector()
        case "like": if selection.isEmpty { return false }; toggleLikeSelected()
        case "similar": findSimilar()
        case "shuffle": applySort(.random(seed:Int64.random(in:1...Int64(Int32.max))))
        case "author": if selection.isEmpty { return false }; editAuthor()
        case "source": if selection.isEmpty { return false }; editSource()
        default: return false
        }
        return true
    }
    @objc func reloadAction() { reload() }
    func reload() {
        let wanted = pendingScope ?? scope; pendingScope = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let tree = try self.database.collectionTree(), connected = try self.database.connectedFolders(), tags = try self.database.tagCounts()
                var all: [CollectionNode] = []
                func walk(_ nodes: [CollectionNode]) { for node in nodes { all.append(node); walk(node.children) } }
                walk(tree)
                // A watched folder opens to its subfolders while you're in it, down the path to where you are.
                var subfolders: [String:[(path: String, count: Int)]] = [:]
                let open: String? = { switch wanted { case .folder(let id): return connected.first { $0.id == id }?.path; case .folderPath(let path): return path; default: return nil } }()
                if let open, let root = connected.first(where:{ open == $0.path || open.hasPrefix($0.path + "/") }) {
                    var dir = root.path
                    while true {
                        let inside = try self.database.subfolders(of:root.id,in:dir); subfolders[dir] = inside
                        guard dir != open, let next = inside.first(where:{ open == $0.path || open.hasPrefix($0.path + "/") }) else { break }
                        dir = next.path
                    }
                }
                let fixed: [Scope] = [.all,.inbox,.liked,.trash] + connected.map { .folder($0.id) }
                let counts = Dictionary(uniqueKeysWithValues:zip(fixed,try self.database.counts(for:fixed)))
                DispatchQueue.main.async {
                    self.updatingSidebar = true
                    self.collectionNames = Dictionary(all.map { ($0.id,$0.collection.name) },uniquingKeysWith:{ a,_ in a })
                    self.regularCollections = all.filter { !$0.collection.isSmart && !$0.collection.archived }.map { ($0.id,$0.collection.name) }
                    self.tagCache = tags
                    self.rows = self.sidebarRows(tree:tree,folders:connected,counts:counts,tags:tags,subfolders:subfolders)
                    self.sidebar.reloadData()
                    let row = self.rows.firstIndex { $0.kind != .header && $0.scope == wanted } ?? 0
                    if self.rows[row].scope != self.scope { self.preserveNextLoad = false }
                    self.scope = self.rows[row].scope; self.collectionTitle = self.rows[row].title
                    self.sidebar.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
                    self.updatingSidebar = false
                    self.loadItems()
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    func loadItems() {
        queryGeneration += 1; let generation = queryGeneration
        searchText = search.stringValue
        let query = effectiveQuery, scope = scope, sort = sort, ascending = ascending, rules = filterRules
        let preserve = preserveNextLoad; preserveNextLoad = false
        let shown = results?.items.map(\.id)
        let vocabulary = semanticSearch ? tagCache.map(\.name) : []
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                var items = try shown.map { ids in try ids.compactMap { try self.database.item(id:$0) }.filter { $0.trashed == nil } }
                    ?? self.database.items(scope:scope,query:query,rules:rules,sort:sort,ascending:ascending)
                let related = shown == nil && rules == nil ? try self.relatedItems(query:query,scope:scope,vocabulary:vocabulary,excluding:Set(items.map(\.id)),best:items.prefix(3).map(\.id)) : []
                items += related
                DispatchQueue.main.async {
                    guard generation == self.queryGeneration else { return }
                    self.relatedCount = related.count
                    self.grid.setItems(items,preservePosition:preserve)
                    if self.wantsBoard { self.loadBoard(items,keepSelection:preserve) } else { self.hideBoard() }
                    if !self.wantsBoard && self.grid.style == .infinity { self.showInfinity(items) } else { self.hideInfinity() }
                    if preserve { self.inspector.show(self.selection,keepEdits:true) }
                    if let id = self.pendingReveal, let index = items.firstIndex(where:{ $0.id == id }) {
                        self.pendingReveal = nil; self.grid.select([id],focus:id); self.grid.reveal(index)
                    }
                    if !self.viewer.isHidden { self.viewer.replace(items) }
                    if let next = self.afterLoad { self.afterLoad = nil; next() }
                    self.updateTitle(count:items.count)
                    if self.selection.isEmpty { self.inspector.describePlace() }
                    self.updateEmptyState(count:items.count,query:query)
                    if !preserve { self.scheduleClassification() }
                    if self.startupMS == 0 { self.finishStartup(items) }
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    private func finishStartup(_ items: [ShelfItem]) {
        startupMS = (CACurrentMediaTime() - processStart) * 1000
        if args.contains("--select-first"), let first = items.first {
            grid.select([first.id],focus:first.id); showInspector(true,animated:false)
        }
        if let count = argument("--select-count").flatMap(Int.init) { grid.select(Set(items.prefix(count).map(\.id)),focus:items.first?.id); showInspector(true,animated:false) }
        if args.contains("--open-first"), let first = items.first { showViewer(first) }
        // Development: stage a scene for a capture. --show opens a sidebar place, then --search, --board and --select-title.
        if let name = argument("--show"), let row = rows.first(where:{ $0.title == name && $0.kind != .header }) { showScope(row.scope) }
        if let path = argument("--show-folder") { showScope(.folderPath(path)) }
        if let link = argument("--open-url").flatMap(URL.init(string:)) { application(NSApp,open:[link]) }
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.8) { [self] in
            if let text = argument("--search") { search.stringValue = text; loadItems() }
            if args.contains("--board") { setBoard(true) }
            if let kind = argument("--hover"), let index = grid.items.firstIndex(where:{ $0.kind == kind || $0.ext == kind }) {
                // Twice: the first rest starts loading what the second shows.
                grid.hoverItem(index); DispatchQueue.main.asyncAfter(deadline:.now() + 1.2) { [self] in grid.hoverItem(index,at:0.7) }
            }
            if args.contains("--hints") { hints.show() }
            if args.contains("--details") { showInspector(true,animated:false); inspector.describePlace() }
            if let name = argument("--edit-smart-folder") { editSmartFolder(rows.first { $0.kind == .smart && $0.title == name }?.id) }
            if args.contains("--advanced-filter") { showAdvancedFilter() }
        }
        // After a search has had a moment to load.
        DispatchQueue.main.asyncAfter(deadline:.now() + 1.8) { [self] in
            if let title = argument("--select-title"), let item = grid.items.first(where:{ $0.title == title }) {
                grid.select([item.id],focus:item.id); showInspector(true,animated:false)
            }
        }
        if let output = argument("--benchmark-json") { startBenchmark(to:URL(fileURLWithPath:output)) }
        if let folder = argument("--qa") {
            MainActor.assumeIsolated { let qa = QAHarness(app:self,folder:URL(fileURLWithPath:folder,isDirectory:true)); qaRun = qa; qa.run() }
        }
        if let output = argument("--snapshot") { DispatchQueue.main.asyncAfter(deadline:.now()+(Double(argument("--snapshot-delay") ?? "") ?? 2)) { self.snapshotWindow(to:output) } }
    }
    func loadSort() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey:"sort") {
        case "custom": sort = .custom
        case "fileDate": sort = .fileDate
        case "name": sort = .name
        case "size": sort = .size
        case "random": sort = .random(seed:Int64.random(in:1...Int64(Int32.max)))
        default: sort = .added
        }
        ascending = defaults.bool(forKey:"sortAscending")
    }
    func saveSort() {
        let key: String
        switch sort { case .custom: key = "custom"; case .fileDate: key = "fileDate"; case .name: key = "name"; case .size: key = "size"; case .random: key = "random"; default: key = "added" }
        UserDefaults.standard.set(key,forKey:"sort"); UserDefaults.standard.set(ascending,forKey:"sortAscending")
    }
    func selectionChanged(_ items: [ShelfItem]) {
        inspector.show(items)
        if !items.isEmpty, !inspectorDismissed { showInspector(true) }
    }
    func showScope(_ target: Scope) {
        search.stringValue = ""; pendingScope = target; reload()
    }
    func search(for text: String) {
        search.stringValue = text.contains(" ") ? "\"\(text)\"" : text
        if let row = rows.firstIndex(where:{ $0.scope == .all }), sidebar.selectedRow != row {
            updatingSidebar = true; sidebar.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); updatingSidebar = false
            scope = .all; collectionTitle = "All Items"
        }
        loadItems()
    }
    /// A notice over the grid. With `undo`, the action name it reports, it offers Undo while that is still the last edit.
    func notify(_ message: String, undo name: String? = nil) {
        toast.show(message,action:name.map { name in ("Undo",{ [weak self] in
            guard let manager = self?.window.undoManager, manager.canUndo, manager.undoActionName == name else { NSSound.beep(); return }
            manager.undo()
        }) })
    }

    // MARK: Item edits (undoable)

    /// Runs an item edit off the main thread, registers its undo, reloads and optionally shows a notice.
    func edit(_ name: String, notice: String? = nil, _ work: @escaping (LibraryDatabase) throws -> [ItemState]) {
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let states = try work(self.database)
                DispatchQueue.main.async {
                    self.registerItemUndo(name,states)
                    self.preserveNextLoad = true; self.reload()
                    if let notice { self.notify(notice,undo:name) }
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    func registerItemUndo(_ name: String, _ states: [ItemState]) {
        guard !states.isEmpty else { return }
        registerUndo(name) { target in
            do {
                let current = try target.database.snapshot(ids:states.map(\.id))
                try target.database.restore(states)
                target.registerItemUndo(name,current)
                target.preserveNextLoad = true; target.reload()
            } catch { target.showError(error) }
        }
    }
    /// Edits save off the main thread and register their undo afterwards, outside any event. The undo manager only
    /// closes its automatic group at the end of an event, so such a registration gets a group of its own; otherwise
    /// the next edit would join it and one Undo would take back both.
    func registerUndo(_ name: String, _ handler: @escaping (AppController) -> Void) {
        guard let manager = window.undoManager else { return }
        // With grouping by event on, beginUndoGrouping would first open the automatic event group and leave it open.
        let own = manager.groupingLevel == 0
        if own { manager.groupsByEvent = false; manager.beginUndoGrouping() }
        manager.registerUndo(withTarget:self,handler:handler)
        manager.setActionName(name)
        if own { manager.endUndoGrouping(); manager.groupsByEvent = true }
    }
    func addTags(_ tags: [String], to items: [ShelfItem]) { edit("Add Tag") { try $0.addTags(tags,to:items.map(\.id)) } }
    func removeTags(_ tags: [String], from items: [ShelfItem]) { edit("Remove Tag") { try $0.removeTags(tags,from:items.map(\.id)) } }
    func setTitle(_ title: String, for item: ShelfItem) { edit("Rename") { try $0.setTitle(title,for:[item.id]) } }
    func setNote(_ note: String, for item: ShelfItem) { setNote(note,for:[item]) }
    func setNote(_ note: String, for items: [ShelfItem]) { edit("Edit Note") { try $0.setNote(note,for:items.map(\.id)) } }
    func setAuthor(_ author: String, for item: ShelfItem) { setAuthor(author,for:[item]) }
    func setAuthor(_ author: String, for items: [ShelfItem]) { edit("Edit Author") { try $0.setAuthor(author,for:items.map(\.id)) } }
    func setSource(_ source: String, for item: ShelfItem) { setSource(source,for:[item]) }
    func setSource(_ source: String, for items: [ShelfItem]) { edit("Edit Source") { try $0.setSource(source,for:items.map(\.id)) } }
    func setLiked(_ items: [ShelfItem], _ liked: Bool) {
        guard !items.isEmpty else { return }
        edit(liked ? "Like" : "Unlike") { try $0.setLiked(items.map(\.id),liked) }
    }
    func addToCollection(_ items: [ShelfItem], id: String, name: String) {
        guard !items.isEmpty else { return }
        edit("Add to Collection",notice:"Added \(Self.count(items)) to \(name)") { try $0.addItems(items.map(\.id),to:id) }
    }
    func removeFromCollection(_ items: [ShelfItem], id: String) {
        edit("Remove from Collection") { try $0.removeItems(items.map(\.id),from:id) }
    }
    var semanticSearch: Bool { (UserDefaults.standard.object(forKey:"semanticSearch") as? Bool) ?? true }
    /// Search by meaning: images whose labels answer the words of a plain-text search, after the exact matches.
    /// Filters and quoted phrases ask for exactly what they say, so they get no extras.
    /// `best`: the strongest direct matches, which also lead the search for look-alikes.
    func relatedItems(query: String, scope: Scope, vocabulary: [String], excluding: Set<String>, best: [String] = []) throws -> [ShelfItem] {
        let parsed = SearchQuery(query)
        guard !vocabulary.isEmpty, parsed.clauses.isEmpty, parsed.hasText, !parsed.terms.contains(where:\.phrase) else { return [] }
        let words = parsed.terms.filter { !$0.negated }.map(\.text).joined(separator:" ")
        var weights = SemanticSearch.expand(words,vocabulary:vocabulary)
        // A description gets the Mac's own reading of it too, where the model is there.
        for (rank,label) in DescribedSearch.labels(for:words,vocabulary:vocabulary).enumerated() { weights[label] = max(weights[label] ?? 0,0.95 - Double(rank) * 0.04) }
        guard !weights.isEmpty || !best.isEmpty else { return [] }
        let rules = SmartRules(match:.any,rules:weights.keys.map { SmartRule(.tag,.is,$0) })
        let inside = scope == .all ? nil : Set(try database.items(scope:scope).map(\.id))
        let found = weights.isEmpty ? [] : try database.items(scope:.smart(rules)).filter { !excluding.contains($0.id) && inside?.contains($0.id) != false }
        // Colours a description names ("warm", "blue", "dark") lift the matches that have them.
        let colours = words.split(separator:" ").flatMap { ColorMath.named(String($0)) }
        func score(_ item: ShelfItem) -> Double {
            let lift = colours.contains { colour in ColorMath.matches(palette:item.colors.joined(separator:" "),target:colour) } ? 0.15 : 0
            return SemanticSearch.score(item,weights) + lift
        }
        let ranked = found.map { ($0,score($0)) }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(400).map(\.0)
        // Then pictures nobody tagged that look like the best matches: found by how they look, not by words.
        let seeds = Array((best + ranked.map(\.id)).prefix(3))
        guard !seeds.isEmpty else { return ranked }
        let prints = similarityQueue.sync { loadedPrints() }
        var seen = excluding.union(ranked.map(\.id)), lookalikes: [(ShelfItem,Float)] = []
        for seed in seeds {
            for neighbour in VisualSimilarity.nearest(to:seed,in:prints,limit:12) where neighbour.distance < 0.62 && seen.insert(neighbour.id).inserted {
                guard inside?.contains(neighbour.id) != false, let item = try database.item(id:neighbour.id), item.trashed == nil else { continue }
                lookalikes.append((item,neighbour.distance))
            }
        }
        return Array(ranked) + lookalikes.sorted { $0.1 < $1.1 }.prefix(60).map(\.0)
    }
    /// The regular collection being shown, if any.
    var currentCollection: String? {
        if case .collection(let id,_) = scope, regularCollections.contains(where:{ $0.id == id }) { return id }
        return nil
    }
    /// Drag to arrange: the collection switches to your own (Manual) order and keeps it.
    func reorderItems(_ ids: [String], before: String?) {
        guard let collection = currentCollection else { return }
        // Switching to Manual starts from the order on screen, so only the dragged items move.
        let previous = sort, ascendingBefore = ascending
        let visible = sort == .custom ? nil : grid.items.map(\.id)
        if sort != .custom { sort = .custom; saveSort(); notify("Arranged by hand. Choose another sort to go back.",undo:"Arrange") }
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let first = try visible.map { try self.database.reorder($0,before:nil,in:collection) } ?? []
                let moved = try self.database.reorder(ids,before:before,in:collection)
                let seen = Set(first.map(\.id)), states = first + moved.filter { !seen.contains($0.id) }
                DispatchQueue.main.async { self.registerArrangeUndo(states,sort:previous,ascending:ascendingBefore); self.preserveNextLoad = true; self.reload() }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    /// Undoing an arrangement also puts back the sort it replaced, so the grid looks as it did.
    private func registerArrangeUndo(_ states: [ItemState], sort previous: Sort, ascending previousAscending: Bool) {
        let arranged = sort, arrangedAscending = ascending
        registerUndo("Arrange") { target in
            do {
                let current = try target.database.snapshot(ids:states.map(\.id))
                try target.database.restore(states)
                target.sort = previous; target.ascending = previousAscending; target.saveSort()
                target.registerArrangeUndo(current,sort:arranged,ascending:arrangedAscending)
                target.preserveNextLoad = true; target.reload()
            } catch { target.showError(error) }
        }
    }
    static func count(_ items: [ShelfItem]) -> String { items.count == 1 ? "“\(items[0].title)”" : "\(items.count) items" }
    @objc func toggleLikeSelected() { setLiked(selection,!selection.allSatisfy(\.liked)) }
    @objc func removeSelected() { remove(selection) }
    @objc func putBackSelected() {
        let items = selection
        edit("Put Back",notice:"Put back \(Self.count(items))") { try $0.putBack(items.map(\.id)) }
    }
    /// Moves items to the library's trash (the original files are untouched), or deletes them for good from the Trash.
    func remove(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        if inTrash { deleteImmediately(items); return }
        let ids = Set(items.map(\.id)), list = grid.items
        let after = list.drop { !ids.contains($0.id) }.first { !ids.contains($0.id) } ?? list.last { !ids.contains($0.id) }
        workQueue.async { [weak self] in
            do { guard let states = try self?.database.moveToTrash(Array(ids)) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.registerItemUndo("Move to Trash",states)
                    self.grid.select(after.map { [$0.id] } ?? [],focus:after?.id)
                    self.preserveNextLoad = true; self.reload()
                    self.notify("Moved \(Self.count(items)) to the Trash. Original files are kept.",undo:"Move to Trash")
                }
            } catch { DispatchQueue.main.async { self?.showError(error) } }
        }
    }
    func deleteImmediately(_ items: [ShelfItem]) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete \(Self.count(items)) immediately?"
        alert.informativeText = "\(items.count == 1 ? "It's" : "They're") removed from your library for good. Original files on your Mac aren't touched."
        alert.addButton(withTitle:"Delete"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.workQueue.async {
                do { _ = try? self.database.snapshot(before:"Delete Immediately"); try self.database.deletePermanently(items.map(\.id)); DispatchQueue.main.async { self.grid.select([],focus:nil); self.reload() } }
                catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
    }
    @objc func emptyTrash() {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Empty the Trash?"; alert.informativeText = "Everything in the Trash is removed from your library for good. Original files on your Mac aren't touched."
        alert.addButton(withTitle:"Empty Trash"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.workQueue.async {
                do { _ = try? self.database.snapshot(before:"Empty Trash"); try self.database.emptyTrash(); DispatchQueue.main.async { self.grid.select([],focus:nil); self.reload() } }
                catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
    }

    // MARK: Item actions

    func itemMenu(_ items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
        }
        let single = items.count == 1, files = items.contains { $0.path.hasPrefix("/") }
        add("Open",#selector(viewSelected),enabled:single)
        add("Quick Look",#selector(quickLook))
        add("Open with Default App",#selector(openSelected),enabled:single)
        add("Show in Finder",#selector(revealSelected),enabled:files)
        if single, let openWith = openWithMenu(items[0]) {
            let entry = NSMenuItem(title:"Open With",action:nil,keyEquivalent:""); entry.submenu = openWith; menu.addItem(entry)
        }
        if single, let show = showInCollectionItem(items[0]) { menu.addItem(show) }
        add("Find Similar",#selector(findSimilar),enabled:single && items[0].hasLook)
        if single, items[0].kind == "image", items[0].path.hasPrefix("/") { add("Set as Desktop Picture",#selector(setDesktopPicture)) }
        menu.addItem(.separator())
        add(items.allSatisfy(\.liked) ? "Unlike" : "Like",#selector(toggleLikeSelected))
        add("Add Tags…",#selector(showTagPicker))
        let collections = NSMenuItem(title:"Add to Collection",action:nil,keyEquivalent:""); collections.submenu = collectionMenu(for:items); menu.addItem(collections)
        if !otherLibraries.isEmpty {
            for (title,move) in [("Copy to Library",false),("Move to Library",true)] {
                let entry = NSMenuItem(title:title,action:nil,keyEquivalent:""); entry.submenu = libraryMenu(for:items,move:move); menu.addItem(entry)
            }
        }
        if case .collection(let id,_) = scope, regularCollections.contains(where:{ $0.id == id }) {
            let entry = NSMenuItem(title:"Remove from “\(collectionTitle)”",action:#selector(removeFromCurrentCollection(_:)),keyEquivalent:"")
            entry.target = self; entry.representedObject = id; menu.addItem(entry)
        }
        menu.addItem(.separator())
        if boardShown {
            add("Bring to Front",#selector(bringToFront)); add("Send to Back",#selector(sendToBack))
            menu.addItem(.separator())
        }
        add("Copy",#selector(copySelection))
        if items.contains(where:{ !$0.url.isEmpty || !$0.source.isEmpty }) { add(items.count == 1 ? "Copy Link" : "Copy Links",#selector(copyLinks)) }
        if items.contains(where:{ $0.kind == "link" }) {
            let looks = NSMenu()
            for (title,action) in [("Preview Image",#selector(reloadLinkPreview)),("Page Snapshot",#selector(snapshotLinks)),("Title Card",#selector(titleCardLinks))] {
                let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; looks.addItem(entry)
            }
            let entry = NSMenuItem(title:"Show Link As",action:nil,keyEquivalent:""); entry.submenu = looks; menu.addItem(entry)
        }
        add(items.count == 1 ? "Export…" : "Export \(items.count) Files…",#selector(exportSelected),enabled:files)
        add("Refresh Thumbnail",#selector(refreshThumbnails))
        menu.addItem(.separator())
        if inTrash { add("Put Back",#selector(putBackSelected)); add("Delete Immediately…",#selector(removeSelected)) }
        else { add("Move to Trash",#selector(removeSelected)) }
        return menu
    }
    func collectionMenu(for items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu()
        for (id,name) in regularCollections {
            let entry = NSMenuItem(title:name,action:#selector(addSelectionToCollection(_:)),keyEquivalent:""); entry.target = self; entry.representedObject = id
            entry.state = !items.isEmpty && items.allSatisfy { $0.collections.contains(id) } ? .on : .off
            menu.addItem(entry)
        }
        if !regularCollections.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title:"New Collection…",action:#selector(newCollectionWithSelection),keyEquivalent:""); new.target = self; menu.addItem(new)
        return menu
    }
    func emptyGridMenu() -> NSMenu {
        let menu = NSMenu()
        for (title,action) in [("Add Files or Folder…",#selector(importPanel)),("Paste",#selector(pasteIntoLibrary)),("Watch a Folder…",#selector(watchFolderPanel)),("Import Library…",#selector(importLibraryPanel))] {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let sortEntry = NSMenuItem(title:"Sort By",action:nil,keyEquivalent:""); sortEntry.submenu = sortMenu(); menu.addItem(sortEntry)
        let captions = NSMenuItem(title:"Show Filenames",action:#selector(toggleCaptions),keyEquivalent:""); captions.target = self
        captions.state = grid.showsCaptions ? .on : .off; menu.addItem(captions)
        return menu
    }
    @objc func addSelectionToCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if sender.state == .on { removeFromCollection(selection,id:id) } else { addToCollection(selection,id:id,name:sender.title) }
    }
    @objc func removeFromCurrentCollection(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { removeFromCollection(selection,id:id) }
    }
    @objc func newCollectionWithSelection() {
        let entry = NSMenuItem(); entry.identifier = .init("withSelection"); newCollection(entry)
    }
    @objc func copySelection() { grid.copy(nil) }
    /// Saves web addresses as link cards (and addresses of pictures as media, unless `asLinks`).
    func saveLinks(_ urls: [URL], asLinks: Bool = false) {
        guard !urls.isEmpty else { return }
        do {
            let added = try links.save(urls,into:currentCollection,asLinks:asLinks)
            reload()
            if !added.isEmpty { notify(added.count == 1 ? "Saved the link" : "Saved \(added.count) links") }
        } catch { showError(error) }
    }
    /// Keeps colors as swatch cards in the current collection; one already saved isn't added twice.
    func saveColors(_ hexes: [String]) {
        let swatches = hexes.compactMap { ShelfItem.color($0) }
        guard !swatches.isEmpty else { return }
        let into = currentCollection
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let before = Set(try self.database.snapshot(ids:swatches.map(\.id)).map(\.id))
                try self.database.insert(swatches,into:into)
                let added = swatches.filter { !before.contains($0.id) }.count
                DispatchQueue.main.async {
                    self.reload()
                    self.notify(added == 0 ? "\(swatches.count == 1 ? "That color is" : "Those colors are") already saved"
                                : "Saved \(added == 1 ? "1 color" : "\(added) colors")")
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    @objc func pasteAsLink() {
        let text = NSPasteboard.general.string(forType:.string) ?? NSPasteboard.general.string(forType:.URL) ?? ""
        let urls = LinkMetadata.urls(in:text)
        urls.isEmpty ? NSSound.beep() : saveLinks(urls,asLinks:true)
    }
    @objc func copyLinks() {
        let addresses = selection.compactMap { $0.url.isEmpty ? ($0.source.isEmpty ? nil : $0.source) : $0.url }
        guard !addresses.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(addresses.joined(separator:"\n"),forType:.string)
        notify(addresses.count == 1 ? "Copied the link" : "Copied \(addresses.count) links")
    }
    @objc func reloadLinkPreview() {
        for item in selection where item.kind == "link" { links.refresh(item) }
        notify("Loading a fresh preview…")
    }
    @objc func snapshotLinks() {
        for item in selection where item.kind == "link" { links.snapshotPage(item) }
        notify("Taking a snapshot of the page…")
    }
    @objc func titleCardLinks() { for item in selection where item.kind == "link" { links.showTitleCard(item) } }
    @objc func pasteIntoLibrary() { grid.paste(nil) }
    @objc func quickLook() { grid.toggleQuickLook() }
    @objc func viewSelected() { if let selected { showViewer(selected) } }
    @objc func revealSelected() { reveal(selection) }
    func reveal(_ items: [ShelfItem]) {
        let urls = items.filter { $0.path.hasPrefix("/") }.map { URL(fileURLWithPath:$0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func open(_ item: ShelfItem) {
        if item.kind == "link", let url = URL(string:item.url.isEmpty ? item.source : item.url) { NSWorkspace.shared.open(url); return }
        guard item.path.hasPrefix("/") else { return }
        let file = URL(fileURLWithPath:item.path).resolvingSymlinksInPath()
        // Browser captures land in the library's media folder: open one only while its bytes are still an image or video.
        let media = database.root.appendingPathComponent("media",isDirectory:true).resolvingSymlinksInPath().path + "/"
        if file.path.hasPrefix(media), !["image","video"].contains(item.kind) || (try? CaptureMedia.inspect(file)) == nil {
            NSSound.beep(); return
        }
        NSWorkspace.shared.open(file)
    }
    @objc func openSelected() { if let selected { open(selected) } }
    @objc func focusSearch() { if let searchItem { searchItem.beginSearchInteraction() } else { window.makeFirstResponder(search) } }

    // MARK: Importing

    @objc func importPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Add images and videos. Originals stay in their folders."
        panel.beginSheetModal(for:window) { [weak self] response in if response == .OK { self?.importURLs(panel.urls) } }
    }
    func keepTemporaryFile(_ url: URL) throws -> URL {
        let path = url.resolvingSymlinksInPath().path
        if path.hasPrefix(database.root.resolvingSymlinksInPath().path + "/") { return url }
        guard ["/private/var/folders/","/var/folders/","/private/tmp/","/tmp/"].contains(where:{ path.hasPrefix($0) }) || path.contains("/TemporaryItems/") else { return url }
        let media = database.mediaFolder
        try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        var target = media.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath:target.path) { target = media.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + url.lastPathComponent) }
        try FileManager.default.copyItem(at:url,to:target)
        return target
    }
    /// Adds files and folders. A folder becomes a collection of the same name unless `collection` is given.
    /// The folder on disk a watched-folder place shows, and the watched folder it's in.
    func watchedDirectory(_ scope: Scope) -> (path: String, folder: String)? {
        guard let folders = try? database.connectedFolders() else { return nil }
        switch scope {
        case .folder(let id): return folders.first { $0.id == id }.map { ($0.path,$0.id) }
        case .folderPath(let path): return folders.first { path.hasPrefix($0.path + "/") }.map { (path,$0.id) }
        default: return nil
        }
    }
    /// Files dropped on a watched folder go into that folder on disk, as in the Finder; the watch then adds them.
    func copyIntoWatchedFolder(_ urls: [URL], _ place: (path: String, folder: String)) {
        let directory = URL(fileURLWithPath:place.path,isDirectory:true), name = directory.lastPathComponent
        workQueue.async { [weak self] in
            guard let self else { return }
            var copied = 0
            for url in urls where url.deletingLastPathComponent().standardizedFileURL.path != directory.standardizedFileURL.path {
                var target = directory.appendingPathComponent(url.lastPathComponent), n = 2
                let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                while FileManager.default.fileExists(atPath:target.path) {
                    target = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"); n += 1
                }
                do { try FileManager.default.copyItem(at:url,to:target); copied += 1 }
                catch { DispatchQueue.main.async { self.showError(error) }; return }
            }
            DispatchQueue.main.async {
                self.folders.rescan(place.folder)
                self.notify(copied == 0 ? "Already in “\(name)”" : "Copied \(copied == 1 ? "1 file" : "\(copied) files") into “\(name)”")
            }
        }
    }
    func importURLs(_ urls: [URL], into collection: String? = nil) {
        let target = collection ?? {
            if case .collection(let id,_) = scope, regularCollections.contains(where:{ $0.id == id }) { return id }
            return nil
        }()
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Drags from Photos, Messages and browsers hand over temporary files macOS deletes later: keep a copy.
                let urls = try urls.map { try self.keepTemporaryFile($0) }
                var added = 0
                for group in MediaFiles.scanGroups(urls) {
                    let into = try target ?? group.group.flatMap { try self.database.collection(named:$0,createIfMissing:true)?.id }
                    added += try self.database.insert(group.items,into:into).count
                }
                DispatchQueue.main.async {
                    self.reload()
                    self.notify(added == 0 ? "Nothing new to add" : "Added \(added == 1 ? "1 item" : "\(added.formatted()) items")")
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }
    /// Pasted or dropped image data with no file behind it is saved into the library's media folder.
    func importImageData(_ data: Data, ext: String) {
        do {
            let media = database.mediaFolder
            try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
            let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            var url = media.appendingPathComponent("Pasted \(format.string(from:Date())).\(ext)")
            if FileManager.default.fileExists(atPath:url.path) { url = media.appendingPathComponent("Pasted \(format.string(from:Date())) \(UUID().uuidString.prefix(4)).\(ext)") }
            try data.write(to:url,options:.atomic)
            importURLs([url])
        } catch { showError(error) }
    }

    // MARK: Watched folders

    @objc func watchFolderPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Watch"; panel.message = "Folio adds the images in this folder and keeps up as files come and go. Files stay where they are."
        panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.watch(url) } }
    }
    func watch(_ url: URL) {
        setActivity("Reading \(FolderWatcher.displayName(url.path))…")
        folders.watch(url) { [weak self] result in
            self?.setActivity(nil)
            switch result {
            case .success(let folder): self?.notify("Watching \(FolderWatcher.displayName(folder.path))"); self?.showScope(.folder(folder.id))
            case .failure(let error): self?.showError(error)
            }
        }
    }
    @objc func revealFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let path = try? database.connectedFolders().first(where:{ $0.id == id })?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])
    }
    @objc func revealSubfolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) }
    }
    @objc func rescanFolder(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { folders.rescan(id) } }
    @objc func stopWatching(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = rows.first(where:{ $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Stop watching “\(row.title)”?"
        alert.informativeText = "Items already added stay in your library. New files in the folder won't be added."
        alert.addButton(withTitle:"Stop Watching"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.folders.unwatch(id) { self?.pendingScope = .all; self?.reload() }
        }
    }

    // MARK: Other

    @objc func copyKey() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(server.token,forType:.string)
        notify("Connection key copied")
    }
    @objc func exportLibrary() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "library.json"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.workQueue.async { do { try self.database.exportJSON(to:url) } catch { DispatchQueue.main.async { self.showError(error) } } }
        }
    }
    func startBenchmark(to url: URL) {
        let waitStart = CACurrentMediaTime()
        func wait() {
            if grid.loadedVisibleCount < grid.visibleCount && CACurrentMediaTime() - waitStart < 15 {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:wait); return
            }
            let previewMS = (CACurrentMediaTime() - waitStart) * 1000
            let firstReady = grid.loadedVisibleCount == grid.visibleCount
            if let screenshot = argument("--screenshot"), let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                }
                try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:screenshot))
            }
            grid.resetMeasurements()
            var step = 0, intervals: [Double] = [], last = CACurrentMediaTime()
            var readySamples = 0, visibleSamples = 0
            let steps = Int(argument("--benchmark-steps") ?? "360") ?? 360
            let fullSweep = args.contains("--benchmark-full-sweep")
            let rate = max(60,Double(argument("--benchmark-scroll-rate") ?? "2400") ?? 2400)
            let maxY = min(max(0,grid.bounds.height - scroll.contentSize.height),fullSweep ? .greatestFiniteMagnitude : rate * Double(steps) / 120)
            benchmarkTimer = Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let now = CACurrentMediaTime(); intervals.append(now-last); last = now
                // Sample the prior viewport after its full timer interval to load previews.
                readySamples += self.grid.loadedVisibleCount; visibleSamples += self.grid.visibleCount
                let phase = Double(step) / Double(max(1,steps-1))
                // Traverse a reproducible out-and-back path at the requested scroll rate.
                let y = maxY * (phase < 0.5 ? phase * 2 : (1-phase)*2)
                self.scroll.contentView.scroll(to:NSPoint(x:0,y:y)); self.scroll.reflectScrolledClipView(self.scroll.contentView)
                step += 1
                if step >= steps {
                    timer.invalidate()
                    let updates = Distribution(seconds:self.grid.updateTimes), ticks = Distribution(seconds:intervals)
                    var report: [String:Any] = [
                        "app":AppIdentity.name,"version":AppIdentity.version,"items":self.grid.items.count,"steps":steps,
                        "startupToItemsMS":self.startupMS,"firstScreenPreviewWaitMS":previewMS,
                        "gridUpdateCPU":self.dictionary(updates),"mainRunLoopIntervals":self.dictionary(ticks),
                        "peakTileLayers":self.grid.peakLayers,"viewportWidth":self.scroll.contentSize.width,"viewportHeight":self.scroll.contentSize.height,
                        "tileSize":self.grid.tileSize,"gridStyle":self.grid.style.rawValue,
                        "note":"CPU update times and timer intervals; not GPU frame times. Preview readiness measured separately."
                    ]
                    report["visiblePreviewReadyFraction"] = Double(readySamples) / Double(max(1,visibleSamples))
                    report["firstScreenPreviewsReady"] = firstReady
                    report["scrollMode"] = fullSweep ? "full-library stress sweep" : "fixed-speed scrolling"
                    report["nominalScrollPointsPerSecond"] = fullSweep ? maxY * 120 / Double(max(1,steps)) : rate
                    report["scrollSpanPoints"] = maxY
                    do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
                    catch { self.showError(error) }
                    if args.contains("--quit-after-benchmark") { NSApp.terminate(nil) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:wait)
    }
    /// Development check: renders the whole window, toolbar included, without screen-recording access.
    @MainActor func snapshotWindow(to path: String) {
        let target: NSWindow = argument("--settings") != nil ? SettingsWindowController.shared.window ?? window : window
        for (shown,file) in [(target,path),(target.attachedSheet,path.replacingOccurrences(of:".png",with:"-sheet.png"))] {
            guard let frameView = shown?.contentView?.superview,
                  let bitmap = frameView.bitmapImageRepForCachingDisplay(in:frameView.bounds) else { continue }
            target.effectiveAppearance.performAsCurrentDrawingAppearance { frameView.cacheDisplay(in:frameView.bounds,to:bitmap) }
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:file))
        }
        if let sheet = target.attachedSheet { target.endSheet(sheet,returnCode:.abort) }
        // Development check: snapshots can't show animation, so say how many GIFs are moving.
        if args.contains("--report-motion") { fputs("GIFs playing: \(grid.playingGIFs)\n",stderr) }
        if args.contains("--quit-after-snapshot") { NSApp.terminate(nil) }
    }
    func dictionary(_ d: Distribution) -> [String:Any] { ["count":d.count,"medianMS":d.medianMS,"p95MS":d.p95MS,"maxMS":d.maxMS] }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = AppIdentity.name; alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for:window) } else { alert.runModal() }
    }
}

extension AppController: NSMenuDelegate {
    /// Fills the Item ▸ Add to Collection and View ▸ Sort By submenus when they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let owner = menu.supermenu?.items.first(where:{ $0.submenu === menu }) else { return }
        let source = owner.identifier?.rawValue == "sortBy" ? sortMenu() : collectionMenu(for:selection)
        menu.removeAllItems()
        for entry in source.items { source.removeItem(entry); menu.addItem(entry) }
    }
}

let app = NSApplication.shared
let controller = AppController()
// Start without a Dock icon when it's hidden, rather than flashing one.
app.setActivationPolicy(UserDefaults.standard.object(forKey:"general.dockIcon") as? Bool == false ? .accessory : .regular)
app.delegate = controller
app.run()

if argument("--analysis-report") != nil { fputs("Application run returned\n",stderr) }
