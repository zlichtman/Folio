import Foundation
import CoreGraphics
import ImageIO
// Renders the macOS iconset from the 1024 px master in Design/folio-app-icon.png.
let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let master=URL(fileURLWithPath:CommandLine.arguments[2])
guard let source=CGImageSourceCreateWithURL(master as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { fatalError("Cannot read icon master \(master.path)") }
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for (name,pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let c=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(image,in:CGRect(x:0,y:0,width:pixels,height:pixels))
    let out=CGImageDestinationCreateWithURL(folder.appendingPathComponent(name+".png") as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(out,c.makeImage()!,nil);CGImageDestinationFinalize(out)
}
