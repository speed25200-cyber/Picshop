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

    func testPromptMentionsEveryAction() {
        let prompt = IntentPrompt.systemInstructions(context: .video)
        for action in IntentAction.allCases {
            XCTAssertTrue(prompt.contains(action.rawValue), "prompt is missing \(action.rawValue)")
        }
        XCTAssertTrue(prompt.contains("VIDEO"))
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
            func plan(_ utterance: String, context: IntentContext) async throws -> EditPlan {
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
            func plan(_ utterance: String, context: IntentContext) async throws -> EditPlan {
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
