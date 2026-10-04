import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D22 step 2–3: the KV engine's per-turn decision, on ledgers built the way the engine builds them (step 2.2):
/// the prompt ids fed, then every id `next()` returned, the stop token included. Prompts are rendered with
/// `QwenChatTemplate` and cut into ids by `ToyTokenizer`, whose special tokens are atomic as Qwen's are, so the
/// boundaries that matter (`<|im_end|>`, the `\n` after it, the picture pads) land where the real ones do.
/// Also the picture slicing, the stop-string filter and the self-test verdict, which the engine runs as is.
final class KVTurnPlannerTests: XCTestCase {
    // MARK: Fixtures

    private let tokenizer = ToyTokenizer()
    private let setup = LocalChatSetup(system: "Tu es l'assistant photo de PicShop.", tools: [
        .object(["type": .string("function"), "function": .object(["name": .string("apply_edits"), "description": .string("Edit the photo.")])]),
    ], history: [
        .user("plus chaud", imageJPEG: nil),
        .assistant("Je réchauffe.", toolCalls: [LocalToolCall(id: "ex1", name: "apply_edits", arguments: .object(["steps": .string("[{\"action\":\"adjust\"}]")]))]),
        .toolResult(callID: "ex1", name: "apply_edits", content: "1 adjust applied: Warmth +15"),
        .assistant("C'est plus chaud.", toolCalls: []),
    ], imageMaxPixels: 196_608)

    /// The prompt for `messages` after the setup, with the generation prompt.
    private func prompt(_ messages: [LocalChatMessage]) -> [Int] {
        tokenizer.encode(QwenChatTemplate.render(setup, appending: messages))
    }

    /// The prefix snapshot's ids: the setup rendered with its generation prompt, that prompt stripped (step 3).
    private var prefix: [Int] {
        KVTurnPlanner.prefixTokens(rendered: tokenizer.encode(QwenChatTemplate.render(setup, appending: [])),
                                   generationPrompt: tokenizer.encode(QwenChatTemplate.generationPrompt))!
    }

    /// A finished turn: the prompt fed, then what `next()` returned, the stop token last.
    private func ledger(prompt: [Int], generated: String, stop: String? = QwenChatTemplate.imEnd) -> [Int] {
        prompt + tokenizer.encode(generated) + (stop.map { tokenizer.encode($0) } ?? [])
    }

    private func decide(_ ledger: [Int], _ prompt: [Int], checkpoint: Int?, media: Bool = false, verified: Bool = false) -> KVTurnDecision {
        KVTurnPlanner.decide(ledger: ledger, prompt: prompt, prefixCount: prefix.count, turnCheckpoint: checkpoint,
                             hasNewMedia: media, mediaAppendVerified: verified)
    }

    private let firstUser = LocalChatMessage.user("<editor_state v=1>\nmode: photo\n</editor_state>\nlangue: fr\nrends-la plus chaude", imageJPEG: nil)
    private let secondUser = LocalChatMessage.user("<editor_state v=2>\nnew: Warmth +15\n</editor_state>\nlangue: fr\nencore un peu", imageJPEG: nil)
    private let call = LocalToolCall(id: "c1", name: "apply_edits", arguments: .object(["steps": .string("[{\"action\":\"adjust\",\"warmth\":15}]")]))

    // MARK: Appending

    func testTheFirstTurnAppendsAfterThePrefix() {
        let first = prompt([firstUser])
        XCTAssertEqual(decide(prefix, first, checkpoint: nil), .appendSuffix(from: prefix.count))
        XCTAssertEqual(Array(first[..<prefix.count]), prefix, "the prompt starts with the snapshot")
    }

    func testAnEOSStopAppendsFromTheNewlineAfterImEnd() {
        let first = prompt([firstUser])
        let reply = "Je réchauffe la photo."
        let held = ledger(prompt: first, generated: reply)
        let next = prompt([firstUser, .assistant(reply, toolCalls: []), secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .appendSuffix(from: held.count))
        XCTAssertEqual(next[held.count], tokenizer.id("\n"), "the suffix starts at the newline after <|im_end|>")
        XCTAssertEqual(held.last, tokenizer.id(QwenChatTemplate.imEnd), "the stop token is in the ledger: it is in the cache")
    }

    func testAToolCallThatReRendersAsGeneratedAppends() {
        let first = prompt([firstUser])
        let generated = "Je réchauffe.\n\n" + QwenChatTemplate.functionCall(call)
        let held = ledger(prompt: first, generated: generated)
        let result = LocalChatMessage.toolResult(callID: "c1", name: "apply_edits", content: "1 adjust applied: Warmth +15")
        let next = prompt([firstUser, .assistant("Je réchauffe.", toolCalls: [call]), result, secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .appendSuffix(from: held.count))
    }

    func testToolResultsAloneContinueTheTurn() {
        // The brain's tool round: the results go back with no new user message.
        let first = prompt([firstUser])
        let generated = QwenChatTemplate.functionCall(call)
        let held = ledger(prompt: first, generated: generated)
        let result = LocalChatMessage.toolResult(callID: "c1", name: "apply_edits", content: "1 adjust failed: no subject")
        let next = prompt([firstUser, .assistant("", toolCalls: [call]), result])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .appendSuffix(from: held.count))
    }

    func testAMaxTokensStopAppendsWhenTheContentReTokenisesTheSame() {
        let first = prompt([firstUser])
        let cut = "Je réchauffe la photo et je"
        let held = ledger(prompt: first, generated: cut, stop: nil)
        // The re-render closes the message with <|im_end|>\n: the prompt still starts with the ledger.
        let next = prompt([firstUser, .assistant(cut, toolCalls: []), secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .appendSuffix(from: held.count))
        XCTAssertEqual(next[held.count], tokenizer.id(QwenChatTemplate.imEnd))
    }

    func testAMaxTokensStopOnTrailingWhitespaceRestoresTheTurn() {
        let first = prompt([firstUser])
        let cut = "Je réchauffe la photo et "
        let held = ledger(prompt: first, generated: cut, stop: nil)
        // The template trims the content: the trailing space the model generated is not re-rendered.
        let next = prompt([firstUser, .assistant(cut, toolCalls: []), secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .restoreTurn(thenAppendFrom: first.count))
    }

    // MARK: Restoring the turn

    func testAToolCallReRenderedDifferentlyRestoresTheTurn() {
        let first = prompt([firstUser])
        // The model wrote compact JSON; the parsed array re-renders with Python's ", " and ": " separators.
        let generated = "<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\":\"adjust\",\"warmth\":15}]\n</parameter>\n</function>\n</tool_call>"
        let held = ledger(prompt: first, generated: generated)
        let parsed = LocalToolCall(id: "c1", name: "apply_edits",
                                   arguments: .object(["steps": .array([.object(["action": .string("adjust"), "warmth": .number(15)])])]))
        let result = LocalChatMessage.toolResult(callID: "c1", name: "apply_edits", content: "1 adjust applied: Warmth +15")
        let next = prompt([firstUser, .assistant("", toolCalls: [parsed]), result])
        XCTAssertNotEqual(KVTurnPlanner.commonPrefixCount(held, next), held.count, "the re-render diverges")
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .restoreTurn(thenAppendFrom: first.count))
    }

    func testABargeInRestoredToTheCheckpointThenAppendsTheReplay() {
        // A cut generation restores the checkpoint at once; the replay (the user message, then "…") extends it.
        let first = prompt([firstUser])
        let restored = first
        let next = prompt([firstUser, .assistant("…", toolCalls: []), secondUser])
        XCTAssertEqual(decide(restored, next, checkpoint: first.count), .appendSuffix(from: first.count))
    }

    func testAStopOnEndOfTextRestoresTheTurn() {
        // generation_config's <|endoftext|> stops the turn too; the re-render writes <|im_end|> instead.
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Voilà.", stop: "<|endoftext|>")
        let next = prompt([firstUser, .assistant("Voilà.", toolCalls: []), secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .restoreTurn(thenAppendFrom: first.count))
    }

    func testAPromptEqualToTheLedgerHasNothingToFeedAndRestores() {
        let first = prompt([firstUser])
        XCTAssertEqual(decide(first, first, checkpoint: first.count - 3), .restoreTurn(thenAppendFrom: first.count - 3))
        XCTAssertEqual(decide(first, first, checkpoint: nil), .restorePrefix(thenAppendFrom: prefix.count))
    }

    // MARK: Pictures

    func testANewPictureAppendsOnlyWhenMediaAppendIsVerified() {
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Je réchauffe.")
        let look = LocalChatMessage.user("<editor_state v=2>\n</editor_state>\nlangue: fr\nque vois-tu ?", imageJPEG: Data([1, 2, 3]))
        let next = prompt([firstUser, .assistant("Je réchauffe.", toolCalls: []), look])
        XCTAssertEqual(decide(held, next, checkpoint: first.count, media: true, verified: true), .appendSuffix(from: held.count))
        // Without the picture bit: the prefix, then the whole tail with every picture in it.
        XCTAssertEqual(decide(held, next, checkpoint: first.count, media: true, verified: false), .restorePrefix(thenAppendFrom: prefix.count))
        XCTAssertEqual(KVTurnDecision.restorePrefix(thenAppendFrom: prefix.count).path(hasNewMedia: true), "picture")
    }

    func testANewPictureAfterADivergedCallRestoresTheTurnOnlyWhenVerified() {
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Voilà.", stop: "<|endoftext|>")
        let look = LocalChatMessage.user("que vois-tu ?", imageJPEG: Data([9]))
        let next = prompt([firstUser, .assistant("Voilà.", toolCalls: []), look])
        XCTAssertEqual(decide(held, next, checkpoint: first.count, media: true, verified: true), .restoreTurn(thenAppendFrom: first.count))
        XCTAssertEqual(decide(held, next, checkpoint: first.count, media: true, verified: false), .restorePrefix(thenAppendFrom: prefix.count))
    }

    func testAnEarlierPictureRendersTheSameAndKeepsTheCache() {
        let look = LocalChatMessage.user("que vois-tu ?", imageJPEG: Data([7]))
        let first = prompt([look])
        let held = ledger(prompt: first, generated: "Une plage.")
        let next = prompt([look, .assistant("Une plage.", toolCalls: []), secondUser])
        // The old picture's pads are re-prepared identically; nothing new to see: a text append.
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .appendSuffix(from: held.count))
        XCTAssertEqual(KVMediaSlice.plan(tokens: next, padToken: tokenizer.imagePad, rowsPerPicture: [ToyTokenizer.padsPerPicture * 4],
                                         mergeLength: 4, from: held.count)?.carriesPictures, false)
    }

    // MARK: Prefix and rebuild

    func testADriftBeforeTheCheckpointRestoresThePrefix() {
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Voilà.")
        // The brain re-sent an edited first message (a state line it rewrote): only the prefix still matches.
        let edited = LocalChatMessage.user("<editor_state v=1>\nmode: photo, 4032x3024\n</editor_state>\nlangue: fr\nrends-la plus chaude", imageJPEG: nil)
        let next = prompt([edited, .assistant("Voilà.", toolCalls: []), secondUser])
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .restorePrefix(thenAppendFrom: prefix.count))
    }

    func testATemplateOrLayoutChangeRebuilds() {
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Voilà.")
        var other = setup
        other.system = "Tu es l'assistant photo de PicShop. Réponds court."
        let next = tokenizer.encode(QwenChatTemplate.render(other, appending: [firstUser, .assistant("Voilà.", toolCalls: []), secondUser]))
        XCTAssertEqual(decide(held, next, checkpoint: first.count), .rebuild)
        XCTAssertEqual(KVTurnDecision.rebuild.path(hasNewMedia: false), "cold")
        XCTAssertEqual(KVTurnDecision.rebuild.appendFrom, 0)
    }

    func testAnEmptyLedgerOrPromptRebuilds() {
        XCTAssertEqual(KVTurnPlanner.decide(ledger: [], prompt: [1, 2, 3], prefixCount: 0, turnCheckpoint: nil, hasNewMedia: false,
                                            mediaAppendVerified: true), .rebuild)
        XCTAssertEqual(KVTurnPlanner.decide(ledger: [1, 2], prompt: [], prefixCount: 1, turnCheckpoint: nil, hasNewMedia: false,
                                            mediaAppendVerified: true), .rebuild)
    }

    func testWithoutASnapshotNothingButTheLedgerAndCheckpointIsReused() {
        let ledger = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: ledger + [7], prefixCount: 0, turnCheckpoint: 4, hasNewMedia: false,
                                            mediaAppendVerified: false), .appendSuffix(from: 6))
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: [1, 2, 3, 4, 9], prefixCount: 0, turnCheckpoint: 4, hasNewMedia: false,
                                            mediaAppendVerified: false), .restoreTurn(thenAppendFrom: 4))
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: [1, 2, 9], prefixCount: 0, turnCheckpoint: 4, hasNewMedia: false,
                                            mediaAppendVerified: false), .rebuild)
        // A checkpoint beyond the ledger (stale) or inside the prefix is never used.
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: [1, 2, 3, 9], prefixCount: 3, turnCheckpoint: 9, hasNewMedia: false,
                                            mediaAppendVerified: false), .restorePrefix(thenAppendFrom: 3))
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: [1, 2, 3, 9], prefixCount: 3, turnCheckpoint: 2, hasNewMedia: false,
                                            mediaAppendVerified: false), .restorePrefix(thenAppendFrom: 3))
        // A prefix count past the ledger is ignored.
        XCTAssertEqual(KVTurnPlanner.decide(ledger: ledger, prompt: [1, 9], prefixCount: 40, turnCheckpoint: nil, hasNewMedia: false,
                                            mediaAppendVerified: false), .rebuild)
    }

    func testThePathsAndTheAppendPoint() {
        XCTAssertEqual(KVTurnDecision.appendSuffix(from: 9).path(hasNewMedia: false), "warm")
        XCTAssertEqual(KVTurnDecision.restoreTurn(thenAppendFrom: 9).path(hasNewMedia: false), "restored")
        XCTAssertEqual(KVTurnDecision.restorePrefix(thenAppendFrom: 9).path(hasNewMedia: false), "prefix")
        XCTAssertEqual(KVTurnDecision.appendSuffix(from: 9).path(hasNewMedia: true), "picture")
        XCTAssertEqual(KVTurnDecision.restoreTurn(thenAppendFrom: 7).appendFrom, 7)
        XCTAssertEqual(Set(FirstTokenStats.paths), ["warm", "restored", "prefix", "cold", "picture"])
    }

    func testThePrefixSnapshotNeedsTheGenerationPromptAtTheEnd() {
        let generation = tokenizer.encode(QwenChatTemplate.generationPrompt)
        let rendered = tokenizer.encode(QwenChatTemplate.render(setup, appending: []))
        XCTAssertEqual(KVTurnPlanner.prefixTokens(rendered: rendered, generationPrompt: generation)?.count, rendered.count - generation.count)
        XCTAssertNil(KVTurnPlanner.prefixTokens(rendered: tokenizer.encode(QwenChatTemplate.render(setup, appending: [], addGenerationPrompt: false)),
                                                generationPrompt: generation))
        XCTAssertNil(KVTurnPlanner.prefixTokens(rendered: generation, generationPrompt: generation), "an empty prefix")
        XCTAssertNil(KVTurnPlanner.prefixTokens(rendered: rendered, generationPrompt: []))
    }

    // MARK: Picture slicing

    func testTheSuffixCarriesOnlyThePicturesAfterItsStart() {
        let pad = 99
        // Two pictures: 3 pads (12 rows) then 2 pads (8 rows).
        let tokens = [1, 2, pad, pad, pad, 3, 4, 5, pad, pad, 6]
        XCTAssertEqual(KVMediaSlice.pictureRuns(in: tokens, padToken: pad), [2..<5, 8..<10])
        XCTAssertEqual(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 4, from: 6),
                       KVMediaSlice.Plan(firstPicture: 1, droppedRows: 12, pictureCount: 2))
        XCTAssertEqual(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 4, from: 0),
                       KVMediaSlice.Plan(firstPicture: 0, droppedRows: 0, pictureCount: 2))
        let none = KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 4, from: 10)
        XCTAssertEqual(none?.carriesPictures, false)
        XCTAssertEqual(none?.droppedRows, 20)
        // A start inside a picture, or a payload that does not describe the prompt: no slice (prefill from earlier).
        XCTAssertNil(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 4, from: 3))
        XCTAssertNil(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12], mergeLength: 4, from: 6))
        XCTAssertNil(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 12], mergeLength: 4, from: 6))
        XCTAssertNil(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 0, from: 6))
        XCTAssertNil(KVMediaSlice.plan(tokens: tokens, padToken: pad, rowsPerPicture: [12, 8], mergeLength: 4, from: 40))
    }

    func testARenderedLookSlicesAtTheTurnBoundary() {
        let look = LocalChatMessage.user("que vois-tu ?", imageJPEG: Data([5]))
        let first = prompt([firstUser])
        let held = ledger(prompt: first, generated: "Voilà.")
        let next = prompt([firstUser, .assistant("Voilà.", toolCalls: []), look])
        let plan = KVMediaSlice.plan(tokens: next, padToken: tokenizer.imagePad, rowsPerPicture: [ToyTokenizer.padsPerPicture * 4],
                                     mergeLength: 4, from: held.count)
        XCTAssertEqual(plan, KVMediaSlice.Plan(firstPicture: 0, droppedRows: 0, pictureCount: 1))
    }

    // MARK: Stop strings

    func testTheStopStringFilterHoldsOnlyWhatCouldStillStop() {
        var filter = KVStopStringFilter(stopStrings: ["<|im_end|>", "</tool_call>\n\n<", ""])
        XCTAssertEqual(filter.stopStrings.count, 2, "empty strings dropped")
        XCTAssertEqual(filter.process("Bonjour").text, "Bonjour")
        let held = filter.process(" <|im")
        XCTAssertEqual(held.text, " ")
        XCTAssertFalse(held.stopped)
        let stop = filter.process("_end|> après")
        XCTAssertNil(stop.text)
        XCTAssertTrue(stop.stopped)
        XCTAssertTrue(filter.stopped)
        XCTAssertNil(filter.process("encore").text, "nothing passes after a stop")
        XCTAssertNil(filter.finish())

        var other = KVStopStringFilter(stopStrings: ["<|im_end|>"])
        XCTAssertEqual(other.process("a <").text, "a ")
        XCTAssertEqual(other.process("b").text, "<b", "a false start is released")
        XCTAssertEqual(other.process("fin <|im").text, "fin ")
        XCTAssertEqual(other.finish(), "<|im", "the held tail at the end")
        var none = KVStopStringFilter(stopStrings: [])
        XCTAssertEqual(none.process("<|im_end|>").text, "<|im_end|>")
        var split = KVStopStringFilter(stopStrings: ["STOP"])
        let both = split.process("avant STOP après")
        XCTAssertEqual(both.text, "avant ")
        XCTAssertTrue(both.stopped)
    }

    // MARK: Self-test verdict

    func testTheSelfTestComparesCallsOrTheFirstEightIDs() {
        let callJSON = #"{"arguments":{"steps":[{"action":"adjust"}]},"name":"apply_edits"}"#
        XCTAssertTrue(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: [1, 2, 3], calls: [callJSON]),
                                               cold: KVSelfTestTurn(tokenIDs: [1, 2, 4], calls: [callJSON])), "tool turns compare calls")
        XCTAssertFalse(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: [1], calls: [callJSON]), cold: KVSelfTestTurn(tokenIDs: [1], calls: [])))
        let ids = Array(1...24)
        var drifted = ids
        drifted[12] = 0
        XCTAssertTrue(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: ids, calls: []), cold: KVSelfTestTurn(tokenIDs: drifted, calls: [])),
                      "a drift after 8 ids passes")
        drifted[5] = 0
        XCTAssertFalse(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: ids, calls: []), cold: KVSelfTestTurn(tokenIDs: drifted, calls: [])))
        XCTAssertTrue(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: [4, 5], calls: []), cold: KVSelfTestTurn(tokenIDs: [4, 5], calls: [])),
                      "both stopped early at the same place")
        XCTAssertFalse(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: [4, 5], calls: []), cold: KVSelfTestTurn(tokenIDs: [4, 5, 6], calls: [])))
        XCTAssertFalse(KVSelfTestVerdict.agrees(warm: KVSelfTestTurn(tokenIDs: [], calls: []), cold: KVSelfTestTurn(tokenIDs: [], calls: [])))
        XCTAssertEqual(KVSelfTestVerdict.defaultsKey(modelID: "live-qwen35-4b", revision: "32f3", runtimeRevision: "ee673d6", build: "412"),
                       "picshop.kv.verified.live-qwen35-4b.32f3.ee673d6.412")
        XCTAssertEqual(KVSelfTestVerdict.defaultsKey(modelID: "m", revision: "r", runtimeRevision: "x", build: "b", media: true),
                       "picshop.kv.verified.m.r.x.b.media")
    }
}

/// A tokenizer with Qwen's atomic special tokens, words and single characters otherwise, and a picture's
/// `<|image_pad|>` expanded to `padsPerPicture` ids as the processor expands it. Deterministic, stable across runs.
struct ToyTokenizer {
    static let padsPerPicture = 6
    static let specials = ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "<|vision_start|>", "<|image_pad|>", "<|vision_end|>",
                           "<tool_call>", "</tool_call>", "<tool_response>", "</tool_response>", "<think>", "</think>"]

    var imagePad: Int { id("<|image_pad|>") }

    func id(_ piece: String) -> Int {
        if let special = Self.specials.firstIndex(of: piece) { return 1_000_000 + special }
        return Int(StableHash.fnv1a64(piece) % 900_000)
    }

    func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        var word = ""
        func flush() {
            if !word.isEmpty { ids.append(id(word)) }
            word = ""
        }
        while let first = rest.first {
            if first == "<", let special = Self.specials.first(where: { rest.hasPrefix($0) }) {
                flush()
                if special == "<|image_pad|>" {
                    ids += Array(repeating: id(special), count: Self.padsPerPicture)
                } else {
                    ids.append(id(special))
                }
                rest = rest.dropFirst(special.count)
            } else if first.isLetter || first.isNumber {
                word.append(first)
                rest = rest.dropFirst()
            } else {
                flush()
                ids.append(id(String(first)))
                rest = rest.dropFirst()
            }
        }
        flush()
        return ids
    }
}
