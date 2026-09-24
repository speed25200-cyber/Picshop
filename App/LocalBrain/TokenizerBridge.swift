// The tokenizer MLX loads a model with: swift-transformers' AutoTokenizer (the
// model folder's tokenizer.json, tokenizer_config.json and chat_template.jinja),
// adapted to MLXLMCommon's Tokenizer protocol. The same adapter mlx-swift-lm's
// #huggingFaceTokenizerLoader macro writes, without the macro (no swift-syntax build).
//
// Both modules export `Tokenizer` and `TokenizerError`, so every use is qualified.
//
// The chat template is patched once at load: Qwen3.5's template writes the empty
// think block only on assistant turns after the last user query, so the reply the
// model generated after `<think>\n\n</think>\n\n` loses that block when the next
// user turn re-renders the history. The prompt then no longer starts with the
// tokens ChatSession cached, and Qwen3.5's cache (its linear layers are not
// trimmable) is rebuilt at every turn. With the condition always true, every
// assistant turn keeps the block, the history re-renders exactly as it was
// generated, and each turn only prefills what it adds. QwenChatTemplate
// (PicshopIntent) renders the same way for the Linux tests.
#if canImport(MLXVLM)
import Foundation
import MLXLMCommon
import PicshopCore
import Tokenizers

/// Loads the tokenizer from the model's own folder; nothing is fetched.
struct TokenizerBridge: MLXLMCommon.TokenizerLoader {
    /// The template's condition for the empty think block (both pinned repos).
    static let thinkCondition = "{%- if loop.index0 > ns.last_query_index %}"

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return Adapter(upstream, template: Self.patchedTemplate(in: directory))
    }

    /// The folder's chat_template.jinja with the think block on every assistant turn;
    /// nil when there is no such file or no such condition (the template is then used as is).
    static func patchedTemplate(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("chat_template.jinja")
        guard let template = try? String(contentsOf: url, encoding: .utf8), template.contains(thinkCondition) else {
            PSLog.error("local model: chat template not patched; the KV cache will be rebuilt each turn", category: .models)
            return nil
        }
        return template.replacingOccurrences(of: thinkCondition, with: "{%- if true %}")
    }

    /// swift-transformers' tokenizer seen through MLXLMCommon's protocol.
    private struct Adapter: MLXLMCommon.Tokenizer {
        private let upstream: any Tokenizers.Tokenizer
        /// The patched chat template, or nil for the tokenizer's own.
        private let template: String?

        init(_ upstream: any Tokenizers.Tokenizer, template: String?) {
            self.upstream = upstream
            self.template = template
        }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        // swift-transformers names it decode(tokens:).
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? {
            upstream.convertTokenToId(token)
        }

        func convertIdToToken(_ id: Int) -> String? {
            upstream.convertIdToToken(id)
        }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        /// The chat template, with `enable_thinking: false` passed through additionalContext.
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            do {
                if let template {
                    return try upstream.applyChatTemplate(messages: messages, chatTemplate: .literal(template), addGenerationPrompt: true,
                                                          truncation: false, maxLength: nil, tools: tools, additionalContext: additionalContext)
                }
                return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}
#endif
