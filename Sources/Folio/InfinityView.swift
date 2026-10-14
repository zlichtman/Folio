import AppKit
import QuartzCore
import ShelfCore

/// Infinity: the place's pictures as a wall that never ends. The items are laid out once in a block, and the block
/// repeats in every direction, so scrolling or dragging any way keeps finding pictures. Pinch or ⌘-scroll zooms around
/// the pointer, and a click opens what's under it. Only what's on screen is drawn.
final class InfinityView: NSView {
    private(set) var items: [ShelfItem] = []
    /// The wall's columns: each is an endless strip of its own items, repeating every `period` points, so no row is
    /// ever half empty. The set of columns repeats across every `blockWidth` points.
    private struct Column { var x: CGFloat; var period: CGFloat; var cells: [(index: Int, y: CGFloat, height: CGFloat)] }
    private var columns: [Column] = []
    private var blockWidth: CGFloat = 1
    private let cell: CGFloat = 220, gap: CGFloat = 12
    private var offset = CGPoint.zero
    private(set) var zoom: CGFloat = 1
    private var pieces: [String:CALayer] = [:]
    private var spare: [CALayer] = []
    private var dragged = false, dragStart = CGPoint.zero, offsetStart = CGPoint.zero
    private let thumbnails: ThumbnailCache
    var openItem: ((ShelfItem) -> Void)?
    var escape: (() -> Void)?
    var quickLook: ((ShelfItem) -> Void)?
    /// Single keys that make sense on the wall (Shuffle); the rest act on a selection, which Infinity doesn't have.
    var shortcut: ((String) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var drawnPieces: Int { pieces.count }

    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        super.init(frame:.zero)
        wantsLayer = true; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [ShelfItem]) {
        let changed = items.map(\.id) != self.items.map(\.id)
        self.items = items
        guard changed else { layoutPieces(); return }
        // Items go to the shortest column, as in Columns; there are about as many columns as items per column.
        let count = max(1,min(items.count,Int((Double(items.count).squareRoot() * 1.3).rounded())))
        columns = (0..<count).map { Column(x:CGFloat($0) * (cell + gap),period:0,cells:[]) }
        for (index,item) in items.enumerated() {
            let c = columns.indices.min { columns[$0].period < columns[$1].period } ?? 0
            let height = (cell / CGFloat(MasonryLayout.aspect(item))).clamped(cell * 0.55,cell * 1.65)
            columns[c].cells.append((index,columns[c].period,height)); columns[c].period += height + gap
        }
        blockWidth = CGFloat(count) * (cell + gap)
        for piece in pieces.values { piece.removeFromSuperlayer(); spare.append(piece) }
        pieces = [:]
        layoutPieces()
    }
    override func layout() { super.layout(); layoutPieces() }

    /// Every column, in every copy across, starts at its own height, so neither rows nor repeats line up,
    /// even when the pictures are all one shape.
    private func stagger(_ copy: Int, _ c: Int, _ column: Column) -> CGFloat { CGFloat(copy * columns.count + c) * column.period * 0.382 }
    /// Every placed picture in a rectangle of the wall: which item, which copy (for a stable key) and where.
    private func placed(in view: CGRect) -> [(key: String, index: Int, frame: CGRect)] {
        var out: [(String,Int,CGRect)] = []
        for bx in Int(floor(view.minX / blockWidth))...Int(floor(view.maxX / blockWidth)) {
            for (c,column) in columns.enumerated() where column.period > 0 {
                let x = CGFloat(bx) * blockWidth + column.x
                guard x + cell >= view.minX, x <= view.maxX else { continue }
                let shift = stagger(bx,c,column)
                for r in Int(floor((view.minY - shift) / column.period))...Int(floor((view.maxY - shift) / column.period)) {
                    let top = CGFloat(r) * column.period + shift
                    for cell in column.cells {
                        let frame = CGRect(x:x,y:top + cell.y,width:self.cell,height:cell.height)
                        if frame.intersects(view) { out.append(("\(cell.index)|\(bx)|\(c)|\(r)",cell.index,frame)) }
                    }
                }
            }
        }
        return out
    }
    private func item(at point: CGPoint) -> ShelfItem? {
        let plane = CGPoint(x:offset.x + point.x / zoom,y:offset.y + point.y / zoom)
        return placed(in:CGRect(origin:plane,size:CGSize(width:1,height:1))).first { $0.frame.contains(plane) }.map { items[$0.index] }
    }
    private func layoutPieces() {
        guard !items.isEmpty, !columns.isEmpty, bounds.width > 0 else { pieces.values.forEach { $0.removeFromSuperlayer() }; pieces = [:]; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let view = CGRect(x:offset.x,y:offset.y,width:bounds.width / zoom,height:bounds.height / zoom).insetBy(dx:-200,dy:-200)
        let scale = (window?.backingScaleFactor ?? 2) * zoom
        var shown = Set<String>()
        var chip = Theme.chip.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { chip = Theme.chip.cgColor }
        for (key,index,placed) in placed(in:view) {
            shown.insert(key)
            let piece = pieces[key] ?? {
                let p = spare.popLast() ?? Self.makePiece()
                p.contents = nil; p.name = nil
                pieces[key] = p; layer?.addSublayer(p); return p
            }()
            piece.frame = CGRect(x:(placed.minX - offset.x) * zoom,y:(placed.minY - offset.y) * zoom,width:placed.width * zoom,height:placed.height * zoom)
            piece.cornerRadius = ShelfGridView.corner * min(1,zoom)
            let item = items[index], bucket = ThumbnailCache.bucket(Int(max(placed.width,placed.height) * scale))
            let wanted = "\(item.id)@\(bucket)"
            if piece.name != wanted {
                piece.name = wanted; piece.contents = nil
                piece.backgroundColor = item.kind == "color" ? item.colors.first.flatMap(Theme.rgb).map { Theme.color($0).cgColor } ?? chip : chip
                if item.path.hasPrefix("/") {
                    thumbnails.request(path:item.path,pixels:bucket) { [weak piece] image in
                        guard let piece, piece.name == wanted, let image else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true); piece.contents = image; CATransaction.commit()
                    }
                }
            }
        }
        for (key,piece) in pieces where !shown.contains(key) { piece.removeFromSuperlayer(); spare.append(piece); pieces[key] = nil }
        if spare.count > 300 { spare.removeFirst(spare.count - 300) }
        CATransaction.commit()
    }
    private static func makePiece() -> CALayer {
        let p = CALayer(); p.contentsGravity = .resizeAspectFill; p.masksToBounds = true
        p.actions = ["position":NSNull(),"bounds":NSNull(),"contents":NSNull(),"cornerRadius":NSNull()]
        return p
    }
    /// Zooms around a point on screen, keeping what's under it in place.
    func zoom(by factor: CGFloat, at point: CGPoint) {
        let next = min(2.5,max(0.12,zoom * factor))
        let plane = CGPoint(x:offset.x + point.x / zoom,y:offset.y + point.y / zoom)
        zoom = next; offset = CGPoint(x:plane.x - point.x / zoom,y:plane.y - point.y / zoom)
        layoutPieces()
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), ShelfGridView.commandScrollZooms {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            zoom(by:1 + step,at:convert(event.locationInWindow,from:nil)); return
        }
        // Trackpads carry their own momentum in these events, so a flick keeps gliding.
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        offset.x -= event.scrollingDeltaX * k / zoom; offset.y -= event.scrollingDeltaY * k / zoom
        layoutPieces()
    }
    override func magnify(with event: NSEvent) { zoom(by:1 + event.magnification,at:convert(event.locationInWindow,from:nil)) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragged = false; dragStart = event.locationInWindow; offsetStart = offset
    }
    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStart.x, dy = event.locationInWindow.y - dragStart.y
        if !dragged, hypot(dx,dy) < 4 { return }
        if !dragged { NSCursor.closedHand.push() }
        dragged = true
        offset = CGPoint(x:offsetStart.x - dx / zoom,y:offsetStart.y + dy / zoom)
        layoutPieces()
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { NSCursor.pop(); dragged = false; return }
        // A click opens; letting go after panning doesn't.
        if let item = item(at:convert(event.locationInWindow,from:nil)) { openItem?(item) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: escape?()
        case 49:
            if let point = window?.mouseLocationOutsideOfEventStream, let item = item(at:convert(point,from:nil)) { quickLook?(item) }
        case 123, 124, 125, 126:
            let step: CGFloat = 120 / zoom
            offset.x += event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            offset.y += event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            layoutPieces()
        case 24 where event.modifierFlags.contains(.command): zoom(by:1.25,at:CGPoint(x:bounds.midX,y:bounds.midY))
        case 27 where event.modifierFlags.contains(.command): zoom(by:0.8,at:CGPoint(x:bounds.midX,y:bounds.midY))
        default:
            if event.modifierFlags.intersection([.command,.control,.option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
               key.count == 1, shortcut?(key) == true { return }
            super.keyDown(with:event)
        }
    }
}

private extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(high,Swift.max(low,self)) }
}
