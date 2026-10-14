import AppKit

/// Holding ⌘ for a moment shows the keys Folio answers to: the menu commands (as set in Settings ▸ Shortcuts) and the
/// single keys that act on the selection. Letting go, or pressing any key, puts it away.
final class ShortcutHints: NSVisualEffectView {
    private var timer: Timer?
    private var monitor: Any?
    private let stack = NSStackView()
    static var singleKeys: [(String,String)] { SingleKeys.actions.map { (SingleKeys.key($0.id).uppercased(),$0.title) } + [("Space","Quick Look"),("↩","Open")] }
    /// Menu commands worth a hint, by "Menu/Title".
    static let picks = ["Edit/Command Menu…","Edit/Go to…","Edit/Find","File/Add Files or Folder…","File/New Collection…","File/New Smart Folder…",
                        "Edit/Paste as Link","View/as Rows","View/as Columns","View/as Board","View/as List","View/as Infinity","View/Show Details","Item/Show in Finder","Item/Move to Trash"]
    init() {
        super.init(frame:.zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true; layer?.borderWidth = 0.5
        updateColors()
        alphaValue = 0; isHidden = true
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 36
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-24),
                                     stack.topAnchor.constraint(equalTo:topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-20)])
        setAccessibilityRole(.group); setAccessibilityLabel("Keyboard shortcuts")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    /// Solid, so the keys read clearly over busy pictures.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.flagsChanged,.keyDown,.leftMouseDown]) { [weak self] event in
            self?.handle(event); return event
        }
    }
    private func handle(_ event: NSEvent) {
        let onlyCommand = event.type == .flagsChanged && event.modifierFlags.intersection([.command,.shift,.option,.control]) == .command
        timer?.invalidate(); timer = nil
        if onlyCommand, window?.isKeyWindow == true, window?.attachedSheet == nil {
            timer = Timer.scheduledTimer(withTimeInterval:0.8,repeats:false) { [weak self] _ in self?.show() }
        } else { hide() }
    }
    func show() {
        rebuild(); isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }
    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }) { [weak self] in if self?.alphaValue == 0 { self?.isHidden = true } }
    }
    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let menu = Self.picks.compactMap { id -> (String,String)? in
            let keys = Shortcuts.current(id)
            let title = String(id.split(separator:"/").last ?? "").replacingOccurrences(of:"…",with:"")
            return keys.isEmpty ? nil : (keys,title.hasPrefix("as ") ? "Show " + title : title)
        }
        stack.addArrangedSubview(column("Commands",menu)); stack.addArrangedSubview(column("With items selected",Self.singleKeys))
    }
    private func column(_ title: String, _ rows: [(String,String)]) -> NSView {
        let header = label(title,size:11,weight:.semibold,color:.secondaryLabelColor)
        let grid = NSGridView(views:rows.map { keys, name in
            let key = label(keys,size:12,weight:.semibold,color:.labelColor); key.alignment = .right
            key.font = .monospacedDigitSystemFont(ofSize:12,weight:.semibold)
            return [key,label(name,size:12,color:.labelColor)]
        })
        grid.columnSpacing = 12; grid.rowSpacing = 6; grid.column(at:0).xPlacement = .trailing
        let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        column.setViews([header,grid],in:.top)
        grid.setContentHuggingPriority(.required,for:.vertical)
        for row in 0..<grid.numberOfRows { grid.row(at:row).yPlacement = .center }
        return column
    }
}
