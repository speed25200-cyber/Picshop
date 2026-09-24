import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class JSONValueTests: XCTestCase {
    func testStrictParseRejectsWhatRFC8259Rejects() {
        let invalid = [
            "{\"a\":1,}", "[1,]", "{\"a\":1} x", "[1][2]", "NaN", "[NaN]", "[Infinity]", "[1e400]", "[01]", "[.5]", "[1.]", "[+1]", "{'a':1}",
            "[\"\\ud800\"]", "[\"a\u{01}b\"]", "{\"a\":1,\"a\":2}", "// c\n[1]", "", "   ", "[\"\\x41\"]", "{\"a\" 1}", "[true false]", "tru", "[\"unterminated]",
        ]
        for text in invalid {
            XCTAssertThrowsError(try JSONValue.parse(text), text.debugDescription)
        }
    }

    func testStrictParseAcceptsValidJSON() throws {
        XCTAssertEqual(try JSONValue.parse(" {\"a\" : [1, -0.5, 2e3, true, null, \"é\\u00e9\\ud83d\\ude00\\n\"]} \n"),
                       ["a": [1, -0.5, 2000, true, nil, "éé😀\n"]])
        XCTAssertEqual(try JSONValue.parse("1"), 1)
        XCTAssertEqual(try JSONValue.parse("\"x\\/y\""), "x/y")
        XCTAssertEqual(try JSONValue.parse("[]"), [])
        XCTAssertEqual(try JSONValue.parse("{}"), [:])
    }

    func testGoldenSerialization() {
        let value: JSONValue = [
            "zeta": 1, "alpha": ["b": 2.5, "a": -3], "Émile": "raw é 😀 / \"quoted\" \\ back",
            "big": 9_007_199_254_740_991, "huge": 1e16, "small": 0.1, "neg": -0.0, "ctl": "\u{01}\u{1F}\t\n\r\u{08}\u{0C}", "list": [nil, false, true],
        ]
        let expected = #"{"alpha":{"a":-3,"b":2.5},"big":9007199254740991,"ctl":"\u0001\u001f\t\n\r\b\f","huge":1e+16,"list":[null,false,true],"neg":0,"small":0.1,"zeta":1,"Émile":"raw é 😀 / \"quoted\" \\ back"}"#
        XCTAssertEqual(value.serialized(), expected)
    }

    func testKeysSortByUTF8Bytes() {
        let value: JSONValue = ["b": 1, "B": 2, "é": 3, "e": 4, "_": 5]
        XCTAssertEqual(value.serialized(), #"{"B":2,"_":5,"b":1,"e":4,"é":3}"#)
    }

    func testRoundTrips() throws {
        let values: [JSONValue] = [
            ["steps": [["action": "adjust", "amount": 15, "parameter": "temperature"]]],
            ["text": "Ligne 1\nLigne « 2 »\t\"fin\"", "n": 1.25, "deep": [[[["x": nil]]]]],
            "😀", 0, -12.75, true,
        ]
        for value in values {
            let text = value.serialized()
            XCTAssertEqual(try JSONValue.parse(text), value, text)
            XCTAssertEqual(try JSONValue.parse(text).serialized(), text)
        }
    }

    func testAccessors() {
        let value: JSONValue = ["n": 3, "f": 1.5, "s": "x", "b": true, "a": [1], "o": ["k": nil]]
        XCTAssertEqual(value["n"]?.int, 3)
        XCTAssertNil(value["f"]?.int)
        XCTAssertEqual(value["f"]?.double, 1.5)
        XCTAssertEqual(value["s"]?.string, "x")
        XCTAssertEqual(value["b"]?.bool, true)
        XCTAssertEqual(value["a"]?.array?.count, 1)
        XCTAssertEqual(value["o"]?.object?["k"], .null)
        XCTAssertNil(value["missing"])
    }
}

final class SSEParserTests: XCTestCase {
    private func parse(_ text: String, chunks: [Int]) -> [SSEEvent] {
        var parser = SSEParser()
        let bytes = Array(text.utf8)
        var events: [SSEEvent] = []
        var offset = 0
        var index = 0
        while offset < bytes.count {
            let size = chunks.isEmpty ? bytes.count : chunks[index % chunks.count]
            events += parser.feed(bytes[offset..<min(bytes.count, offset + size)])
            offset += size
            index += 1
        }
        return events + parser.finish()
    }

    func testWholeByteByByteAndRandomChunksAgree() {
        let stream = SSE.midStreamFallback + SSE.thinkingThenText
        let whole = parse(stream, chunks: [])
        XCTAssertFalse(whole.isEmpty)
        XCTAssertEqual(parse(stream, chunks: [1]), whole)
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<20 {
            let sizes = (0..<16).map { _ in Int.random(in: 1...40, using: &generator) }
            XCTAssertEqual(parse(stream, chunks: sizes), whole)
        }
    }

    func testLineEndings() {
        let expected = [SSEEvent(event: "a", data: "1"), SSEEvent(event: "b", data: "2")]
        XCTAssertEqual(parse("event: a\r\ndata: 1\r\n\r\nevent: b\r\ndata: 2\r\n\r\n", chunks: [1]), expected)
        XCTAssertEqual(parse("event: a\rdata: 1\r\revent: b\rdata: 2\r\r", chunks: [3]), expected)
        XCTAssertEqual(parse("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n", chunks: [2]), expected)
    }

    func testCommentsMultiLineDataAndFields() {
        let text = ": keep-alive\nevent: x\ndata: first\ndata:second\nid: 7\nretry: 100\nunknown: y\n\n: bye\n\n"
        XCTAssertEqual(parse(text, chunks: [5]), [SSEEvent(event: "x", data: "first\nsecond", id: "7")])
    }

    func testUTF8SplitInsideCharacters() {
        let text = "data: {\"t\":\"é😀ü\"}\n\n"
        let bytes = Array(text.utf8)
        // Split inside é (2 bytes) and inside the emoji (4 bytes).
        let e = bytes.firstIndex(of: 0xC3)! + 1
        let emoji = bytes.firstIndex(of: 0xF0)! + 2
        var parser = SSEParser()
        var events = parser.feed(bytes[..<e])
        events += parser.feed(bytes[e..<emoji])
        events += parser.feed(bytes[emoji...])
        XCTAssertEqual(events, [SSEEvent(data: "{\"t\":\"é😀ü\"}")])
    }

    func testFinishFlushesTheLastEvent() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Array("event: message_stop\ndata: {\"type\":\"message_stop\"}".utf8)), [])
        XCTAssertEqual(parser.finish(), [SSEEvent(event: "message_stop", data: "{\"type\":\"message_stop\"}")])
        XCTAssertEqual(parser.finish(), [])
    }

    func testEventWithoutDataIsNotDispatched() {
        XCTAssertEqual(parse("event: ping\n\ndata: x\n\n", chunks: []), [SSEEvent(data: "x")])
    }
}

/// Deterministic randomness for chunk sizes.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

final class StreamDecoderTests: XCTestCase {
    private func accumulate(_ stream: String) throws -> (MessageAccumulator, [AccumulatorOutput], [ClaudeStreamEvent]) {
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        var outputs: [AccumulatorOutput] = []
        var decoded: [ClaudeStreamEvent] = []
        for event in parser.feed(Array(stream.utf8)) + parser.finish() {
            guard let value = try ClaudeStreamEvent.decode(event) else { continue }
            decoded.append(value)
            outputs += accumulator.apply(value)
        }
        return (accumulator, outputs, decoded)
    }

    func testTextOnly() throws {
        let (accumulator, outputs, _) = try accumulate(SSE.textOnly)
        XCTAssertEqual(outputs, [.text("Je "), .text("réchauffe un peu"), .text(" la photo.")])
        XCTAssertEqual(accumulator.content(), [.text("Je réchauffe un peu la photo.")])
        XCTAssertEqual(accumulator.stopReason, .endTurn)
        XCTAssertTrue(accumulator.isComplete)
        XCTAssertEqual(accumulator.usage.inputTokens, 1200)
        XCTAssertEqual(accumulator.usage.outputTokens, 40)
        XCTAssertFalse(accumulator.hasToolUse)
    }

    func testEmptyThinkingWithSignatureIsKept() throws {
        let (accumulator, outputs, _) = try accumulate(SSE.thinkingThenText)
        XCTAssertEqual(outputs, [.text("Bonne idée, "), .text("on y va.")])
        XCTAssertEqual(accumulator.content(), [.thinking(text: "", signature: "sig-abc"), .text("Bonne idée, on y va.")])
        XCTAssertEqual(EchoPolicy.sanitize(accumulator.content()), accumulator.content())
    }

    func testToolInputAcrossFragments() throws {
        let (accumulator, outputs, _) = try accumulate(SSE.textThenTool())
        let completed = outputs.compactMap { if case .toolCompleted(let use) = $0 { return use } else { return nil } }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].rawInput, #"{"steps":[{"action":"adjust","parameter":"temperature","amountMode":"relative","amount":15}]}"#)
        XCTAssertEqual(completed[0].blockIndex, 1)
        XCTAssertTrue(outputs.contains(.toolStarted(id: "toolu_01", name: "apply_edits")))
        XCTAssertGreaterThan(outputs.filter { if case .toolFragment = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(accumulator.executableToolUses(), completed)
        XCTAssertTrue(accumulator.hasTextBeforeFirstToolUse)
        guard case .toolUse(_, _, let input) = accumulator.content()[1] else { return XCTFail("tool_use expected") }
        XCTAssertEqual(input["steps"]?.array?.first?["amount"], 15)
    }

    func testNoDeltaMeansEmptyObject() throws {
        let stream = SSE.stream([SSE.messageStart()] + SSE.tool(0, id: "toolu_1", name: "compare_before_after", fragments: []) + SSE.end("tool_use"))
        let (accumulator, _, _) = try accumulate(stream)
        XCTAssertEqual(accumulator.executableToolUses().first?.rawInput, "{}")
    }

    func testTwoParallelTools() throws {
        let (accumulator, _, _) = try accumulate(SSE.twoParallelTools)
        XCTAssertEqual(accumulator.executableToolUses().map(\.name), ["apply_edits", "propose_ideas"])
        XCTAssertEqual(accumulator.executableToolUses().map(\.id), ["toolu_a", "toolu_b"])
    }

    func testRefusalBeforeAnyOutput() throws {
        let (accumulator, outputs, _) = try accumulate(SSE.refusalBeforeOutput)
        XCTAssertEqual(outputs, [])
        XCTAssertEqual(accumulator.stopReason, .refusal)
        XCTAssertNil(accumulator.stopDetails)
        XCTAssertEqual(accumulator.content(), [])
        let (withCategory, _, _) = try accumulate(SSE.refusalWithCategory)
        XCTAssertEqual(withCategory.stopDetails?["category"]?.string, "cyber")
    }

    func testMidStreamFallbackBoundary() throws {
        let (accumulator, outputs, _) = try accumulate(SSE.midStreamFallback)
        XCTAssertTrue(outputs.contains(.fallback(from: "claude-opus-5", to: "claude-opus-4-8")))
        XCTAssertEqual(outputs.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(), "Je vais retirer le chien.")
        XCTAssertEqual(accumulator.lastFallbackIndex, 3)
        XCTAssertEqual(accumulator.executableToolUses().map(\.id), ["toolu_ok"])
        XCTAssertTrue(accumulator.usage.servedByFallback)
        // Echo: no thinking or tool_use from before the boundary, no fallback marker; text and later blocks stay.
        let echoed = EchoPolicy.sanitize(accumulator.content())
        XCTAssertEqual(echoed, [
            .text("Je vais "),
            .text("retirer le chien."),
            .toolUse(id: "toolu_ok", name: "apply_edits", input: ["steps": [["action": "removeObject", "target": "dog"]]]),
        ])
    }

    func testMaxTokensInsideToolInput() throws {
        let (accumulator, _, _) = try accumulate(SSE.maxTokensInToolInput)
        XCTAssertEqual(accumulator.stopReason, .maxTokens)
        XCTAssertTrue(accumulator.hasToolUse)
        XCTAssertEqual(accumulator.executableToolUses().first?.rawInput, #"{"steps":[{"action":"adj"#)
        // The truncated input echoes as {} (never run).
        XCTAssertEqual(accumulator.content()[1], .toolUse(id: "toolu_cut", name: "apply_edits", input: [:]))
    }

    func testOverloadedErrorEvent() throws {
        let (_, _, decoded) = try accumulate(SSE.overloadedError)
        XCTAssertEqual(decoded.last, .error(type: "overloaded_error", message: "Overloaded"))
    }

    func testPingAndUnknownTypes() throws {
        let (accumulator, _, decoded) = try accumulate(SSE.withPingAndUnknown)
        XCTAssertTrue(decoded.contains(.ping))
        XCTAssertEqual(accumulator.content(), [.unknown(raw: ["type": "mystery_block", "payload": [1, 2]]), .text("Ok.")])
        XCTAssertEqual(EchoPolicy.sanitize(accumulator.content()).first, .unknown(raw: ["type": "mystery_block", "payload": [1, 2]]))
    }

    func testMalformedEventThrows() {
        XCTAssertThrowsError(try ClaudeStreamEvent.decode(SSEEvent(data: "{not json")))
        XCTAssertThrowsError(try ClaudeStreamEvent.decode(SSEEvent(data: "{\"no\":\"type\"}")))
    }

    func testContentBlocksRoundTripThroughJSON() throws {
        let blocks: [ClaudeContentBlock] = [
            .text("Salut", cache: .oneHour), .image(.base64(mediaType: "image/jpeg", data: "AAA=")), .thinking(text: "", signature: "s"),
            .redactedThinking(data: "zzz"), .toolUse(id: "t", name: "undo", input: ["count": 1]),
            .toolResult(toolUseID: "t", content: [.text("{\"ok\":true}")], isError: true), .fallback(raw: ["type": "fallback"]), .unknown(raw: ["type": "new"]),
        ]
        for block in blocks {
            let decoded = try ClaudeContentBlock(json: block.json)
            if case .text(let text, _) = block { XCTAssertEqual(decoded, .text(text)) } else if case .image(let source, _) = block { XCTAssertEqual(decoded, .image(source)) } else { XCTAssertEqual(decoded, block) }
        }
        XCTAssertEqual(ClaudeContentBlock.toolResult(toolUseID: "t", content: [.text("x")], isError: false).json.serialized(),
                       #"{"content":[{"text":"x","type":"text"}],"tool_use_id":"t","type":"tool_result"}"#)
        XCTAssertEqual(ClaudeMessage.system("state").json.serialized(), #"{"content":"state","role":"system"}"#)
        XCTAssertEqual(StopReason(raw: "model_context_window_exceeded"), .contextWindowExceeded)
        XCTAssertEqual(StopReason(raw: "weird").raw, "weird")
    }

    func testAPIErrorBody() {
        let error = ClaudeAPIError(status: 429, body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"},"request_id":"req_1"}"#.utf8),
                                   headers: ["Retry-After": "1.5"])
        XCTAssertEqual(error.type, "rate_limit_error")
        XCTAssertEqual(error.message, "slow down")
        XCTAssertEqual(error.requestID, "req_1")
        XCTAssertEqual(error.retryAfter, 1.5)
    }
}
