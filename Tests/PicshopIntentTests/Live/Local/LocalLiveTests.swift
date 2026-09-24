import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// Invariants of the local model's text layer that hold from the phase 0 stubs on.

final class LocalLivePromptInvariantTests: XCTestCase {
    func testToolSpecsCoverEveryToolAsValidJSON() throws {
        for mode in [EditorMode.photo, .video] {
            let specs = LocalLivePrompt.toolSpecs(mode: mode)
            let names = specs.compactMap { $0["function"]?["name"]?.string }
            XCTAssertEqual(names.count, LiveToolName.allCases.count)
            XCTAssertEqual(Set(names), Set(LiveToolName.allCases.map(\.rawValue)))
            for spec in specs {
                XCTAssertEqual(spec["type"], "function")
                XCTAssertNotNil(spec["function"]?["parameters"]?.object)
                XCTAssertEqual(try JSONValue.parse(spec.serialized()), spec)
            }
            XCTAssertEqual(specs, LocalLivePrompt.toolSpecs(mode: mode), "deterministic")
        }
    }

    func testSystemPromptFitsItsBudgetAndNamesNoCloudService() {
        for mode in [EditorMode.photo, .video] {
            for size in [LocalPromptSize.full, .compact] {
                let prompt = LocalLivePrompt.system(mode: mode, size: size)
                XCTAssertEqual(prompt, LocalLivePrompt.system(mode: mode, size: size), "deterministic")
                XCTAssertFalse(prompt.isEmpty)
                XCTAssertLessThanOrEqual(prompt.count, size == .full ? LocalLivePrompt.Budgets.systemFull : LocalLivePrompt.Budgets.systemCompact)
                for word in ["claude", "anthropic", "chatgpt"] {
                    XCTAssertFalse(prompt.lowercased().contains(word), "\(mode) \(size) says \(word)")
                }
            }
        }
    }

    func testMessagesEndWithTheWordsAndTheRecapFits() {
        let turn = LiveUserTurn.speech("plus chaud")
        let message = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false)
        XCTAssertTrue(message.hasSuffix("plus chaud"))
        var start = LiveUserTurn.speech("")
        start.kind = .sessionStart
        XCTAssertFalse(LocalLivePrompt.sessionStartMessage(start, imageAttached: true).isEmpty)
        XCTAssertTrue(LocalLivePrompt.needsFreshLook(start, versionsSinceLastLook: 0), "a session opens with a look")
        XCTAssertFalse(LocalLivePrompt.needsFreshLook(turn, versionsSinceLastLook: 0))
        let long = LocalRecapInput(appliedEdits: (1...200).map { "Edit \($0)" }, lastExchanges: ["plus chaud -> Je réchauffe."], openQuestion: nil, lastLook: nil)
        XCTAssertLessThanOrEqual(LocalLivePrompt.recap(long).count, LocalLivePrompt.Budgets.recap)
    }
}

final class ToolArgumentCoercerTests: XCTestCase {
    func testStrictArgumentsReachTheValidatorUnchanged() throws {
        let arguments: JSONValue = ["steps": [["action": "adjust", "parameter": "temperature", "amountMode": "relative", "amount": 15]]]
        let use = ToolArgumentCoercer.rawToolUse(id: "call_1", name: "apply_edits", arguments: arguments)
        XCTAssertEqual(use.id, "call_1")
        XCTAssertEqual(use.name, "apply_edits")
        XCTAssertEqual(use.blockIndex, 0)
        XCTAssertEqual(try JSONValue.parse(use.rawInput), arguments)
        let call = try ToolInputValidator(mode: .photo).validate(use, context: .photo).get()
        XCTAssertEqual(call.id, "call_1")
        guard case .applyEdits(let intents) = call.tool else { return XCTFail("\(call.tool)") }
        XCTAssertEqual(intents.first?.action, .adjust)
    }
}

final class LocalOutputFilterInvariantTests: XCTestCase {
    func testPlainSpeechIsNeverLost() {
        var filter = LocalOutputFilter()
        var spoken = ""
        func take(_ pieces: [LocalOutputFilter.Piece]) {
            for piece in pieces {
                if case .speech(let text) = piece { spoken += text }
            }
        }
        for delta in ["Je ", "réchauffe", " un peu", ", ", "c'est plus doux."] { take(filter.feed(delta)) }
        take(filter.finish())
        XCTAssertEqual(spoken, "Je réchauffe un peu, c'est plus doux.")
    }
}
