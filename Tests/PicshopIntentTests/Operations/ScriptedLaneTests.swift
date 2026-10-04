import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The S lane: every catalog example, in every domain, as the model would write it, through the
/// coercer, the validator and the normalizer (Live's path for photo and video, the planner's for PDF),
/// then the executor on fake hosts, then the operation's structural postconditions. Must be 100 %.
final class ScriptedLaneTests: XCTestCase {
    struct Failure: CustomStringConvertible {
        var op: OpID
        var domain: OpDomain
        var say: String
        var stage: String
        var detail: String
        var description: String { "\(domain.rawValue) \(op.raw) « \(say) » — \(stage): \(detail)" }
    }

    /// The step object an example means: {"action": id, …its arguments}.
    static func stepObject(_ spec: OperationSpec, _ example: OpExample) -> JSONValue {
        OperationArguments.json(OperationCall(spec.id, args: example.args))
    }

    /// The examples that should run: positive and paraphrase, of the steps Live and the planner write, in
    /// each domain of the operation whose fields they use (a clip number is a video example, a ref a photo one).
    static func cases() -> [(OperationSpec, OpExample, OpDomain)] {
        OperationCatalog.shared.specs.flatMap { spec -> [(OperationSpec, OpExample, OpDomain)] in
            if case .intent(let action) = spec.lowering, LiveToolSchema.excluded.contains(action) { return [] }
            return spec.examples.filter { if case .negative = $0.role { return false } else { return true } }
                .flatMap { example in spec.domains.sorted { $0.rawValue < $1.rawValue }.filter { fits(example, in: $0, spec: spec) }.map { (spec, example, $0) } }
        }
    }

    static func fits(_ example: OpExample, in domain: OpDomain, spec: OperationSpec) -> Bool {
        guard spec.domains.count > 1, case .intent = spec.lowering else { return true }
        let keys = Set(example.args.keys)
        switch domain {
        case .photo: return keys.isDisjoint(with: LiveToolSchema.videoFields)
        case .video: return keys.isDisjoint(with: LiveToolSchema.photoFields)
        case .pdf: return keys.isDisjoint(with: LiveToolSchema.photoFields)
        }
    }

    /// Known host gaps, each refused honestly at the named stage (not a crash, not a silent no-op),
    /// owned by another lane. A gap that starts passing is fine; a new failure is not.
    /// None today: video straighten runs from the horizon (VideoHorizonDetecting) or the angle given.
    static let knownGaps: [(op: OpID, domain: OpDomain, stage: String, owner: String)] = []

    static func isKnownGap(_ failure: Failure) -> Bool {
        knownGaps.contains { $0.op == failure.op && $0.domain == failure.domain && $0.stage == failure.stage }
    }

    func testEveryCatalogExampleRunsAndPassesItsPostconditions() async throws {
        let cases = Self.cases()
        try XCTSkipIf(cases.isEmpty, "the catalog has no entries yet")
        var failures: [Failure] = []
        for (spec, example, domain) in cases {
            if let failure = await Self.run(spec, example, domain: domain), !Self.isKnownGap(failure) { failures.append(failure) }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(cases.count) examples fail:\n" + failures.map(\.description).joined(separator: "\n"))
    }

    static func run(_ spec: OperationSpec, _ example: OpExample, domain: OpDomain) async -> Failure? {
        func fail(_ stage: String, _ detail: String) -> Failure { Failure(op: spec.id, domain: domain, say: example.say, stage: stage, detail: detail) }
        let step = stepObject(spec, example)
        switch domain {
        case .photo:
            // W2: the poster with two masks (a1, a2) and a selection, so refs and the selection operations run.
            let document = OperationFixtures.photoWithMasks()
            let context = OperationFixtures.photoContext(document)
            let use = ToolArgumentCoercer.rawToolUse(id: "s", name: "apply_edits", arguments: ["steps": [step]])
            let grounding = ToolInputValidator.Grounding(imageAspect: 4.0 / 3.0, canvasAspect: 4.0 / 3.0)
            let call: LiveToolCall
            switch ToolInputValidator(mode: .photo).validate(use, context: context, grounding: grounding) {
            case .success(let valid): call = valid
            case .failure(let error): return fail("validator", "\(error) for \(use.rawInput)")
            }
            guard case .applyEdits(let intents) = call.tool, let intent = intents.first else { return fail("validator", "no step") }
            let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .english)
            let (after, result) = await executor.execute(intent, on: document, context: context)
            if let problem = problem(result, intent: intent) { return fail("executor", problem) }
            guard result.outcome.isSuccess else { return nil }
            // The executor's report (structural and, from W2, pixel postconditions on the fake host's probes).
            if let carried = OperationPostconditions.report(in: result.effects), !carried.failed.isEmpty {
                return fail("pixel postconditions", carried.failed.joined(separator: "; "))
            }
            let report = OperationPostconditions.check(intent, before: document, after: after)
            return report.failed.isEmpty ? nil : fail("postconditions", report.failed.joined(separator: "; "))
        case .video:
            let timeline = OperationFixtures.video()
            let context = OperationFixtures.videoContext
            let use = ToolArgumentCoercer.rawToolUse(id: "s", name: "apply_edits", arguments: ["steps": [step]])
            let call: LiveToolCall
            switch ToolInputValidator(mode: .video).validate(use, context: context) {
            case .success(let valid): call = valid
            case .failure(let error): return fail("validator", "\(error) for \(use.rawInput)")
            }
            guard case .applyEdits(let intents) = call.tool, let intent = intents.first else { return fail("validator", "no step") }
            let executor = VideoCommandExecutor(services: LaneVideoServices(), language: .english)
            let (after, result) = await executor.execute(intent, on: timeline, context: context)
            if let problem = problem(result, intent: intent) { return fail("executor", problem) }
            guard result.outcome.isSuccess else { return nil }
            let report = OperationPostconditions.check(intent, before: timeline, after: after)
            return report.failed.isEmpty ? nil : fail("postconditions", report.failed.joined(separator: "; "))
        case .pdf:
            // PDF has no Live conversation before W5: the planner lane (parser, normalizer).
            let document = OperationFixtures.pdf()
            let context = IntentContext(mode: .pdf, pageCount: 6, currentPage: 2)
            let json = JSONValue.object(["steps": .array([step])]).serialized()
            guard let raw = LLMResponseParser.parse(json) else { return fail("parser", json) }
            let plan = IntentNormalizer.plan(from: raw, utterance: example.say, context: context, engine: .proLocal)
            guard let intent = plan.intents.first, intent.action != .unknown, intent.isAllowed(in: .pdf) else { return fail("normalizer", json) }
            let hit = PDFTextHit(pageIndex: 1, rects: [PSRect(x: 0.2, y: 0.3, width: 0.1, height: 0.02)], text: "total")
            let signature = MediaAsset(kind: .image, relativePath: "/signature.png", pixelSize: PSSize(width: 900, height: 300))
            let executor = PDFCommandExecutor(services: FakePDFServices(hits: [hit], signature: signature), language: .english)
            let (after, result) = await executor.execute(intent, on: document, context: context)
            if let problem = problem(result, intent: intent) { return fail("executor", problem) }
            guard result.outcome.isSuccess else { return nil }
            let report = OperationPostconditions.check(intent, before: document, after: after)
            return report.failed.isEmpty ? nil : fail("postconditions", report.failed.joined(separator: "; "))
        }
    }

    /// A failure of the contract: the executor has no case for the step (its "not here" for the step's
    /// own summary, or the unsupported reason). A service the fake host does not have (transcription,
    /// scene cuts…), a question back or an info line are the fixture's limits, not the contract's.
    static func problem(_ result: ExecutionResult, intent: EditIntent) -> String? {
        if result.effects.contains(ExecutionReason.unsupported.effect) { return "unsupported: \(result.outcome)" }
        if case .failed(let message) = result.outcome, message == PicshopError.unsupportedOperation(intent.summary).message(french: false) {
            return "no executor case: \(message)"
        }
        return nil
    }

    func testTheLaneCoversEveryDomainAndTheNewOperations() throws {
        let cases = Self.cases()
        try XCTSkipIf(cases.isEmpty, "the catalog has no entries yet")
        let domains = Set(cases.map(\.2))
        XCTAssertEqual(domains, [.photo, .video, .pdf])
        let ops = Set(cases.map(\.0.id))
        for id in ["curves", "levels", "autoTone", "hsl", "colorGrade", "lutIntensity", "removeLUT", "perspective", "lensFocus",
                   "layerOpacity", "layerBlend", "layerVisibility", "layerOrder",
                   "maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"] as [OpID] where OperationCatalog.shared.spec(id) != nil {
            XCTAssertTrue(ops.contains(id), id.raw)
        }
    }
}

/// The video host of the S lane: the fixtures' dog, a transcript, a dialogue with two pauses and a
/// horizon tilted 2°, so captions, silence cuts and straighten run; the other magic tools keep their
/// "not here" (a fixture limit).
struct LaneVideoServices: VideoAIServices, VideoHorizonDetecting {
    let base = FakeVideoServices(candidates: [OperationFixtures.dog])

    func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate] {
        try await base.candidates(for: target, in: clip, timeline: timeline, at: time)
    }
    func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        try await base.removeObject(candidates: candidates, target: target, from: clip, timeline: timeline, progress: progress)
    }
    func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        try await base.stabilize(clip: clip, timeline: timeline, progress: progress)
    }
    func reverse(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        try await base.reverse(clip: clip, timeline: timeline, progress: progress)
    }
    func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        try await base.extractFrame(at: time, timeline: timeline)
    }
    func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        try await base.freezeFrame(at: time, duration: duration, timeline: timeline)
    }
    func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        try await base.subjectMatte(for: clip, timeline: timeline, progress: progress)
    }

    func transcribe(timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> (words: [CaptionWord], language: String?) {
        let words = "bienvenue dans ma cuisine aujourd'hui on fait des crêpes".split(separator: " ").enumerated().map { index, token in
            CaptionWord(text: String(token), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
        return (words, "fr-FR")
    }

    /// Speech everywhere but two 3-second pauses.
    func dialogueSignal(timeline: VideoTimeline) async throws -> AudioSignal {
        let rate = 8_000.0
        var samples = [Float](repeating: 0.0005, count: Int(timeline.duration * rate))
        for (start, end) in [(0.0, 10.0), (13.0, 25.0), (28.0, timeline.duration)] {
            for index in Int(start * rate)..<min(samples.count, Int(end * rate)) { samples[index] = Float(0.4 * sin(Double(index) * 0.07)) }
        }
        return AudioSignal(samples: samples, sampleRate: rate)
    }

    func horizonAngle(at time: Double, timeline: VideoTimeline) async throws -> Double? { 2.0 }
}
