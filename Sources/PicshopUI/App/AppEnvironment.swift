#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
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
    /// Thermal / battery aware render and animation budget.
    public let performance: PerformanceGovernor
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
    /// How the previous session ended, when it ended badly (crash, memory kill), until
    /// dismissed. Offer to share it with `writeCrashReport()`.
    public private(set) var pendingCrashReport: Diagnostics.Report?
    /// Set by EditorHost while an editor is on screen: model installs pause, and
    /// never start or resume while it is true. The Live model keeps downloading.
    @ObservationIgnored public var isEditorOpen = false {
        didSet {
            guard isEditorOpen != oldValue else { return }
            let models = self.models
            let open = isEditorOpen
            let previous = installGate
            // In order: a quick close and reopen must end paused.
            installGate = Task {
                await previous?.value
                if open { await models.pauseAll(except: AppEnvironment.liveModelIDs) } else { await models.resumeAll() }
            }
            // The last editor closed: the local brain's weights go after a minute, unless one opens again.
            if !open { LocalBrainHub.shared.release(reason: "editor_closed") }
            if !open { startAutoInstallIfDue() }
            // SAM and its kept encodings serve no closed editor (D12): they go shortly after the last one closes,
            // unless one opens again first (a reopen then pays no reload).
            samReleaseTask?.cancel()
            samReleaseTask = nil
            if !open {
                samReleaseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled, !self.isEditorOpen else { return }
                    await SAMSegmenter.shared.unload()
                }
            }
        }
    }
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var samReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var installGate: Task<Void, Never>?
    /// The launch delay has passed but an editor was open: installs start when it closes.
    @ObservationIgnored private var autoInstallDue = false
    /// Registered at launch, prewarmed only when an editor appears.
    @ObservationIgnored private var appleEngine: (any IntentEngine)?
    @ObservationIgnored private var lastPrewarm: [EditorMode: Date] = [:]
    /// The mode of the editor opened last, for the local planner's warm-up.
    @ObservationIgnored private var lastEditorMode: EditorMode?
    @ObservationIgnored private var pendingModelStates: [String: ModelManager.State] = [:]
    @ObservationIgnored private var modelStatesFlush: Task<Void, Never>?
    @ObservationIgnored private var lastModelStatesFlush = Date.distantPast

    /// Automatic model installs wait this long after launch, so the first
    /// minutes run cool, at full quality.
    static let autoInstallDelay: TimeInterval = 60
    /// modelStates is written at most this often; terminal states go through at once.
    static let modelStatesInterval: TimeInterval = 0.25
    /// The models that keep downloading while an editor is open: the local brain's, and the two mask models (W2),
    /// which a tool's offer starts from inside the photo editor.
    static let liveModelIDs: Set<String> = Set([LocalModelTiering.maxModelID, LocalModelTiering.fastModelID] + MaskModelCatalog.all.map(\.id))
    /// The pinned mask models (SAM 2.1 tiny, Depth Anything V2 Small): on request only, Wi‑Fi unless allowed.
    static let maskModelIDs: Set<String> = Set(MaskModelCatalog.all.map(\.id))
    /// How long push-to-talk waits for a language model. The local planner answers
    /// in 1–2 s now (no thinking, a reused session), so a stalled model costs less:
    /// 4 s when the grammar has nothing, 1.5 s when it already has a usable plan.
    static let routerConfiguration = HybridIntentRouter.Configuration(llmTimeout: .seconds(4), improveTimeout: .milliseconds(1_500))
    /// With the local planner preferred (no Apple Intelligence): a command the grammar cannot
    /// read waits longer, so a cold first command (its examples prefilled) is not always given up on.
    static let localRouterConfiguration = HybridIntentRouter.Configuration(llmTimeout: .seconds(8), improveTimeout: .milliseconds(1_500))

    public init(extraEngines: [any IntentEngine] = []) {
        let settings = AppSettings()
        self.settings = settings
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let root = documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(rootURL: root)
        library = ProjectLibrary(store: store)
        models = ModelManager.shared
        let performance = PerformanceGovernor()
        performance.preference = settings.performancePreference
        self.performance = performance
        router = HybridIntentRouter(preferredEngine: .appleIntelligence, configuration: Self.routerConfiguration)
        voice = VoiceController(locale: settings.voiceLocale)
        voice.mode = settings.voiceMode
        pendingCrashReport = Diagnostics.shared.pendingReport
        Diagnostics.shared.setReportHandler { [weak self] report in self?.pendingCrashReport = report }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                AppEnvironment.relieveMemoryPressure()
                LocalBrainHub.shared.release(reason: "memory_warning")
                // The mask models too (W2): SAM directly (with or without the broker), then every other idle one.
                await SAMSegmenter.shared.unload()
                await ModelResidency.releaseIdle(reason: "memory_warning")
            }
        }
        // In the background the app is a jetsam candidate: no idle model stays (the LLM has its own observer).
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task {
                await SAMSegmenter.shared.unload()
                await ModelResidency.releaseIdle(reason: "background")
            }
        }
        // The model broker (W2, D12) before anything loads a model: behind its flag, else every load is admitted.
        ModelBroker.installAtLaunch()
        // The Metal orb's library lookup (W2, D19), once and off the main thread, before the first orb draws.
        Task.detached(priority: .utility) { _ = OrbShader.isAvailable }
        // The runtime was registered by the app target just before; the hub reads settings and models from here.
        LocalBrainHub.shared.attach(self)

        Task {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                let engine = FoundationModelsIntentEngine()
                await router.register(engine)
                appleEngine = engine
                appleIntelligenceReason = engine.unavailabilityReason
            }
            #endif
            for engine in extraEngines { await router.register(engine) }
            await refreshEngines()
            await observeModels()
            try? await Task.sleep(for: .seconds(Self.autoInstallDelay))
            autoInstallDue = true
            startAutoInstallIfDue()
        }
    }

    /// Picks push-to-talk's planner: Apple Intelligence when it works on this device (warm,
    /// and quick on a command the grammar cannot read), otherwise the local model's planner
    /// once LocalBrainHub has loaded it (the hub registers it then, and calls this again after
    /// loading and releasing), otherwise the instant grammar. Live's own order is not this one.
    public func refreshEngines() async {
        availableEngines = await router.availableEngines()
        let best: IntentEngineKind = availableEngines.contains(.appleIntelligence)
            ? .appleIntelligence : (availableEngines.contains(.proLocal) ? .proLocal : .rules)
        let changed = best != activeEngine
        activeEngine = best
        await router.setPreferredEngine(best)
        await router.setConfiguration(best == .proLocal ? Self.localRouterConfiguration : Self.routerConfiguration)
        // The local planner's first command would prefill its instructions and examples: done now, off the main actor.
        if best == .proLocal, changed, let mode = lastEditorMode { LocalBrainHub.shared.warmPlanner(mode: mode) }
    }

    // MARK: Models

    private func observeModels() async {
        var initial: [String: ModelManager.State] = [:]
        for model in ModelCatalog.all {
            initial[model.id] = await models.state(of: model.id)
        }
        modelStates = initial
        _ = await models.observe { [weak self] id, state in
            Task { @MainActor in self?.receive(state, for: id) }
        }
    }

    /// Coalesces download progress to `modelStatesInterval`, so Home and Settings
    /// redraw a few times a second rather than once per network chunk. Progress
    /// never runs backwards and never follows a finished install.
    private func receive(_ state: ModelManager.State, for id: String) {
        var state = state
        // The mask models fail with ModelManager's codes, like the language models: shown in words (the offer
        // card's toast, Settings › Avancé).
        if Self.maskModelIDs.contains(id), case .failed(let code) = state { state = .failed(LocalBrainHub.failureText(code)) }
        let last = pendingModelStates[id] ?? modelStates[id]
        if case .downloading(let progress) = state {
            switch last {
            case .installed?, .compiling?: return
            case .downloading(let previous)? where progress < previous: return
            default: break
            }
            pendingModelStates[id] = state
            guard modelStatesFlush == nil else { return }
            let wait = max(0, Self.modelStatesInterval - Date().timeIntervalSince(lastModelStatesFlush))
            modelStatesFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.flushModelStates()
            }
        } else {
            pendingModelStates[id] = state
            flushModelStates()
        }
    }

    private func flushModelStates() {
        modelStatesFlush?.cancel()
        modelStatesFlush = nil
        lastModelStatesFlush = Date()
        guard !pendingModelStates.isEmpty else { return }
        var states = modelStates
        var installed = false
        for (id, state) in pendingModelStates {
            states[id] = state
            if case .installed = state { installed = true }
        }
        pendingModelStates.removeAll()
        if states != modelStates { modelStates = states }
        if installed { Task { await refreshEngines() } }
    }

    /// Whether the runtime needed by a model is linked into this build. Language models go
    /// through LocalBrainHub: only the Live model for this iPhone's tier.
    public func canInstall(_ model: ModelDescriptor) -> Bool {
        switch model.kind {
        case .generative: return generativeEngineProvider != nil
        case .languageModel:
            let hub = LocalBrainHub.shared
            return hub.runtime != nil && model.id == hub.status.model?.id
        case .inpainting, .superResolution: return true
        case .segmentation, .depth:
            // Pinned Core ML packages, compiled on the device: every build can install them. They are never
            // auto-installed (autoInstallModels leaves them out); the user or a tool's offer starts them.
            return model.pinned != nil
        }
    }

    /// Starts a download from Settings or automatically. Returns false when the build
    /// lacks the runtime for that model.
    @discardableResult
    public func install(_ model: ModelDescriptor) -> Bool {
        guard canInstall(model) else { return false }
        settings.setAutoInstallSkipped(false, for: model.id)
        switch model.kind {
        case .languageModel:
            LocalBrainHub.shared.download(allowCellular: false)
        case .segmentation, .depth:
            // Wi‑Fi only, unless Settings › Avancé allows cellular for them.
            let allowsCellular = settings.maskModelsAllowCellular
            Task { await models.install(model, allowsCellular: allowsCellular) }
        case .inpainting, .superResolution, .generative:
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
    /// Of the language models, only the Live model recommended for this iPhone (canInstall).
    public func autoInstallModels() async {
        guard settings.autoInstallsModels else { return }
        guard !isEditorOpen else {
            autoInstallDue = true
            return
        }
        // SAM and Depth (W2) install only on request: the user or a tool's offer starts them.
        let pending = ModelCatalog.all.filter { model in
            model.kind != .segmentation && model.kind != .depth
                && !ModelManager.isBundled(model.id) && canInstall(model) && !settings.isAutoInstallSkipped(model.id)
        }
        var toInstall: [ModelDescriptor] = []
        for model in pending {
            switch await models.state(of: model.id) {
            case .notInstalled, .failed: toInstall.append(model)
            default: continue
            }
        }
        guard !toInstall.isEmpty, performance.allowsHeavyWork, await NetworkPath.isUnmetered() else { return }
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

    // MARK: Diagnostics

    /// Writes the pending report (or, with none, the current breadcrumbs) to a text file to share.
    public func writeCrashReport() -> URL? {
        do {
            return try Diagnostics.shared.writeShareableReport(pendingCrashReport)
        } catch {
            PSLog.error("could not write the diagnostics report: \(error)", category: .ui)
            return nil
        }
    }

    /// The report was shared or waved away: it is not offered again.
    public func dismissCrashReport() {
        Diagnostics.shared.dismissPendingReport()
        pendingCrashReport = nil
    }

    /// App-wide part of a memory warning: the shared Core Image caches. Editors drop
    /// their own renders and thumbnails on the same notification.
    static func relieveMemoryPressure() {
        RenderContext.clearAllCaches()
    }

    private func startAutoInstallIfDue() {
        guard autoInstallDue, !isEditorOpen else { return }
        autoInstallDue = false
        Task { await autoInstallModels() }
    }

    /// Warms the on-device planner for the editor about to open, off the main
    /// thread, and lets the local brain preload its weights when conditions allow.
    /// EditorHost calls it on appear, so launch does not pay for it.
    public func prewarmIntentEngine(mode: EditorMode) {
        let hub = LocalBrainHub.shared
        lastEditorMode = mode
        editorShowedFirstPixels = false
        if let open = editorOpenSignpost { PSSignpost.end(open) }
        editorOpenSignpost = PSSignpost.begin("editor.open", "\(mode)")
        if settings.livePreparesOnOpen { preloadAfterFirstPixels() }
        // The operation catalog and its retrieval index (about 60 ms cold) are read before the
        // router's model deadline: build them now, off the main thread, not on the first command.
        Task.detached(priority: .utility) { OperationAbstention.prewarm() }
        if activeEngine == .proLocal { hub.warmPlanner(mode: mode) }
        #if canImport(FoundationModels)
        // Push-to-talk plans with Apple's model whenever it is available, the local model loaded or not.
        if #available(iOS 26.0, *), let engine = appleEngine as? FoundationModelsIntentEngine {
            let now = Date()
            if let last = lastPrewarm[mode], now.timeIntervalSince(last) < 60 { return }
            lastPrewarm[mode] = now
            Task.detached(priority: .utility) {
                if await engine.isAvailable() { engine.prewarm(context: IntentContext(mode: mode)) }
            }
        }
        #endif
    }

    // MARK: - Model load timing

    /// The editor opening drew its first pixels (photo frame, video item, PDF page).
    @ObservationIgnored private var editorShowedFirstPixels = false
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// From the editor's appearance to its first pixels (Instruments' Points of Interest).
    @ObservationIgnored private var editorOpenSignpost: PSSignpost.Interval?

    /// The local model's weights (2.5–3 GB) never compete with an editor's first
    /// frame: they start loading 500 ms after it, or 2 s after the editor opened
    /// when it never reports one.
    private func preloadAfterFirstPixels() {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            let opened = ContinuousClock.now
            while let self, !self.editorShowedFirstPixels, ContinuousClock.now - opened < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.isEditorOpen else { return }
            PSSignpost.event("llm.preload", "after first pixels")
            LocalBrainHub.shared.preload(reason: "editor")
        }
    }

    /// An editor's first frame is on screen: the model may load now (after a short breath).
    public func noteEditorFirstPixels() {
        guard !editorShowedFirstPixels else { return }
        editorShowedFirstPixels = true
        if let open = editorOpenSignpost {
            PSSignpost.end(open)
            editorOpenSignpost = nil
        }
    }

    public func applyPerformanceSettings() {
        performance.preference = settings.performancePreference
    }

    public func applyVoiceSettings() {
        voice.locale = settings.voiceLocale
        voice.mode = settings.voiceMode
        Task { await refreshEngines() }
    }

    /// Inpainting pipeline for a session, with the neural model when installed.
    public func makeInpaintingPipeline() async -> InpaintingPipeline {
        let pipeline = InpaintingPipeline()
        await attachEngines(to: pipeline)
        return pipeline
    }

    /// Loads the neural eraser and the generative engine and attaches them to
    /// `pipeline`.
    ///
    /// `MLModel(contentsOf:)` is synchronous and takes seconds on device the
    /// first time a model is prepared for the Neural Engine. On the main actor
    /// that freezes the editor before it has drawn a single frame, so the load
    /// runs off the main thread and the pipeline — a reference type — receives
    /// the engines whenever they are ready.
    public func attachEngines(to pipeline: InpaintingPipeline) async {
        if let eraserURL = await models.compiledModelURL(for: "lama-inpainting") {
            // Every LaMa load goes through the broker (D12). This one is speculative, so it asks at `.preload`:
            // refused rather than evicting an idle model, it leaves a deferred eraser whose first erase asks again.
            let result = await Task.detached(priority: .userInitiated) { () async -> Result<CoreMLInpainter?, Error> in
                do { return .success(try await CoreMLInpainter.load(compiledModelURL: eraserURL, priority: .preload)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success(let neural?):
                pipeline.setNeural(neural)
            case .success(nil):
                PSLog.info("neural eraser deferred: model broker refused the preload", category: .models)
                pipeline.setNeural(CoreMLInpainter(deferredCompiledModelURL: eraserURL))
            case .failure(let error):
                PSLog.error("neural eraser failed to load: \(error)", category: .models)
            }
        }
        if let provider = generativeEngineProvider, let resourcesURL = await models.resourcesURL(for: "sd-generative-fill") {
            let engine = await Task.detached(priority: .utility) { provider(resourcesURL) }.value
            pipeline.setGenerative(engine)
        }
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
