// One Live conversation with the loaded Qwen3.5 weights: an MLX `ChatSession`
// (mlx-swift-lm main, pinned), behind PicshopIntent's `LocalChatEngine`.
//
// What ChatSession gives the brain (contract D6): one KV cache per conversation,
// append-only prefix reuse, Qwen3.5's position state carried between turns, a
// transcript ledger (reused only because TokenizerBridge writes every assistant turn
// with its empty think block, and MLXLocalRuntime drops the pictures' all-ones mask),
// Qwen3.5's XML-function tool calls (`.toolCall` / `.rejectedToolCall`) and the
// continuation after tool results. Thinking is always off.
//
// What it does not do, and how this file copes:
// - No prefill without generating. prepare() makes the session from the system
//   prompt, the tool specs and the few-shot history (the "re-hydration" init);
//   the first send prefills them together with the first message. The runtime
//   already ran a warm-up decode at load, so the Metal kernels are compiled.
// - A generation that is cancelled, empty or holds a rejected tool call is not
//   recorded, and its input is rolled back. The brain believes it was sent, so
//   those messages are replayed in front of the next send, followed by what the
//   model wrote ("…" when it was cut off: what was heard reaches the model as
//   interruptedAfter). The cache is rebuilt from the transcript then (D6: 1–3 s).
// - Any other error drops the session; the next send starts a fresh one from the
//   setup (the brain's next message then carries the whole editor state).
// - close() (the runtime unloads the weights) lets go of the container as well as
//   the session: a brain that keeps this engine for its conversation must not keep
//   about 3 GB of weights resident. A closed engine answers `.modelNotReady`; the
//   brain then opens a fresh one, which works once the weights are back.
#if canImport(MLXVLM)
import CoreImage
import Foundation
import MLXLMCommon
import PicshopCore
import PicshopIntent

final class MLXChatEngine: LocalChatEngine, @unchecked Sendable {
    let info: LocalModelInfo
    /// Nil once closed: nothing here keeps the weights alive after an unload.
    private var container: ModelContainer?
    private let setup: LocalChatSetup
    private let lock = NSLock()
    private var session: ChatSession?
    private var closed = false
    /// Sent, but rolled back by the session: replayed in front of the next send.
    private var unrecorded: [Chat.Message] = []
    private var current: Task<Void, Never>?
    private var lastContextTokens = 0
    private var callCounter = 0

    init(container: ModelContainer, info: LocalModelInfo, setup: LocalChatSetup) {
        self.container = container
        self.info = info
        self.setup = setup
    }

    func prepare() async throws {
        try lock.withLock {
            guard !closed else { throw LiveBrainError.modelNotReady }
            if session == nil { session = makeSession() }
            guard session != nil else { throw LiveBrainError.modelNotReady }
        }
    }

    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LocalChatEvent, Error>.makeStream()
        let batch = messages.flatMap(Self.chatMessages)
        // One generation at a time, in order: a cut-off one finishes (and says what it
        // left unrecorded) before the next takes the replay.
        let task: Task<Void, Never> = lock.withLock {
            let previous = current
            previous?.cancel()
            let task = Task { [weak self] in
                await previous?.value
                guard let self else {
                    continuation.finish(throwing: LiveBrainError.modelNotReady)
                    return
                }
                await self.generate(batch, options: options, continuation: continuation)
            }
            current = task
            return task
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func contextTokens() async -> Int {
        lock.withLock { lastContextTokens }
    }

    func close() async {
        let running: Task<Void, Never>? = lock.withLock {
            closed = true
            session = nil
            container = nil
            unrecorded = []
            defer { current = nil }
            return current
        }
        running?.cancel()
    }

    /// Stops the generation in flight (the app is leaving the foreground); the conversation stays.
    func stopGenerating() {
        let running = lock.withLock { current }
        running?.cancel()
    }

    // MARK: Generation

    private func generate(_ batch: [Chat.Message], options: LocalGenerationOptions,
                          continuation: AsyncThrowingStream<LocalChatEvent, Error>.Continuation) async {
        let prepared: (ChatSession, [Chat.Message])? = lock.withLock {
            guard !closed, let session = self.session ?? makeSession() else { return nil }
            self.session = session
            let replay = unrecorded
            unrecorded = []
            return (session, replay + batch)
        }
        guard let prepared else {
            continuation.finish(throwing: LiveBrainError.modelNotReady)
            return
        }
        let (session, input) = prepared
        session.generateParameters = Self.parameters(options)
        let started = Date()
        var firstTokenMs: Int?
        var text = ""
        var calls = 0
        var rejected: [String] = []
        var completion: GenerateCompletionInfo?

        func first() {
            if firstTokenMs == nil { firstTokenMs = Int(Date().timeIntervalSince(started) * 1_000) }
        }

        do {
            for try await item in session.streamDetails(to: input) {
                if Task.isCancelled { break }
                switch item {
                case .chunk(let chunk):
                    first()
                    text += chunk
                    continuation.yield(.text(chunk))
                case .toolCall(let call):
                    first()
                    calls += 1
                    continuation.yield(.toolCall(localCall(call)))
                case .rejectedToolCall(let rejection):
                    first()
                    rejected.append(rejection.rawTextPreview)
                    continuation.yield(.rejectedToolCall(raw: rejection.rawTextPreview))
                case .info(let info):
                    completion = info
                }
            }
        } catch {
            // The session's state is unknown after a failure: start clean next time.
            lock.withLock {
                if self.session === session { self.session = nil }
                unrecorded = []
            }
            if Task.isCancelled {
                continuation.finish()
            } else {
                PSLog.error("local model generation failed: \(error)", category: .intent)
                continuation.finish(throwing: LiveBrainError.unavailable("mlx: \(String(describing: type(of: error)).prefix(40))"))
            }
            return
        }

        // No completion info: the stream was cut off before the end.
        let cancelled = completion == nil || completion?.stopReason == .cancelled
        let recorded = !cancelled && rejected.isEmpty && (!text.isEmpty || calls > 0)
        lock.withLock {
            if !recorded, self.session === session {
                let wrote = cancelled ? "…" : (text + rejected.joined(separator: "\n"))
                unrecorded = input + [.assistant(wrote.isEmpty ? "…" : wrote)]
            }
            if let completion { lastContextTokens = completion.totalPromptTokenCount + completion.generationTokenCount }
        }
        if cancelled {
            continuation.finish()
            return
        }
        continuation.yield(.finished(stats(completion, firstTokenMs: firstTokenMs), Self.stopReason(completion)))
        continuation.finish()
    }

    /// Nil once the engine is closed (the weights were unloaded). Called with the lock held.
    private func makeSession() -> ChatSession? {
        guard let container else { return nil }
        return ChatSession(container, instructions: setup.system, history: setup.history.flatMap(Self.chatMessages),
                    generateParameters: Self.parameters(LocalGenerationOptions()),
                    processing: UserInput.Processing(maxPixels: setup.imageMaxPixels),
                    additionalContext: ["enable_thinking": false],
                    tools: setup.tools.compactMap(MLXJSON.toolSpec))
    }

    private func localCall(_ call: ToolCall) -> LocalToolCall {
        let id: String = call.id ?? lock.withLock {
            callCounter += 1
            return "mlx_call_\(callCounter)"
        }
        return LocalToolCall(id: id, name: call.function.name, arguments: .object(call.function.arguments.mapValues(MLXJSON.local)))
    }

    private func stats(_ info: GenerateCompletionInfo?, firstTokenMs: Int?) -> LiveGenerationStats {
        let speed = info?.tokensPerSecond ?? 0
        return LiveGenerationStats(model: self.info.displayName, promptTokens: info?.promptTokenCount ?? 0, cachedTokens: info?.cachedPromptTokenCount ?? 0,
                                   generatedTokens: info?.generationTokenCount ?? 0, firstTokenMs: firstTokenMs ?? 0,
                                   tokensPerSecond: speed.isFinite ? speed : 0)
    }

    static func parameters(_ options: LocalGenerationOptions) -> GenerateParameters {
        GenerateParameters(maxTokens: options.maxTokens, temperature: Float(options.temperature), topP: Float(options.topP), topK: options.topK,
                           presencePenalty: Float(options.presencePenalty))
    }

    static func stopReason(_ info: GenerateCompletionInfo?) -> LocalStopReason {
        switch info?.stopReason {
        case .length?: return .maxTokens
        case .cancelled?: return .cancelled
        case .stop?, nil: return .endOfTurn
        }
    }

    /// PicshopIntent's messages in MLX's chat format; pictures as CIImages (the processor downsizes them to the pixel budget).
    static func chatMessages(_ message: LocalChatMessage) -> [Chat.Message] {
        switch message {
        case .user(let text, let jpeg):
            let images: [UserInput.Image] = jpeg.flatMap { CIImage(data: $0) }.map { [.ciImage($0)] } ?? []
            return [.user(text, images: images)]
        case .assistant(let text, let calls):
            let toolCalls = calls.map { call in
                ToolCall(function: ToolCall.Function(name: call.name, arguments: MLXJSON.arguments(call.arguments)), id: call.id)
            }
            return [.assistant(text, toolCalls: toolCalls.isEmpty ? nil : toolCalls)]
        case .toolResult(let id, let name, let content):
            return [.tool(content, id: id, name: name)]
        }
    }
}

/// JSON between PicshopIntent (numbers as Double) and MLXLMCommon (Int or Double, and
/// `[String: any Sendable]` for tool specs). Both modules call it JSONValue.
enum MLXJSON {
    static func mlx(_ value: PicshopIntent.JSONValue) -> MLXLMCommon.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return .int(Int(number)) }
            return .double(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(mlx))
        case .object(let object): return .object(object.mapValues(mlx))
        }
    }

    static func local(_ value: MLXLMCommon.JSONValue) -> PicshopIntent.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return .number(Double(number))
        case .double(let number): return .number(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(local))
        case .object(let object): return .object(object.mapValues(local))
        }
    }

    /// A tool call's arguments object.
    static func arguments(_ value: PicshopIntent.JSONValue) -> [String: MLXLMCommon.JSONValue] {
        guard case .object(let object) = value else { return [:] }
        return object.mapValues(mlx)
    }

    /// `{"type":"function","function":{…}}` as the chat template reads it.
    static func toolSpec(_ value: PicshopIntent.JSONValue) -> MLXLMCommon.ToolSpec? {
        guard case .object = value, let spec = sendable(value) as? [String: any Sendable] else { return nil }
        return spec
    }

    /// Plain Swift values for the Jinja renderer; nulls are left out of objects.
    static func sendable(_ value: PicshopIntent.JSONValue) -> any Sendable {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return Int(number) }
            return number
        case .string(let text): return text
        case .array(let items): return items.map(sendable)
        case .object(let object):
            var result: [String: any Sendable] = [:]
            for (key, item) in object where item != .null { result[key] = sendable(item) }
            return result
        }
    }
}
#endif
