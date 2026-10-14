import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Vision
import CoreML

private final class OCRComputePreference: @unchecked Sendable {
    private let lock = NSLock()
    private var cpu = false
    var needsCPU: Bool { lock.lock(); defer { lock.unlock() }; return cpu }
    func useCPU() { lock.lock(); cpu = true; lock.unlock() }
}

public enum MediaFiles {
    private static let ocrCompute = OCRComputePreference()
    public static func kind(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        // Vector documents show as images: PDFs and Illustrator files draw their first page, SVGs draw themselves.
        if ["pdf","ai","svg"].contains(ext) { return "image" }
        if let type = UTType(filenameExtension:ext) {
            if type.conforms(to: .image) { return "image" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        }
        // Extension fallback also works in a headless process without Launch Services.
        if ["jpg","jpeg","png","heic","heif","avif","webp","gif","tif","tiff","bmp","ico","dng","cr2","cr3","nef","arw","raf","orf","rw2","pef"].contains(ext) { return "image" }
        if ["mp4","mov","m4v","webm","mkv","avi","mpeg","mpg"].contains(ext) { return "video" }
        return nil
    }
    public static func scan(_ urls: [URL]) -> [ShelfItem] { scanGroups(urls).flatMap(\.items) }
    /// Media under each URL. A folder's items are grouped under its name; loose files have no group.
    public static func scanGroups(_ urls: [URL]) -> [(group: String?, items: [ShelfItem])] {
        var groups: [(group: String?, items: [ShelfItem])] = [], seen = Set<String>()
        let now = Date().timeIntervalSince1970
        func item(_ url: URL) -> ShelfItem? {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard let kind = kind(canonical), seen.insert(canonical.path).inserted else { return nil }
            let values = try? canonical.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.creationDateKey,.contentModificationDateKey])
            guard values?.isRegularFile == true else { return nil }
            let dimensions = dimensions(canonical)
            // A photo's date is when it was taken, which survives copying; other files use the file's own date.
            let taken = kind == "image" ? takenDate(canonical) : nil
            return ShelfItem(path:canonical.path,kind:kind,added:now,
                             fileDate:(taken ?? values?.creationDate ?? values?.contentModificationDate)?.timeIntervalSince1970 ?? 0,
                             fileSize:Int64(values?.fileSize ?? 0),width:dimensions.width,height:dimensions.height)
        }
        var loose: [ShelfItem] = []
        for url in urls {
            guard (try? url.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory == true else { if let item = item(url) { loose.append(item) }; continue }
            var items: [ShelfItem] = []
            if let enumerator = FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) {
                for case let child as URL in enumerator {
                    if (try? child.resourceValues(forKeys:[.isSymbolicLinkKey]))?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if let item = item(child) { items.append(item) }
                }
            }
            if !items.isEmpty { groups.append((url.lastPathComponent,items)) }
        }
        if !loose.isEmpty { groups.insert((nil,loose),at:0) }
        return groups
    }
    /// When a photo was taken, from its camera metadata (with the camera's time zone when it recorded one).
    public static func takenDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any],
              let stamp = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from:stamp + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from:stamp)
    }
    public static func dimensions(_ url: URL) -> CGSize {
        if kind(url) == "video" { return CGSize(width:16,height:9) }
        if let size = Vector.size(url) { return size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return .zero }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width:height.doubleValue,height:width.doubleValue) : CGSize(width:width.doubleValue,height:height.doubleValue)
    }
    public static func thumbnail(url: URL, pixels: Int) -> CGImage? {
        let size = max(32,min(4096,pixels))
        if Vector.handles(url) { return Vector.render(url,pixels:size) }
        if kind(url) == "video" {
            let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width:size,height:size)
            return try? generator.copyCGImage(at:CMTime(seconds:0,preferredTimescale:600),actualTime:nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else { return nil }
        let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                                     kCGImageSourceCreateThumbnailWithTransform:true,
                                     kCGImageSourceThumbnailMaxPixelSize:size,
                                     kCGImageSourceShouldCacheImmediately:true]
        return CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary)
    }
    public static func readText(url: URL) throws -> String {
        guard let image = thumbnail(url:url,pixels:1600) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage:image)
        func selectCPU() throws {
            for (stage,devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where:{ if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu,for:stage)
                }
            }
        }
        let usingCPU = ocrCompute.needsCPU
        if usingCPU { try selectCPU() }
        do { try handler.perform([request]) }
        catch {
            guard !usingCPU else { throw error }
            // Some OS/device combinations fail in the accelerated Vision runtime.
            // Keep this fallback off the main thread with the rest of OCR indexing.
            ocrCompute.useCPU(); try selectCPU()
            try handler.perform([request])
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
    }
}

/// A shared, bounded decoder. Multiple requests for the same file/bucket share one operation.
public final class ThumbnailCache: @unchecked Sendable {
    private struct Pending {
        var id: UUID
        var path: String
        var operation: BlockOperation?
        var callbacks: [(CGImage?) -> Void]
    }
    private let cache = NSCache<NSString,CGImage>()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending: [String:Pending] = [:]
    private var failures: [String:Date] = [:]
    public let disk: URL
    public init(disk: URL, budgetMB: Int = 128) {
        self.disk = disk
        cache.totalCostLimit = budgetMB * 1024 * 1024
        queue.name = "org.lumashelf.thumbnail-decode"; queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        try? FileManager.default.createDirectory(at:disk,withIntermediateDirectories:true)
    }
    public static func bucket(_ pixels: Int) -> Int { pixels <= 256 ? 256 : pixels <= 512 ? 512 : 1024 }
    private func key(_ path: String, _ pixels: Int) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath:path)
        let size = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        return ShelfItem.digest("v1|\(path)|\(size?.int64Value ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)|\(Self.bucket(pixels))")
    }
    public func request(path: String, pixels: Int, prefetch: Bool = false, completion: @escaping (CGImage?) -> Void) {
        let k = key(path,pixels)
        if let hit = cache.object(forKey:k as NSString) { completion(hit); return }
        lock.lock()
        if let failed = failures[k], Date().timeIntervalSince(failed) < 5 {
            lock.unlock(); completion(nil); return
        }
        if pending[k] != nil { pending[k]!.callbacks.append(completion); lock.unlock(); return }
        let workID = UUID()
        pending[k] = Pending(id:workID,path:path,operation:nil,callbacks:[completion]); lock.unlock()
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            let image: CGImage? = autoreleasepool {
                let stored = self.disk.appendingPathComponent(k).appendingPathExtension("png")
                if FileManager.default.fileExists(atPath:stored.path), let image = MediaFiles.thumbnail(url:stored,pixels:Self.bucket(pixels)) { return image }
                guard let image = MediaFiles.thumbnail(url:URL(fileURLWithPath:path),pixels:Self.bucket(pixels)) else { return nil }
                // Atomic promotion prevents partial cache files after a crash.
                let temp = self.disk.appendingPathComponent(".\(UUID().uuidString).png")
                if let destination = CGImageDestinationCreateWithURL(temp as CFURL,UTType.png.identifier as CFString,1,nil) {
                    CGImageDestinationAddImage(destination,image,nil)
                    if CGImageDestinationFinalize(destination) { try? FileManager.default.moveItem(at:temp,to:stored) }
                    try? FileManager.default.removeItem(at:temp)
                }
                return image
            }
            if let image { self.cache.setObject(image,forKey:k as NSString,cost:image.bytesPerRow * image.height) }
            self.lock.lock()
            let callbacks: [(CGImage?) -> Void]
            if self.pending[k]?.id == workID { callbacks = self.pending.removeValue(forKey:k)?.callbacks ?? [] }
            else { callbacks = [] }
            if image == nil { self.failures[k] = Date() }
            self.lock.unlock()
            DispatchQueue.main.async { callbacks.forEach { $0(image) } }
        }
        operation.queuePriority = prefetch ? .low : .veryHigh
        lock.lock()
        if pending[k]?.id == workID { pending[k]?.operation = operation }
        lock.unlock()
        queue.addOperation(operation)
    }
    public func clearMemory() { cache.removeAllObjects() }
    /// Forgets the stored thumbnails of a file, so the next request draws it again.
    public func invalidate(path: String) {
        let keys = [256,512,1024].map { key(path,$0) }
        for k in keys {
            cache.removeObject(forKey:k as NSString)
            try? FileManager.default.removeItem(at:disk.appendingPathComponent(k).appendingPathExtension("png"))
        }
        lock.lock(); keys.forEach { failures.removeValue(forKey:$0) }; lock.unlock()
    }
    public func retainRequests(for paths: Set<String>) {
        lock.lock()
        var callbacks: [(CGImage?) -> Void] = []
        for (key,work) in pending where !paths.contains(work.path) {
            guard let operation = work.operation, !operation.isExecuting else { continue }
            operation.cancel(); callbacks += work.callbacks; pending.removeValue(forKey:key)
        }
        lock.unlock()
        if !callbacks.isEmpty { DispatchQueue.main.async { callbacks.forEach { $0(nil) } } }
    }
}

/// PDFs, Illustrator files and SVGs, which ImageIO can't draw: their size in points and a bitmap of the first page.
enum Vector {
    static func handles(_ url: URL) -> Bool { ["pdf","ai","svg"].contains(url.pathExtension.lowercased()) }
    static func size(_ url: URL) -> CGSize? {
        switch url.pathExtension.lowercased() {
        case "pdf", "ai":
            guard let page = CGPDFDocument(url as CFURL)?.page(at:1) else { return nil }
            let box = page.getBoxRect(.cropBox), turned = page.rotationAngle % 180 != 0
            return turned ? CGSize(width:box.height,height:box.width) : box.size
        case "svg": return NSImage(contentsOf:url).map { $0.size }.flatMap { $0.width > 0 ? $0 : nil }
        default: return nil
        }
    }
    static func render(_ url: URL, pixels: Int) -> CGImage? {
        guard let natural = size(url), natural.width > 0, natural.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(natural.width,natural.height)
        let width = max(1,Int(natural.width * scale)), height = max(1,Int(natural.height * scale))
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        switch url.pathExtension.lowercased() {
        case "svg":
            // SVGs keep their transparency.
            guard let image = NSImage(contentsOf:url) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            image.draw(in:CGRect(x:0,y:0,width:width,height:height))
            NSGraphicsContext.restoreGraphicsState()
        default:
            guard let page = CGPDFDocument(url as CFURL)?.page(at:1) else { return nil }
            // A page is paper: white behind it, as any viewer shows it.
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
            let transform = page.getDrawingTransform(.cropBox,rect:CGRect(x:0,y:0,width:width,height:height),rotate:0,preserveAspectRatio:true)
            context.concatenate(transform); context.drawPDFPage(page)
        }
        return context.makeImage()
    }
}
