import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Search by description ("a warm bar interior at night"): the Mac's own language model, where it has one, picks the
/// library's labels that fit the words, so pictures nobody tagged by hand still answer. Nothing leaves the Mac; on
/// Macs without the model, search by meaning keeps to word matching.
enum DescribedSearch {
    private static var answers: [String:[String]] = [:]
    private static let lock = NSLock()

    /// Labels from `vocabulary` that fit a description of three words or more; empty when there's no model.
    static func labels(for description: String, vocabulary: [String]) -> [String] {
        let text = description.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.split(separator:" ").count >= 3, !vocabulary.isEmpty else { return [] }
        let key = text.lowercased()
        lock.lock(); let known = answers[key]; lock.unlock()
        if let known { return known }
        var found: [String] = []
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
            let choices = Array(vocabulary.prefix(500))
            let done = DispatchSemaphore(value:0)
            var reply = ""
            Task.detached {
                defer { done.signal() }
                let session = LanguageModelSession(instructions:"You match descriptions of pictures to labels. Answer only with labels from the list given, one per line.")
                reply = (try? await session.respond(to:"""
                    Labels: \(choices.joined(separator:", "))

                    Which of these labels fit pictures described as “\(text)”? Give up to eight, best first, one per line, nothing else.
                    """).content) ?? ""
            }
            // Search shouldn't wait long on the model; without an answer it falls back to word matching.
            if done.wait(timeout:.now() + 4) == .success {
                let byName = Dictionary(choices.map { ($0.lowercased(),$0) },uniquingKeysWith:{ a,_ in a })
                found = reply.split(whereSeparator:\.isNewline)
                    .map { $0.trimmingCharacters(in:CharacterSet(charactersIn:" -•*0123456789.").union(.whitespaces)).lowercased() }
                    .compactMap { byName[$0] }
                found = Array(NSOrderedSet(array:found).array as? [String] ?? found).prefix(8).map { $0 }
            }
        }
        #endif
        lock.lock(); answers[key] = found; lock.unlock()
        return found
    }
}
