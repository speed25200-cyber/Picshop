import Foundation
import PicshopCore

/// State of the editor that makes some operations likelier (a table on the picture, captions on the timeline…).
public enum OpStateHint: String, Sendable, CaseIterable {
    case table, sceneText, selection, multipleLayers, captions, overlays, importedLUT, subject
    /// The photo has local adjustments (W2: `LiveEditorState.masks` is not empty).
    case localMasks
}

/// One retrieval request: the turn's words in its editor.
public struct OperationQuery: Sendable, Equatable {
    public var text: String
    public var domain: OpDomain
    public var language: NormalizedUtterance.Language
    public var hints: Set<OpStateHint>
    /// Operations used in the last turns, kept on the cards first.
    public var sticky: [OpID]
    /// State the caller does not know (its editor does not report it): an operation that needs it is
    /// never marked unavailable for its absence from `hints`.
    public var unknownState: Set<OpStateHint>

    public init(text: String, domain: OpDomain, language: NormalizedUtterance.Language, hints: Set<OpStateHint> = [], sticky: [OpID] = [],
                unknownState: Set<OpStateHint> = []) {
        self.text = text
        self.domain = domain
        self.language = language
        self.hints = hints
        self.sticky = sticky
        self.unknownState = unknownState
    }
}

/// One retrieved operation; `unavailable` says why it cannot run on this document now.
public struct RetrievedOperation: Sendable, Equatable {
    public var id: OpID
    public var score: Double
    public var unavailable: String?

    public init(id: OpID, score: Double, unavailable: String? = nil) {
        self.id = id
        self.score = score
        self.unavailable = unavailable
    }
}

/// Finds the catalog operations a turn is about, on the device and in well under a
/// millisecond per query:
/// - each operation is one document with fields: its id split on camelCase and its FR/EN
///   titles (×2), triggers (×3), example utterances (×2), summaries and enum values (×1);
/// - text is folded and stemmed by TextFolding; BM25F scores the content words;
/// - an exact multi-word trigger adds a bonus, an `avoid` phrase cuts the score;
/// - typed slots (%, seconds, page, ratio, colour, colour bands, tinted ranges) boost the
///   operations with a matching param; state hints are priors; the domain is a hard filter;
/// - an unmet requirement halves the score and marks the card unavailable;
/// - an optional sentence embedder is fused by reciprocal rank fusion (k = 60).
/// Below the threshold τ nothing is retrieved, so small talk brings no cards.
public struct OperationIndex: Sendable {
    public static let shared = OperationIndex()

    /// τ: the least score a retrieved operation needs, calibrated on small talk and the R lane.
    public static let threshold = 2.9
    /// Questions and opinions need more evidence before cards are added.
    public static let questionThreshold = 5.5
    /// The least cosine an embedder-only match needs.
    public static let embeddingThreshold: Float = 0.82

    public let catalog: OperationCatalog
    public let embedder: (any OperationEmbedder)?
    let documents: [Document]
    let documentFrequency: [String: Int]
    let averageLength: [Field: Double]
    let embeddings: EmbeddingCache?

    public init(catalog: OperationCatalog = .shared, embedder: (any OperationEmbedder)? = nil) {
        self.catalog = catalog
        self.embedder = embedder
        let stems = StemMemo()
        var documents: [Document] = []
        documents.reserveCapacity(catalog.specs.count)
        for (position, spec) in catalog.specs.enumerated() { documents.append(Document(spec: spec, position: position, stems: stems)) }
        var frequency: [String: Int] = [:]
        var totals: [Field: Int] = [:]
        for document in documents {
            for term in Set(document.fields.values.flatMap(\.keys)) { frequency[term, default: 0] += 1 }
            for (field, length) in document.lengths { totals[field, default: 0] += length }
        }
        var average: [Field: Double] = [:]
        for field in Field.allCases { average[field] = max(1, Double(totals[field] ?? 0) / Double(max(1, documents.count))) }
        self.documents = documents
        self.documentFrequency = frequency
        self.averageLength = average
        self.embeddings = embedder.map { EmbeddingCache(embedder: $0, catalog: catalog) }
    }

    /// Non-core operations of the query's domain, sticky ones first; empty below the threshold τ.
    public func retrieve(_ query: OperationQuery, limit: Int) -> [RetrievedOperation] {
        guard limit > 0 else { return [] }
        let core = Set(OperationGate.core(for: query.domain, catalog: catalog).map(\.id))
        let threshold = Self.isQuestion(query.text) ? Self.questionThreshold : Self.threshold
        var picked: [RetrievedOperation] = []
        var seen: Set<OpID> = []
        func take(_ operation: RetrievedOperation) {
            guard picked.count < limit, !seen.contains(operation.id), !core.contains(operation.id) else { return }
            seen.insert(operation.id)
            picked.append(operation)
        }
        let whole = ranking(query)
        let byID = Dictionary(whole.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The last operations used, so "encore" or "pareil sur le clip 2" still finds them.
        for id in query.sticky.prefix(2) {
            guard let spec = catalog.spec(id), spec.domains.contains(query.domain) else { continue }
            take(byID[id] ?? RetrievedOperation(id: id, score: 0, unavailable: Self.unavailable(spec, hints: query.hints, unknown: query.unknownState)))
        }
        // A quota per clause, so "courbe en S et opacité du calque à 50 %" shows both.
        let clauses = Self.clauses(query.text)
        if clauses.count > 1 {
            let quota = max(1, Int((Double(limit) / Double(clauses.count)).rounded(.up)))
            let perClause = clauses.map { clause -> [RetrievedOperation] in
                var copy = query
                copy.text = clause
                return ranking(copy).filter { Self.passes($0, threshold) && !core.contains($0.id) }.prefix(quota).map { $0 }
            }
            for rank in 0..<quota { for list in perClause where rank < list.count { take(list[rank]) } }
        }
        for operation in whole where Self.passes(operation, threshold) { take(operation) }
        if let embeddings, let fused = embeddings.fused(query, lexical: whole, catalog: catalog) {
            for operation in fused { take(operation) }
        }
        return picked
    }

    /// Whether the words are evidence enough: an operation the document cannot run now was halved
    /// for the ranking, but is still shown (marked unavailable) when the words name it.
    static func passes(_ operation: RetrievedOperation, _ threshold: Double) -> Bool {
        operation.score * (operation.unavailable == nil ? 1 : 2) >= threshold
    }

    /// The best operation of the whole domain (core included) and its margin over the next one,
    /// (best − second) / best; nil when nothing reaches τ.
    public func top(_ query: OperationQuery) -> (id: OpID, margin: Double)? {
        let scored = ranking(query)
        guard let best = scored.first, Self.passes(best, Self.threshold) else { return nil }
        let second = scored.count > 1 ? scored[1].score : 0
        return (best.id, (best.score - second) / best.score)
    }

    /// Every operation of the domain with a score above zero, best first (catalog order on ties),
    /// core included, below τ included. Unavailable ones carry their reason.
    public func ranking(_ query: OperationQuery) -> [RetrievedOperation] {
        let tokens = TextFolding.tokens(query.text)
        let stems = tokens.map(TextFolding.stem)
        let content = tokens.filter { !TextFolding.stopwords.contains($0) && $0 != "%" }.map(TextFolding.stem)
        let terms = Array(Set(content)).sorted()
        guard !terms.isEmpty else { return [] }
        let slots = SlotExtractor.extract(tokens: tokens)
        let disabled = OperationGate.disabled()
        var scored: [(RetrievedOperation, Int)] = []
        for document in documents where document.spec.domains.contains(query.domain) && !disabled.contains(document.spec.id) {
            var score = bm25(document, terms: terms)
            score += document.phraseBonus(stems, content: content)
            guard score > 0 else { continue }
            if document.avoided(stems) { score *= 0.3 }
            score *= Self.slotBoost(document.spec, slots: slots)
            score *= Self.prior(document.spec, hints: query.hints)
            let reason = Self.unavailable(document.spec, hints: query.hints, unknown: query.unknownState)
            if reason != nil { score *= 0.5 }
            scored.append((RetrievedOperation(id: document.spec.id, score: (score * 1_000).rounded() / 1_000, unavailable: reason), document.position))
        }
        scored.sort { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
        return scored.map(\.0)
    }

    // MARK: Scoring

    static let k1 = 1.2
    static let b = 0.75

    func bm25(_ document: Document, terms: [String]) -> Double {
        let count = Double(documents.count)
        var score = 0.0
        for term in terms {
            var weighted = 0.0
            for field in Field.allCases {
                guard let frequency = document.fields[field]?[term] else { continue }
                let length = Double(document.lengths[field] ?? 0)
                let normalizer = 1 - Self.b + Self.b * length / (averageLength[field] ?? 1)
                weighted += field.weight * Double(frequency) / normalizer
            }
            guard weighted > 0 else { continue }
            let frequency = Double(documentFrequency[term] ?? 0)
            let idf = log(1 + (count - frequency + 0.5) / (frequency + 0.5))
            score += idf * weighted / (Self.k1 + weighted)
        }
        return score
    }

    /// Typed values said boost the operations with a parameter of that type.
    static func slotBoost(_ spec: OperationSpec, slots: OperationSlots) -> Double {
        guard !slots.isEmpty else { return 1 }
        var boost = 1.0
        let kinds = spec.params.map(\.kind)
        func hasUnit(_ units: Set<OpUnit>) -> Bool {
            kinds.contains { kind in
                if case .number(_, let unit) = kind { return units.contains(unit) }
                return false
            }
        }
        if slots.units.contains(.percent), hasUnit([.percent, .signedPercent]) { boost *= 1.1 }
        if slots.units.contains(.seconds), hasUnit([.seconds]) { boost *= 1.15 }
        if slots.units.contains(.degrees), hasUnit([.degrees]) { boost *= 1.15 }
        if slots.units.contains(.multiplier), hasUnit([.multiplier]) { boost *= 1.15 }
        if slots.page != nil, spec.domains == [.pdf], spec.params.contains(where: { $0.key == "clipNumber" }) { boost *= 1.15 }
        if slots.ratio, spec.params.contains(where: { $0.key == "aspect" }) { boost *= 1.2 }
        if !slots.colors.isEmpty, kinds.contains(.color) { boost *= 1.1 }
        if !slots.bands.isEmpty, spec.params.contains(where: { $0.key == "band" }) { boost *= 1.6 }
        if !slots.tintedRanges.isEmpty, spec.params.contains(where: { $0.key == "range" }) { boost *= 1.6 }
        return boost
    }

    /// What the editor holds makes some operations likelier.
    static func prior(_ spec: OperationSpec, hints: Set<OpStateHint>) -> Double {
        var prior = 1.0
        if hints.contains(.table), spec.category == .table { prior *= 1.5 }
        if hints.contains(.sceneText), spec.category == .text { prior *= 1.2 }
        if hints.contains(.multipleLayers), spec.category == .layers { prior *= 1.3 }
        if hints.contains(.captions), spec.category == .captions { prior *= 1.3 }
        if hints.contains(.overlays), spec.category == .overlays { prior *= 1.3 }
        if hints.contains(.importedLUT), spec.requires.importedLUT { prior *= 1.3 }
        if hints.contains(.selection), spec.requires.selection { prior *= 1.3 }
        if hints.contains(.subject), spec.requires.subject { prior *= 1.1 }
        if hints.contains(.localMasks), spec.requires.localMask { prior *= 1.3 }
        return prior
    }

    /// Why the operation cannot run on this document now, from what the hints say is there.
    /// State in `unknown` is never held against an operation.
    static func unavailable(_ spec: OperationSpec, hints: Set<OpStateHint>, unknown: Set<OpStateHint> = []) -> String? {
        func missing(_ hint: OpStateHint) -> Bool { !hints.contains(hint) && !unknown.contains(hint) }
        if spec.requires.importedLUT, missing(.importedLUT) { return "no LUT imported" }
        if spec.requires.nonBaseLayer, missing(.multipleLayers) { return "only the photo layer" }
        if spec.requires.table, missing(.table) { return "no table on the picture" }
        if spec.requires.captions, missing(.captions) { return "no captions yet" }
        if spec.requires.selection, missing(.selection) { return "nothing selected" }
        if spec.requires.localMask, missing(.localMasks) { return "no mask yet" }
        return nil
    }

    // MARK: Text

    /// Clauses split on et, puis, mais, then, and commas (UtteranceSegmenter keeps "noir et blanc").
    static func clauses(_ text: String) -> [String] {
        let pieces = UtteranceSegmenter.clauses(of: text).flatMap { UtteranceSegmenter.segments(of: NormalizedUtterance.normalize($0)) }
        return pieces.filter { !TextFolding.contentStems($0).isEmpty }
    }

    /// A question or an opinion, not a request ("tu penses quoi de…", "why is it…").
    static func isQuestion(_ text: String) -> Bool {
        let tokens = TextFolding.tokens(text)
        guard let first = tokens.first else { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        let openers: Set<String> = ["pourquoi", "comment", "quel", "quelle", "quels", "quelles", "combien", "est", "what", "why", "how", "which",
                                    "should", "do", "does", "would", "is", "are", "any", "qu"]
        if openers.contains(first) { return true }
        let joined = tokens.prefix(4).joined(separator: " ")
        return ["tu penses", "a ton avis", "t as une idee", "tu trouves", "qu est ce", "donne moi un conseil", "propose moi", "what do you",
                "do you think"].contains { joined.hasPrefix($0) }
    }
}

// MARK: - Documents

extension OperationIndex {
    enum Field: Int, CaseIterable, Sendable {
        case title, triggers, examples, summary, values

        var weight: Double {
            switch self {
            case .triggers: return 3
            case .title, .examples: return 2
            case .summary, .values: return 1
            }
        }
    }

    /// One operation as the index reads it.
    struct Document: Sendable {
        let spec: OperationSpec
        let position: Int
        /// Term frequencies of the content stems, per field.
        let fields: [Field: [String: Int]]
        let lengths: [Field: Int]
        /// Multi-word triggers as stem sequences (stopwords kept), with their content-word count.
        let phrases: [(stems: [String], content: Int)]
        /// One-word triggers (one content word): a query that says only that word names the operation.
        let words: Set<String>
        let avoid: [[String]]

        /// `memo` keeps the stems across the catalog while the index is built.
        init(spec: OperationSpec, position: Int, stems memo: StemMemo) {
            let stem = memo.stem
            func contentStems(_ text: String) -> [String] {
                TextFolding.tokens(text).filter { !TextFolding.stopwords.contains($0) && $0 != "%" }.map(stem)
            }
            self.spec = spec
            self.position = position
            var texts: [Field: [String]] = [:]
            texts[.title] = [TextFolding.camelWords(spec.id.raw), spec.title.en, spec.title.fr]
            texts[.summary] = [spec.summary.en, spec.summary.fr]
            texts[.triggers] = OpLanguage.allCases.flatMap { spec.triggers[$0] ?? [] }
            texts[.examples] = spec.examples.filter { example in
                switch example.role {
                case .positive, .paraphrase: return true
                case .negative: return false
                }
            }.map(\.say)
            var values: [String] = []
            for param in spec.params {
                values.append(TextFolding.camelWords(param.key))
                if case .enumeration(let cases) = param.kind { values += cases.map(TextFolding.camelWords) }
                values += param.valueAliases.keys.sorted()
            }
            texts[.values] = values
            var fields: [Field: [String: Int]] = [:]
            var lengths: [Field: Int] = [:]
            for (field, strings) in texts {
                var counts: [String: Int] = [:]
                var length = 0
                for string in strings {
                    for stem in contentStems(string) {
                        counts[stem, default: 0] += 1
                        length += 1
                    }
                }
                fields[field] = counts
                lengths[field] = length
            }
            self.fields = fields
            self.lengths = lengths
            self.phrases = (texts[.triggers] ?? []).compactMap { trigger in
                let tokens = TextFolding.tokens(trigger)
                let content = contentStems(trigger).count
                guard tokens.count >= 2, content >= 1 else { return nil }
                return (tokens.map(stem), content)
            }
            self.words = Set((texts[.triggers] ?? []).compactMap { trigger in
                let content = contentStems(trigger)
                return content.count == 1 ? content[0] : nil
            })
            self.avoid = OpLanguage.allCases.flatMap { spec.avoid[$0] ?? [] }.map { TextFolding.tokens($0).map(stem) }.filter { !$0.isEmpty }
        }

        /// The best exact multi-word trigger in the query; or the query is exactly a one-word trigger ("niveaux").
        func phraseBonus(_ query: [String], content: [String]) -> Double {
            var best = 0.0
            for phrase in phrases where Self.contains(query, phrase.stems) {
                best = max(best, 1 + 0.75 * Double(phrase.content))
            }
            if best == 0, content.count == 1, words.contains(content[0]) { best = 1.5 }
            return best
        }

        /// A trigger of two content words or more is in the query: strong evidence for this operation.
        func hasStrongPhrase(_ query: [String]) -> Bool {
            phrases.contains { $0.content >= 2 && Self.contains(query, $0.stems) }
        }

        func avoided(_ query: [String]) -> Bool {
            avoid.contains { Self.contains(query, $0) }
        }

        /// Whether `needle` occurs as a contiguous run of `haystack`.
        static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
            guard !needle.isEmpty, haystack.count >= needle.count else { return false }
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                if Array(haystack[start..<(start + needle.count)]) == needle { return true }
            }
            return false
        }
    }
}

/// The stemmer's results while one index is built (the same words recur across the catalog).
final class StemMemo {
    private var stems: [String: String] = [:]

    func stem(_ token: String) -> String {
        if let known = stems[token] { return known }
        let stemmed = TextFolding.stem(token)
        stems[token] = stemmed
        return stemmed
    }
}

// MARK: - Embeddings

/// Operation vectors, computed on first use per language and kept (title, summary and examples).
final class EmbeddingCache: @unchecked Sendable {
    private let embedder: any OperationEmbedder
    private let lock = NSLock()
    private var vectors: [String: [OpID: [Float]]] = [:]
    private let texts: [(id: OpID, language: OpLanguage, text: String)]

    init(embedder: any OperationEmbedder, catalog: OperationCatalog) {
        self.embedder = embedder
        var texts: [(OpID, OpLanguage, String)] = []
        for spec in catalog.specs {
            for language in OpLanguage.allCases {
                let examples = spec.examples.filter { $0.language == language && $0.role == .positive }.map(\.say)
                texts.append((spec.id, language, ([spec.title(language), spec.summary(language)] + examples).joined(separator: ". ")))
            }
        }
        self.texts = texts
    }

    private func vectors(for language: NormalizedUtterance.Language) -> [OpID: [Float]] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = vectors[language.rawValue] { return cached }
        let opLanguage: OpLanguage = language == .french ? .fr : .en
        var computed: [OpID: [Float]] = [:]
        for entry in texts where entry.language == opLanguage {
            if let vector = embedder.vector(for: entry.text, language: language) { computed[entry.id] = vector }
        }
        vectors[language.rawValue] = computed
        return computed
    }

    /// The embedder's ranking fused with the lexical one (reciprocal rank fusion, k = 60): the
    /// fused order, keeping operations the lexical ranking found above τ or the embedder above its own threshold.
    func fused(_ query: OperationQuery, lexical: [RetrievedOperation], catalog: OperationCatalog) -> [RetrievedOperation]? {
        guard let queryVector = embedder.vector(for: query.text, language: query.language) else { return nil }
        let operations = vectors(for: query.language)
        var cosines: [(OpID, Float)] = []
        for spec in catalog.specs(in: query.domain) {
            guard let vector = operations[spec.id], vector.count == queryVector.count else { continue }
            cosines.append((spec.id, Self.cosine(queryVector, vector)))
        }
        guard !cosines.isEmpty else { return nil }
        cosines.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.raw < $1.0.raw }
        var fused: [OpID: Double] = [:]
        for (rank, operation) in lexical.enumerated() { fused[operation.id, default: 0] += 1 / Double(60 + rank + 1) }
        for (rank, entry) in cosines.enumerated() { fused[entry.0, default: 0] += 1 / Double(60 + rank + 1) }
        let lexicalByID = Dictionary(lexical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cosineByID = Dictionary(cosines, uniquingKeysWith: { first, _ in first })
        return fused.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.raw < $1.key.raw }.compactMap { id, _ in
            if let lexical = lexicalByID[id], OperationIndex.passes(lexical, OperationIndex.threshold) { return lexical }
            guard let cosine = cosineByID[id], cosine >= OperationIndex.embeddingThreshold, let spec = catalog.spec(id) else { return nil }
            return RetrievedOperation(id: id, score: OperationIndex.threshold, unavailable: OperationIndex.unavailable(spec, hints: query.hints))
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}

// MARK: - Flags (W2)

/// Which catalog operations the flags leave on: the mask operations follow `masks`, the selection ones
/// `aiSelection`. Off, they leave the cards, retrieval and the Foundation Models schema, and the photo core set
/// gets selectiveAdjust back in maskAdjust's place; their handlers answer « Pas encore activé sur cet iPhone. ».
public enum OperationGate {
    static let maskOperations: Set<OpID> = ["maskAdjust", "maskEdit", "maskDelete"]
    static let selectionOperations: Set<OpID> = ["select", "selectionModify", "selectionApply"]
    /// W3 (§8.3): the layer operations the LLM reaches behind `layerOps`; the ones that create v2-only state
    /// (groups, clipping, fill opacity, partial locks, gradients, layer masks, via copy/cut, merges) also need `proLayers`.
    static let layerOperations: Set<OpID> = ["addImageLayer", "layerVia", "addFillLayer", "fillLayer", "addAdjustmentLayer", "layerMask", "layerClip",
                                              "groupLayers", "mergeLayers", "layerTransform", "layerProperties"]
    static let proLayerOperations: Set<OpID> = ["layerVia", "addFillLayer", "fillLayer", "layerMask", "layerClip", "groupLayers", "mergeLayers",
                                                 "layerProperties"]

    /// `isOn` reads the flags (tests pass their own, so they never flip the shared defaults).
    public static func isEnabled(_ id: OpID, flags isOn: (FeatureFlag) -> Bool = FeatureFlags.isOn) -> Bool {
        if maskOperations.contains(id) { return isOn(.masks) }
        if selectionOperations.contains(id) { return isOn(.aiSelection) }
        if layerOperations.contains(id) {
            return isOn(.layerOps) && (!proLayerOperations.contains(id) || isOn(.proLayers))
        }
        if id == "recipe" { return isOn(.recipes) }
        if id == "exportPhoto" { return isOn(.layerOps) && isOn(.proExport) }
        return true
    }

    /// The operations the flags turn off now.
    public static func disabled() -> Set<OpID> {
        var off: Set<OpID> = []
        if !FeatureFlags.isOn(.masks) { off.formUnion(maskOperations) }
        if !FeatureFlags.isOn(.aiSelection) { off.formUnion(selectionOperations) }
        for id in layerOperations.union(["recipe", "exportPhoto"]) where !isEnabled(id) { off.insert(id) }
        return off
    }

    /// The domain's core set, in catalog order, as the flags leave it.
    public static func core(for domain: OpDomain, catalog: OperationCatalog = .shared, disabled off: Set<OpID>? = nil) -> [OperationSpec] {
        let off = off ?? disabled()
        let selectiveBack = domain == .photo && off.contains("maskAdjust")
        return catalog.specs.filter { spec in
            guard spec.domains.contains(domain) else { return false }
            if spec.coreIn.contains(domain) { return !off.contains(spec.id) }
            return selectiveBack && spec.id == "selectiveAdjust"
        }
    }
}
