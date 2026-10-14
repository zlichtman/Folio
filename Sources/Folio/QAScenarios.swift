import AppKit
import ShelfCore

/// The steps `--qa` runs, in order. Each acts through the same input paths a person uses and checks the outcome.
@MainActor enum QAScenarios {
    static func build(_ qa: QAHarness) {
        let app = qa.app, grid = app.grid!
        var first = "", liked = 0, total = 0, trashed = 0, zoomCheck = false
        qa.add("Library loads",snapshot:true,timeout:8,{ }) { grid.items.count >= 12 && grid.visibleCount > 0 }
        qa.add("An empty Collections section offers a first one",{ }) {
            app.sidebarRows(tree:[],folders:[],counts:[:],tags:[]).contains { $0.kind == .prompt }
                && app.rows.contains { $0.kind == .collection } != app.rows.contains { $0.kind == .prompt }
        }
        qa.add("Click selects one item",{ total = grid.items.count; first = grid.items[0].id; qa.click(grid,at:qa.tile(0)) }) {
            qa.ids == [first] && app.inspector.items.map(\.id) == [first]
        }
        qa.add("Command-click adds to the selection",{ qa.click(grid,at:qa.tile(2),flags:.command) }) { qa.ids.count == 2 }
        qa.add("Shift-click selects a range",{ qa.click(grid,at:qa.tile(5),flags:.shift) }) { qa.ids.count == 4 }
        qa.add("Details show several items",snapshot:true,{ }) { app.inspector.items.count == 4 }
        qa.add("Command-A selects everything",{ qa.key(0,"a",flags:.command) }) { qa.ids.count == total }
        qa.add("Escape clears the selection",{ qa.key(53,"\u{1B}") }) { qa.ids.isEmpty }
        qa.add("Drag across empty space selects",{
            let a = grid.geometry.frame(index:0), b = grid.geometry.frame(index:1)
            qa.drag(grid,from:NSPoint(x:a.minX - 12,y:a.minY - 12),to:NSPoint(x:b.midX,y:b.midY))
        }) { qa.ids.count == 2 }
        qa.add("Arrow keys move the selection",{ qa.click(grid,at:qa.tile(0)); qa.key(124,"\u{F703}") }) { qa.ids == [grid.items[1].id] }
        qa.add("Down arrow moves to the next row",{ qa.click(grid,at:qa.tile(0)); qa.key(125,"\u{F701}") }) {
            guard let id = qa.ids.first, let index = grid.items.firstIndex(where:{ $0.id == id }) else { return false }
            return grid.geometry.frame(index:index).minY > grid.geometry.frame(index:0).maxY
        }
        qa.add("Return opens the viewer",snapshot:true,{ qa.click(grid,at:qa.tile(0)); qa.key(36,"\r") }) { !app.viewer.isHidden && app.viewer.index == 0 }
        qa.add("Arrow keys page in the viewer",{ qa.key(124,"\u{F703}") }) { app.viewer.index == 1 && qa.ids == [grid.items[1].id] }
        qa.add("Escape closes the viewer",{ qa.key(53,"\u{1B}") }) { app.viewer.isHidden && app.window.firstResponder === grid && qa.ids == [grid.items[1].id] }
        qa.add("Double-click opens the viewer",{ qa.click(grid,at:qa.tile(3),count:2) }) { !app.viewer.isHidden && app.viewer.index == 3 }
        qa.add("Back button closes the viewer",{ app.viewer.closeViewer() }) { app.viewer.isHidden }
        qa.add("The viewer can hide the sidebar",timeout:3,{
            UserDefaults.standard.set(true,forKey:"viewerHidesSidebar"); app.showViewer(grid.items[0])
        }) { app.split.splitViewItems.first?.isCollapsed == true }
        qa.add("…and brings it back after",timeout:3,{ app.viewer.closeViewer(); UserDefaults.standard.removeObject(forKey:"viewerHidesSidebar") }) {
            app.split.splitViewItems.first?.isCollapsed == false
        }
        qa.add("L likes the selection",{ liked = qa.count(.liked); qa.click(grid,at:qa.tile(0)); qa.key(37,"l") }) { qa.count(.liked) == liked + 1 }
        qa.add("Liked shows in the sidebar",{ }) { app.rows.first { $0.scope == .liked }?.count == liked + 1 }
        qa.add("Right-click offers item actions",{ }) {
            let event = NSEvent.mouseEvent(with:.rightMouseDown,location:grid.convert(qa.tile(1),to:nil),modifierFlags:[],timestamp:0,
                                           windowNumber:app.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            let titles = grid.menu(for:event)?.items.map(\.title) ?? []
            return ["Open","Quick Look","Show in Finder","Add to Collection","Move to Trash"].allSatisfy(titles.contains) && qa.ids == [grid.items[1].id]
        }
        qa.add("Delete moves to the Trash",{ trashed = qa.count(.trash); qa.click(grid,at:qa.tile(0)); qa.key(51,"\u{7F}") }) {
            qa.count(.trash) == trashed + 1 && grid.items.count == total - 1
        }
        qa.add("Undo puts it back",{ qa.key(6,"z",flags:.command) }) { qa.count(.trash) == trashed && grid.items.count == total }
        qa.add("Redo trashes it again",{ qa.key(6,"z",flags:[.command,.shift]) }) { qa.count(.trash) == trashed + 1 }
        qa.add("Undo again",{ qa.key(6,"z",flags:.command) }) { qa.count(.trash) == trashed }
        qa.add("The Trash notice offers Undo",snapshot:true,timeout:3,{ qa.click(grid,at:qa.tile(0)); qa.key(51,"\u{7F}") }) {
            qa.count(.trash) == trashed + 1 && app.toast.actionTitle == "Undo" && !app.toast.isHidden
        }
        qa.add("Undo in the notice puts it back",{ app.toast.run() }) { qa.count(.trash) == trashed && grid.items.count == total }
        qa.add("Sidebar opens Liked",snapshot:true,{ if let p = qa.sidebarRow("Liked") { qa.click(app.sidebar,at:p) } }) {
            app.scope == .liked && grid.items.count == liked + 1
        }
        qa.add("Sidebar opens All Items",{ if let p = qa.sidebarRow("All Items") { qa.click(app.sidebar,at:p) } }) { app.scope == .all && grid.items.count == total }
        qa.add("New collection from the selection",timeout:4,{
            qa.click(grid,at:qa.tile(0)); qa.click(grid,at:qa.tile(1),flags:.command)
            let ids = qa.ids
            app.workQueue.async {
                guard let collection = try? app.database.createCollection(name:"QA Board") else { return }
                try? app.database.addItems(ids,to:collection.id)
                DispatchQueue.main.async { app.reload() }
            }
        }) { app.rows.contains { $0.title == "QA Board" && $0.count == 2 } && !app.rows.contains { $0.kind == .prompt } }
        qa.add("Sorting by name orders the grid",{ app.sort = .name; app.ascending = true; app.loadItems() }) {
            let names = grid.items.map(\.title)
            return names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        qa.add("Columns layout",snapshot:true,{ app.setStyle(.columns) }) { grid.style == .columns && grid.geometry.columns > 1 }
        qa.add("Rows layout",{ app.setStyle(.rows) }) { grid.style == .rows }
        qa.add("Search filters the grid",{ app.search.stringValue = "Sonoma"; app.loadItems() }) {
            !grid.items.isEmpty && grid.items.allSatisfy { $0.title.localizedCaseInsensitiveContains("sonoma") || !$0.tags.isEmpty || !$0.autoTags.isEmpty }
        }
        qa.add("Clearing search shows everything",{ app.search.stringValue = ""; app.loadItems() }) { grid.items.count == total }
        qa.add("Pasting an image adds it",timeout:5,{
            let image = NSImage(size:NSSize(width:64,height:40),flipped:false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
            if let data = NSBitmapImageRep(data:image.tiffRepresentation!)?.representation(using:.png,properties:[:]) { app.importImageData(data,ext:"png") }
        }) { grid.items.count == total + 1 }
        qa.add("Sidebar counts stay inside the sidebar",{ }) {
            guard let clip = app.sidebar.enclosingScrollView?.contentView else { return false }
            return (0..<app.sidebar.numberOfRows).allSatisfy { row in
                guard let cell = app.sidebar.view(atColumn:0,row:row,makeIfNecessary:false) else { return true }
                return cell.subviews.compactMap { $0 as? NSTextField }.allSatisfy { field in
                    let frame = field.convert(field.bounds,to:clip)
                    return field.stringValue.isEmpty || frame.maxX <= clip.bounds.maxX - 4
                }
            }
        }
        qa.add("Command-K opens the palette",snapshot:true,{ qa.click(grid,at:qa.tile(0)); qa.key(40,"k",flags:.command) }) {
            !app.palette.isHidden && app.palette.mode == .root && app.palette.entries.contains { $0.title == "Add Tags…" }
        }
        qa.add("Typing narrows the palette",{ qa.typeText("new col") }) { app.palette.entries.first { $0.section == "Commands" }?.title == "New Collection…" }
        qa.add("Escape closes the palette",{ qa.key(53,"\u{1B}") }) { app.palette.isHidden && app.window.firstResponder === grid }
        qa.add("T opens the tag picker",{ qa.key(17,"t") }) { !app.palette.isHidden && app.palette.mode == .tags }
        qa.add("Return creates and adds a tag",{ qa.typeText("qa-tag"); qa.key(36,"\r") }) {
            app.palette.isHidden && (try? app.database.item(id:grid.items[0].id))?.tags.contains("qa-tag") == true
        }
        qa.add("The new tag shows in the sidebar",snapshot:true,{ }) { app.rows.contains { $0.kind == .tag && $0.title == "qa-tag" } }
        qa.add("C files into a collection",timeout:4,{ qa.click(grid,at:qa.tile(4)); qa.key(8,"c"); qa.typeText("QA Board"); qa.key(36,"\r") }) {
            app.rows.first { $0.title == "QA Board" }?.count == 3
        }
        qa.add("Seed more tags",{ try? app.database.addTags(["red","blue"],to:[grid.items[9].id]); app.reload() }) { app.tagCache.count >= 3 }
        qa.add("Tab picks several tags",{ qa.click(grid,at:qa.tile(5)); qa.key(17,"t"); qa.key(48,"\t"); qa.key(48,"\t") }) {
            app.palette.entries.filter(\.marked).count == 2
        }
        qa.add("Return adds the picked tags",{ qa.key(36,"\r") }) {
            app.palette.isHidden && ((try? app.database.item(id:grid.items[5].id))?.tags.count ?? 0) >= 2
        }
        qa.add("Command-J goes to a tag",{ qa.key(38,"j",flags:.command); qa.typeText("qa-tag"); qa.key(36,"\r") }) {
            app.palette.isHidden && !grid.items.isEmpty && grid.items.allSatisfy { $0.tags.contains("qa-tag") }
                && grid.items.count == app.tagCache.first { $0.name == "qa-tag" }?.count
        }
        qa.add("Palette finds items by name",{ qa.key(40,"k",flags:.command); qa.typeText("Sonoma") }) { app.palette.entries.contains { $0.section == "Items" } }
        qa.add("Choosing an item reveals it in the library",{
            if let index = app.palette.entries.firstIndex(where:{ $0.section == "Items" }) { app.palette.entries[index].run(); app.palette.close() }
        }) { app.scope == .all && qa.ids.count == 1 && grid.items.first { $0.id == qa.ids[0] }?.title.contains("Sonoma") == true }
        qa.add("Seed analysis and look-alike prints",timeout:60,{
            let ids = grid.items.prefix(8).map { ($0.id,$0.path) }, all = grid.items.map { ($0.id,$0.path) }
            app.workQueue.async {
                let classifier = ImageClassifier()
                for (id,path) in ids {
                    if let value = try? classifier.analyze(url:URL(fileURLWithPath:path)) {
                        try? app.database.saveAnalysis(id:id,signature:ImageClassifier.fingerprint(path),value:value,dimensions:MediaFiles.dimensions(URL(fileURLWithPath:path)),applyTags:true)
                    }
                }
                for (id,path) in all { if let data = try? VisualSimilarity.featurePrint(url:URL(fileURLWithPath:path)) { try? app.database.saveFeaturePrint(id:id,version:VisualSimilarity.version,data:data) } }
                DispatchQueue.main.async { app.reload() }
            }
        }) { ((try? app.database.featurePrints(version:VisualSimilarity.version).count) ?? 0) >= total }
        qa.add("Search and Add stay over the grid",{ }) {
            guard let toolbar = app.window.toolbar else { return false }
            let search: NSView = app.search
            app.inspectorDismissed = false; app.showInspector(true,animated:false); app.window.contentView?.layoutSubtreeIfNeeded()
            let field = search.convert(search.bounds,to:nil), details = app.inspector.view.convert(app.inspector.view.bounds,to:nil)
            _ = toolbar
            return field.maxX <= details.minX + 1
        }
        qa.add("S finds similar images",snapshot:true,timeout:8,{ qa.click(grid,at:qa.tile(0)); qa.key(1,"s") }) {
            app.results?.title.hasPrefix("Similar to") == true && grid.items.count > 2 && app.backButton.isHidden == false && app.titleLabel.stringValue.hasPrefix("Similar to")
        }
        qa.add("Escape leaves the results",{ qa.key(53,"\u{1B}"); qa.key(53,"\u{1B}") }) { app.results == nil && grid.items.count == total + 1 && app.backButton.isHidden }
        qa.add("Details show an image's colors",snapshot:true,{ qa.click(grid,at:qa.tile(0)) }) {
            !app.inspector.swatchColors.isEmpty || grid.items[0].colors.isEmpty == false
        }
        qa.add("A swatch finds items with that color",{ app.inspector.pickSwatch(0) }) {
            app.search.stringValue.hasPrefix("#") && !grid.items.isEmpty && app.titleLabel.stringValue.hasPrefix("Results for")
        }
        qa.add("Back clears the color search",{ app.goBack() }) { app.search.stringValue.isEmpty && grid.items.count == total + 1 }
        var fitScale: CGFloat = 0
        qa.add("The viewer opens fitted",snapshot:true,timeout:5,{ qa.click(grid,at:qa.tile(0)); qa.key(36,"\r") }) {
            fitScale = app.viewer.zoom.magnificationValue
            return !app.viewer.isHidden && app.viewer.zoomTitle == "Fit" && app.viewer.zoom.hasFullImage
        }
        qa.add("Z zooms to fill",{ qa.key(6,"z") }) { app.viewer.zoomTitle == "Fill" && app.viewer.zoom.magnificationValue > fitScale }
        qa.add("Z again shows 100%",snapshot:true,{ qa.key(6,"z") }) { app.viewer.zoomTitle == "100%" && abs(app.viewer.zoom.magnificationValue - 1) < 0.01 }
        qa.add("Command-plus zooms further",{ qa.key(24,"+",flags:.command) }) { app.viewer.zoom.magnificationValue > 1.2 && app.viewer.zoomTitle.hasSuffix("%") }
        qa.add("Z returns to fit",{ qa.key(6,"z") }) { app.viewer.zoomTitle == "Fit" && abs(app.viewer.zoom.magnificationValue - fitScale) < 0.01 }
        qa.add("Escape closes the zoomed viewer",{ qa.key(53,"\u{1B}") }) { app.viewer.isHidden }
        qa.add("Hover lifts the tile under the pointer",{ qa.move(grid,to:qa.tile(2)) }) { grid.hoveredIndex == 2 }
        qa.add("Moving off the tiles ends the hover",{ qa.move(grid,to:NSPoint(x:4,y:4)) }) { grid.hoveredIndex == nil }
        qa.add("Zooming keeps the item under the pointer in place",{
            let point = qa.tile(9), visible = grid.visibleRect, index = grid.geometry.index(x:point.x,y:point.y)!
            let offset = point.y - visible.minY
            grid.setZoom(grid.tileSize * 1.6,anchor:point)
            let after = grid.geometry.frame(index:index)
            zoomCheck = after.minY - 2 <= grid.visibleRect.minY + offset && grid.visibleRect.minY + offset <= after.maxY + 2
        }) { zoomCheck }
        qa.add("Zooming back out",{ grid.setZoom(220) }) { grid.tileSize == 220 }
        if let gif = ProcessInfo.processInfo.environment["QA_GIF"] {
            qa.add("A GIF imports",timeout:5,{ app.importURLs([URL(fileURLWithPath:gif)]) }) { grid.items.contains { $0.ext == "gif" } }
            qa.add("A GIF plays on hover",timeout:4,{
                if let index = grid.items.firstIndex(where:{ $0.ext == "gif" }) { grid.reveal(index); grid.refresh(); qa.move(grid,to:qa.tile(index)) }
            }) { grid.items.firstIndex(where:{ $0.ext == "gif" }).map { grid.isAnimating($0) } ?? false }
        }
        if let video = ProcessInfo.processInfo.environment["QA_VIDEO"] {
            qa.add("A video imports",timeout:5,{ app.importURLs([URL(fileURLWithPath:video)]) }) { grid.items.contains { $0.kind == "video" } }
            qa.add("A video plays muted on hover",timeout:4,{
                if let index = grid.items.firstIndex(where:{ $0.kind == "video" }) { grid.reveal(index); grid.refresh(); qa.move(grid,to:qa.tile(index)) }
            }) { grid.playingVideo.map { $0.playing && $0.muted } ?? false }
            qa.add("The viewer saves a video frame as a picture",timeout:6,{
                if let video = grid.items.first(where:{ $0.kind == "video" }) { app.showViewer(video) }
                DispatchQueue.main.asyncAfter(deadline:.now() + 1) { app.saveVideoFrame() }
            }) { grid.items.contains { $0.kind == "image" && $0.title.contains(" at 0.0") } }
            qa.add("Opening the viewer stops the hover video",{ }) { grid.playingVideo == nil }
            qa.add("Back from the video",{ app.viewer.closeViewer() }) { app.viewer.isHidden }
            qa.add("Find Similar works on a video",timeout:8,{
                if let i = grid.items.firstIndex(where:{ $0.kind == "video" }) { qa.click(grid,at:qa.tile(i)); app.findSimilar() }
            }) {
                guard let video = grid.items.first(where:{ $0.kind == "video" }) ?? app.results?.items.first(where:{ $0.kind == "video" }) else { return false }
                return ((try? app.database.featurePrints(version:VisualSimilarity.version)) ?? []).contains { $0.id == video.id }
            }
            qa.add("Back from similar videos",{ if app.results != nil { app.goBack() } }) { app.results == nil }
            qa.add("Moving off a video stops it",{ qa.move(grid,to:NSPoint(x:2,y:2)) }) { grid.playingVideo == nil }
        }
        qa.add("A quick filter narrows the grid",{ app.setFilter(("Liked","is:liked")) }) {
            !grid.items.isEmpty && grid.items.allSatisfy(\.liked) && app.countLabel.stringValue.hasSuffix("Liked")
        }
        qa.add("Everything clears the filter",{ app.setFilter(nil) }) { grid.items.count > 10 && !app.countLabel.stringValue.contains("·") }
        qa.add("Right-click offers Open With and Export",{ }) {
            let event = NSEvent.mouseEvent(with:.rightMouseDown,location:grid.convert(qa.tile(1),to:nil),modifierFlags:[],timestamp:0,
                                           windowNumber:app.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            let titles = grid.menu(for:event)?.items.map(\.title) ?? []
            return titles.contains("Open With") && titles.contains("Export…") && titles.contains("Find Similar")
        }
        qa.add("Refresh redraws thumbnails",{ app.refreshThumbnails() }) { grid.loadedVisibleCount == grid.visibleCount }
        qa.add("Open a collection",{ if let p = qa.sidebarRow("QA Board") { qa.click(app.sidebar,at:p) } }) {
            app.currentCollection != nil && grid.items.count == 3 && grid.canReorder?() == true
        }
        var arranged: [String] = []
        qa.add("Dragging arranges a collection by hand",{
            arranged = grid.items.map(\.id)
            grid.reorder?([arranged[2]],arranged[0])
        }) {
            app.sort == .custom && grid.items.map(\.id) == [arranged[2],arranged[0],arranged[1]]
        }
        qa.add("A drop point maps to a place in the order",{ }) {
            let first = grid.geometry.frame(index:0)
            return grid.insertion(at:CGPoint(x:first.minX + 2,y:first.midY)) == 0 && grid.insertion(at:CGPoint(x:first.maxX - 2,y:first.midY)) == 1
        }
        qa.add("Undo restores the order",{ qa.key(6,"z",flags:.command) }) { grid.items.map(\.id) == arranged }
        qa.add("Back to date added",{ app.applySort(.added) }) { app.sort == .added }
        if let page = ProcessInfo.processInfo.environment["QA_LINK"].flatMap(URL.init(string:)) {
            qa.add("Pasting a web address saves a link card",timeout:20,{
                if let p = qa.sidebarRow("All Items") { qa.click(app.sidebar,at:p) }
                let board = NSPasteboard(name:.init("org.lumashelf.qa")); board.clearContents(); board.setString(page.absoluteString,forType:.string)
                _ = grid.receive(board)
            }) {
                guard let link = (try? app.database.items(scope:.kind("link")))?.first else { return false }
                return link.title == "Quiet rooms" && link.path.hasPrefix("/") && link.width > 0
            }
            qa.add("The link card shows its preview",snapshot:true,timeout:5,{ app.loadItems() }) { grid.items.first?.kind == "link" && grid.loadedVisibleCount == grid.visibleCount }
            if let bare = ProcessInfo.processInfo.environment["QA_LINK_BARE"].flatMap(URL.init(string:)) {
                qa.add("A page without a preview image gets a snapshot",timeout:40,{ app.saveLinks([bare]) }) {
                    (try? app.database.items(scope:.kind("link")))?.contains { $0.url == bare.absoluteString && $0.path.hasPrefix("/") && $0.title == "Plain page" } == true
                }
            }
        }
        qa.add("A saved color shows as a paint chip",snapshot:true,timeout:4,{
            if let swatch = ShelfItem.color("#3366ff") { try? app.database.insert([swatch]); app.loadItems() }
        }) { grid.items.contains { $0.kind == "color" } }
        qa.add("Search by meaning adds related images",{ app.search.stringValue = "skies"; app.loadItems() }) {
            app.relatedCount > 0 && grid.items.suffix(app.relatedCount).allSatisfy { ($0.tags + $0.autoTags).contains { $0.lowercased().contains("sky") } }
                && app.countLabel.stringValue.contains("related")
        }
        qa.add("Quoted searches stay exact",{ app.search.stringValue = "\"skies\""; app.loadItems() }) { app.relatedCount == 0 }
        qa.add("Clear the meaning search",{ app.search.stringValue = ""; app.loadItems() }) { app.relatedCount == 0 && grid.items.count > 10 }
        var boardBefore: BoardPlacement?
        qa.add("Command-3 shows a collection as a board",snapshot:true,timeout:5,{
            if let p = qa.sidebarRow("QA Board") { qa.click(app.sidebar,at:p) }
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.5) { qa.key(20,"3",flags:.command) }
        }) { app.boardShown && !app.boardScroll.isHidden && app.board.items.count == 3 && app.board.placements.count == 3 && app.styleSwitch.selectedSegment == 2 }
        qa.add("Dragging moves an item on the board",timeout:4,{
            let item = app.board.items[0], frame = app.board.frame(of:item)
            boardBefore = app.board.placements[item.id]
            qa.drag(app.board,from:NSPoint(x:frame.midX,y:frame.midY),to:NSPoint(x:frame.midX + 140,y:frame.midY + 60))
        }) {
            guard let id = app.board.items.first?.id, let before = boardBefore, let saved = (try? app.database.boardPlacements(collection:app.currentCollection ?? ""))?[id] else { return false }
            return abs(saved.x - before.x - 140) < 1 && abs(saved.y - before.y - 60) < 1
        }
        qa.add("Undo puts it back",timeout:4,{ qa.key(6,"z",flags:.command) }) {
            guard let id = app.board.items.first?.id, let before = boardBefore else { return false }
            return (try? app.database.boardPlacements(collection:app.currentCollection ?? ""))?[id].map { abs($0.x - before.x) < 1 && abs($0.y - before.y) < 1 } == true
        }
        qa.add("The corner handle resizes",timeout:4,{
            let item = app.board.items[0]; qa.click(app.board,at:NSPoint(x:app.board.frame(of:item).midX,y:app.board.frame(of:item).midY))
            let frame = app.board.frame(of:item)
            qa.drag(app.board,from:NSPoint(x:frame.maxX - 3,y:frame.maxY - 3),to:NSPoint(x:frame.maxX + 97,y:frame.maxY + 40))
        }) {
            guard let id = app.board.items.first?.id, let before = boardBefore else { return false }
            return ((try? app.database.boardPlacements(collection:app.currentCollection ?? ""))?[id]?.width ?? 0) > before.width + 90
        }
        qa.add("Arrow keys nudge",{ qa.key(124,"\u{F703}",flags:.shift) }) {
            guard let id = app.board.selection.first else { return false }
            return abs((app.board.placements[id]?.x ?? 0) - ((boardBefore?.x ?? 0) + 10)) < 1
        }
        qa.add("Tidy Up lays the board out again",timeout:5,{ app.resetBoardLayout() }) {
            guard let id = app.board.items.first?.id, let before = boardBefore else { return false }
            return app.board.placements[id].map { abs($0.width - before.width) < 1 } == true && !app.boardScroll.isHidden
        }
        qa.add("Command-1 goes back to rows",{ qa.key(18,"1",flags:.command) }) { !app.boardShown && app.boardScroll.isHidden && !app.scroll.isHidden && grid.style == .rows }
        qa.add("All Items has a board too",snapshot:true,timeout:6,{
            if let p = qa.sidebarRow("All Items") { qa.click(app.sidebar,at:p) }
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.4) { qa.key(20,"3",flags:.command) }
        }) {
            app.boardShown && app.board.items.count == grid.items.count && app.styleSwitch.segmentCount == 3
                && (try? app.database.boardPlacements(collection:"scope:all"))?.count == grid.items.count
        }
        qa.add("A board builds only what is near the view",{ }) { app.board.builtPieces > 0 && app.board.builtPieces <= app.board.items.count }
        qa.add("Back to rows in All Items",{ qa.key(18,"1",flags:.command) }) { !app.boardShown && grid.style == .rows }
        qa.add("A tag has its own board",timeout:6,{
            if let p = qa.sidebarRow("blue") { qa.click(app.sidebar,at:p) }
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.4) { qa.key(20,"3",flags:.command) }
        }) { app.boardKey == "tag:blue" && app.boardShown && app.board.items.count == grid.items.count && !grid.items.isEmpty }
        qa.add("Back to rows for the tag",{ qa.key(18,"1",flags:.command) }) { !app.boardShown }
        var target = ""
        qa.add("A folio:// link reveals the item",timeout:4,{
            if let p = qa.sidebarRow("Liked") { qa.click(app.sidebar,at:p) }
            target = (try? app.database.items(query:"Sonoma",limit:1))?.first?.id ?? ""
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.4) { app.application(NSApp,open:[URL(string:"folio://item/\(target)")!]) }
        }) { !target.isEmpty && app.scope == .all && qa.ids == [target] }
        qa.add("Changes from the folio command show up",timeout:4,{
            try? app.database.addTags(["from-terminal"],to:[target])
            DistributedNotificationCenter.default().postNotificationName(.init("org.lumashelf.library-changed"),object:nil,userInfo:nil,deliverImmediately:true)
        }) { app.tagCache.contains { $0.name == "from-terminal" } }
        qa.add("The menu bar pin offers the library and a way back to Settings",{ }) {
            let menu = NSMenu(); MenuBarPin.shared.menuNeedsUpdate(menu)
            let titles = menu.items.map(\.title)
            return ["Open Folio","Paste into Folio","Add Files or Folder…","Settings…","Quit Folio"].allSatisfy(titles.contains) && MenuBarPin.mark.isTemplate
        }
        var flipID = "", flipWas = false
        qa.add("Option-click likes without selecting",timeout:3,{
            qa.click(grid,at:qa.tile(0)); flipID = grid.items[2].id; flipWas = grid.items[2].liked; qa.click(grid,at:qa.tile(2),flags:.option)
        }) { qa.ids == [grid.items[0].id] && grid.items.first { $0.id == flipID }?.liked == !flipWas }
        qa.add("Option-click again puts it back",timeout:3,{ if let i = grid.items.firstIndex(where:{ $0.id == flipID }) { qa.click(grid,at:qa.tile(i),flags:.option) } }) {
            grid.items.first { $0.id == flipID }?.liked == flipWas
        }
        qa.add("The command menu offers Open With for one item",{
            if let i = grid.items.firstIndex(where:{ $0.kind == "image" && $0.path.hasPrefix("/") }) { grid.reveal(i); grid.refresh(); qa.click(grid,at:qa.tile(i)) }
        }) {
            app.paletteEntries(.root,"open with").contains { $0.title.hasPrefix("Open With ") }
        }
        qa.add("R shuffles",timeout:3,{ qa.key(15,"r") }) { if case .random = app.sort { return true }; return false }
        qa.add("Sorting by date added again",timeout:3,{ app.applySort(.added) }) { if case .added = app.sort { return true }; return false }
        qa.add("New Smart Folder opens the editor",snapshot:true,timeout:3,{ app.newSmartFolder(nil) }) {
            app.smartFolderEditing != nil && app.window.attachedSheet != nil
        }
        qa.add("The editor counts what its rules gather",timeout:3,{
            guard let model = app.smartFolderEditing else { return }
            model.name = "Wide pictures"; model.rows = [.init(rule:SmartRule(.orientation,.is,"landscape"))]
        }) {
            guard let model = app.smartFolderEditing, let expected = try? app.database.count(rules:model.saved) else { return false }
            return expected > 0 && model.count == expected && model.canSave
        }
        qa.add("Create makes the smart folder",timeout:4,{ app.smartFolderEditing?.finish?(true) }) {
            app.smartFolderEditing == nil && app.rows.contains { $0.kind == .smart && $0.title == "Wide pictures" }
        }
        qa.add("Editing it shows its rules again",timeout:3,{
            if let id = app.rows.first(where:{ $0.title == "Wide pictures" })?.id { app.editSmartFolder(id) }
        }) { app.smartFolderEditing?.rows.first?.rule.field == .orientation && app.smartFolderEditing?.name == "Wide pictures" }
        qa.add("Cancel leaves it as it was",timeout:3,{ app.smartFolderEditing?.finish?(false) }) {
            app.smartFolderEditing == nil && app.window.attachedSheet == nil
        }
        qa.add("Back to All Items",timeout:3,{ if let p = qa.sidebarRow("All Items") { qa.click(app.sidebar,at:p) }; app.window.makeFirstResponder(grid) }) { app.scope == .all }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("QA copy of a picture.png")
        qa.add("A copy of a picture imports",timeout:5,{
            try? FileManager.default.removeItem(at:copy)
            if let original = grid.items.first(where:{ $0.ext == "png" && $0.path.hasPrefix("/") }) { try? FileManager.default.copyItem(atPath:original.path,toPath:copy.path) }
            app.importURLs([copy])
        }) { grid.items.contains { $0.title == "QA copy of a picture" } }
        qa.add("Find Duplicates selects the extra copy",snapshot:true,timeout:8,{ app.findDuplicates() }) {
            app.results?.title == "Duplicates" && qa.ids.contains { id in grid.items.first { $0.id == id }?.title == "QA copy of a picture" }
                && app.toast.actionTitle == "Move to Trash"
        }
        var trashBefore = 0
        qa.add("Moving the extras to the Trash keeps the oldest",timeout:4,{ trashBefore = qa.count(.trash); app.toast.run() }) {
            qa.count(.trash) > trashBefore && (try? app.database.items(query:"QA copy of a picture"))?.isEmpty == true
        }
        qa.add("Back from Duplicates",{ app.goBack() }) { app.results == nil }
        qa.add("Backups say when and why they were kept",{ }) {
            GeneralSettingsPane.describe(URL(fileURLWithPath:"/x/index-20261012-181502-000-before-empty-trash.sqlite")).hasSuffix("· Before emptying the Trash")
                && GeneralSettingsPane.describe(URL(fileURLWithPath:"/x/index-20261012-090000-000-auto.sqlite")).hasSuffix("· Daily backup")
        }
        func menuItem(_ menu: String, _ title: String) -> NSMenuItem? { NSApp.mainMenu?.items.first { $0.title == menu }?.submenu?.items.first { $0.title == title } }
        qa.add("A menu command takes new keys",{ Shortcuts.set("Item/Find Similar",Shortcuts.Keys(key:"s",modifiers:NSEvent.ModifierFlags([.command,.option]).rawValue)) }) {
            menuItem("Item","Find Similar").map { $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask.contains([.command,.option]) } == true
        }
        qa.add("Keys already in use move to the new command",{ Shortcuts.set("Item/Find Similar",Shortcuts.Keys(key:"k",modifiers:NSEvent.ModifierFlags.command.rawValue)) }) {
            menuItem("Item","Find Similar")?.keyEquivalent == "k" && menuItem("Edit","Command Menu…")?.keyEquivalent == ""
                && app.paletteEntries(.root,"").first { $0.id == "newcollection" }?.hint == "⇧⌘N"
        }
        qa.add("Reset All puts every shortcut back",{ Shortcuts.resetAll() }) {
            menuItem("Edit","Command Menu…")?.keyEquivalent == "k" && menuItem("Item","Find Similar")?.keyEquivalent == "" && Shortcuts.overrides.isEmpty
        }
        func gapAfterFirst() -> Double { Double(grid.geometry.frame(index:1).minX - grid.geometry.frame(index:0).maxX) }
        qa.add("Tight spacing pulls pictures together",{
            UserDefaults.standard.set("tight",forKey:"gridSpacing"); NotificationCenter.default.post(name:ShelfGridView.shapeChanged,object:nil)
        }) { gapAfterFirst() > 0 && gapAfterFirst() < 6 }
        qa.add("Standard spacing again",{
            UserDefaults.standard.removeObject(forKey:"gridSpacing"); NotificationCenter.default.post(name:ShelfGridView.shapeChanged,object:nil)
        }) { gapAfterFirst() >= 9 }
        let otherLibrary = FileManager.default.temporaryDirectory.appendingPathComponent("QA Other Library")
        var savedOthers: [URL] = [], sentID = ""
        qa.add("Right-click offers another library",{
            try? FileManager.default.removeItem(at:otherLibrary); try? FileManager.default.createDirectory(at:otherLibrary,withIntermediateDirectories:true)
            savedOthers = LibraryLocation.others; LibraryLocation.others = [otherLibrary]
            qa.click(grid,at:qa.tile(0)); sentID = grid.items[0].id
        }) { app.itemMenu(app.selection).items.contains { $0.title == "Copy to Library" } }
        qa.add("Copy to Library puts the item there",timeout:5,{ app.send(app.selection,to:otherLibrary,move:false) }) {
            ((try? LibraryDatabase(root:otherLibrary).count()) ?? 0) == 1 && grid.items.contains { $0.id == sentID }
        }
        var trashBeforeMove = 0
        qa.add("Move to Library takes it from here",timeout:5,{
            trashBeforeMove = qa.count(.trash); qa.click(grid,at:qa.tile(1)); app.send(app.selection,to:otherLibrary,move:true)
        }) { ((try? LibraryDatabase(root:otherLibrary).count()) ?? 0) == 2 && qa.count(.trash) == trashBeforeMove + 1 }
        qa.add("Undo brings the moved item back here",timeout:3,{ qa.key(6,"z",flags:.command); LibraryLocation.others = savedOthers }) { qa.count(.trash) == trashBeforeMove }
        var colorsBefore = 0
        qa.add("Pasting a palette saves its colors",timeout:3,{
            colorsBefore = grid.items.filter { $0.kind == "color" }.count
            let board = NSPasteboard(name:.init("org.lumashelf.qa")); board.clearContents(); board.setString("Palette: #E07A5F, #3D405B, #F2CC8F",forType:.string)
            grid.receive(board)
        }) { grid.items.filter { $0.kind == "color" }.count == colorsBefore + 3 && app.toast.message == "Saved 3 colors" }
        qa.add("Pasting them again adds nothing",timeout:3,{
            let board = NSPasteboard(name:.init("org.lumashelf.qa")); board.clearContents(); board.setString("#e07a5f",forType:.string)
            grid.receive(board)
        }) { grid.items.filter { $0.kind == "color" }.count == colorsBefore + 3 && app.toast.message == "That color is already saved" }
        qa.add("A note goes on several items at once",timeout:3,{
            qa.click(grid,at:qa.tile(0)); qa.click(grid,at:qa.tile(1),flags:.command); app.setNote("Shared note",for:app.selection)
        }) { qa.ids.count == 2 && grid.items.prefix(2).allSatisfy { $0.note == "Shared note" } && app.inspector.items.count == 2 }
        qa.add("An item's source can be set and undone",timeout:3,{
            qa.click(grid,at:qa.tile(0)); if let item = app.selection.first { app.setSource("https://example.com/ref",for:item) }
        }) { grid.items.first?.source == "https://example.com/ref" }
        qa.add("Undo takes the source back",timeout:3,{ qa.key(6,"z",flags:.command) }) { grid.items.first?.source.isEmpty == true }
        qa.add("Each selection colour is its own",{ }) {
            let dark = NSAppearance(named:.darkAqua)!
            let colors = ["accent","graphite","lightGrey","ink"].map { Theme.selection($0,appearance:dark).usingColorSpace(.sRGB)! }
            return Set(colors.map { "\(Int($0.redComponent*255)),\(Int($0.greenComponent*255)),\(Int($0.blueComponent*255))" }).count == 4
        }
        qa.add("File ▸ Library lists libraries and makes new ones",{ }) {
            let menu = NSMenu(); LibraryMenu.shared.app = app; LibraryMenu.shared.menuNeedsUpdate(menu)
            let titles = menu.items.map(\.title)
            return titles.first == "Main Library" && ["New Library…","Open Library…","Show Library in Finder"].allSatisfy(titles.contains)
                && app.libraries.first == LibraryLocation.folder
        }
        qa.add("Tags sort by name from their heading",timeout:3,{
            let menu = app.sidebarMenu(for:app.rows.firstIndex { $0.kind == .header && $0.title == "Tags" } ?? 0)
            if let choice = menu.items.first(where:{ $0.title == "Sort Tags By" })?.submenu?.items.first(where:{ $0.title == "Name" }) { app.chooseSidebarSort(choice) }
        }) {
            let names = app.rows.filter { $0.kind == .tag }.map { $0.id ?? "" }
            return names.count > 1 && names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        qa.add("And back to by number of items",{ UserDefaults.standard.set("count",forKey:"sidebar.sort.Tags"); app.reload() }) { app.sidebarSort("Tags") == "count" }
        qa.add("Clicking a section title folds it away",{
            guard let row = app.rows.firstIndex(where:{ $0.kind == .header && $0.title == "Tags" }),
                  let header = app.sidebar.view(atColumn:0,row:row,makeIfNecessary:true) as? SidebarHeader else { return }
            header.mouseDown(with:NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:app.window.windowNumber,
                                                     context:nil,eventNumber:0,clickCount:1,pressure:1)!)
        }) {
            !app.rows.contains { $0.kind == .tag } && app.rows.contains { $0.kind == .header && $0.title == "Tags" }
        }
        qa.add("Clicking it again brings it back",{ app.toggleSection("Tags") }) { app.rows.contains { $0.kind == .tag } }
        let eagle = FileManager.default.temporaryDirectory.appendingPathComponent("QA Shelf.library")
        qa.add("Importing a library makes its folders collections",snapshot:true,timeout:8,{
            try? FileManager.default.removeItem(at:eagle)
            let picture = URL(fileURLWithPath:grid.items.first { $0.ext == "png" || $0.ext == "jpg" }?.path ?? "")
            func json(_ object: Any, _ path: String) {
                let url = eagle.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try? JSONSerialization.data(withJSONObject:object).write(to:url)
            }
            json(["folders":[["id":"P","name":"Posters","children":[["id":"S","name":"Swiss","children":[]]]]]],"metadata.json")
            json(["id":"I1","name":"Kunsthalle","ext":picture.pathExtension,"tags":["swiss"],"folders":["S"],"url":"https://example.com/k"],"images/I1.info/metadata.json")
            try? FileManager.default.copyItem(at:picture,to:eagle.appendingPathComponent("images/I1.info/Kunsthalle.\(picture.pathExtension)"))
            app.importLibrary(at:eagle)
        }) {
            let collections = (try? app.database.collections()) ?? []
            guard case .collection(let shown,_) = app.scope, let root = collections.first(where:{ $0.name == "QA Shelf" }), let posters = collections.first(where:{ $0.name == "Posters" }),
                  let swiss = collections.first(where:{ $0.name == "Swiss" }) else { return false }
            return posters.parent == root.id && swiss.parent == posters.id && shown == root.id && app.toast.message.hasPrefix("Imported 1 item")
        }
        qa.add("Importing it again changes nothing",timeout:6,{ app.importLibrary(at:eagle) }) {
            app.toast.message.hasSuffix("is up to date") && ((try? app.database.collections()) ?? []).filter { $0.name == "Swiss" }.count == 1
        }
    }
}
