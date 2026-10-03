import Foundation
import PicshopCore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// An optional sentence embedder fused with the lexical retrieval (reciprocal rank fusion).
/// Returns nil when it has no vector for the text (unsupported language, asset not loaded).
public protocol OperationEmbedder: Sendable {
    func vector(for text: String, language: NormalizedUtterance.Language) -> [Float]?
}

#if canImport(NaturalLanguage)
/// Apple's on-device sentence embeddings (NLEmbedding, part of iOS: nothing is downloaded).
/// The contextual embeddings are never used: their assets come from the network.
public final class NaturalLanguageOperationEmbedder: OperationEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [String: NLEmbedding] = [:]
    private var missing: Set<String> = []

    public init() {}

    public func vector(for text: String, language: NormalizedUtterance.Language) -> [Float]? {
        guard let embedding = embedding(for: language) else { return nil }
        return embedding.vector(for: text).map { $0.map(Float.init) }
    }

    private func embedding(for language: NormalizedUtterance.Language) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = embeddings[language.rawValue] { return cached }
        if missing.contains(language.rawValue) { return nil }
        let nlLanguage: NLLanguage = language == .french ? .french : .english
        guard let loaded = NLEmbedding.sentenceEmbedding(for: nlLanguage) else {
            missing.insert(language.rawValue)
            return nil
        }
        embeddings[language.rawValue] = loaded
        return loaded
    }
}
#endif
