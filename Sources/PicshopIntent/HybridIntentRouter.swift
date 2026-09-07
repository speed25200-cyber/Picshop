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
        /// Maximum time to wait for the language model.
        public var llmTimeout: Duration
        /// Always consult the LLM (useful for evaluation / debugging).
        public var alwaysUseLLM: Bool

        public init(fastPathThreshold: Double = 0.85, llmTimeout: Duration = .seconds(6), alwaysUseLLM: Bool = false) {
            self.fastPathThreshold = fastPathThreshold
            self.llmTimeout = llmTimeout
            self.alwaysUseLLM = alwaysUseLLM
        }
    }

    public private(set) var preferredEngine: IntentEngineKind
    public var configuration: Configuration
    private let rules = RuleBasedIntentEngine()
    private var llmEngines: [IntentEngineKind: any IntentEngine] = [:]
    private var lastResolvedEngine: IntentEngineKind = .rules

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

        let timeout = configuration.llmTimeout
        let llmPlan: EditPlan? = await withTaskGroup(of: EditPlan?.self) { group in
            group.addTask {
                do {
                    return try await engine.plan(utterance, context: context)
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

        if let llmPlan, !llmPlan.isEmpty || llmPlan.needsClarification {
            lastResolvedEngine = llmPlan.engine
            return merge(fast: fast, llm: llmPlan)
        }
        lastResolvedEngine = .rules
        return fast
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

extension AmountParser {
    /// Whether the utterance contains an explicit number (used when merging plans).
    static func magnitudeHasExplicitNumber(_ utterance: String) -> Bool {
        magnitude(in: NormalizedUtterance(utterance)).explicitNumber != nil
    }
}
