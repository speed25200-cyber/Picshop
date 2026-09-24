import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The pure-Swift rendering of Qwen3.5's chat template, checked against the
/// template's rules (chat_template.jinja at the pinned revisions).
final class QwenChatTemplateTests: XCTestCase {
    private let tool: JSONValue = ["type": "function", "function": ["name": "undo", "description": "Undo.", "parameters": ["type": "object", "properties": [:]]]]

    func testAConversationRendersAsTheTemplateDoes() {
        let messages: [LocalChatMessage] = [
            .user("rends-la plus chaude", imageJPEG: nil),
            .assistant("Je la réchauffe.", toolCalls: [LocalToolCall(id: "1", name: "apply_edits", arguments: ["steps": [["action": "adjust", "amount": 15, "parameter": "temperature"]]])]),
            .toolResult(callID: "1", name: "apply_edits", content: "1 adjust applied: Warmth +15"),
            .user("c'est trop", imageJPEG: nil),
        ]
        let expected = """
        <|im_start|>system
        # Tools

        You have access to the following functions:

        <tools>
        {"function": {"description": "Undo.", "name": "undo", "parameters": {"properties": {}, "type": "object"}}, "type": "function"}
        </tools>\(QwenChatTemplate.toolsInstructions)

        Tu es Picshop Live.<|im_end|>
        <|im_start|>user
        rends-la plus chaude<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        Je la réchauffe.

        <tool_call>
        <function=apply_edits>
        <parameter=steps>
        [{"action": "adjust", "amount": 15, "parameter": "temperature"}]
        </parameter>
        </function>
        </tool_call><|im_end|>
        <|im_start|>user
        <tool_response>
        1 adjust applied: Warmth +15
        </tool_response><|im_end|>
        <|im_start|>user
        c'est trop<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
        XCTAssertEqual(QwenChatTemplate.render(system: "  Tu es Picshop Live.\n", tools: [tool], messages: messages), expected)
    }

    /// TokenizerBridge patches the template so every assistant turn carries the empty think
    /// block, before the last query too: the history re-renders as it was generated.
    func testEveryAssistantTurnCarriesTheEmptyThinkBlock() {
        let messages: [LocalChatMessage] = [
            .user("a", imageJPEG: nil), .assistant("b", toolCalls: []),
            .user("c", imageJPEG: nil), .assistant("", toolCalls: [LocalToolCall(id: "1", name: "undo", arguments: [:])]),
            .toolResult(callID: "1", name: "undo", content: "Undone: Warmth +15"),
            .assistant("Voilà.", toolCalls: []),
        ]
        let text = QwenChatTemplate.render(system: "S", tools: [], messages: messages, addGenerationPrompt: false)
        XCTAssertEqual(text, """
        <|im_start|>system
        S<|im_end|>
        <|im_start|>user
        a<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        b<|im_end|>
        <|im_start|>user
        c<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        <tool_call>
        <function=undo>
        </function>
        </tool_call><|im_end|>
        <|im_start|>user
        <tool_response>
        Undone: Warmth +15
        </tool_response><|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        Voilà.<|im_end|>

        """)
    }

    func testPicturesToolResultsAndCalls() {
        let text = QwenChatTemplate.render(system: "", tools: [], messages: [
            .user("que vois-tu ?  ", imageJPEG: Data([1, 2, 3])),
            .assistant("Deux choses.", toolCalls: [LocalToolCall(id: "1", name: "undo", arguments: ["count": 2, "to_original": false]),
                                                   LocalToolCall(id: "2", name: "compare_before_after", arguments: ["seconds": 2.5])]),
            .toolResult(callID: "1", name: "undo", content: "Undone: A, B"),
            .toolResult(callID: "2", name: "compare_before_after", content: "Done."),
        ], addGenerationPrompt: true)
        XCTAssertTrue(text.hasPrefix("<|im_start|>user\n<|vision_start|><|image_pad|><|vision_end|>que vois-tu ?<|im_end|>\n"), "the picture before the text, no system block")
        XCTAssertTrue(text.contains("Deux choses.\n\n<tool_call>\n<function=undo>\n<parameter=count>\n2\n</parameter>\n<parameter=to_original>\nfalse\n</parameter>\n</function>\n</tool_call>\n<tool_call>\n<function=compare_before_after>\n<parameter=seconds>\n2.5\n</parameter>\n</function>\n</tool_call><|im_end|>\n"))
        XCTAssertTrue(text.contains("<|im_start|>user\n<tool_response>\nUndone: A, B\n</tool_response>\n<tool_response>\nDone.\n</tool_response><|im_end|>\n"), "consecutive results share one user block")
        XCTAssertTrue(text.hasSuffix(QwenChatTemplate.generationPrompt))
    }

    /// The KV cache is reused only when the next prompt starts with the cached tokens:
    /// the previous prompt, its generation prompt and the reply. Checked for a text reply,
    /// a reply with a tool call and its result, and a reply before a picture turn.
    func testTheNextPromptExtendsTheCachedOne() {
        let setup = LocalChatSetup(system: "S", tools: [tool], history: [.user("exemple", imageJPEG: nil), .assistant("Réponse.", toolCalls: [])],
                                   imageMaxPixels: 196_608)
        let call = LocalToolCall(id: "1", name: "undo", arguments: ["count": 1])
        let turns: [(sent: [LocalChatMessage], reply: String, calls: [LocalToolCall])] = [
            ([.user("rends-la plus chaude", imageJPEG: Data([1]))], "Je la réchauffe.", [call]),
            ([.toolResult(callID: "1", name: "undo", content: "Undone")], "Voilà.", []),
            ([.user("et plus lumineuse ?", imageJPEG: nil)], "D'accord.", []),
            ([.user("tu en penses quoi ?", imageJPEG: Data([2]))], "Elle est belle.", []),
        ]
        var history: [LocalChatMessage] = []
        var cached: String?
        for turn in turns {
            let prompt = QwenChatTemplate.render(setup, appending: history + turn.sent)
            if let cached { XCTAssertTrue(prompt.hasPrefix(cached), "turn after \(history.count) messages rebuilds the cache") }
            var reply = turn.reply
            for (index, call) in turn.calls.enumerated() {
                reply += (index == 0 ? "\n\n" : "\n") + QwenChatTemplate.functionCall(call)
            }
            cached = prompt + reply + QwenChatTemplate.imEnd
            history += turn.sent + [.assistant(turn.reply, toolCalls: turn.calls)]
        }
    }

    func testPythonJSON() {
        XCTAssertEqual(QwenChatTemplate.pythonJSON(["b": [1, 2.5, "é\"\n"], "a": nil, "c": true]), "{\"a\": null, \"b\": [1, 2.5, \"é\\\"\\n\"], \"c\": true}")
    }

    /// What the template writes for a call, the output filter reads back.
    func testRenderedCallsParseBack() {
        for mode in [EditorMode.photo, .video] {
            for example in LocalLivePrompt.examples(mode: mode, size: .full) {
                guard let tool = example.toolName else { continue }
                let call = LocalToolCall(id: "x", name: tool.rawValue, arguments: example.arguments ?? [:])
                let output = FilteredOutput.run([example.assistant + "\n\n" + QwenChatTemplate.functionCall(call)])
                XCTAssertEqual(output.normalizedSpeech, example.assistant)
                XCTAssertEqual(output.calls, [.toolCall(name: tool.rawValue, arguments: example.arguments ?? [:])], example.user)
            }
        }
    }

    func testLedger() {
        let setup = LocalChatSetup(system: LocalLivePrompt.system(mode: .photo, size: .full), tools: LocalLivePrompt.toolSpecs(mode: .photo),
                                   history: [.user("a", imageJPEG: nil), .assistant("b", toolCalls: [])], imageMaxPixels: 196_608)
        var ledger = LocalContextLedger(setup: setup)
        XCTAssertEqual(ledger.prefixCharacters, QwenChatTemplate.render(setup, addGenerationPrompt: false).count)
        XCTAssertEqual(ledger.images, 0)
        let start = ledger.estimatedTokens
        ledger.append([.user(String(repeating: "mot ", count: 100), imageJPEG: Data([0]))])
        XCTAssertEqual(ledger.images, 1)
        XCTAssertEqual(ledger.turns, 1)
        XCTAssertGreaterThan(ledger.estimatedTokens, start + LocalContextLedger.tokensPerImage + 100)
        let before = ledger.estimatedTokens
        ledger.appendReply("Je réchauffe.", calls: [LocalToolCall(id: "1", name: "undo", arguments: [:])])
        XCTAssertGreaterThan(ledger.estimatedTokens, before)
        XCTAssertFalse(ledger.needsCompaction(compactAt: 6_000, maxImages: 2))
        XCTAssertFalse(ledger.needsCompaction(compactAt: 6_000, maxImages: 2, addingImage: true))
        ledger.append([.user("encore", imageJPEG: Data([0]))])
        XCTAssertTrue(ledger.needsCompaction(compactAt: 6_000, maxImages: 2, addingImage: true), "a third picture")
        XCTAssertTrue(ledger.needsCompaction(compactAt: 100, maxImages: 2))
        XCTAssertEqual(LocalContextLedger.tokens(characters: 32), 10)
    }
}
