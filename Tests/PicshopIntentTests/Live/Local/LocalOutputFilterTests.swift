import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// What one generation became once filtered.
struct FilteredOutput: Equatable {
    var speech = ""
    var calls: [LocalOutputFilter.Piece] = []
    var malformed: [String] = []
    var speechPieces: [String] = []

    /// Whitespace collapsed: splits may move a space, never a word.
    var normalizedSpeech: String {
        speech.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func run(_ deltas: [String]) -> FilteredOutput {
        var filter = LocalOutputFilter()
        var output = FilteredOutput()
        for delta in deltas { output.take(filter.feed(delta)) }
        output.take(filter.finish())
        return output
    }

    mutating func take(_ pieces: [LocalOutputFilter.Piece]) {
        for piece in pieces {
            switch piece {
            case .speech(let text):
                speech += text
                speechPieces.append(text)
            case .toolCall:
                calls.append(piece)
            case .malformed(let raw):
                malformed.append(raw)
            }
        }
    }
}

/// Deterministic pseudo-random numbers (SplitMix64), so a failing split can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Qwen3.5 outputs as the model writes them (XML-function and JSON dialects, think
/// blocks, leaks, stop tokens, markdown), with what must be spoken and executed.
enum RecordedQwenOutputs {
    struct Sample {
        var text: String
        var speech: String
        var calls: [LocalOutputFilter.Piece]
        var malformed = 0
    }

    static func steps(_ steps: JSONValue) -> JSONValue { ["steps": steps] }

    static let all: [Sample] = [
        Sample(text: "Je réchauffe un peu.\n\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"adjust\", \"parameter\": \"temperature\", \"amount\": 15}]\n</parameter>\n</function>\n</tool_call>",
               speech: "Je réchauffe un peu.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "adjust", "parameter": "temperature", "amount": 15]]))]),
        Sample(text: "<think>\n\n</think>\n\nJe reviens en arrière.\n<tool_call>\n<function=undo>\n</function>\n</tool_call>",
               speech: "Je reviens en arrière.", calls: [.toolCall(name: "undo", arguments: [:])]),
        Sample(text: "Elle a une belle lumière douce, le sujet est bien placé.\n\n<tool_call>\n<function=propose_ideas>\n<parameter=ideas>\n[{\"title\": \"Ciel plus dense\", \"why\": \"Le ciel est un peu pâle.\", \"symbol\": \"cloud.sun\", \"steps\": [{\"action\": \"selectiveAdjust\", \"target\": \"sky\", \"parameter\": \"saturation\", \"amount\": 20}]}, {\"title\": \"Portrait doux\", \"why\": \"La peau gagnerait en douceur.\", \"steps\": [{\"action\": \"applyLook\", \"look\": \"portrait\", \"amount\": 60}]}]\n</parameter>\n</function>\n</tool_call>",
               speech: "Elle a une belle lumière douce, le sujet est bien placé.",
               calls: [.toolCall(name: "propose_ideas", arguments: ["ideas": [
                   ["title": "Ciel plus dense", "why": "Le ciel est un peu pâle.", "symbol": "cloud.sun",
                    "steps": [["action": "selectiveAdjust", "target": "sky", "parameter": "saturation", "amount": 20]]],
                   ["title": "Portrait doux", "why": "La peau gagnerait en douceur.", "steps": [["action": "applyLook", "look": "portrait", "amount": 60]]],
               ]])]),
        Sample(text: "Adding some punch.\n<tool_call>\n{\"name\": \"apply_edits\", \"arguments\": {\"steps\": [{\"action\": \"applyLook\", \"look\": \"vivid\", \"amount\": 60}]}}\n</tool_call>",
               speech: "Adding some punch.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "applyLook", "look": "vivid", "amount": 60]]))]),
        Sample(text: "Je te montre l'avant.<tool_call><function=compare_before_after><parameter=seconds>2</parameter></function></tool_call>",
               speech: "Je te montre l'avant.", calls: [.toolCall(name: "compare_before_after", arguments: ["seconds": "2"])]),
        Sample(text: "Je l'enlève.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"removeObject\", \"target\": \"trash\", \"point\": {\"x\": 640, \"y\": 410}}]\n</parameter>\n</function>\n</tool_call>",
               speech: "Je l'enlève.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "removeObject", "target": "trash", "point": ["x": 640, "y": 410]]]))]),
        Sample(text: "Paris est la capitale de la France, mais parlons de ta photo !",
               speech: "Paris est la capitale de la France, mais parlons de ta photo !", calls: []),
        Sample(text: "D'accord, je fais les deux.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"adjust\", \"parameter\": \"contrast\", \"amount\": 20}]\n</parameter>\n</function>\n</tool_call>\n<tool_call>\n<function=compare_before_after>\n<parameter=seconds>\n3\n</parameter>\n</function>\n</tool_call>",
               speech: "D'accord, je fais les deux.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "adjust", "parameter": "contrast", "amount": 20]])),
                       .toolCall(name: "compare_before_after", arguments: ["seconds": "3"])]),
        Sample(text: "**Bonne idée** ! 😊 Je passe en noir et blanc.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"applyLook\", \"look\": \"mono\", \"amount\": 100}]\n</parameter>\n</function>\n</tool_call>",
               speech: "Bonne idée ! Je passe en noir et blanc.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "applyLook", "look": "mono", "amount": 100]]))]),
        Sample(text: "Je réchauffe.<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"adjust\", \"parameter\": \"temperature\", \"amount\": 10}]\n</parameter>\n</function>\n</tool_call><|im_end|>\n<|im_start|>user\nmerci",
               speech: "Je réchauffe.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "adjust", "parameter": "temperature", "amount": 10]]))]),
        Sample(text: "Voilà, c'est plus lumineux.<|im_end|>", speech: "Voilà, c'est plus lumineux.", calls: []),
        Sample(text: "<think>\nL'utilisateur veut plus de contraste.\n</think>\n\nJ'ajoute du contraste.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"adjust\", \"parameter\": \"contrast\", \"amount\": 20}]\n</parameter>\n</function>\n</tool_call>",
               speech: "J'ajoute du contraste.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "adjust", "parameter": "contrast", "amount": 20]]))]),
        Sample(text: "Je recadre en carré.\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"setAspect\", \"aspect\": \"square\"}]\n</parameter>\n</function>",
               speech: "Je recadre en carré.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "setAspect", "aspect": "square"]]))]),
        Sample(text: "J'annule les deux dernières.\n<tool_call>\n<function=undo>\n<parameter=count>\n2\n</parameter>\n</function>\n</tool_call>",
               speech: "J'annule les deux dernières.", calls: [.toolCall(name: "undo", arguments: ["count": "2"])]),
        Sample(text: "Je te propose une piste.\n<tool_call>\n{\"name\": \"propose_ideas\", \"arguments\": \"{\\\"ideas\\\": [{\\\"title\\\": \\\"Plus chaud\\\", \\\"why\\\": \\\"Ambiance dorée.\\\", \\\"steps\\\": [{\\\"action\\\": \\\"adjust\\\", \\\"parameter\\\": \\\"temperature\\\", \\\"amount\\\": 20}]}]}\"}\n</tool_call>",
               speech: "Je te propose une piste.",
               calls: [.toolCall(name: "propose_ideas", arguments: ["ideas": [["title": "Plus chaud", "why": "Ambiance dorée.",
                                                                              "steps": [["action": "adjust", "parameter": "temperature", "amount": 20]]]]])]),
        Sample(text: "Sure, going back to the original.\n<tool_call>\n<function=undo>\n<parameter=to_original>\ntrue\n</parameter>\n</function>\n</tool_call>",
               speech: "Sure, going back to the original.", calls: [.toolCall(name: "undo", arguments: ["to_original": "true"])]),
        Sample(text: "Je floute l'arrière-plan.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"blurBackground\", \"amount\": 40}]\n</parameter>\n</function>",
               speech: "Je floute l'arrière-plan.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "blurBackground", "amount": 40]]))]),
        Sample(text: "Oups <tool_call>apply_edits(steps=[...])</tool_call> je réessaie.", speech: "Oups je réessaie.", calls: [], malformed: 1),
        Sample(text: "Pour 5 < 10 secondes, je ralentis {un peu}.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"setSpeed\", \"speed\": 0.5}]\n</parameter>\n</function>\n</tool_call>",
               speech: "Pour 5 10 secondes, je ralentis un peu.",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "setSpeed", "speed": 0.5]]))]),
        Sample(text: "Je mets le titre.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"addText\", \"text\": \"Été 2026 <3\", \"placement\": \"bottom\"}]\n</parameter>\n</function>\n</tool_call>\nC'est fait !",
               speech: "Je mets le titre. C'est fait !",
               calls: [.toolCall(name: "apply_edits", arguments: steps([["action": "addText", "text": "Été 2026 <3", "placement": "bottom"]]))]),
    ]
}

final class LocalOutputFilterTests: XCTestCase {
    func testRecordedOutputsInOneDelta() {
        XCTAssertEqual(RecordedQwenOutputs.all.count, 20)
        for (index, sample) in RecordedQwenOutputs.all.enumerated() {
            let output = FilteredOutput.run([sample.text])
            XCTAssertEqual(output.normalizedSpeech, sample.speech, "sample \(index)")
            XCTAssertEqual(output.calls, sample.calls, "sample \(index)")
            XCTAssertEqual(output.malformed.count, sample.malformed, "sample \(index): \(output.malformed)")
        }
    }

    /// 20 recorded outputs × 1,000 random delta splits: no markup is ever spoken, every call is recovered.
    func testFuzzRandomSplitsNeverSpeakMarkupAndRecoverEveryCall() {
        var random = SplitMix64(seed: 0x5EED_1234)
        let forbidden: [Character] = ["<", ">", "{", "}", "[", "]", "*", "`", "|"]
        for (index, sample) in RecordedQwenOutputs.all.enumerated() {
            let characters = Array(sample.text)
            for round in 0..<1_000 {
                var cuts = Set<Int>()
                let count = Int.random(in: 1...min(40, max(1, characters.count - 1)), using: &random)
                for _ in 0..<count { cuts.insert(Int.random(in: 1..<characters.count, using: &random)) }
                var deltas: [String] = []
                var start = 0
                for cut in cuts.sorted() {
                    deltas.append(String(characters[start..<cut]))
                    start = cut
                }
                deltas.append(String(characters[start...]))
                let output = FilteredOutput.run(deltas)
                // Checked by hand, asserted only on a failure: 20,000 runs stay fast.
                let badPiece = output.speechPieces.first { piece in
                    piece.allSatisfy(\.isWhitespace) || piece.contains(where: { forbidden.contains($0) })
                }
                if badPiece != nil || output.calls != sample.calls || output.normalizedSpeech != sample.speech || output.malformed.count != sample.malformed {
                    XCTFail("sample \(index), round \(round), deltas \(deltas): spoke \(output.speechPieces), calls \(output.calls), malformed \(output.malformed)")
                    return
                }
            }
        }
    }

    func testCharacterByCharacter() {
        for sample in RecordedQwenOutputs.all {
            let output = FilteredOutput.run(sample.text.map { String($0) })
            XCTAssertEqual(output.calls, sample.calls)
            XCTAssertEqual(output.normalizedSpeech, sample.speech)
        }
    }

    func testThinkBlocksAreDroppedEvenAcrossDeltas() {
        let output = FilteredOutput.run(["<th", "ink>\nJe pense à ", "<tool_call>rien</tool_call>", "</thi", "nk>\n\nBonjour !"])
        XCTAssertEqual(output.speech, "Bonjour !")
        XCTAssertTrue(output.calls.isEmpty, "a call inside a think block never runs")
        let stray = FilteredOutput.run(["</think>\n\nVoilà."])
        XCTAssertEqual(stray.speech, "Voilà.")
        let unfinished = FilteredOutput.run(["<think>\nJe réfléchis encore"])
        XCTAssertEqual(unfinished.speech, "")
    }

    func testTheCallRunsAsSoonAsItsFunctionCloses() {
        var filter = LocalOutputFilter()
        XCTAssertEqual(filter.feed("Je réchauffe.\n<tool_call>\n<function=undo>\n"), [.speech("Je réchauffe. ")])
        XCTAssertEqual(filter.feed("</function>"), [.toolCall(name: "undo", arguments: [:])], "no need to wait for </tool_call>")
        XCTAssertEqual(filter.feed("\n</tool_call>"), [])
        XCTAssertEqual(filter.finish(), [])
    }

    func testStopTokensEndWhatIsSpoken() {
        XCTAssertEqual(FilteredOutput.run(["Voilà.<|endoftext|>Et puis"]).speech, "Voilà.")
        XCTAssertEqual(FilteredOutput.run(["Voilà.", "<|im_st", "art|>user\nencore"]).speech, "Voilà.")
        XCTAssertEqual(FilteredOutput.run(["C'est fait.\n<tool_response>\n{\"ok\":true}"]).normalizedSpeech, "C'est fait.")
        var filter = LocalOutputFilter()
        _ = filter.feed("Fini.<|im_end|>")
        XCTAssertEqual(filter.feed("encore du texte"), [], "nothing after the end of the turn")
    }

    func testTruncatedCalls() {
        // Missing </tool_call> and </function>: still one complete call.
        let noClose = FilteredOutput.run(["<tool_call>\n<function=undo>\n<parameter=count>\n2\n</parameter>\n"])
        XCTAssertEqual(noClose.calls, [.toolCall(name: "undo", arguments: ["count": "2"])])
        // A value cut by max tokens is never guessed at.
        let cut = FilteredOutput.run(["Je mets le titre.\n<tool_call>\n<function=apply_edits>\n<parameter=steps>\n[{\"action\": \"addText\", \"text\": \"Joyeux anniv"])
        XCTAssertEqual(cut.normalizedSpeech, "Je mets le titre.")
        XCTAssertTrue(cut.calls.isEmpty)
        XCTAssertEqual(cut.malformed.count, 1)
        XCTAssertTrue(cut.malformed[0].hasPrefix("<function=apply_edits>"))
        // A value whose </parameter> the model forgot ends at the next tag.
        let forgot = FilteredOutput.run(["<tool_call>\n<function=undo>\n<parameter=count>\n2\n<parameter=direction>\nredo\n</function>\n</tool_call>"])
        XCTAssertEqual(forgot.calls, [.toolCall(name: "undo", arguments: ["count": "2", "direction": "redo"])])
        // A tag cut at the very end is dropped, never spoken.
        let partial = FilteredOutput.run(["Voilà ", "<tool_c"])
        XCTAssertEqual(partial.normalizedSpeech, "Voilà")
        XCTAssertTrue(partial.calls.isEmpty)
    }

    func testJSONDialectAndBareCalls() {
        let wrapped = FilteredOutput.run(["<tool_call>{\"function\": {\"name\": \"undo\", \"arguments\": null}}</tool_call>"])
        XCTAssertEqual(wrapped.calls, [.toolCall(name: "undo", arguments: [:])])
        let parameters = FilteredOutput.run(["<tool_call>{\"name\": \"compare_before_after\", \"parameters\": {\"seconds\": 2}}</tool_call>"])
        XCTAssertEqual(parameters.calls, [.toolCall(name: "compare_before_after", arguments: ["seconds": 2])])
        let bare = FilteredOutput.run(["Je reviens. ", "{\"name\": \"undo\", \"arguments\": {}}", " Voilà."])
        XCTAssertEqual(bare.calls, [.toolCall(name: "undo", arguments: [:])])
        XCTAssertEqual(bare.normalizedSpeech, "Je reviens. Voilà.")
        let repaired = FilteredOutput.run(["<tool_call>{\"name\": \"undo\", \"arguments\": {\"count\": 2,}}</tool_call>"])
        XCTAssertEqual(repaired.calls, [.toolCall(name: "undo", arguments: ["count": 2])], "a trailing comma is repaired")
        let nameless = FilteredOutput.run(["Tiens ", "{\"foo\": 1}", " voilà."])
        XCTAssertTrue(nameless.calls.isEmpty)
        XCTAssertEqual(nameless.malformed, ["{\"foo\": 1}"])
        XCTAssertEqual(nameless.normalizedSpeech, "Tiens voilà.", "speech goes on after a bare object")
    }

    func testMalformedCallsAreReportedAndSkipped() {
        let noFunction = FilteredOutput.run(["Je fais ça.\n<tool_call>\n<parameter=steps>\n[]\n</parameter>\n</tool_call>\nVoilà."])
        XCTAssertEqual(noFunction.malformed.count, 1)
        XCTAssertEqual(noFunction.normalizedSpeech, "Je fais ça. Voilà.")
        let orphan = FilteredOutput.run(["<parameter=count>\n2\n</parameter>"])
        XCTAssertEqual(orphan.malformed.count, 1)
        XCTAssertEqual(orphan.speech, "")
        let spaced = FilteredOutput.run(["<tool_call>\n<function=apply edits>\n</function>\n</tool_call>"])
        XCTAssertEqual(spaced.malformed.count, 1, "a name with a space")
    }

    func testSpeechIsCleaned() {
        XCTAssertEqual(FilteredOutput.run(["- Plus chaud\n- Plus doux\n## Titre"]).normalizedSpeech, "Plus chaud Plus doux Titre")
        XCTAssertEqual(FilteredOutput.run(["C'est <b>très</b> joli 🌅✨."]).normalizedSpeech, "C'est très joli .")
        XCTAssertEqual(FilteredOutput.run(["Le `contraste` à 20 %, #1 ; l'apply_edits"]).normalizedSpeech, "Le contraste à 20 %, #1 ; l'apply edits")
        XCTAssertEqual(FilteredOutput.run(["\n\n   Bonjour"]).speech, "Bonjour", "no leading blank")
        XCTAssertEqual(FilteredOutput.run(["Été, œuvre, naïve — 3,5 € ; c'est ça ?"]).speech, "Été, œuvre, naïve — 3,5 € ; c'est ça ?", "French stays intact")
        let pieces = FilteredOutput.run(["Oui.", "\n", "<tool_call><function=undo></function></tool_call>", "\n"]).speechPieces
        XCTAssertEqual(pieces, ["Oui."], "no blank piece after a call")
    }

    /// Deltas keep their spaces as streamed, so a consumer can stop right after a word.
    func testDeltasKeepTheirSpaces() {
        var filter = LocalOutputFilter()
        XCTAssertEqual(filter.feed("Je "), [.speech("Je ")])
        XCTAssertEqual(filter.feed("regarde "), [.speech("regarde ")])
        XCTAssertEqual(filter.feed(" ta"), [.speech("ta")], "no double space")
        XCTAssertEqual(filter.feed("\n"), [], "a blank delta waits for words")
        XCTAssertEqual(filter.feed("photo."), [.speech(" photo.")])
    }

    func testTheFilterIsReusableAfterFinish() {
        var filter = LocalOutputFilter()
        _ = filter.feed("Fin.<|im_end|>")
        _ = filter.finish()
        XCTAssertEqual(filter.feed("Encore."), [.speech("Encore.")])
    }
}
