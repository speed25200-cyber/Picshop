import Foundation
import PicshopCore

/// What may be echoed back of a response. After a server-side fallback, the
/// thinking, redacted thinking and tool_use blocks before the last fallback
/// block are dropped, and so are the fallback markers; everything else is
/// echoed unchanged (thinking with empty text and its signature included).
public enum EchoPolicy {
    public static func sanitize(_ blocks: [ClaudeContentBlock]) -> [ClaudeContentBlock] {
        guard let last = blocks.lastIndex(where: { if case .fallback = $0 { return true } else { return false } }) else {
            return blocks.filter { !$0.isEmptyText }
        }
        return blocks.enumerated().compactMap { index, block in
            switch block {
            case .fallback: return nil
            case .thinking, .redactedThinking, .toolUse: return index < last ? nil : block
            case .text(let text, _): return text.isEmpty ? nil : block
            default: return block
            }
        }
    }
}

/// When the current image goes with a turn: on session start and on the first
/// turn of an epoch, then only when the picture changed; one per turn.
public struct ImageAttachmentPolicy: Sendable, Equatable {
    public static let maxPerEpoch = 3

    public private(set) var lastAttachedVersion: Int?
    public private(set) var lastAttachedFrameKey: String?
    public private(set) var imagesInEpoch = 0

    public init() {}

    public func wants(version: Int, frameKey: String?, kind: LiveUserTurn.Kind, firstTurnOfEpoch: Bool) -> Bool {
        if kind == .sessionStart || firstTurnOfEpoch { return true }
        return lastAttachedVersion != version || lastAttachedFrameKey != frameKey
    }

    /// The next image would be one too many for this epoch: compact first.
    public var epochIsFull: Bool { imagesInEpoch >= Self.maxPerEpoch }

    public mutating func noteAttached(version: Int, frameKey: String?) {
        lastAttachedVersion = version
        lastAttachedFrameKey = frameKey
        imagesInEpoch += 1
    }

    public mutating func resetEpoch() {
        imagesInEpoch = 0
    }
}

/// The conversation of one Live session with Claude, append-only so every
/// request's bytes extend the previous one and the prompt cache keeps hitting.
public struct LiveConversation: Sendable {
    public struct Checkpoint: Sendable, Equatable {
        let count: Int
        let open: [ClaudeContentBlock]
        let images: ImageAttachmentPolicy
        let turns: Int
        let exchanges: [Exchange]
        let epoch: Int
        let lastImageAspect: Double?
    }

    /// One user turn and what the assistant said back, for the session summary.
    public struct Exchange: Sendable, Equatable {
        public var user: String
        public var assistant: String
    }

    public static let epochTokenLimit = 60_000
    public static let epochTurnLimit = 40

    public private(set) var messages: [ClaudeMessage] = []
    /// tool_result blocks owed to the next user message, placed first.
    public private(set) var openUserContent: [ClaudeContentBlock] = []
    public private(set) var epoch = 0
    public private(set) var userTurnsInEpoch = 0
    public private(set) var exchanges: [Exchange] = []
    /// Width / height of the last image sent, for grounding points.
    public private(set) var lastImageAspect: Double?
    public var images = ImageAttachmentPolicy()

    public init() {}

    public func checkpoint() -> Checkpoint {
        Checkpoint(count: messages.count, open: openUserContent, images: images, turns: userTurnsInEpoch, exchanges: exchanges, epoch: epoch,
                   lastImageAspect: lastImageAspect)
    }

    public mutating func rollback(to checkpoint: Checkpoint) {
        guard checkpoint.epoch == epoch else { return }
        messages.removeSubrange(min(checkpoint.count, messages.count)...)
        openUserContent = checkpoint.open
        images = checkpoint.images
        userTurnsInEpoch = checkpoint.turns
        exchanges = checkpoint.exchanges
        lastImageAspect = checkpoint.lastImageAspect
    }

    public var isFirstTurnOfEpoch: Bool { userTurnsInEpoch == 0 }

    /// A new user message: owed tool results first, then the turn's blocks; then the turn's
    /// context as a role:system message.
    public mutating func appendUserTurn(blocks: [ClaudeContentBlock], systemText: String?) {
        let content = openUserContent + blocks
        openUserContent = []
        if messages.last?.role == .user {
            // Two user messages in a row would be refused: the earlier one never got an answer.
            messages.append(ClaudeMessage(role: .assistant, content: [.text("...")]))
        } else if messages.last?.role == .system {
            messages.append(ClaudeMessage(role: .assistant, content: [.text("...")]))
        }
        messages.append(ClaudeMessage(role: .user, content: content))
        if let systemText, !systemText.isEmpty { messages.append(.system(systemText)) }
        userTurnsInEpoch += 1
        let words = blocks.compactMap(\.textValue).filter { !$0.hasPrefix("<") }.joined(separator: " ")
        exchanges.append(Exchange(user: words, assistant: ""))
    }

    /// The assistant's response, sanitized by EchoPolicy.
    public mutating func appendAssistant(_ blocks: [ClaudeContentBlock]) {
        var content = EchoPolicy.sanitize(blocks)
        if content.isEmpty { content = [.text("...")] }
        messages.append(ClaudeMessage(role: .assistant, content: content))
        let said = content.compactMap(\.textValue).joined(separator: " ")
        if !said.isEmpty, !exchanges.isEmpty {
            exchanges[exchanges.count - 1].assistant += (exchanges[exchanges.count - 1].assistant.isEmpty ? "" : " ") + said
        }
    }

    /// Results for the tool_use blocks of the last assistant message, then fresh context when the document changed.
    public mutating func appendToolResults(_ results: [ClaudeContentBlock], systemText: String?) {
        messages.append(ClaudeMessage(role: .user, content: openUserContent + results))
        openUserContent = []
        if let systemText, !systemText.isEmpty { messages.append(.system(systemText)) }
    }

    /// Results kept for the next user message (the edit spoke for itself, or the turn ended at the limit).
    public mutating func deferToolResults(_ results: [ClaudeContentBlock]) {
        openUserContent += results
    }

    /// Records the aspect of an image attached this turn (the policy is noted by the caller).
    public mutating func noteImageAspect(_ aspect: Double?) {
        lastImageAspect = aspect
    }

    /// Repairs the history after the user cut in.
    /// - spoken: what the voice said of the reply in flight; stored as exactly that plus " ...".
    /// - executedResults: results of the calls that ran; their tool_use blocks stay, every other one goes.
    /// A turn cancelled before any output is rolled back by the caller instead.
    public mutating func recordInterruption(spoken: String, executedResults: [ClaudeContentBlock]) {
        let partial = Self.partial(spoken)
        guard let last = messages.last else { return }
        if last.role == .assistant, last.content.contains(where: \.isToolUse), openUserContent.isEmpty {
            // Cut during the tools of a response that was already appended.
            let executed = Set(executedResults.compactMap(\.toolUseID))
            if executed.isEmpty {
                messages[messages.count - 1].content = [.text(partial)]
            } else {
                messages[messages.count - 1].content.removeAll { block in
                    guard case .toolUse(let id, _, _) = block else { return false }
                    return !executed.contains(id)
                }
                let order = messages[messages.count - 1].content.compactMap(\.toolUseID)
                openUserContent = order.compactMap { id in executedResults.first { $0.toolUseID == id } }
            }
        } else if last.role == .assistant {
            // The reply had fully arrived; the user heard only part of it.
            guard !last.content.contains(where: \.isToolUse) else { return }
            let kept = last.content.filter { if case .text = $0 { return false } else { return true } }
            messages[messages.count - 1].content = kept + [.text(partial)]
        } else {
            // Cut while the reply streamed: nothing of it was appended yet.
            messages.append(ClaudeMessage(role: .assistant, content: [.text(partial)]))
        }
        if !exchanges.isEmpty { exchanges[exchanges.count - 1].assistant = partial }
    }

    /// "what was said ..." — or "..." when nothing was heard.
    static func partial(_ spoken: String) -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + " ..."
    }

    /// Ends a turn that stopped without a reply (an error or a refusal after tools ran), so the next user message alternates.
    public mutating func closeTurn(with text: String) {
        guard let last = messages.last, last.role != .assistant else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ClaudeMessage(role: .assistant, content: [.text(words.isEmpty ? "..." : words)]))
        if !exchanges.isEmpty, !words.isEmpty { exchanges[exchanges.count - 1].assistant = words }
    }

    /// What would make the API refuse the request: checked before every send.
    public func invariantViolations() -> [String] {
        var problems: [String] = []
        guard let first = messages.first else { return ["no messages"] }
        if first.role != .user { problems.append("the first message is not from the user") }
        var previousSpeaker: ClaudeRole?
        for (index, message) in messages.enumerated() {
            if message.content.isEmpty || message.content.allSatisfy(\.isEmptyText) { problems.append("message \(index) is empty") }
            switch message.role {
            case .system:
                if index == 0 || messages[index - 1].role != .user { problems.append("system message \(index) does not follow a user message") }
                if index + 1 < messages.count, messages[index + 1].role != .assistant { problems.append("system message \(index) is not followed by an assistant message") }
                if !message.content.allSatisfy({ $0.textValue != nil }) { problems.append("system message \(index) is not text") }
            case .user, .assistant:
                if previousSpeaker == message.role { problems.append("message \(index) repeats the \(message.role.rawValue) role") }
                previousSpeaker = message.role
            }
            guard message.role == .assistant else { continue }
            let uses = message.content.compactMap { block -> String? in
                guard case .toolUse(let id, _, _) = block else { return nil }
                return id
            }
            guard !uses.isEmpty else { continue }
            let nextUser = messages[(index + 1)...].first { $0.role == .user }
            if let nextUser {
                let leading = nextUser.content.prefix { $0.isToolResult }.compactMap(\.toolUseID)
                if Set(leading) != Set(uses) { problems.append("tool_use in message \(index) is not answered first in the next user message") }
            } else if index != messages.count - 1 || Set(openUserContent.compactMap(\.toolUseID)) != Set(uses) {
                problems.append("tool_use in message \(index) has no result")
            }
        }
        return problems
    }

    /// chars / 3.2, plus 1,200 per image and 400 per tool result.
    public var estimatedTokens: Int {
        var characters = 0, images = 0, results = 0
        func count(_ block: ClaudeContentBlock) {
            switch block {
            case .text(let text, _): characters += text.count
            case .image: images += 1
            case .thinking(let text, let signature): characters += text.count + signature.count / 4
            case .redactedThinking(let data): characters += data.count / 4
            case .toolUse(_, let name, let input): characters += name.count + input.serialized().count
            case .toolResult(_, let content, _):
                results += 1
                content.forEach(count)
            case .fallback, .unknown: break
            }
        }
        for message in messages { message.content.forEach(count) }
        openUserContent.forEach(count)
        return Int(Double(characters) / 3.2) + images * 1_200 + results * 400
    }

    /// Past the epoch's size or turn limits.
    public var needsCompaction: Bool {
        estimatedTokens > Self.epochTokenLimit || userTurnsInEpoch >= Self.epochTurnLimit
    }

    /// Starts a new epoch whose first user message will open with [image] + the summary.
    /// Owed tool results are dropped: their tool_use blocks are gone with the old epoch.
    public mutating func compact(summary: String, image: ClaudeContentBlock?) {
        messages = []
        openUserContent = (image.map { [$0] } ?? []) + [.text(summary)]
        epoch += 1
        userTurnsInEpoch = 0
        images.resetEpoch()
    }
}

/// The local, deterministic summary a new epoch starts from. No model call.
public enum SessionSummary {
    public static func build(applied: [String], exchanges: [LiveConversation.Exchange], ideasOnScreen: [String], openQuestion: String?) -> String {
        var lines = ["<session_summary>"]
        lines.append("Earlier in this Live session (older turns were summarized):")
        lines.append("applied: " + (applied.isEmpty ? "nothing yet" : applied.suffix(12).joined(separator: "; ")))
        for exchange in exchanges.suffix(6) {
            if !exchange.user.isEmpty { lines.append("user: " + clip(exchange.user)) }
            if !exchange.assistant.isEmpty { lines.append("you: " + clip(exchange.assistant)) }
        }
        if !ideasOnScreen.isEmpty { lines.append("ideas on screen: " + ideasOnScreen.joined(separator: " | ")) }
        if let openQuestion, !openQuestion.isEmpty { lines.append("open question: " + clip(openQuestion)) }
        lines.append("</session_summary>")
        return lines.joined(separator: "\n")
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 600 ? flat : String(flat.prefix(599)) + "…"
    }
}
