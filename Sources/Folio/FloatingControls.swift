import AppKit

/// A small glass capsule that floats over the grid.
final class FloatingBar: NSVisualEffectView {
    init(_ views: [NSView], spacing: CGFloat = 6, inset: CGFloat = 5) {
        super.init(frame:.zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 15; layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        let stack = NSStackView(views:views); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:inset+3),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-inset-3),
                                     stack.topAnchor.constraint(equalTo:topAnchor,constant:inset),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-inset),
                                     heightAnchor.constraint(equalToConstant:30)])
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
    private func updateBorder() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor } }
}

/// A one-line notice above the floating controls that fades after a moment, in the same capsule as the controls.
/// A notice about something undoable carries an Undo button and stays a little longer.
final class Toast: NSVisualEffectView {
    private let text = label("",size:12,weight:.medium,color:.labelColor)
    private let button = NSButton(title:"Undo",target:nil,action:nil)
    private var action: (() -> Void)?
    private var hide: DispatchWorkItem?
    init() {
        super.init(frame:.zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 15; layer?.masksToBounds = true; layer?.borderWidth = 0.5
        alphaValue = 0; isHidden = true
        text.lineBreakMode = .byTruncatingMiddle
        button.isBordered = false; button.font = .systemFont(ofSize:12,weight:.semibold); button.contentTintColor = .controlAccentColor
        button.target = self; button.action = #selector(run); button.isHidden = true
        let stack = NSStackView(views:[text,button]); stack.spacing = 10; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),
                                     stack.centerYAnchor.constraint(equalTo:centerYAnchor),heightAnchor.constraint(equalToConstant:30),
                                     widthAnchor.constraint(lessThanOrEqualToConstant:560)])
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
    private func updateBorder() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor } }
    var message: String { text.stringValue }
    var actionTitle: String? { button.isHidden ? nil : button.title }
    func show(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        text.stringValue = message; hide?.cancel()
        self.action = action?.run; button.isHidden = action == nil; button.title = action?.title ?? ""
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = work; DispatchQueue.main.asyncAfter(deadline:.now() + (action == nil ? 2.6 : 5),execute:work)
    }
    func dismiss() {
        hide?.cancel(); action = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; animator().alphaValue = 0 }) { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        }
    }
    @objc func run() { let action = action; dismiss(); action?() }
}

func capsuleButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let button = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:tip)!,target:target,action:action)
    button.isBordered = false; button.bezelStyle = .accessoryBarAction; button.contentTintColor = .secondaryLabelColor
    button.symbolConfiguration = .init(pointSize:12,weight:.medium); button.toolTip = tip
    button.widthAnchor.constraint(equalToConstant:22).isActive = true
    return button
}
