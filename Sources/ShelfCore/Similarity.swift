import Foundation
import Vision

/// Finds items that look alike: Apple Vision feature prints compared on this Mac, by palette, composition and style.
public enum VisualSimilarity {
    /// Bump when the print changes so old ones are recomputed.
    public static let version = 1
    /// A print of the image at `url`, archived for `LibraryDatabase.saveFeaturePrint`.
    public static func featurePrint(url: URL) throws -> Data {
        guard let image = MediaFiles.thumbnail(url:url,pixels:512) else {
            throw NSError(domain:"Folio.Similarity",code:1,userInfo:[NSLocalizedDescriptionKey:"This file could not be decoded."])
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage:image)
        do { try handler.perform([request]) }
        catch {
            // Some Macs and virtual machines have no Neural Engine for this request; the CPU always works.
            for (stage,devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where:{ if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu,for:stage) }
            }
            try handler.perform([request])
        }
        guard let print = request.results?.first else { throw NSError(domain:"Folio.Similarity",code:2) }
        return try NSKeyedArchiver.archivedData(withRootObject:print,requiringSecureCoding:true)
    }
    public static func observation(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass:VNFeaturePrintObservation.self,from:data)
    }
    /// The closest prints to `target`, nearest first, leaving out the target itself.
    public static func nearest(to target: String, in prints: [String:VNFeaturePrintObservation], limit: Int = 60) -> [(id: String, distance: Float)] {
        guard let anchor = prints[target] else { return [] }
        var out: [(id: String, distance: Float)] = []
        out.reserveCapacity(prints.count)
        for (id,print) in prints where id != target {
            var distance: Float = 0
            if (try? anchor.computeDistance(&distance,to:print)) != nil { out.append((id,distance)) }
        }
        out.sort { $0.distance < $1.distance }
        // Measured on varied libraries: near copies sit under 0.5, related images under 0.8 and unrelated ones
        // above 0.9. Keep the related ones, and the closest few that aren't far off, so odd images still get some.
        return Array(out.enumerated().filter { $1.distance <= 0.8 || ($0 < 6 && $1.distance < 1.12) }.map(\.element).prefix(limit))
    }
}
