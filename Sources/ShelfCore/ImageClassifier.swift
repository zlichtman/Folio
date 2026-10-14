import Foundation
import Vision
import CoreML
import CoreGraphics

public struct TagSuggestion: Codable, Equatable, Sendable {
    public let label: String
    public let confidence: Float
    public let evidence: String
    public init(label: String, confidence: Float, evidence: String = "vision") {
        self.label = label; self.confidence = confidence; self.evidence = evidence
    }
}
public struct ImageAnalysis: Codable, Sendable {
    public var suggestions: [TagSuggestion]
    public var colors: [String]
    public var text: String
    public var engine: String
    public var elapsedMS: Double
    public var automaticTags: [String] {
        let objects = suggestions.filter { $0.evidence == "vision" && $0.confidence >= 0.20 }.prefix(3)
        let supporting = suggestions.filter { ($0.evidence == "color" && $0.confidence >= 0.25) || $0.evidence == "ocr" }.prefix(2)
        return (Array(objects) + Array(supporting)).map(\.label)
    }
}

/// One instance per indexing worker. These are real pixel-based Vision classifications.
public final class ImageClassifier {
    public static let version = "vision-r2-color-v2"
    private var cpuOnly = false
    public init() {}
    public static func fingerprint(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath:path)
        return ShelfItem.digest("\(version)|\(path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
    }
    public func analyze(url: URL, includeOCR: Bool = false) throws -> ImageAnalysis {
        let start = ProcessInfo.processInfo.systemUptime
        guard let image = MediaFiles.thumbnail(url:url,pixels:768) else {
            throw NSError(domain:"Folio.Classifier",code:1,userInfo:[NSLocalizedDescriptionKey:"This file could not be decoded for tagging."])
        }
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        func selectCPU() throws {
            for (stage, devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where:{ if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu,for:stage) }
            }
        }
        if cpuOnly { try selectCPU() }
        let handler = VNImageRequestHandler(cgImage:image)
        do { try handler.perform([request]) }
        catch { guard !cpuOnly else { throw error }; cpuOnly = true; try selectCPU(); try handler.perform([request]) }
        let excluded: Set<String> = ["object","thing","indoors","outdoors","animal","mammal","feline","vertebrate","material"]
        var seen = Set<String>()
        var labels = (request.results ?? []).filter { $0.confidence >= 0.07 }.sorted { $0.confidence > $1.confidence }.compactMap { value -> TagSuggestion? in
            var label = value.identifier.lowercased().replacingOccurrences(of:"_",with:"-").replacingOccurrences(of:" ",with:"-")
            if ["adult-cat","kitten"].contains(label) { label = "cat" }
            guard !excluded.contains(label),seen.insert(label).inserted else { return nil }
            return TagSuggestion(label:label,confidence:value.confidence)
        }
        labels = Array(labels.prefix(5))
        let palette = Self.palette(image)
        if let top = palette.first { labels.append(TagSuggestion(label:top.name,confidence:Float(top.fraction),evidence:"color")) }
        let text = includeOCR ? (try? MediaFiles.readText(url:url)) ?? "" : ""
        if text.filter({ !$0.isWhitespace }).count >= 18 { labels.append(TagSuggestion(label:"typography",confidence:0.8,evidence:"ocr")) }
        // The four largest colours, then up to two small accents that still show (2% of the picture or more).
        let colors = palette.enumerated().filter { $0.offset < 4 || $0.element.fraction >= 0.02 }.prefix(6).map(\.element.hex)
        return ImageAnalysis(suggestions:labels,colors:colors,text:text,
                             engine:cpuOnly ? "Apple Vision · CPU" : "Apple Vision · local",
                             elapsedMS:(ProcessInfo.processInfo.systemUptime-start)*1000)
    }
    private struct Swatch { var name: String; var hex: String; var fraction: Double }
    private static func palette(_ image: CGImage) -> [Swatch] {
        let side = 48
        var bytes = [UInt8](repeating:0,count:side*side*4)
        let names = ColorMath.buckets
        var counts = [Int](repeating:0,count:names.count), sums = [[Int]](repeating:[0,0,0],count:names.count)
        bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data:memory.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:side,height:side))
            context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
        }
        for offset in stride(from:0,to:bytes.count,by:4) {
            let r=Double(bytes[offset])/255,g=Double(bytes[offset+1])/255,b=Double(bytes[offset+2])/255
            let bucket = names.firstIndex(of:ColorMath.bucket(r:r,g:g,b:b)) ?? 10
            counts[bucket] += 1
            for c in 0..<3 { sums[bucket][c] += Int(bytes[offset+c]) }
        }
        return counts.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }.map { i in
            let values=sums[i].map { $0/counts[i] }
            return Swatch(name:names[i],hex:String(format:"#%02x%02x%02x",values[0],values[1],values[2]),fraction:Double(counts[i])/Double(side*side))
        }
    }
}
