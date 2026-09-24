import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// The fakes the Live tests share: a tool handler, a clock, a log collector,
// turn builders and an event collector.

/// Time in tests: sleeps are scaled down so watchdogs fire in milliseconds.
struct ScaledClock: LiveClock {
    var scale = 0.01

    func now() -> Double { ProcessInfo.processInfo.systemUptime / scale }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * scale * 1_000_000_000))
    }
}

/// Collects the log entries a brain writes, from any thread.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LiveLogEntry] = []

    func add(_ entry: LiveLogEntry) { lock.withLock { entries.append(entry) } }
    var all: [LiveLogEntry] { lock.withLock { entries } }
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
