import Foundation
import XCTest
import PicshopCore
import PicshopIntent

// Compile-time guard for the frozen Live contract (shared contract 6.2-6.6):
// every cross-owner symbol is used here through a plain, non-testable import,
// so a signature or access-level change breaks this file. The assertions only
// cover behaviour the contract states outright.

@MainActor
private final class ContractHost: LiveEditingHost {
    var revision = 3
    var liveSpeechSuppressed = false

    var liveMode: EditorMode { .photo }
    var liveVersion: Int { revision }
    var liveIsBusy: Bool { false }
    var liveProcessingProgress: Double? { nil }
    var livePendingChoice: LiveChoiceRequest? { nil }
    func liveIntentContext() -> IntentContext { .photo }
    func liveContextSummary() -> LiveEditorState { LiveEditorState(mode: .photo, version: revision) }
    func liveRun(_ intent: EditIntent) async -> LiveRunResult { LiveRunResult(outcome: .applied(label: "Enhance")) }
    func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] { [] }
    func liveCompareBeforeAfter(seconds: Double) {}
    func liveSnapshotImage(maxPixel: Int) async -> LiveImage? { nil }
    func liveHandleCommand(_ text: String) async -> LiveCommandReply { LiveCommandReply(text: text, isProblem: false, isError: false, language: "fr") }
    func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult { LiveRunResult(outcome: .ignored) }
    func liveCancelProcessing() -> Bool { false }
}

private struct ContractTransport: ClaudeTransport {
    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        (200, [:], Data())
    }
}

/// Runs on the main actor, as LiveSession does.
@MainActor
private func exerciseEditorSide() async throws {
    let host = ContractHost()
    host.livePausePlayback()
    let execution = await host.execute(steps: [])
    XCTAssertEqual(execution.version, 3)

    var ideas: [LiveIdea] = []
    let handler = EditorToolHandler(host: host, runningAfter: 2.5, onIdeas: { ideas = $0 }, onJobFinished: { _ in })
    handler.language = .english
    XCTAssertEqual(handler.context().mode, .photo)
    let result = await handler.perform(LiveToolCall(id: "toolu_1", tool: .undo(count: 1, redo: false, toOriginal: false)))
    _ = result.isError
    _ = await handler.runPlan(EditPlan(utterance: "", intents: []))
    let idea = LiveIdea(title: "Portrait doux", why: "", symbol: nil, steps: [RawIntentStep(action: "autoEnhance", amount: 70)], source: .heuristic)
    _ = await handler.runIdea(idea)
    _ = ideas

    for brain in [ClaudeLiveBrain(mode: .photo, apiKey: "", transport: ContractTransport()) as any LiveBrain,
                  LocalLiveBrain(router: HybridIntentRouter(), mode: .photo)] {
        _ = brain.kind
        _ = await brain.isAvailable()
        await brain.warmUp()
        let turn = LiveUserTurn(id: 1, kind: .speech, text: "plus chaud", language: .french, image: nil, editorState: host.liveContextSummary())
        for try await event in brain.respond(to: turn, tools: handler) { _ = event }
        await brain.interrupt(turn: 1, spokenText: "")
        await brain.reset()
    }
    let claude = ClaudeLiveBrain(mode: .video, apiKey: "k", transport: ContractTransport(), options: .init(), clock: SystemLiveClock(), log: { _ in })
    XCTAssertEqual(claude.kind, .claude)
    _ = await claude.secondsSinceLastRequest
}

final class LiveContractTests: XCTestCase {
    func testEditorSideOfTheContract() async throws {
        try await exerciseEditorSide()
    }

    func testPureSideOfTheContract() {
        var selector = BrainSelector()
        _ = selector.choose(.init(claudeAllowed: true, online: true, onDeviceAvailable: true, now: 0))
        selector.recordFailure(.rateLimited(retryAfter: 30), now: 0)
        selector.recordSuccess()
        selector.resetClaude()
        _ = selector.claudeDisabledReason

        var machine = LiveTurnMachine(options: .init(bargeInOnSpeaker: .safe, turnTaking: false))
        machine.setOptions(.init(bargeInOnSpeaker: .full, turnTaking: true))
        _ = machine.handle(.transcript(TranscriptSnapshot(), grammar: nil, at: 0))
        machine.noteAssistantSpoke("Ok", at: 0)
        let state = machine.state
        _ = (state.phase, state.paused, state.muted, state.turn, state.caption, state.brainOpen, state.toolsRunning,
             state.chunksQueued, state.spokenText, state.echoRisk, state.effectiveBargeIn)
        _ = EndOfTurnDetector(parameters: .init()).parameters
        _ = VoiceActivityDetector(parameters: .init()).noiseFloorDB
        _ = BargeInPolicy(parameters: .init())

        var accumulator = TranscriptAccumulator()
        accumulator.beginTurn(at: 0)
        _ = accumulator.apply(TranscriptSegment(text: "plus", start: 0, end: 0.4, isFinal: false))
        _ = accumulator.snapshot.wordCount

        var chunker = SpeechChunker(language: .french)
        _ = chunker.append("Je réchauffe l'image. ")
        _ = chunker.finish()
        _ = chunker.lastEndsWithQuestion
        _ = SpeakableText.clean("**Ok**")

        let voice = VoiceCandidate(identifier: "fr.thomas", name: "Thomas", language: "fr-FR", quality: .enhanced, isNovelty: false, isPersonalVoice: false)
        _ = VoiceSelector.best(for: "fr-FR", among: [voice], preferredIdentifier: nil, region: nil)
        _ = VoiceSelector.sorted([voice], language: "fr-FR")
        XCTAssertTrue(VoiceSelector.needsBetterVoiceHint(nil))
        XCTAssertTrue(VoiceCandidate.Quality.premium > .enhanced)

        _ = LiveTurnRouter.route("plus chaud", grammar: EditPlan(utterance: "plus chaud", intents: []), brain: .claude, ideasOnScreen: 3, jobRunning: false, fastLane: true)
        for key in LiveLineKey.allCases { XCTAssertFalse(LiveLines.line(key, .french).isEmpty) }
        _ = LiveLines.problem(.noSpeechRecognition(language: "fr-FR"), .english)
        _ = LiveLines.ideaApplied("Noir et blanc", .french)
        _ = LiveLines.filler(.french, avoiding: nil)

        var latency = LatencyTracker()
        latency.mark(.speechEnd, at: 0, turn: 1)
        latency.record(usage: ClaudeUsage(), bodyBytes: 0, turn: 1)
        _ = latency.report(turn: 1)
        _ = latency.percentiles(.firstAudio)

        _ = LivePrompt.system(mode: .photo)
        _ = LivePrompt.onDeviceInstructions(mode: .video)
        _ = ToolInputValidator(mode: .photo).steps(raw: [RawIntentStep(action: "autoEnhance")], context: .photo)
        _ = ToolResultEncoder.compactText(LiveToolResult(isError: false, payload: ["ok": true], changedDocument: false))
        _ = IdeaEngine.heuristic(LiveEditorState(mode: .photo, version: 0), dismissed: [], language: .french)
        _ = IdeaEngine.merge(current: [], incoming: [], dismissed: [], fill: [])
        _ = LiveCostEstimator.dollars(ClaudeUsage())
        _ = ClaudeRequestBuilder(options: ClaudeRequestOptions())
    }

    func testStatedValues() throws {
        XCTAssertEqual(ClaudeRequestOptions.model, "claude-opus-5")
        XCTAssertEqual(LiveToolName.allCases.map(\.rawValue), ["apply_edits", "undo", "compare_before_after", "propose_ideas"])
        XCTAssertEqual(LiveStepResult.Status.needsClarification.rawValue, "needs_clarification")
        XCTAssertEqual(LiveCaption(stable: "plus", volatile: "chaud").text, "plus chaud")
        XCTAssertEqual(IdeaSymbols.sanitize("trash"), "sparkles")
        XCTAssertEqual(IdeaSymbols.sanitize("crop"), "crop")

        let request = ClaudeRequestBuilder.keyCheckRequest(apiKey: "sk-ant-test")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, ClaudeRequestBuilder.modelURL)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 200, offline: false), .valid)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 401, offline: false), .invalid)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 402, offline: false), .noCredit)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 404, offline: false), .noAccess)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 429, offline: false), .rateLimited)
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: 529, offline: false), .server(529))
        XCTAssertEqual(ClaudeRequestBuilder.keyStatus(httpStatus: nil, offline: true), .offline)

        let key = "sk-ant-api03-" + String(repeating: "a", count: 40) + "A1b2"
        XCTAssertTrue(APIKeyFormat.looksValid(" \(key)\n"))
        XCTAssertFalse(APIKeyFormat.looksValid("sk-ant-admin01-" + String(repeating: "a", count: 40)))
        XCTAssertEqual(APIKeyFormat.mask(key), "sk-ant-...A1b2")
        XCTAssertEqual(APIKeyFormat.redact("key=\(key) end"), "key=sk-ant-... end")

        let value: JSONValue = ["b": 1, "a": [true, nil, 1.5, "x/\"y\""]]
        XCTAssertEqual(value.serialized(), #"{"a":[true,null,1.5,"x/\"y\""],"b":1}"#)
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
        XCTAssertEqual(value["b"]?.int, 1)

        let idea = LiveIdea(title: "Flouter le fond", why: "", symbol: "camera.aperture", steps: [RawIntentStep(action: "blurBackground", amount: 60)], source: .heuristic)
        let same = LiveIdea(title: "Blur the background", why: "", symbol: nil, steps: [RawIntentStep(action: "blurBackground", amount: 60)], source: .claude)
        XCTAssertEqual(idea.id.count, 16)
        XCTAssertEqual(idea.id, same.id)
        XCTAssertNotEqual(idea.id, LiveIdea(title: "Améliorer", why: "", symbol: nil, steps: [RawIntentStep(action: "autoEnhance")], source: .heuristic).id)
        XCTAssertEqual(LiveIdea(title: "Un deux trois quatre cinq", why: "", symbol: nil, steps: [], source: .heuristic).title, "Un deux trois quatre")
    }
}
