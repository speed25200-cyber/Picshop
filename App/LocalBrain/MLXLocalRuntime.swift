// The local brain's runtime: Qwen3.5 through MLX (mlx-swift-lm pinned by revision
// in project.yml, tokenizer from swift-transformers). PicshopKit never links MLX:
// PicshopApp.init registers this runtime with LocalBrainHub, and everything
// MLX-specific stays in App/LocalBrain.
//
// - load: from ModelManager's `<id>/model` folder with VLMModelFactory (the same
//   weights see pictures), gated on free memory (D13), then one short decode so
//   the Metal kernels are compiled before the first real turn. The processor is
//   wrapped so pictures do not come with an attention mask (prefix reuse needs none).
// - makeEngine: one MLXChatEngine (one ChatSession, one KV cache) per Live
//   conversation. Unloading closes every engine, so no session keeps the weights alive.
// - makePlanner: push-to-talk's planner over the same weights.
// - benchmark: the Settings speed test.
#if canImport(MLXVLM)
import Foundation
import MLXLMCommon
import MLXVLM
import PicshopCore
import PicshopIntent
import PicshopUI

final class MLXLocalRuntime: LocalModelRuntime, @unchecked Sendable {
    static let shared = MLXLocalRuntime()

    private let lock = NSLock()
    private var container: ModelContainer?
    private var loadedInfo: LocalModelInfo?
    /// Bumped by every load and unload, so a reused planner session never outlives its weights.
    private var generation = 0
    private var loading: (id: String, task: Task<Void, Error>)?
    private let engines = NSHashTable<MLXChatEngine>.weakObjects()
    private var planner: MLXPlanner?
    private var lastLoadMs = 0

    private init() {}

    /// False on the simulator (MLX builds there but cannot run) and without a Metal GPU.
    var isUsable: Bool { Self.deviceCanRun }
    /// Asked once: the hub reads isUsable on every status refresh.
    private static let deviceCanRun = MemoryGuard.deviceCanRun

    func load(_ info: LocalModelInfo, from directory: URL) async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if loadedInfo?.id == info.id, container != nil { return nil }
            if let loading, loading.id == info.id { return loading.task }
            loading?.task.cancel()
            let task = Task.detached(priority: .userInitiated) { [self] in
                try await self.performLoad(info, from: directory)
            }
            loading = (info.id, task)
            return task
        }
        guard let task else { return }
        defer {
            lock.withLock {
                if loading?.task == task { loading = nil }
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performLoad(_ info: LocalModelInfo, from directory: URL) async throws {
        guard isUsable else { throw LiveBrainError.modelUnavailable("no Metal device") }
        if lock.withLock({ loadedInfo != nil && loadedInfo?.id != info.id }) { await releaseWeights() }
        let entry = LocalModelCatalog.entry(id: info.id) ?? LocalModelCatalog.max
        guard MemoryGuard.canLoad(entry) else {
            Diagnostics.shared.note("local brain: not loaded, \(MemoryGuard.availableBytes.map { "\($0 / 1_000_000) MB" } ?? "?") free")
            throw LiveBrainError.memoryPressure
        }
        MemoryGuard.applyLimits(for: entry)
        Diagnostics.shared.note("local brain: loading \(info.id)")
        let started = Date()
        let loaded: ModelContainer
        do {
            loaded = try await VLMModelFactory.shared.loadContainer(from: directory, using: TokenizerBridge())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            PSLog.error("local model load failed: \(error)", category: .models)
            throw LiveBrainError.modelUnavailable("load: \(String(describing: type(of: error)).prefix(40))")
        }
        try Task.checkCancellation()
        // Qwen3VLProcessor pairs every chat that holds a picture with an all-ones mask, and
        // ChatSession never extends a cached prefix for a masked input: without it, every
        // turn after the opening look would rebuild the cache and re-run the vision tower.
        await loaded.update { $0.processor = UnmaskedProcessor(base: $0.processor) }
        await Self.compileKernels(loaded)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        // An unload that came meanwhile wins: the weights are dropped, not kept.
        let kept: Bool = lock.withLock {
            guard !Task.isCancelled else { return false }
            container = loaded
            loadedInfo = info
            generation += 1
            lastLoadMs = milliseconds
            return true
        }
        guard kept else {
            MemoryGuard.clearCache()
            throw CancellationError()
        }
        MemoryGuard.clearCache()
        Diagnostics.shared.note("local brain: \(info.id) loaded in \(milliseconds) ms")
        PSLog.info("local model \(info.id) loaded in \(milliseconds) ms", category: .models)
    }

    /// One short decode: the first real turn does not pay for compiling the kernels.
    private static func compileKernels(_ container: ModelContainer) async {
        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 2, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        do {
            for try await _ in session.streamResponse(to: "Bonjour") {}
        } catch {
            PSLog.error("local model warm-up failed: \(error)", category: .models)
        }
    }

    func unload() async {
        lock.withLock {
            loading?.task.cancel()
            loading = nil
        }
        await releaseWeights()
    }

    /// Closes every conversation and drops the container, so nothing keeps the weights alive.
    private func releaseWeights() async {
        let (open, planner, wasLoaded): ([MLXChatEngine], MLXPlanner?, Bool) = lock.withLock {
            let open = engines.allObjects
            engines.removeAllObjects()
            let wasLoaded = container != nil
            container = nil
            loadedInfo = nil
            generation += 1
            return (open, self.planner, wasLoaded)
        }
        for engine in open { await engine.close() }
        await planner?.reset()
        MemoryGuard.clearCache()
        if wasLoaded { Diagnostics.shared.note("local brain: unloaded") }
    }

    func isLoaded(_ id: String) async -> Bool {
        lock.withLock { loadedInfo?.id == id && container != nil }
    }

    func makeEngine(_ setup: LocalChatSetup) async throws -> any LocalChatEngine {
        try lock.withLock {
            guard let container, let loadedInfo else { throw LiveBrainError.modelNotReady }
            let engine = MLXChatEngine(container: container, info: loadedInfo, setup: setup)
            engines.add(engine)
            return engine
        }
    }

    func makePlanner() -> (any IntentEngine)? {
        lock.withLock {
            if let planner { return planner }
            let made = MLXPlanner(runtime: self)
            planner = made
            return made
        }
    }

    func benchmark() async throws -> LocalModelSpeed {
        guard let container = loadedContainer() else { throw LiveBrainError.modelNotReady }
        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 64, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        let started = Date()
        var firstTokenMs: Int?
        var completion: GenerateCompletionInfo?
        let prompt = Chat.Message.user("Décris en deux phrases une photo de plage au coucher du soleil.")
        for try await item in session.streamDetails(to: [prompt]) {
            switch item {
            case .chunk:
                if firstTokenMs == nil { firstTokenMs = Int(Date().timeIntervalSince(started) * 1_000) }
            case .info(let info):
                completion = info
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        MemoryGuard.clearCache()
        let speed = completion?.tokensPerSecond ?? 0
        return LocalModelSpeed(tokensPerSecond: speed.isFinite ? speed : 0, firstTokenMs: firstTokenMs ?? 0, loadMs: lock.withLock { lastLoadMs })
    }

    func warmPlanner(mode: EditorMode) {
        let planner = lock.withLock { self.planner }
        planner?.warm(mode: mode)
    }

    /// The app is leaving the foreground: no GPU work may run in the background.
    func stopGenerating() {
        let (open, planner) = lock.withLock { (engines.allObjects, self.planner) }
        for engine in open { engine.stopGenerating() }
        planner?.stopGenerating()
    }

    // MARK: Input

    /// The model's processor without the attention mask it adds for pictures. The mask is
    /// all ones (nothing is padded: one sequence at a time), which is what the model assumes
    /// with none: text-only input already comes without one, Qwen3.5's rope index treats a
    /// missing mask as all ones, and warm continuations are anchored by the carried rope state.
    struct UnmaskedProcessor: UserInputProcessor {
        let base: any UserInputProcessor

        func prepare(input: UserInput) async throws -> LMInput {
            let prepared = try await base.prepare(input: input)
            guard prepared.text.mask != nil else { return prepared }
            return LMInput(text: .init(tokens: prepared.text.tokens), image: prepared.image, video: prepared.video, audio: prepared.audio)
        }
    }

    // MARK: For the planner

    func loadedContainer() -> ModelContainer? {
        lock.withLock { container }
    }

    func loadedContainerAndGeneration() -> (ModelContainer, Int)? {
        lock.withLock { container.map { ($0, generation) } }
    }
}
#endif
