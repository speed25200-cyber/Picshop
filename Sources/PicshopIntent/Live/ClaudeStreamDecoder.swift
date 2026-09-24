import Foundation

/// One Messages API streaming event, keyed on `data.type` (the SSE event
/// line is informational only).
public enum ClaudeStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String, usage: ClaudeUsage)
    /// text | thinking | redacted_thinking | tool_use | fallback | anything else, as sent.
    case blockStart(index: Int, block: JSONValue)
    case textDelta(index: Int, String)
    case thinkingDelta(index: Int, String)
    case signatureDelta(index: Int, String)
    case inputJSONDelta(index: Int, String)
    case otherDelta(index: Int, JSONValue)
    case blockStop(index: Int)
    /// usage is the raw object: its fields are cumulative and merge over message_start's.
    case messageDelta(stopReason: StopReason?, stopDetails: JSONValue?, usage: JSONValue?)
    case messageStop, ping
    case error(type: String, message: String)

    /// nil for event types this client does not know (they are skipped).
    public static func decode(_ event: SSEEvent) throws -> ClaudeStreamEvent? {
        let json = try JSONValue.parse(event.data)
        guard let type = json["type"]?.string else { throw JSONParseError(offset: 0, reason: "event without a type") }
        switch type {
        case "message_start":
            let message = json["message"] ?? [:]
            return .messageStart(id: message["id"]?.string ?? "", model: message["model"]?.string ?? "",
                                 usage: message["usage"].map(ClaudeUsage.init(json:)) ?? ClaudeUsage())
        case "content_block_start":
            return .blockStart(index: json["index"]?.int ?? 0, block: json["content_block"] ?? [:])
        case "content_block_delta":
            let index = json["index"]?.int ?? 0
            let delta = json["delta"] ?? [:]
            switch delta["type"]?.string {
            case "text_delta": return .textDelta(index: index, delta["text"]?.string ?? "")
            case "thinking_delta": return .thinkingDelta(index: index, delta["thinking"]?.string ?? "")
            case "signature_delta": return .signatureDelta(index: index, delta["signature"]?.string ?? "")
            case "input_json_delta": return .inputJSONDelta(index: index, delta["partial_json"]?.string ?? "")
            default: return .otherDelta(index: index, delta)
            }
        case "content_block_stop":
            return .blockStop(index: json["index"]?.int ?? 0)
        case "message_delta":
            let delta = json["delta"] ?? [:]
            // JSONValue is nil-literal convertible: spell the Optional out so null means absent.
            let raw = delta["stop_details"]
            let details: JSONValue? = raw == .null ? Optional<JSONValue>.none : raw
            return .messageDelta(stopReason: delta["stop_reason"]?.string.map(StopReason.init(raw:)), stopDetails: details, usage: json["usage"])
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            let error = json["error"] ?? [:]
            return .error(type: error["type"]?.string ?? "error", message: error["message"]?.string ?? "")
        default:
            return nil
        }
    }
}
