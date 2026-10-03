import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class LLMPlanTests: XCTestCase {
    func testParsesCleanJSON() throws {
        let text = #"{"steps":[{"action":"removeObject","target":"dog","spatialHint":"left"}],"reply":"J'efface le chien.","clarification":null,"language":"fr"}"#
        let raw = try XCTUnwrap(LLMResponseParser.parse(text))
        XCTAssertEqual(raw.steps.count, 1)
        XCTAssertEqual(raw.reply, "J'efface le chien.")
        let plan = IntentNormalizer.plan(from: raw, utterance: "efface le chien à gauche", context: .photo, engine: .proLocal)
        XCTAssertEqual(plan.intents[0].action, .removeObject)
        XCTAssertEqual(plan.intents[0].target?.label, "dog")
        XCTAssertEqual(plan.intents[0].target?.spatialHint, .left)
        XCTAssertEqual(plan.engine, .proLocal)
    }

    func testParsesFencedAndChattyOutput() throws {
        let text = """
        Sure! Here is the plan:
        ```json
        {"steps": [{"action": "adjust", "parameter": "warmth", "amountMode": "relative", "amount": 20,}], "reply": "Warmer.", "language": "en",}
        ```
        """
        let raw = try XCTUnwrap(LLMResponseParser.parse(text))
        let intent = try XCTUnwrap(IntentNormalizer.normalize(raw.steps[0], context: .photo))
        XCTAssertEqual(intent.parameter, .temperature)
        XCTAssertEqual(intent.amount, .relative(0.2))
    }

    func testLooseSchemaWithArgumentsObject() throws {
        let text = #"{"actions":[{"name":"set_speed","arguments":{"speed":"0.5"}},{"type":"mute"}]}"#
        let raw = try XCTUnwrap(LLMResponseParser.parse(text))
        XCTAssertEqual(raw.steps.count, 2)
        let plan = IntentNormalizer.plan(from: raw, utterance: "slow motion and mute", context: .video, engine: .proLocal)
        XCTAssertEqual(plan.intents.map(\.action), [.setSpeed, .mute])
        XCTAssertEqual(plan.intents[0].amount, .absolute(0.5))
    }

    func testRejectsHallucinatedValues() {
        let step = RawIntentStep(action: "applyLook", look: "banana-vision")
        let intent = IntentNormalizer.normalize(step, context: .photo)
        XCTAssertEqual(intent?.look, nil)
        XCTAssertLessThan(intent?.confidence ?? 1, 0.6)
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "teleport"), context: .photo))
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "split", seconds: 3), context: .photo), "video actions are dropped in photo mode")
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "removeObject"), context: .photo), "removeObject needs a target")
    }

    func testPercentNormalisation() throws {
        let step = RawIntentStep(action: "adjust", parameter: "brightness", amountMode: "absolute", amount: 55)
        let intent = try XCTUnwrap(IntentNormalizer.normalize(step, context: .photo))
        XCTAssertEqual(intent.amount, .absolute(0.55))
    }

    /// Each planner names every action its editor can run, and none of another editor's (W1: a PDF
    /// planner no longer reads photo and video actions).
    func testPromptMentionsEveryActionOfItsEditor() {
        // `.operation` is never written by a model: catalog operations go by their own ids.
        XCTAssertFalse(IntentPrompt.actionList.contains("operation"))
        for mode in [EditorMode.photo, .video, .pdf] {
            let prompt = IntentPrompt.systemInstructions(mode: mode)
            let listed = Set(IntentPrompt.actionList(for: mode).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            XCTAssertFalse(listed.contains("operation"))
            for action in IntentAction.allCases where action != .operation {
                if action.isAllowed(in: mode) {
                    XCTAssertTrue(prompt.contains(action.rawValue), "\(mode) prompt is missing \(action.rawValue)")
                    XCTAssertTrue(listed.contains(action.rawValue), "\(mode) list is missing \(action.rawValue)")
                } else if action != .unknown {
                    XCTAssertFalse(listed.contains(action.rawValue), "\(mode) lists \(action.rawValue)")
                }
            }
        }
        XCTAssertTrue(IntentPrompt.systemInstructions(mode: .video).contains("VIDEO"))
    }

    /// The model session is reused across commands, so anything that changes
    /// while editing has to travel with the request or it goes stale.
    func testEditorStateTravelsWithTheRequestNotTheInstructions() {
        var context = IntentContext.video
        context.clipCount = 3
        context.playheadSeconds = 12.5
        let instructions = IntentPrompt.systemInstructions(mode: .video)
        XCTAssertFalse(instructions.contains("12.5"))
        XCTAssertFalse(instructions.contains("3 clip"))
        let prompt = IntentPrompt.userPrompt(for: "coupe ici", context: context, hint: nil)
        XCTAssertTrue(prompt.contains("12.5"))
        XCTAssertTrue(prompt.contains("3 clip"))
        XCTAssertTrue(prompt.contains("coupe ici"))
        var pdf = IntentContext.pdf
        pdf.currentPage = 4
        XCTAssertTrue(IntentPrompt.userPrompt(for: "efface cette page", context: pdf, hint: nil).contains("page 4"))
    }

    func testRouterCachesRepeatedRequests() async {
        actor CallCounter {
            private(set) var value = 0
            func bump() { value += 1 }
        }
        struct CountingEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            let counter: CallCounter
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                await counter.bump()
                return EditPlan(utterance: utterance, intents: [EditIntent(action: .removeObject, target: ObjectTarget(label: "surfboard"))], confidence: 0.9, engine: .proLocal)
            }
        }
        let counter = CallCounter()
        let router = HybridIntentRouter(preferredEngine: .proLocal)
        await router.register(CountingEngine(counter: counter))
        _ = await router.plan("get rid of the surfboard", context: .photo)
        _ = await router.plan("get rid of the surfboard", context: .photo)
        let repeated = await counter.value
        XCTAssertEqual(repeated, 1, "the same words in the same state must not pay for inference twice")
        var moved = IntentContext.photo
        moved.lastParameter = .brightness
        _ = await router.plan("get rid of the surfboard", context: moved)
        let afterChange = await counter.value
        XCTAssertEqual(afterChange, 2, "a different editor state is a different request")
    }

    func testRouterFallsBackToRulesWhenNoLLM() async {
        let router = HybridIntentRouter(preferredEngine: .appleIntelligence)
        let plan = await router.plan("efface le chien", context: .photo)
        XCTAssertEqual(plan.engine, .rules)
        XCTAssertEqual(plan.intents[0].action, .removeObject)
        let engines = await router.availableEngines()
        XCTAssertEqual(engines, [.rules])
    }

    func testRouterUsesLLMForLowConfidence() async {
        struct StubEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                EditPlan(utterance: utterance, intents: [EditIntent(action: .removeObject, target: ObjectTarget(label: "surfboard"))], confidence: 0.9, engine: .proLocal)
            }
        }
        let router = HybridIntentRouter(preferredEngine: .proLocal)
        await router.register(StubEngine())
        let plan = await router.plan("get rid of the surfboard", context: .photo)
        XCTAssertEqual(plan.engine, .proLocal)
        let fast = await router.plan("efface le chien", context: .photo)
        XCTAssertEqual(fast.engine, .rules, "confident grammar results skip the model")
    }

    func testRouterTimesOut() async {
        struct SlowEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                try await Task.sleep(for: .seconds(5))
                return EditPlan(utterance: utterance, intents: [], engine: .proLocal)
            }
        }
        let router = HybridIntentRouter(preferredEngine: .proLocal, configuration: .init(llmTimeout: .milliseconds(100)))
        await router.register(SlowEngine())
        let start = Date()
        let plan = await router.plan("blah blah", context: .photo)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(plan.engine, .rules)
    }
}

extension LLMPlanTests {
    /// W0: the timeout is hard. An engine that never checks for cancellation (a task group
    /// would wait for it) still leaves the caller on time, with the grammar's plan.
    func testRouterTimeoutHoldsAgainstAnEngineThatIgnoresCancellation() async {
        struct StubbornEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                // Not cancellable: resumes only when the queue fires, 3 s later.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return EditPlan(utterance: utterance, intents: [EditIntent(action: .autoEnhance)], engine: .proLocal)
            }
        }
        let router = HybridIntentRouter(preferredEngine: .proLocal, configuration: .init(llmTimeout: .milliseconds(150)))
        await router.register(StubbornEngine())
        // The lazy catalog and index are built before the deadline race (the app prewarms them);
        // in a test process of its own (swift test --parallel) they must not count against it.
        OperationAbstention.prewarm()
        _ = OperationAbstention.capped(EditPlan.unknown("blah blah"), utterance: "blah blah", domain: .photo)
        let start = Date()
        let plan = await router.plan("blah blah", context: .photo)
        let elapsed = Date().timeIntervalSince(start)
        // The engine gives up after 3 s; the slack only absorbs a loaded CI runner.
        XCTAssertLessThan(elapsed, 0.15 + 0.6, "the answer comes at the timeout, not when the engine gives up")
        XCTAssertEqual(plan.engine, .rules)
    }

    /// W0: the cache keys on the document revision. A repeat in the same state is served from the
    /// cache; the same words after a change, and follow-ups ("encore"), are planned again.
    func testRouterCacheKeysOnTheDocumentRevision() async {
        actor CallCounter {
            private(set) var value = 0
            func bump() { value += 1 }
        }
        struct CountingEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            let counter: CallCounter
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                await counter.bump()
                return EditPlan(utterance: utterance, intents: [EditIntent(action: .removeObject, target: ObjectTarget(label: "surfboard"))], confidence: 0.9, engine: .proLocal)
            }
        }
        let counter = CallCounter()
        let router = HybridIntentRouter(preferredEngine: .proLocal)
        await router.register(CountingEngine(counter: counter))
        var context = IntentContext.photo
        context.documentRevision = 3
        _ = await router.plan("get rid of the surfboard", context: context)
        _ = await router.plan("get rid of the surfboard", context: context)
        var calls = await counter.value
        XCTAssertEqual(calls, 1, "same words, same revision: served from the cache")
        context.documentRevision = 4
        _ = await router.plan("get rid of the surfboard", context: context)
        calls = await counter.value
        XCTAssertEqual(calls, 2, "after a change the request is planned again")
        _ = await router.plan("get rid of the surfboard again", context: context)
        _ = await router.plan("get rid of the surfboard again", context: context)
        calls = await counter.value
        XCTAssertEqual(calls, 4, "a follow-up is never cached")
    }

    func testPlansThatUseRefsOrTapsAreNeverCached() {
        var tapped = EditIntent(action: .removeObject, target: ObjectTarget(label: "object"))
        tapped.target?.point = PSPoint(x: 0.4, y: 0.5)
        XCTAssertFalse(HybridIntentRouter.isCacheable(EditPlan(utterance: "efface ça", intents: [tapped])))
        XCTAssertFalse(HybridIntentRouter.isCacheable(EditPlan(utterance: "efface t3", intents: [EditIntent(action: .removeText, ref: .text(3))])))
        let layerCall = OperationCall("layerOpacity", args: ["ref": .string("l2"), "opacity": .number(50)])
        XCTAssertFalse(HybridIntentRouter.isCacheable(EditPlan(utterance: "calque 2 à 50 %", intents: [EditIntent(action: .operation, operation: layerCall)])))
        XCTAssertTrue(HybridIntentRouter.isCacheable(EditPlan(utterance: "plus chaud", intents: [EditIntent(action: .adjust, parameter: .temperature, amount: .relative(0.2))])))
        XCTAssertTrue(HybridIntentRouter.isFollowUp("encore un peu"))
        XCTAssertTrue(HybridIntentRouter.isFollowUp("pareil pour les autres"))
        XCTAssertTrue(HybridIntentRouter.isFollowUp("a bit more"))
        XCTAssertFalse(HybridIntentRouter.isFollowUp("efface le chien"))
    }

    /// W0: 'seek' is a timeline action and never a PDF step; movePage reads clipNumber = source, choiceIndex = destination.
    func testSeekIsNotAPDFAction() {
        XCTAssertFalse(IntentAction.seek.isAllowed(in: .pdf))
        XCTAssertTrue(IntentAction.seek.isAllowed(in: .video))
        XCTAssertFalse(IntentAction.operation.isAllowed(in: .photo), "operations are gated per call by the catalog")
    }
}

final class CandidateSelectorTests: XCTestCase {
    let a = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.05, y: 0.3, width: 0.2, height: 0.5), confidence: 0.9)
    let b = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.4, y: 0.35, width: 0.15, height: 0.4), confidence: 0.85)
    let c = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.7, y: 0.3, width: 0.25, height: 0.6), confidence: 0.8)

    func testSpatialSelection() {
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", spatialHint: .left)), .single(a))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", spatialHint: .right)), .single(c))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", spatialHint: .center)), .single(b))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", spatialHint: .largest)), .single(c))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", spatialHint: .smallest)), .single(b))
    }

    func testOrdinalAllAndAmbiguity() {
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", ordinal: 2)), .single(b))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", ordinal: -1)), .single(c))
        XCTAssertEqual(CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person", matchesAll: true)), .multiple([a, b, c]))
        if case .ambiguous(let options) = CandidateSelector.select(from: [a, b, c], for: ObjectTarget(label: "person")) {
            XCTAssertEqual(options.count, 3)
        } else {
            XCTFail("three similar people must be ambiguous")
        }
        let weak = ObjectCandidate(label: "person", boundingBox: .unit, confidence: 0.1)
        XCTAssertEqual(CandidateSelector.select(from: [weak], for: ObjectTarget(label: "person")), .none)
    }

    func testDecisiveMarginAndTapPoint() {
        let strong = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), confidence: 0.95)
        let faint = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3), confidence: 0.4)
        XCTAssertEqual(CandidateSelector.select(from: [strong, faint], for: ObjectTarget(label: "dog")), .single(strong))
        let tapped = ObjectTarget(label: "dog", point: PSPoint(x: 0.7, y: 0.7))
        XCTAssertEqual(CandidateSelector.select(from: [strong, faint], for: tapped), .single(faint))
    }
}
