import Foundation
import PicshopCore

/// Qwen3.5's chat template (`chat_template.jinja` of the pinned 4B and 2B MLX
/// repos), rendered in pure Swift with `enable_thinking` false: what the model
/// actually reads for a `LocalChatSetup` and the messages that follow it.
///
/// On the phone the tokenizer's own Jinja template does the rendering (inside
/// MLX's `ChatSession`); this copy exists so Linux tests can see the prompt the
/// way the model does: the few-shot examples as real turns, tool calls in the
/// XML-function dialect, tool results as `<tool_response>` blocks, the empty
/// think block on every assistant turn, and how many characters the cached
/// prefix costs (`LocalContextLedger`).
///
/// Faithful to the template as the app runs it. The upstream template writes the
/// empty think block only on assistant turns after the last real user query, so a
/// reply generated after `<think>\n\n</think>\n\n` is re-rendered without it at the
/// next user turn: the new prompt no longer starts with the cached tokens, and
/// Qwen3.5's cache (not trimmable) is rebuilt every turn. TokenizerBridge (App)
/// therefore patches that condition to always true, and this copy does the same.
/// Two formatting details the Jinja engine decides differ: object keys are sorted,
/// and scalar parameter values are written as JSON scalars (`true`, `15`, `0.5`).
public enum QwenChatTemplate {
    public static let imStart = "<|im_start|>"
    public static let imEnd = "<|im_end|>"
    /// One picture, as the template writes it before the text of its message.
    public static let imagePlaceholder = "<|vision_start|><|image_pad|><|vision_end|>"
    /// The empty think block, before every assistant turn's words (thinking is off).
    public static let emptyThink = "<think>\n\n</think>\n\n"
    /// The assistant prefix with thinking off.
    public static let generationPrompt = "<|im_start|>assistant\n" + emptyThink

    static let toolsHeader = "# Tools\n\nYou have access to the following functions:\n\n<tools>"
    static let toolsInstructions = """


    If you choose to call a function ONLY reply in the following format with NO suffix:

    <tool_call>
    <function=example_function_name>
    <parameter=example_parameter_1>
    value_1
    </parameter>
    <parameter=example_parameter_2>
    This is the value for the second parameter
    that can span
    multiple lines
    </parameter>
    </function>
    </tool_call>

    <IMPORTANT>
    Reminder:
    - Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags
    - Required parameters MUST be specified
    - You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after
    - If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls
    </IMPORTANT>
    """

    /// The engine's conversation: system and tools, the setup's history, then `messages`.
    public static func render(_ setup: LocalChatSetup, appending messages: [LocalChatMessage] = [], addGenerationPrompt: Bool = true) -> String {
        render(system: setup.system, tools: setup.tools, messages: setup.history + messages, addGenerationPrompt: addGenerationPrompt)
    }

    public static func render(system: String, tools: [JSONValue], messages: [LocalChatMessage], addGenerationPrompt: Bool = true) -> String {
        var out = systemBlock(system: system, tools: tools)
        for (index, message) in messages.enumerated() {
            switch message {
            case .user(let text, let image):
                let content = ((image == nil ? "" : imagePlaceholder) + text).trimmingCharacters(in: .whitespacesAndNewlines)
                out += imStart + "user\n" + content + imEnd + "\n"
            case .assistant(let text, let calls):
                let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Always, as the patched template does: history re-renders exactly as it was generated.
                out += imStart + "assistant\n" + emptyThink
                out += content
                for (position, call) in calls.enumerated() {
                    if position == 0 {
                        out += content.isEmpty ? "" : "\n\n"
                    } else {
                        out += "\n"
                    }
                    out += functionCall(call)
                }
                out += imEnd + "\n"
            case .toolResult(_, _, let content):
                let previousIsTool = index > 0 && isToolResult(messages[index - 1])
                if index > 0, !previousIsTool { out += imStart + "user" }
                out += "\n<tool_response>\n" + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</tool_response>"
                let nextIsTool = index + 1 < messages.count && isToolResult(messages[index + 1])
                if !nextIsTool { out += imEnd + "\n" }
            }
        }
        if addGenerationPrompt { out += generationPrompt }
        return out
    }

    /// `<|im_start|>system` with the tools block, the format reminder, then the instructions.
    public static func systemBlock(system: String, tools: [JSONValue]) -> String {
        let instructions = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty else {
            return instructions.isEmpty ? "" : imStart + "system\n" + instructions + imEnd + "\n"
        }
        var out = imStart + "system\n" + toolsHeader
        for tool in tools { out += "\n" + pythonJSON(tool) }
        out += "\n</tools>" + toolsInstructions
        if !instructions.isEmpty { out += "\n\n" + instructions }
        return out + imEnd + "\n"
    }

    /// One call as an assistant turn writes it.
    public static func functionCall(_ call: LocalToolCall) -> String {
        var out = "<tool_call>\n<function=\(call.name)>\n"
        let arguments = call.arguments.object ?? [:]
        for key in arguments.keys.sorted() {
            guard let value = arguments[key] else { continue }
            out += "<parameter=\(key)>\n" + parameterText(value) + "\n</parameter>\n"
        }
        return out + "</function>\n</tool_call>"
    }

    /// Objects and arrays as JSON, strings verbatim, other scalars as JSON scalars.
    static func parameterText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .object, .array: return pythonJSON(value)
        default: return value.serialized()
        }
    }

    private static func isToolResult(_ message: LocalChatMessage) -> Bool {
        if case .toolResult = message { return true }
        return false
    }

    /// Python's `json.dumps(ensure_ascii=False)`: `", "` and `": "` separators, keys sorted.
    public static func pythonJSON(_ value: JSONValue) -> String {
        switch value {
        case .array(let items):
            return "[" + items.map(pythonJSON).joined(separator: ", ") + "]"
        case .object(let object):
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "{" + keys.map { JSONValue.string($0).serialized() + ": " + pythonJSON(object[$0] ?? .null) }.joined(separator: ", ") + "}"
        default:
            return value.serialized()
        }
    }
}
