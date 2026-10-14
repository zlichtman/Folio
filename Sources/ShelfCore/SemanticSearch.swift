import Foundation
import NaturalLanguage

/// Search by meaning, on this Mac: the words of a query point to the labels Folio's image analysis gave your
/// images (and colour words to colours), so "dogs on the beach" finds pictures tagged dog and beach even when
/// no name or note says so. Built on Apple's on-device word embeddings.
public enum SemanticSearch {
    private static let embedding = NLEmbedding.wordEmbedding(for:.english)
    private static let skipped: Set<String> = ["the","a","an","of","on","in","at","with","and","or","for","to","from","by","my","some","photo","photos",
                                               "picture","pictures","image","images","shot","shots","that","this","these","those","like","looks"]
    /// Words that stand for several colours at once.
    static let colourWords: [String:[String]] = ["warm":["red","orange","yellow"],"cool":["blue","teal","green"],"cold":["blue","teal","white"],
                                                 "dark":["black"],"night":["black"],"bright":["white","yellow"],"pastel":["pink","white"],
                                                 "neon":["pink","green","teal"],"earthy":["orange","green"],"monochrome":["black","white","gray"]]
    /// The labels from `vocabulary` a query points to, each with a weight from 0 to 1. Exact words weigh 1; close
    /// words and labels that only share a word with the query weigh less.
    public static func expand(_ query: String, vocabulary: [String]) -> [String:Double] {
        let words = lemmas(query).filter { $0.count > 2 && !skipped.contains($0) }
        guard !words.isEmpty, !vocabulary.isEmpty else { return [:] }
        var out: [String:Double] = [:]
        func keep(_ label: String, _ weight: Double) { if weight > (out[label] ?? 0) { out[label] = weight } }
        let parts = vocabulary.map { label in (label,label.lowercased().split(whereSeparator:{ $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)) }
        for word in words {
            for colour in colourWords[word] ?? [] where vocabulary.contains(colour) { keep(colour,0.6) }
            for (label,pieces) in parts where !pieces.isEmpty {
                var best = 0.0
                let forms: Set<String> = [word,singular(word)]
                for piece in pieces {
                    if forms.contains(piece) || forms.contains(singular(piece)) { best = 1; break }
                    if let embedding, piece.count > 2 {
                        let distance = embedding.distance(between:word,and:piece)
                        // Measured: true synonyms sit under 0.6; everything past 0.75 is noise.
                        if distance < 0.75 { best = max(best,1 - distance) }
                    }
                }
                guard best > 0 else { continue }
                // A label only partly named by the query ("prairie dog" for "dog") counts for less.
                keep(label,best * (pieces.count == 1 ? 1 : 0.6))
            }
        }
        return out.filter { $0.value >= 0.3 }
    }
    /// The base forms of the words: "mountains" becomes "mountain", "running" becomes "run".
    static func lemmas(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes:[.lemma])
        tagger.string = text.lowercased()
        var out: [String] = []
        tagger.enumerateTags(in:tagger.string!.startIndex..<tagger.string!.endIndex,unit:.word,scheme:.lemma,options:[.omitWhitespace,.omitPunctuation]) { tag, range in
            out.append((tag?.rawValue ?? String(tagger.string![range])).lowercased()); return true
        }
        return out
    }
    /// Plain English plurals, for words the lemmatizer leaves alone (it needs a sentence around them).
    static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if ["ches","shes","sses","xes","zes"].contains(where:word.hasSuffix) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }
    /// How well an item's tags answer the expanded query: the sum of the weights it carries.
    public static func score(_ item: ShelfItem, _ weights: [String:Double]) -> Double {
        Set((item.tags + item.autoTags).map { $0.lowercased() }).reduce(0) { $0 + (weights[$1] ?? 0) }
    }
}
