import AppKit
import QuartzCore
import AVFoundation
import ImageIO
import Quartz
import ShelfCore

extension NSPasteboard.PasteboardType {
    /// Item ids dragged inside Folio, for dropping onto collections.
    static let folioItems = Self("org.lumashelf.items")
    /// A collection dragged in the sidebar.
    static let folioCollection = Self("org.lumashelf.collection")
    /// A watched folder ("folder:<id>") or tag ("tag:<name>") row being dragged into a new order.
    static let folioSidebarRow = Self("org.lumashelf.sidebar-row")
}

private final class Tile {
    let root = CALayer()
    let image = CALayer()
    let ring = CALayer()
    let badge = CALayer()
    let caption = CATextLayer()
    let scale: CGFloat
    static let still: [String:CAAction] = ["position":NSNull(),"bounds":NSNull(),"sublayers":NSNull(),"contents":NSNull(),"hidden":NSNull(),"borderColor":NSNull(),"opacity":NSNull()]
    /// Shown on hover when filenames are off: a soft shade with the name. Made the first time a tile is hovered.
    lazy var hoverLayers: (shade: CAGradientLayer, title: CATextLayer) = {
        let shade = CAGradientLayer(), title = CATextLayer()
        for layer in [shade,title] as [CALayer] { layer.actions = Self.still; layer.isHidden = true; image.addSublayer(layer) }
        shade.colors = [NSColor.black.withAlphaComponent(0).cgColor,NSColor.black.withAlphaComponent(0.55).cgColor]
        title.fontSize = 11; title.font = NSFont.systemFont(ofSize:11,weight:.medium); title.foregroundColor = NSColor.white.cgColor
        title.truncationMode = .end; title.contentsScale = scale
        return (shade,title)
    }()
    /// Link cards (a title and the site, or a chip over a preview picture) and colour chips. Made only for those items,
    /// so a scroll through photos never pays for them.
    lazy var cardLayers: (title: CATextLayer, site: CATextLayer, chip: CALayer, chipText: CATextLayer, paint: CALayer, paintText: CATextLayer) = {
        let title = CATextLayer(), site = CATextLayer(), chip = CALayer(), chipText = CATextLayer(), paint = CALayer(), paintText = CATextLayer()
        for layer in [title,site,chip,chipText,paint,paintText] as [CALayer] { layer.actions = Self.still; layer.isHidden = true }
        for text in [title,site,chipText,paintText] { text.contentsScale = scale; text.truncationMode = .end }
        title.isWrapped = true; title.fontSize = 13; title.font = NSFont.systemFont(ofSize:13,weight:.semibold)
        site.fontSize = 11; chipText.fontSize = 11; chipText.font = NSFont.systemFont(ofSize:11,weight:.medium); chipText.foregroundColor = NSColor.white.cgColor
        chip.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor; chip.cornerRadius = 10
        paint.backgroundColor = NSColor.white.cgColor
        paintText.fontSize = 11; paintText.font = NSFont.monospacedSystemFont(ofSize:11,weight:.medium); paintText.foregroundColor = NSColor(white:0.15,alpha:1).cgColor
        for layer in [title,site,chip,paint] { image.addSublayer(layer) }
        chip.addSublayer(chipText); paint.addSublayer(paintText)
        hasCard = true
        return (title,site,chip,chipText,paint,paintText)
    }()
    private var hasCard = false
    var itemID = ""
    var bucket = 0
    var hovered = false
    /// What the card layers were last laid out for, so scrolling doesn't redo them every frame.
    var cardKey = ""
    fileprivate var laidOutRow = CGRect.null
    private var laidOut = CGRect.null, laidOutCaptions = false, captionText = "", badgeSymbol: String?
    /// In the list view: a small thumbnail at the start of a full-width row, the name and a quieter line after it.
    private var listMode = false, detailText = ""
    lazy var detail: CATextLayer = {
        let layer = CATextLayer(); layer.actions = Self.still; layer.fontSize = 11; layer.truncationMode = .end; layer.contentsScale = scale
        root.addSublayer(layer); return layer
    }()
    static func describe(_ item: ShelfItem) -> String {
        var parts = [item.kind == "link" ? (item.site.isEmpty ? "Link" : item.site) : item.kind == "color" ? (item.colors.first ?? "").uppercased()
                     : item.ext.isEmpty ? item.kind.capitalized : item.ext.uppercased()]
        if item.kind == "image", item.width > 0 { parts.append("\(Int(item.width)) × \(Int(item.height))") }
        if item.kind == "video", item.duration > 0 { parts.append(Duration.seconds(item.duration).formatted(.time(pattern:.minuteSecond))) }
        if item.fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount:item.fileSize,countStyle:.file)) }
        parts.append(Date(timeIntervalSince1970:item.added).formatted(date:.abbreviated,time:.omitted))
        return parts.joined(separator:"  ·  ")
    }
    /// A card that covers the tile (a link without a picture, or a colour) already names it.
    var showsCard: Bool { hasCard && (!cardLayers.title.isHidden || !cardLayers.paint.isHidden) }
    init(scale: CGFloat, appearance: NSAppearance) {
        self.scale = scale
        for layer in [root,image,ring,badge,caption] { layer.actions = Self.still }
        root.shadowColor = NSColor.black.cgColor; root.shadowOffset = CGSize(width:0,height:4); root.shadowRadius = 12; root.shadowOpacity = 0
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true; image.cornerRadius = ShelfGridView.corner
        ring.borderWidth = 2; ring.cornerRadius = ShelfGridView.corner + 3; ring.isHidden = true
        badge.contentsGravity = .center; badge.isHidden = true
        caption.contentsScale = scale; caption.fontSize = 11; caption.truncationMode = .end
        colour(appearance)
        root.addSublayer(image); root.addSublayer(ring); root.addSublayer(badge); root.addSublayer(caption)
    }
    /// A gentle lift with a shadow, and the name over the picture when filenames are hidden.
    func setHover(_ on: Bool, title: String, captions: Bool, animated: Bool) {
        hovered = on
        if listMode { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        if !animated { CATransaction.setDisableActions(true) }
        // Reduce Motion keeps the shadow but not the lift.
        root.transform = on && !Motion.reduced ? CATransform3DMakeScale(1.015,1.015,1) : CATransform3DIdentity
        root.shadowOpacity = on ? 0.18 : 0
        root.shadowPath = CGPath(roundedRect:image.frame,cornerWidth:image.cornerRadius,cornerHeight:image.cornerRadius,transform:nil)
        CATransaction.commit()
        let showName = on && !captions && image.frame.height >= 70 && !showsCard
        guard showName || on == false else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A link's site chip steps aside for its title.
        if hasCard { cardLayers.chip.opacity = showName ? 0 : 1 }
        let (shade,label) = hoverLayers
        shade.isHidden = !showName; label.isHidden = !showName
        if showName {
            shade.frame = CGRect(x:0,y:image.frame.height - 44,width:image.frame.width,height:44)
            // The name starts after the corner badge (liked, video) rather than under it.
            let inset: CGFloat = badge.isHidden ? 10 : 36
            label.frame = CGRect(x:inset,y:image.frame.height - 24,width:image.frame.width - inset - 10,height:16)
            label.string = title
        }
        CATransaction.commit()
    }
    /// The selection ring follows the window: accent while it's in front, grey behind other windows.
    var emphasized = true
    func colour(_ appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            image.backgroundColor = Theme.chip.cgColor
            ring.borderColor = (emphasized ? Theme.selection : NSColor.secondaryLabelColor.withAlphaComponent(0.55)).cgColor
            caption.foregroundColor = NSColor.secondaryLabelColor.cgColor
            if !listMode { detail.foregroundColor = NSColor.tertiaryLabelColor.cgColor }
            if hasCard { cardLayers.title.foregroundColor = Theme.ink.cgColor; cardLayers.site.foregroundColor = Theme.muted.cgColor }
        }
    }
    /// Lays out the link or colour card for an item; hides the card layers for everything else.
    func card(_ item: ShelfItem, appearance: NSAppearance) {
        let isColor = item.kind == "color", isLink = item.kind == "link"
        guard isColor || isLink || hasCard else { return }
        let bounds = image.bounds, preview = isLink && item.path.hasPrefix("/")
        let (cardTitle,cardSite,chip,chipText,paintLabel,paintText) = cardLayers
        appearance.performAsCurrentDrawingAppearance {
            cardTitle.foregroundColor = Theme.ink.cgColor; cardSite.foregroundColor = Theme.muted.cgColor
            paintLabel.backgroundColor = Theme.swatchLabel.cgColor; paintText.foregroundColor = Theme.ink.cgColor
        }
        cardTitle.isHidden = !(isLink && !preview); cardSite.isHidden = cardTitle.isHidden
        // Settings ▸ General ▸ Links: the label over a link's picture names its site, its title, or nothing.
        let label = UserDefaults.standard.string(forKey:"linkChip") ?? "site"
        chip.isHidden = !preview || label == "none"; chipText.isHidden = chip.isHidden
        paintLabel.isHidden = !isColor; paintText.isHidden = !isColor
        if isColor, let hex = item.colors.first, let value = Theme.rgb(hex) {
            image.backgroundColor = Theme.color(value).cgColor
            let label = max(22,bounds.height * 0.22)
            paintLabel.frame = CGRect(x:0,y:bounds.height - label,width:bounds.width,height:label)
            paintText.frame = CGRect(x:10,y:(label - 15)/2,width:bounds.width - 20,height:15); paintText.string = hex.uppercased()
        } else {
            appearance.performAsCurrentDrawingAppearance { image.backgroundColor = Theme.chip.cgColor }
        }
        if isLink && !preview {
            cardTitle.frame = CGRect(x:12,y:12,width:bounds.width - 24,height:max(16,bounds.height - 44))
            cardTitle.string = item.title
            cardSite.frame = CGRect(x:12,y:bounds.height - 26,width:bounds.width - 24,height:15)
            cardSite.string = "↗ " + (item.site.isEmpty ? item.url : item.site)
        }
        if preview {
            // The picture usually shows the page's title already; the chip says where it's from.
            let host = URL(string:item.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            let text = label == "title" && !item.title.isEmpty ? item.title : "↗ " + (item.site.isEmpty ? host ?? item.url : item.site)
            let width = min(bounds.width * 0.8,(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium)]).width + 18)
            chip.frame = CGRect(x:8,y:bounds.height - 28,width:max(40,width),height:20)
            chipText.frame = CGRect(x:9,y:3,width:chip.frame.width - 18,height:14); chipText.string = text
        }
    }
    func configure(item: ShelfItem, frame: CGRect, selected: Bool, scale: CGFloat, captions: Bool, badges: [String:CGImage], list: Bool = false) {
        if list != listMode {
            listMode = list; laidOut = .null; laidOutRow = .null; captionText = ""; cardKey = "-"
            caption.fontSize = list ? 13 : 11
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { caption.foregroundColor = (list ? Theme.ink : NSColor.secondaryLabelColor).cgColor }
            detail.isHidden = !list; detail.alignmentMode = list ? .left : .right; detailText = "-"
        }
        if list { configureRow(item:item,frame:frame,selected:selected,scale:scale,badges:badges); return }
        if item.id != itemID {
            itemID = item.id; image.contents = nil; bucket = 0; image.removeAnimation(forKey:"gif")
            image.sublayers?.filter { $0 is AVPlayerLayer }.forEach { ($0 as? AVPlayerLayer)?.player?.pause(); $0.removeFromSuperlayer() }
            if hovered { setHover(false,title:"",captions:captions,animated:false) }
        }
        // Scrolling refreshes every frame; only touch what changed, since each layer write costs a commit.
        let moved = frame != laidOut || captions != laidOutCaptions
        if moved {
            laidOut = frame; laidOutCaptions = captions
            root.frame = frame
            image.frame = CGRect(x:0,y:0,width:frame.width,height:frame.height-(captions ? 24 : 0))
            ring.frame = image.frame.insetBy(dx:-3,dy:-3)
            caption.isHidden = !captions
            caption.frame = CGRect(x:2,y:image.frame.height + 5,width:frame.width - 4,height:17)
        }
        if ring.isHidden == selected { ring.isHidden = !selected }
        if caption.contentsScale != scale { caption.contentsScale = scale }
        if captions, captionText != item.title { captionText = item.title; caption.string = item.title }
        // Pictures and videos name their pixel size beside the filename, where the tile is wide enough for both.
        let size = captions && frame.width >= 150 && item.width > 0 && ["image","video","gif"].contains(item.kind) ? "\(Int(item.width)) × \(Int(item.height))" : ""
        if size != detailText || moved {
            detailText = size; detail.isHidden = size.isEmpty
            let width = size.isEmpty ? 0 : ceil((size as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width) + 2
            if !size.isEmpty {
                detail.string = size; detail.contentsScale = scale
                detail.frame = CGRect(x:frame.width - 2 - width,y:image.frame.height + 5,width:width,height:17)
                NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { detail.foregroundColor = NSColor.tertiaryLabelColor.cgColor }
            }
            caption.frame.size.width = frame.width - 4 - (width > 0 ? width + 8 : 0)
        }
        let key = item.kind == "link" || item.kind == "color" ? "\(item.id)|\(item.path)|\(item.title)|\(Int(frame.width))x\(Int(frame.height))" : ""
        if key != cardKey { cardKey = key; card(item,appearance:NSApp.effectiveAppearance) }
        let symbol = item.liked ? "liked" : item.kind == "video" ? "video" : item.missing ? "missing" : nil
        if symbol != badgeSymbol || moved {
            badgeSymbol = symbol; badge.isHidden = symbol == nil
            if let symbol, let glyph = badges[symbol] {
                badge.contents = glyph; badge.contentsScale = scale
                badge.frame = CGRect(x:image.frame.minX + 6,y:image.frame.maxY - 30,width:24,height:24)
            }
        }
    }
}

extension Tile {
    /// One row of the list: thumbnail, name, and kind or site, size and date.
    fileprivate func configureRow(item: ShelfItem, frame: CGRect, selected: Bool, scale: CGFloat, badges: [String:CGImage]) {
        if item.id != itemID {
            itemID = item.id; image.contents = nil; bucket = 0; image.removeAnimation(forKey:"gif")
            image.sublayers?.filter { $0 is AVPlayerLayer }.forEach { ($0 as? AVPlayerLayer)?.player?.pause(); $0.removeFromSuperlayer() }
        }
        let h = frame.height
        if frame != laidOutRow {
            laidOutRow = frame
            root.frame = frame
            image.frame = CGRect(x:4,y:4,width:h - 8,height:h - 8)
            ring.frame = CGRect(x:0,y:0,width:frame.width,height:h).insetBy(dx:-1,dy:-1)
            caption.isHidden = false
            caption.frame = CGRect(x:h + 8,y:h / 2 - 18,width:frame.width - h - 20,height:18)
            detail.frame = CGRect(x:h + 8,y:h / 2 + 2,width:frame.width - h - 20,height:15)
        }
        // A link still waiting for its preview shows a link mark rather than an empty square.
        let waiting = item.kind == "link" && !item.path.hasPrefix("/")
        badge.isHidden = !waiting
        if waiting, let glyph = badges["link"] {
            badge.contents = glyph; badge.contentsScale = scale
            badge.frame = CGRect(x:image.frame.midX - 12,y:image.frame.midY - 12,width:24,height:24)
        }
        if ring.isHidden == selected { ring.isHidden = !selected }
        for text in [caption,detail] where text.contentsScale != scale { text.contentsScale = scale }
        if captionText != item.title { captionText = item.title; caption.string = item.title }
        let line = Self.describe(item)
        if detailText != line {
            detailText = line; detail.string = line
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { detail.foregroundColor = Theme.muted.cgColor }
        }
        // Card overlays don't fit a row: a color shows as its swatch, a link as its preview or a plain chip.
        if hasCard { for layer in [cardLayers.title,cardLayers.site,cardLayers.chip,cardLayers.paint] { layer.isHidden = true } }
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.backgroundColor = item.kind == "color" ? item.colors.first.flatMap(Theme.rgb).map { Theme.color($0).cgColor } ?? Theme.chip.cgColor : Theme.chip.cgColor
        }
    }
}

/// O(visible rows) work: item count does not affect the per-scroll layout loop.
final class ShelfGridView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [ShelfItem] = [] { didSet { indexByID = Dictionary(items.enumerated().map { ($1.id,$0) },uniquingKeysWith:{ a,_ in a }) } }
    var tileSize: Double = UserDefaults.standard.object(forKey:"tileSize") as? Double ?? 220
    var style = GridStyle(rawValue:UserDefaults.standard.string(forKey:"gridStyle") ?? "") ?? .rows
    var showsCaptions = UserDefaults.standard.bool(forKey:"showsCaptions")
    /// Selected item ids. `focusID` is the item arrow keys move from and the inspector shows when one is selected.
    private(set) var selection = Set<String>()
    private(set) var focusID: String?
    private var anchor: Int?
    var selectedID: String? {
        get { focusID }
        set { selection = newValue.map { [$0] } ?? []; focusID = newValue; anchor = newValue.flatMap { indexByID[$0] } }
    }
    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }
    var didChangeSelection: (([ShelfItem]) -> Void)?
    var openItem: ((ShelfItem) -> Void)?
    var importFiles: (([URL]) -> Void)?
    var importImage: ((Data, String) -> Void)?
    /// Web addresses pasted or dropped on the grid.
    var importLinks: (([URL]) -> Void)?
    /// Colours pasted or dropped on the grid, as `#rrggbb`.
    var importColors: (([String]) -> Void)?
    var toggleLike: ((ShelfItem) -> Void)?
    var removeItems: (([ShelfItem]) -> Void)?
    var menuForItems: (([ShelfItem]) -> NSMenu?)?
    /// Letter keys without modifiers (T, C, M, N, I, L); returns whether the key was used.
    var shortcut: ((String) -> Bool)?
    /// Esc with nothing selected, to leave search or results.
    var escape: (() -> Void)?
    var emptyMenu: (() -> NSMenu?)?
    private var indexByID: [String:Int] = [:]
    private var active: [Int:Tile] = [:]
    private var recycled: [Tile] = []
    private var observer: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var accentObserver: NSObjectProtocol?, selectionObserver: NSObjectProtocol?, shapeObserver: NSObjectProtocol?
    /// Settings ▸ Appearance ▸ Grid: how far apart pictures sit and how round their corners are.
    static var spacing: Double { [ "tight":0.4, "airy":2.0 ][UserDefaults.standard.string(forKey:"gridSpacing") ?? ""] ?? 1 }
    static var corner: CGFloat { [ "square":0, "round":14 ][UserDefaults.standard.string(forKey:"gridCorners") ?? ""] ?? 6 }
    static let shapeChanged = Notification.Name("org.lumashelf.grid-shape")
    private let thumbnails: ThumbnailCache
    private var badges: [String:CGImage] = [:]
    private let band = CAShapeLayer()
    private let insertionLine = CALayer()
    /// Whether the items shown can be put in your own order (a collection, unsearched and unfiltered).
    var canReorder: (() -> Bool)?
    /// Moves items to just before an item, or to the end when nil.
    var reorder: (([String], String?) -> Void)?
    private var bandStart: CGPoint?
    private var bandBase = Set<String>()
    private var pressed: (index: Int, point: CGPoint)?
    private(set) var hoveredIndex: Int?
    func isAnimating(_ index: Int) -> Bool { active[index]?.image.animation(forKey:"gif") != nil }
    private var scrubber: (id: String, generator: AVAssetImageGenerator)?
    private var scrubbing = false, scrubPending: Double?
    /// A video playing in its tile while the pointer rests on it.
    private var hoverVideo: (id: String, player: AVQueuePlayer, looper: AVPlayerLooper, layer: AVPlayerLayer, ready: NSKeyValueObservation)?
    /// Keeps the thin line along a playing video's bottom edge up to date.
    private var hoverProgress: Any?
    /// The video playing under the pointer and a way to grab its frame on screen, for Save Frame.
    func hoverFrameSource() -> (video: ShelfItem, frame: (@escaping (CGImage?, Double) -> Void) -> Void)? {
        guard let playing = hoverVideo, let item = items.first(where:{ $0.id == playing.id }), let asset = playing.player.currentItem?.asset else { return nil }
        let player = playing.player
        return (item,{ done in
            let time = player.currentTime()
            let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            generator.generateCGImageAsynchronously(for:time) { image, _, _ in DispatchQueue.main.async { done(image,time.seconds) } }
        })
    }
    private func stopHoverVideo() {
        guard let video = hoverVideo else { return }
        if let hoverProgress { video.player.removeTimeObserver(hoverProgress) }
        video.player.pause(); video.layer.removeFromSuperlayer(); hoverVideo = nil; hoverProgress = nil
    }
    /// Settings ▸ General ▸ Videos: play on hover (the default) or scrub with the pointer, and whether to play sound.
    static var playsVideoOnHover: Bool { UserDefaults.standard.string(forKey:"videoHover") != "scrub" }
    static var videoHoverSound: Bool { UserDefaults.standard.bool(forKey:"videoHoverSound") }
    var playingVideo: (id: String, playing: Bool, muted: Bool)? { hoverVideo.map { ($0.id,$0.player.rate > 0,$0.player.isMuted) } }
    private let gifFrames = NSCache<NSString,GIFFrames>()
    /// Pinch or ⌘-scroll changed the thumbnail size.
    var zoomChanged: ((Double) -> Void)?
    private(set) var updateTimes: [Double] = []
    private(set) var peakLayers = 0
    private(set) var geometry = MasonryLayout(items:[],width:1,tileSize:220)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        super.init(frame:.zero)
        wantsLayer = true
        band.lineWidth = 1; band.isHidden = true; band.zPosition = 10; band.actions = ["path":NSNull(),"hidden":NSNull()]
        layer?.addSublayer(band)
        insertionLine.cornerRadius = 1.5; insertionLine.isHidden = true; insertionLine.zPosition = 11; layer?.addSublayer(insertionLine)
        registerForDraggedTypes([.fileURL,.URL,.png,.tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        setAccessibilityRole(.grid); setAccessibilityLabel("Library")
        accentObserver = NotificationCenter.default.addObserver(forName:NSColor.systemColorsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.viewDidChangeEffectiveAppearance() }
        selectionObserver = NotificationCenter.default.addObserver(forName:Theme.selectionChanged,object:nil,queue:.main) { [weak self] _ in self?.viewDidChangeEffectiveAppearance() }
        shapeObserver = NotificationCenter.default.addObserver(forName:Self.shapeChanged,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            for tile in self.active.values + self.recycled { tile.image.cornerRadius = Self.corner; tile.ring.cornerRadius = Self.corner + 3; tile.cardKey = "-" }
            self.relayout { }
        }
        renderBadges()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func renderBadges() {
        for (name,symbol,tint) in [("liked","heart.fill",NSColor.white),("video","play.fill",NSColor.white),("missing","exclamationmark.triangle.fill",NSColor.systemYellow),
                                   ("link","link",NSColor.white)] {
            let size = NSSize(width:24,height:24), image = NSImage(size:size, flipped:false) { rect in
                // The heart sits straight on the picture with a soft shadow; the others keep a disc to read on any image.
                if name == "liked" {
                    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width:0,height:-1); shadow.set()
                } else { NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(ovalIn:rect).fill() }
                let config = NSImage.SymbolConfiguration(pointSize:name == "liked" ? 13 : 10,weight:.semibold).applying(.init(paletteColors:[tint]))
                if let glyph = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(config) {
                    glyph.draw(in:NSRect(x:(rect.width-glyph.size.width)/2,y:(rect.height-glyph.size.height)/2,width:glyph.size.width,height:glyph.size.height))
                }
                return true
            }
            badges[name] = image.cgImage(forProposedRect:nil,context:nil,hints:[.ctm:NSAffineTransform(transform:AffineTransform(scale:2))])
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            band.fillColor = Theme.selection.withAlphaComponent(0.12).cgColor
            band.strokeColor = Theme.selection.withAlphaComponent(0.6).cgColor
        }
        for tile in active.values + recycled { tile.colour(effectiveAppearance); tile.cardKey = "-" }
        // Colour and link cards take their surfaces from the theme too.
        for (index,tile) in active where items.indices.contains(index) { tile.cardKey = "-"; tile.card(items[index],appearance:effectiveAppearance) }
    }
    deinit { for token in [observer,frameObserver,accentObserver,selectionObserver,shapeObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) } }
    private var keyObservers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver); keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in self?.updateEmphasis() })
        }
    }
    private func updateEmphasis() {
        let key = window?.isKeyWindow ?? false
        for tile in active.values + recycled { tile.emphasized = key; tile.colour(effectiveAppearance) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        for token in [observer,frameObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main) { [weak self] _ in self?.refresh() }
            // Sidebar/inspector collapse resizes the clip view without resizing the window.
            frameObserver = NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:clip,queue:.main) { [weak self] _ in
                guard let self, abs(self.frame.width - clip.frame.width) > 0.5 else { return }
                self.resizeDocument(); self.refresh()
            }
        }
    }
    func setItems(_ items: [ShelfItem], preservePosition: Bool = false) {
        let position = enclosingScrollView?.contentView.bounds.origin ?? .zero
        // A new list puts different items under the pointer; the next move works out the hover again.
        if let hoveredIndex, let tile = active[hoveredIndex] { tile.setHover(false,title:"",captions:showsCaptions,animated:false) }
        hoveredIndex = nil
        let before = selection, focus = focusID
        self.items = items
        for tile in active.values { tile.root.removeFromSuperlayer(); recycled.append(tile) }
        active.removeAll(keepingCapacity:true)
        if preservePosition {
            selection = before.filter { indexByID[$0] != nil }
            focusID = focus.flatMap { indexByID[$0] != nil ? $0 : nil } ?? selection.first
        } else { selection = []; focusID = nil }
        anchor = focusID.flatMap { indexByID[$0] }
        if selection != before { notifySelection() }
        resizeDocument()
        enclosingScrollView?.contentView.scroll(to:preservePosition ? position : .zero)
        refresh()
    }
    func resizeDocument() {
        let width = max(1,enclosingScrollView?.contentSize.width ?? bounds.width)
        geometry = MasonryLayout(items:items,width:width,tileSize:tileSize,captions:showsCaptions,style:style,spacing:Self.spacing)
        setFrameSize(CGSize(width:width,height:max(geometry.height,enclosingScrollView?.contentSize.height ?? 1)))
    }
    /// Keeps an item in place while the layout changes: the one under `anchor` (a point in the grid), or the
    /// first visible one. Tiles stay as they are and move to their new frames, so nothing flickers.
    func relayout(anchor: CGPoint? = nil, _ change: () -> Void) {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let index = anchor.flatMap { geometry.index(x:$0.x,y:$0.y) }
            ?? geometry.visibleRange(y:visible.minY,height:1).first { geometry.frame(index:$0).maxY > visible.minY } ?? 0
        let old = geometry.frame(index:index)
        let offset = (anchor?.y ?? old.minY + 20) - visible.minY, within = anchor.map { old.height > 0 ? ($0.y - old.minY) / old.height : 0 } ?? 0
        change(); resizeDocument()
        guard !items.isEmpty else { refresh(); return }
        let frame = geometry.frame(index:min(index,items.count-1))
        let newY = anchor == nil ? frame.minY - 20 : frame.minY + within * frame.height - offset
        enclosingScrollView?.contentView.scroll(to:CGPoint(x:0,y:max(0,min(newY,self.frame.height - (enclosingScrollView?.contentSize.height ?? 0)))))
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
        refresh()
    }
    func setZoom(_ size: Double, anchor: CGPoint? = nil) {
        relayout(anchor:anchor) { tileSize = min(420,max(120,size)) }; UserDefaults.standard.set(tileSize,forKey:"tileSize")
    }
    /// The size the fingers ask for during a pinch, which may run past the limits.
    private var pinchSize: Double?
    private var spring: Timer?
    /// Pinching past the smallest or largest size gives a little, with resistance, and springs back on letting go.
    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow,from:nil), low = 120.0, high = 420.0
        if event.phase == .began || pinchSize == nil { spring?.invalidate(); pinchSize = tileSize }
        pinchSize! *= 1 + event.magnification
        let wanted = pinchSize!
        func give(_ over: Double) -> Double { over / (1 + over / 36) }
        let shown = wanted < low ? low - give(low - wanted) : wanted > high ? high + give(wanted - high) : wanted
        relayout(anchor:anchor) { tileSize = shown }; zoomChanged?(min(high,max(low,shown)))
        guard event.phase == .ended || event.phase == .cancelled else { return }
        pinchSize = nil
        let target = min(high,max(low,tileSize))
        guard target != tileSize, !Motion.reduced else {
            if target != tileSize { relayout(anchor:anchor) { tileSize = target }; zoomChanged?(target) }
            UserDefaults.standard.set(target,forKey:"tileSize"); return
        }
        let start = tileSize, began = CACurrentMediaTime()
        spring = Timer.scheduledTimer(withTimeInterval:1.0 / 60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1,(CACurrentMediaTime() - began) / 0.22), eased = 1 - pow(1 - t,3)
                self.relayout(anchor:anchor) { self.tileSize = start + (target - start) * eased }
                if t >= 1 { timer.invalidate(); UserDefaults.standard.set(target,forKey:"tileSize") }
            }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.scrollingDeltaY != 0, ShelfGridView.commandScrollZooms else { super.scrollWheel(with:event); return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        setZoom(tileSize * (1 + step),anchor:convert(event.locationInWindow,from:nil)); zoomChanged?(tileSize)
    }
    /// Settings ▸ Appearance ▸ Grid: whether ⌘ and scrolling zoom (in the grid, on boards and in Infinity).
    var playingGIFs: Int { active.values.filter { $0.image.animation(forKey:"gif") != nil }.count }
    static var gifsAlwaysPlay: Bool { UserDefaults.standard.bool(forKey:"gifsAlwaysPlay") }
    static var commandScrollZooms: Bool { UserDefaults.standard.object(forKey:"commandScrollZooms") as? Bool ?? true }
    func setStyle(_ value: GridStyle) { relayout { style = value }; UserDefaults.standard.set(value.rawValue,forKey:"gridStyle") }
    func setCaptions(_ on: Bool) { relayout { showsCaptions = on }; UserDefaults.standard.set(on,forKey:"showsCaptions") }
    func refresh() {
        let start = CACurrentMediaTime()
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let g = geometry, wanted = g.visibleRange(y:visible.minY,height:visible.height,marginRows:1)
        let keep = g.visibleRange(y:visible.minY,height:visible.height,marginRows:3)
        thumbnails.retainRequests(for:Set(keep.map { items[$0].path }))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in Array(active.keys) where !keep.contains(index) {
            if let tile = active.removeValue(forKey:index) { tile.root.removeFromSuperlayer(); recycled.append(tile) }
        }
        let scale = window?.backingScaleFactor ?? 2
        for index in wanted {
            let item = items[index]
            let tile: Tile
            if let existing = active[index] { tile = existing }
            else {
                tile = recycled.popLast() ?? Tile(scale:scale,appearance:effectiveAppearance)
                active[index] = tile; layer?.insertSublayer(tile.root,below:band)
            }
            let frame = g.frame(index:index)
            tile.configure(item:item,frame:frame,selected:selection.contains(item.id),scale:scale,captions:showsCaptions,badges:badges,list:style == .list)
            let bucket = ThumbnailCache.bucket(Int((style == .list ? frame.height : max(frame.width,frame.height - (showsCaptions ? 24 : 0))) * scale))
            if item.path.hasPrefix("/"), tile.bucket != bucket {
                tile.bucket = bucket
                thumbnails.request(path:item.path,pixels:bucket,prefetch:!frame.intersects(visible)) { [weak self,weak tile] image in
                    guard let self, let tile, tile.itemID == item.id, tile.bucket == bucket,
                          self.active[index] === tile else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    tile.image.contents = image
                    CATransaction.commit()
                }
            }
            // Settings ▸ General ▸ Videos: GIFs on screen can keep playing, not just under the pointer.
            if item.ext == "gif", style != .list {
                let playing = tile.image.animation(forKey:"gif") != nil
                if Self.gifsAlwaysPlay, !playing, frame.intersects(visible) { playGIF(tile,item,always:true) }
                else if !Self.gifsAlwaysPlay, playing, !tile.hovered { tile.image.removeAnimation(forKey:"gif") }
            }
        }
        // Reposition retained layers too after a resize/zoom, without decoding extra images.
        for (index,tile) in active where !wanted.contains(index) {
            tile.configure(item:items[index],frame:g.frame(index:index),selected:selection.contains(items[index].id),scale:scale,captions:showsCaptions,badges:badges,list:style == .list)
        }
        CATransaction.commit()
        if let hoveredIndex, let tile = active[hoveredIndex], !tile.hovered { tile.setHover(true,title:items[hoveredIndex].title,captions:showsCaptions,animated:false) }
        if recycled.count > 120 { recycled.removeFirst(recycled.count - 120) }
        peakLayers = max(peakLayers,active.count)
        updateTimes.append(CACurrentMediaTime() - start)
        if updateTimes.count > 5000 { updateTimes.removeFirst(1000) }
    }
    /// Draws every visible thumbnail again, for example after a refresh.
    func reloadThumbnails() { for tile in active.values { tile.bucket = 0; tile.image.contents = nil }; refresh() }
    func resetMeasurements() { updateTimes.removeAll(keepingCapacity:true); peakLayers = active.count }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self))
    }
    override func mouseMoved(with event: NSEvent) { hover(at:convert(event.locationInWindow,from:nil)) }
    override func mouseExited(with event: NSEvent) { hover(at:nil) }
    /// Where an item's tile sits in the grid, if it's in this view.
    func frame(of id: String) -> CGRect? { items.firstIndex { $0.id == id }.map { geometry.frame(index:$0) } }
    /// Rests the pointer on an item as if it were there, for staged captures.
    func hoverItem(_ index: Int, at across: CGFloat = 0.5) {
        let frame = geometry.frame(index:index); hover(at:CGPoint(x:frame.minX + frame.width * across,y:frame.midY))
    }
    private func hover(at point: CGPoint?) {
        let index = point.flatMap { geometry.index(x:$0.x,y:$0.y) }
        if index != hoveredIndex {
            if let old = hoveredIndex, let tile = active[old] { endMotion(tile,old); tile.setHover(false,title:"",captions:showsCaptions,animated:true) }
            hoveredIndex = index
            if let index, let tile = active[index] {
                tile.setHover(true,title:items[index].title,captions:showsCaptions,animated:true)
                if items[index].ext == "gif", Self.playsVideoOnHover { playGIF(tile,items[index]) }
                if items[index].kind == "video", Self.playsVideoOnHover { playVideo(tile,items[index]) }
            }
        }
        if let index, let point, items[index].kind == "video" || items[index].ext == "gif", !Self.playsVideoOnHover, let tile = active[index] {
            let frame = geometry.frame(index:index), fraction = Double(max(0,min(1,(point.x - frame.minX) / max(1,frame.width))))
            if items[index].ext == "gif" { scrubGIF(tile,items[index],fraction:fraction) } else { scrub(tile,items[index],fraction:fraction) }
        }
    }
    /// Stops whatever the pointer started (a playing video, a GIF) when the grid leaves the screen, as for the viewer.
    func endHover() {
        if let old = hoveredIndex, let tile = active[old] { endMotion(tile,old); tile.setHover(false,title:"",captions:showsCaptions,animated:false) }
        hoveredIndex = nil
        stopHoverVideo()
    }
    private func endMotion(_ tile: Tile, _ index: Int) {
        if !Self.gifsAlwaysPlay { tile.image.removeAnimation(forKey:"gif") }
        if items.indices.contains(index), items[index].kind == "video" {
            stopHoverVideo()
            scrubber = nil; tile.bucket = 0; refresh()
        } else if items.indices.contains(index), items[index].ext == "gif", !Self.playsVideoOnHover {
            tile.bucket = 0; refresh()
        }
    }
    private var gifLoading = Set<String>()
    /// Shows the GIF frame at the pointer's position across its tile, as for videos.
    private func scrubGIF(_ tile: Tile, _ item: ShelfItem, fraction: Double) {
        let key = item.path as NSString
        guard let frames = gifFrames.object(forKey:key) else {
            guard gifLoading.insert(item.path).inserted else { return }
            let pixels = max(tile.bucket,256)
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let frames = GIFFrames(url:URL(fileURLWithPath:item.path),pixels:pixels)
                DispatchQueue.main.async {
                    self?.gifLoading.remove(item.path)
                    if let frames { self?.gifFrames.setObject(frames,forKey:key) }
                }
            }
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tile.image.contents = frames.images[min(frames.images.count - 1,Int(fraction * Double(frames.images.count)))]
        CATransaction.commit()
    }
    /// Plays a video in its tile, looping and muted unless sound is on, fading in once its first frame is ready.
    private func playVideo(_ tile: Tile, _ item: ShelfItem) {
        guard item.path.hasPrefix("/") else { return }
        let player = AVQueuePlayer(), looper = AVPlayerLooper(player:player,templateItem:AVPlayerItem(url:URL(fileURLWithPath:item.path)))
        player.isMuted = !Self.videoHoverSound
        let layer = AVPlayerLayer(player:player)
        layer.videoGravity = .resizeAspectFill; layer.frame = tile.image.bounds; layer.opacity = 0
        tile.image.addSublayer(layer)
        let ready = layer.observe(\.isReadyForDisplay,options:[.initial,.new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.duration = 0.15; layer.add(fade,forKey:"fade"); layer.opacity = 1 }
        }
        hoverVideo = (item.id,player,looper,layer,ready)
        // A thin line along the bottom shows how far through the video is.
        let track = CALayer(), line = CALayer()
        track.frame = CGRect(x:0,y:layer.bounds.height - 3,width:layer.bounds.width,height:3); track.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        line.frame = CGRect(x:0,y:0,width:0,height:3); line.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        for part in [track,line] { part.actions = Tile.still }
        track.addSublayer(line); layer.addSublayer(track)
        hoverProgress = player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) { [weak player] time in
            guard let length = player?.currentItem?.duration.seconds, length.isFinite, length > 0 else { return }
            line.frame.size.width = track.bounds.width * CGFloat(min(1,max(0,time.seconds / length)))
        }
        player.play()
    }
    /// Plays a GIF in its tile while the pointer rests on it.
    private func playGIF(_ tile: Tile, _ item: ShelfItem, always: Bool = false) {
        guard tile.image.animation(forKey:"gif") == nil else { return }
        let key = item.path as NSString, pixels = max(tile.bucket,256)
        func start(_ frames: GIFFrames) {
            guard tile.itemID == item.id, tile.hovered || always, frames.images.count > 1, tile.image.animation(forKey:"gif") == nil else { return }
            let animation = CAKeyframeAnimation(keyPath:"contents")
            animation.values = frames.images; animation.keyTimes = frames.keyTimes; animation.duration = frames.duration
            animation.calculationMode = .discrete; animation.repeatCount = .infinity
            tile.image.add(animation,forKey:"gif")
        }
        if let cached = gifFrames.object(forKey:key) { start(cached); return }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let frames = GIFFrames(url:URL(fileURLWithPath:item.path),pixels:pixels) else { return }
            DispatchQueue.main.async { self?.gifFrames.setObject(frames,forKey:key); start(frames) }
        }
    }
    /// Shows the frame of a video at the pointer's position across its tile.
    private func scrub(_ tile: Tile, _ item: ShelfItem, fraction: Double) {
        if scrubber?.id != item.id {
            let generator = AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:item.path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width:tile.bucket,height:tile.bucket)
            generator.requestedTimeToleranceBefore = CMTime(seconds:0.2,preferredTimescale:600)
            generator.requestedTimeToleranceAfter = CMTime(seconds:0.2,preferredTimescale:600)
            scrubber = (item.id,generator)
        }
        guard !scrubbing else { scrubPending = fraction; return }
        guard let generator = scrubber?.generator else { return }
        let length = item.duration > 0 ? item.duration : generator.asset.duration.seconds
        guard length.isFinite, length > 0 else { return }
        scrubbing = true
        generator.generateCGImageAsynchronously(for:CMTime(seconds:length * fraction,preferredTimescale:600)) { [weak self, weak tile] image, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scrubbing = false
                if let image, let tile, tile.itemID == item.id, tile.hovered {
                    CATransaction.begin(); CATransaction.setDisableActions(true); tile.image.contents = image; CATransaction.commit()
                }
                if let next = self.scrubPending, let tile, tile.hovered { self.scrubPending = nil; self.scrub(tile,item,fraction:next) }
            }
        }
    }

    // MARK: Selection

    private func notifySelection() {
        didChangeSelection?(selectedItems)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }
    func select(_ ids: Set<String>, focus: String?) {
        selection = ids; focusID = focus; anchor = focus.flatMap { indexByID[$0] }
        notifySelection(); refresh()
    }
    func reveal(_ index: Int) { scrollToVisible(geometry.frame(index:index).insetBy(dx:0,dy:-24)) }
    override func selectAll(_ sender: Any?) {
        guard !items.isEmpty else { return }
        selection = Set(items.map(\.id)); focusID = focusID ?? items.first?.id; notifySelection(); refresh()
    }
    @objc func deselectAll(_ sender: Any?) { select([],focus:nil) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil)
        let flags = event.modifierFlags
        guard let index = geometry.index(x:p.x,y:p.y) else {
            pressed = nil; bandStart = p
            bandBase = flags.contains(.command) || flags.contains(.shift) ? selection : []
            if bandBase.isEmpty, !selection.isEmpty { select([],focus:nil) }
            return
        }
        let id = items[index].id
        // Option-click likes or unlikes the item under the pointer, leaving the selection alone.
        if flags.contains(.option), !flags.contains(.command), !flags.contains(.shift), event.clickCount == 1 { toggleLike?(items[index]); return }
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id); focusID = selection.contains(focusID ?? "") ? focusID : selection.first }
            else { selection.insert(id); focusID = id }
            anchor = index; notifySelection(); refresh(); return
        }
        if flags.contains(.shift), let anchor {
            selection = Set(items[min(anchor,index)...max(anchor,index)].map(\.id)); focusID = id
            notifySelection(); refresh(); return
        }
        if event.clickCount == 2 { openItem?(items[index]); return }
        if !selection.contains(id) { select([id],focus:id) } else if focusID != id { focusID = id; anchor = index; notifySelection() }
        pressed = (index,p)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        if let bandStart {
            autoscroll(with:event)
            let rect = CGRect(x:min(bandStart.x,p.x),y:min(bandStart.y,p.y),width:abs(p.x-bandStart.x),height:abs(p.y-bandStart.y))
            band.path = CGPath(roundedRect:rect,cornerWidth:3,cornerHeight:3,transform:nil); band.isHidden = false
            let hit = Set(geometry.indices(in:rect).map { items[$0].id })
            let next = bandBase.symmetricDifference(hit)
            if next != selection { selection = next; focusID = geometry.indices(in:rect).last.map { items[$0].id } ?? focusID; refresh() }
            return
        }
        guard let pressed, hypot(p.x-pressed.point.x,p.y-pressed.point.y) > 4 else { return }
        self.pressed = nil
        beginDrag(event)
    }
    override func mouseUp(with event: NSEvent) {
        if bandStart != nil { bandStart = nil; band.isHidden = true; anchor = focusID.flatMap { indexByID[$0] }; notifySelection() }
        else if let pressed, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), selection.count > 1 {
            select([items[pressed.index].id],focus:items[pressed.index].id)
        }
        pressed = nil
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow,from:nil)
        guard let index = geometry.index(x:p.x,y:p.y) else { return emptyMenu?() }
        if !selection.contains(items[index].id) { select([items[index].id],focus:items[index].id) }
        return menuForItems?(selectedItems)
    }
    override func keyDown(with event: NSEvent) {
        guard !items.isEmpty else { super.keyDown(with:event); return }
        let current = focusID.flatMap { indexByID[$0] }
        switch event.keyCode {
        case 49: toggleQuickLook(); return
        case 36, 76: if let current { openItem?(items[current]) }; return
        case 53: if selection.isEmpty { escape?() } else { select([],focus:nil) }; return
        case 51, 117: if selection.isEmpty { NSSound.beep() } else { removeItems?(selectedItems) }; return
        default: break
        }
        let move: (Int,Int)
        switch event.keyCode {
        case 123: move = (-1,0)
        case 124: move = (1,0)
        case 125: move = (0,1)
        case 126: move = (0,-1)
        default:
            if event.modifierFlags.intersection([.command,.control,.option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
               key.count == 1, shortcut?(key) == true { return }
            interpretKeyEvents([event]); return
        }
        guard let from = current else { select([items[0].id],focus:items[0].id); reveal(0); return }
        guard let next = geometry.neighbor(of:from,dx:move.0,dy:move.1) else { NSSound.beep(); return }
        let id = items[next].id
        if event.modifierFlags.contains(.shift), let anchor {
            selection = Set(items[min(anchor,next)...max(anchor,next)].map(\.id)); focusID = id; notifySelection(); refresh()
        } else { select([id],focus:id) }
        reveal(next)
    }

    // MARK: Pasteboard

    @objc func copy(_ sender: Any?) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        pasteboard.writeObjects(chosen.compactMap(Self.writer))
    }
    @objc func paste(_ sender: Any?) { if !receive(NSPasteboard.general) { NSSound.beep() } }
    @objc func delete(_ sender: Any?) { if !selection.isEmpty { removeItems?(selectedItems) } }
    static func writer(_ item: ShelfItem) -> NSPasteboardWriting? {
        if item.kind == "link" { return URL(string:item.url.isEmpty ? item.source : item.url) as NSURL? }
        guard item.path.hasPrefix("/") else { return nil }
        let entry = NSPasteboardItem()
        entry.setString(URL(fileURLWithPath:item.path).absoluteString,forType:.fileURL)
        entry.setString(item.id,forType:.folioItems)
        return entry
    }
    /// Imports files, file promises (Photos, Messages) and raw image data from a pasteboard.
    @discardableResult func receive(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty {
            importFiles?(urls); return true
        }
        if let promises = pasteboard.readObjects(forClasses:[NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped-\(UUID().uuidString.prefix(8))",isDirectory:true)
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let group = DispatchGroup(), lock = NSLock(); var received: [URL] = []
            for promise in promises {
                group.enter()
                promise.receivePromisedFiles(atDestination:folder,options:[:],operationQueue:.main) { url, error in
                    if error == nil { lock.lock(); received.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue:.main) { [weak self] in if !received.isEmpty { self?.importFiles?(received) } }
            return true
        }
        for (type,ext) in [(NSPasteboard.PasteboardType.png,"png"),(.tiff,"tiff")] {
            if let data = pasteboard.data(forType:type) { importImage?(data,ext); return true }
        }
        let text = [pasteboard.string(forType:.URL),pasteboard.string(forType:.string)].compactMap { $0 }.joined(separator:"\n")
        let urls = LinkMetadata.urls(in:text)
        if !urls.isEmpty { importLinks?(urls); return true }
        // Colours: hex codes in text (a palette copied from a design tool), or a colour from a colour picker.
        var colors = ColorMath.colors(in:text)
        if colors.isEmpty, let color = (pasteboard.readObjects(forClasses:[NSColor.self]) as? [NSColor])?.first?.usingColorSpace(.sRGB) {
            colors = [String(format:"#%02x%02x%02x",Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255))]
        }
        if !colors.isEmpty { importColors?(colors); return true }
        return false
    }

    // MARK: Dragging

    private func beginDrag(_ event: NSEvent) {
        let chosen = selectedItems, point = convert(event.locationInWindow,from:nil)
        // A compact stack under the pointer, so the preview doesn't hide the places it can be dropped.
        let draggable = chosen.prefix(200).enumerated().compactMap { offset, item -> NSDraggingItem? in
            guard let writer = Self.writer(item), let index = indexByID[item.id] else { return nil }
            let drag = NSDraggingItem(pasteboardWriter:writer)
            let source = geometry.frame(index:index), side: CGFloat = 120
            let scale = min(1,side / max(source.width,source.height))
            let size = CGSize(width:source.width * scale,height:source.height * scale)
            let shift = CGFloat(min(offset,3)) * 4
            let frame = CGRect(x:point.x - size.width/2 + shift,y:point.y - size.height/2 + shift,width:size.width,height:size.height)
            let image = active[index]?.image.contents
            drag.setDraggingFrame(frame,contents:image.map { NSImage(cgImage:$0 as! CGImage,size:size) } ?? NSImage(size:size))
            return drag
        }
        guard !draggable.isEmpty else { return }
        let session = beginDraggingSession(with:draggable,event:event,source:self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = draggable.count > 1 ? .pile : .none
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy,.generic,.move]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    /// Files from elsewhere are added; the grid's own items reorder, inside a collection, with a line where they'll land.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as? ShelfGridView) === self else { return .copy }
        guard canReorder?() == true else { showInsertion(nil); return [] }
        showInsertion(insertion(at:convert(sender.draggingLocation,from:nil)))
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showInsertion(nil) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { showInsertion(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard (sender.draggingSource as? ShelfGridView) === self else { return receive(sender.draggingPasteboard) }
        showInsertion(nil)
        guard canReorder?() == true else { return false }
        let target = insertion(at:convert(sender.draggingLocation,from:nil))
        let moving = selectedItems.map(\.id)
        // Dropping in front of the selection's own first item, or just after it, leaves the order as it is.
        let before = target < items.count ? items[target].id : nil
        if let before, moving.contains(before) { return false }
        reorder?(moving,before)
        return true
    }
    /// The index an item dropped at `point` goes in front of (`items.count` for the end).
    func insertion(at point: CGPoint) -> Int {
        let probe = CGRect(x:0,y:point.y - 1,width:bounds.width,height:2)
        let row = geometry.indices(in:probe)
        guard let nearest = (row.isEmpty ? geometry.indices(in:probe.insetBy(dx:0,dy:-80)) : row)
            .min(by:{ abs(geometry.frame(index:$0).midX - point.x) < abs(geometry.frame(index:$1).midX - point.x) }) else { return items.count }
        return point.x > geometry.frame(index:nearest).midX ? nearest + 1 : nearest
    }
    private func showInsertion(_ index: Int?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guard let index, !items.isEmpty else { insertionLine.isHidden = true; CATransaction.commit(); return }
        let frame = index < items.count ? geometry.frame(index:index) : geometry.frame(index:items.count - 1)
        let x = index < items.count ? frame.minX - 6 : frame.maxX + 3
        insertionLine.frame = CGRect(x:x,y:frame.minY,width:3,height:frame.height - (showsCaptions ? 24 : 0))
        effectiveAppearance.performAsCurrentDrawingAppearance { insertionLine.backgroundColor = Theme.selection.cgColor }
        insertionLine.isHidden = false
        CATransaction.commit()
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) }
        else if !selection.isEmpty { panel.makeKeyAndOrderFront(nil) } else { NSSound.beep() }
    }
    private var previewURLs: [URL] { selectedItems.compactMap { $0.path.hasPrefix("/") ? URL(fileURLWithPath:$0.path) : URL(string:$0.url) } }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self; panel.delegate = self
        if let focusID, let index = selectedItems.firstIndex(where:{ $0.id == focusID }) { panel.currentPreviewItemIndex = index }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123,124,125,126].contains(event.keyCode), selection.count <= 1 else { return false }
        keyDown(with:event); panel.reloadData(); return true
    }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item as? URL, let index = items.firstIndex(where:{ $0.path == url.path }), let window else { return .zero }
        let frame = geometry.frame(index:index)
        guard frame.intersects(visibleRect) else { return .zero }
        return window.convertToScreen(convert(frame,to:nil))
    }

    var loadedVisibleCount: Int {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        let range = geometry.visibleRange(y:visible.minY,height:visible.height)
        return range.filter { geometry.frame(index:$0).intersects(visible) && (active[$0]?.image.contents != nil || !items[$0].path.hasPrefix("/")) }.count
    }
    var visibleCount: Int {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        return geometry.visibleRange(y:visible.minY,height:visible.height).filter { geometry.frame(index:$0).intersects(visible) }.count
    }
    func frameOnScreen(_ id: String) -> NSRect? {
        guard let index = indexByID[id], let window else { return nil }
        let frame = geometry.frame(index:index)
        return frame.intersects(visibleRect) ? window.convertToScreen(convert(frame,to:nil)) : nil
    }
}

/// The frames of a GIF, downsized for a grid tile, ready for a keyframe animation.
final class GIFFrames {
    let images: [CGImage]
    let keyTimes: [NSNumber]
    let duration: Double
    init?(url: URL, pixels: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }
        let count = min(CGImageSourceGetCount(source),120)
        guard count > 1 else { return nil }
        var images: [CGImage] = [], delays: [Double] = []
        let options = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source,index,options) else { continue }
            let gif = (CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any])?[kCGImagePropertyGIFDictionary] as? [CFString:Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            images.append(frame); delays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard images.count > 1 else { return nil }
        let total = delays.reduce(0,+)
        var elapsed = 0.0, times: [NSNumber] = []
        for delay in delays { times.append(NSNumber(value:elapsed / total)); elapsed += delay }
        self.images = images; keyTimes = times; duration = total
    }
}
