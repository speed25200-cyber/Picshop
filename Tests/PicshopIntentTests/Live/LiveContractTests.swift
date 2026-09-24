import Foundation
import XCTest
import PicshopCore
import PicshopIntent

// Compile-time guard for the frozen Live contract (local Live contract, section 5):
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

/// The smallest brain that uses the protocol's default capabilities.
private struct WordsOnlyBrain: LiveBrain {
    var kind: LiveBrainKind { .onDevice }
    func isAvailable() async -> Bool { true }
    func warmUp() async {}
    func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        AsyncThrowingStream {
            $0.yield(.started(model: "test"))
            $0.yield(.text("Ok."))
            $0.yield(.stats(LiveGenerationStats(model: "test", promptTokens: 1, cachedTokens: 0, generatedTokens: 1, firstTokenMs: 10, tokensPerSecond: 20)))
            $0.yield(.completed(.answered))
            $0.finish()
        }
    }
    func interrupt(turn: Int, spokenText: String) async {}
    func reset() async {}
}

/// Runs on the main actor, as LiveSession does.
@MainActor
private func exerciseEditorSide() async throws {
    let host = ContractHost()
    host.livePausePlayback()
    // Only the video editor plays: the default is false.
    XCTAssertFalse(host.liveIsPlaying)
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

    for brain in [WordsOnlyBrain() as any LiveBrain, LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: .photo)] {
        _ = brain.kind
        XCTAssertEqual(brain.capabilities, LiveBrainCapabilities.none)
        _ = await brain.isAvailable()
        await brain.warmUp()
        let turn = LiveUserTurn(id: 1, kind: .speech, text: "plus chaud", language: .french, image: nil, editorState: host.liveContextSummary())
        for try await event in brain.respond(to: turn, tools: handler) { _ = event }
        await brain.interrupt(turn: 1, spokenText: "")
        await brain.reset()
    }
}

final class LiveContractTests: XCTestCase {
    func testEditorSideOfTheContract() async throws {
        try await exerciseEditorSide()
    }

    func testPureSideOfTheContract() {
        var selector = BrainSelector()
        let kind: LiveBrainKind = selector.choose(.init(modelReady: true, onDeviceAvailable: true, thermalCritical: false, now: 0), excluding: [.onDevice])
        _ = selector.choose(.init(modelReady: false, onDeviceAvailable: true, now: 0))
        selector.recordFailure(kind, .timeout(stage: "first_token"), now: 0)
        selector.recordSuccess(kind)
        _ = selector.isOffForSession(.model)
        let problem: LiveProblem = BrainSelector.problem(for: .memoryPressure)
        _ = BrainSelector.errorName(.modelUnavailable("x"))
        _ = (BrainSelector.cooldown, BrainSelector.failureWindow, problem)
        for error in [LiveBrainError.modelNotReady, .modelUnavailable("x"), .memoryPressure, .timeout(stage: "turn"), .streamTruncated, .unavailable("x")] {
            _ = BrainSelector.problem(for: error)
        }
        for problem in [LiveProblem.noMicrophone, .noSpeechRecognition(language: "fr"), .refusal, .audioFailed, .voiceFailed, .notHearing, .brainTimeout,
                        .modelUnavailable, .unavailable("x")] {
            XCTAssertFalse(LiveLines.problem(problem, .french).isEmpty)
        }

        let capabilities = LiveBrainCapabilities(opensSession: true, seesImages: true, imageMaxPixel: 768, proposesIdeas: true)
        _ = (capabilities.opensSession, capabilities.seesImages, capabilities.imageMaxPixel, capabilities.proposesIdeas, LiveBrainCapabilities.none)
        let stats = LiveGenerationStats(model: "Qwen3.5 4B", promptTokens: 1, cachedTokens: 2, generatedTokens: 3, firstTokenMs: 4, tokensPerSecond: 5)
        _ = (stats.model, stats.promptTokens, stats.cachedTokens, stats.generatedTokens, stats.firstTokenMs, stats.tokensPerSecond)
        let events: [LiveBrainEvent] = [.started(model: "m"), .text("t"), .ideas([]), .stats(stats), .completed(.editApplied)]
        _ = events
        var route = LiveRoute()
        XCTAssertEqual(route.brain, .commands)
        route = LiveRoute(brain: .model, modelName: "Qwen3.5 4B")
        _ = (route.brain, route.modelName, LiveRoute.Brain.onDevice)
        _ = [LiveIdea.Source.heuristic, .onDevice, .model]
        _ = [LiveBrainKind.model, .onDevice, .local]

        var machine = LiveTurnMachine(options: .init(bargeInOnSpeaker: .safe, turnTaking: false))
        machine.setOptions(.init(bargeInOnSpeaker: .full, turnTaking: true))
        machine.setOptions(.init(bargeInOnSpeaker: .safe, turnTaking: true, externalEndpointing: true))
        _ = machine.handle(.transcript(TranscriptSnapshot(), grammar: nil, at: 0))
        _ = machine.handle(.utterance("plus chaud", at: 0))
        machine.noteAssistantSpoke("Ok", at: 0)
        let state = machine.state
        _ = (state.phase, state.paused, state.muted, state.turn, state.caption, state.brainOpen, state.toolsRunning,
             state.chunksQueued, state.spokenText, state.echoRisk, state.effectiveBargeIn)
        _ = (state.committedAt, state.queuedAt, state.lastChunkStartedAt, state.lastChunkWords, state.echoGateUntil)
        let effects: [LiveEffect] = [.turnTimedOut(1), .speakerStuck]
        _ = effects
        _ = (LiveTurnMachine.emptyHearingCap, LiveTurnMachine.externalEndpointCap, LiveTurnMachine.thinkingDeadline,
             LiveTurnMachine.queuedLineDeadline, LiveTurnMachine.echoTail, LiveTurnMachine.drainDeadline(words: 9))
        var options = LiveTurnMachine.Options(bargeInOnSpeaker: .safe, turnTaking: false)
        options.externalEndpointing = true
        _ = EndOfTurnDetector(parameters: .init()).parameters
        var vadParameters = VoiceActivityDetector.Parameters()
        vadParameters.maxSpeechRun = 8
        _ = VoiceActivityDetector(parameters: vadParameters).noiseFloorDB
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

        _ = LiveTurnRouter.route("plus chaud", grammar: EditPlan(utterance: "plus chaud", intents: []), brain: .model, ideasOnScreen: 3, jobRunning: false, fastLane: true)
        for key in LiveLineKey.allCases { XCTAssertFalse(LiveLines.line(key, .french).isEmpty) }
        _ = LiveLines.problem(.noSpeechRecognition(language: "fr-FR"), .english)
        _ = LiveLines.ideaApplied("Noir et blanc", .french)
        _ = LiveLines.filler(.french, avoiding: nil)
        _ = LiveLines.line(.greetingLooking, .french, mode: .video)
        for key in [LiveLineKey.greetingLocal, .greetingLooking, .refusal, .lostThread, .jobDone, .jobCancelled, .resume, .stopping, .running, .micRestarted,
                    .modelLoading] {
            _ = LiveLines.line(key, .english)
        }

        var latency = LatencyTracker()
        latency.mark(.speechEnd, at: 0, turn: 1)
        latency.record(stats: stats, turn: 1)
        _ = latency.stats(turn: 1)
        _ = latency.report(turn: 1)
        _ = latency.percentiles(.firstAudio)

        _ = LivePrompt.onDeviceInstructions(mode: .video)
        _ = LivePrompt.onDevicePrompt(LiveUserTurn(id: 1, kind: .speech, text: "plus chaud", language: .french, image: nil, editorState: LiveEditorState(mode: .photo, version: 1)))
        _ = LivePrompt.editorState(LiveEditorState(mode: .photo, version: 1))
        let definitions: [LiveToolDefinition] = LiveToolSchema.tools(for: .photo)
        _ = definitions.map { ($0.name, $0.description, $0.inputSchema) }
        _ = LiveToolDefinition(name: "undo", description: "", inputSchema: ["type": "object"])
        let use = RawToolUse(id: "call_1", name: "undo", rawInput: "{}")
        XCTAssertEqual(use.blockIndex, 0)
        _ = ToolInputValidator(mode: .photo).validate(use, context: .photo, grounding: .init())
        _ = ToolInputValidator(mode: .photo).steps(raw: [RawIntentStep(action: "autoEnhance")], context: .photo)
        _ = ToolResultEncoder.compactText(LiveToolResult(isError: false, payload: ["ok": true], changedDocument: false))
        _ = IdeaEngine.heuristic(LiveEditorState(mode: .photo, version: 0), dismissed: [], language: .french)
        _ = IdeaEngine.merge(current: [], incoming: [], dismissed: [], fill: [])

        // Live/Local
        let turn = LiveUserTurn(id: 2, kind: .sessionStart, text: "", language: .french, image: nil, editorState: LiveEditorState(mode: .photo, version: 1))
        _ = LocalLivePrompt.system(mode: .photo, size: .full)
        _ = LocalLivePrompt.system(mode: .video, size: .compact)
        let specs: [JSONValue] = LocalLivePrompt.toolSpecs(mode: .photo)
        _ = specs
        let examples: [LocalPromptExample] = LocalLivePrompt.examples(mode: .photo, size: .compact)
        _ = examples.map { ($0.user, $0.assistant, $0.toolName, $0.arguments, $0.toolResult) }
        _ = LocalPromptExample(user: "plus chaud", assistant: "Je réchauffe.", toolName: .applyEdits, arguments: ["steps": []], toolResult: "Done.")
        _ = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false)
        _ = LocalLivePrompt.sessionStartMessage(turn, imageAttached: true)
        _ = LocalLivePrompt.needsFreshLook(turn, versionsSinceLastLook: 0)
        let recap = LocalRecapInput(appliedEdits: [], lastExchanges: [], openQuestion: nil, lastLook: nil)
        _ = (recap.appliedEdits, recap.lastExchanges, recap.openQuestion, recap.lastLook)
        _ = LocalLivePrompt.recap(recap)
        _ = (LocalLivePrompt.Budgets.systemFull, LocalLivePrompt.Budgets.systemCompact, LocalLivePrompt.Budgets.userMessage,
             LocalLivePrompt.Budgets.editorDelta, LocalLivePrompt.Budgets.recap)
        _ = LocalPromptSize(rawValue: "full")
        let raw: RawToolUse = ToolArgumentCoercer.rawToolUse(id: "call_1", name: "undo", arguments: [:])
        _ = raw
        var filter = LocalOutputFilter()
        let pieces: [LocalOutputFilter.Piece] = filter.feed("Je réchauffe.") + filter.finish()
        for piece in pieces {
            switch piece {
            case .speech(let text): _ = text
            case .toolCall(let name, let arguments): _ = (name, arguments)
            case .malformed(let text): _ = text
            }
        }
    }

    func testStatedValues() throws {
        XCTAssertEqual(LiveToolName.allCases.map(\.rawValue), ["apply_edits", "undo", "compare_before_after", "propose_ideas"])
        XCTAssertEqual(LiveStepResult.Status.needsClarification.rawValue, "needs_clarification")
        XCTAssertEqual(LiveCaption(stable: "plus", volatile: "chaud").text, "plus chaud")
        XCTAssertEqual(IdeaSymbols.sanitize("trash"), "sparkles")
        XCTAssertEqual(IdeaSymbols.sanitize("crop"), "crop")

        XCTAssertEqual(BrainSelector.cooldown, 60)
        XCTAssertEqual(BrainSelector.failureWindow, 600)
        XCTAssertEqual(LiveTurnMachine.emptyHearingCap, 4)
        XCTAssertEqual(LiveTurnMachine.externalEndpointCap, 25)
        XCTAssertEqual(LiveTurnMachine.thinkingDeadline, 15)
        XCTAssertEqual(LiveTurnMachine.queuedLineDeadline, 4)
        XCTAssertEqual(LiveTurnMachine.echoTail, 0.6)
        XCTAssertEqual(LiveTurnMachine.drainDeadline(words: 9), 8, accuracy: 1e-9)
        XCTAssertEqual(VoiceActivityDetector.Parameters().maxSpeechRun, 8)
        XCTAssertFalse(LiveTurnMachine.Options(bargeInOnSpeaker: .safe, turnTaking: false).externalEndpointing)
        XCTAssertEqual(LiveBrainKind.model.rawValue, "model")
        XCTAssertEqual(LiveLines.line(.lostThread, .french), "Je perds le fil — tu peux redire ?")
        XCTAssertEqual(LiveLines.problem(.audioFailed, .french), "Le micro a décroché — je le relance.")
        XCTAssertEqual(LiveBrainCapabilities.none, LiveBrainCapabilities(opensSession: false, seesImages: false, imageMaxPixel: 0, proposesIdeas: false))
        XCTAssertEqual(LocalLivePrompt.Budgets.systemFull, 7_500)
        XCTAssertEqual(LocalLivePrompt.Budgets.systemCompact, 4_800)
        XCTAssertEqual(LocalPromptSize.full.rawValue, "full")
        XCTAssertEqual(LocalPromptSize.compact.rawValue, "compact")

        let value: JSONValue = ["b": 1, "a": [true, nil, 1.5, "x/\"y\""]]
        XCTAssertEqual(value.serialized(), #"{"a":[true,null,1.5,"x/\"y\""],"b":1}"#)
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
        XCTAssertEqual(value["b"]?.int, 1)

        let idea = LiveIdea(title: "Flouter le fond", why: "", symbol: "camera.aperture", steps: [RawIntentStep(action: "blurBackground", amount: 60)], source: .heuristic)
        let same = LiveIdea(title: "Blur the background", why: "", symbol: nil, steps: [RawIntentStep(action: "blurBackground", amount: 60)], source: .model)
        XCTAssertEqual(idea.id.count, 16)
        XCTAssertEqual(idea.id, same.id)
        XCTAssertNotEqual(idea.id, LiveIdea(title: "Améliorer", why: "", symbol: nil, steps: [RawIntentStep(action: "autoEnhance")], source: .heuristic).id)
        XCTAssertEqual(LiveIdea(title: "Un deux trois quatre cinq", why: "", symbol: nil, steps: [], source: .heuristic).title, "Un deux trois quatre")
    }
}
