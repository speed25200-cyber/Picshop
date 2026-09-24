import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The local model's turn loop on Linux: a scripted engine streams recorded
/// Qwen3.5 outputs in random deltas into LocalModelLiveBrain, which filters,
/// coerces, validates and runs them. Only contract-level behaviour is checked
/// (§6: event order, calls reach the editor, no markup is ever spoken).
final class LocalTurnLoopTests: XCTestCase {
    private func run(_ text: String, words: String = "vas-y", mode: EditorMode = .photo, seed: UInt64) async -> LiveEvalHarness.Outcome {
        let factory: LocalChatEngineFactory = { _ in ScriptedQwenEngine(info: ScriptedQwenEngine.modelInfo, seed: seed) { _ in text } }
        let brain = LocalModelLiveBrain(mode: mode, info: ScriptedQwenEngine.modelInfo, makeEngine: factory,
                                        fallback: LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: mode))
        var context = IntentContext(mode: mode)
        context.timelineDuration = 30
        context.clipCount = 2
        return await LiveEvalHarness.run(brain, text: words, mode: mode, context: context)
    }

    func testRecordedOutputsThroughTheModelBrain() async {
        for (index, sample) in RecordedQwenOutputs.all.enumerated() {
            let mode: EditorMode = sample.text.contains("setSpeed") ? .video : .photo
            for round in 0..<5 {
                let outcome = await run(sample.text, mode: mode, seed: UInt64(index * 100 + round))
                let label = "sample \(index), round \(round)"
                XCTAssertNil(outcome.error, label)
                guard case .started? = outcome.events.first else { return XCTFail("\(label): \(outcome.events)") }
                guard case .completed? = outcome.events.last else { return XCTFail("\(label): \(outcome.events)") }
                let statsIndex = outcome.events.lastIndex { if case .stats = $0 { return true } else { return false } }
                XCTAssertEqual(statsIndex, outcome.events.count - 2, "\(label): stats right before completed")
                for event in outcome.events {
                    if case .text(let text) = event {
                        XCTAssertFalse(text.contains(where: { "<>{}[]*`".contains($0) }), "\(label) spoke '\(text)'")
                        for tag in ["<tool_call", "<function=", "<think>", "<|im_"] { XCTAssertFalse(text.contains(tag), label) }
                    }
                }
                XCTAssertTrue(outcome.spoken.hasPrefix(sample.speech.split(separator: " ").first.map(String.init) ?? ""), "\(label): '\(outcome.spoken)'")
                // Every readable call reached the editor, in order (a clean edit ends the turn: later calls wait).
                let expected = sample.calls.compactMap { piece -> String? in
                    if case .toolCall(let name, _) = piece { return name }
                    return nil
                }
                let performed = outcome.calls.map { call -> String in
                    switch call.tool {
                    case .applyEdits: return "apply_edits"
                    case .undo: return "undo"
                    case .compare: return "compare_before_after"
                    case .proposeIdeas: return "propose_ideas"
                    }
                }
                XCTAssertEqual(performed, expected, label)
                if expected.contains("propose_ideas") { XCTAssertFalse(outcome.ideas.isEmpty, label) }
            }
        }
    }

    func testAMalformedCallIsSentBackNotSpoken() async {
        let outcome = await run("Oups <tool_call>apply_edits(steps=[...])</tool_call>", seed: 1)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.calls.isEmpty)
        XCTAssertFalse(outcome.spoken.contains("apply_edits"))
        XCTAssertTrue(outcome.spoken.hasPrefix("Oups"))
    }

    func testAnInvalidCallWithNothingSaidGoesToTheGrammar() async {
        // Twice an unknown look and no sentence: the rules-only grammar answers the same words.
        let bad = "<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"applyLook\", \"look\": \"mélancolie\"}]\n</parameter>\n</function>\n</tool_call>"
        let outcome = await run(bad, words: "passe en noir et blanc", seed: 2)
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.spoken.isEmpty, "never silent")
        XCTAssertEqual(outcome.firstIntent?.action, .applyLook, "the grammar ran the command")
        XCTAssertEqual(outcome.firstIntent?.look, .mono)
    }
}
