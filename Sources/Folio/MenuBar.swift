import AppKit

/// Folio's pin in the menu bar: open the library, paste or add to it, and the way back to Settings when the Dock icon
/// is hidden. Hiding the Dock icon always keeps the pin, so Folio can't go missing.
@MainActor final class MenuBarPin: NSObject, NSMenuDelegate {
    static let shared = MenuBarPin()
    private var item: NSStatusItem?
    weak var app: AppController?
    static var showsPin: Bool { UserDefaults.standard.bool(forKey:"general.menuBar") || !showsDockIcon }
    static var showsDockIcon: Bool { UserDefaults.standard.object(forKey:"general.dockIcon") as? Bool ?? true }

    /// Applies both settings; called at launch and whenever either changes.
    func update() {
        let dock = Self.showsDockIcon
        if (NSApp.activationPolicy() == .regular) != dock {
            // Switching policy sends the app to the back; bring back the window the person was in (often Settings,
            // where the switch was flipped), not always the library.
            let working = NSApp.keyWindow ?? app?.window
            NSApp.setActivationPolicy(dock ? .regular : .accessory)
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps:true); working?.makeKeyAndOrderFront(nil) }
        }
        if Self.showsPin, item == nil {
            let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
            item.button?.image = Self.mark; item.button?.setAccessibilityLabel("Folio")
            // Files, links and colors dropped on the pin go into the library, as if pasted.
            if let button = item.button {
                let target = PinDropTarget(frame:button.bounds); target.autoresizingMask = [.width,.height]
                target.receive = { [weak self] pasteboard in self?.app?.grid.receive(pasteboard) ?? false }
                button.addSubview(target)
            }
            let menu = NSMenu(); menu.delegate = self; item.menu = menu
            self.item = item
        } else if !Self.showsPin, let item {
            NSStatusBar.system.removeStatusItem(item); self.item = nil
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:key); entry.target = self; menu.addItem(entry)
        }
        add("Open Folio",#selector(open))
        add("Command Menu…",#selector(palette))
        menu.addItem(.separator())
        add("Paste into Folio",#selector(paste))
        add("Add Files or Folder…",#selector(addFiles))
        menu.addItem(.separator())
        add("Settings…",#selector(settings))
        if !Self.showsDockIcon { add("Show Dock Icon",#selector(showDock)) }
        menu.addItem(.separator())
        add("Quit Folio",#selector(quit))
    }
    private func front() { NSApp.activate(ignoringOtherApps:true); app?.showLibrary() }
    @objc private func open() { front() }
    @objc private func palette() { front(); app?.showPalette() }
    @objc private func paste() { app?.pasteIntoLibrary() }
    @objc private func addFiles() { front(); app?.importPanel() }
    @objc private func settings() { NSApp.activate(ignoringOtherApps:true); app?.openSettings(.general) }
    @objc private func showDock() { UserDefaults.standard.set(true,forKey:"general.dockIcon"); update() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// The app's mark (three square tiles and a round one) drawn as a menu bar template.
    static let mark: NSImage = {
        let image = NSImage(size:NSSize(width:16,height:16),flipped:true) { _ in
            NSColor.black.setFill()
            let tile: CGFloat = 7, gap: CGFloat = 1.6, origin: CGFloat = (16 - tile * 2 - gap) / 2
            for (x,y) in [(0,0),(0,1),(1,1)] as [(CGFloat,CGFloat)] {
                NSBezierPath(roundedRect:NSRect(x:origin + x * (tile + gap),y:origin + y * (tile + gap),width:tile,height:tile),xRadius:1.3,yRadius:1.3).fill()
            }
            NSBezierPath(ovalIn:NSRect(x:origin + tile + gap,y:origin,width:tile,height:tile)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Sits over the menu bar pin to take drops; a click opens the pin's menu as usual.
final class PinDropTarget: NSView {
    var receive: ((NSPasteboard) -> Bool)?
    override init(frame: NSRect) { super.init(frame:frame); registerForDraggedTypes([.fileURL,.URL,.string,.png,.tiff,.color]) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { (superview as? NSButton)?.performClick(nil) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receive?(sender.draggingPasteboard) ?? false }
}
