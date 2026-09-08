#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopSpeech
import Network

/// App-wide services shared by every screen.
@MainActor
@Observable
public final class AppEnvironment {
    public let settings: AppSettings
    public let store: ProjectStore
    public let library: ProjectLibrary
    public let router: HybridIntentRouter
    public let voice: VoiceController
    public let models: ModelManager
    /// Named styles saved by voice ("enregistre ce style sous plage").
    public let styles = StyleLibrary()
    /// Engines available on this device (refreshed on launch and after model installs).
    public private(set) var availableEngines: [IntentEngineKind] = [.rules]
    /// The brain currently answering voice commands: the best one available, chosen automatically.
    public private(set) var activeEngine: IntentEngineKind = .rules
    public private(set) var appleIntelligenceReason: String?
    /// Live state of every catalog model (downloads started automatically or from Settings).
    public private(set) var modelStates: [String: ModelManager.State] = [:]
    /// Provided by the app target when the Stable Diffusion runtime is linked.
    public var generativeEngineProvider: (@Sendable (URL) -> any GenerativeFillEngine)?

    public init(extraEngines: [any IntentEngine] = []) {
        let settings = AppSettings()
        self.settings = settings
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let root = documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(rootURL: root)
        library = ProjectLibrary(store: store)
        models = ModelManager.shared
        router = HybridIntentRouter(preferredEngine: .appleIntelligence)
        voice = VoiceController(locale: settings.voiceLocale)
        voice.mode = settings.voiceMode

        Task {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                let engine = FoundationModelsIntentEngine()
                await router.register(engine)
                appleIntelligenceReason = engine.unavailabilityReason
                if await engine.isAvailable() { engine.prewarm(context: .photo) }
            }
            #endif
            for engine in extraEngines { await router.register(engine) }
            await refreshEngines()
            await observeModels()
            await autoInstallModels()
        }
    }

    /// Picks the most capable brain that works on this device: Pro Brain (MLX) when its
    /// weights are installed, otherwise Apple Intelligence, otherwise the instant grammar.
    public func refreshEngines() async {
        availableEngines = await router.availableEngines()
        let best: IntentEngineKind = availableEngines.contains(.proLocal) ? .proLocal : (availableEngines.contains(.appleIntelligence) ? .appleIntelligence : .rules)
        activeEngine = best
        await router.setPreferredEngine(best)
    }

    // MARK: Models

    private func observeModels() async {
        for model in ModelCatalog.all {
            modelStates[model.id] = await models.state(of: model.id)
        }
        _ = await models.observe { [weak self] id, state in
            Task { @MainActor in
                guard let self else { return }
                self.modelStates[id] = state
                if case .installed = state { await self.refreshEngines() }
            }
        }
    }

    /// Whether the runtime needed by a model is linked into this build.
    public func canInstall(_ model: ModelDescriptor) -> Bool {
        switch model.kind {
        case .generative: return generativeEngineProvider != nil
        case .languageModel: return ProBrainInstaller.shared != nil
        case .inpainting, .superResolution: return true
        }
    }

    /// Starts a download from Settings or automatically. Returns false when the build
    /// lacks the runtime for that model.
    @discardableResult
    public func install(_ model: ModelDescriptor) -> Bool {
        guard canInstall(model) else { return false }
        settings.setAutoInstallSkipped(false, for: model.id)
        if model.kind == .languageModel, let installer = ProBrainInstaller.shared {
            Task { await installer.install(model, app: self) }
        } else {
            Task { await models.install(model) }
        }
        return true
    }

    public func delete(_ model: ModelDescriptor) async {
        settings.setAutoInstallSkipped(true, for: model.id)
        try? await models.delete(model.id)
        await refreshEngines()
    }

    /// Every model ships "installed by default": the ones that are not bundled with the
    /// app download by themselves over Wi‑Fi, with progress shown on the Home screen.
    public func autoInstallModels() async {
        guard settings.autoInstallsModels else { return }
        let pending = ModelCatalog.all.filter { model in
            !ModelManager.isBundled(model.id) && canInstall(model) && !settings.isAutoInstallSkipped(model.id)
        }
        var toInstall: [ModelDescriptor] = []
        for model in pending {
            switch await models.state(of: model.id) {
            case .notInstalled, .failed: toInstall.append(model)
            default: continue
            }
        }
        guard !toInstall.isEmpty, await NetworkPath.isUnmetered() else { return }
        for model in toInstall { install(model) }
    }

    /// Progress of the automatic installs, 0…1, or nil when nothing is downloading.
    public var modelInstallProgress: Double? {
        let active = modelStates.values.compactMap { state -> Double? in
            switch state {
            case .downloading(let progress): return progress
            case .compiling: return 1
            default: return nil
            }
        }
        guard !active.isEmpty else { return nil }
        return active.reduce(0, +) / Double(active.count)
    }

    public func applyVoiceSettings() {
        voice.locale = settings.voiceLocale
        voice.mode = settings.voiceMode
        Task { await refreshEngines() }
    }

    /// Inpainting pipeline for a session, with the neural model when installed.
    public func makeInpaintingPipeline() async -> InpaintingPipeline {
        let pipeline = InpaintingPipeline()
        if let url = await models.compiledModelURL(for: "lama-inpainting"), let neural = try? CoreMLInpainter(compiledModelURL: url) {
            pipeline.setNeural(neural)
        }
        if let provider = generativeEngineProvider, let resources = await models.resourcesURL(for: "sd-generative-fill") {
            pipeline.setGenerative(provider(resources))
        }
        return pipeline
    }

    public func makeUpscaler() async -> Upscaler {
        Upscaler(modelURL: await models.compiledModelURL(for: "realesrgan-x4"))
    }
}

/// One-shot network check used before starting multi-gigabyte downloads.
enum NetworkPath {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    static func isUnmetered() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "picshop.network"))
        }
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppEnvironment? { nil }
}

public extension EnvironmentValues {
    var picshop: AppEnvironment? {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
#endif
