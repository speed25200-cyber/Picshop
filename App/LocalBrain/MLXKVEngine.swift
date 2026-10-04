// The KV engine (W3, D22): one Live conversation over the loaded Qwen3.5 weights on mlx-swift-lm's public low-level
// API, so the cache survives what ChatSession throws away. Where W2's `MLXChatEngine` rebuilds the whole cache after a
// cut-off reply (1–3 s), a picture turn, or a tool call the template re-renders differently, this engine:
// - keeps the exact token ledger the cache holds (prompt ids fed, then every id `next()` returned, the stop token
//   included) and the transcript, re-rendered each turn by the model's own processor (the patched Jinja template);
// - lets `KVTurnPlanner` (PicshopIntent, Linux-tested) choose: append the new suffix, restore the turn checkpoint,
//   restore the prefix snapshot, or rebuild;
// - takes a checkpoint after each turn's prefill (attention layers are trimmed back, the recurrent ones copied), so a
//   barge-in, an empty or a rejected reply restores in about 0 ms and keeps W2's replay of the unrecorded messages;
// - starts every conversation and every compaction from a copy of the prefix snapshot (`MLXPrefixStore`), so only
//   the recap and the first message are prefilled;
// - appends a picture turn to the warm cache when the self-test verified it (`mediaAppendVerified`), slicing the
//   picture payload to the pictures in the suffix (`KVMediaSlice`); otherwise it restores the prefix and prefills the
//   tail with every picture in it.
// It keeps `MLXChatEngine`'s outside: one generation at a time, `close()` drops the container, `stopGenerating()`,
// the model marked busy for the broker, the `llm.prefill` and `llm.decode` signposts, the same events and stats.
//
// The decode loop is the one mlx-swift-lm's generate task runs (Evaluate.swift, ee673d6): cancellation is checked
// before each `next()`, stop ids are the configuration's EOS ids, the tokenizer's EOS and the extra EOS tokens (plus
// the unknown token), text goes through a streaming detokenizer, the stop-string filter (`KVStopStringFilter`: the
// library's is package-internal) and `ToolCallProcessor`, and `Stream().synchronize()` settles the GPU before the
// turn leaves the worker. All MLX work runs on one serial worker outside Swift's cooperative pool.
#if canImport(MLXVLM)
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import PicshopCore
import PicshopImaging
import PicshopIntent
import PicshopUI

/// Runs the KV engines' blocking MLX work one turn at a time, outside Swift's cooperative pool (mlx-swift-lm's own
/// `GenerationWorker` is internal). The calling task's cancellation is still visible inside `run`.
actor KVWorker {
    static let shared = KVWorker()

    private nonisolated let queue = DispatchSerialQueue(label: "com.picshopio.picshop.kv")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func run<R: Sendable>(_ body: @Sendable () throws -> R) rethrows -> R {
        try body()
    }
}

/// Non-Sendable MLX values handed across the worker hop; only ever touched by one turn at a time.
struct KVUnchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// What a turn's cache looked like right after its prefill: the ledger count, copies of the layers that cannot be
/// trimmed (Qwen3.5's recurrent ones), and the model state.
struct KVCheckpoint {
    let count: Int
    let copies: [Int: KVCache]
    let state: LMOutput.State?
}

/// The conversation's KV state. Touched only by the generation in flight (generations are chained).
final class KVConversation {
    var cache: [KVCache] = []
    var state: LMOutput.State?
    var ledger: [Int] = []
    var snapshot: KVPrefixSnapshot?
    var checkpoint: KVCheckpoint?
    /// The setup's history, then every recorded (or replayed) message.
    var transcript: [Chat.Message] = []
    /// The last turn's cache offset did not match the ledger: the next turn rebuilds.
    var needsRebuild = false
    /// Seeded from the prefix snapshot and no turn yet: the first turn's path is "prefix".
    var freshFromPrefix = false

    var prefixCount: Int { snapshot?.tokens.count ?? 0 }
}

/// What one turn did, for the stats and the self-test.
struct KVTurnOutcome: Sendable {
    var path: String
    var prefilled: Int
    var cached: Int
    var generatedIDs: [Int]
    var calls: [String]
    var firstTokenMs: Int?
    var decodeSeconds: Double
    var stopReason: LocalStopReason
    var cancelled: Bool
    var restoreMs: Int?
}

final class MLXKVEngine: LocalChatEngine, @unchecked Sendable {
    let info: LocalModelInfo
    let mediaAppendVerified: Bool
    var engineKind: LocalEngineKind { .kvEngine }

    private let setup: LocalChatSetup
    private let store: MLXPrefixStore
    /// The self-test's cold reference: never a snapshot, never a reuse.
    private let coldOnly: Bool
    /// Barge-in restores and diagnostics notes, to the runtime.
    private let report: (@Sendable (KVTurnOutcome) -> Void)?
    private let lock = NSLock()
    private var container: ModelContainer?
    private var closed = false
    private var current: Task<Void, Never>?
    private var callCounter = 0
    private var lastContextTokens = 0
    private var conversation = KVConversation()
    /// The memory-warning path asked to let go of the prefix snapshot: the next turn forgets it.
    private var dropsPrefix = false
    /// The last turn's outcome (the self-test reads it).
    private var lastOutcome: KVTurnOutcome?

    /// `transcript`: the self-test's cold reference starts from the warm engine's transcript instead of the setup's.
    init(container: ModelContainer, info: LocalModelInfo, setup: LocalChatSetup, mediaAppendVerified: Bool, store: MLXPrefixStore = .shared,
         coldOnly: Bool = false, transcript: [Chat.Message]? = nil, report: (@Sendable (KVTurnOutcome) -> Void)? = nil) {
        self.container = container
        self.info = info
        self.setup = setup
        self.mediaAppendVerified = mediaAppendVerified
        self.store = store
        self.coldOnly = coldOnly
        self.report = report
        conversation.transcript = transcript ?? setup.history.flatMap(MLXChatEngine.chatMessages)
    }

    /// The transcript between generations (the self-test's cold reference copies it).
    func transcriptSnapshot() -> [Chat.Message] {
        lock.withLock { conversation.transcript }
    }

    // MARK: LocalChatEngine

    /// Seeds the conversation from the prefix snapshot (a copy when it exists, else it is built now), so the first
    /// turn prefills only its own message. Idempotent; a failure leaves the first turn to do it.
    func prepare() async throws {
        let task: Task<Void, Never> = try lock.withLock {
            guard !closed, container != nil else { throw LiveBrainError.modelNotReady }
            let previous = current
            let task = Task { [weak self] in
                await previous?.value
                await self?.seed()
            }
            current = task
            return task
        }
        // The caller's cancellation (the app resigning active) reaches the seeding task: its prefill is not started.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LocalChatEvent, Error>.makeStream()
        let batch = messages.flatMap(MLXChatEngine.chatMessages)
        let hasNewMedia = messages.contains { if case .user(_, let image?) = $0 { return !image.isEmpty } else { return false } }
        let sendable = KVUnchecked(value: batch)
        // One generation at a time, in order: a cut-off one restores its checkpoint before the next one starts.
        let task: Task<Void, Never> = lock.withLock {
            let previous = current
            previous?.cancel()
            let task = Task { [weak self] in
                await previous?.value
                guard let self else {
                    continuation.finish(throwing: LiveBrainError.modelNotReady)
                    return
                }
                await self.generate(sendable.value, hasNewMedia: hasNewMedia, options: options, continuation: continuation)
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
            container = nil
            conversation = KVConversation()
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

    /// The memory-warning path: forget the prefix snapshot (the next compaction or restore rebuilds from scratch).
    func dropPrefix() {
        lock.withLock { dropsPrefix = true }
    }

    /// The last turn's outcome, for KVSelfTest.
    var outcome: KVTurnOutcome? { lock.withLock { lastOutcome } }

    // MARK: Generation

    /// One generation, the model marked busy for the broker throughout (W2, D12): a busy LLM is never evicted.
    private func generate(_ batch: [Chat.Message], hasNewMedia: Bool, options: LocalGenerationOptions,
                          continuation: AsyncThrowingStream<LocalChatEvent, Error>.Continuation) async {
        await ModelResidency.markBusy(.llm, true)
        await run(batch, hasNewMedia: hasNewMedia, options: options, continuation: continuation)
        await ModelResidency.markBusy(.llm, false)
    }

    private func run(_ batch: [Chat.Message], hasNewMedia: Bool, options: LocalGenerationOptions,
                     continuation: AsyncThrowingStream<LocalChatEvent, Error>.Continuation) async {
        // Every member read through self: a bare name here would resolve to the locals declared below.
        let state: (ModelContainer, KVConversation, Bool)? = lock.withLock {
            guard !self.closed, let held = self.container else { return nil }
            let dropping = self.dropsPrefix
            self.dropsPrefix = false
            return (held, self.conversation, dropping)
        }
        guard let state else {
            continuation.finish(throwing: LiveBrainError.modelNotReady)
            return
        }
        let (container, conversation, drop) = state
        if drop { conversation.snapshot = nil }
        let started = Date()
        let parameters = MLXChatEngine.parameters(options)
        let input = KVUnchecked(value: (conversation, batch))
        do {
            let outcome = try await container.perform { context in
                let (conversation, batch) = input.value
                let prompt = try await self.render(conversation.transcript + batch, context: context)
                var plan: PrefixPlan?
                if conversation.ledger.isEmpty, !self.coldOnly { plan = try? await self.prefixPlan(context: context) }
                let work = KVUnchecked(value: (context, prompt, plan, conversation, batch))
                return try await KVWorker.shared.run {
                    let (context, prompt, plan, conversation, batch) = work.value
                    return try self.turn(conversation, batch: batch, prompt: prompt, plan: plan, hasNewMedia: hasNewMedia, context: context,
                                         parameters: parameters, started: started, continuation: continuation)
                }
            }
            lock.withLock {
                lastContextTokens = conversation.ledger.count
                lastOutcome = outcome
            }
            report?(outcome)
            if outcome.cancelled {
                continuation.finish()
                return
            }
            let speed = outcome.decodeSeconds > 0 ? Double(outcome.generatedIDs.count) / outcome.decodeSeconds : 0
            let stats = LiveGenerationStats(model: info.displayName, promptTokens: outcome.prefilled, cachedTokens: outcome.cached,
                                            generatedTokens: outcome.generatedIDs.count, firstTokenMs: outcome.firstTokenMs ?? 0,
                                            tokensPerSecond: speed.isFinite ? speed : 0, kvPath: outcome.path, prefixTokens: conversation.prefixCount)
            continuation.yield(.finished(stats, outcome.stopReason))
            continuation.finish()
        } catch {
            // The cache's state is unknown after a failure: the next turn rebuilds from the transcript.
            conversation.needsRebuild = true
            if Task.isCancelled {
                continuation.finish()
            } else {
                PSLog.error("kv engine: generation failed: \(error)", category: .intent)
                Diagnostics.shared.note("kv engine: \(String(describing: type(of: error)).prefix(40)), rebuilding")
                continuation.finish(throwing: LiveBrainError.unavailable("mlx-kv: \(String(describing: type(of: error)).prefix(40))"))
            }
        }
    }

    /// The prefix snapshot, before the first turn (`prepare`).
    private func seed() async {
        guard !coldOnly, let container = lock.withLock({ closed ? nil : container }) else { return }
        let conversation = lock.withLock { self.conversation }
        guard conversation.ledger.isEmpty else { return }
        let box = KVUnchecked(value: conversation)
        do {
            try await container.perform { context in
                guard let plan = try await self.prefixPlan(context: context) else { return }
                let work = KVUnchecked(value: context)
                try await KVWorker.shared.run {
                    let conversation = box.value
                    guard !Task.isCancelled, conversation.ledger.isEmpty else { return }
                    let snapshot = try self.store.snapshot(for: plan.key, tokens: plan.tokens, context: work.value, persist: plan.persist)
                    self.adopt(snapshot, into: conversation)
                    conversation.freshFromPrefix = true
                }
            }
            lock.withLock { lastContextTokens = conversation.ledger.count }
        } catch {
            PSLog.error("kv engine: prefix snapshot failed: \(error)", category: .models)
        }
    }

    // MARK: Rendering (async, before the worker)

    struct PrefixPlan: Sendable {
        var key: LivePrefixKey
        var tokens: [Int]
        var persist: Bool
    }

    /// The prompt exactly as ChatSession renders it: the system prompt, the transcript, the tools, thinking off,
    /// through the container's processor (the patched template; pictures without the all-ones mask).
    private func render(_ messages: [Chat.Message], context: ModelContext) async throws -> LMInput {
        let input = UserInput(chat: [.system(setup.system)] + messages, processing: UserInput.Processing(maxPixels: setup.imageMaxPixels),
                              tools: setup.tools.compactMap(MLXJSON.toolSpec), additionalContext: ["enable_thinking": false])
        return try await context.processor.prepare(input: input)
    }

    /// D22 step 3: the shared prefix's ids (the canonical setup, rendered and stripped of the generation prompt) and
    /// its key. Nil when the render does not end with the generation prompt or holds a picture.
    private func prefixPlan(context: ModelContext) async throws -> PrefixPlan? {
        let (prefixSetup, canonical) = store.prefixSetup(for: setup)
        let input = UserInput(chat: [.system(prefixSetup.system)] + prefixSetup.history.flatMap(MLXChatEngine.chatMessages),
                              processing: UserInput.Processing(maxPixels: prefixSetup.imageMaxPixels),
                              tools: prefixSetup.tools.compactMap(MLXJSON.toolSpec), additionalContext: ["enable_thinking": false])
        let rendered = try await context.processor.prepare(input: input)
        guard rendered.image == nil, rendered.video == nil else { return nil }
        let generation = context.tokenizer.encode(text: QwenChatTemplate.generationPrompt, addSpecialTokens: false)
        guard let tokens = KVTurnPlanner.prefixTokens(rendered: rendered.text.tokens.asArray(Int.self), generationPrompt: generation) else {
            PSLog.error("kv engine: the prefix render does not end with the generation prompt; no snapshot", category: .models)
            return nil
        }
        let key = LivePrefixKey(modelID: info.id, revision: info.revision, runtimeRevision: MLXPrefixStore.runtimeRevision,
                                mode: "system-" + String(StableHash.hex(prefixSetup.system).prefix(8)), size: info.promptSize.rawValue,
                                layout: LocalPromptLayout.current.rawValue, prefixHash: LivePrefixKey.prefixHash(tokens: tokens),
                                templateHash: TokenizerBridge.templateHash)
        return PrefixPlan(key: key, tokens: tokens, persist: canonical)
    }

    // MARK: The turn (on the worker)

    private func adopt(_ snapshot: KVPrefixSnapshot, into conversation: KVConversation) {
        let (cache, state) = snapshot.restored()
        conversation.cache = cache
        conversation.state = state
        conversation.ledger = snapshot.tokens
        conversation.snapshot = snapshot
        conversation.checkpoint = nil
    }

    private func freshCache(_ conversation: KVConversation, context: ModelContext, parameters: GenerateParameters) throws {
        conversation.cache = try context.model.newCache(parameters: parameters)
        conversation.state = nil
        conversation.ledger = []
        conversation.checkpoint = nil
    }

    /// Restores the turn checkpoint: attention layers trimmed back to it, recurrent layers replaced by copies of its
    /// copies, its model state. Returns the milliseconds it took.
    @discardableResult
    private func restore(_ checkpoint: KVCheckpoint, in conversation: KVConversation) -> Int {
        let started = Date()
        for index in conversation.cache.indices {
            if let copy = checkpoint.copies[index] {
                conversation.cache[index] = copy.copy()
            } else {
                let layer = conversation.cache[index]
                let excess = layer.offset - checkpoint.count
                if excess > 0 { layer.trim(excess) }
            }
        }
        conversation.state = checkpoint.state
        if conversation.ledger.count > checkpoint.count { conversation.ledger.removeSubrange(checkpoint.count...) }
        return Int(Date().timeIntervalSince(started) * 1_000)
    }

    private func makeCheckpoint(_ conversation: KVConversation, state: LMOutput.State?) -> KVCheckpoint {
        var copies: [Int: KVCache] = [:]
        for (index, layer) in conversation.cache.enumerated() where !canTrimPromptCache([layer]) {
            copies[index] = layer.copy()
        }
        return KVCheckpoint(count: conversation.ledger.count, copies: copies, state: state)
    }

    /// The suffix input from `from`: text ids, plus the picture payload of the pictures whose placeholders lie in
    /// it. Nil when the payload cannot be attributed picture by picture (the caller prefills from scratch).
    private func suffixInput(_ prompt: LMInput, ids: [Int], from: Int, context: ModelContext) -> LMInput? {
        let suffix = Array(ids[from...])
        guard let image = prompt.image else {
            guard prompt.video == nil else { return nil }
            return LMInput(tokens: MLXArray(suffix))
        }
        guard prompt.video == nil, image.positionIds == nil, let frames = image.frames, !frames.isEmpty, frames.allSatisfy({ $0.t == 1 }),
              let pad = context.tokenizer.convertTokenToId("<|image_pad|>") else { return nil }
        let rows = frames.map(\.product)
        let pads = ids.filter { $0 == pad }.count
        guard pads > 0, rows.reduce(0, +) % pads == 0, image.pixels.ndim == 2, image.pixels.dim(0) == rows.reduce(0, +),
              let plan = KVMediaSlice.plan(tokens: ids, padToken: pad, rowsPerPicture: rows, mergeLength: rows.reduce(0, +) / pads, from: from)
        else { return nil }
        // The processor's [1, n] layout: a rank-1 suffix would take the model's cold path.
        let tokens = MLXArray(suffix).expandedDimensions(axis: 0)
        guard plan.carriesPictures else { return LMInput(text: .init(tokens: tokens)) }
        let pixels = image.pixels[plan.droppedRows ..< image.pixels.dim(0), 0...]
        return LMInput(text: .init(tokens: tokens), image: LMInput.ProcessedImage(pixels: pixels, frames: Array(frames[plan.firstPicture...])))
    }

    private func turn(_ conversation: KVConversation, batch: [Chat.Message], prompt: LMInput, plan: PrefixPlan?, hasNewMedia: Bool,
                      context: ModelContext, parameters: GenerateParameters, started: Date,
                      continuation: AsyncThrowingStream<LocalChatEvent, Error>.Continuation) throws -> KVTurnOutcome {
        let ids = prompt.text.tokens.asArray(Int.self)
        guard !ids.isEmpty else { throw LiveBrainError.unavailable("mlx-kv: empty prompt") }
        // Cancelled before the prefill (the app resigning active, a barge-in): no GPU work starts. The cache is as the
        // last turn left it (the ledger says what it holds); the turn is recorded as cut off, as after a decode stop.
        func cancelledBeforePrefill() -> KVTurnOutcome {
            conversation.transcript += batch + [.assistant("…")]
            return KVTurnOutcome(path: "cancelled", prefilled: 0, cached: conversation.ledger.count, generatedIDs: [], calls: [], firstTokenMs: nil,
                                 decodeSeconds: 0, stopReason: .cancelled, cancelled: true, restoreMs: nil)
        }
        if Task.isCancelled { return cancelledBeforePrefill() }

        // A fresh conversation starts from the prefix snapshot.
        if conversation.ledger.isEmpty, !coldOnly, let plan {
            do {
                adopt(try store.snapshot(for: plan.key, tokens: plan.tokens, context: context, persist: plan.persist), into: conversation)
                conversation.freshFromPrefix = true
            } catch {
                PSLog.error("kv engine: prefix snapshot failed: \(error)", category: .models)
            }
        }

        // The decision.
        var decision: KVTurnDecision
        if coldOnly || conversation.needsRebuild {
            decision = .rebuild
        } else {
            decision = KVTurnPlanner.decide(ledger: conversation.ledger, prompt: ids, prefixCount: conversation.prefixCount,
                                            turnCheckpoint: conversation.checkpoint?.count, hasNewMedia: hasNewMedia,
                                            mediaAppendVerified: mediaAppendVerified)
        }
        // Never an iterator over a warm cache without its state (Qwen3.5's rope anchor).
        if case .appendSuffix = decision, conversation.state == nil { decision = .rebuild }
        conversation.needsRebuild = false

        // Apply it.
        var restoreMs: Int?
        switch decision {
        case .appendSuffix:
            break
        case .restoreTurn:
            if let checkpoint = conversation.checkpoint { restoreMs = restore(checkpoint, in: conversation) } else { decision = .rebuild }
        case .restorePrefix:
            if let snapshot = conversation.snapshot { adopt(snapshot, into: conversation) } else { decision = .rebuild }
        case .rebuild:
            break
        }
        if case .rebuild = decision {
            // A layout or template change, or a failed restore: from the prefix when the prompt still starts with it.
            if !coldOnly, let snapshot = conversation.snapshot, ids.count > snapshot.tokens.count, ids.starts(with: snapshot.tokens) {
                adopt(snapshot, into: conversation)
            } else {
                try freshCache(conversation, context: context, parameters: parameters)
            }
        }

        // The suffix.
        var from = conversation.ledger.count
        var input: LMInput
        if from == 0 {
            input = prompt
        } else if let suffix = suffixInput(prompt, ids: ids, from: from, context: context) {
            input = suffix
        } else {
            Diagnostics.shared.note("kv engine: picture payload not sliceable, full prefill")
            try freshCache(conversation, context: context, parameters: parameters)
            from = 0
            input = prompt
        }
        let path: String
        if from == 0 {
            path = KVTurnDecision.rebuild.path(hasNewMedia: hasNewMedia)
        } else if conversation.freshFromPrefix, case .appendSuffix = decision {
            path = KVTurnDecision.restorePrefix(thenAppendFrom: from).path(hasNewMedia: hasNewMedia)
        } else {
            path = decision.path(hasNewMedia: hasNewMedia)
        }
        conversation.freshFromPrefix = false
        let prefill = PSSignpost.begin("llm.prefill", "\(info.displayName) · path=\(path) prefilled=\(ids.count - from) cached=\(from)")
        var prefillOpen = true
        var decode: PSSignpost.Interval?
        defer {
            if prefillOpen { PSSignpost.end(prefill) }
            if let decode { PSSignpost.end(decode) }
        }

        // Last stop before the prefill: the cache and the ledger agree here (adopt, restore and fresh caches keep them so).
        if Task.isCancelled { return cancelledBeforePrefill() }
        var iterator: TokenIterator
        do {
            iterator = try TokenIterator(input: input, model: context.model, cache: conversation.cache, state: conversation.state, parameters: parameters)
        } catch let error as ContinuationStateError where from > 0 {
            // A warm cache without its anchor: rebuild once, cold.
            Diagnostics.shared.note("kv engine: \(error.localizedDescription.prefix(60)), rebuilding")
            try freshCache(conversation, context: context, parameters: parameters)
            from = 0
            iterator = try TokenIterator(input: prompt, model: context.model, cache: conversation.cache, state: nil, parameters: parameters)
        }
        // Right after init the cache holds exactly the prompt: the turn checkpoint.
        conversation.ledger = ids
        conversation.checkpoint = makeCheckpoint(conversation, state: iterator.state)

        // The decode loop.
        let configuration = context.configuration
        let tokenizer = context.tokenizer
        var stop = configuration.eosTokenIds
        if let eos = tokenizer.eosTokenId { stop.insert(eos) }
        for token in configuration.extraEOSTokens { if let id = tokenizer.convertTokenToId(token) { stop.insert(id) } }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        var filter = KVStopStringFilter(stopStrings: configuration.effectiveStopStrings)
        let processor = ToolCallProcessor(format: configuration.toolCallFormat ?? .json, tools: setup.tools.compactMap(MLXJSON.toolSpec),
                                          toolCallPolicy: parameters.toolCallPolicy)
        var generated: [Int] = []
        var content = ""
        var calls: [ToolCall] = []
        var rejected: [String] = []
        var stopReason = LocalStopReason.maxTokens
        var cancelled = false
        var firstTokenMs: Int?
        var decodeStarted = Date()

        func emit(_ outputs: [ToolCallProcessor.Output]) {
            for output in outputs {
                switch output {
                case .response(let text):
                    content += text
                    continuation.yield(.text(text))
                case .toolCall(let call):
                    calls.append(call)
                    continuation.yield(.toolCall(localCall(call)))
                case .rejectedToolCall(let rejection):
                    rejected.append(rejection.rawTextPreview)
                    continuation.yield(.rejectedToolCall(raw: rejection.rawTextPreview))
                }
            }
        }

        while true {
            // Before next(): an asyncEval submitted after cancellation faults in the background.
            if Task.isCancelled {
                cancelled = true
                break
            }
            guard let token = iterator.next() else { break }
            conversation.ledger.append(token)
            generated.append(token)
            if firstTokenMs == nil {
                firstTokenMs = Int(Date().timeIntervalSince(started) * 1_000)
                PSSignpost.end(prefill)
                prefillOpen = false
                decode = PSSignpost.begin("llm.decode", info.displayName)
                decodeStarted = Date()
            }
            if token == tokenizer.unknownTokenId || stop.contains(token) {
                stopReason = .endOfTurn
                break
            }
            detokenizer.append(token: token)
            if let chunk = detokenizer.next() {
                let filtered = filter.process(chunk)
                if let text = filtered.text { emit(processor.processChunkOutputs(text)) }
                if filtered.stopped {
                    stopReason = .endOfTurn
                    break
                }
            }
        }
        if !cancelled {
            if let tail = filter.finish() { emit(processor.processChunkOutputs(tail)) }
            emit(processor.processEOSOutputs())
        }
        Stream().synchronize()
        conversation.state = iterator.state
        let decodeSeconds = Date().timeIntervalSince(decodeStarted)

        // Record, or restore and replay (W2's rule): what the model wrote goes in front of the next send.
        let recorded = !cancelled && rejected.isEmpty && (!content.isEmpty || !calls.isEmpty)
        if recorded {
            conversation.transcript += batch + [.assistant(content, toolCalls: calls.isEmpty ? nil : calls)]
            // After every generation the attention offset must equal the ledger: else the next turn rebuilds.
            if let attention = conversation.cache.first(where: { $0.isTrimmable }), attention.offset != conversation.ledger.count {
                conversation.needsRebuild = true
                Diagnostics.shared.note("kv engine: cache offset \(attention.offset) ≠ ledger \(conversation.ledger.count), rebuilding")
            }
        } else {
            let wrote = cancelled ? "…" : content + rejected.joined(separator: "\n")
            conversation.transcript += batch + [.assistant(wrote.isEmpty ? "…" : wrote)]
            if let checkpoint = conversation.checkpoint { restoreMs = restore(checkpoint, in: conversation) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let callJSON: [String] = calls.map { call in
            guard let data = try? encoder.encode(call.function), let text = String(data: data, encoding: .utf8) else { return call.function.name }
            return text
        }
        return KVTurnOutcome(path: path, prefilled: ids.count - from, cached: from, generatedIDs: generated, calls: callJSON,
                             firstTokenMs: firstTokenMs, decodeSeconds: decodeSeconds, stopReason: cancelled ? .cancelled : stopReason,
                             cancelled: cancelled, restoreMs: recorded ? nil : restoreMs)
    }

    private func localCall(_ call: ToolCall) -> LocalToolCall {
        let id: String = call.id ?? lock.withLock {
            callCounter += 1
            return "kv_call_\(callCounter)"
        }
        return LocalToolCall(id: id, name: call.function.name, arguments: .object(call.function.arguments.mapValues(MLXJSON.local)))
    }
}
#endif
