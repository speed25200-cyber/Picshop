import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// The local-brain tests' own fakes, independent of the Live fixtures: the
// editor the model's calls land on, a fast clock, turn builders and an event
// collector.

/// Time for the brain's deadlines, scaled down so a 6 s watchdog fires in 60 ms.
struct BrainTestClock: LiveClock {
    var scale = 0.01

    func now() -> Double { ProcessInfo.processInfo.systemUptime / scale }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * scale * 1_000_000_000))
    }
}

/// The editor: records every call and answers it as scripted.
@MainActor final class ScriptedToolHandler: LiveToolHandler {
    var intentContext = IntentContext.photo
    private(set) var calls: [LiveToolCall] = []
    var version = 10
    /// Status of every apply_edits step (applied unless a test says otherwise).
    var stepStatus: LiveStepResult.Status = .applied

    nonisolated init() {}

    func context() -> IntentContext { intentContext }

    func perform(_ call: LiveToolCall) async -> LiveToolResult {
        calls.append(call)
        switch call.tool {
        case .applyEdits(let intents):
            let status = stepStatus
            let steps = intents.enumerated().map { index, intent in
                LiveStepResult(index: index, action: intent.action, status: status, label: status == .applied ? "Warmth +15" : nil,
                               message: status == .applied ? nil : "Sélectionne d'abord la zone.", needsUser: status == .needsUser ? "select_region" : nil)
            }
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

    var toolNames: [LiveToolName] {
        calls.map { call in
            switch call.tool {
            case .applyEdits: return .applyEdits
            case .undo: return .undo
            case .compare: return .compareBeforeAfter
            case .proposeIdeas: return .proposeIdeas
            }
        }
    }
}

enum BrainTurns {
    static func state(version: Int = 10, mode: EditorMode = .photo) -> LiveEditorState {
        var state = LiveEditorState(mode: mode, version: version)
        state.canvasPixels = PSSize(width: 4032, height: 3024)
        return state
    }

    static func image(version: Int) -> LiveImage {
        LiveImage(jpeg: Data([0xFF, 0xD8, 0xFF, UInt8(version % 256)]), pixelWidth: 768, pixelHeight: 576, version: version)
    }

    static func speech(_ text: String, id: Int = 1, version: Int = 10, image: LiveImage? = nil) -> LiveUserTurn {
        LiveUserTurn(id: id, kind: .speech, text: text, language: .french, image: image, editorState: state(version: version))
    }

    static func sessionStart(id: Int = 1, version: Int = 10, image: LiveImage? = nil) -> LiveUserTurn {
        LiveUserTurn(id: id, kind: .sessionStart, text: "", language: .french, image: image, editorState: state(version: version))
    }
}

/// A brain's events, or the error that ended them.
func drain(_ stream: AsyncThrowingStream<LiveBrainEvent, Error>) async -> (events: [LiveBrainEvent], error: Error?) {
    var events: [LiveBrainEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

extension Array where Element == LiveBrainEvent {
    var said: String {
        compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }

    var end: LiveTurnEnd? {
        compactMap { if case .completed(let end) = $0 { return end } else { return nil } }.last
    }

    var startedTools: [LiveToolName] {
        compactMap { if case .toolStarted(_, let name, _) = $0 { return name } else { return nil } }
    }

    var proposedIdeas: [LiveIdea] {
        flatMap { event -> [LiveIdea] in if case .ideas(let ideas) = event { return ideas } else { return [] } }
    }

    /// Event kinds in order, for sequence checks.
    var kinds: [String] {
        map { event in
            switch event {
            case .started: return "started"
            case .text: return "text"
            case .toolStarted: return "toolStarted"
            case .toolFinished: return "toolFinished"
            case .ideas: return "ideas"
            case .stats: return "stats"
            case .completed: return "completed"
            }
        }
    }
}

extension LocalChatMessage {
    var userText: String? {
        if case .user(let text, _) = self { return text }
        return nil
    }

    var hasImage: Bool {
        if case .user(_, let image) = self { return image != nil }
        return false
    }

    var isToolResult: Bool {
        if case .toolResult = self { return true }
        return false
    }

    var toolResultContent: String? {
        if case .toolResult(_, _, let content) = self { return content }
        return nil
    }
}
