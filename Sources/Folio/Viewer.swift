import AppKit
import AVKit
import ShelfCore

/// Full-size viewing inside the library window. Arrow keys page through the current list; Esc returns to the grid.
/// Images zoom: Fit, Fill or 100% (Z or the label at the top right), pinch, ⌘+ / ⌘−, and a double-click toggles Fit and 100%.
final class ViewerView: NSView {
    let zoom = ZoomImageView()
    private let player = AVPlayerView()
    private let mode = NSButton()
    private let previous = NSButton(), next = NSButton()
    private var previousBar: NSView?, nextBar: NSView?
    /// The item shown and its place in the list, for the window's title bar.
    var heading: (title: String, position: String)? { current.map { ($0.title,"\(index + 1) of \(items.count)") } }
    private var token = 0
    private(set) var items: [ShelfItem] = []
    private(set) var index = 0
    var thumbnails: ThumbnailCache?
    var didClose: ((ShelfItem?) -> Void)?
    var didShow: ((ShelfItem) -> Void)?
    var shortcut: ((String) -> Bool)?
    var current: ShelfItem? { items.indices.contains(index) ? items[index] : nil }
    var zoomTitle: String { mode.title }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init() {
        super.init(frame:.zero)
        wantsLayer = true
        player.controlsStyle = .floating; player.isHidden = true
        mode.bezelStyle = .accessoryBarAction; mode.font = .systemFont(ofSize:12,weight:.medium); mode.contentTintColor = Theme.ink
        mode.target = self; mode.action = #selector(cycleZoom); mode.toolTip = "Fit, Fill or 100% · Z"; mode.title = "Fit"
        zoom.didChangeMode = { [weak self] name in self?.mode.title = name }
        for (button,symbol,action) in [(previous,"chevron.left",#selector(showPrevious)),(next,"chevron.right",#selector(showNext))] {
            button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:symbol == "chevron.left" ? "Previous" : "Next")
            button.symbolConfiguration = .init(pointSize:13,weight:.semibold)
            button.bezelStyle = .accessoryBarAction; button.isBordered = false; button.contentTintColor = .labelColor
            button.target = self; button.action = action
        }
        // The item's name, its place in the list and Back live in the window's title bar; here only the picture,
        // round glass arrows and the zoom label.
        let before = FloatingBar([previous],inset:0), after = FloatingBar([next],inset:0), zoomBar = FloatingBar([mode],inset:2)
        for bar in [before,after] { bar.layer?.cornerRadius = 16 }
        previousBar = before; nextBar = after
        for view in [zoom,player,zoomBar,before,after] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            zoomBar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),zoomBar.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-14),
            zoom.leadingAnchor.constraint(equalTo:leadingAnchor),zoom.trailingAnchor.constraint(equalTo:trailingAnchor),
            zoom.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor),zoom.bottomAnchor.constraint(equalTo:bottomAnchor),
            player.leadingAnchor.constraint(equalTo:leadingAnchor,constant:40),player.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-40),
            player.topAnchor.constraint(equalTo:safeAreaLayoutGuide.topAnchor,constant:16),player.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-28),
            before.leadingAnchor.constraint(equalTo:leadingAnchor,constant:16),before.centerYAnchor.constraint(equalTo:zoom.centerYAnchor),
            after.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),after.centerYAnchor.constraint(equalTo:zoom.centerYAnchor),
            before.widthAnchor.constraint(equalToConstant:32),after.widthAnchor.constraint(equalToConstant:32),
            previous.widthAnchor.constraint(equalToConstant:22),next.widthAnchor.constraint(equalToConstant:22)])
    }
    required init?(coder: NSCoder) { fatalError() }
    // The library pane behind already draws the canvas (and Glass), and the grid is hidden while viewing.
    override var isOpaque: Bool { false }
    func show(_ items: [ShelfItem], at index: Int) {
        self.items = items; self.index = index; isHidden = false; present()
        window?.makeFirstResponder(self)
    }
    private func present() {
        guard let item = current else { closeViewer(); return }
        token += 1; let ticket = token
        previousBar?.isHidden = index == 0; nextBar?.isHidden = index >= items.count - 1
        player.player?.pause()
        if item.kind == "video", item.path.hasPrefix("/") {
            zoom.isHidden = true; mode.superview?.isHidden = true; player.isHidden = false
            player.player = AVPlayer(url:URL(fileURLWithPath:item.path))
        } else {
            zoom.isHidden = false; mode.superview?.isHidden = false; player.isHidden = true; player.player = nil
            let size = CGSize(width:max(1,item.width),height:max(1,item.height)), url = URL(fileURLWithPath:item.path)
            zoom.show(nil,pixelSize:size)
            if item.kind == "color", let value = item.colors.first.flatMap(Theme.rgb) {
                // A colour fills the view as a swatch, its code along the bottom as on its card.
                zoom.show(Self.swatch(value,hex:item.colors[0].uppercased()),pixelSize:CGSize(width:1200,height:900),full:true)
            } else if item.ext == "gif" {
                // GIFs play: NSImage keeps every frame and the image view animates them.
                if let animated = NSImage(contentsOf:url) { zoom.showAnimated(animated,pixelSize:size) }
            } else {
                // The grid's preview first, then the whole picture for zooming in.
                thumbnails?.request(path:item.path,pixels:1024) { [weak self] preview in
                    guard let self, self.token == ticket, !self.zoom.hasFullImage, let preview else { return }
                    self.zoom.show(preview,pixelSize:size)
                }
                DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                    // Vector files are drawn at three times their size, so zooming in stays sharp.
                    let scale: CGFloat = ["pdf","ai","svg"].contains(item.ext) ? 3 : 1
                    let full = MediaFiles.thumbnail(url:url,pixels:Int(min(8192,max(size.width,size.height) * scale)))
                    DispatchQueue.main.async { if let self, self.token == ticket, let full { self.zoom.show(full,pixelSize:size,full:true) } }
                }
            }
        }
        didShow?(item)
    }
    static func swatch(_ value: UInt32, hex: String) -> CGImage? {
        guard let context = CGContext(data:nil,width:1200,height:900,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(Theme.color(value).cgColor); context.fill(CGRect(x:0,y:0,width:1200,height:900))
        context.setFillColor(.white); context.fill(CGRect(x:0,y:0,width:1200,height:170))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        NSAttributedString(string:hex,attributes:[.font:NSFont.monospacedSystemFont(ofSize:52,weight:.medium),.foregroundColor:NSColor(white:0.15,alpha:1)])
            .draw(at:NSPoint(x:56,y:56))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
    /// The video frame on screen at full size, for Save Frame; nil unless a video is showing.
    func currentFrame(_ done: @escaping (CGImage?, Double) -> Void) {
        guard let item = current, item.kind == "video", let player = player.player, let asset = player.currentItem?.asset else { done(nil,0); return }
        let time = player.currentTime()
        let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.generateCGImageAsynchronously(for:time) { image, _, _ in DispatchQueue.main.async { done(image,time.seconds) } }
    }
    var showsVideo: Bool { !isHidden && current?.kind == "video" }
    func replace(_ items: [ShelfItem]) {
        guard let id = current?.id else { return }
        self.items = items
        if let found = items.firstIndex(where:{ $0.id == id }) { index = found } else { index = min(index,items.count - 1) }
        items.isEmpty ? closeViewer() : present()
    }
    @objc func showPrevious() { guard index > 0 else { NSSound.beep(); return }; index -= 1; present() }
    @objc func showNext() { guard index < items.count - 1 else { NSSound.beep(); return }; index += 1; present() }
    @objc func cycleZoom() { zoom.cycle() }
    /// R: somewhere else in the list, chosen at random.
    @objc func showRandom() {
        guard items.count > 1 else { NSSound.beep(); return }
        var next = index
        while next == index { next = Int.random(in:items.indices) }
        index = next; present()
    }
    @objc func closeViewer() {
        player.player?.pause(); player.player = nil
        isHidden = true; token += 1
        didClose?(current)
    }
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command,.control,.option]).isEmpty
        switch event.keyCode {
        case 123, 126: showPrevious()
        case 124, 125: showNext()
        case 53, 36, 76: closeViewer()
        case 49: if current?.kind == "video", let player = player.player { player.rate == 0 ? player.play() : player.pause() } else { closeViewer() }
        // , and . step a paused video a frame at a time, as in most video apps.
        case 43 where plain && current?.kind == "video", 47 where plain && current?.kind == "video":
            guard let video = player.player else { break }
            video.pause(); video.currentItem?.step(byCount:event.keyCode == 43 ? -1 : 1)
        case 6 where plain: zoom.cycle()
        case 15 where plain: showRandom()
        case 24 where event.modifierFlags.contains(.command): zoom.step(1.25)
        case 27 where event.modifierFlags.contains(.command): zoom.step(0.8)
        default:
            if plain, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, shortcut?(key) == true { return }
            super.keyDown(with:event)
        }
    }
    override func cancelOperation(_ sender: Any?) { closeViewer() }
}

/// An image that zooms and pans. Fit shows it whole with a margin, Fill covers the view, 100% is one image pixel
/// to one screen pixel. Pinching or ⌘± in between reads as a percentage.
final class ZoomImageView: NSScrollView {
    enum Mode: CaseIterable { case fit, fill, actual }
    private let imageView = NSImageView()
    private(set) var hasFullImage = false
    private var pixelSize = CGSize(width:1,height:1)
    private(set) var mode: Mode = .fit
    /// Set once pinching or ⌘± leave the named modes; a resize then keeps the zoom.
    private var free = false
    var didChangeMode: ((String) -> Void)?
    init() {
        super.init(frame:.zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        scrollerStyle = .overlay; allowsMagnification = true; maxMagnification = 8
        contentView = CenteringClipView(); contentView.drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.animates = true
        imageView.wantsLayer = true; imageView.layer?.cornerRadius = 6; imageView.layer?.masksToBounds = true
        documentView = imageView
        NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveMagnifyNotification,object:self,queue:.main) { [weak self] _ in
            self?.free = true; self?.report()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The image's size in points at 100%: one image pixel per screen pixel.
    private var naturalSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width:max(1,pixelSize.width/scale),height:max(1,pixelSize.height/scale))
    }
    var magnificationValue: CGFloat { magnification }
    /// Shows a picture. The first one for an item fits it; a sharper copy that arrives later keeps the zoom.
    func show(_ image: CGImage?, pixelSize: CGSize, full: Bool = false) {
        let fresh = !full || imageView.image == nil
        self.pixelSize = pixelSize; hasFullImage = full
        imageView.image = image.map { NSImage(cgImage:$0,size:naturalSize) }
        imageView.frame = CGRect(origin:.zero,size:naturalSize)
        if fresh { free = false; set(.fit) } else { apply() }
    }
    func showAnimated(_ image: NSImage, pixelSize: CGSize) {
        self.pixelSize = pixelSize; hasFullImage = true
        image.size = naturalSize; imageView.image = image
        imageView.frame = CGRect(origin:.zero,size:naturalSize); free = false; set(.fit)
    }
    /// Whether an animated picture plays; off while the window is out of sight.
    var animates: Bool { get { imageView.animates } set { imageView.animates = newValue } }
    override func layout() { super.layout(); if !free { apply() } }
    private func scale(for mode: Mode) -> CGFloat {
        let size = naturalSize, room = CGSize(width:max(1,bounds.width - 80),height:max(1,bounds.height - 56))
        switch mode {
        case .fit: return min(1,min(room.width/size.width,room.height/size.height))
        case .fill: return max(bounds.width/size.width,bounds.height/size.height)
        case .actual: return 1
        }
    }
    func set(_ mode: Mode) { self.mode = mode; free = false; apply(); report() }
    func cycle() { set(free ? .fit : Mode.allCases[(Mode.allCases.firstIndex(of:mode)! + 1) % Mode.allCases.count]) }
    func step(_ factor: CGFloat) {
        free = true
        setMagnification(min(maxMagnification,max(minMagnification,magnification * factor)),centeredAt:CGPoint(x:contentView.bounds.midX,y:contentView.bounds.midY))
        report()
    }
    private func apply() {
        minMagnification = min(scale(for:.fit),0.25)
        guard !free else { return }
        setMagnification(scale(for:mode),centeredAt:CGPoint(x:imageView.frame.midX,y:imageView.frame.midY))
    }
    private func report() {
        let name = !free ? (mode == .fit ? "Fit" : mode == .fill ? "Fill" : "100%") : "\(Int((magnification * 100).rounded()))%"
        didChangeMode?(name)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { set(!free && mode == .fit ? .actual : .fit) } else { super.mouseDown(with:event) }
    }
}

/// Keeps a document smaller than the view in the middle instead of the corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
