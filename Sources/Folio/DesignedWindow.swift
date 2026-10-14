import AppKit
import ShelfCore

/// Hosts a plain view in a split view item.
final class HostController: NSViewController {
    private let hosted: NSView
    init(_ view: NSView) { hosted = view; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = hosted }
}

extension NSToolbarItem.Identifier {
    static let folioSearch = Self("folio.search")
    static let folioAdd = Self("folio.add")
    static let folioInspector = Self("folio.inspector")
    static let folioTitle = Self("folio.title")
}

extension AppController: NSToolbarDelegate {
    func buildDesignedWindow() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1380,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "All Items"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified; window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width:900,height:620); window.delegate = self; window.isReleasedWhenClosed = false
        let rail = Surface(Theme.sidebarTint), main = Surface(Theme.canvas)
        backdrop.blendingMode = .behindWindow; backdrop.material = .underWindowBackground; backdrop.state = .active; backdrop.isHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(backdrop)
        NSLayoutConstraint.activate([backdrop.leadingAnchor.constraint(equalTo:main.leadingAnchor),backdrop.trailingAnchor.constraint(equalTo:main.trailingAnchor),
                                     backdrop.topAnchor.constraint(equalTo:main.topAnchor),backdrop.bottomAnchor.constraint(equalTo:main.bottomAnchor)])
        inspector = Inspector(app:self)
        inspector.place = { [weak self] in (self?.results?.title ?? self?.collectionTitle ?? "",self?.grid.items ?? []) }
        buildSidebar(in:rail); buildContent(in:main)
        split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController:HostController(rail))
        sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 280; sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController:HostController(main)); contentItem.minimumThickness = 420
        // The details panel sits on the sidebar's material, so the window reads as one surface with the grid in the middle.
        let material = NSVisualEffectView(); material.material = .sidebar; material.blendingMode = .behindWindow; material.state = .followsWindowActiveState
        let details = Surface(Theme.sidebarTint); inspector.view.translatesAutoresizingMaskIntoConstraints = false
        material.translatesAutoresizingMaskIntoConstraints = false; details.addSubview(material); details.addSubview(inspector.view)
        NSLayoutConstraint.activate([material.leadingAnchor.constraint(equalTo:details.leadingAnchor),material.trailingAnchor.constraint(equalTo:details.trailingAnchor),
                                     material.topAnchor.constraint(equalTo:details.topAnchor),material.bottomAnchor.constraint(equalTo:details.bottomAnchor)])
        NSLayoutConstraint.activate([inspector.view.leadingAnchor.constraint(equalTo:details.leadingAnchor),inspector.view.trailingAnchor.constraint(equalTo:details.trailingAnchor),
                                     inspector.view.topAnchor.constraint(equalTo:details.topAnchor),inspector.view.bottomAnchor.constraint(equalTo:details.bottomAnchor)])
        inspectorItem = NSSplitViewItem(inspectorWithViewController:HostController(details))
        inspectorItem.minimumThickness = 260; inspectorItem.maximumThickness = 380; inspectorItem.canCollapse = true; inspectorItem.isCollapsed = true
        split.splitViewItems = [sidebarItem,contentItem,inspectorItem]
        window.contentViewController = split
        let toolbar = NSToolbar(identifier:"FolioMainToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width:1380,height:860)); window.center()
        window.setFrameAutosaveName("FolioMainWindow")
        window.contentView?.layoutSubtreeIfNeeded()
        // The sidebar keeps the width it was dragged to.
        let savedWidth = UserDefaults.standard.double(forKey:"sidebarWidth")
        if savedWidth >= 190 { split.splitView.setPosition(min(280,savedWidth),ofDividerAt:0); window.contentView?.layoutSubtreeIfNeeded() }
        NotificationCenter.default.addObserver(forName:NSSplitView.didResizeSubviewsNotification,object:split.splitView,queue:.main) { [weak self] _ in
            guard let self, !sidebarItem.isCollapsed, let width = self.split.splitView.arrangedSubviews.first?.frame.width, width >= 190 else { return }
            UserDefaults.standard.set(Double(width),forKey:"sidebarWidth")
        }
        grid.resizeDocument(); grid.refresh()
        NotificationCenter.default.addObserver(forName:.folioThemeChanged,object:nil,queue:.main) { [weak self] _ in self?.applyGlass() }
        applyGlass()
    }
    /// Glass themes: the window turns see-through, with the desktop blurred behind the tint unless the theme is clear.
    func applyGlass() {
        let tint = Theme.family.glassTint
        window.isOpaque = tint == nil
        window.backgroundColor = tint == nil ? .windowBackgroundColor : .clear
        backdrop.isHidden = tint == nil || !Theme.family.glassBlurs
        window.contentView?.needsDisplay = true
    }
    private func buildSidebar(in rail: NSView) {
        sidebar = SidebarTable(); sidebar.headerView = nil
        // One column that always matches the sidebar's width, so counts never run past its edge.
        let column = NSTableColumn(identifier:.init("library")); column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column); sidebar.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebar.delegate = self; sidebar.dataSource = self; sidebar.style = .plain; sidebar.selectionHighlightStyle = .regular
        sidebar.backgroundColor = .clear; sidebar.floatsGroupRows = false; sidebar.intercellSpacing = NSSize(width:0,height:2)
        sidebar.registerForDraggedTypes([.folioItems,.folioCollection,.folioSidebarRow,.fileURL]); sidebar.setDraggingSourceOperationMask(.copy,forLocal:false)
        sidebar.setDraggingSourceOperationMask(.move,forLocal:true)
        sidebar.menuProvider = { [weak self] row in self?.sidebarMenu(for:row) }
        sidebar.setAccessibilityLabel("Library")
        let sideScroll = NSScrollView(); sideScroll.drawsBackground = false; sideScroll.hasVerticalScroller = true; sideScroll.autohidesScrollers = true; sideScroll.documentView = sidebar
        activity.maximumNumberOfLines = 2; activity.lineBreakMode = .byWordWrapping; activity.isHidden = true
        for view in [sideScroll,activity] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(view) }
        NSLayoutConstraint.activate([
            sideScroll.leadingAnchor.constraint(equalTo:rail.leadingAnchor),sideScroll.trailingAnchor.constraint(equalTo:rail.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo:rail.safeAreaLayoutGuide.topAnchor,constant:4),sideScroll.bottomAnchor.constraint(equalTo:activity.topAnchor,constant:-10),
            activity.leadingAnchor.constraint(equalTo:rail.leadingAnchor,constant:20),activity.trailingAnchor.constraint(equalTo:rail.trailingAnchor,constant:-14),
            activity.bottomAnchor.constraint(equalTo:rail.bottomAnchor,constant:-14)])
    }
    private func buildContent(in main: NSView) {
        search.placeholderString = "Search"; search.delegate = self
        search.sendsWholeSearchString = false; search.sendsSearchStringImmediately = true
        search.toolTip = "Search names, tags, notes and the text in images"
        scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top:0,left:0,bottom:56,right:0)
        scroll.scrollerInsets = NSEdgeInsets(top:0,left:0,bottom:-56,right:0); scroll.documentView = grid
        grid.didChangeSelection = { [weak self] items in self?.selectionChanged(items) }
        grid.openItem = { [weak self] item in self?.showViewer(item) }
        grid.importFiles = { [weak self] urls in
            guard let self else { return }
            if let place = self.watchedDirectory(self.scope) { self.copyIntoWatchedFolder(urls,place) } else { self.importURLs(urls) }
        }
        grid.importImage = { [weak self] data, ext in self?.importImageData(data,ext:ext) }
        grid.importLinks = { [weak self] urls in self?.saveLinks(urls) }
        grid.importColors = { [weak self] colors in self?.saveColors(colors) }
        grid.toggleLike = { [weak self] item in self?.setLiked([item],!item.liked) }
        grid.removeItems = { [weak self] items in self?.remove(items) }
        grid.menuForItems = { [weak self] items in self?.itemMenu(items) }
        grid.emptyMenu = { [weak self] in self?.emptyGridMenu() }
        // Floating controls: the layout switch in the middle, size and sort on the right.
        styleSwitch = NSSegmentedControl(labels:["Rows","Columns"],trackingMode:.selectOne,target:self,action:#selector(styleChanged(_:)))
        styleSwitch.segmentStyle = .capsule; styleSwitch.controlSize = .small; styleSwitch.font = .systemFont(ofSize:11,weight:.medium)
        styleSwitch.selectedSegment = grid.style == .rows ? 0 : grid.style == .columns ? 1 : 0
        styleSwitch.setToolTip("Justified rows · ⌘1",forSegment:0); styleSwitch.setToolTip("Columns · ⌘2",forSegment:1)

        let layoutCapsule = FloatingBar([styleSwitch],inset:3)
        zoom = NSSlider(value:grid.tileSize,minValue:120,maxValue:420,target:self,action:#selector(zoomChanged(_:)))
        zoom.controlSize = .mini; zoom.widthAnchor.constraint(equalToConstant:96).isActive = true; zoom.toolTip = "Thumbnail size"
        let smaller = capsuleButton("minus.magnifyingglass","Smaller · ⌘−",self,#selector(zoomOut)), larger = capsuleButton("plus.magnifyingglass","Larger · ⌘+",self,#selector(zoomIn))
        sortButton = capsuleButton("arrow.up.arrow.down","Sort",self,#selector(showSortMenu(_:)))
        filterButton.image = NSImage(systemSymbolName:"line.3.horizontal.decrease",accessibilityDescription:"Filter")
        filterButton.target = self; filterButton.action = #selector(showFilterMenu(_:)); filterButton.isBordered = false
        filterButton.bezelStyle = .accessoryBarAction; filterButton.contentTintColor = .secondaryLabelColor; filterButton.toolTip = "Show only images, videos, GIFs, liked or untagged items"
        filterButton.symbolConfiguration = .init(pointSize:12,weight:.medium); filterButton.widthAnchor.constraint(equalToConstant:22).isActive = true
        let divider = NSBox(); divider.boxType = .separator; divider.heightAnchor.constraint(equalToConstant:14).isActive = true
        let sizeCapsule = FloatingBar([smaller,zoom,larger,divider,filterButton,sortButton],spacing:4)
        emptyTitle.font = .systemFont(ofSize:17,weight:.semibold); emptyTitle.textColor = Theme.ink; emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize:13); emptyBody.textColor = Theme.muted; emptyBody.alignment = .center
        emptyBody.preferredMaxLayoutWidth = 340
        emptyIcon.symbolConfiguration = .init(pointSize:36,weight:.light); emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyActions.orientation = .horizontal; emptyActions.spacing = 8
        emptyState = NSStackView(views:[emptyIcon,emptyTitle,emptyBody,emptyActions]); emptyState.orientation = .vertical; emptyState.spacing = 8
        emptyState.setCustomSpacing(14,after:emptyIcon); emptyState.setCustomSpacing(18,after:emptyBody)
        viewer.thumbnails = thumbnails; viewer.isHidden = true
        viewer.didClose = { [weak self] item in self?.viewerClosed(item) }
        viewer.didShow = { [weak self] item in
            guard let self else { return }
            self.grid.select([item.id],focus:item.id); self.updateTitle(count:self.grid.items.count)
        }
        palette.isHidden = true
        palette.provider = { [weak self] mode, query in self?.paletteEntries(mode,query) ?? [] }
        palette.applyMarked = { [weak self] mode, ids in self?.paletteApply(mode,ids) }
        palette.didClose = { [weak self] in self?.paletteClosed() }
        grid.shortcut = { [weak self] key in self?.singleKey(key) ?? false }
        grid.escape = { [weak self] in self?.goBack() }
        grid.zoomChanged = { [weak self] size in self?.zoom.doubleValue = size }
        grid.canReorder = { [weak self] in self?.currentCollection != nil && self?.results == nil && self?.effectiveQuery.trimmingCharacters(in:.whitespaces).isEmpty == true }
        grid.reorder = { [weak self] ids, before in self?.reorderItems(ids,before:before) }
        viewer.shortcut = { [weak self] key in self?.singleKey(key) ?? false }
        for view in [scroll!,emptyState!,layoutCapsule,sizeCapsule,toast,viewer,palette,hints] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(view) }
        NSLayoutConstraint.activate([hints.centerXAnchor.constraint(equalTo:main.centerXAnchor),hints.centerYAnchor.constraint(equalTo:main.centerYAnchor)])
        hints.start()
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo:main.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:main.trailingAnchor),
            scroll.topAnchor.constraint(equalTo:main.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:main.bottomAnchor),
            layoutCapsule.centerXAnchor.constraint(equalTo:main.centerXAnchor),layoutCapsule.bottomAnchor.constraint(equalTo:main.bottomAnchor,constant:-14),
            sizeCapsule.trailingAnchor.constraint(equalTo:main.trailingAnchor,constant:-16),sizeCapsule.bottomAnchor.constraint(equalTo:layoutCapsule.bottomAnchor),
            sizeCapsule.leadingAnchor.constraint(greaterThanOrEqualTo:layoutCapsule.trailingAnchor,constant:12),
            toast.centerXAnchor.constraint(equalTo:main.centerXAnchor),toast.bottomAnchor.constraint(equalTo:layoutCapsule.topAnchor,constant:-10),
            emptyState.centerXAnchor.constraint(equalTo:scroll.centerXAnchor),emptyState.centerYAnchor.constraint(equalTo:scroll.centerYAnchor,constant:-24),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant:440),
            viewer.leadingAnchor.constraint(equalTo:main.leadingAnchor),viewer.trailingAnchor.constraint(equalTo:main.trailingAnchor),
            viewer.topAnchor.constraint(equalTo:main.topAnchor),viewer.bottomAnchor.constraint(equalTo:main.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo:main.leadingAnchor),palette.trailingAnchor.constraint(equalTo:main.trailingAnchor),
            palette.topAnchor.constraint(equalTo:main.topAnchor),palette.bottomAnchor.constraint(equalTo:main.bottomAnchor)])
        floating = [layoutCapsule,sizeCapsule]
        zoomBar = sizeCapsule
        buildBoard(in:main)
        infinity = InfinityView(thumbnails:thumbnails); infinity.isHidden = true
        infinity.openItem = { [weak self] item in self?.showViewer(item) }
        infinity.escape = { [weak self] in self?.goBack() }
        infinity.shortcut = { [weak self] key in SingleKeys.action(for:key) == "shuffle" && self?.singleKey(key) == true }
        infinity.quickLook = { [weak self] item in
            guard let self else { return }
            self.grid.select([item.id],focus:item.id); self.window.makeFirstResponder(self.grid); self.grid.toggleQuickLook()
        }
        infinity.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(infinity,positioned:.above,relativeTo:scroll)
        NSLayoutConstraint.activate([infinity.leadingAnchor.constraint(equalTo:main.leadingAnchor),infinity.trailingAnchor.constraint(equalTo:main.trailingAnchor),
                                     infinity.topAnchor.constraint(equalTo:main.safeAreaLayoutGuide.topAnchor),infinity.bottomAnchor.constraint(equalTo:main.bottomAnchor)])
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .folioSearch:
            let item = NSSearchToolbarItem(itemIdentifier:id); item.searchField = search
            item.preferredWidthForSearchField = 200; item.label = "Search"; searchItem = item; return item
        case .folioAdd:
            let item = NSToolbarItem(itemIdentifier:id); item.image = NSImage(systemSymbolName:"plus",accessibilityDescription:"Add")
            item.label = "Add"; item.toolTip = "Add images or a folder · ⌘O"; item.target = self; item.action = #selector(importPanel); item.isBordered = true; return item
        case .folioTitle:
            // A label, not a control: no bezel or glass behind it.
            let item = NSToolbarItem(itemIdentifier:id); item.view = makeTitleBar(); item.label = "Title"; item.visibilityPriority = .low; item.isBordered = false
            return item
        case .folioInspector:
            let item = NSToolbarItem(itemIdentifier:id); item.image = NSImage(systemSymbolName:"sidebar.trailing",accessibilityDescription:"Details")
            item.label = "Details"; item.toolTip = "Show or hide details · ⌘I"; item.target = self; item.action = #selector(toggleInspector); item.isBordered = true; return item
        default: return nil
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The tracking separators keep Add and Search over the grid and Details over the details panel.
        [.toggleSidebar,.sidebarTrackingSeparator,.folioTitle,.flexibleSpace,.folioAdd,.folioSearch,.inspectorTrackingSeparator,.flexibleSpace,.folioInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    // MARK: Empty states

    /// A calm first run that offers the folders new images usually land in; quieter text everywhere else.
    func updateEmptyState(count: Int, query: String) {
        emptyState.isHidden = count > 0 || !viewer.isHidden
        if viewer.isHidden { floating.forEach { $0.isHidden = count == 0 }; if boardShown || infinityShown { zoomBar?.isHidden = true } }
        guard count == 0 else { return }
        emptyActions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let firstRun = query.isEmpty && scope == .all && rows.first?.count == 0 && rows.allSatisfy { $0.kind != .folder }
        func button(_ title: String, _ action: Selector, _ value: Any? = nil) {
            let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .push; b.controlSize = .large
            if let value { b.identifier = .init(String(describing:value)) }
            emptyActions.addArrangedSubview(b)
        }
        switch (firstRun,scope,query.isEmpty) {
        case (true,_,_):
            emptyIcon.image = NSImage(systemSymbolName:"square.grid.2x2",accessibilityDescription:nil)
            emptyTitle.stringValue = "Start your library"
            emptyBody.stringValue = "Drop images or folders here, or let Folio watch the places new images land. Your files stay where they are."
            for (title,url) in FolderWatcher.suggestions { button("Watch \(title)",#selector(watchSuggested(_:)),url.path) }
            button("Add Images…",#selector(importPanel))
            // The main way in, styled as the default button.
            (emptyActions.arrangedSubviews.last as? NSButton)?.keyEquivalent = "\r"
        case (_,_,false):
            emptyIcon.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)
            emptyTitle.stringValue = "No results"; emptyBody.stringValue = "Try another name, tag, or a word that appears in the image."
        case (_,.trash,_):
            emptyIcon.image = NSImage(systemSymbolName:"trash",accessibilityDescription:nil)
            emptyTitle.stringValue = "The Trash is empty"; emptyBody.stringValue = "Items you remove stay here for 30 days. Original files are never touched."
        case (_,.liked,_):
            emptyIcon.image = NSImage(systemSymbolName:"heart",accessibilityDescription:nil)
            emptyTitle.stringValue = "Nothing liked yet"; emptyBody.stringValue = "Press L or click the heart in the details panel to keep favourites here."
        default:
            emptyIcon.image = NSImage(systemSymbolName:"photo.on.rectangle.angled",accessibilityDescription:nil)
            emptyTitle.stringValue = "Nothing here yet"; emptyBody.stringValue = "Drop images or folders here."
        }
    }
    @objc func watchSuggested(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        watch(URL(fileURLWithPath:path,isDirectory:true))
    }

    // MARK: Floating controls

    @objc func styleChanged(_ sender: NSSegmentedControl) {
        let choices = layoutChoices
        guard choices.indices.contains(sender.selectedSegment) else { return }
        switch choices[sender.selectedSegment] {
        case "Board": setBoard(true)
        case "Columns": setStyle(.columns)
        case "List": setStyle(.list)
        case "Infinity": setStyle(.infinity)
        default: setStyle(.rows)
        }
    }
    func setStyle(_ style: GridStyle) {
        if boardShown { setBoard(false) }
        grid.setStyle(style); updateLayoutSwitch()
    }
    @objc func showRows() { setStyle(.rows) }
    @objc func showColumns() { setStyle(.columns) }
    @objc func showList() { setStyle(.list) }
    @objc func showInfinityStyle() { setStyle(.infinity) }
    /// The endless wall in place of the grid.
    func showInfinity(_ items: [ShelfItem]) {
        infinityShown = true
        infinity.isHidden = !viewer.isHidden; scroll.isHidden = true; emptyState.isHidden = !items.isEmpty
        infinity.show(items)
        if viewer.isHidden { zoomBar?.isHidden = true; if window.firstResponder === grid { window.makeFirstResponder(infinity) } }
        updateLayoutSwitch()
    }
    func hideInfinity() {
        guard infinityShown else { return }
        infinityShown = false; infinity.isHidden = true
        if !boardShown { scroll.isHidden = !viewer.isHidden }
        updateLayoutSwitch()
    }
    @objc func zoomChanged(_ slider: NSSlider) { grid.setZoom(slider.doubleValue) }
    /// ⌘+ and ⌘− size the thumbnails, or zoom the picture while the viewer is open.
    @objc func zoomIn() {
        if !viewer.isHidden { viewer.zoom.step(1.25); return }
        zoom.doubleValue = min(zoom.maxValue,zoom.doubleValue * 1.2); grid.setZoom(zoom.doubleValue)
    }
    @objc func zoomOut() {
        if !viewer.isHidden { viewer.zoom.step(0.8); return }
        zoom.doubleValue = max(zoom.minValue,zoom.doubleValue / 1.2); grid.setZoom(zoom.doubleValue)
    }
    @objc func showSortMenu(_ sender: NSButton) { sortMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height + 6),in:sender) }
    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for (title,value) in [("Date Added",Sort.added),("Date Created",.fileDate),("Name",.name),("Size",.size)] {
            let item = NSMenuItem(title:title,action:#selector(chooseSort(_:)),keyEquivalent:""); item.target = self
            item.representedObject = title; item.state = sort == value ? .on : .off; menu.addItem(item)
        }
        let manual = NSMenuItem(title:"Manual",action:#selector(chooseSort(_:)),keyEquivalent:""); manual.target = self
        manual.representedObject = "Manual"; manual.state = sort == .custom ? .on : .off
        manual.toolTip = "Your own order inside each collection: drag items to arrange them"; menu.addItem(manual)
        let shuffle = NSMenuItem(title:"Shuffle",action:#selector(chooseSort(_:)),keyEquivalent:""); shuffle.target = self
        shuffle.representedObject = "Shuffle"; if case .random = sort { shuffle.state = .on }; menu.addItem(shuffle)
        menu.addItem(.separator())
        let orders: [(String,Bool)] = sort == .name ? [("A to Z",true),("Z to A",false)]
            : sort == .size ? [("Largest First",false),("Smallest First",true)] : [("Newest First",false),("Oldest First",true)]
        for (title,value) in orders {
            let item = NSMenuItem(title:title,action:#selector(chooseOrder(_:)),keyEquivalent:""); item.target = self
            item.representedObject = value; item.state = ascending == value ? .on : .off
            if case .random = sort { item.isEnabled = false }
            if sort == .custom { item.isEnabled = false }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    @objc func chooseSort(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "Date Created": sort = .fileDate
        case "Name": sort = .name
        case "Size": sort = .size
        case "Shuffle": sort = .random(seed:Int64.random(in:1...Int64(Int32.max)))
        case "Manual": sort = .custom
        default: sort = .added
        }
        ascending = sort == .name
        saveSort(); loadItems()
    }
    @objc func chooseOrder(_ sender: NSMenuItem) { ascending = sender.representedObject as? Bool ?? false; saveSort(); loadItems() }

    // MARK: Inspector and viewer

    var panelVisible: Bool { inspectorItem.map { !$0.isCollapsed } ?? false }
    func showInspector(_ show: Bool, animated: Bool = true) {
        guard let inspectorItem, panelVisible != show else { return }
        if animated && !Motion.reduced && !args.contains("--background-check") { inspectorItem.animator().isCollapsed = !show } else { inspectorItem.isCollapsed = !show }
    }
    @objc func toggleInspector() { inspectorDismissed = panelVisible; showInspector(!panelVisible) }
    @objc func toggleCaptions() { grid.setCaptions(!grid.showsCaptions) }
    func showViewer(_ item: ShelfItem) {
        if item.kind == "link" { open(item); return }
        // Opening a colour finds what uses it.
        if item.kind == "color", let hex = item.colors.first { runSearch(hex); return }
        guard let index = grid.items.firstIndex(where:{ $0.id == item.id }) else { return }
        grid.endHover()
        // Settings ▸ General ▸ Viewer: more room for the picture.
        if UserDefaults.standard.bool(forKey:"viewerHidesSidebar"), let sidebar = split.splitViewItems.first, !sidebar.isCollapsed {
            (Motion.reduced ? sidebar : sidebar.animator()).isCollapsed = true; sidebarHiddenForViewer = true
        }
        floating.forEach { $0.isHidden = true }; emptyState.isHidden = true; scroll.isHidden = true; boardScroll.isHidden = true; infinity.isHidden = true
        viewer.show(grid.items,at:index)
    }
    func viewerClosed(_ item: ShelfItem?) {
        defer { updateTitle(count:grid.items.count) }
        if sidebarHiddenForViewer, let sidebar = split.splitViewItems.first { (Motion.reduced ? sidebar : sidebar.animator()).isCollapsed = false; sidebarHiddenForViewer = false }
        floating.forEach { $0.isHidden = false }; scroll.isHidden = boardShown || infinityShown; boardScroll.isHidden = !boardShown
        infinity.isHidden = !infinityShown
        if infinityShown { zoomBar?.isHidden = true; window.makeFirstResponder(infinity); return }
        if boardShown { zoomBar?.isHidden = true; window.makeFirstResponder(board); if let item { board.select([item.id]) }; return }
        window.makeFirstResponder(grid)
        if let item, let index = grid.items.firstIndex(where:{ $0.id == item.id }) { grid.select([item.id],focus:item.id); grid.reveal(index) }
    }
}
