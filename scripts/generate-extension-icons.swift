import Foundation
import CoreGraphics
import ImageIO
// Renders the browser extension icons: Design/folio-mark.svg in white on a black squircle.
// Usage: swift scripts/generate-extension-icons.swift Design/folio-mark.svg Extensions/shared/icons
let mark=URL(fileURLWithPath:CommandLine.arguments[1]), folder=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)

final class Shapes: NSObject, XMLParserDelegate {
    var paths: [(CGFloat) -> CGPath] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String:String]) {
        func v(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "0") ?? 0) }
        if name == "rect" {
            let r=CGRect(x:v("x"),y:v("y"),width:v("width"),height:v("height")), radius=v("rx")
            paths.append { s in CGPath(roundedRect:r.applying(.init(scaleX:s,y:s)),cornerWidth:radius*s,cornerHeight:radius*s,transform:nil) }
        } else if name == "circle" {
            let c=CGPoint(x:v("cx"),y:v("cy")), r=v("r")
            paths.append { s in CGPath(ellipseIn:CGRect(x:(c.x-r)*s,y:(c.y-r)*s,width:2*r*s,height:2*r*s),transform:nil) }
        }
    }
}
let shapes=Shapes(), parser=XMLParser(contentsOf:mark)!
parser.delegate=shapes
guard parser.parse(), !shapes.paths.isEmpty else { fatalError("Cannot read \(mark.path)") }
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)

func squircle(_ size: CGFloat) -> CGPath {
    let path=CGMutablePath(), half=size/2, n=5.0
    for i in 0...360 {
        let t=Double(i)*Double.pi/180, c=cos(t), s=sin(t)
        let p=CGPoint(x:half+half*CGFloat(copysign(pow(abs(c),2/n),c)),y:half+half*CGFloat(copysign(pow(abs(s),2/n),s)))
        if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
    }
    path.closeSubpath(); return path
}

for pixels in [16,32,48,96,128] {
    let size=CGFloat(pixels)
    let c=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(true)
    c.addPath(squircle(size)); c.setFillColor(CGColor(gray:0,alpha:1)); c.fillPath()
    // SVG space is y-down; the mark sits at 56% of the tile, centered.
    let inner=size*0.56, scale=inner/100
    c.translateBy(x:(size-inner)/2,y:(size+inner)/2); c.scaleBy(x:1,y:-1)
    c.setFillColor(CGColor(gray:1,alpha:1))
    for shape in shapes.paths { c.addPath(shape(scale)) }
    c.fillPath()
    let out=CGImageDestinationCreateWithURL(folder.appendingPathComponent("icon-\(pixels).png") as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(out,c.makeImage()!,nil); CGImageDestinationFinalize(out)
}
print("Wrote extension icons to \(folder.path)")
