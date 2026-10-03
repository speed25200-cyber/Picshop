import Foundation
import PicshopCore

/// Keeps the grammar from answering confidently when the request is not what it parsed:
/// such plans are capped at 0.5, so the routers hand them to the model (or, without one,
/// answer honestly with the nearest operation) instead of running a wrong edit.
///
/// A plan is capped when, in its editor:
/// 1. the words name an operation the grammar does not own: a trigger of a catalog operation
///    with `grammar: .none` that no grammar-owned operation shares ("courbe en S", "opacité",
///    "mode produit", "perspective"), a colour band said as a group ("désature les bleus"),
///    or a tonal range with a tint ("ombres bleues");
/// 2. the words name an operation planned for a later wave ("yeux rouges", "keyframe",
///    "filigrane"), which the grammar can only get wrong today;
/// 3. the grammar's action is not offered in this editor by the catalog (selectiveAdjust on a video);
/// 4. retrieval disagrees clearly: its best operation matches an exact multi-word trigger,
///    and the grammar's operations score under half of it ("agrandis la toile" → expandCanvas,
///    not upscale; "zoom lent" → kenBurns, not the viewer zoom).
/// Undo, redo, confirm, cancel, compare and choices are never capped.
public enum OperationAbstention {
    /// The confidence a capped plan keeps.
    public static let cappedConfidence: Double = 0.5
    /// Rule 4: the grammar's best operation scores at most this share of retrieval's best.
    public static let disagreementRatio = 0.45

    /// Why a plan is capped.
    public enum Reason: Sendable, Equatable {
        case unownedOperation(OpID)
        case plannedOperation(String)
        case outsideDomain(IntentAction)
        case retrievalDisagrees(OpID)
    }

    /// Dialogue that is never second-guessed.
    static let neverCapped: Set<IntentAction> = [.undo, .redo, .revert, .confirm, .cancel, .compare, .chooseCandidate, .unknown]

    /// Builds the lazy statics the router reads before its model deadline (the catalog, the
    /// index and the per-editor lexicons, about 60 ms in a cold process), so the first command
    /// does not pay for them. Call it off the main thread; later calls cost nothing.
    public static func prewarm() {
        _ = OperationIndex.shared
        _ = sharedLexicon
    }

    public static func capped(_ plan: EditPlan, utterance: String, domain: OpDomain, index: OperationIndex = .shared) -> EditPlan {
        guard reason(for: plan, utterance: utterance, domain: domain, index: index) != nil else { return plan }
        var capped = plan
        capped.confidence = min(plan.confidence, cappedConfidence)
        capped.intents = plan.intents.map { intent in
            var copy = intent
            copy.confidence = min(intent.confidence, cappedConfidence)
            return copy
        }
        return capped
    }

    /// Why the plan would be capped; nil when it stands.
    public static func reason(for plan: EditPlan, utterance: String, domain: OpDomain, index: OperationIndex = .shared) -> Reason? {
        guard plan.confidence > cappedConfidence, plan.clarification == nil else { return nil }
        let acting = plan.intents.filter { !neverCapped.contains($0.action) }
        guard !acting.isEmpty else { return nil }
        let stems = TextFolding.stems(utterance)
        if let id = unownedOperation(stems, tokens: TextFolding.tokens(utterance), domain: domain, catalog: index.catalog) { return .unownedOperation(id) }
        if let phrase = planned(TextFolding.tokens(utterance), domain: domain) { return .plannedOperation(phrase) }
        for intent in acting where intent.action != .operation {
            if let spec = index.catalog.spec(lowering: intent.action), !spec.domains.contains(domain) { return .outsideDomain(intent.action) }
        }
        let language = NormalizedUtterance(utterance).language
        let ranking = index.ranking(OperationQuery(text: utterance, domain: domain, language: language))
        guard let best = ranking.first, OperationIndex.passes(best, OperationIndex.threshold), index.hasPhraseMatch(best.id, stems: stems),
              let bestSpec = index.catalog.spec(best.id), bestSpec.grammar != .keywordsOnly else { return nil }
        let grammarOps = Set(acting.compactMap { index.catalog.spec(lowering: $0.action)?.id })
        guard !grammarOps.contains(best.id) else { return nil }
        let grammarBest = ranking.filter { grammarOps.contains($0.id) }.map(\.score).max() ?? 0
        return grammarBest <= disagreementRatio * best.score ? .retrievalDisagrees(best.id) : nil
    }

    /// The catalog operation the utterance names that the grammar does not own, if any.
    public static func namesUnownedOp(_ utterance: String, domain: OpDomain) -> OpID? {
        unownedOperation(TextFolding.stems(utterance), tokens: TextFolding.tokens(utterance), domain: domain, catalog: .shared)
    }

    static func unownedOperation(_ stems: [String], tokens: [String], domain: OpDomain, catalog: OperationCatalog) -> OpID? {
        let isShared = catalog.specs.map(\.id) == OperationCatalog.shared.specs.map(\.id)
        let lexicon = isShared ? sharedLexicon[domain] ?? [] : Self.lexicon(domain, catalog: catalog)
        var best: (id: OpID, length: Int)?
        for entry in lexicon where OperationIndex.Document.contains(stems, entry.stems) {
            if best == nil || entry.stems.count > best!.length { best = (entry.id, entry.stems.count) }
        }
        if let best { return best.id }
        let slots = SlotExtractor.extract(tokens: tokens)
        let notOwned = catalog.specs(in: domain).filter { $0.grammar == .none }
        if !slots.bands.isEmpty, let spec = notOwned.first(where: { $0.params.contains { $0.key == "band" } }) { return spec.id }
        if !slots.tintedRanges.isEmpty, let spec = notOwned.first(where: { $0.params.contains { $0.key == "range" } }) { return spec.id }
        return nil
    }

    /// Matched on folded words, not stems: "cherchable" must not catch "cherche".
    static func planned(_ tokens: [String], domain: OpDomain) -> String? {
        for (phrase, phraseTokens) in plannedLexicon[domain] ?? [] where OperationIndex.Document.contains(tokens, phraseTokens) { return phrase }
        return nil
    }

    // MARK: Lexicons

    /// Triggers of the operations the grammar does not own, minus any phrase a grammar-owned
    /// operation of the editor also lists ("calque" stays with duplicateLayer).
    static func lexicon(_ domain: OpDomain, catalog: OperationCatalog) -> [(stems: [String], id: OpID)] {
        let specs = catalog.specs(in: domain)
        var owned: Set<[String]> = []
        for spec in specs where spec.grammar != .none {
            for trigger in OpLanguage.allCases.flatMap({ spec.triggers[$0] ?? [] }) { owned.insert(TextFolding.stems(trigger)) }
        }
        var entries: [(stems: [String], id: OpID)] = []
        for spec in specs where spec.grammar == .none {
            for trigger in OpLanguage.allCases.flatMap({ spec.triggers[$0] ?? [] }) {
                let stems = TextFolding.stems(trigger)
                guard !stems.isEmpty, !owned.contains(stems) else { continue }
                entries.append((stems, spec.id))
            }
        }
        return entries
    }

    static let sharedLexicon: [OpDomain: [(stems: [String], id: OpID)]] = {
        var lexicons: [OpDomain: [(stems: [String], id: OpID)]] = [:]
        for domain in OpDomain.allCases { lexicons[domain] = lexicon(domain, catalog: .shared) }
        return lexicons
    }()

    /// Operations planned for later waves (W2–W5): the grammar has no rule for them and maps their
    /// words to something else, so a plan that names one is never trusted.
    public static let plannedPhrases: [OpDomain: [String]] = [
        .photo: [
            "flou de mouvement", "motion blur", "flou gaussien", "gaussian blur", "flou radial", "tilt shift", "yeux rouges", "red eye", "colorise",
            "colorize", "colorie", "affine le visage", "slim the face", "agrandis les yeux", "bigger eyes", "liquify", "liquefier", "rectangle",
            "rectangles", "cercle", "cercles", "circle", "circles", "fleche", "fleches", "arrow", "arrows", "ombre portee", "drop shadow",
            "contour blanc", "contour noir", "outline", "bordure", "border",
            "filigrane", "filigranes", "watermark", "redimensionne", "redimensionner", "resize", "pixels de large", "pixels wide", "clone le", "clone the", "tampon de duplication",
            "clone stamp", "selectionne le sujet", "select the subject", "inverse la selection", "invert the selection", "fusionne les calques",
            "merge the layers", "merge layers", "aplatis", "flatten", "masque de fusion", "layer mask", "degrade", "gradient", "melangeur de couches", "channel mixer", "posterise", "posterize", "seuil", "threshold", "filtre photo", "photo filter",
        ],
        .video: [
            "keyframe", "keyframes", "image cle", "images cles", "incrustation", "incrustations", "picture in picture", "chroma key", "chroma", "fond vert sur",
            "sous titres en haut", "sous titres en bas", "position des sous titres", "captions at the top", "captions at the bottom",
            "le titre dure", "duree du titre", "title duration", "opacite", "opacity", "lut", "courbe", "courbes", "curves", "egaliseur",
            "equalizer", "compresseur", "compressor", "voix off enregistre", "export en prores", "prores", "gif",
        ],
        .pdf: [
            "filigrane", "filigranes", "watermark", "compresse", "compresser", "compress", "mot de passe", "password", "formulaire",
            "fill the form", "rogne les marges", "marges", "margins", "divise le pdf", "diviser le pdf", "split the pdf", "fleche", "fleches",
            "arrow", "dessine", "dessiner", "draw", "commentaire", "commentaires", "add a comment",
            "convertis en images", "convert to images", "cherchable", "searchable", "ocr", "en tete", "header", "pied de page", "footer",
            "tampon", "stamp", "bates",
        ],
    ]

    static let plannedLexicon: [OpDomain: [(String, [String])]] = {
        var lexicons: [OpDomain: [(String, [String])]] = [:]
        for (domain, phrases) in plannedPhrases {
            lexicons[domain] = phrases.map { ($0, TextFolding.tokens($0)) }.filter { !$0.1.isEmpty }
        }
        return lexicons
    }()
}

extension OperationIndex {
    /// Whether a trigger of two content words or more of the operation is in the words.
    func hasPhraseMatch(_ id: OpID, stems: [String]) -> Bool {
        documents.first { $0.spec.id == id }?.hasStrongPhrase(stems) ?? false
    }
}
