import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Original vector artwork for visual development. Never mixed with benchmark or user data.
func demoArtwork(_ folder:URL) throws {
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for index in 0..<32 {
        let style = index % 8, width = 900, height = [1160,1200,740,670,1000,800,1200,650][style]
        guard let c = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        func color(_ hex:UInt32) -> CGColor { CGColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
        func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ hex:UInt32) { c.setFillColor(color(hex)); c.fill(CGRect(x:x,y:y,width:w,height:h)) }
        func circle(_ x:CGFloat,_ y:CGFloat,_ d:CGFloat,_ hex:UInt32) { c.setFillColor(color(hex)); c.fillEllipse(in:CGRect(x:x,y:y,width:d,height:d)) }
        func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ hex:UInt32,_ font:String="HelveticaNeue-Bold") {
            let a = NSAttributedString(string:value,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName(font as CFString,size,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(hex)])
            c.textPosition = CGPoint(x:x,y:y); CTLineDraw(CTLineCreateWithAttributedString(a),c)
        }
        let shift = index / 8
        switch style {
        case 0:
            rect(0,0,900,1160,shift%2 == 0 ? 0xEF542D : 0x728B69)
            text("FORM",54,925,166,0xFFF4DF); text("& FIELD",54,770,137,0xFFF4DF)
            circle(490,135,310,0xE4B7FD); rect(90,190,390,380,0x272C28)
            text("A study in everyday shapes.",54,72,24,0xFFF4DF,"HelveticaNeue")
            text("FOLIO STUDIO  /  0\(index+1)",54,1100,18,0xFFF4DF)
        case 1:
            rect(0,0,900,1200,0xF2EBDD); text("Silt",65,945,216,0x262B25,"TimesNewRomanPSMT")
            text("THE ART OF TAKING YOUR TIME",70,1140,18,0x262B25)
            rect(70,350,760,500,0xC7D0B3); circle(180,355,460,0x7A8B73)
            rect(260,350,220,400,0xDCCBAA); text("Objects with a quieter point of view.",70,265,31,0x262B25,"TimesNewRomanPSMT")
            text("VOL. \(shift+1)     DESIGN / MATERIAL / PLACE",70,85,20,0x262B25)
        case 2:
            rect(0,0,900,740,0x242AC0)
            for n in (0..<12).reversed() { c.setLineWidth(28); c.setStrokeColor(color(n%2 == 0 ? 0xC7ACF3 : 0xFFA669)); c.strokeEllipse(in:CGRect(x:CGFloat(n)*30-300,y:CGFloat(n)*20-650,width:1600-CGFloat(n)*40,height:1250-CGFloat(n)*20)) }
            text("PLAY / IN / COLOR",45,650,30,0xFFFFFF); text("NO. \(index+1)",45,50,24,0xFFFFFF)
        case 3:
            rect(0,0,900,670,0xEEF0F6); rect(45,45,810,580,0xFFFFFF); rect(45,45,155,580,0x262A40)
            text("tempo",70,565,28,0xFFFFFF); text("Overview",70,490,16,0xCDD2E5); text("Projects",70,445,16,0xCDD2E5)
            text("Good morning, Alex.",230,555,29,0x2C2F45); text("Your week, at a glance",230,522,16,0x9296AD,"HelveticaNeue")
            for n in 0..<3 { rect(230+CGFloat(n)*195,395,177,100,[0xE9E9FA,0xFBEAE3,0xE9F1E8][n]);text(["24","86%","7"][n],249+CGFloat(n)*195,435,33,0x3B3E57) }
            text("Activity",230,337,21,0x2C2F45)
            for n in 0..<8 { rect(240+CGFloat(n)*69,115,38,CGFloat((n*47+shift*13)%145+55),n%3 == 0 ? 0xB6B9E8 : 0x6267D5) }
        case 4:
            rect(0,0,900,1000,0xDBCEC0); rect(0,0,900,240,0xC3B0A0)
            for n in 0..<3 {
                let x=CGFloat(n)*220+155, y=CGFloat(n%2)*80+220
                circle(x-45,y-35,235,0xAE9A87); rect(x,y,138,350, [0xF4EFDF,0x323D34,0xBE774F][n]); rect(x+23,y+350,92,40,0x212721)
                text("morrow",x+13,y+240,24,n == 1 ? 0xF4EFDF : 0x323D34,"TimesNewRomanPSMT")
                text("DAILY",x+20,y+205,12,n == 1 ? 0xF4EFDF : 0x323D34)
            }
            text("Less, but better.",80,852,61,0x323D34,"TimesNewRomanPSMT")
        case 5:
            rect(0,0,900,800,0xF1EBD9); text("Chromatic",50,680,66,0x252622,"TimesNewRomanPSMT")
            let colors:[UInt32] = shift%2 == 0 ? [0x385C3A,0x8BA66C,0xD4DBAE,0xB5AAD1,0x74638F] : [0xC75437,0xE6B573,0xF6DEAB,0x647DA3,0x273A63]
            for n in 0..<5 { rect(50+CGFloat(n)*160,210,160,390,colors[n]); text(String(format:"#%06X",colors[n]),59+CGFloat(n)*160,170,15,0x252622) }
            text("A palette for a different kind of day.",50,95,24,0x252622,"HelveticaNeue")
        case 6:
            rect(0,0,900,1200,0xE8F13F); text("MAKE",47,915,200,0x27272C);text("ROOM",47,715,187,0x27272C);text("FOR",47,515,200,0x27272C);text("IDEAS.",47,315,184,0x27272C)
            text("AN INDEPENDENT DESIGN EXHIBITION",53,1135,21,0x27272C); text("OCT 11—25     /     EVERYWHERE",53,90,24,0x27272C)
        default:
            rect(0,0,900,650,0xD7E3E8); rect(0,0,900,125,0xB0C2B5)
            c.setFillColor(color(0xCEBCA6)); c.move(to:CGPoint(x:140,y:170));c.addLine(to:CGPoint(x:565,y:100));c.addLine(to:CGPoint(x:800,y:265));c.addLine(to:CGPoint(x:345,y:340));c.closePath();c.fillPath()
            rect(140,170,425,275,0xEBDFCB); c.setFillColor(color(0x9B9484));c.move(to:CGPoint(x:565,y:170));c.addLine(to:CGPoint(x:800,y:335));c.addLine(to:CGPoint(x:800,y:525));c.addLine(to:CGPoint(x:565,y:445));c.closePath();c.fillPath()
            for n in 0..<6 { rect(175+CGFloat(n)*58,220,35,170,0x605F53) }; text("Spaces for stillness",50,580,31,0x35433C,"TimesNewRomanPSMT")
        }
        guard let image=c.makeImage(),let out=CGImageDestinationCreateWithURL(folder.appendingPathComponent(String(format:"study-%02d.png",index)) as CFURL,"public.png" as CFString,1,nil) else { continue }
        CGImageDestinationAddImage(out,image,nil); CGImageDestinationFinalize(out)
    }
}
