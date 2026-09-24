import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class ClaudeLiveBrainTests: XCTestCase {
    /// 1 s of brain time is 50 ms here: watchdogs stay far from normal replies even on a busy CI machine.
    private func brain(_ transport: FakeTransport, clock: ScaledClock = ScaledClock(scale: 0.05), log: (@Sendable (LiveLogEntry) -> Void)? = nil) -> ClaudeLiveBrain {
        ClaudeLiveBrain(mode: .photo, apiKey: "sk-ant-test", transport: transport, clock: clock, log: log)
    }

    private func run(_ brain: ClaudeLiveBrain, _ turn: LiveUserTurn, _ handler: FakeToolHandler) async -> (events: [LiveBrainEvent], error: Error?) {
        await collect(brain.respond(to: turn, tools: handler))
    }

    private static let ideasFollowUp = SSE.stream([SSE.messageStart()] + SSE.text(0, ["Ou alors un noir et blanc."]) + SSE.end("end_turn"))

    // MARK: The loop

    func testFullLoopTextToolResultText() async throws {
        let transport = FakeTransport([.sse(SSE.twoParallelTools, chunk: 17), .sse(Self.ideasFollowUp)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, error) = await run(brain, .speech("tu ferais quoi ?"), handler)
        XCTAssertNil(error)
        // Order: started, the sentence, both tools in block order, ideas, then the follow-up and the end.
        guard case .started(let model)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(model, "claude-opus-5")
        XCTAssertEqual(events.toolNames, [.applyEdits, .proposeIdeas])
        XCTAssertEqual(events.spoken, "Deux choses.Ou alors un noir et blanc.")
        XCTAssertEqual(events.completion, .answered)
        let kinds = events.map { event -> String in
            switch event {
            case .started: return "started"
            case .text: return "text"
            case .toolStarted: return "toolStarted"
            case .toolFinished: return "toolFinished"
            case .ideas: return "ideas"
            case .usage: return "usage"
            case .completed: return "completed"
            case .fallbackModel: return "fallback"
            }
        }
        XCTAssertEqual(kinds, ["started", "text", "usage", "toolStarted", "toolFinished", "toolStarted", "toolFinished", "ideas", "text", "usage", "completed"])
        let calls = await MainActor.run { handler.calls }
        XCTAssertEqual(calls.count, 2)
        guard case .proposeIdeas(let ideas) = calls[1].tool else { return XCTFail() }
        XCTAssertEqual(ideas.first?.title, "Noir et blanc")
        // The follow-up request answers both calls first, then gives the new state.
        let second = transport.requestBodies[1]["messages"]?.array ?? []
        XCTAssertEqual(second.map { $0["role"]?.string ?? "" }, ["user", "system", "assistant", "user", "system"])
        XCTAssertEqual(second[3]["content"]?.array?.compactMap { $0["tool_use_id"]?.string }, ["toolu_a", "toolu_b"])
        XCTAssertTrue(second[4]["content"]?.string?.contains("<editor_state v=11>") ?? false)
        let history = await brain.history
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testSkipCommentAfterAnAppliedEdit() async throws {
        let transport = FakeTransport([.sse(SSE.textThenTool()), .sse(SSE.textOnly)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("rends-la plus chaude"), handler)
        XCTAssertEqual(events.completion, .editApplied)
        XCTAssertEqual(transport.requests.count, 1, "no follow-up request")
        XCTAssertEqual(events.spoken, "Je réchauffe un peu.")
        guard case .toolStarted(_, _, let activity)? = events.first(where: { if case .toolStarted = $0 { return true } else { return false } }) else { return XCTFail() }
        XCTAssertEqual(activity, "Je règle chaleur…")
        var history = await brain.history
        XCTAssertEqual(history.openUserContent.compactMap(\.toolUseID), ["toolu_01"])
        // The next turn's user message opens with the owed result.
        _ = await run(brain, .speech("merci", id: 2, version: 11), handler)
        let messages = transport.requestBodies[1]["messages"]?.array ?? []
        XCTAssertEqual(messages[3]["content"]?.array?.first?["type"], "tool_result")
        XCTAssertEqual(messages[3]["content"]?.array?.last?["text"], "merci")
        history = await brain.history
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testRunningJobAsksForAComment() async throws {
        let transport = FakeTransport([.sse(SSE.textThenTool()), .sse(SSE.textOnly)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        await MainActor.run { handler.stepStatus = .running }
        let (events, _) = await run(brain, .speech("génère un ciel"), handler)
        XCTAssertEqual(transport.requests.count, 2, "a running step is not 'applied': Claude comments")
        XCTAssertEqual(events.completion, .answered)
        let result = transport.requestBodies[1]["messages"]?.array?[3]["content"]?.array?.first?["content"]?.array?.first?["text"]?.string ?? ""
        XCTAssertTrue(result.contains(#""status":"running""#), result)
    }

    func testRefusalRunsNoToolAndRollsBack() async throws {
        let refusedTool = SSE.stream([SSE.messageStart()] + SSE.text(0, ["Je "]) + SSE.tool(1, id: "toolu_x", name: "apply_edits", fragments: [#"{"steps":[{"action":"autoEnhance"}]}"#]) + SSE.end("refusal", details: ["category": "cyber"]))
        let transport = FakeTransport([.sse(refusedTool)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, error) = await run(brain, .speech("fais un truc interdit"), handler)
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .refused(category: "cyber"))
        let calls = await MainActor.run { handler.calls }
        XCTAssertTrue(calls.isEmpty)
        let history = await brain.history
        XCTAssertTrue(history.messages.isEmpty, "iteration 0: as if the turn never happened")
    }

    func testRefusalOnALaterIterationKeepsTheResults() async throws {
        let transport = FakeTransport([.sse(SSE.twoParallelTools), .sse(SSE.refusalBeforeOutput)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("oui, vas-y, applique les deux", id: 3), handler)
        XCTAssertEqual(events.completion, .refused(category: nil))
        let history = await brain.history
        XCTAssertEqual(history.messages.map(\.role), [.user, .system, .assistant, .user, .system, .assistant])
        XCTAssertEqual(history.messages.last?.content, [.text("Je ne peux pas faire ça. Une autre idée ?")])
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testMaxTokensRetriesOnceWithoutRepeatingItself() async throws {
        let retry = SSE.stream([SSE.messageStart()] + SSE.text(0, ["Je m'en occupe.", " Voilà."])
            + SSE.tool(1, id: "toolu_ok", name: "apply_edits", fragments: [#"{"steps":[{"action":"autoEnhance"}]}"#]) + SSE.end("tool_use"))
        let transport = FakeTransport([.sse(SSE.maxTokensInToolInput), .sse(retry)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("améliore"), handler)
        XCTAssertEqual(events.spoken, "Je m'en occupe. Voilà.", "the first sentence is not said twice")
        XCTAssertEqual(transport.requestBodies.map { $0["max_tokens"]?.int ?? 0 }, [2048, 4096])
        let calls = await MainActor.run { handler.calls }
        XCTAssertEqual(calls.count, 1, "nothing from the cut response ran")
        XCTAssertEqual(events.completion, .editApplied)
    }

    func testMaxTokensTwiceEndsTheTurn() async throws {
        let transport = FakeTransport([.sse(SSE.maxTokensInToolInput), .sse(SSE.maxTokensInToolInput)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("améliore"), handler)
        XCTAssertEqual(events.completion, .maxTokens)
        let calls = await MainActor.run { handler.calls }
        XCTAssertTrue(calls.isEmpty)
        let history = await brain.history
        XCTAssertEqual(history.messages.last?.content, [.text("Je m'en occupe.")])
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testMidStreamFallbackOnlyRunsLaterTools() async throws {
        let transport = FakeTransport([.sse(SSE.midStreamFallback, chunk: 9)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("enlève le chien"), handler)
        XCTAssertTrue(events.contains(.fallbackModel(from: "claude-opus-5", to: "claude-opus-4-8")))
        XCTAssertEqual(events.spoken, "Je vais retirer le chien.")
        let calls = await MainActor.run { handler.calls }
        XCTAssertEqual(calls.map(\.id), ["toolu_ok"])
        let history = await brain.history
        let echoed = history.messages[2].content
        XCTAssertFalse(echoed.contains { if case .fallback = $0 { return true } else { return false } })
        XCTAssertEqual(echoed.compactMap(\.toolUseID), ["toolu_ok"])
    }

    func testInvalidInputGetsAnErrorResultAndTheLoopGoesOn() async throws {
        let bad = SSE.stream([SSE.messageStart()] + SSE.text(0, ["Ok."])
            + SSE.tool(1, id: "toolu_bad", name: "apply_edits", fragments: [#"{"steps":[{"action":"adjust","parameter":"brightness","amount":250}]}"#]) + SSE.end("tool_use"))
        let transport = FakeTransport([.sse(bad), .sse(SSE.textOnly)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("beaucoup plus clair"), handler)
        XCTAssertEqual(events.completion, .answered)
        let calls = await MainActor.run { handler.calls }
        XCTAssertTrue(calls.isEmpty)
        let result = transport.requestBodies[1]["messages"]?.array?[3]["content"]?.array?.first
        XCTAssertEqual(result?["is_error"], true)
        XCTAssertTrue(result?["content"]?.array?.first?["text"]?.string?.contains("250 is outside -100...100") ?? false)
    }

    func testApplyEditsLimitPerTurn() async throws {
        func toolReply(_ id: String) -> FakeTransport.Reply {
            .sse(SSE.stream([SSE.messageStart()] + SSE.tool(0, id: id, name: "apply_edits", fragments: [#"{"steps":[{"action":"autoEnhance"}]}"#]) + SSE.end("tool_use")))
        }
        let transport = FakeTransport([toolReply("t1"), toolReply("t2"), toolReply("t3"), toolReply("t4"), .sse(SSE.textOnly)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("encore et encore"), handler)
        let calls = await MainActor.run { handler.calls }
        XCTAssertEqual(calls.count, 3, "the 4th apply_edits of a turn does not run")
        XCTAssertEqual(transport.requests.count, 5)
        let limited = transport.requestBodies[4]["messages"]?.array?.last { $0["role"] == "user" }?["content"]?.array?.first
        XCTAssertEqual(limited?["is_error"], true)
        XCTAssertEqual(events.completion, .answered)
    }

    func testRequestLimitEndsTheTurn() async throws {
        func ideasReply(_ id: String) -> FakeTransport.Reply {
            .sse(SSE.stream([SSE.messageStart()] + SSE.tool(0, id: id, name: "compare_before_after", fragments: ["{}"]) + SSE.end("tool_use")))
        }
        let transport = FakeTransport((1...7).map { ideasReply("c\($0)") })
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, _) = await run(brain, .speech("montre"), handler)
        XCTAssertEqual(transport.requests.count, 6)
        XCTAssertEqual(events.completion, .loopLimit)
        let history = await brain.history
        XCTAssertEqual(history.invariantViolations(), [])
        XCTAssertEqual(history.openUserContent.count, 1)
    }

    // MARK: Errors

    func testBetaRejectionResendsWithoutFallbacks() async throws {
        let transport = FakeTransport([
            .http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header"}}"#),
            .sse(SSE.textOnly), .sse(SSE.textOnly),
        ])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (events, error) = await run(brain, .speech("salut"), handler)
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .answered)
        XCTAssertEqual(transport.requests[0].headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertNil(transport.requests[1].headers["anthropic-beta"])
        XCTAssertNil(transport.requestBodies[1]["fallbacks"])
        _ = await run(brain, .speech("encore", id: 2), handler)
        XCTAssertNil(transport.requestBodies[2]["fallbacks"], "for the brain's lifetime")
    }

    func testRateLimitShortRetryAndLongFailure() async throws {
        let limited = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#
        let short = FakeTransport([.http(status: 429, body: limited, headers: ["retry-after": "1"]), .sse(SSE.textOnly)])
        let (events, error) = await run(brain(short), .speech("salut"), FakeToolHandler())
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .answered)
        XCTAssertEqual(short.requests.count, 2)

        let long = FakeTransport([.http(status: 429, body: limited, headers: ["retry-after": "30"])])
        let longBrain = brain(long)
        let (_, failure) = await run(longBrain, .speech("salut"), FakeToolHandler())
        XCTAssertEqual(failure as? LiveBrainError, .rateLimited(retryAfter: 30))
        XCTAssertEqual(long.requests.count, 1)
        let history = await longBrain.history
        XCTAssertTrue(history.messages.isEmpty, "a failure before output leaves no trace")
    }

    func testOverloadedRetriesOnce() async throws {
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let once = FakeTransport([.http(status: 529, body: overloaded), .sse(SSE.textOnly)])
        let (events, error) = await run(brain(once), .speech("salut"), FakeToolHandler())
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .answered)
        let twice = FakeTransport([.http(status: 529, body: overloaded), .http(status: 529, body: overloaded)])
        let (_, failure) = await run(brain(twice), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(failure as? LiveBrainError, .overloaded)
        let event = FakeTransport([.sse(SSE.overloadedError), .sse(SSE.textOnly)])
        let (eventEvents, eventError) = await run(brain(event), .speech("salut"), FakeToolHandler())
        XCTAssertNil(eventError, "an SSE overloaded_error before output retries too")
        XCTAssertEqual(eventEvents.completion, .answered)
        let server = FakeTransport([.http(status: 500, body: "{}"), .http(status: 503, body: "{}")])
        let (_, serverFailure) = await run(brain(server), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(serverFailure as? LiveBrainError, .server(status: 503))
    }

    func testAuthenticationBillingAndSizeErrors() async throws {
        let cases: [(Int, LiveBrainError)] = [(401, .invalidKey), (402, .noCredit), (403, .forbidden), (404, .modelUnavailable)]
        for (status, expected) in cases {
            let transport = FakeTransport([.http(status: status, body: #"{"type":"error","error":{"type":"x","message":"no"}}"#)])
            let (_, error) = await run(brain(transport), .speech("salut"), FakeToolHandler())
            XCTAssertEqual(error as? LiveBrainError, expected, "\(status)")
            XCTAssertEqual(transport.requests.count, 1)
        }
        let tooLarge = #"{"type":"error","error":{"type":"request_too_large","message":"too big"}}"#
        let once = FakeTransport([.sse(SSE.textOnly), .http(status: 413, body: tooLarge), .sse(SSE.textOnly)])
        let onceBrain = brain(once)
        _ = await run(onceBrain, .speech("un", id: 1), FakeToolHandler())
        let (events, error) = await run(onceBrain, .speech("deux", id: 2), FakeToolHandler())
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .answered)
        let history = await onceBrain.history
        XCTAssertEqual(history.epoch, 1, "413: compacted into a new epoch and resent")
        let twice = FakeTransport([.http(status: 413, body: tooLarge), .http(status: 413, body: tooLarge)])
        let (_, failure) = await run(brain(twice), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(failure as? LiveBrainError, .requestTooLarge)
        let badRequest = FakeTransport([
            .http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: bad"},"request_id":"req_9"}"#),
            .http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: bad"},"request_id":"req_10"}"#),
        ])
        let (_, badFailure) = await run(brain(badRequest), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(badFailure as? LiveBrainError, .badRequest(requestID: "req_10", message: "messages: bad"))
        XCTAssertEqual(badRequest.requests.count, 2, "compacted and resent once")
    }

    func testWatchdogs() async throws {
        let silent = FakeTransport([.hang])
        let (_, noByte) = await run(brain(silent, clock: ScaledClock(scale: 0.01)), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(noByte as? LiveBrainError, .timeout(stage: "first_byte"))
        let started = FakeTransport([.bytesThenHang(SSE.stream([SSE.messageStart(), SSE.ping]))])
        let (_, noOutput) = await run(brain(started, clock: ScaledClock(scale: 0.01)), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(noOutput as? LiveBrainError, .timeout(stage: "first_output"))
        for _ in 0..<100 where started.cancelled == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(started.cancelled, 1, "the HTTP stream is cancelled")
    }

    func testTruncatedStream() async throws {
        let cut = String(SSE.textOnly.components(separatedBy: "event: message_delta")[0])
        let (events, error) = await run(brain(FakeTransport([.sse(cut)])), .speech("salut"), FakeToolHandler())
        XCTAssertEqual(error as? LiveBrainError, .streamTruncated)
        XCTAssertFalse(events.spoken.isEmpty)
    }

    // MARK: Cancellation and history

    func testCancellationLeavesAValidHistory() async throws {
        let partial = SSE.stream([SSE.messageStart()] + [["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                                                         ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "D'accord, je"]]])
        let transport = FakeTransport([.bytesThenHang(partial), .sse(SSE.textOnly)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (textSeen, textContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await event in brain.respond(to: .speech("le gauche", id: 4), tools: handler) {
                if case .text = event { textContinuation.yield() }
            }
        }
        for await _ in textSeen { break }
        consumer.cancel()
        _ = await consumer.result
        await brain.interrupt(turn: 4, spokenText: "D'accord")
        var history = await brain.history
        XCTAssertEqual(history.messages.last, ClaudeMessage(role: .assistant, content: [.text("D'accord ...")]))
        XCTAssertEqual(history.invariantViolations(), [])
        for _ in 0..<100 where transport.cancelled == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(transport.cancelled, 1, "the HTTP stream is cancelled")
        let (events, _) = await run(brain, .speech("non, le droit", id: 5), handler)
        XCTAssertEqual(events.completion, .answered)
        history = await brain.history
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testInterruptedFollowUpDoesNotRepeatTheSentenceBeforeTheTool() async throws {
        let partial = SSE.stream([SSE.messageStart()] + [["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                                                         ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Et pour le ciel"]]])
        let transport = FakeTransport([.sse(SSE.twoParallelTools), .bytesThenHang(partial)])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        let (textSeen, textContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await event in brain.respond(to: .speech("vas-y, fais les deux", id: 7), tools: handler) {
                if case .text(let text) = event, text.hasPrefix("Et") { textContinuation.yield() }
            }
        }
        for await _ in textSeen { break }
        consumer.cancel()
        _ = await consumer.result
        await brain.interrupt(turn: 7, spokenText: "Deux choses. Et pour le")
        let history = await brain.history
        XCTAssertEqual(history.messages.last, ClaudeMessage(role: .assistant, content: [.text("Et pour le ...")]))
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testCancelledBeforeAnyOutputRollsBack() async throws {
        let transport = FakeTransport([.bytesThenHang(SSE.stream([SSE.messageStart()]))])
        let brain = brain(transport)
        let consumer = Task { for try await _ in brain.respond(to: .speech("euh attends"), tools: FakeToolHandler()) {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        _ = await consumer.result
        await brain.interrupt(turn: 1, spokenText: "")
        let history = await brain.history
        XCTAssertTrue(history.messages.isEmpty)
    }

    /// Five turns with tools and an interruption: every request's messages are a byte prefix of the next one's.
    func testPrefixPropertyAcrossAScriptedConversation() async throws {
        let clarify = SSE.stream([SSE.messageStart()] + SSE.text(0, ["J'enlève le chien."])
            + SSE.tool(1, id: "toolu_dog", name: "apply_edits", fragments: [#"{"steps":[{"action":"removeObject","target":"dog"}]}"#]) + SSE.end("tool_use"))
        let which = SSE.stream([SSE.messageStart()] + SSE.text(0, ["Lequel, celui de gauche ou de droite ?"]) + SSE.end("end_turn"))
        let partial = SSE.stream([SSE.messageStart()] + SSE.text(0, ["D'accord, j"]))
        let transport = FakeTransport([
            .sse(SSE.textThenTool(), chunk: 11),
            .sse(SSE.twoParallelTools, chunk: 5), .sse(Self.ideasFollowUp),
            .sse(clarify), .sse(which),
            .bytesThenHang(partial),
            .sse(SSE.thinkingThenText),
        ])
        let brain = brain(transport)
        let handler = FakeToolHandler()
        var image = LiveImage(jpeg: Data([0xFF, 0xD8, 0xFF]), pixelWidth: 1024, pixelHeight: 768, version: 10)
        _ = await run(brain, .speech("rends-la plus chaude", id: 1, version: 10, image: image), handler)
        image.version = 11
        _ = await run(brain, .speech("et tu ferais quoi ?", id: 2, version: 11, image: image), handler)
        await MainActor.run { handler.stepStatus = .needsClarification }
        _ = await run(brain, .speech("enlève le chien", id: 3, version: 13, image: image), handler)
        await MainActor.run { handler.stepStatus = .applied }
        let (textSeen, textContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await event in brain.respond(to: .speech("le gauche", id: 4, version: 13), tools: handler) {
                if case .text = event { textContinuation.yield() }
            }
        }
        for await _ in textSeen { break }
        consumer.cancel()
        _ = await consumer.result
        await brain.interrupt(turn: 4, spokenText: "D'accord")
        image.version = 14
        _ = await run(brain, .speech("non, plutôt noir et blanc", id: 5, version: 14, image: image), handler)

        let bodies = transport.requestBodies
        XCTAssertEqual(bodies.count, 7)
        let serialized = bodies.map { ($0["messages"] ?? []).serialized() }
        for index in 1..<serialized.count {
            let previous = String(serialized[index - 1].dropLast())
            XCTAssertTrue(serialized[index].hasPrefix(previous), "request \(index) does not extend request \(index - 1)")
        }
        // Tools and system never change.
        XCTAssertEqual(Set(bodies.map { ($0["tools"] ?? nil).serialized() }).count, 1)
        XCTAssertEqual(Set(bodies.map { ($0["system"] ?? nil).serialized() }).count, 1)
        // Images: attached on turn 1 and turn 2 (new version), not on turn 3 (same version), again on turn 5.
        XCTAssertEqual(transport.requests.map(\.carriesImage), [true, true, false, false, false, false, true])
        let history = await brain.history
        XCTAssertEqual(history.invariantViolations(), [])
    }

    func testWarmUpAndBookkeeping() async throws {
        let transport = FakeTransport([.sse(SSE.textOnly)])
        let entries = LogCollector()
        let brain = brain(transport, log: { entries.add($0) })
        var seconds = await brain.secondsSinceLastRequest
        XCTAssertNil(seconds)
        await brain.warmUp()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertNil(transport.sent[0].headers["anthropic-beta"])
        let isAvailable = await brain.isAvailable()
        XCTAssertTrue(isAvailable)
        _ = await run(brain, .speech("salut"), FakeToolHandler())
        seconds = await brain.secondsSinceLastRequest
        XCTAssertNotNil(seconds)
        let logged = entries.all
        XCTAssertTrue(logged.contains { $0.event == "response" && $0.fields["stop_reason"] == "end_turn" && $0.fields["input"] == "1200" })
        XCTAssertTrue(logged.contains { $0.event == "request" && $0.fields["bytes"] != nil })
        // Never text: neither the user's words nor the reply.
        XCTAssertFalse(logged.contains { entry in entry.fields.values.contains { $0.contains("salut") || $0.contains("réchauffe") } })
        await brain.reset()
        let history = await brain.history
        XCTAssertTrue(history.messages.isEmpty)
        let wants = await brain.wantsImage(version: 1, frameKey: nil, kind: .speech)
        XCTAssertTrue(wants)
    }
}

final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LiveLogEntry] = []

    func add(_ entry: LiveLogEntry) { lock.withLock { entries.append(entry) } }
    var all: [LiveLogEntry] { lock.withLock { entries } }
}
