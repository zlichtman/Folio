import AppKit
import ShelfCore

/// Export, Open With, Show in Collection, Refresh Thumbnail and the quick filters.
extension AppController {
    // MARK: Export

    @objc func exportSelected() {
        let chosen = selection.filter { $0.path.hasPrefix("/") && FileManager.default.fileExists(atPath:$0.path) }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = chosen.count == 1 ? "Export" : "Export \(chosen.count)"
        panel.message = "Choose a folder for copies of the selected files."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            DispatchQueue.global(qos:.userInitiated).async {
                var copied = 0
                for item in chosen {
                    let source = URL(fileURLWithPath:item.path)
                    var target = folder.appendingPathComponent(source.lastPathComponent), n = 2
                    while FileManager.default.fileExists(atPath:target.path) {
                        target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) \(n)").appendingPathExtension(source.pathExtension); n += 1
                    }
                    if (try? FileManager.default.copyItem(at:source,to:target)) != nil { copied += 1 }
                }
                DispatchQueue.main.async { self?.notify("Exported \(copied == 1 ? "1 file" : "\(copied) files") to \(folder.lastPathComponent)") }
            }
        }
    }

    /// Fetches titles and previews for links added from outside the app.
    func fillInLinks() {
        workQueue.async { [weak self] in
            guard let self, let links = try? self.database.items(scope:.kind("link")) else { return }
            DispatchQueue.main.async { self.links.fillIn(Array(links.prefix(50))) }
        }
    }

    // MARK: Frames and desktop pictures

    /// Keeps the video frame showing in the viewer as a picture of its own, named for the video and the moment.
    /// The frame keeps what the video had: its tags, its collections and where it came from.
    /// In the grid, the frame of the video playing under the pointer.
    @objc func saveVideoFrame() {
        let source: (video: ShelfItem, frame: (@escaping (CGImage?, Double) -> Void) -> Void)
        if let video = viewer.current, viewer.showsVideo { source = (video,viewer.currentFrame) }
        else if let playing = grid.hoverFrameSource() { source = playing }
        else { NSSound.beep(); return }
        let video = source.video
        source.frame { [weak self] image, seconds in
            guard let self, let image, let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { NSSound.beep(); return }
            let moment = Duration.seconds(seconds).formatted(.time(pattern:.minuteSecond)).replacingOccurrences(of:":",with:".")
            let media = self.database.mediaFolder
            var url = media.appendingPathComponent("\(video.title) at \(moment).png")
            if FileManager.default.fileExists(atPath:url.path) { url = media.appendingPathComponent("\(video.title) at \(moment) \(UUID().uuidString.prefix(4)).png") }
            do {
                try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
                try png.write(to:url,options:.atomic)
            } catch { self.showError(error); return }
            self.workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let ids = try self.database.insert(MediaFiles.scan([url]))
                    if !ids.isEmpty {
                        if !video.tags.isEmpty { try self.database.addTags(video.tags,to:ids) }
                        let source = video.source.isEmpty ? video.url : video.source
                        if !source.isEmpty { try self.database.setSource(source,for:ids) }
                        for collection in video.collections { try? self.database.addItems(ids,to:collection) }
                    }
                    DispatchQueue.main.async {
                        self.preserveNextLoad = true; self.reload()
                        self.notify("Saved the frame at \(moment.replacingOccurrences(of:".",with:":"))")
                    }
                } catch { DispatchQueue.main.async { self.showError(error) } }
            }
        }
    }
    @objc func setDesktopPicture() {
        guard let item = selected, item.kind == "image", item.path.hasPrefix("/") else { NSSound.beep(); return }
        do {
            for screen in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath:item.path),for:screen,options:[:]) }
            notify("“\(item.title)” is your desktop picture")
        } catch { showError(error) }
    }

    // MARK: Open With

    /// ⌥⌘O: the apps that open the selected file, listed beside it.
    @objc func showOpenWith() {
        guard let item = selected, let menu = openWithMenu(item) else { NSSound.beep(); return }
        if let frame = grid.frame(of:item.id), grid.visibleRect.intersects(frame) {
            menu.popUp(positioning:nil,at:NSPoint(x:frame.minX + 8,y:frame.minY + 8),in:grid)
        } else {
            let content = window.contentView!
            menu.popUp(positioning:nil,at:NSPoint(x:content.bounds.midX,y:content.bounds.midY),in:content)
        }
    }

    func openWithMenu(_ item: ShelfItem) -> NSMenu? {
        guard item.path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath:item.path), menu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen:url)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen:url)
        for app in ([preferred].compactMap { $0 } + apps.filter { $0 != preferred }).prefix(12) {
            let name = FileManager.default.displayName(atPath:app.path).replacingOccurrences(of:".app",with:"")
            let entry = NSMenuItem(title:app == preferred ? "\(name) (default)" : name,action:#selector(openWithApp(_:)),keyEquivalent:"")
            entry.target = self; entry.representedObject = [url,app]
            let icon = NSWorkspace.shared.icon(forFile:app.path); icon.size = NSSize(width:16,height:16); entry.image = icon
            menu.addItem(entry)
            if app == preferred, apps.count > 1 { menu.addItem(.separator()) }
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]],withApplicationAt:pair[1],configuration:NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error) } }
        }
    }

    // MARK: Show in Collection

    /// For an item seen outside its collections: an entry to jump there, or a submenu when it's in several.
    func showInCollectionItem(_ item: ShelfItem) -> NSMenuItem? {
        var current: String?
        if case .collection(let id,_) = scope { current = id }
        let places = item.collections.filter { $0 != current }.compactMap { id in collectionNames[id].map { (id,$0) } }
        guard !places.isEmpty else { return nil }
        if places.count == 1 {
            let entry = NSMenuItem(title:"Show in “\(places[0].1)”",action:#selector(showInCollection(_:)),keyEquivalent:"")
            entry.target = self; entry.representedObject = [places[0].0,item.id]; return entry
        }
        let entry = NSMenuItem(title:"Show in Collection",action:nil,keyEquivalent:""), menu = NSMenu()
        for (id,name) in places {
            let sub = NSMenuItem(title:name,action:#selector(showInCollection(_:)),keyEquivalent:""); sub.target = self; sub.representedObject = [id,item.id]
            menu.addItem(sub)
        }
        entry.submenu = menu; return entry
    }
    @objc func showInCollection(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        pendingReveal = pair[1]; showScope(.collection(pair[0]))
    }

    // MARK: Refresh

    @objc func refreshThumbnails() {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        for item in chosen { thumbnails.invalidate(path:item.path) }
        grid.reloadThumbnails(); inspector.show(selection)
        notify(chosen.count == 1 ? "Refreshed the thumbnail" : "Refreshed \(chosen.count) thumbnails")
    }

    // MARK: Filters

    static let filters: [(title: String, query: String, symbol: String)] = [
        ("Images","type:image","photo"),("Videos","type:video","film"),("GIFs","type:gif","square.stack.3d.forward.dottedline"),
        ("Vectors and PDFs","type:svg type:pdf type:ai","doc.richtext"),("Wide","is:wide","rectangle"),("Tall","is:tall","rectangle.portrait"),("Square","is:square","square"),
        ("Liked","is:liked","heart"),("Untagged","is:untagged","tag.slash")]
    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        let none = NSMenuItem(title:"Everything",action:#selector(chooseFilter(_:)),keyEquivalent:""); none.target = self
        none.state = filter == nil ? .on : .off; menu.addItem(none); menu.addItem(.separator())
        for entry in Self.filters {
            let item = NSMenuItem(title:entry.title,action:#selector(chooseFilter(_:)),keyEquivalent:""); item.target = self
            item.representedObject = entry.title; item.image = NSImage(systemSymbolName:entry.symbol,accessibilityDescription:nil)
            item.state = filter?.title == entry.title ? .on : .off; menu.addItem(item)
        }
        let recent = recentFilters
        if !recent.isEmpty {
            menu.addItem(.separator()); menu.addItem(.sectionHeader(title:"Recent"))
            let folders = watchedFolderNames
            for (index,rules) in recent.enumerated() {
                let item = NSMenuItem(title:SmartFolderEditor.summary(rules,collections:regularCollections,folders:folders),action:#selector(chooseRecentFilter(_:)),keyEquivalent:"")
                item.target = self; item.tag = index; item.state = filterRules == rules ? .on : .off; menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let advanced = NSMenuItem(title:"Advanced Filter…",action:#selector(showAdvancedFilter),keyEquivalent:""); advanced.target = self
        advanced.image = NSImage(systemSymbolName:"slider.horizontal.3",accessibilityDescription:nil); menu.addItem(advanced)
        if filterRules != nil {
            let save = NSMenuItem(title:"Save as Smart Folder…",action:#selector(saveFilterAsSmartFolder),keyEquivalent:""); save.target = self
            save.image = NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil); menu.addItem(save)
        }
        return menu
    }
    /// The last few advanced filters, newest first.
    var recentFilters: [SmartRules] {
        guard let data = UserDefaults.standard.data(forKey:"recentFilters") else { return [] }
        return (try? JSONDecoder().decode([SmartRules].self,from:data)) ?? []
    }
    @objc func showAdvancedFilter() {
        editSmartFolder(nil,starting:filterRules ?? SmartRules(rules:[SmartRule(.kind,.is,"image")]),filtering:true)
    }
    @objc func chooseRecentFilter(_ sender: NSMenuItem) {
        let recent = recentFilters
        if recent.indices.contains(sender.tag) { setRuleFilter(recent[sender.tag]) }
    }
    @objc func saveFilterAsSmartFolder() {
        guard let rules = filterRules else { return }
        editSmartFolder(nil,starting:rules) { [weak self] in self?.setFilter(nil) }
    }
    /// Filters the place on screen by rules, and remembers them among the recent filters.
    func setRuleFilter(_ rules: SmartRules) {
        let recent = [rules] + recentFilters.filter { $0 != rules }
        if let data = try? JSONEncoder().encode(Array(recent.prefix(5))) { UserDefaults.standard.set(data,forKey:"recentFilters") }
        setFilter(("Advanced",""),rules:rules)
    }
    @objc func showFilterMenu(_ sender: NSButton) { filterMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height + 6),in:sender) }
    @objc func chooseFilter(_ sender: NSMenuItem) {
        let title = sender.representedObject as? String
        setFilter(Self.filters.first { $0.title == title }.map { ($0.title,$0.query) })
    }
    func setFilter(_ value: (title: String, query: String)?, rules: SmartRules? = nil) {
        filter = value; filterRules = rules
        filterButton.contentTintColor = value == nil ? .secondaryLabelColor : .controlAccentColor
        filterButton.image = NSImage(systemSymbolName:value == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",accessibilityDescription:"Filter")
        loadItems()
    }
    /// The search text plus the quick filter, as one query.
    var effectiveQuery: String {
        guard let filter else { return search.stringValue }
        // Several type: clauses match any of them, so a filter can name more than one kind.
        return search.stringValue + " " + filter.query
    }
}
