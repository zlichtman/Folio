import AppKit
import Quartz
import ShelfCore

/// The Board view of a collection: switching to it, loading and saving where things sit, and its menus.
extension AppController {
    var boardCollections: Set<String> { Set(UserDefaults.standard.stringArray(forKey:"boardCollections") ?? []) }
    /// Which board the current place has: a collection or smart folder by its id, a tag, All Items, the Inbox,
    /// Liked or a watched folder by a key of its own. The Trash and search results have none.
    var boardKey: String? {
        guard results == nil else { return nil }
        switch scope {
        case .collection(let id,_): return id
        case .all: return "scope:all"
        case .inbox: return "scope:inbox"
        case .liked: return "scope:liked"
        case .folder(let id): return "folder:" + id
        case .folderPath(let path): return "path:" + path
        case .smart(let rules) where rules.rules.count == 1 && rules.rules[0].field == .tag && rules.groups.isEmpty: return "tag:" + rules.rules[0].value.lowercased()
        default: return nil
        }
    }
    /// The current collection is shown as a board (and nothing narrows it: boards show the whole collection).
    var wantsBoard: Bool {
        guard let id = boardKey else { return false }
        return boardCollections.contains(id) && results == nil && effectiveQuery.trimmingCharacters(in:.whitespaces).isEmpty
    }
    func setBoard(_ on: Bool) {
        guard let id = boardKey else { return }
        var set = boardCollections
        if on { set.insert(id) } else { set.remove(id) }
        UserDefaults.standard.set(Array(set),forKey:"boardCollections")
        loadItems()
    }
    @objc func showBoard() { if boardKey == nil { notify("The Trash and search results don't have a board.") } else { setBoard(true) } }
    func buildBoard(in main: NSView) {
        board = BoardView(thumbnails:thumbnails)
        boardScroll.contentView = CenteringClipView(); boardScroll.scrollerStyle = .overlay
        boardScroll.documentView = board; boardScroll.drawsBackground = false; boardScroll.hasVerticalScroller = true; boardScroll.hasHorizontalScroller = true
        boardScroll.autohidesScrollers = true; boardScroll.allowsMagnification = true; boardScroll.minMagnification = 0.1; boardScroll.maxMagnification = 4
        boardScroll.isHidden = true; boardScroll.automaticallyAdjustsContentInsets = false
        NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveMagnifyNotification,object:boardScroll,queue:.main) { [weak self] _ in self?.board.refreshForZoom() }
        // Pieces come into being as they scroll into view.
        boardScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:boardScroll.contentView,queue:.main) { [weak self] _ in self?.board.refreshForZoom() }
        board.didChangeSelection = { [weak self] items in self?.selectionChanged(items) }
        board.openItem = { [weak self] item in self?.showViewer(item) }
        board.removeItems = { [weak self] items in self?.remove(items) }
        board.quickLook = { [weak self] in self?.boardQuickLook() }
        board.shortcut = { [weak self] key in self?.singleKey(key) ?? false }
        board.escape = { [weak self] in self?.goBack() }
        board.menuForItems = { [weak self] items in self?.itemMenu(items) }
        board.emptyMenu = { [weak self] in self?.boardMenu() }
        board.commit = { [weak self] changes in self?.saveBoard(changes) }
        boardScroll.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(boardScroll,positioned:.above,relativeTo:scroll)
        NSLayoutConstraint.activate([boardScroll.leadingAnchor.constraint(equalTo:main.leadingAnchor),boardScroll.trailingAnchor.constraint(equalTo:main.trailingAnchor),
                                     boardScroll.topAnchor.constraint(equalTo:main.safeAreaLayoutGuide.topAnchor),boardScroll.bottomAnchor.constraint(equalTo:main.bottomAnchor)])
    }
    /// Shows the board for these items, placing any that have no spot yet below the rest.
    func loadBoard(_ items: [ShelfItem], keepSelection: Bool) {
        guard let collection = boardKey else { return }
        let firstOpen = boardScroll.isHidden
        workQueue.async { [weak self] in
            guard let self else { return }
            var placements = (try? self.database.boardPlacements(collection:collection)) ?? [:]
            // A big board starts roughly square rather than as one long strip.
            let fresh = BoardLayout.place(items,around:placements,rowWidth:max(1600,(Double(items.count).squareRoot() * 300).rounded()))
            if !fresh.isEmpty { _ = try? self.database.setBoardPlacements(collection:collection,fresh.mapValues { .some($0) }); placements.merge(fresh) { $1 } }
            DispatchQueue.main.async {
                guard self.boardKey == collection, self.wantsBoard else { return }
                self.boardShown = true
                self.boardScroll.isHidden = !self.viewer.isHidden; self.scroll.isHidden = true; self.emptyState.isHidden = !items.isEmpty
                self.board.show(items,placements:placements,keepSelection:keepSelection)
                if firstOpen { items.count > 150 ? self.openLargeBoard() : self.zoomBoardToFit() }
                self.updateLayoutSwitch()
            }
        }
    }
    func hideBoard() {
        if boardShown { boardShown = false; boardScroll.isHidden = true; scroll.isHidden = !viewer.isHidden }
        updateLayoutSwitch()
    }
    /// The layouts on offer: Board needs a place to keep its layout, so the Trash and search results go without it.
    var layoutChoices: [String] { ["Rows","Columns"] + (boardKey == nil ? [] : ["Board"]) + ["List","Infinity"] }
    /// Rows, Columns, Board or List.
    func updateLayoutSwitch() {
        let choices = layoutChoices
        if (0..<styleSwitch.segmentCount).map({ styleSwitch.label(forSegment:$0) ?? "" }) != choices {
            styleSwitch.segmentCount = choices.count
            let tips = ["Rows":"Justified rows · ⌘1","Columns":"Columns · ⌘2","Board":"Lay these out by hand · ⌘3","List":"A list with names and details · ⌘4",
                        "Infinity":"An endless wall to wander · ⌘5"]
            for (index,title) in choices.enumerated() { styleSwitch.setLabel(title,forSegment:index); styleSwitch.setWidth(0,forSegment:index); styleSwitch.setToolTip(tips[title],forSegment:index) }
        }
        let current = boardShown ? "Board" : ["rows":"Rows","columns":"Columns","list":"List","infinity":"Infinity"][grid.style.rawValue] ?? "Rows"
        styleSwitch.selectedSegment = choices.firstIndex(of:current) ?? 0
        if viewer.isHidden { zoomBar?.isHidden = boardShown || infinityShown || grid.items.isEmpty }
    }
    private func saveBoard(_ changes: [String:BoardPlacement]) {
        guard let collection = boardKey, !changes.isEmpty else { return }
        workQueue.async { [weak self] in
            guard let self, let previous = try? self.database.setBoardPlacements(collection:collection,changes.mapValues { .some($0) }) else { return }
            DispatchQueue.main.async { self.registerBoardUndo(collection,previous) }
        }
    }
    private func registerBoardUndo(_ collection: String, _ previous: [String:BoardPlacement?]) {
        registerUndo("Move on Board") { target in
            guard let undone = try? target.database.setBoardPlacements(collection:collection,previous) else { return }
            target.registerBoardUndo(collection,undone)
            target.preserveNextLoad = true; target.loadItems()
        }
    }
    func boardMenu() -> NSMenu {
        let menu = NSMenu()
        for (title,action) in [("Zoom to Fit",#selector(zoomBoardToFit)),("Actual Size",#selector(boardActualSize)),("Tidy Up",#selector(resetBoardLayout))] {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (title,action) in [("Add Files or Folder…",#selector(importPanel)),("Paste",#selector(pasteIntoLibrary))] {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:""); entry.target = self; menu.addItem(entry)
        }
        let grid = NSMenuItem(title:"Show as Rows",action:#selector(leaveBoard),keyEquivalent:""); grid.target = self; menu.addItem(grid)
        return menu
    }
    @objc func leaveBoard() { setBoard(false) }
    /// Hundreds of pictures fitted on screen are too small to see: start at the top left at a size you can read.
    func openLargeBoard() {
        let content = board.contentBounds
        guard !content.isNull else { return }
        boardScroll.magnification = 0.6
        boardScroll.contentView.scroll(to:CGPoint(x:max(0,content.minX - 40),y:max(0,content.minY - 40)))
        boardScroll.reflectScrolledClipView(boardScroll.contentView); board.refreshForZoom()
    }
    @objc func zoomBoardToFit() {
        let content = board.contentBounds
        guard !content.isNull, content.width > 0 else { return }
        let room = boardScroll.contentSize
        let padded = content.insetBy(dx:-40,dy:-40)
        let scale = min(1.25,max(boardScroll.minMagnification,min(room.width / padded.width,room.height / padded.height)))
        boardScroll.magnification = scale
        boardScroll.contentView.scroll(to:CGPoint(x:max(0,padded.midX - room.width / scale / 2),y:max(0,padded.midY - room.height / scale / 2)))
        boardScroll.reflectScrolledClipView(boardScroll.contentView); board.refreshForZoom()
    }
    @objc func boardActualSize() { boardScroll.magnification = 1; board.refreshForZoom() }
    /// Lays the board out again in the collection's order.
    @objc func resetBoardLayout() {
        guard let collection = boardKey else { return }
        workQueue.async { [weak self] in
            guard let self, let previous = try? self.database.resetBoard(collection:collection) else { return }
            DispatchQueue.main.async { self.registerBoardUndo(collection,previous); self.boardScroll.isHidden = true; self.loadItems() }
        }
    }
    @objc func bringToFront() { board.restack(front:true) }
    @objc func sendToBack() { board.restack(front:false) }
    func boardQuickLook() {
        grid.select(Set(board.selection),focus:board.selectedItems.first?.id)
        window.makeFirstResponder(grid); grid.toggleQuickLook()
    }
}
