import AppKit

/// One line in the command palette.
struct PaletteEntry {
    var id: String
    var title: String
    var detail = ""
    var symbol = "circle"
    var hint = ""
    var section = ""
    /// In a list where several can be picked (Tab), whether this one is picked.
    var marked = false
    /// Colours the icon, for a colour search.
    var tint: NSColor?
    var run: () -> Void = {}
}

/// ⌘K: type to find a command, a place or an item; Return runs it, Tab picks several in lists that allow it, Esc closes.
final class CommandPalette: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Equatable { case root, tags, collections(move: Bool), goTo }
    private let card = NSVisualEffectView()
    private let field = NSTextField()
    private let icon = NSImageView()
    private let table = PaletteTable()
    private let scroller = NSScrollView()
    private let footer = label("",size:11,color:.tertiaryLabelColor)
    private var heightConstraint: NSLayoutConstraint!
    private(set) var entries: [PaletteEntry] = []
    private var rows: [PaletteEntry?] = []
    private(set) var mode: Mode = .root
    private var marked = Set<String>()
    /// Builds the entries for a mode and query.
    var provider: ((Mode, String) -> [PaletteEntry])?
    /// Applies the picked entries of a multi-pick list (tags, collections) at once.
    var applyMarked: ((Mode, [String]) -> Void)?
    var didClose: (() -> Void)?
    var query: String { field.stringValue }
    var selectedEntry: PaletteEntry? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame:.zero)
        card.material = .popover; card.blendingMode = .withinWindow; card.state = .active
        card.wantsLayer = true; card.layer?.cornerRadius = 16; card.layer?.masksToBounds = true; card.layer?.borderWidth = 0.5
        card.translatesAutoresizingMaskIntoConstraints = false; addSubview(card)
        icon.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)
        icon.symbolConfiguration = .init(pointSize:15,weight:.medium); icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize:17); field.delegate = self; field.lineBreakMode = .byTruncatingTail
        table.addTableColumn(NSTableColumn(identifier:.init("entry"))); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear; table.style = .plain
        table.intercellSpacing = NSSize(width:0,height:0); table.selectionHighlightStyle = .regular; table.floatsGroupRows = false
        table.target = self; table.action = #selector(clicked); table.refusesFirstResponder = true
        scroller.documentView = table; scroller.drawsBackground = false; scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true
        let divider = NSBox(); divider.boxType = .separator
        for view in [icon,field,divider,scroller,footer] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(view) }
        heightConstraint = scroller.heightAnchor.constraint(equalToConstant:0)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo:centerXAnchor),card.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:36),
            card.widthAnchor.constraint(equalToConstant:600),card.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-40),
            icon.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:18),icon.centerYAnchor.constraint(equalTo:field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),field.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-18),
            field.topAnchor.constraint(equalTo:card.topAnchor,constant:16),
            divider.leadingAnchor.constraint(equalTo:card.leadingAnchor),divider.trailingAnchor.constraint(equalTo:card.trailingAnchor),
            divider.topAnchor.constraint(equalTo:field.bottomAnchor,constant:14),
            scroller.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:6),scroller.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-6),
            scroller.topAnchor.constraint(equalTo:divider.bottomAnchor,constant:6),heightConstraint,
            footer.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:18),footer.topAnchor.constraint(equalTo:scroller.bottomAnchor,constant:6),
            footer.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-10)])
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            shadow = { let s = NSShadow(); s.shadowBlurRadius = 30; s.shadowOffset = NSSize(width:0,height:-10); s.shadowColor = NSColor.black.withAlphaComponent(0.25); return s }()
        }
    }
    /// Clicks outside the card close the palette.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow,from:nil)) { close() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (super.hitTest(point) ?? self) }

    func open(_ mode: Mode, query: String = "") {
        self.mode = mode; marked = []
        field.stringValue = query
        field.placeholderString = switch mode {
        case .root: "Search, go to or run a command"
        case .tags: "Add tags"
        case .collections(let move): move ? "Move to collection" : "Add to collection"
        case .goTo: "Go to"
        }
        icon.image = NSImage(systemSymbolName:mode == .tags ? "tag" : mode == .goTo ? "arrow.right.circle" : mode == .root ? "magnifyingglass" : "rectangle.stack",accessibilityDescription:nil)
        isHidden = false; refresh()
        window?.makeFirstResponder(field)
    }
    func close() {
        guard !isHidden else { return }
        isHidden = true; didClose?()
    }
    func refresh() {
        entries = provider?(mode,field.stringValue) ?? []
        for index in entries.indices { entries[index].marked = marked.contains(entries[index].id) }
        rows = []
        var section: String?
        for entry in entries {
            if entry.section != section, !entry.section.isEmpty { rows.append(nil) }
            section = entry.section; rows.append(entry)
        }
        table.reloadData()
        heightConstraint.constant = min(420,rows.reduce(0) { $0 + ($1 == nil ? 26 : 32) } + (rows.isEmpty ? 0 : 4))
        if let first = rows.firstIndex(where:{ $0 != nil }) { table.selectRowIndexes(IndexSet(integer:first),byExtendingSelection:false); table.scrollRowToVisible(0) }
        let multi = mode == .tags || mode == .collections(move:false)
        footer.stringValue = rows.isEmpty ? "No matches" : multi ? (marked.isEmpty ? "↩  Add      ⇥  Pick several      esc  Close" : "↩  Add \(marked.count) picked      ⇥  Pick more      esc  Close")
            : "↩  Run      ↑↓  Navigate      esc  Close"
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.insertTab(_:)): toggleMark(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if mode != .root && !field.stringValue.isEmpty && marked.isEmpty { field.stringValue = ""; refresh() } else { close() }
            return true
        default: return false
        }
    }
    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var row = table.selectedRow
        repeat { row += delta } while row >= 0 && row < rows.count && rows[row] == nil
        guard row >= 0, row < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row)
    }
    private func toggleMark() {
        guard mode == .tags || mode == .collections(move:false), let entry = selectedEntry else { NSSound.beep(); return }
        if marked.contains(entry.id) { marked.remove(entry.id) } else { marked.insert(entry.id) }
        let row = table.selectedRow
        refresh()
        if row < rows.count { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        move(1)
    }
    func runSelected() {
        if !marked.isEmpty { let picked = Array(marked); close(); applyMarked?(mode,picked); return }
        guard let entry = selectedEntry else { NSSound.beep(); return }
        close(); entry.run()
    }
    @objc private func clicked() {
        guard table.clickedRow >= 0, table.clickedRow < rows.count, rows[table.clickedRow] != nil else { return }
        table.selectRowIndexes(IndexSet(integer:table.clickedRow),byExtendingSelection:false); runSelected()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row] == nil ? 26 : 32 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row] == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row] != nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = rows[row] else {
            let next = rows[(row+1)...].first { $0 != nil } ?? nil
            return SidebarHeader(title:next?.section ?? "")
        }
        return PaletteCell(entry)
    }
}

final class PaletteTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:1),xRadius:8,yRadius:8).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class PaletteCell: NSTableCellView {
    init(_ entry: PaletteEntry) {
        super.init(frame:.zero)
        let icon = NSImageView(image:NSImage(systemSymbolName:entry.symbol,accessibilityDescription:nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize:13,weight:.regular); icon.contentTintColor = entry.tint ?? .secondaryLabelColor
        let title = label(entry.title,size:13.5,color:.labelColor)
        let detail = label(entry.detail,size:12,color:.tertiaryLabelColor)
        // Shortcuts draw as keycaps, so a bare "T" reads as a key.
        let hintText = label(entry.hint,size:11,weight:.medium,color:.secondaryLabelColor); hintText.alignment = .center
        let hint = Surface(.clear,radius:5,stroke:.separatorColor); hint.isHidden = entry.marked || entry.hint.isEmpty
        hintText.translatesAutoresizingMaskIntoConstraints = false; hint.addSubview(hintText)
        NSLayoutConstraint.activate([hintText.leadingAnchor.constraint(equalTo:hint.leadingAnchor,constant:6),hintText.trailingAnchor.constraint(equalTo:hint.trailingAnchor,constant:-6),
                                     hintText.centerYAnchor.constraint(equalTo:hint.centerYAnchor),hint.heightAnchor.constraint(equalToConstant:18),
                                     hint.widthAnchor.constraint(greaterThanOrEqualToConstant:18)])
        let check = NSImageView(image:NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:"Picked")!)
        check.contentTintColor = .controlAccentColor; check.isHidden = !entry.marked
        for view in [icon,title,detail,hint,check] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        title.setContentCompressionResistancePriority(.defaultHigh,for:.horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),icon.centerYAnchor.constraint(equalTo:centerYAnchor),icon.widthAnchor.constraint(equalToConstant:20),
            title.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),title.centerYAnchor.constraint(equalTo:centerYAnchor),
            detail.leadingAnchor.constraint(equalTo:title.trailingAnchor,constant:8),detail.centerYAnchor.constraint(equalTo:centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo:detail.trailingAnchor,constant:8),hint.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),
            hint.centerYAnchor.constraint(equalTo:centerYAnchor),
            check.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),check.centerYAnchor.constraint(equalTo:centerYAnchor)])
        setAccessibilityLabel(entry.detail.isEmpty ? entry.title : "\(entry.title), \(entry.detail)")
    }
    required init?(coder: NSCoder) { fatalError() }
}
