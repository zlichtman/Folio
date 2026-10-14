import AppKit
import ShelfCore

/// Development check (`--qa <folder>`): drives the real window with synthetic clicks and keys while it stays
/// off-screen, checks the result of each step, saves snapshots and writes `report.json`, then quits.
/// Use a throwaway library (`--library`), since the steps edit it.
@MainActor final class QAHarness {
    struct Step {
        var name: String
        var action: () -> Void
        var check: () -> Bool
        var timeout: Double = 3
        var snapshot = false
    }
    let app: AppController
    private let folder: URL
    private var steps: [Step] = []
    private var results: [[String:Any]] = []
    init(app: AppController, folder: URL) { self.app = app; self.folder = folder }

    // MARK: Synthetic input

    var window: NSWindow { app.window }
    /// The window isn't on screen, so AppKit drops its mouse events: deliver them to the view under the point,
    /// the same handlers a real click reaches. Views that track the mouse themselves get the release queued first.
    private func event(_ type: NSEvent.EventType, _ view: NSView, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = [], _ count: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
                           windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:1)!
    }
    private func target(_ view: NSView, _ point: NSPoint) -> NSView {
        let frame = window.contentView!.superview!
        return frame.hitTest(frame.convert(view.convert(point,to:nil),from:nil)) ?? view
    }
    func click(_ view: NSView, at point: NSPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1, right: Bool = false) {
        let hit = target(view,point)
        if ProcessInfo.processInfo.environment["QA_DEBUG"] != nil { fputs("click \(type(of:view)) \(point) -> \(type(of:hit))\n",stderr) }
        if right { _ = hit.menu(for:event(.rightMouseDown,view,point,flags)); return }
        let tracker = sequence(first:hit,next:{ $0.superview }).first { $0 is NSTableView }
        // A table tracks the mouse in its own loop, which needs a key window; apply the selection its click would make.
        if let table = tracker as? NSTableView {
            let row = table.row(at:table.convert(view.convert(point,to:nil),from:nil))
            if row >= 0, table.delegate?.tableView?(table,shouldSelectRow:row) ?? true { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
            if ProcessInfo.processInfo.environment["QA_DEBUG"] != nil { fputs("table row \(row) selected \(table.selectedRow) scope \(app.scope)\n",stderr) }
            return
        }
        if window.firstResponder !== hit, hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
        hit.mouseDown(with:event(.leftMouseDown,view,point,flags,count))
        hit.mouseUp(with:event(.leftMouseUp,view,point,flags,count))
    }
    func move(_ view: NSView, to point: NSPoint) { target(view,point).mouseMoved(with:event(.mouseMoved,view,point)) }
    func drag(_ view: NSView, from start: NSPoint, to end: NSPoint) {
        let hit = target(view,start)
        hit.mouseDown(with:event(.leftMouseDown,view,start))
        for t in 1...6 { hit.mouseDragged(with:event(.leftMouseDragged,view,NSPoint(x:start.x + (end.x-start.x)*Double(t)/6,y:start.y + (end.y-start.y)*Double(t)/6))) }
        hit.mouseUp(with:event(.leftMouseUp,view,end))
    }
    /// Types a key the way the system would: menu shortcuts first, then the first responder. The off-screen window is
    /// never key, so a shortcut's action is sent along the window's responder chain the way AppKit does for the key window.
    func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
                                           windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,
                                           isARepeat:false,keyCode:code) else { return }
        if !flags.intersection([.command,.control]).isEmpty, let item = menuItem(characters,flags), let action = item.action {
            if let target = item.target { NSApp.sendAction(action,to:target,from:item); return }
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                if current.responds(to:action) { NSApp.sendAction(action,to:current,from:item); return }
                responder = current.nextResponder
            }
            for candidate in [window,window.delegate,NSApp.delegate] as [AnyObject?] where candidate?.responds(to:action) == true {
                NSApp.sendAction(action,to:candidate,from:item); return
            }
            return
        }
        window.sendEvent(event)
    }
    private func menuItem(_ key: String, _ flags: NSEvent.ModifierFlags) -> NSMenuItem? {
        let wanted = flags.intersection([.command,.shift,.option,.control])
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let found = search(sub) { return found }
                if item.keyEquivalent.lowercased() == key.lowercased(), !item.keyEquivalent.isEmpty,
                   item.keyEquivalentModifierMask.intersection([.command,.shift,.option,.control]) == wanted { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }
    /// Types text into whatever field is being edited, as the keyboard would.
    func typeText(_ text: String) {
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.insertText(text,replacementRange:editor.selectedRange())
    }
    func tile(_ index: Int) -> NSPoint { let f = app.grid.geometry.frame(index:index); return NSPoint(x:f.midX,y:f.midY) }
    func sidebarRow(_ title: String) -> NSPoint? {
        guard let row = app.rows.firstIndex(where:{ $0.title == title && $0.kind != .header }) else { return nil }
        let rect = app.sidebar.rect(ofRow:row); return NSPoint(x:rect.midX,y:rect.midY)
    }
    var ids: [String] { app.selection.map(\.id) }
    func count(_ scope: Scope) -> Int { (try? app.database.count(scope)) ?? -1 }

    // MARK: Running

    func add(_ name: String, snapshot: Bool = false, timeout: Double = 3, _ action: @escaping () -> Void, until check: @escaping () -> Bool) {
        steps.append(Step(name:name,action:action,check:check,timeout:timeout,snapshot:snapshot))
    }
    func run() {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        QAScenarios.build(self)
        next(0)
    }
    private func next(_ index: Int) {
        guard index < steps.count else { finish(); return }
        let step = steps[index], start = CACurrentMediaTime()
        step.action()
        func poll() {
            let passed = step.check()
            if passed || CACurrentMediaTime() - start > step.timeout {
                var entry: [String:Any] = ["step":step.name,"passed":passed,"ms":Int((CACurrentMediaTime()-start)*1000)]
                if step.snapshot {
                    let file = folder.appendingPathComponent(String(format:"%02d-",index) + step.name.lowercased().replacingOccurrences(of:" ",with:"-") + ".png")
                    snapshot(to:file); entry["snapshot"] = file.lastPathComponent
                }
                results.append(entry)
                fputs("\(passed ? "PASS" : "FAIL")  \(step.name)\n",stderr)
                if ProcessInfo.processInfo.environment["QA_DEBUG"] != nil { fputs("   liked \(count(.liked)) trash \(count(.trash)) undo '\(window.undoManager?.undoActionName ?? "")' redo '\(window.undoManager?.redoActionName ?? "")'\n",stderr) }
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.05) { self.next(index + 1) }
            } else { DispatchQueue.main.asyncAfter(deadline:.now() + 0.05,execute:poll) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.05,execute:poll)
    }
    func snapshot(to file: URL) {
        guard let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in:frame.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in:frame.bounds,to:bitmap) }
        try? bitmap.representation(using:.png,properties:[:])?.write(to:file)
    }
    private func finish() {
        let failed = results.filter { $0["passed"] as? Bool == false }.count
        let report: [String:Any] = ["version":AppIdentity.version,"steps":results,"failed":failed,"passed":results.count - failed]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("report.json"))
        fputs("QA: \(results.count - failed) passed, \(failed) failed\n",stderr)
        NSApp.terminate(nil)
    }
}
