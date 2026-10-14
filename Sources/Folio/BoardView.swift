import AppKit
import QuartzCore
import ShelfCore

/// A collection laid out by hand: drag items anywhere, resize them by the corner, layer them, pinch to zoom.
final class BoardView: NSView {
    private final class Piece {
        let root = CALayer(), image = CALayer(), ring = CALayer(), handle = CALayer()
        var bucket = 0, itemID = ""
        init() {
            let still: [String:CAAction] = ["position":NSNull(),"bounds":NSNull(),"contents":NSNull(),"hidden":NSNull(),"zPosition":NSNull()]
            for layer in [root,image,ring,handle] { layer.actions = still }
            image.contentsGravity = .resizeAspectFill; image.masksToBounds = true; image.cornerRadius = ShelfGridView.corner
            ring.borderWidth = 2; ring.cornerRadius = 9; ring.isHidden = true
            handle.cornerRadius = 6; handle.borderWidth = 2; handle.isHidden = true
            root.shadowColor = NSColor.black.cgColor; root.shadowOpacity = 0.25; root.shadowRadius = 6; root.shadowOffset = CGSize(width:0,height:2)
            root.addSublayer(image); root.addSublayer(ring); root.addSublayer(handle)
        }
    }
    private enum Gesture { case move(origin: CGPoint, start: [String:BoardPlacement]), resize(id: String, origin: CGPoint, start: BoardPlacement), band(origin: CGPoint, base: Set<String>),
                           pan(origin: CGPoint, start: CGPoint) }
    /// Space held down: a drag pans the board instead of moving pictures, and a tap without a drag is Quick Look.
    private var spaceHeld = false, panned = false
    private(set) var items: [ShelfItem] = []
    private(set) var placements: [String:BoardPlacement] = [:]
    private(set) var selection = Set<String>()
    private var pieces: [String:Piece] = [:]
    /// Pieces scrolled out of view, kept to show the next items that come into it.
    private var spare: [Piece] = []
    private var gesture: Gesture?
    private var moved = false
    private let band = CAShapeLayer()
    private let thumbnails: ThumbnailCache
    var didChangeSelection: (([ShelfItem]) -> Void)?
    var openItem: ((ShelfItem) -> Void)?
    var removeItems: (([ShelfItem]) -> Void)?
    var quickLook: (() -> Void)?
    var shortcut: ((String) -> Bool)?
    var escape: (() -> Void)?
    var menuForItems: (([ShelfItem]) -> NSMenu?)?
    var emptyMenu: (() -> NSMenu?)?
    /// Placements changed by a drag, a resize or a nudge, to save with undo.
    var commit: (([String:BoardPlacement]) -> Void)?
    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        super.init(frame:.zero)
        wantsLayer = true
        band.lineWidth = 1; band.isHidden = true; band.zPosition = 1_000_000; band.actions = ["path":NSNull(),"hidden":NSNull()]
        layer?.addSublayer(band)
        NotificationCenter.default.addObserver(self,selector:#selector(selectionColorChanged),name:Theme.selectionChanged,object:nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func selectionColorChanged() { viewDidChangeEffectiveAppearance() }

    // MARK: Content

    func show(_ items: [ShelfItem], placements: [String:BoardPlacement], keepSelection: Bool) {
        self.items = items; self.placements = placements
        let ids = Set(items.map(\.id))
        for (id,piece) in pieces where !ids.contains(id) { piece.root.removeFromSuperlayer(); spare.append(piece); pieces[id] = nil }
        selection = keepSelection ? selection.intersection(ids) : []
        layoutPieces(); resizeDocument()
        didChangeSelection?(selectedItems)
    }
    func frame(of item: ShelfItem) -> CGRect {
        guard let p = placements[item.id] else { return .zero }
        return CGRect(x:p.x,y:p.y,width:p.width,height:p.width / BoardLayout.aspect(item))
    }
    /// Everything on the board, for zoom to fit.
    var contentBounds: CGRect { items.map(frame(of:)).reduce(CGRect.null) { $0.union($1) } }
    private func resizeDocument() {
        let content = contentBounds.isNull ? .zero : contentBounds
        let visible = enclosingScrollView?.contentSize ?? .zero
        // Room to drag past the edges.
        setFrameSize(CGSize(width:max(visible.width,content.maxX + 800),height:max(visible.height,content.maxY + 800)))
    }
    /// Lays out what is in view and a margin around it; a board of thousands only builds the pieces you can see.
    private func layoutPieces() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let magnification = enclosingScrollView?.magnification ?? 1
        let scale = (window?.backingScaleFactor ?? 2) * max(1,magnification)
        let margin = 400 / max(0.1,magnification), near = visibleRect.isEmpty ? bounds : visibleRect.insetBy(dx:-margin,dy:-margin)
        var shown = Set<String>()
        for item in items {
            let frame = frame(of:item)
            guard frame.intersects(near) || selection.contains(item.id) else { continue }
            shown.insert(item.id)
            let piece = pieces[item.id] ?? {
                let p = spare.popLast() ?? Piece()
                if p.itemID != item.id { p.itemID = item.id; p.image.contents = nil; p.bucket = 0 }
                pieces[item.id] = p; layer?.insertSublayer(p.root,below:band); return p
            }()
            piece.root.frame = frame; piece.root.zPosition = CGFloat(placements[item.id]?.z ?? 0)
            piece.image.frame = piece.root.bounds
            piece.image.cornerRadius = ShelfGridView.corner; piece.ring.cornerRadius = ShelfGridView.corner + 3
            piece.root.shadowPath = CGPath(roundedRect:piece.root.bounds,cornerWidth:ShelfGridView.corner,cornerHeight:ShelfGridView.corner,transform:nil)
            let selected = selection.contains(item.id)
            piece.ring.frame = piece.root.bounds.insetBy(dx:-3,dy:-3); piece.ring.isHidden = !selected
            piece.handle.frame = CGRect(x:frame.width - 9,y:frame.height - 9,width:12,height:12)
            piece.handle.isHidden = !(selected && selection.count == 1)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                piece.ring.borderColor = Theme.selection.cgColor
                piece.handle.backgroundColor = NSColor.white.cgColor; piece.handle.borderColor = Theme.selection.cgColor
                piece.image.backgroundColor = Theme.chip.cgColor
            }
            let bucket = ThumbnailCache.bucket(Int(max(frame.width,frame.height) * scale))
            if item.path.hasPrefix("/"), piece.bucket < bucket {
                piece.bucket = bucket
                thumbnails.request(path:item.path,pixels:bucket) { [weak piece] image in
                    guard let piece, let image, piece.itemID == item.id else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true); piece.image.contents = image; CATransaction.commit()
                }
            }
        }
        for (id,piece) in pieces where !shown.contains(id) { piece.root.removeFromSuperlayer(); spare.append(piece); pieces[id] = nil }
        if spare.count > 200 { spare.removeFirst(spare.count - 200) }
        CATransaction.commit()
    }
    func refreshForZoom() { layoutPieces() }
    var builtPieces: Int { pieces.count }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A quiet dot grid, so the board reads as a surface you can place things on.
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        let step: CGFloat = 24
        var y = (dirtyRect.minY / step).rounded(.down) * step
        while y <= dirtyRect.maxY {
            var x = (dirtyRect.minX / step).rounded(.down) * step
            while x <= dirtyRect.maxX { NSBezierPath(ovalIn:CGRect(x:x - 1,y:y - 1,width:2,height:2)).fill(); x += step }
            y += step
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            band.fillColor = Theme.selection.withAlphaComponent(0.12).cgColor
            band.strokeColor = Theme.selection.withAlphaComponent(0.6).cgColor
        }
        layoutPieces(); needsDisplay = true
    }

    // MARK: Selection

    private func item(at point: CGPoint) -> ShelfItem? {
        items.filter { frame(of:$0).contains(point) }.max { (placements[$0.id]?.z ?? 0) < (placements[$1.id]?.z ?? 0) }
    }
    func select(_ ids: Set<String>) { selection = ids; layoutPieces(); didChangeSelection?(selectedItems) }
    override func selectAll(_ sender: Any?) { select(Set(items.map(\.id))) }

    // MARK: Mouse

    private func beginPan(_ event: NSEvent) {
        gesture = .pan(origin:event.locationInWindow,start:enclosingScrollView?.contentView.bounds.origin ?? .zero); NSCursor.closedHand.set()
    }
    private func pan(_ event: NSEvent) {
        guard case .pan(let origin,let start) = gesture, let clip = enclosingScrollView?.contentView else { return }
        let scale = max(0.1,enclosingScrollView?.magnification ?? 1)
        clip.scroll(to:CGPoint(x:start.x - (event.locationInWindow.x - origin.x) / scale,y:start.y + (event.locationInWindow.y - origin.y) / scale))
        enclosingScrollView?.reflectScrolledClipView(clip); panned = true
    }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { beginPan(event) } else { super.otherMouseDown(with:event) } }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseUp(with event: NSEvent) { gesture = nil; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceHeld { beginPan(event); return }
        let point = convert(event.locationInWindow,from:nil), flags = event.modifierFlags
        moved = false
        if selection.count == 1, let id = selection.first, let item = items.first(where:{ $0.id == id }), let start = placements[id] {
            let f = frame(of:item)
            if CGRect(x:f.maxX - 14,y:f.maxY - 14,width:20,height:20).contains(point) { gesture = .resize(id:id,origin:point,start:start); return }
        }
        guard let hit = item(at:point) else {
            gesture = .band(origin:point,base:flags.contains(.command) || flags.contains(.shift) ? selection : [])
            if !(flags.contains(.command) || flags.contains(.shift)) { select([]) }
            return
        }
        if event.clickCount == 2 { openItem?(hit); return }
        if flags.contains(.command) || flags.contains(.shift) {
            if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
            select(selection)
        } else if !selection.contains(hit.id) { select([hit.id]) }
        // What's picked up comes to the front.
        let top = (placements.values.map(\.z).max() ?? 0) + 1
        var start: [String:BoardPlacement] = [:]
        for (offset,id) in selection.sorted(by:{ (placements[$0]?.z ?? 0) < (placements[$1]?.z ?? 0) }).enumerated() {
            guard var p = placements[id] else { continue }
            start[id] = p; p.z = top + Double(offset); placements[id] = p
        }
        gesture = .move(origin:point,start:start)
        layoutPieces()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if case .pan = gesture { pan(event); return }
        autoscroll(with:event)
        switch gesture {
        case .move(let origin,let start):
            moved = true
            for (id,p) in start { var next = placements[id] ?? p; next.x = max(0,p.x + point.x - origin.x); next.y = max(0,p.y + point.y - origin.y); placements[id] = next }
            layoutPieces()
        case .resize(let id,let origin,let start):
            moved = true
            var next = placements[id] ?? start; next.width = max(48,start.width + point.x - origin.x); placements[id] = next
            layoutPieces()
        case .band(let origin,let base):
            let rect = CGRect(x:min(origin.x,point.x),y:min(origin.y,point.y),width:abs(point.x - origin.x),height:abs(point.y - origin.y))
            band.path = CGPath(roundedRect:rect,cornerWidth:3,cornerHeight:3,transform:nil); band.isHidden = false
            selection = base.symmetricDifference(Set(items.filter { frame(of:$0).intersects(rect) }.map(\.id)))
            layoutPieces()
        case .pan, nil: break
        }
    }
    override func mouseUp(with event: NSEvent) {
        switch gesture {
        case .move(_,let start) where moved: finish(Array(start.keys))
        case .move(_,let start):
            // A click picks up nothing: keep the stacking change only if something moved.
            for (id,p) in start { placements[id]?.z = p.z }
            layoutPieces()
        case .resize(let id,_,_) where moved: finish([id])
        case .band: band.isHidden = true; didChangeSelection?(selectedItems)
        case .pan: (spaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
        default: break
        }
        gesture = nil; resizeDocument()
    }
    private func finish(_ ids: [String]) {
        commit?(Dictionary(uniqueKeysWithValues:ids.compactMap { id in placements[id].map { (id,$0) } }))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow,from:nil)
        guard let hit = item(at:point) else { return emptyMenu?() }
        if !selection.contains(hit.id) { select([hit.id]) }
        return menuForItems?(selectedItems)
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), ShelfGridView.commandScrollZooms, let scroll = enclosingScrollView else { super.scrollWheel(with:event); return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        scroll.setMagnification(min(scroll.maxMagnification,max(scroll.minMagnification,scroll.magnification * (1 + step))),centeredAt:convert(event.locationInWindow,from:nil))
        refreshForZoom()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 49:
            if !event.isARepeat { spaceHeld = true; panned = false; NSCursor.openHand.set() }
            return
        case 36, 76: if let first = selectedItems.first { openItem?(first) }; return
        case 53: if selection.isEmpty { escape?() } else { select([]) }; return
        case 51, 117: if !selection.isEmpty { removeItems?(selectedItems) }; return
        case 123, 124, 125, 126:
            guard !selection.isEmpty else { return }
            let step: Double = flags.contains(.shift) ? 10 : 1
            let (dx,dy): (Double,Double) = event.keyCode == 123 ? (-step,0) : event.keyCode == 124 ? (step,0) : event.keyCode == 125 ? (0,step) : (0,-step)
            for id in selection {
                guard var p = placements[id] else { continue }
                p.x = max(0,p.x + dx); p.y = max(0,p.y + dy); placements[id] = p
            }
            layoutPieces(); finish(Array(selection)); return
        default: break
        }
        if flags.intersection([.command,.control,.option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, shortcut?(key) == true { return }
        super.keyDown(with:event)
    }
    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { super.keyUp(with:event); return }
        spaceHeld = false; NSCursor.arrow.set()
        if !panned { quickLook?() }
    }
    /// Brings the selection to the front or sends it to the back.
    func restack(front: Bool) {
        let values = placements.values.map(\.z)
        let base = front ? (values.max() ?? 0) + 1 : (values.min() ?? 0) - Double(selection.count)
        var changed: [String:BoardPlacement] = [:]
        for (offset,id) in selection.sorted(by:{ (placements[$0]?.z ?? 0) < (placements[$1]?.z ?? 0) }).enumerated() {
            guard var p = placements[id] else { continue }
            p.z = base + Double(offset); placements[id] = p; changed[id] = p
        }
        layoutPieces(); if !changed.isEmpty { commit?(changed) }
    }
}
