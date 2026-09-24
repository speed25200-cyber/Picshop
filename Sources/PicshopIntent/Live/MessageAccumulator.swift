import Foundation

/// A tool call as it came off the stream, before validation.
public struct RawToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    /// The concatenated partial_json, or the start input serialized ({}) when no delta arrived.
    public var rawInput: String
    public var blockIndex: Int

    public init(id: String, name: String, rawInput: String, blockIndex: Int) {
        self.id = id
        self.name = name
        self.rawInput = rawInput
        self.blockIndex = blockIndex
    }
}

/// What a streamed event means to the brain.
public enum AccumulatorOutput: Sendable, Equatable {
    case text(String)
    case toolStarted(id: String, name: String)
    case toolFragment(id: String, fragment: String)
    case toolCompleted(RawToolUse)
    case fallback(from: String?, to: String?)
}

/// Rebuilds one assistant message from its stream events.
public struct MessageAccumulator: Sendable {
    private enum Block: Sendable {
        case text(String)
        case thinking(text: String, signature: String)
        case redactedThinking(String)
        case toolUse(id: String, name: String, start: JSONValue, partial: String, hasDelta: Bool, done: Bool)
        case fallback(JSONValue)
        case unknown(JSONValue)
    }

    public private(set) var id: String?
    public private(set) var model: String?
    public private(set) var stopReason: StopReason?
    public private(set) var stopDetails: JSONValue?
    public private(set) var usage = ClaudeUsage()
    public private(set) var lastFallbackIndex: Int?
    /// message_stop seen.
    public private(set) var isComplete = false
    /// A text delta or a tool_use block start arrived: the first visible output.
    public private(set) var hasVisibleOutput = false
    private var blocks: [Int: Block] = [:]

    public init() {}

    public mutating func apply(_ event: ClaudeStreamEvent) -> [AccumulatorOutput] {
        switch event {
        case .messageStart(let id, let model, let usage):
            self.id = id
            self.model = model
            self.usage = usage
            return []
        case .blockStart(let index, let block):
            switch block["type"]?.string {
            case "text":
                let initial = block["text"]?.string ?? ""
                blocks[index] = .text(initial)
                if !initial.isEmpty {
                    hasVisibleOutput = true
                    return [.text(initial)]
                }
                return []
            case "thinking":
                blocks[index] = .thinking(text: block["thinking"]?.string ?? "", signature: block["signature"]?.string ?? "")
                return []
            case "redacted_thinking":
                blocks[index] = .redactedThinking(block["data"]?.string ?? "")
                return []
            case "tool_use":
                let id = block["id"]?.string ?? ""
                let name = block["name"]?.string ?? ""
                blocks[index] = .toolUse(id: id, name: name, start: block["input"] ?? [:], partial: "", hasDelta: false, done: false)
                hasVisibleOutput = true
                return [.toolStarted(id: id, name: name)]
            case "fallback":
                blocks[index] = .fallback(block)
                lastFallbackIndex = max(lastFallbackIndex ?? index, index)
                return [.fallback(from: block["from"]?["model"]?.string, to: block["to"]?["model"]?.string)]
            default:
                blocks[index] = .unknown(block)
                return []
            }
        case .textDelta(let index, let text):
            guard case .text(let current) = blocks[index] ?? .text("") else { return [] }
            blocks[index] = .text(current + text)
            guard !text.isEmpty else { return [] }
            hasVisibleOutput = true
            return [.text(text)]
        case .thinkingDelta(let index, let text):
            if case .thinking(let current, let signature) = blocks[index] { blocks[index] = .thinking(text: current + text, signature: signature) }
            return []
        case .signatureDelta(let index, let signature):
            if case .thinking(let text, let current) = blocks[index] { blocks[index] = .thinking(text: text, signature: current + signature) }
            return []
        case .inputJSONDelta(let index, let fragment):
            guard case .toolUse(let id, let name, let start, let partial, _, let done) = blocks[index] else { return [] }
            blocks[index] = .toolUse(id: id, name: name, start: start, partial: partial + fragment, hasDelta: true, done: done)
            return fragment.isEmpty ? [] : [.toolFragment(id: id, fragment: fragment)]
        case .otherDelta:
            return []
        case .blockStop(let index):
            guard case .toolUse(let id, let name, let start, let partial, let hasDelta, _) = blocks[index] else { return [] }
            blocks[index] = .toolUse(id: id, name: name, start: start, partial: partial, hasDelta: hasDelta, done: true)
            return [.toolCompleted(RawToolUse(id: id, name: name, rawInput: hasDelta ? partial : start.serialized(), blockIndex: index))]
        case .messageDelta(let stopReason, let stopDetails, let usage):
            if let stopReason { self.stopReason = stopReason }
            if let stopDetails { self.stopDetails = stopDetails }
            if let usage { self.usage = self.usage.merged(with: usage) }
            return []
        case .messageStop:
            isComplete = true
            return []
        case .ping, .error:
            return []
        }
    }

    /// The message by block index. A tool_use input is its strict parse, or {} when invalid.
    public func content() -> [ClaudeContentBlock] {
        blocks.keys.sorted().compactMap { index in
            switch blocks[index]! {
            case .text(let text): return .text(text)
            case .thinking(let text, let signature): return .thinking(text: text, signature: signature)
            case .redactedThinking(let data): return .redactedThinking(data: data)
            case .toolUse(let id, let name, let start, let partial, let hasDelta, _):
                let input = hasDelta ? ((try? JSONValue.parse(partial)) ?? [:]) : start
                return .toolUse(id: id, name: name, input: input.object == nil ? [:] : input)
            case .fallback(let raw): return .fallback(raw: raw)
            case .unknown(let raw): return .unknown(raw: raw)
            }
        }
    }

    /// Completed tool_use blocks after the last fallback block, in block order.
    public func executableToolUses() -> [RawToolUse] {
        blocks.keys.sorted().compactMap { index in
            guard index > (lastFallbackIndex ?? -1), case .toolUse(let id, let name, let start, let partial, let hasDelta, let done) = blocks[index], done else { return nil }
            return RawToolUse(id: id, name: name, rawInput: hasDelta ? partial : start.serialized(), blockIndex: index)
        }
    }

    public var hasToolUse: Bool {
        blocks.values.contains { if case .toolUse = $0 { return true } else { return false } }
    }

    /// Every text block, joined in order.
    public var text: String {
        blocks.keys.sorted().compactMap { index in
            if case .text(let text) = blocks[index]! { return text }
            return nil
        }.joined()
    }

    /// Whether a text block with words comes before the first tool_use block.
    public var hasTextBeforeFirstToolUse: Bool {
        for index in blocks.keys.sorted() {
            switch blocks[index]! {
            case .toolUse: return false
            case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return true
            default: continue
            }
        }
        return false
    }
}
