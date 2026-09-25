import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// The model brain's turn contract (contract §6 and §9 "Acceptance: Linux"),
// against a scripted engine: ordering, the tool loop and its limits, retries
// and the grammar fallback, pictures, compaction, cancellation, deadlines,
// thermal limits, and never any markup in speech.

final class LocalModelLiveBrainTests: XCTestCase {
    private func brain(_ factory: FakeEngineFactory, fallback: (any LiveBrain)? = nil, limits: LocalModelLiveBrain.Limits = .init(),
                       info: LocalModelInfo = .qwen4B, clock: BrainTestClock = BrainTestClock(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) -> LocalModelLiveBrain {
        LocalModelLiveBrain(mode: .photo, info: info, makeEngine: factory.factory, fallback: fallback, limits: limits, clock: clock, log: log)
    }

    // 1. .started, speech as .text, .stats, .completed.
    func testSpeechTurnOrder() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Belle "), .text("lumière !"), Say.done()]]])
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("tu aimes ?"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.kinds, ["started", "text", "text", "stats", "completed"])
        XCTAssertEqual(events.first, .started(model: "Qwen3.5 4B"))
        XCTAssertEqual(events.said, "Belle lumière !")
        XCTAssertEqual(events.end, .answered)
        guard case .stats(let stats) = events[events.count - 2] else { return XCTFail("stats before completed") }
        XCTAssertEqual(stats.model, "Qwen3.5 4B")
        XCTAssertEqual(stats.cachedTokens, 2_000)
        XCTAssertEqual(stats.generatedTokens, 12)
        assertSpeakable(events)
    }

    func testTheEngineStartsFromTheExamplesAndIsPreparedOnce() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Oui."), Say.done()], [.text("D'accord."), Say.done()]]])
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        _ = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1), tools: handler))
        _ = await drain(brain.respond(to: BrainTurns.speech("ok", id: 2), tools: handler))
        XCTAssertEqual(factory.engines.count, 1, "one engine, one KV cache, for the whole conversation")
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertEqual(engine.setup.system, LocalLivePrompt.system(mode: .photo, size: .full))
        XCTAssertEqual(engine.setup.tools, LocalLivePrompt.toolSpecs(mode: .photo))
        XCTAssertEqual(engine.setup.history, LocalModelLiveBrain.exampleHistory(mode: .photo, size: .full))
        XCTAssertEqual(engine.setup.imageMaxPixels, 196_608)
        XCTAssertEqual(engine.sent.count, 2)
    }

    func testExamplesBecomeRealHistory() {
        let examples = LocalLivePrompt.examples(mode: .photo, size: .full)
        let history = LocalModelLiveBrain.exampleHistory(mode: .photo, size: .full)
        let users = history.compactMap(\.userText)
        XCTAssertEqual(users, examples.map(\.user))
        for (index, example) in examples.enumerated() where example.toolName != nil {
            let calls = history.compactMap { message -> [LocalToolCall]? in
                if case .assistant(let text, let calls) = message, text == example.assistant { return calls }
                return nil
            }.first
            XCTAssertEqual(calls?.first?.name, example.toolName?.rawValue, "example \(index)")
        }
    }

    // 2. A clean structured apply_edits ends the turn, with no second generation; its result is owed.
    func testCleanEditEndsTheTurnAndOwesItsResult() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je réchauffe un peu."), Say.call("apply_edits", Say.warmer), Say.done()],
            [.text("Voilà."), Say.done()],
        ]])
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain.respond(to: BrainTurns.speech("rends-la plus chaude"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.kinds, ["started", "text", "toolStarted", "toolFinished", "stats", "completed"])
        XCTAssertEqual(events.end, .editApplied)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 1)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 1, "no second generation after a clean edit")

        _ = await drain(brain.respond(to: BrainTurns.speech("merci", id: 2, version: 11), tools: handler))
        let next = try XCTUnwrap(engine.sent.last)
        XCTAssertEqual(next.count, 2)
        XCTAssertTrue(next[0].isToolResult, "the owed result opens the next message")
        guard case .toolResult(let id, let name, _) = next[0] else { return XCTFail() }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "apply_edits")
        XCTAssertNotNil(next[1].userText)
    }

    func testCleanEditWithoutASentenceStillSaysSomething() async throws {
        let factory = FakeEngineFactory(scripts: [[[Say.call("apply_edits", Say.warmer), Say.done()]]])
        let (events, _) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: ScriptedToolHandler()))
        XCTAssertEqual(events.end, .editApplied)
        XCTAssertFalse(events.said.isEmpty, "a turn is never silent")
        XCTAssertEqual(factory.engines.first?.sent.count, 1)
    }

    // 3. needs_user / failed goes back to the model, which generates again.
    func testNeedsUserResultIsSentBackAndTheModelSpeaksAgain() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Say.warmer), Say.done()],
            [.text("Sélectionne la zone d'abord."), Say.done()],
        ]])
        let handler = ScriptedToolHandler()
        await MainActor.run { handler.stepStatus = .needsUser }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("floute le fond"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.said, "Sélectionne la zone d'abord.")
        XCTAssertEqual(events.end, .answered)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 2)
        XCTAssertEqual(engine.sent[1].count, 1)
        XCTAssertTrue(engine.sent[1][0].isToolResult)
        XCTAssertEqual(engine.options[1].maxTokens, engine.options[0].maxTokens)
    }

    /// A different failing step each round (identical ones are blocked, LocalTurnRepairTests).
    static func warmer(_ amount: Double) -> [LocalChatEvent] {
        [Say.call("apply_edits", ["steps": [["action": "adjust", "parameter": "temperature", "amount": .number(amount)]]]), Say.done()]
    }

    func testApplyEditsLimitEndsWithLoopLimit() async throws {
        let factory = FakeEngineFactory(scripts: [[Self.warmer(15), Self.warmer(20), Self.warmer(25), Self.warmer(30)]])
        let handler = ScriptedToolHandler()
        await MainActor.run { handler.stepStatus = .failed }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.end, .loopLimit)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 2, "maxApplyEdits: the third call never runs")
        XCTAssertFalse(events.said.isEmpty)
        assertSpeakable(events)
    }

    func testRoundLimitEndsWithLoopLimit() async throws {
        let factory = FakeEngineFactory(scripts: [[Self.warmer(15), Self.warmer(20), Self.warmer(25), Self.warmer(30)]])
        var limits = LocalModelLiveBrain.Limits()
        limits.maxApplyEdits = 10
        let handler = ScriptedToolHandler()
        await MainActor.run { handler.stepStatus = .failed }
        let (events, _) = await drain(brain(factory, limits: limits).respond(to: BrainTurns.speech("plus chaud"), tools: handler))
        XCTAssertEqual(events.end, .loopLimit)
        XCTAssertEqual(factory.engines.first?.sent.count, 3, "maxRounds generations in all")
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 3)
    }

    // 4. Invalid arguments: an error result and one retry; still invalid with nothing said, the grammar answers.
    func testInvalidCallIsRetriedOnceThenForwardedToTheGrammar() async throws {
        let invalid: [LocalChatEvent] = [Say.call("apply_edits", Say.invalidSteps), Say.done()]
        let factory = FakeEngineFactory(scripts: [[invalid, invalid]])
        let fallback = FakeFallbackBrain()
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain(factory, fallback: fallback).respond(to: BrainTurns.speech("téléporte le chien"), tools: handler))
        XCTAssertNil(error)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 2, "one retry")
        let retry = try XCTUnwrap(engine.sent.last?.first?.toolResultContent)
        XCTAssertTrue(retry.hasPrefix("Invalid input"), retry)
        let forwarded = await fallback.turns
        XCTAssertEqual(forwarded.map(\.text), ["téléporte le chien"])
        XCTAssertEqual(events.said, "Réponse des commandes.")
        XCTAssertEqual(events.end, .answered)
        XCTAssertEqual(events.filter { if case .started = $0 { return true } else { return false } }.count, 1, "one .started")
        XCTAssertTrue(events.kinds.contains("stats"))
        let calls = await handler.calls
        XCTAssertTrue(calls.isEmpty, "an invalid call never reaches the editor")
    }

    func testInvalidCallFixedOnRetryRuns() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Say.invalidSteps), Say.done()],
            [.text("Je réchauffe."), Say.call("apply_edits", Say.warmer, id: "call_2"), Say.done()],
        ]])
        let fallback = FakeFallbackBrain()
        let handler = ScriptedToolHandler()
        let (events, _) = await drain(brain(factory, fallback: fallback).respond(to: BrainTurns.speech("plus chaud"), tools: handler))
        XCTAssertEqual(events.end, .editApplied)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 1)
        let forwarded = await fallback.turns
        XCTAssertTrue(forwarded.isEmpty)
    }

    func testInvalidAfterSpeakingIsNotForwarded() async throws {
        let invalid: [LocalChatEvent] = [.text("Je m'en occupe."), Say.call("apply_edits", Say.invalidSteps), Say.done()]
        let factory = FakeEngineFactory(scripts: [[invalid, invalid]])
        let fallback = FakeFallbackBrain()
        let (events, _) = await drain(brain(factory, fallback: fallback).respond(to: BrainTurns.speech("fais un truc"), tools: ScriptedToolHandler()))
        let forwarded = await fallback.turns
        XCTAssertTrue(forwarded.isEmpty, "the user already heard the model: no second voice")
        XCTAssertEqual(events.end, .loopLimit)
    }

    func testEmptyAnswerGoesToTheGrammar() async throws {
        let factory = FakeEngineFactory(scripts: [[[Say.done()]]])
        let fallback = FakeFallbackBrain()
        let (events, error) = await drain(brain(factory, fallback: fallback).respond(to: BrainTurns.speech("hein"), tools: ScriptedToolHandler()))
        XCTAssertNil(error)
        XCTAssertEqual(events.said, "Réponse des commandes.")
    }

    // 5. A call leaked as text is recovered by the filter and run; none of its markup is spoken.
    func testLeakedToolCallIsRecoveredAndNeverSpoken() async throws {
        try XCTSkipUnless(outputFilterIsReal(), "LocalOutputFilter is still P's phase 0 pass-through")
        let leaked = "<tool_call>\n<function=undo>\n<parameter=count>\n1\n</parameter>\n</function>\n</tool_call>"
        var deltas: [LocalChatEvent] = [.text("Je reviens "), .text("en arrière.")]
        var index = leaked.startIndex
        while index < leaked.endIndex {
            let end = leaked.index(index, offsetBy: 5, limitedBy: leaked.endIndex) ?? leaked.endIndex
            deltas.append(.text(String(leaked[index..<end])))
            index = end
        }
        deltas.append(Say.done())
        let factory = FakeEngineFactory(scripts: [[deltas]])
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("c'est trop"), tools: handler))
        XCTAssertNil(error)
        let names = await handler.toolNames
        XCTAssertEqual(names, [.undo])
        XCTAssertEqual(events.said.trimmingCharacters(in: .whitespacesAndNewlines), "Je reviens en arrière.")
        XCTAssertFalse(events.said.contains("<"))
        assertSpeakable(events)
    }

    // 13. Whatever the filter does, markup never reaches the voice.
    func testMarkupNeverReachesTheVoice() async throws {
        let factory = FakeEngineFactory(scripts: [[[
            .text("D'accord. "), .text("<think>"), .text("</think>"), .text("<tool_call>"), .text("<function=undo>"),
            .text("</function></tool_call>"), .text("<|im_end|>"), Say.done(),
        ]]])
        let (events, _) = await drain(brain(factory, fallback: FakeFallbackBrain()).respond(to: BrainTurns.speech("annule"), tools: ScriptedToolHandler()))
        assertSpeakable(events)
        XCTAssertFalse(events.said.contains("<"))
        XCTAssertFalse(events.said.contains(">"))
    }

    // 6. A rejected call: parsed when the filter can read it, otherwise an invalid call.
    func testUnreadableRejectedCallIsTreatedAsInvalid() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.rejectedToolCall(raw: "<tool_call>{broken"), Say.done()],
            [.text("Je n'ai pas compris l'outil."), Say.done()],
        ]])
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain(factory, fallback: FakeFallbackBrain()).respond(to: BrainTurns.speech("fais-le"), tools: handler))
        XCTAssertNil(error)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 2)
        XCTAssertTrue(engine.sent[1][0].isToolResult)
        XCTAssertEqual(events.said, "Je n'ai pas compris l'outil.")
        let calls = await handler.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testReadableRejectedCallIsRun() async throws {
        try XCTSkipUnless(outputFilterIsReal(), "LocalOutputFilter is still P's phase 0 pass-through")
        let raw = "<tool_call>\n<function=compare_before_after>\n<parameter=seconds>\n2\n</parameter>\n</function>\n</tool_call>"
        let factory = FakeEngineFactory(scripts: [[[.text("Regarde."), .rejectedToolCall(raw: raw), Say.done()]]])
        let handler = ScriptedToolHandler()
        _ = await drain(brain(factory).respond(to: BrainTurns.speech("montre-moi l'avant"), tools: handler))
        let names = await handler.toolNames
        XCTAssertEqual(names, [.compareBeforeAfter])
    }

    // 7. propose_ideas gives .ideas with source .model.
    func testProposeIdeasYieldsModelIdeas() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Elle a un joli potentiel."), Say.call("propose_ideas", Say.ideas), Say.done()]]])
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("tu en penses quoi ?"), tools: ScriptedToolHandler()))
        XCTAssertNil(error)
        XCTAssertEqual(events.proposedIdeas.count, 2)
        XCTAssertTrue(events.proposedIdeas.allSatisfy { $0.source == .model })
        XCTAssertEqual(events.proposedIdeas.first?.title, "Soir doré")
        XCTAssertEqual(factory.engines.first?.options.first?.maxTokens, 320, "an opinion gets the ideas budget")
    }

    // 8. Session start: the picture in the first message, the ideas budget.
    func testSessionStartSendsThePictureAndUsesTheIdeasBudget() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Une belle scène de plage."), Say.call("propose_ideas", Say.ideas), Say.done()]]])
        let turn = BrainTurns.sessionStart(image: BrainTurns.image(version: 10))
        let (events, error) = await drain(brain(factory).respond(to: turn, tools: ScriptedToolHandler()))
        XCTAssertNil(error)
        let engine = try XCTUnwrap(factory.engines.first)
        let first = try XCTUnwrap(engine.sent.first?.last)
        XCTAssertTrue(first.hasImage)
        XCTAssertEqual(first.userText, LocalLivePrompt.sessionStartMessage(turn, imageAttached: true))
        XCTAssertEqual(engine.options.first?.maxTokens, 320)
        XCTAssertFalse(events.proposedIdeas.isEmpty)
    }

    func testPlainCommandUsesTheSpeechBudget() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Ok."), Say.done()]]])
        _ = await drain(brain(factory).respond(to: BrainTurns.speech("encore un peu"), tools: ScriptedToolHandler()))
        XCTAssertEqual(factory.engines.first?.options.first?.maxTokens, 120)
    }

    // 9. A picture only for a new version that deserves a look; a third picture compacts.
    func testPicturesFollowVersionsAndFreshLooks() async throws {
        let answer: [LocalChatEvent] = [.text("D'accord."), Say.done()]
        let factory = FakeEngineFactory(scripts: [Array(repeating: answer, count: 4), Array(repeating: answer, count: 4)])
        let brain = brain(factory)
        let handler = ScriptedToolHandler()

        _ = await drain(brain.respond(to: BrainTurns.sessionStart(id: 1, version: 10, image: BrainTurns.image(version: 10)), tools: handler))
        let same = BrainTurns.speech("encore un peu", id: 2, version: 10, image: BrainTurns.image(version: 10))
        _ = await drain(brain.respond(to: same, tools: handler))
        let small = BrainTurns.speech("encore un peu", id: 3, version: 11, image: BrainTurns.image(version: 11))
        _ = await drain(brain.respond(to: small, tools: handler))
        let far = BrainTurns.speech("encore un peu", id: 4, version: 14, image: BrainTurns.image(version: 14))
        _ = await drain(brain.respond(to: far, tools: handler))

        let engine = try XCTUnwrap(factory.engines.first)
        let pictures = engine.sent.map { $0.last?.hasImage ?? false }
        XCTAssertEqual(pictures[0], true, "session start looks")
        XCTAssertEqual(pictures[1], false, "same version: no second look")
        XCTAssertEqual(pictures[2], LocalLivePrompt.needsFreshLook(small, versionsSinceLastLook: 1))
        let lookedAt11 = pictures[2]
        XCTAssertEqual(pictures[3], LocalLivePrompt.needsFreshLook(far, versionsSinceLastLook: lookedAt11 ? 3 : 4))
        XCTAssertTrue(pictures[3], "three versions since the last look")

        // The third picture in context: a fresh engine from the examples and a recap.
        let third = BrainTurns.speech("encore un peu", id: 5, version: 18, image: BrainTurns.image(version: 18))
        let before = pictures.filter { $0 }.count
        _ = await drain(brain.respond(to: third, tools: handler))
        if before >= 2 {
            XCTAssertEqual(factory.engines.count, 2)
            XCTAssertTrue(engine.isClosed)
            let fresh = try XCTUnwrap(factory.engines.last)
            XCTAssertTrue(fresh.sent.first?.last?.hasImage ?? false)
            XCTAssertGreaterThan(fresh.setup.history.count, LocalModelLiveBrain.exampleHistory(mode: .photo, size: .full).count, "the recap follows the examples")
        }
    }

    func testTextOnlyModelNeverGetsPictures() async throws {
        var info = LocalModelInfo.qwen2B
        info.supportsVision = false
        let factory = FakeEngineFactory(scripts: [[[.text("Bonjour."), Say.done()]]])
        let turn = BrainTurns.sessionStart(image: BrainTurns.image(version: 10))
        _ = await drain(brain(factory, info: info).respond(to: turn, tools: ScriptedToolHandler()))
        XCTAssertEqual(factory.engines.first?.sent.first?.last?.hasImage, false)
    }

    // 10. Past compactAt, the engine is remade with the recap and the conversation continues.
    func testCompactionPastTheTokenBudget() async throws {
        let answer: [LocalChatEvent] = [.text("Ok."), Say.done()]
        let factory = FakeEngineFactory(scripts: [[answer, answer], [answer]], growth: 80)
        var limits = LocalModelLiveBrain.Limits()
        limits.compactAt = 100
        let entries = LogCollectorBox()
        let brain = brain(factory, limits: limits, log: { entries.add($0) })
        let handler = ScriptedToolHandler()
        _ = await drain(brain.respond(to: BrainTurns.speech("rends-la plus chaude", id: 1), tools: handler))
        _ = await drain(brain.respond(to: BrainTurns.speech("encore", id: 2, version: 11), tools: handler))
        XCTAssertEqual(factory.engines.count, 1)
        let (events, error) = await drain(brain.respond(to: BrainTurns.speech("encore", id: 3, version: 12), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.said, "Ok.")
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertTrue(factory.engines[0].isClosed)
        let fresh = factory.engines[1]
        let examples = LocalModelLiveBrain.exampleHistory(mode: .photo, size: .full)
        XCTAssertEqual(Array(fresh.setup.history.prefix(examples.count)), examples)
        let recap = try XCTUnwrap(fresh.setup.history.dropFirst(examples.count).first?.userText)
        XCTAssertTrue(recap.contains("rends-la plus chaude"), "the recap keeps the last exchanges")
        XCTAssertEqual(fresh.sent.count, 1)
        XCTAssertTrue(entries.events.contains("model.compacted"))
        for entry in entries.all {
            XCTAssertFalse(entry.fields.values.contains { $0.contains("plus chaude") }, "the log carries no transcript")
        }
    }

    // 11. A cancelled turn stops at once; the next message carries what was heard.
    func testCancellationStopsTheTurnAndTheNextMessageCarriesTheInterruption() async throws {
        let slow: [LocalChatEvent] = [.text("Je "), .text("regarde "), .text("ta "), .text("photo "), Say.call("apply_edits", Say.warmer), Say.done()]
        let factory = FakeEngineFactory(scripts: [[slow, [.text("Ok."), Say.done()]]], eventDelay: 0.03)
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        let consumer = Task { () -> [LiveBrainEvent] in
            var events: [LiveBrainEvent] = []
            do {
                for try await event in brain.respond(to: BrainTurns.speech("tu vois quoi ?", id: 1), tools: handler) {
                    events.append(event)
                    if events.said == "Je regarde " { break }
                }
            } catch {}
            return events
        }
        let seen = await consumer.value
        XCTAssertEqual(seen.said, "Je regarde ")
        try await Task.sleep(nanoseconds: 300_000_000)
        let calls = await handler.calls
        XCTAssertTrue(calls.isEmpty, "nothing runs after the cancellation")
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.cancelledStreams, 1, "the generation was cancelled")

        await brain.interrupt(turn: 1, spokenText: "Je regarde")
        _ = await drain(brain.respond(to: BrainTurns.speech("non attends", id: 2), tools: handler))
        let next = try XCTUnwrap(engine.sent.last?.last?.userText)
        XCTAssertTrue(next.contains("Je regarde"), next)
    }

    // 12. No token in time: .timeout(first_token) before any .text.
    func testFirstTokenTimeout() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Trop tard."), Say.done()]]], eventDelay: 0.5)
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: ScriptedToolHandler()))
        XCTAssertEqual(error as? LiveBrainError, .timeout(stage: "first_token"))
        XCTAssertEqual(events.kinds, ["started"])
    }

    func testColdCacheGetsTheLongerFirstTokenDeadline() async throws {
        // 450 ms per event: inside the cold deadline (12 s → 600 ms), past the warm one (6 s → 300 ms).
        let answer: [LocalChatEvent] = [.text("Ok."), Say.done()]
        let factory = FakeEngineFactory(scripts: [[answer, answer, answer]], eventDelay: 0.45)
        let brain = brain(factory, clock: BrainTestClock(scale: 0.05))
        let handler = ScriptedToolHandler()
        let first = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1), tools: handler))
        XCTAssertNil(first.error, "a new conversation prefills everything first")
        let second = await drain(brain.respond(to: BrainTurns.speech("encore", id: 2), tools: handler))
        XCTAssertEqual(second.error as? LiveBrainError, .timeout(stage: "first_token"), "a warm turn keeps the 6 s deadline")
        let third = await drain(brain.respond(to: BrainTurns.speech("encore", id: 3), tools: handler))
        XCTAssertNil(third.error, "after a cut-off turn the cache is rebuilt: cold again")
        XCTAssertEqual(LocalModelLiveBrain.Limits().coldFirstTokenTimeout, 12)
    }

    /// Warm only once reuse was seen: a turn whose stats show no cached tokens leaves the next one cold.
    func testNoReuseSeenKeepsTheCacheCold() async throws {
        let rebuilt = LiveGenerationStats(model: "Qwen3.5 4B", promptTokens: 3_000, cachedTokens: 0, generatedTokens: 12, firstTokenMs: 900, tokensPerSecond: 22)
        let answer: [LocalChatEvent] = [.text("Ok."), .finished(rebuilt, .endOfTurn)]
        let factory = FakeEngineFactory(scripts: [[answer, answer]], eventDelay: 0.45)
        let brain = brain(factory, clock: BrainTestClock(scale: 0.05))
        let handler = ScriptedToolHandler()
        let first = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1), tools: handler))
        XCTAssertNil(first.error)
        let second = await drain(brain.respond(to: BrainTurns.speech("encore", id: 2), tools: handler))
        XCTAssertNil(second.error, "the first turn rebuilt the cache: the second gets the cold deadline too")
    }

    /// A turn that attaches a fresh picture prefills it and runs the vision tower: the cold deadline.
    func testATurnWithAFreshPictureGetsTheColdDeadline() async throws {
        let answer: [LocalChatEvent] = [.text("Ok."), Say.done()]
        let factory = FakeEngineFactory(scripts: [[answer, answer, answer]], eventDelay: 0.45)
        let brain = brain(factory, clock: BrainTestClock(scale: 0.05))
        let handler = ScriptedToolHandler()
        let first = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1, version: 10, image: BrainTurns.image(version: 10)), tools: handler))
        XCTAssertNil(first.error)
        let warm = BrainTurns.speech("tu en penses quoi ?", id: 2, version: 14, image: BrainTurns.image(version: 14))
        let second = await drain(brain.respond(to: warm, tools: handler))
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.last?.last?.hasImage, true, "a new version and a question: a fresh look")
        XCTAssertNil(second.error, "the picture turn gets 12 s, not the warm 6 s")
    }

    /// The runtime unloaded the weights (the engine was closed) and loaded them again: the
    /// next turn opens a fresh engine instead of failing with `.modelNotReady`.
    func testAClosedEngineIsReopenedOnce() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Oui."), Say.done()]], [[.text("Me revoilà."), Say.done()]]])
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        _ = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1), tools: handler))
        await factory.engines[0].close()
        let (events, error) = await drain(brain.respond(to: BrainTurns.speech("plus chaud", id: 2), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.said, "Me revoilà.")
        XCTAssertEqual(factory.engines.count, 2)
        let fresh = try XCTUnwrap(factory.engines.last?.sent.first?.last)
        guard case .user(let text, _) = fresh else { return XCTFail("a user message") }
        XCTAssertEqual(text, LocalLivePrompt.userMessage(BrainTurns.speech("plus chaud", id: 2), previous: nil, imageAttached: false),
                       "a fresh conversation reads the whole editor state")
    }

    /// Closed, and the weights are not back: `.modelNotReady` before any output, for the next brain.
    func testAClosedEngineWithoutWeightsFailsBeforeOutput() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Oui."), Say.done()]]])
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        _ = await drain(brain.respond(to: BrainTurns.speech("salut", id: 1), tools: handler))
        await factory.engines[0].close()
        factory.failure = LiveBrainError.modelNotReady
        let (events, error) = await drain(brain.respond(to: BrainTurns.speech("plus chaud", id: 2), tools: handler))
        XCTAssertEqual(error as? LiveBrainError, .modelNotReady)
        XCTAssertEqual(events.kinds, ["started"])
    }

    func testTurnDeadline() async throws {
        var limits = LocalModelLiveBrain.Limits()
        limits.turnTimeout = 10
        let events = (0..<40).map { _ in LocalChatEvent.text("bla ") } + [Say.done()]
        let factory = FakeEngineFactory(scripts: [[events]], eventDelay: 0.01)
        let (seen, error) = await drain(brain(factory, limits: limits).respond(to: BrainTurns.speech("raconte"), tools: ScriptedToolHandler()))
        XCTAssertEqual(error as? LiveBrainError, .timeout(stage: "turn"))
        XCTAssertFalse(seen.said.isEmpty)
    }

    func testEngineNotReadyFailsBeforeAnyOutput() async throws {
        let factory = FakeEngineFactory()
        factory.failure = LiveBrainError.modelNotReady
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: ScriptedToolHandler()))
        XCTAssertEqual(error as? LiveBrainError, .modelNotReady)
        XCTAssertEqual(events.kinds, ["started"])
    }

    func testForeignEngineErrorsBecomeModelUnavailable() async throws {
        struct Boom: Error {}
        let factory = FakeEngineFactory()
        factory.failure = Boom()
        let (_, error) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: ScriptedToolHandler()))
        guard case .modelUnavailable? = error as? LiveBrainError else { return XCTFail("\(String(describing: error))") }
    }

    // 14. Thermal serious: 80 tokens, and no ideas at session start.
    func testThermalSeriousShortensAndSuppressesSessionIdeas() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Jolie photo."), Say.call("propose_ideas", Say.ideas), Say.done()]]])
        let brain = brain(factory)
        await brain.setThermalSerious(true)
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain.respond(to: BrainTurns.sessionStart(image: BrainTurns.image(version: 10)), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(factory.engines.first?.options.first?.maxTokens, 80)
        XCTAssertTrue(events.proposedIdeas.isEmpty)
        let calls = await handler.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(events.said, "Jolie photo.")
    }

    func testWarmUpPreparesTheEngineAndResetClosesIt() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Oui."), Say.done()]]])
        let brain = brain(factory)
        await brain.warmUp()
        XCTAssertEqual(factory.engines.count, 1)
        XCTAssertEqual(factory.engines.first?.prepareCount, 1)
        _ = await drain(brain.respond(to: BrainTurns.speech("salut"), tools: ScriptedToolHandler()))
        XCTAssertEqual(factory.engines.count, 1, "the turn uses the warmed engine")
        await brain.reset()
        XCTAssertTrue(factory.engines[0].isClosed)
    }

    func testWarmUpWithoutWeightsIsQuiet() async {
        let factory = FakeEngineFactory()
        factory.failure = LiveBrainError.modelNotReady
        let brain = brain(factory)
        await brain.warmUp()
        XCTAssertTrue(factory.engines.isEmpty)
    }

    func testTurnsRunOneAtATime() async throws {
        let answer: [LocalChatEvent] = [.text("Un."), Say.done()]
        let factory = FakeEngineFactory(scripts: [[answer, [.text("Deux."), Say.done()]]], eventDelay: 0.02)
        let brain = brain(factory)
        let handler = ScriptedToolHandler()
        async let first = drain(brain.respond(to: BrainTurns.speech("un", id: 1), tools: handler))
        async let second = drain(brain.respond(to: BrainTurns.speech("deux", id: 2), tools: handler))
        let (a, b) = await (first, second)
        XCTAssertNil(a.error)
        XCTAssertNil(b.error)
        XCTAssertEqual(Set([a.events.said, b.events.said]), ["Un.", "Deux."])
        XCTAssertEqual(factory.engines.count, 1)
    }

    func testCapabilities() {
        let brain = brain(FakeEngineFactory())
        XCTAssertEqual(brain.kind, .model)
        XCTAssertEqual(brain.capabilities, LiveBrainCapabilities(opensSession: true, seesImages: true, imageMaxPixel: 768, proposesIdeas: true))
    }

    func testExpectsIdeas() {
        XCTAssertTrue(LocalModelLiveBrain.expectsIdeas(BrainTurns.sessionStart()))
        XCTAssertTrue(LocalModelLiveBrain.expectsIdeas(BrainTurns.speech("t'as une idée ?")))
        XCTAssertTrue(LocalModelLiveBrain.expectsIdeas(BrainTurns.speech("Tu en penses quoi")))
        XCTAssertFalse(LocalModelLiveBrain.expectsIdeas(BrainTurns.speech("plus chaud")))
    }
}

/// Log entries from any thread.
final class LogCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LiveLogEntry] = []

    func add(_ entry: LiveLogEntry) { lock.withLock { entries.append(entry) } }
    var all: [LiveLogEntry] { lock.withLock { entries } }
    var events: [String] { all.map(\.event) }
}
