// "Pro Brain": a larger on-device language model (Qwen3 4B, 4-bit) served by MLX.
//
// This file only compiles when the mlx-swift-examples package is linked (see
// project.yml). Remove the package to ship with Apple Intelligence + grammar only.
#if canImport(MLXLLM) && canImport(MLXLMCommon)
import Foundation
import MLXLLM
import MLXLMCommon
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Planner backed by an MLX language model running on the GPU.
public final class MLXIntentEngine: IntentEngine, @unchecked Sendable {
    public static let shared = MLXIntentEngine()
    public let kind: IntentEngineKind = .proLocal

    private let lock = NSLock()
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private let modelID = "qwen3-4b-4bit"

    private init() {}

    public func isAvailable() async -> Bool {
        await ModelManager.shared.isInstalled(modelID)
    }

    /// Downloads the weights through the MLX hub client and marks the model installed.
    public func install(_ descriptor: ModelDescriptor, models: ModelManager) async {
        guard let hub = descriptor.huggingFaceID else { return }
        do {
            let configuration = ModelConfiguration(id: hub)
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { progress in
                Task { await models.setDownloadProgress(descriptor.id, progress.fractionCompleted) }
            }
            lock.withLock { container = loaded }
            try await models.markInstalled(descriptor.id)
        } catch {
            PSLog.error("Pro Brain install failed: \(error)", category: .models)
            await models.setFailure(descriptor.id, error.localizedDescription)
        }
    }

    private func loadedContainer() async throws -> ModelContainer {
        let hub = ModelCatalog.descriptor(id: modelID)?.huggingFaceID ?? "mlx-community/Qwen3-4B-4bit"
        enum State { case ready(ModelContainer), loading(Task<ModelContainer, Error>) }
        let state: State = lock.withLock {
            if let container { return .ready(container) }
            if let loading { return .loading(loading) }
            let task = Task<ModelContainer, Error> {
                try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(id: hub)) { _ in }
            }
            loading = task
            return .loading(task)
        }
        switch state {
        case .ready(let container):
            return container
        case .loading(let task):
            let result = try await task.value
            lock.withLock {
                container = result
                loading = nil
            }
            return result
        }
    }

    public func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
        let container = try await loadedContainer()
        let instructions = IntentPrompt.systemInstructions(mode: context.mode) + "\n\nExamples:\n"
            + IntentPrompt.fewShotExamples.map { "Request: \"\($0.0)\" → \($0.1)" }.joined(separator: "\n")
        let prompt = IntentPrompt.userPrompt(for: utterance, context: context, hint: hint) + "\nJSON:"
        let session = ChatSession(container, instructions: instructions, generateParameters: GenerateParameters(maxTokens: 400, temperature: 0.1))
        let text = try await session.respond(to: prompt)
        guard let raw = LLMResponseParser.parse(text) else {
            throw PicshopError.renderFailed("Pro Brain returned no plan")
        }
        return IntentNormalizer.plan(from: raw, utterance: utterance, context: context, engine: .proLocal)
    }
}
#endif
