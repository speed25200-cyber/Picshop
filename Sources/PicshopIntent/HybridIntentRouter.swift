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
    /// be part of the key or a stale plan would be replayed.
    private struct CacheKey: Hashable {
        let utterance: String
        let mode: EditorMode
        let clipCount: Int
        let pageCount: Int
        let currentPage: Int
        let playheadTenths: Int
        let lastParameter: String
        let lastDirection: Int

        init(utterance: String, context: IntentContext) {
            self.utterance = utterance.lowercased()
            mode = context.mode
            clipCount = context.clipCount
            pageCount = context.pageCount
            currentPage = context.currentPage
            playheadTenths = Int((context.playheadSeconds * 10).rounded())
            lastParameter = context.lastParameter?.rawValue ?? ""
            lastDirection = context.lastAdjustmentDirection
        }
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
        let fast = rules.parse(utterance, context: context)
        let fastIsGood = !fast.isEmpty && fast.confidence >= configuration.fastPathThreshold
        if fastIsGood && !configuration.alwaysUseLLM {
            lastResolvedEngine = .rules
            return fast
        }

        guard preferredEngine != .rules, let engine = llmEngines[preferredEngine], await engine.isAvailable() else {
            lastResolvedEngine = .rules
            return fast
        }

        // Repeating a command — said twice, or misheard the first time — must not
        // pay for inference again. Only exact repeats in the same editor state hit.
        let key = CacheKey(utterance: trimmed, context: context)
        let cacheable = context.pendingClarification == nil && !trimmed.isEmpty
        if cacheable, let cached = cache[key] {
            lastResolvedEngine = cached.engine
            return cached
        }

        // With a usable grammar plan in hand the model is only being asked to do
        // better, so it gets a short slot; when the grammar came up empty it gets
        // the full budget because it is the only thing that can answer.
        let hasUsableFast = !fast.isEmpty && fast.confidence >= 0.5
        let timeout = hasUsableFast ? configuration.improveTimeout : configuration.llmTimeout
        let llmPlan: EditPlan? = await withTaskGroup(of: EditPlan?.self) { group in
            group.addTask {
                do {
                    return try await engine.plan(utterance, context: context, hint: fast)
                } catch {
                    PSLog.error("LLM planning failed: \(error)", category: .intent)
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let llmPlan {
            let checked = Self.validated(llmPlan, for: context)
            if !checked.isEmpty || checked.needsClarification {
                lastResolvedEngine = checked.engine
                let merged = merge(fast: fast, llm: checked)
                if cacheable { remember(merged, for: key) }
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
        return fast
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
        let allowed = plan.intents.filter { $0.action.isAllowed(in: context.mode) }
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

extension IntentAction {
    /// Whether an executor exists for this action in the given editor.
    public func isAllowed(in mode: EditorMode) -> Bool {
        switch mode {
        case .photo: return !isVideoOnly && !isPDFOnly
        case .video: return !isPhotoOnly && !isPDFOnly
        case .pdf:
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
