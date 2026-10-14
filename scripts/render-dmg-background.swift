import AppKit
// Draws the installer window's background. MacSpaces, Tape and Folio share this design and ship
// identical copies of this file, so keep them in sync: an ink band with the app's mark and name over
// warm paper, where Finder shows the app and the Applications link. Finder draws icon labels dark on
// any picture background, so they always sit on the paper. Finder pins the picture to the window's
// top-left corner at its own size, so the art runs past the window: a larger window shows more of
// the design, never a blank edge. Matches dmg-layout.swift: a 720 × 500 window, icons at y = 296.
// Usage: swift render-dmg-background.swift folio|tape|macspaces output.tiff version minimum-macos "arm64 x86_64"
// Writes output.tiff (sRGB, 1x and 2x; Finder picks the display's) and output.png (2x) for review.
let args = CommandLine.arguments
guard args.count == 6, let app = App(rawValue:args[1]) else {
    FileHandle.standardError.write(Data("Usage: swift render-dmg-background.swift folio|tape|macspaces output.tiff version minimum-macos architectures\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath:args[2]), version = args[3]
let minimum = args[4].hasSuffix(".0") ? String(args[4].dropLast(2)) : args[4]
// The architectures lipo reports for the app's executable.
let platforms = [args[5].contains("arm64") ? "Apple silicon" : nil,args[5].contains("x86_64") ? "Intel" : nil].compactMap { $0 }

enum App: String {
    case folio, tape, macspaces
    var name: String { self == .macspaces ? "MacSpaces" : rawValue.capitalized }
    var line: String {
        switch self {
        case .folio: "Fast sorting for your images and files."
        case .tape: "Your windows side by side on one scrolling strip."
        case .macspaces: "Music, little tasks and files, right at your notch."
        }
    }
    // The mark on the 100-unit grid of its Design source, y down.
    var mark: NSBezierPath {
        let path = NSBezierPath()
        switch self {
        case .folio:
            for (x,y): (CGFloat,CGFloat) in [(0,0),(0,54),(54,54)] {
                path.appendRoundedRect(NSRect(x:x,y:y,width:46,height:46),xRadius:5,yRadius:5)
            }
            path.appendOval(in:NSRect(x:54,y:0,width:46,height:46))
        case .tape:
            path.windingRule = .evenOdd
            let strip: [NSPoint] = [(8,32),(92,32),(100,41),(92,50),(100,59),(92,68),(8,68),(0,59),(8,50),(0,41)].map { NSPoint(x:$0.0,y:$0.1) }
            path.move(to:strip[0]); strip.dropFirst().forEach { path.line(to:$0) }; path.close()
            for x: CGFloat in [36,57] { path.appendRect(NSRect(x:x,y:42,width:7,height:16)) }
        case .macspaces:
            // The notch moon of Scripts/generate-app-icon.swift: a disc with the notch cut from its top.
            let (left, right, floor, corner): (CGFloat,CGFloat,CGFloat,CGFloat) = (34,66,28,8)
            let rim = 50 - CGFloat(2500 - 16 * 16).squareRoot(), angle = atan2(rim - 50,left - 50) * 180 / .pi
            path.move(to:NSPoint(x:left,y:rim))
            path.appendArc(withCenter:NSPoint(x:50,y:50),radius:50,startAngle:angle,endAngle:180 - angle,clockwise:true)
            path.line(to:NSPoint(x:right,y:floor - corner))
            path.curve(to:NSPoint(x:right - corner,y:floor),controlPoint1:NSPoint(x:right,y:floor - corner * 0.45),
                controlPoint2:NSPoint(x:right - corner * 0.45,y:floor))
            path.line(to:NSPoint(x:left + corner,y:floor))
            path.curve(to:NSPoint(x:left,y:floor - corner),controlPoint1:NSPoint(x:left + corner * 0.45,y:floor),
                controlPoint2:NSPoint(x:left,y:floor - corner * 0.45))
            path.close()
        }
        return path
    }
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed:CGFloat(hex >> 16 & 255) / 255,green:CGFloat(hex >> 8 & 255) / 255,blue:CGFloat(hex & 255) / 255,alpha:1)
}
let ink = rgb(0x121212), inkMark = rgb(0x1d1d1d), onInk = rgb(0xf5f3ef), onInkQuiet = rgb(0x8f8b85)
// Quiet text keeps 4.5:1 contrast on its ground.
let paper = rgb(0xf3f0eb), dot = rgb(0xdcd6cc), onPaper = rgb(0x1a1918), onPaperQuiet = rgb(0x706a61)
let canvas = NSSize(width:2560,height:1600), width: CGFloat = 720, band: CGFloat = 176
let iconY: CGFloat = 296, appX: CGFloat = 200, applicationsX: CGFloat = 520, footer: CGFloat = 430

// Scales the mark to fit the box, left-aligned and centred in it, or at its top.
@discardableResult func mark(_ box: NSRect, top: Bool = false, _ fill: NSColor) -> NSRect {
    let path = app.mark, shape = path.bounds
    let scale = min(box.width / shape.width,box.height / shape.height)
    let drawn = NSRect(x:box.minX,y:top ? box.minY : box.midY - shape.height * scale / 2,width:shape.width * scale,height:shape.height * scale)
    var t = AffineTransform(translationByX:drawn.minX - shape.minX * scale,byY:drawn.minY - shape.minY * scale); t.scale(scale)
    path.transform(using:t)
    fill.setFill(); path.fill()
    return drawn
}
// Draws one line of text with its first baseline at y, from x (or ending at x, or centred on it).
func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, tracking: CGFloat = 0, anchor: CGFloat = 0) {
    let line = NSAttributedString(string:s,attributes:[.font:font,.foregroundColor:color,.kern:tracking])
    // Kerning also follows the last glyph; leave it out of the measured width.
    line.draw(at:NSPoint(x:x - (line.size().width - tracking) * anchor,y:y - font.ascender))
}
func label(_ s: String, _ color: NSColor, x: CGFloat, y: CGFloat, anchor: CGFloat = 0) {
    text(s.uppercased(),.monospacedSystemFont(ofSize:9.5,weight:.medium),color,x:x,y:y,tracking:1.2,anchor:anchor)
}

func paint() {
    paper.setFill(); NSRect(origin:.zero,size:canvas).fill()
    dot.setFill()
    for y in stride(from:band + 20,to:canvas.height,by:20) {
        for x in stride(from:0,to:canvas.width,by:20) { NSBezierPath(ovalIn:NSRect(x:x - 0.75,y:y - 0.75,width:1.5,height:1.5)).fill() }
    }
    ink.setFill(); NSRect(x:0,y:0,width:canvas.width,height:band).fill()
    // A large crop of the mark, cut off by the band's lower edge. At y = 34 Folio's lower row starts just
    // below the band instead of leaving a sliver along its edge.
    NSGraphicsContext.saveGraphicsState()
    NSRect(x:0,y:0,width:canvas.width,height:band).clip()
    mark(NSRect(x:500,y:34,width:268,height:268),top:true,inkMark)
    NSGraphicsContext.restoreGraphicsState()

    let lockup = mark(NSRect(x:44,y:44,width:44,height:32),onInk)
    text(app.name,.systemFont(ofSize:32,weight:.bold),onInk,x:lockup.maxX + 14,y:72,tracking:-0.7)
    text(app.line,.systemFont(ofSize:14),onInkQuiet,x:44,y:114)
    let facts = ["Version \(version)","macOS \(minimum) or later",platforms.joined(separator:" + ")].filter { !$0.isEmpty }
    label(facts.joined(separator:"  ·  "),onInkQuiet,x:44,y:146)

    // The drag cue: a dot at the app, a rule and an arrowhead at Applications.
    let from = appX + 70, to = applicationsX - 70
    label("Drag to install",onPaperQuiet,x:(from + to) / 2,y:iconY - 16,anchor:0.5)
    onPaper.set()
    NSBezierPath(ovalIn:NSRect(x:from - 3,y:iconY - 3,width:6,height:6)).fill()
    let arrow = NSBezierPath(); arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to:NSPoint(x:from + 8,y:iconY)); arrow.line(to:NSPoint(x:to,y:iconY))
    arrow.move(to:NSPoint(x:to - 7,y:iconY - 7)); arrow.line(to:NSPoint(x:to,y:iconY)); arrow.line(to:NSPoint(x:to - 7,y:iconY + 7))
    arrow.stroke()

    label("Then open \(app.name) from Applications and eject this disk.",onPaperQuiet,x:44,y:footer)
    label("Free and open source",onPaperQuiet,x:width - 44,y:footer,anchor:1)
}

let image = NSImage(size:canvas)
for scale in [1,2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(canvas.width) * scale,pixelsHigh:Int(canvas.height) * scale,
        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        .retagging(with:.sRGB)!
    rep.size = canvas
    let cg = NSGraphicsContext(bitmapImageRep:rep)!.cgContext
    cg.translateBy(x:0,y:canvas.height); cg.scaleBy(x:1,y:-1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext:cg,flipped:true)
    paint()
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
    if scale == 2 { try rep.representation(using:.png,properties:[:])!.write(to:output.deletingPathExtension().appendingPathExtension("png")) }
}
try image.tiffRepresentation(using:.lzw,factor:0)!.write(to:output)
