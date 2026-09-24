import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// Recorded-shape SSE streams, written as Swift literals, and the fakes the
// Live tests share: a transport that replays them, a tool handler, a clock.

enum SSE {
    /// "event: <type>\ndata: <json>\n\n" for each event.
    static func stream(_ events: [JSONValue]) -> String {
        events.map { "event: \($0["type"]?.string ?? "message")\ndata: \($0.serialized())\n\n" }.joined()
    }

    static func messageStart(model: String = "claude-opus-5", input: Int = 1200, cacheRead: Int = 0, cacheWrite: Int = 0) -> JSONValue {
        ["type": "message_start", "message": ["id": "msg_01", "type": "message", "role": "assistant", "model": .string(model), "content": [],
                                               "usage": ["input_tokens": .number(Double(input)), "output_tokens": 1,
                                                         "cache_read_input_tokens": .number(Double(cacheRead)),
                                                         "cache_creation_input_tokens": .number(Double(cacheWrite))]]]
    }

    static func text(_ index: Int, _ pieces: [String]) -> [JSONValue] {
        [["type": "content_block_start", "index": .number(Double(index)), "content_block": ["type": "text", "text": ""]]]
            + pieces.map { ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "text_delta", "text": .string($0)]] }
            + [["type": "content_block_stop", "index": .number(Double(index))]]
    }

    /// Adaptive thinking as returned by default: empty text, then a signature.
    static func thinking(_ index: Int, signature: String = "sig-abc") -> [JSONValue] {
        [["type": "content_block_start", "index": .number(Double(index)), "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
         ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "signature_delta", "signature": .string(signature)]],
         ["type": "content_block_stop", "index": .number(Double(index))]]
    }

    static func tool(_ index: Int, id: String, name: String, fragments: [String], stop: Bool = true) -> [JSONValue] {
        var events: [JSONValue] = [["type": "content_block_start", "index": .number(Double(index)),
                                    "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]]]
        events += fragments.map { ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "input_json_delta", "partial_json": .string($0)]] }
        if stop { events.append(["type": "content_block_stop", "index": .number(Double(index))]) }
        return events
    }

    static func fallback(_ index: Int, from: String = "claude-opus-5", to: String = "claude-opus-4-8") -> [JSONValue] {
        [["type": "content_block_start", "index": .number(Double(index)),
          "content_block": ["type": "fallback", "from": ["model": .string(from)], "to": ["model": .string(to)]]],
         ["type": "content_block_stop", "index": .number(Double(index))]]
    }

    static func end(_ reason: String, details: JSONValue = .null, output: Int = 40, fallback: Bool = false) -> [JSONValue] {
        var usage: [String: JSONValue] = ["output_tokens": .number(Double(output))]
        if fallback { usage["iterations"] = [["type": "message", "input_tokens": 10], ["type": "fallback_message", "input_tokens": 10]] }
        return [["type": "message_delta", "delta": ["stop_reason": .string(reason), "stop_details": details], "usage": .object(usage)],
                ["type": "message_stop"]]
    }

    static let ping: JSONValue = ["type": "ping"]

    // MARK: Fixtures

    static var textOnly: String {
        stream([messageStart()] + text(0, ["Je ", "réchauffe un peu", " la photo."]) + end("end_turn"))
    }

    static var thinkingThenText: String {
        stream([messageStart()] + thinking(0) + text(1, ["Bonne idée, ", "on y va."]) + end("end_turn"))
    }

    static func textThenTool(id: String = "toolu_01", input: String = #"{"steps":[{"action":"adjust","parameter":"temperature","amountMode":"relative","amount":15}]}"#) -> String {
        let fragments = stride(from: 0, to: input.count, by: 7).map { offset -> String in
            let start = input.index(input.startIndex, offsetBy: offset)
            let end = input.index(start, offsetBy: min(7, input.distance(from: start, to: input.endIndex)))
            return String(input[start..<end])
        }
        return stream([messageStart()] + text(0, ["Je réchauffe", " un peu."]) + tool(1, id: id, name: "apply_edits", fragments: fragments) + end("tool_use"))
    }

    static var twoParallelTools: String {
        var events: [JSONValue] = [messageStart()]
        events += text(0, ["Deux choses."])
        events += tool(1, id: "toolu_a", name: "apply_edits", fragments: [#"{"steps":[{"action":"autoEnhance","amount":70}]}"#])
        events += tool(2, id: "toolu_b", name: "propose_ideas", fragments: [#"{"ideas":[{"title":"Noir et blanc","why":"Graphique.","steps":[{"action":"applyLook","look":"mono"}]}]}"#])
        events += end("tool_use")
        return stream(events)
    }

    static var refusalBeforeOutput: String {
        stream([messageStart()] + end("refusal", details: .null, output: 0))
    }

    static var refusalWithCategory: String {
        stream([messageStart()] + text(0, ["Je "]) + end("refusal", details: ["category": "cyber"], output: 2))
    }

    /// Text, a declined tool call, the fallback marker, then more text and a tool call from the fallback model.
    static var midStreamFallback: String {
        var events: [JSONValue] = [messageStart()]
        events += thinking(0, signature: "sig-declined")
        events += text(1, ["Je vais "])
        events += tool(2, id: "toolu_declined", name: "apply_edits", fragments: [#"{"steps":[{"action":"autoEnhance"}]}"#])
        events += fallback(3)
        events += text(4, ["retirer le chien."])
        events += tool(5, id: "toolu_ok", name: "apply_edits", fragments: [#"{"steps":[{"action":"removeObject","target":"dog"}]}"#])
        events += end("tool_use", fallback: true)
        return stream(events)
    }

    static var maxTokensInToolInput: String {
        stream([messageStart()] + text(0, ["Je m'en occupe."]) + tool(1, id: "toolu_cut", name: "apply_edits", fragments: [#"{"steps":[{"action":"adj"#]) + end("max_tokens"))
    }

    static var overloadedError: String {
        stream([messageStart(), ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]])
    }

    static var withPingAndUnknown: String {
        var events: [JSONValue] = [messageStart(), ping, ["type": "brand_new_event", "x": 1]]
        events.append(["type": "content_block_start", "index": 0, "content_block": ["type": "mystery_block", "payload": [1, 2]]])
        events.append(["type": "content_block_stop", "index": 0])
        events += text(1, ["Ok."])
        events += end("end_turn")
        return stream(events)
    }
}

// MARK: - Fakes

/// Replays scripted replies and records every request.
final class FakeTransport: ClaudeTransport, @unchecked Sendable {
    enum Reply {
        case sse(String, chunk: Int? = nil)
        case http(status: Int, body: String, headers: [String: String] = [:])
        /// Never sends a byte; ends only when cancelled.
        case hang
        /// Sends these bytes, then nothing more.
        case bytesThenHang(String)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [ClaudeHTTPRequest] = []
    private(set) var sent: [ClaudeHTTPRequest] = []
    private(set) var cancelled = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requestBodies: [JSONValue] {
        lock.withLock { requests }.compactMap { $0.body.flatMap { try? JSONValue.parse(String(decoding: $0, as: UTF8.self)) } }
    }

    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .http(status: 500, body: #"{"type":"error","error":{"type":"api_error","message":"script exhausted"}}"#) : replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.lock.withLock { self?.cancelled += 1 } }
            }
            switch reply {
            case .sse(let text, let chunk):
                let bytes = Array(text.utf8)
                let size = chunk ?? bytes.count
                var offset = 0
                while offset < bytes.count {
                    continuation.yield(Data(bytes[offset..<min(bytes.count, offset + size)]))
                    offset += size
                }
                continuation.finish()
            case .http(let status, let body, let headers):
                continuation.finish(throwing: ClaudeAPIError(status: status, body: Data(body.utf8), headers: headers))
            case .hang:
                break
            case .bytesThenHang(let text):
                continuation.yield(Data(text.utf8))
            }
        }
    }

    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        lock.withLock { sent.append(request) }
        return (200, [:], Data("{}".utf8))
    }
}

/// Time in tests: sleeps are scaled down so watchdogs fire in milliseconds.
struct ScaledClock: LiveClock {
    var scale = 0.01

    func now() -> Double { ProcessInfo.processInfo.systemUptime / scale }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * scale * 1_000_000_000))
    }
}

/// Records the calls a brain makes and answers them as scripted.
@MainActor final class FakeToolHandler: LiveToolHandler {
    var intentContext = IntentContext.photo
    private(set) var calls: [LiveToolCall] = []
    var version = 10
    /// Status for every apply_edits step (applied by default).
    var stepStatus: LiveStepResult.Status = .applied

    nonisolated init() {}

    func context() -> IntentContext { intentContext }

    func perform(_ call: LiveToolCall) async -> LiveToolResult {
        calls.append(call)
        switch call.tool {
        case .applyEdits(let intents):
            let status = stepStatus
            let steps = intents.enumerated().map { LiveStepResult(index: $0.offset, action: $0.element.action, status: status, label: status == .applied ? $0.element.summary : nil,
                                                                  message: status == .applied ? nil : "Which one?", candidates: status == .needsClarification ? ["dog (left)", "dog (right)"] : []) }
            if steps.contains(where: { $0.status == .applied }) { version += 1 }
            return ToolResultEncoder.applyEdits(LiveExecution(steps: steps, version: version, canUndo: true))
        case .undo(_, let redo, _):
            version += 1
            return ToolResultEncoder.undo(labels: ["Warmth +15"], redo: redo, version: version)
        case .compare:
            return ToolResultEncoder.compare()
        case .proposeIdeas(let ideas):
            let valid = ideas.filter { !$0.steps.isEmpty }
            return ToolResultEncoder.ideas(shown: valid.count, replaced: ideas.count - valid.count)
        }
    }
}

extension LiveUserTurn {
    static func speech(_ text: String, id: Int = 1, version: Int = 10, image: LiveImage? = nil, mode: EditorMode = .photo) -> LiveUserTurn {
        var state = LiveEditorState(mode: mode, version: version)
        state.canvasPixels = PSSize(width: 4032, height: 3024)
        return LiveUserTurn(id: id, kind: .speech, text: text, language: NormalizedUtterance(text).language, image: image, editorState: state)
    }
}

/// Collects a brain's events, or the error that ended them.
func collect(_ stream: AsyncThrowingStream<LiveBrainEvent, Error>) async -> (events: [LiveBrainEvent], error: Error?) {
    var events: [LiveBrainEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

extension Array where Element == LiveBrainEvent {
    var spoken: String {
        compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    var completion: LiveTurnEnd? {
        compactMap { if case .completed(let end) = $0 { return end } else { return nil } }.last
    }

    var toolNames: [LiveToolName] {
        compactMap { if case .toolStarted(_, let name, _) = $0 { return name } else { return nil } }
    }
}
