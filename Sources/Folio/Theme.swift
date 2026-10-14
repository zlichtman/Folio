import AppKit

// Identity can change without moving the user's existing library or capture credentials.
enum AppIdentity {
    static let name = "Folio"
    static let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.3.0"
}
/// The library window's colours, from the chosen theme family's palette. Glass themes make the canvas a
/// translucent tint over the blurred desktop (see `AppController.applyGlass`).
enum Theme {
    nonisolated(unsafe) static var family = ThemeFamily.noir
    static func adaptive(_ light: UInt32, _ dark: UInt32, _ derive: @escaping (_ background: UInt32, _ surface: UInt32, _ ink: UInt32, _ accent: UInt32) -> NSColor? = { _,_,_,_ in nil }) -> NSColor {
        NSColor(name:nil) { appearance in
            let isDark = appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            let p = family.palette(isDark ? .dark : .light)
            if let bg = rgb(p.background), let surface = rgb(p.surface), let ink = rgb(p.foreground), let accent = rgb(p.accent),
               let color = derive(bg,surface,ink,accent) { return color }
            let n = isDark ? dark : light
            return NSColor(calibratedRed:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)
        }
    }
    /// The window behind the grid; in a Glass theme only as much of it as the theme's tint.
    /// Noir's near-black makes photos glare in a library; its dark canvas is the Mac's own dark grey.
    static let canvas = adaptive(0xF4F4F2,0x0B0B0C) { bg,_,_,_ in
        color(canvasRGB(bg)).withAlphaComponent(family.glassTint.map { CGFloat($0) } ?? 1)
    }
    static func canvasRGB(_ background: UInt32) -> UInt32 { family == .noir && background == 0x0B0B0C ? 0x1C1C1E : background }
    static let sidebar = adaptive(0xFFFFFF,0x18181A) { _,surface,_,_ in color(surface) }
    /// Clear for Noir and Glass, so the sidebar keeps the system material; a solid surface for other themes.
    static let sidebarTint = NSColor(name:nil) { appearance in
        if family == .noir { return .clear }
        if let tint = family.glassTint { return canvas.resolved(appearance).withAlphaComponent(CGFloat(tint) * 0.6) }
        return sidebar.resolved(appearance)
    }
    static let border = adaptive(0xE8E8EC,0x33343A) { bg,_,ink,_ in color(mix(bg,ink,0.14)) }
    static let accent = adaptive(0x6E6E6E,0xE8E8E8) { _,_,_,accent in color(accent) }
    /// Cards and placeholders: a step off the canvas they sit on, so they read in every theme.
    static let chip = adaptive(0xF0F1F5,0x303139) { bg,_,ink,_ in color(mix(canvasRGB(bg),ink,0.07)) }
    /// The label under a colour swatch: paper white in light, the card surface in dark so it doesn't glare.
    static let swatchLabel = NSColor(name:nil) { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? chip.resolved(appearance) : .white
    }
    static let ink = adaptive(0x111111,0xF2F2F2) { _,_,ink,_ in color(ink) }
    static let muted = adaptive(0x858691,0x9698A4) { bg,_,ink,_ in color(mix(ink,bg,0.42)) }
    /// The ring, band and drop line around selected items: Settings ▸ Appearance ▸ Selection.
    static let selection = NSColor(name:nil) { selection(UserDefaults.standard.string(forKey:"selectionColor"),appearance:$0) }
    static func selection(_ choice: String?, appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        switch choice {
        case "graphite": return dark ? NSColor(white:0.62,alpha:1) : NSColor(white:0.42,alpha:1)
        case "lightGrey": return dark ? NSColor(white:0.86,alpha:1) : NSColor(white:0.74,alpha:1)
        case "ink": return ink.resolved(appearance)
        default: return .controlAccentColor
        }
    }
    static let selectionChanged = Notification.Name("org.lumashelf.selection-color")

    static func rgb(_ hex: String) -> UInt32? {
        let cleaned = hex.trimmingCharacters(in:CharacterSet.alphanumerics.inverted)
        return cleaned.count == 6 ? UInt32(cleaned,radix:16) : nil
    }
    static func color(_ n: UInt32) -> NSColor {
        NSColor(srgbRed:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)
    }
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a>>shift)&255), y = Double((b>>shift)&255)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
    /// Redraws every window after a theme change; layer-backed views re-resolve their colours.
    @MainActor static func redraw() {
        func visit(_ view: NSView) {
            view.needsDisplay = true
            if view is ShelfGridView { view.viewDidChangeEffectiveAppearance() }
            view.subviews.forEach(visit)
        }
        for window in NSApp.windows { (window.contentView?.superview ?? window.contentView).map(visit) }
    }
}
extension NSColor {
    func resolved(_ appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance { color = self.usingColorSpace(.sRGB) ?? self }
        return color
    }
}
final class Surface: NSView {
    var fill: NSColor
    var radius: CGFloat
    /// An optional hairline around the shape.
    var stroke: NSColor?
    init(_ color: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) { fill=color; self.radius=radius; self.stroke=stroke; super.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        fill.setFill(); NSBezierPath(roundedRect:bounds,xRadius:radius,yRadius:radius).fill()
        if let stroke { stroke.setStroke(); let path = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius); path.lineWidth = 1; path.stroke() }
    }
}
func label(_ text:String, size:CGFloat=12, weight:NSFont.Weight = .regular, color:NSColor = Theme.ink) -> NSTextField {
    let field=NSTextField(labelWithString:text); field.font = .systemFont(ofSize:size,weight:weight); field.textColor=color
    field.lineBreakMode = .byTruncatingTail; return field
}
/// Section headings, in title case like the Mac's own sidebars and inspectors.
/// Less movement: the Mac's Reduce Motion, or Settings ▸ Appearance ▸ Motion in Folio alone. Panels appear without
/// sliding, pictures don't lift or spring; fades stay, as they don't move anything.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey:"reduceMotion") }
}
func sectionLabel(_ text:String) -> NSTextField { label(text,size:11,weight:.semibold,color:.secondaryLabelColor) }
/// A section title with the single key that jumps to it beside it, faint, so the keys are learnt by looking.
/// `key` names a `SingleKeys` action; the letter follows it when it's changed in Settings.
func sectionLabel(_ text: String, key: String, action: String) -> NSView {
    let faint = NSColor(name:nil) { $0.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? NSColor(white:1,alpha:0.32) : NSColor(white:0,alpha:0.3) }
    let cap = label("",size:10,weight:.medium,color:faint)
    let row = NSStackView(views:[sectionLabel(text),cap]); row.orientation = .horizontal; row.spacing = 5; row.alignment = .firstBaseline
    func show() { let letter = SingleKeys.key(key).uppercased(); cap.stringValue = letter; row.toolTip = "Press \(letter) to \(action)" }
    show()
    NotificationCenter.default.addObserver(forName:SingleKeys.changed,object:nil,queue:.main) { _ in MainActor.assumeIsolated { show() } }
    return row
}
/// Automatic tags are stored as slugs ("sunset-sunrise"); people read them as words.
func tagTitle(_ tag: String, automatic: Bool) -> String { automatic ? tag.replacingOccurrences(of:"-",with:" ").replacingOccurrences(of:"_",with:" ") : tag }
final class PreviewImageView: NSView {
    var image:CGImage? { didSet { needsDisplay=true } }
    /// Several selected items: up to three pictures fanned like prints, instead of one.
    var stack: [CGImage] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect:NSRect) {
        if !stack.isEmpty { drawStack(); return }
        Theme.chip.setFill(); NSBezierPath(roundedRect:bounds,xRadius:9,yRadius:9).fill()
        guard let image,let context=NSGraphicsContext.current?.cgContext else { return }
        let ratio=min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height))
        let size=CGSize(width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio)
        context.saveGState(); NSBezierPath(roundedRect:bounds,xRadius:9,yRadius:9).addClip()
        context.draw(image,in:CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)); context.restoreGState()
    }
    private func drawStack() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width,bounds.height) * 0.72
        let angles: [CGFloat] = stack.count == 1 ? [0] : stack.count == 2 ? [-4,3] : [-6,5,0]
        for (index,image) in stack.prefix(3).enumerated() {
            let ratio = min(side/CGFloat(image.width),side/CGFloat(image.height))
            let size = CGSize(width:CGFloat(image.width)*ratio,height:CGFloat(image.height)*ratio)
            context.saveGState()
            context.translateBy(x:bounds.midX + CGFloat(index - 1) * 6,y:bounds.midY)
            context.rotate(by:angles[index] * .pi / 180)
            let rect = CGRect(x:-size.width/2,y:-size.height/2,width:size.width,height:size.height)
            context.setShadow(offset:CGSize(width:0,height:-2),blur:8,color:NSColor.black.withAlphaComponent(0.25).cgColor)
            NSColor.white.setFill(); NSBezierPath(roundedRect:rect.insetBy(dx:-3,dy:-3),xRadius:8,yRadius:8).fill()
            context.setShadow(offset:.zero,blur:0,color:nil)
            NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6).addClip(); context.draw(image,in:rect)
            context.restoreGState()
        }
    }
}
