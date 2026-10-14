import AppKit
import ShelfCore

/// What the command palette offers: commands for the selection, places to go, items, tags and collections.
extension AppController {
    @objc func showPalette() { openPalette(.root) }
    @objc func showGoTo() { openPalette(.goTo) }
    @objc func showTagPicker() { selection.isEmpty ? NSSound.beep() : openPalette(.tags) }
    @objc func showCollectionPicker() { selection.isEmpty ? NSSound.beep() : openPalette(.collections(move:false)) }
    @objc func showMovePicker() { selection.isEmpty ? NSSound.beep() : openPalette(.collections(move:true)) }
    func openPalette(_ mode: CommandPalette.Mode) {
        guard viewer.isHidden || mode != .goTo else { return }
        tagCache = (try? database.tagCounts()) ?? []
        palette.open(mode)
    }
    /// Hands the keyboard back to the grid or the viewer; the palette's hidden field must not keep it.
    func paletteClosed() { window.makeFirstResponder(viewer.isHidden ? grid : viewer) }

    var recentSearches: [String] { UserDefaults.standard.stringArray(forKey:"recentSearches") ?? [] }
    func rememberSearch(_ text: String) {
        let value = text.trimmingCharacters(in:.whitespaces)
        guard !value.isEmpty else { return }
        UserDefaults.standard.set(Array(([value] + recentSearches.filter { $0 != value }).prefix(3)),forKey:"recentSearches")
    }

    /// True when every word typed appears in the text, so "new col" finds "New Collection".
    static func matches(_ text: String, _ query: String) -> Bool {
        let words = query.lowercased().split(separator:" ")
        let haystack = text.lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
    static func rank(_ entries: [PaletteEntry], _ query: String) -> [PaletteEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter { matches($0.title + " " + $0.detail,query) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1) }
    }

    func paletteEntries(_ mode: CommandPalette.Mode, _ query: String) -> [PaletteEntry] {
        switch mode {
        case .root: return rootEntries(query)
        case .goTo: return Self.rank(placeEntries(section:"Go to"),query)
        case .tags: return tagEntries(query)
        case .collections(let move): return collectionEntries(query,move:move)
        }
    }
    private func rootEntries(_ query: String) -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        let q = query.trimmingCharacters(in:.whitespaces)
        if q.isEmpty {
            out += recentSearches.map { text in
                let colour = ColorMath.hex(text).flatMap(Theme.rgb).map(Theme.color)
                return PaletteEntry(id:"recent:\(text)",title:text,symbol:colour == nil ? "clock.arrow.circlepath" : "circle.fill",section:"Recent searches",tint:colour) { [weak self] in self?.runSearch(text) }
            }
        } else {
            if let color = ColorMath.target(q.hasPrefix("#") ? q : "#" + q), q.trimmingCharacters(in:CharacterSet(charactersIn:"#")).allSatisfy(\.isHexDigit), [3,6].contains(q.trimmingCharacters(in:CharacterSet(charactersIn:"#")).count) {
                out.append(PaletteEntry(id:"color",title:"Find items with \(color)",symbol:"paintpalette",section:"Search") { [weak self] in self?.runSearch(color) })
            }
            out.append(PaletteEntry(id:"search",title:"Search for “\(q)”",detail:"names, tags, notes and text in images",symbol:"magnifyingglass",hint:"↩",section:"Search") { [weak self] in self?.runSearch(q) })
        }
        out += Self.rank(selectionCommands(),q)
        let places = Self.rank(placeEntries(section:"Go to"),q)
        out += q.isEmpty ? Array(places.prefix(4)) : Array(places.prefix(8))
        out += Self.rank(generalCommands() + libraryCommands(),q)
        if !q.isEmpty, let found = try? database.items(query:q,limit:6) {
            out += found.map { item in
                PaletteEntry(id:"item:\(item.id)",title:item.title,detail:Inspector.describe(item).components(separatedBy:"  ·  ").prefix(2).joined(separator:" · "),
                             symbol:item.kind == "video" ? "film" : item.kind == "link" ? "link" : "photo",section:"Items") { [weak self] in self?.reveal(item:item) }
            }
        }
        return out
    }
    private func selectionCommands() -> [PaletteEntry] {
        let chosen = selection
        guard !chosen.isEmpty else { return [] }
        let noun = chosen.count == 1 ? "" : " (\(chosen.count))"
        var out = [
            PaletteEntry(id:"tags",title:"Add Tags…" + noun,symbol:"tag",hint:"T",section:"Selection") { [weak self] in self?.openPalette(.tags) },
            PaletteEntry(id:"collect",title:"Add to Collection…" + noun,symbol:"rectangle.stack.badge.plus",hint:"C",section:"Selection") { [weak self] in self?.openPalette(.collections(move:false)) },
            PaletteEntry(id:"move",title:"Move to Collection…" + noun,symbol:"arrow.right.square",hint:"M",section:"Selection") { [weak self] in self?.openPalette(.collections(move:true)) },
            PaletteEntry(id:"like",title:chosen.allSatisfy(\.liked) ? "Unlike" : "Like",symbol:"heart",hint:"L",section:"Selection") { [weak self] in self?.toggleLikeSelected() },
            PaletteEntry(id:"look",title:"Quick Look",symbol:"eye",hint:"Space",section:"Selection") { [weak self] in self?.grid.toggleQuickLook() },
            PaletteEntry(id:"finder",title:"Show in Finder",symbol:"folder",hint:Shortcuts.current("Item/Show in Finder"),section:"Selection") { [weak self] in self?.revealSelected() },
            PaletteEntry(id:"similar",title:"Find Similar",symbol:"square.on.square.dashed",hint:"S",section:"Selection") { [weak self] in self?.findSimilar() },
            PaletteEntry(id:"note",title:"Edit Note",symbol:"note.text",hint:"N",section:"Selection") { [weak self] in self?.editNote() },
            PaletteEntry(id:"author",title:"Edit Author",symbol:"person",hint:"A",section:"Selection") { [weak self] in self?.editAuthor() },
            PaletteEntry(id:"source",title:"Edit Source",symbol:"link",hint:"U",section:"Selection") { [weak self] in self?.editSource() }]
        if chosen.count == 1 { out.insert(PaletteEntry(id:"open",title:"Open",symbol:"arrow.up.forward.square",hint:"↩",section:"Selection") { [weak self] in self?.viewSelected() },at:0) }
        // The apps that open this file, as they appear under Open With.
        if chosen.count == 1, let apps = openWithMenu(chosen[0]) {
            out += apps.items.filter { !$0.isSeparatorItem }.prefix(5).enumerated().map { index, entry in
                PaletteEntry(id:"openwith:\(index)",title:"Open With " + entry.title.replacingOccurrences(of:" (default)",with:""),symbol:"arrow.up.forward.app",section:"Selection") { [weak self] in self?.openWithApp(entry) }
            }
        }
        for library in otherLibraries {
            let name = LibraryLocation.name(library)
            out.append(PaletteEntry(id:"copyto:\(library.path)",title:"Copy to \(name)" + noun,symbol:"books.vertical",section:"Selection") { [weak self] in self?.send(chosen,to:library,move:false) })
            out.append(PaletteEntry(id:"moveto:\(library.path)",title:"Move to \(name)" + noun,symbol:"books.vertical",section:"Selection") { [weak self] in self?.send(chosen,to:library,move:true) })
        }
        out.append(PaletteEntry(id:"trash",title:inTrash ? "Delete Immediately…" : "Move to Trash",symbol:"trash",hint:Shortcuts.current("Item/Move to Trash"),section:"Selection") { [weak self] in self?.removeSelected() })
        return out
    }
    private func libraryCommands() -> [PaletteEntry] {
        libraries.filter { $0.standardizedFileURL != database.root.standardizedFileURL }.map { url in
            PaletteEntry(id:"library:\(url.path)",title:"Switch to \(LibraryLocation.name(url))",symbol:"books.vertical",section:"Commands") { [weak self] in self?.switchLibrary(to:url) }
        }
    }
    private func generalCommands() -> [PaletteEntry] {
        [PaletteEntry(id:"add",title:"Add Files or Folder…",symbol:"plus",hint:Shortcuts.current("File/Add Files or Folder…"),section:"Commands") { [weak self] in self?.importPanel() },
         PaletteEntry(id:"newcollection",title:"New Collection…",symbol:"rectangle.stack",hint:Shortcuts.current("File/New Collection…"),section:"Commands") { [weak self] in self?.newCollection(nil) },
         PaletteEntry(id:"watch",title:"Watch a Folder…",symbol:"folder.badge.plus",section:"Commands") { [weak self] in self?.watchFolderPanel() },
         PaletteEntry(id:"duplicates",title:"Find Duplicates",symbol:"square.on.square",section:"Commands") { [weak self] in self?.findDuplicates() },
         PaletteEntry(id:"newsmart",title:"New Smart Folder…",symbol:"folder.badge.gearshape",hint:Shortcuts.current("File/New Smart Folder…"),section:"Commands") { [weak self] in self?.newSmartFolder(nil) },
         PaletteEntry(id:"newlibrary",title:"New Library…",symbol:"books.vertical",section:"Commands") { [weak self] in self?.newLibraryPanel() },
         PaletteEntry(id:"importlibrary",title:"Import Library…",symbol:"square.and.arrow.down.on.square",section:"Commands") { [weak self] in self?.importLibraryPanel() },
         PaletteEntry(id:"rows",title:"Show as Rows",symbol:"rectangle.grid.1x2",hint:Shortcuts.current("View/as Rows"),section:"Commands") { [weak self] in self?.setStyle(.rows) },
         PaletteEntry(id:"columns",title:"Show as Columns",symbol:"square.grid.3x2",hint:Shortcuts.current("View/as Columns"),section:"Commands") { [weak self] in self?.setStyle(.columns) },
         PaletteEntry(id:"infinity",title:"Show as Infinity",symbol:"infinity",hint:Shortcuts.current("View/as Infinity"),section:"Commands") { [weak self] in self?.setStyle(.infinity) },
         PaletteEntry(id:"list",title:"Show as List",symbol:"list.bullet",hint:Shortcuts.current("View/as List"),section:"Commands") { [weak self] in self?.setStyle(.list) },
         PaletteEntry(id:"random-color",title:"Search a Random Colour",symbol:"dice",section:"Commands") { [weak self] in self?.searchRandomColor() },
         PaletteEntry(id:"captions",title:grid.showsCaptions ? "Hide Filenames" : "Show Filenames",symbol:"textformat",section:"Commands") { [weak self] in self?.toggleCaptions() },
         PaletteEntry(id:"details",title:panelVisible ? "Hide Details" : "Show Details",symbol:"sidebar.trailing",hint:"I",section:"Commands") { [weak self] in self?.toggleInspector() },
         PaletteEntry(id:"sortadded",title:"Sort by Date Added",symbol:"arrow.up.arrow.down",section:"Commands") { [weak self] in self?.applySort(.added) },
         PaletteEntry(id:"sortname",title:"Sort by Name",symbol:"textformat.abc",section:"Commands") { [weak self] in self?.applySort(.name) },
         PaletteEntry(id:"shuffle",title:"Shuffle",symbol:"shuffle",hint:"R",section:"Commands") { [weak self] in self?.applySort(.random(seed:Int64.random(in:1...Int64(Int32.max)))) },
         PaletteEntry(id:"sorting",title:"Sort Images Automatically",detail:"tags and text for new images",symbol:"sparkles",section:"Commands") { [weak self] in self?.tagAllImages() },
         PaletteEntry(id:"emptytrash",title:"Empty Trash…",symbol:"trash.slash",section:"Commands") { [weak self] in self?.emptyTrash() },
         PaletteEntry(id:"settings",title:"Settings…",symbol:"gearshape",hint:"⌘,",section:"Commands") { [weak self] in MainActor.assumeIsolated { self?.showSettings() } },
         PaletteEntry(id:"updates",title:"Check for Updates…",symbol:"arrow.triangle.2.circlepath",section:"Commands") { [weak self] in MainActor.assumeIsolated { self?.checkForUpdates() } }]
    }
    /// Every sidebar place plus tags, for Go to and the root list.
    private func placeEntries(section: String) -> [PaletteEntry] {
        var out = rows.filter { $0.kind != .header }.map { row in
            PaletteEntry(id:"place:\(row.title):\(row.id ?? "")",title:row.title,detail:row.count > 0 ? row.count.formatted() : "",symbol:row.symbol,section:section) { [weak self] in
                self?.showScope(row.scope)
            }
        }
        out += tagCache.prefix(200).map { tag in
            PaletteEntry(id:"tag:\(tag.name)",title:tagTitle(tag.name,automatic:tag.automatic),detail:tag.count.formatted(),symbol:"tag",section:section) { [weak self] in self?.showScope(Self.tagScope(tag.name)) }
        }
        return out
    }
    static func tagScope(_ name: String) -> Scope { .smart(SmartRules(rules:[SmartRule(.tag,.is,name)])) }
    private func tagEntries(_ query: String) -> [PaletteEntry] {
        let q = query.trimmingCharacters(in:.whitespaces), chosen = selection
        let present = Set(chosen.dropFirst().reduce(Set((chosen.first.map { $0.tags + $0.autoTags } ?? []).map { $0.lowercased() })) {
            $0.intersection(($1.tags + $1.autoTags).map { $0.lowercased() })
        })
        var out = Self.rank(tagCache.map { tag in
            PaletteEntry(id:tag.name,title:tagTitle(tag.name,automatic:tag.automatic),detail:present.contains(tag.name.lowercased()) ? "added" : "",symbol:"tag",hint:"",section:"Tags") { [weak self] in
                guard let self else { return }; self.addTags([tag.name],to:self.selection)
            }
        },q)
        if !q.isEmpty, !tagCache.contains(where:{ $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
            out.insert(PaletteEntry(id:q,title:"Create “\(q)”",symbol:"plus",section:"Tags") { [weak self] in
                guard let self else { return }; self.addTags([q],to:self.selection)
            },at:0)
        }
        return Array(out.prefix(60))
    }
    private func collectionEntries(_ query: String, move: Bool) -> [PaletteEntry] {
        let q = query.trimmingCharacters(in:.whitespaces), chosen = selection
        var out = Self.rank(regularCollections.map { collection in
            PaletteEntry(id:collection.id,title:collection.name,detail:chosen.allSatisfy { $0.collections.contains(collection.id) } ? "already in" : "",
                         symbol:"rectangle.stack",section:"Collections") { [weak self] in self?.file(chosen,into:collection.id,name:collection.name,move:move) }
        },q)
        if !q.isEmpty, !regularCollections.contains(where:{ $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
            out.insert(PaletteEntry(id:"new:\(q)",title:"New Collection “\(q)”",symbol:"plus",section:"Collections") { [weak self] in
                self?.perform("New Collection") { db in
                    let collection = try db.createCollection(name:q)
                    if move { try db.moveItems(chosen.map(\.id),from:nil,to:collection.id) } else { try db.addItems(chosen.map(\.id),to:collection.id) }
                    return nil
                }
                self?.notify("\(move ? "Moved" : "Added") \(Self.count(chosen)) to \(q)")
            },at:0)
        }
        return out
    }
    func paletteApply(_ mode: CommandPalette.Mode, _ ids: [String]) {
        let chosen = selection
        switch mode {
        case .tags: addTags(ids,to:chosen)
        case .collections:
            let targets = ids.filter { !$0.hasPrefix("new:") }
            edit("Add to Collection",notice:"Added \(Self.count(chosen)) to \(targets.count) collections") { db in
                var states: [ItemState] = []
                for (index,id) in targets.enumerated() {
                    let before = try db.addItems(chosen.map(\.id),to:id)
                    if index == 0 { states = before }
                }
                return states
            }
        default: break
        }
    }
    /// Adds items to a collection, or moves them there out of the collection being shown (or every collection outside one).
    func file(_ items: [ShelfItem], into id: String, name: String, move: Bool) {
        guard move else { addToCollection(items,id:id,name:name); return }
        var source: String?
        if case .collection(let current,_) = scope, regularCollections.contains(where:{ $0.id == current }) { source = current }
        edit("Move to Collection",notice:"Moved \(Self.count(items)) to \(name)") { try $0.moveItems(items.map(\.id),from:source,to:id) }
    }
    func runSearch(_ text: String) {
        rememberSearch(text)
        search(for:text)
    }
    func applySort(_ value: Sort) { sort = value; ascending = value == .name; saveSort(); loadItems() }
    /// Shows an item from anywhere: All Items when the current view doesn't hold it, selected and scrolled into view.
    func reveal(item: ShelfItem) {
        if let index = grid.items.firstIndex(where:{ $0.id == item.id }) { grid.select([item.id],focus:item.id); grid.reveal(index); return }
        search.stringValue = ""; pendingReveal = item.id; showScope(.all)
    }
    @objc func editNote() {
        guard selected != nil else { NSSound.beep(); return }
        inspectorDismissed = false; showInspector(true,animated:false); inspector.focusNote()
    }
    @objc func editAuthor() {
        guard !selection.isEmpty else { NSSound.beep(); return }
        inspectorDismissed = false; showInspector(true,animated:false); inspector.focusAuthor()
    }
    @objc func editSource() {
        guard !selection.isEmpty else { NSSound.beep(); return }
        inspectorDismissed = false; showInspector(true,animated:false); inspector.focusSource()
    }
}
