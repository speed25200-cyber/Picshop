import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Abstention in both routers: a grammar plan for words that name an operation the grammar does not own
/// never takes the fast path; it reaches the model, or, without one, an honest "pas encore".
final class RouterAbstentionTests: XCTestCase {
    actor Recorder {
        private(set) var utterances: [String] = []
        func record(_ text: String) { utterances.append(text) }
    }

    struct RecordingEngine: IntentEngine {
        let kind: IntentEngineKind = .proLocal
        let recorder: Recorder
        func isAvailable() async -> Bool { true }
        func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
            await recorder.record(utterance)
            return EditPlan(utterance: utterance, intents: [EditIntent(action: .autoEnhance)], confidence: 0.85, engine: .proLocal)
        }
    }

    /// Utterances the probes show the grammar answering confidently and wrongly.
    static let unowned = ["mets le calque en mode produit", "applique une courbe en S légère", "désature les bleus", "ombres bleues et hautes lumières orangées",
                          "corrige la perspective", "baisse l'opacité du calque à 50 %", "fais la mise au point sur le chien"]

    func testUnownedOperationsReachTheModel() async throws {
        let named = Self.unowned.filter { OperationAbstention.namesUnownedOp($0, domain: .photo) != nil }
        try XCTSkipIf(named.isEmpty, "the abstention lexicon is not in yet")
        let recorder = Recorder()
        let router = HybridIntentRouter(preferredEngine: .proLocal)
        await router.register(RecordingEngine(recorder: recorder))
        for text in named { _ = await router.plan(text, context: .photo) }
        let asked = await recorder.utterances
        XCTAssertEqual(Set(asked), Set(named), "every utterance naming an unowned operation goes to the model")
    }

    static func context(_ domain: OpDomain) -> IntentContext {
        switch domain {
        case .photo: return .photo
        case .video: return OperationFixtures.videoContext
        case .pdf: return IntentContext(mode: .pdf, pageCount: 6, currentPage: 2)
        }
    }

    /// The audit's probes whose every right answer is a catalog operation the grammar does not own.
    static func unownedProbes() -> [Probe] {
        let catalog = OperationCatalog.shared
        return ProbeCorpus.all.filter { probe in
            guard !probe.gold.isEmpty else { return false }
            return probe.gold.allSatisfy { id in
                guard let spec = catalog.spec(OpID(id)), spec.domains.contains(probe.domain) else { return false }
                return spec.grammar != .owned
            }
        }
    }

    /// The acceptance on the whole probe corpus: every probe that names an unowned operation reaches
    /// the model (HybridIntentRouter) and never takes Live's fast lane.
    func testEveryUnownedProbeReachesTheModel() async throws {
        let probes = Self.unownedProbes()
        try XCTSkipIf(probes.isEmpty, "the catalog has no entries yet")
        let recorder = Recorder()
        let router = HybridIntentRouter(preferredEngine: .proLocal)
        await router.register(RecordingEngine(recorder: recorder))
        for probe in probes { _ = await router.plan(probe.text, context: Self.context(probe.domain)) }
        let asked = Set(await recorder.utterances)
        let skipped = probes.filter { !asked.contains($0.text) }.map { "\($0.domain) « \($0.text) »" }
        XCTAssertEqual(skipped, [], "\(skipped.count) of \(probes.count) unowned probes skipped the model")
        for probe in probes {
            let mode = Self.context(probe.domain).mode
            let grammar = RuleBasedIntentEngine().parse(probe.text, context: Self.context(probe.domain))
            let lane = LiveTurnRouter.route(probe.text, grammar: grammar, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: mode)
            if case .local = lane { XCTFail("\(probe.domain) « \(probe.text) » took the fast lane") }
        }
    }

    func testWithoutAModelTheAnswerIsHonest() async throws {
        let router = HybridIntentRouter(preferredEngine: .rules)
        for text in Self.unowned {
            guard let id = OperationAbstention.namesUnownedOp(text, domain: .photo) else { continue }
            let parsed = RuleBasedIntentEngine().parse(text, context: .photo)
            let plan = await router.plan(text, context: .photo)
            if OperationAbstention.capped(parsed, utterance: text, domain: .photo).confidence < parsed.confidence {
                XCTAssertTrue(plan.isEmpty, "\(text): no wrong edit")
                let title = OperationCatalog.shared.spec(id)?.title.fr ?? id.raw
                XCTAssertTrue(plan.reply?.contains(title) ?? false, "\(text): \(plan.reply ?? "")")
            }
        }
    }

    func testLiveNeverFastLanesSuchAnUtterance() throws {
        for text in Self.unowned {
            let grammar = RuleBasedIntentEngine().parse(text, context: .photo)
            let lane = LiveTurnRouter.route(text, grammar: grammar, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: .photo)
            if OperationAbstention.namesUnownedOp(text, domain: .photo) != nil {
                if case .local = lane { XCTFail("\(text) took the fast lane") }
            }
        }
        // An owned command keeps its fast lane.
        let warm = RuleBasedIntentEngine().parse("plus chaud", context: .photo)
        if case .local = LiveTurnRouter.route("plus chaud", grammar: warm, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: .photo) {} else {
            XCTFail("an owned instant command stays instant")
        }
    }

    func testTheReplyNamesTheOperationAndItsTool() {
        XCTAssertTrue(Replies.notByVoice("curves", french: true).contains("sans modèle"))
        XCTAssertTrue(Replies.notByVoice("curves", french: false).contains("without a model"))
        XCTAssertTrue(Replies.notByVoice("curves", french: true, modelTried: true).contains("Je n'ai pas réussi"))
    }
}
