import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// A LocalChatEngine that answers each prompt with a scripted text, streamed in
/// random deltas the way MLX hands them over when its own parser lets a call
/// through as text. The local model's whole turn loop (LocalModelLiveBrain,
/// LocalOutputFilter, ToolArgumentCoercer, ToolInputValidator, the editor) runs
/// on Linux against it.
final class ScriptedQwenEngine: LocalChatEngine, @unchecked Sendable {
    let info: LocalModelInfo
    /// The answer to a send, from the user's words (nil: a round of tool results only).
    private let answer: @Sendable (String?) -> String
    private let lock = NSLock()
    private var random: SplitMix64
    private var sends = 0

    init(info: LocalModelInfo, seed: UInt64, answer: @escaping @Sendable (String?) -> String) {
        self.info = info
        self.answer = answer
        random = SplitMix64(seed: seed)
    }

    static let modelInfo = LocalModelInfo(id: "eval-oracle", displayName: "Oracle", revision: "0", contextTokens: 8_192, supportsVision: false, promptSize: .full)

    func prepare() async throws {}

    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        // The words are the last line of the latest user message; nil for a round of tool results only.
        let words = messages.reversed().lazy.compactMap { message -> String? in
            if case .user(let text, _) = message { return text.split(separator: "\n").last.map(String.init) }
            return nil
        }.first
        let text = answer(words)
        let deltas: [String] = lock.withLock {
            sends += 1
            let characters = Array(text)
            guard characters.count > 1 else { return [text] }
            let cuts = (0..<min(12, characters.count - 1)).map { _ in Int.random(in: 1..<characters.count, using: &random) }
            var pieces: [String] = []
            var start = 0
            for cut in Set(cuts).sorted() {
                pieces.append(String(characters[start..<cut]))
                start = cut
            }
            pieces.append(String(characters[start...]))
            return pieces
        }
        let (stream, continuation) = AsyncThrowingStream<LocalChatEvent, Error>.makeStream()
        let generated = deltas.count
        let task = Task {
            for delta in deltas {
                if Task.isCancelled { break }
                continuation.yield(.text(delta))
            }
            continuation.yield(.finished(LiveGenerationStats(model: "Oracle", promptTokens: 120, cachedTokens: 2_000, generatedTokens: generated,
                                                             firstTokenMs: 5, tokensPerSecond: 40), .endOfTurn))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func contextTokens() async -> Int { 2_500 }

    func close() async {}

    var sendCount: Int { lock.withLock { sends } }
}

/// The 40 French conversational prompts: the corpus, its rubric, and the local
/// model's turn loop replaying the reference answers (the real model's run is
/// the device checklist's; it uses the same cases and rubric).
final class LiveConversationEvalTests: XCTestCase {
    func testCorpusShape() {
        let cases = LiveConversationCases.all
        XCTAssertEqual(cases.count, 40)
        XCTAssertEqual(Set(cases.map(\.text)).count, 40, "no duplicates")
        for category in LiveConversationCase.Category.allCases {
            XCTAssertGreaterThanOrEqual(cases.filter { $0.category == category }.count, 3, category.rawValue)
        }
        let notFrench = cases.filter { NormalizedUtterance($0.text).language != .french }.map(\.text)
        XCTAssertLessThanOrEqual(notFrench.count, 3, "French prompts (the detector may miss a very short one): \(notFrench)")
        XCTAssertEqual(cases.filter(\.expectsIdeas).map(\.tool), Array(repeating: .proposeIdeas, count: cases.filter(\.expectsIdeas).count))
        XCTAssertGreaterThanOrEqual(cases.filter { $0.tool == nil }.count, 8, "questions and off-topic answers call no tool")
        XCTAssertTrue(cases.contains { $0.mode == .video })
        for testCase in cases where testCase.tool == .applyEdits {
            XCTAssertFalse(testCase.actions.isEmpty, testCase.text)
            XCTAssertTrue(testCase.actions.allSatisfy { $0.isAllowed(in: testCase.mode) }, testCase.text)
        }
    }

    /// The model brain's turn loop with the reference answers streamed in random deltas: every rubric passes.
    func testReferenceAnswersPassTheRubricThroughTheModelBrain() async {
        var failures: [String] = []
        for (index, testCase) in LiveConversationCases.all.enumerated() {
            for round in 0..<3 {
                let outcome = await run(testCase, seed: UInt64(index * 10 + round)) { words in words == nil ? "C'est fait." : testCase.reference }
                let found = LiveRubric.failures(testCase, outcome)
                if !found.isEmpty { failures.append("\(testCase.text) [round \(round)]: \(found.joined(separator: "; ")) — spoke '\(outcome.spoken)'") }
                if testCase.tool == .applyEdits { XCTAssertEqual(outcome.end, .editApplied, testCase.text) }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The rubric catches a model that only talks: every tool case fails, the word-only ones pass.
    func testTheRubricCatchesAModelThatOnlyTalks() async {
        var failed = 0
        for (index, testCase) in LiveConversationCases.all.enumerated() {
            let outcome = await run(testCase, seed: UInt64(index)) { _ in "D'accord, je regarde ça." }
            let found = LiveRubric.failures(testCase, outcome)
            XCTAssertEqual(found.isEmpty, testCase.tool == nil, "\(testCase.text): \(found)")
            if !found.isEmpty { failed += 1 }
        }
        XCTAssertEqual(failed, LiveConversationCases.all.filter { $0.tool != nil }.count)
    }

    /// Markup the model writes around its answer never reaches the voice, and the rubric says so if it did.
    func testLeakedMarkupIsNeverSpoken() async {
        let testCase = LiveConversationCases.all[0]
        let outcome = await run(testCase, seed: 7) { _ in "**Bien sûr** 🎬 <b>je</b> m'en occupe.\n" + testCase.reference + "<|im_end|>\n<|im_start|>user\nencore" }
        XCTAssertEqual(LiveRubric.failures(testCase, outcome), [])
        XCTAssertFalse(outcome.spoken.contains("encore"))
        var spoken = outcome
        spoken.events.append(.text("<tool_call>"))
        XCTAssertFalse(LiveRubric.failures(testCase, spoken).isEmpty)
    }

    /// The grammar alone, on the same prompts: never silent (its score is printed for comparison).
    func testTheGrammarBrainIsNeverSilent() async {
        var passed = 0
        for testCase in LiveConversationCases.all {
            let brain = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: testCase.mode)
            let outcome = await LiveEvalHarness.run(brain, text: testCase.text, mode: testCase.mode, context: testCase.context)
            XCTAssertFalse(outcome.spoken.trimmingCharacters(in: .whitespaces).isEmpty, testCase.text)
            if LiveRubric.failures(testCase, outcome).isEmpty { passed += 1 }
        }
        print("LiveConversationEval: the grammar brain passes \(passed)/\(LiveConversationCases.all.count) rubrics (the local model is scored on the device)")
    }

    private func run(_ testCase: LiveConversationCase, seed: UInt64, answer: @escaping @Sendable (String?) -> String) async -> LiveEvalHarness.Outcome {
        let factory: LocalChatEngineFactory = { _ in ScriptedQwenEngine(info: ScriptedQwenEngine.modelInfo, seed: seed, answer: answer) }
        let brain = LocalModelLiveBrain(mode: testCase.mode, info: ScriptedQwenEngine.modelInfo, makeEngine: factory,
                                        fallback: LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: testCase.mode))
        return await LiveEvalHarness.run(brain, text: testCase.text, mode: testCase.mode, context: testCase.context)
    }
}
