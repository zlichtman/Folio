import Foundation
import ShelfCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Describes pictures with the Mac's own language model, where it can see images (macOS 27 and Apple Intelligence):
/// a sentence about what's in the picture and a few keywords, kept with the item and searched like its name. A
/// description like "a calm blue pattern" then finds pictures nobody tagged. Nothing leaves the Mac.
enum PictureDescriber {
    /// Whether this Mac can describe pictures at all.
    static var isAvailable: Bool {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, *), case .available = SystemLanguageModel.default.availability {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        #endif
        return false
    }

    /// A description of the picture at `url` (a still, or a video's or link's preview), or nil when there's none to
    /// be had. Waits up to 30 seconds; call it off the main thread.
    static func describe(_ url: URL) -> String? {
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(macOS 27, *), let image = MediaFiles.thumbnail(url:url,pixels:768) else { return nil }
        let done = DispatchSemaphore(value:0)
        nonisolated(unsafe) var reply: String?
        Task.detached {
            defer { done.signal() }
            let session = LanguageModelSession(instructions:"""
                You describe pictures so people can find them by searching. Answer with one plain sentence naming the \
                subject, setting, colours, style and mood, then a new line of up to ten lowercase comma-separated keywords. \
                No preamble.
                """)
            reply = try? await session.respond { "Describe this picture."; Attachment(image) }.content
        }
        guard done.wait(timeout:.now() + 30) == .success, let text = reply?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(600))
        #else
        return nil
        #endif
    }
}

extension AppController {
    /// Settings ▸ Tagging: describing pictures is on unless turned off, and only where the Mac can.
    var describesPictures: Bool {
        autoTagsEnabled && (UserDefaults.standard.object(forKey:"describePictures") as? Bool ?? true) && PictureDescriber.isAvailable
    }
    /// Describes pictures that haven't been, a batch at a time, after tagging. One the model can't describe is marked,
    /// so it isn't tried again on every pass.
    func describePictures(_ job: BlockOperation) {
        guard describesPictures else { return }
        var described = 0
        while !job.isCancelled, let batch = try? database.itemsToDescribe(limit:10), !batch.isEmpty {
            for entry in batch where !job.isCancelled {
                let seen = autoreleasepool { PictureDescriber.describe(URL(fileURLWithPath:entry.path)) } ?? ""
                if !job.isCancelled { try? database.setSeen(seen,id:entry.id) }
                described += 1
                let count = described
                DispatchQueue.main.async { if !job.isCancelled { self.setActivity("Describing pictures · \(count)") } }
            }
        }
        if described > 0 { DispatchQueue.main.async { if !job.isCancelled { self.setActivity(nil) } } }
    }
}
