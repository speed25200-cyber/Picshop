import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Runs one Live turn through any LiveBrain (the grammar, Apple's model, the local
/// model, or a scripted engine behind LocalModelLiveBrain) against a recording
/// tool handler, and keeps what a rubric needs to score it.
enum LiveEvalHarness {
    struct Outcome {
        var events: [LiveBrainEvent]
        var error: Error?
        var calls: [LiveToolCall]

        /// Everything the brain said, as the voice would say it.
        var spoken: String {
            events.compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined()
        }

        var ideas: [LiveIdea] {
            events.flatMap { event -> [LiveIdea] in
                if case .ideas(let ideas) = event { return ideas }
                return []
            }
        }

        var end: LiveTurnEnd? {
            events.lazy.compactMap { event -> LiveTurnEnd? in
                if case .completed(let end) = event { return end }
                return nil
            }.first
        }

        /// The first edit the brain ran, if any.
        var firstIntent: EditIntent? {
            for call in calls {
                if case .applyEdits(let intents) = call.tool { return intents.first }
            }
            return nil
        }

        var firstTool: LiveToolName? {
            calls.first.map { call in
                switch call.tool {
                case .applyEdits: return .applyEdits
                case .undo: return .undo
                case .compare: return .compareBeforeAfter
                case .proposeIdeas: return .proposeIdeas
                }
            }
        }
    }

    /// One user turn, spoken, on a fresh editor state.
    static func run(_ brain: any LiveBrain, text: String, mode: EditorMode, context: IntentContext, version: Int = 1) async -> Outcome {
        let handler = FakeToolHandler()
        await MainActor.run { handler.intentContext = context }
        var state = LiveEditorState(mode: mode, version: version)
        state.canvasPixels = PSSize(width: 4032, height: 3024)
        let turn = LiveUserTurn(id: 1, kind: .speech, text: text, language: NormalizedUtterance(text).language, image: nil, editorState: state)
        let (events, error) = await collect(brain.respond(to: turn, tools: handler))
        let calls = await MainActor.run { handler.calls }
        return Outcome(events: events, error: error, calls: calls)
    }
}
