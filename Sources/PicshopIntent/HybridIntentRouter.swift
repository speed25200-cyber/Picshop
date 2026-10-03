import Foundation
import PicshopCore

/// Chooses between the instant grammar and on-device language models.
///
/// Strategy:
/// 1. The rule engine always runs first (sub-millisecond). A confident,
///    fully-understood result is returned immediately.
/// 2. Otherwise the preferred LLM engine is asked, with the rule result as a
///    hint and a hard timeout. A valid LLM plan wins; on timeout/failure the
///    rule result (or `unknown`) is returned so the UI never hangs.
public actor HybridIntentRouter {
    public struct Configuration: Sendable {
        /// Rule confidence at or above which the LLM is skipped.
        public var fastPathThreshold: Double
        /// Maximum time to wait for the language model when the grammar
        /// produced nothing usable and the model is the only hope.
        public var llmTimeout: Duration
        /// Maximum time to wait when the grammar already has a usable plan and
        /// the model is only being asked to do better. Keeping this short is
        /// what stops an understood command from feeling slow.
        public var improveTimeout: Duration
        /// Always consult the LLM (useful for evaluation / debugging).
        public var alwaysUseLLM: Bool

        public init(fastPathThreshold: Double = 0.85, llmTimeout: Duration = .seconds(6),
                    improveTimeout: Duration = .seconds(2), alwaysUseLLM: Bool = false) {
            self.fastPathThreshold = fastPathThreshold
            self.llmTimeout = llmTimeout
            self.improveTimeout = improveTimeout
            self.alwaysUseLLM = alwaysUseLLM
        }
    }

    public private(set) var preferredEngine: IntentEngineKind
    public var configuration: Configuration
    private let rules = RuleBasedIntentEngine()
    private var llmEngines: [IntentEngineKind: any IntentEngine] = [:]
    private var lastResolvedEngine: IntentEngineKind = .rules
    private var cache: [CacheKey: EditPlan] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 24

    /// Identifies a request completely: the same words in the same editor state
    /// must plan to the same thing, and anything the plan can depend on has to
    /// be part of the key or a stale plan would be replayed. The document revision
    /// is the state: a repeat after any change (the first attempt applied) is
    /// planned again, so "encore" never replays a plan made for an older document.
    struct CacheKey: Hashable {
        let utterance: String
        let mode: EditorMode
        let revision: Int
        let clipCount: Int
        let pageCount: Int
        let currentPage: Int
        let playheadTenths: Int
        let lastParameter: String
        let lastDirection: Int
        let lastStep: String
        let selectedIndex: Int
        let adjustments: Adjustments

        init(utterance: String, context: IntentContext) {
            self.utterance = utterance.lowercased()
            mode = context.mode
            revision = context.documentRevision ?? -1
            clipCount = context.clipCount
            pageCount = context.pageCount
            currentPage = context.currentPage
            playheadTenths = Int((context.playheadSeconds * 10).rounded())
            lastParameter = context.lastParameter?.rawValue ?? ""
            lastDirection = context.lastAdjustmentDirection
            lastStep = context.lastIntent?.summary ?? ""
            selectedIndex = context.selectedIndex ?? -1
            adjustments = context.currentAdjustments
        }
    }

    /// Whether a request may be served from, or stored in, the plan cache. Never for a
    /// pending question, a follow-up ("encore", "pareil", "the others"), a tap, a scene
    /// ref or a selection: those plans depend on more than the words and the revision.
    static func isCacheable(_ utterance: String, context: IntentContext) -> Bool {
        guard context.pendingClarification == nil, !utterance.isEmpty else { return false }
        guard context.selectionMask == nil, !context.hasSelection || context.mode != .photo else { return false }
        return !isFollowUp(utterance)
    }

    /// Whether a planned result may be stored: plans that use refs, taps, regions or
    /// a candidate choice are tied to what is on screen right now.
    static func isCacheable(_ plan: EditPlan) -> Bool {
        !plan.intents.contains { intent in
            if intent.ref != nil || intent.region != nil || intent.target?.point != nil { return true }
            if intent.action == .chooseCandidate || intent.action == .unknown { return true }
            if let call = intent.operation, call.args.values.contains(where: Self.isPositional) { return true }
            return false
        }
    }

    private static func isPositional(_ value: OpValue) -> Bool {
        switch value {
        case .point, .box: return true
        case .string(let text): return isRefLike(text)
        case .list(let values): return values.contains(where: isPositional)
        case .number, .bool: return false
        }
    }

    /// "t3", "l2", "o1", "p4": a scene, layer, clip, page or markup id.
    static func isRefLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count >= 2, let first = trimmed.first, RefKind.allCases.contains(where: { $0.prefix == first }) else { return false }
        return trimmed.dropFirst().allSatisfy(\.isNumber)
    }

    /// Words that make a request lean on the previous one.
    static let followUpWords: [String] = [
        "encore", "pareil", "pareille", "idem", "aussi", "egalement", "trop", "les autres", "le reste", "la meme chose", "de meme",
        "refais", "recommence", "rebelote", "comme avant", "comme ca", "un peu plus", "un peu moins", "plus fort", "moins fort",
        "again", "same", "too", "also", "as well", "the others", "the rest", "more", "less", "too much", "a bit more", "a bit less", "redo it",
    ]

    static func isFollowUp(_ utterance: String) -> Bool {
        let folded = " " + utterance.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        return followUpWords.contains { folded.contains(" \($0) ") }
    }

    public init(preferredEngine: IntentEngineKind = .appleIntelligence, configuration: Configuration = Configuration()) {
        self.preferredEngine = preferredEngine
        self.configuration = configuration
    }

    public func register(_ engine: any IntentEngine) {
        llmEngines[engine.kind] = engine
    }

    public func setPreferredEngine(_ kind: IntentEngineKind) {
        preferredEngine = kind
    }

    /// Additive (Local Live, phase 1): the waits change with the preferred engine.
    public func setConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public func availableEngines() async -> [IntentEngineKind] {
        var result: [IntentEngineKind] = [.rules]
        for (kind, engine) in llmEngines where await engine.isAvailable() {
            result.append(kind)
        }
        return result
    }

    /// Kind of engine that produced the most recent plan.
    public var lastEngine: IntentEngineKind { lastResolvedEngine }

    public func plan(_ utterance: String, context: IntentContext) async -> EditPlan {
        let timer = PSTimer("intent.plan")
        defer { timer.log(category: .intent) }

        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = rules.parse(utterance, context: context)
        // Abstention: a grammar plan for words that name an operation the grammar does
        // not own ("mets le calque en mode produit") is capped below the fast path.
        let abstains = FeatureFlags.isOn(.catalogOps)
        let fast = abstains ? OperationAbstention.capped(parsed, utterance: trimmed, domain: context.mode.opDomain) : parsed
        let wasCapped = fast.confidence < parsed.confidence
        let unowned = abstains && wasCapped ? OperationAbstention.namesUnownedOp(trimmed, domain: context.mode.opDomain) : nil
        let fastIsGood = !fast.isEmpty && fast.confidence >= configuration.fastPathThreshold
        if fastIsGood && !configuration.alwaysUseLLM {
            lastResolvedEngine = .rules
            return fast
        }

        guard preferredEngine != .rules, let engine = llmEngines[preferredEngine], await engine.isAvailable() else {
            lastResolvedEngine = .rules
            // No model: an operation only the model can reach gets an honest answer, not the grammar's guess.
            if let unowned { return Self.notWithoutModel(unowned, utterance: trimmed, context: context, plan: fast) }
            return fast
        }

        // Repeating a command — said twice, or misheard the first time — must not
        // pay for inference again. Only exact repeats in the same editor state
        // (same document revision) hit, and never follow-ups, taps or refs.
        let key = CacheKey(utterance: trimmed, context: context)
        let cacheable = Self.isCacheable(trimmed, context: context)
        if cacheable, let cached = cache[key] {
            lastResolvedEngine = cached.engine
            return cached
        }

        // With a usable grammar plan in hand the model is only being asked to do
        // better, so it gets a short slot; when the grammar came up empty, or was
        // capped by abstention, it gets the full budget because it is the only
        // thing that can answer.
        // A grammar plan about a thing it has no word for ("efface le bidule") is a guess, not a plan.
        let namesUnknownThing = fast.intents.contains { intent in
            guard [.removeObject, .moveObject, .blurObject, .recolor].contains(intent.action), let label = intent.target?.label else { return false }
            return ObjectVocabulary.entry(forLabel: label) == nil
        }
        let hasUsableFast = !fast.isEmpty && fast.confidence >= 0.5 && !namesUnknownThing && !wasCapped
        let timeout = hasUsableFast ? configuration.improveTimeout : configuration.llmTimeout
        // A hard limit: Deadline answers on time even when the engine ignores cancellation
        // (a task group would wait for it to finish).
        let hint = fast
        let llmPlan: EditPlan? = await Deadline.race(timeout) {
            do {
                return try await engine.plan(utterance, context: context, hint: hint)
            } catch {
                PSLog.error("LLM planning failed: \(error)", category: .intent)
                return nil
            }
        }
        if llmPlan == nil {
            PSLog.info("\(preferredEngine.rawValue) gave no plan within \(timeout); keeping the grammar's", category: .intent)
        }

        if let llmPlan {
            var checked = Self.validated(llmPlan, for: context)
            if FeatureFlags.isOn(.catalogOps), checked.intents.count > 1 { checked.intents = PlanLinter.lint(checked.intents, utterance: trimmed).steps }
            if !checked.isEmpty || checked.needsClarification {
                lastResolvedEngine = checked.engine
                let merged = merge(fast: fast, llm: checked)
                if cacheable, Self.isCacheable(merged) { remember(merged, for: key) }
                return merged
            }
            // The model answered with something this editor cannot do: prefer the
            // grammar, and otherwise explain rather than executing a wrong plan.
            if fast.isEmpty, checked.reply != nil {
                lastResolvedEngine = checked.engine
                return checked
            }
        }
        lastResolvedEngine = .rules
        // The grammar's capped guess is not run in place of an operation it does not own.
        if let unowned { return Self.notWithoutModel(unowned, utterance: trimmed, context: context, plan: fast, modelTried: true) }
        return fast
    }

    /// The honest answer for an operation only the model can reach: not done, and where to do it.
    static func notWithoutModel(_ id: OpID, utterance: String, context: IntentContext, plan: EditPlan, modelTried: Bool = false) -> EditPlan {
        let french = (plan.language ?? context.preferredLanguage ?? "").hasPrefix("fr")
        var result = EditPlan.unknown(utterance)
        result.language = plan.language ?? context.preferredLanguage
        result.reply = Replies.notByVoice(id, french: french, modelTried: modelTried)
        return result
    }

    private func remember(_ plan: EditPlan, for key: CacheKey) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache[oldest] = nil
            }
        }
        cache[key] = plan
    }

    /// Drops every step the current editor cannot execute (a photo action inside
    /// a PDF, a timeline action on a photo…). Language models occasionally answer
    /// from the wrong mode; the executor must never see those steps.
    static func validated(_ plan: EditPlan, for context: IntentContext) -> EditPlan {
        let allowed = plan.intents.filter { $0.isAllowed(in: context.mode) }
        guard allowed.count != plan.intents.count else { return plan }
        var result = plan
        result.intents = allowed
        if allowed.isEmpty || allowed.allSatisfy({ $0.action == .unknown }) {
            let french = (plan.language ?? context.preferredLanguage ?? "").hasPrefix("fr")
            result.intents = [EditIntent(action: .unknown, confidence: 0)]
            result.confidence = 0
            result.clarification = nil
            switch context.mode {
            case .photo: result.reply = french ? "Cette commande n'existe pas pour une photo." : "That command isn't available for a photo."
            case .video: result.reply = french ? "Cette commande n'existe pas pour une vidéo." : "That command isn't available for a video."
            case .pdf: result.reply = french ? "Cette commande n'existe pas pour un PDF." : "That command isn't available for a PDF."
            }
        }
        return result
    }

    /// Prefers the LLM plan but keeps precise values from the grammar when the
    /// two agree on the action (numbers and quoted text are more reliable from rules).
    func merge(fast: EditPlan, llm: EditPlan) -> EditPlan {
        guard !fast.isEmpty, fast.intents.count == llm.intents.count else { return llm }
        var merged = llm
        for index in llm.intents.indices {
            let a = fast.intents[index]
            let b = llm.intents[index]
            guard a.action == b.action else { continue }
            var combined = b
            if a.action == .adjust, a.parameter == b.parameter, let amount = a.amount, amount.mode == .absolute || AmountParser.magnitudeHasExplicitNumber(fast.utterance) {
                combined.amount = amount
            }
            if a.action == .addText, let text = a.text, text.count >= (b.text?.count ?? 0) { combined.text = text }
            if a.timeRange != nil, b.timeRange == nil { combined.timeRange = a.timeRange }
            if a.time != nil, b.time == nil { combined.time = a.time }
            if a.target?.point != nil, b.target != nil, b.target?.point == nil { combined.target?.point = a.target?.point }
            merged.intents[index] = combined
        }
        merged.confidence = max(fast.confidence, llm.confidence)
        return merged
    }
}

extension EditIntent {
    /// Whether the editor can execute this step: the action's mode flags, and for a
    /// catalog operation the operation's domains (and the catalogOps kill switch).
    public func isAllowed(in mode: EditorMode) -> Bool {
        guard action == .operation else { return action.isAllowed(in: mode) }
        guard FeatureFlags.isOn(.catalogOps), let domains = operationDomains else { return false }
        return domains.contains(mode.opDomain)
    }
}

extension IntentAction {
    /// Whether an executor exists for this action in the given editor. `.operation` is
    /// allowed nowhere by its flags: `EditIntent.isAllowed(in:)` gates each call by the catalog.
    public func isAllowed(in mode: EditorMode) -> Bool {
        if self == .operation { return false }
        switch mode {
        case .photo: return !isVideoOnly && !isPDFOnly
        case .video: return !isPhotoOnly && !isPDFOnly
        case .pdf:
            // Seek, play and pause are timeline actions: meta, but never PDF steps.
            if isVideoOnly { return false }
            if isPDFOnly || isMeta { return true }
            switch self {
            case .addText, .removeText, .export, .share, .revert: return true
            default: return false
            }
        }
    }
}

extension AmountParser {
    /// Whether the utterance contains an explicit number (used when merging plans).
    static func magnitudeHasExplicitNumber(_ utterance: String) -> Bool {
        magnitude(in: NormalizedUtterance(utterance)).explicitNumber != nil
    }
}
