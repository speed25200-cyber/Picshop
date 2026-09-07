#if canImport(SwiftUI)
import SwiftUI
import Observation
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopSpeech

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
    /// Engines available on this device (refreshed on launch and after model installs).
    public private(set) var availableEngines: [IntentEngineKind] = [.rules]
    public private(set) var appleIntelligenceReason: String?

    public init(extraEngines: [any IntentEngine] = []) {
        let settings = AppSettings()
        self.settings = settings
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let root = documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(rootURL: root)
        library = ProjectLibrary(store: store)
        models = ModelManager.shared
        router = HybridIntentRouter(preferredEngine: settings.preferredEngine)
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
        }
    }

    public func refreshEngines() async {
        availableEngines = await router.availableEngines()
        let preferred = settings.preferredEngine
        if !availableEngines.contains(preferred) {
            await router.setPreferredEngine(availableEngines.contains(.appleIntelligence) ? .appleIntelligence : .rules)
        } else {
            await router.setPreferredEngine(preferred)
        }
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
        return pipeline
    }

    public func makeUpscaler() async -> Upscaler {
        Upscaler(modelURL: await models.compiledModelURL(for: "realesrgan-x4"))
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
