import Foundation
import NaturalLanguage

/// Ranks memories and notes by how related they are to a message, so the prompt carries only
/// what matters and the store can grow without bloating it.
///
/// Uses Natural Language's on-device sentence embeddings when one exists for the message's
/// language, blended with a keyword score that folds case and diacritics and matches word
/// stems loosely (Turkish suffixes included). Without an embedding the keyword score alone
/// decides, which is fully deterministic.
public struct MemoryRanker: Sendable {
    /// Whether to try sentence embeddings. Tests turn them off for deterministic results.
    public var usesEmbeddings: Bool

    public init(usesEmbeddings: Bool = true) {
        self.usesEmbeddings = usesEmbeddings
    }

    /// Scores `items` against `query`, highest first. Ties keep the input order reversed, so
    /// with items sorted oldest to newest the most recent one wins.
    public func rank<Item>(
        _ items: [Item], by text: (Item) -> String, query: String
    ) -> [(item: Item, score: Double)] {
        let queryTokens = Self.tokens(query)
        let embedding = usesEmbeddings ? SentenceEmbeddings.shared.embedder(for: query) : nil
        let queryVector = embedding?(query)
        let scored = items.enumerated().map { offset, item in
            let body = text(item)
            var score = Self.keywordScore(query: queryTokens, item: Self.tokens(body))
            if let queryVector, let vector = embedding?(body) {
                // Sentence vectors of unrelated text are rarely orthogonal, so map the whole
                // cosine range to 0...1 and let the ordering, not the value, matter.
                let similarity = (Self.cosine(queryVector, vector) + 1) / 2
                score = 0.6 * similarity + 0.4 * score
            }
            return (offset: offset, item: item, score: score)
        }
        return
            scored
            .sorted { ($0.score, $0.offset) > ($1.score, $1.offset) }
            .map { ($0.item, $0.score) }
    }

    /// The memories to put in the system prompt: a few recent core memories (preferences and
    /// people), then the ones most related to `message`, `limit` in total. When everything
    /// fits, all memories are returned in their original order.
    ///
    /// - Parameter memories: Memories from oldest to newest, as the store returns them.
    public func promptMemories(
        from memories: [Memory], message: String, coreLimit: Int = 5, limit: Int = 15
    ) -> [Memory] {
        guard memories.count > limit else { return memories }
        let core = memories.filter { $0.category == .preference || $0.category == .person }
            .suffix(min(coreLimit, limit))
        let coreIDs = Set(core.map(\.id))
        let rest = memories.filter { !coreIDs.contains($0.id) }
        let related = rank(rest, by: \.text, query: message)
            .prefix(limit - core.count)
            .map(\.item)
        return Array(core) + related
    }

    // MARK: - Keywords

    /// Words too common to say anything about relevance.
    static let stopWords: Set<String> = [
        // English
        "the", "and", "for", "are", "but", "not", "you", "your", "with", "this", "that", "have",
        "has", "was", "were", "what", "when", "where", "who", "how", "why", "can", "could",
        "would", "should", "about", "from", "into", "some", "any", "all", "our", "they",
        "them", "their", "there", "then", "than", "its", "it's", "user", "user's", "users",
        "please", "tell", "does", "did", "will", "just", "like", "likes", "me", "my", "is",
        "am", "an", "to", "of", "in", "on", "at", "or", "be", "do", "it", "we", "he", "she",
        // Turkish
        "bir", "ve", "ile", "icin", "bu", "su", "o", "da", "de", "mi", "mu", "ne", "ben",
        "sen", "biz", "siz", "onlar", "benim", "senin", "gibi", "daha", "cok", "ama", "ya",
        "ki", "kullanici", "kullanicinin", "nasil", "neden", "hangi", "var", "yok", "olan",
        "misin", "musun", "bana", "sana", "beni",
    ]

    /// Lowercased words without diacritics, stop words or single letters.
    static func tokens(_ text: String) -> [String] {
        let folded =
            text
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .map { word in
                // "Emre's" and "Emre'nin" both mean Emre.
                word.split(separator: "'").first.map(String.init) ?? word
            }
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// How well two words match: exactly, as a stem ("kahve" in "kahveyi") or by a long
    /// shared beginning ("kitap" and "kitabi").
    static func wordMatch(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        if short.count >= 4, long.hasPrefix(short) { return 0.8 }
        let shared = zip(short, long).prefix { $0 == $1 }.count
        if shared >= 4, Double(shared) >= 0.75 * Double(short.count) { return 0.6 }
        return 0
    }

    /// A cosine-like overlap between two token lists, from 0 to 1.
    static func keywordScore(query: [String], item: [String]) -> Double {
        guard !query.isEmpty, !item.isEmpty else { return 0 }
        let queryWords = Array(Set(query))
        let itemWords = Array(Set(item))
        let total = queryWords.reduce(0.0) { sum, word in
            sum + (itemWords.map { wordMatch(word, $0) }.max() ?? 0)
        }
        return min(1, total / (Double(queryWords.count * itemWords.count)).squareRoot())
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        let norm = (left * right).squareRoot()
        return norm > 0 ? dot / norm : 0
    }
}

/// Loads Natural Language sentence embeddings once per language and caches vectors.
///
/// `NLEmbedding` is not `Sendable`, so every access goes through a lock.
final class SentenceEmbeddings: @unchecked Sendable {
    static let shared = SentenceEmbeddings()

    /// Languages worth trying; others fall back to keywords.
    static let languages: Set<NLLanguage> = [
        .english, .turkish, .german, .french, .spanish, .italian, .portuguese, .dutch,
    ]

    private let lock = NSLock()
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private var missing: Set<NLLanguage> = []
    private var vectors: [String: [Double]] = [:]

    /// A function that embeds text with the model for `sample`'s language, or `nil` when the
    /// language is unknown or has no sentence embedding on this Mac.
    func embedder(for sample: String) -> ((String) -> [Double]?)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, Self.languages.contains(language),
            load(language) != nil
        else { return nil }
        return { [self] text in vector(for: text, language: language) }
    }

    private func load(_ language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let embedding = embeddings[language] { return embedding }
        if missing.contains(language) { return nil }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            missing.insert(language)
            return nil
        }
        embeddings[language] = embedding
        return embedding
    }

    private func vector(for text: String, language: NLLanguage) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(language.rawValue)|\(text)"
        if let cached = vectors[key] { return cached }
        guard let vector = embeddings[language]?.vector(for: text) else { return nil }
        if vectors.count > 2000 { vectors.removeAll() }
        vectors[key] = vector
        return vector
    }
}
