import Foundation
import ShelfCore
import ImageIO
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
import QuartzCore

let args = CommandLine.arguments
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of:name), i + 1 < args.count else { return fallback }; return args[i+1]
}
func elapsed<T>(_ operation: () throws -> T) rethrows -> (T,Double) {
    let start = CACurrentMediaTime(); let result = try operation(); return (result,CACurrentMediaTime()-start)
}
func fixture(_ folder: URL, count: Int) throws -> Double {
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let start = CACurrentMediaTime()
    for index in 0..<count {
        try autoreleasepool {
            let themes = ["warm-interior","blue-interface","green-landscape","red-poster","mono-typography"]
            let name = String(format:"%@-%05d.jpg",themes[index % themes.count],index)
            let destination = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:destination.path) { return }
            let width = index % 100 == 0 ? 2560 : 640
            let height = index % 3 == 0 ? width : width * 3 / 4
            let color = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,
                                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain:"Fixture",code:1) }
            let hue = Double((index * 137) % 255) / 255
            context.setFillColor(red:CGFloat(0.15+hue*0.7),green:CGFloat(0.2+Double(index%5)*0.12),blue:CGFloat(0.8-hue*0.6),alpha:1)
            context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.setFillColor(red:1,green:1,blue:1,alpha:0.2)
            context.fill(CGRect(x:width/8,y:height/6,width:width*3/4,height:height*2/3))
            context.setFillColor(red:0.05,green:0.05,blue:0.08,alpha:1)
            context.fillEllipse(in:CGRect(x:width/3,y:height/3,width:width/3,height:width/3))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString,CGFloat(width)/17,nil)
            let text = NSAttributedString(string:"LUMA \(index)",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                                           NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
            context.textPosition = CGPoint(x:width/10,y:height/10)
            CTLineDraw(CTLineCreateWithAttributedString(text),context)
            guard let image = context.makeImage(), let output = CGImageDestinationCreateWithURL(destination as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw NSError(domain:"Fixture",code:2) }
            CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:0.82] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw NSError(domain:"Fixture",code:3) }
        }
    }
    return CACurrentMediaTime()-start
}
func stats(_ seconds: [Double]) -> [String:Any] {
    let d = Distribution(seconds:seconds)
    return ["count":d.count,"medianMS":d.medianMS,"p95MS":d.p95MS,"maxMS":d.maxMS]
}
do {
    let folder = URL(fileURLWithPath:option("--folder","fixtures"),isDirectory:true)
    if args.contains("demo") {
        try demoArtwork(folder); print("Generated original design studies at \(folder.path)")
    } else if args.contains("generate") {
        let count = Int(option("--count","1000")) ?? 1000
        let seconds = try fixture(folder,count:count)
        print("Generated \(count) synthetic JPEG files in \(String(format:"%.2f",seconds)) seconds at \(folder.path)")
    } else if args.contains("classify") {
        let result = try ImageClassifier().analyze(url:URL(fileURLWithPath:option("--file","")),includeOCR:args.contains("--ocr"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(result)
        if args.contains("--output") { try data.write(to:URL(fileURLWithPath:option("--output","analysis.json")),options:.atomic) }
        print(String(decoding:data,as:UTF8.self))
    } else if args.contains("ocr") {
        let file = URL(fileURLWithPath:option("--file",""))
        let (text,seconds) = try elapsed { try MediaFiles.readText(url:file) }
        let report: [String:Any] = ["text":text,"elapsedMS":seconds * 1000,"engine":"Apple Vision local OCR"]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if args.contains("--output") { try data.write(to:URL(fileURLWithPath:option("--output","ocr.json")),options:.atomic) }
        print(String(data:data,encoding:.utf8)!)
    } else if args.contains("run") {
        let root = URL(fileURLWithPath:option("--library","benchmark-library"),isDirectory:true)
        let database = try LibraryDatabase(root:root)
        let (items,scan) = elapsed { MediaFiles.scan([folder]) }
        guard !items.isEmpty else { throw NSError(domain:"ShelfBench",code:1,userInfo:[NSLocalizedDescriptionKey:"No media found in \(folder.path); refusing an empty benchmark."]) }
        let (_,insertion) = try elapsed { try database.insert(items) }
        var loads: [Double] = [], searches: [Double] = [], layouts: [Double] = [], decodes: [Double] = []
        var matched = 0
        for _ in 0..<30 { let (_,t) = try elapsed { try database.items() }; loads.append(t) }
        let queries = ["warm","blue interface","green","poster","mono typ","missingterm","warm-interior-00000"]
        for i in 0..<210 {
            let (results,t) = try elapsed { try database.items(query:queries[i%queries.count]) }
            matched += results.count; searches.append(t)
        }
        var totalVisible = 0
        let geometry = MasonryLayout(items:items,width:960,tileSize:190)
        for i in 0..<10000 {
            let (range,t) = elapsed { geometry.visibleRange(y:Double(i%500)*800,height:720,marginRows:1) }
            totalVisible += range.count; layouts.append(t)
        }
        for item in items.prefix(300) {
            let (_,t) = elapsed { autoreleasepool { MediaFiles.thumbnail(url:URL(fileURLWithPath:item.path),pixels:512) } }
            decodes.append(t)
        }
        let output: [String:Any] = ["app":"Folio","version":"0.2.0","items":items.count,
                                  "scanMS":scan*1000,"insertMS":insertion*1000,"loadAllMetadata":stats(loads),
                                  "fullTextSearch":stats(searches),"visibleRangeMath":stats(layouts),"decode512px":stats(decodes),
                                  "checksum":matched+totalVisible,"searchIncludesResultMaterialization":true,
                                  "dataset":"Synthetic JPEG illustrations; 1% 2560px, others 640px. Not a representative photographic workload.",
                                  "cacheState":"Repeated searches/loads; warm OS filesystem cache. Thumbnail measurements bypass app preview caches.",
                                  "hardware":"Record host details separately; no cross-machine comparison implied."]
        let data = try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
        let out = URL(fileURLWithPath:option("--output","core-benchmark.json"))
        try data.write(to:out,options:.atomic)
        print(String(data:data,encoding:.utf8)!)
    } else {
        print("shelf-bench generate --folder PATH --count 10000\nshelf-bench run --folder PATH --library PATH --output report.json\nshelf-bench ocr --file IMAGE --output report.json")
    }
} catch { fputs("Benchmark error: \(error)\n",stderr); exit(1) }
