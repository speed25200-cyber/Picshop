#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import UIKit
import PicshopCore
import PicshopIntent
import PicshopImaging
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the app target plugs in to run a local model: MLX in App/LocalBrain,
/// registered in PicshopApp.init. PicshopKit never links MLX; a build without a
/// runtime simply has no model brain.
public protocol LocalModelRuntime: AnyObject, Sendable {
    /// False on the simulator, or with no usable Metal device.
    var isUsable: Bool { get }
    func load(_ info: LocalModelInfo, from directory: URL) async throws
    func unload() async
    func isLoaded(_ id: String) async -> Bool
    /// A fresh conversation over the loaded weights. Requires a loaded model.
    func makeEngine(_ setup: LocalChatSetup) async throws -> any LocalChatEngine
    /// Push-to-talk's planner over the same weights (`IntentEngineKind.proLocal`).
    func makePlanner() -> (any IntentEngine)?
    func benchmark() async throws -> LocalModelSpeed
    /// Additive (phase 1): stops every generation in flight, keeping the weights
    /// and the conversations: the app is leaving the foreground (no GPU work in the background).
    func stopGenerating()
    /// Additive (phase 1): prefills the planner's session for `mode` (its instructions and
    /// examples) off the main actor, so push-to-talk's first command is not a cold one.
    /// Only used when the local planner is push-to-talk's preferred engine.
    func warmPlanner(mode: EditorMode)
}

extension LocalModelRuntime {
    public func stopGenerating() {}
    public func warmPlanner(mode: EditorMode) {}
}

public struct LocalModelSpeed: Sendable, Equatable, Codable {
    public var tokensPerSecond: Double
    public var firstTokenMs: Int
    public var loadMs: Int

    public init(tokensPerSecond: Double, firstTokenMs: Int, loadMs: Int) {
        self.tokensPerSecond = tokensPerSecond
        self.firstTokenMs = firstTokenMs
        self.loadMs = loadMs
    }
}

/// Where the local brain stands, for Settings › Intelligence, the Live dock and Diagnostic Live.
public struct LocalBrainStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case notInThisBuild, unsupported, notInstalled, waitingForWiFi, downloading(progress: Double), verifying, installed, loading, ready, failed(String)
    }

    public var phase: Phase
    public var decision: LocalTierDecision
    /// The model for this tier, even when it is not installed.
    public var model: LocalModelInfo?
    public var downloadBytes: Int64
    public var bytesOnDisk: Int64
    public var speed: LocalModelSpeed?

    public init(phase: Phase, decision: LocalTierDecision, model: LocalModelInfo? = nil, downloadBytes: Int64 = 0, bytesOnDisk: Int64 = 0,
                speed: LocalModelSpeed? = nil) {
        self.phase = phase
        self.decision = decision
        self.model = model
        self.downloadBytes = downloadBytes
        self.bytesOnDisk = bytesOnDisk
        self.speed = speed
    }

    static let notInThisBuild = LocalBrainStatus(phase: .notInThisBuild, decision: LocalTierDecision(tier: .unsupported, reason: .notInThisBuild))
}

/// The brains one Live session can use, best first. `local` is always there.
public struct LiveBrainSet {
    public var model: (any LiveBrain)?
    public var onDevice: (any LiveBrain)?
    /// The rules-only grammar: never waits on a language model.
    public var local: any LiveBrain

    public init(model: (any LiveBrain)?, onDevice: (any LiveBrain)?, local: any LiveBrain) {
        self.model = model
        self.onDevice = onDevice
        self.local = local
    }
}

/// The brain step of the Live self-test.
public struct LocalBrainProbe: Sendable, Equatable {
    public var passed: Bool
    /// "Qwen3.5 4B · 24 tok/s · 1re réponse 640 ms · outil OK"
    public var summary: String
    /// deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady or available.
    public var appleIntelligence: String

    public init(passed: Bool, summary: String, appleIntelligence: String) {
        self.passed = passed
        self.summary = summary
        self.appleIntelligence = appleIntelligence
    }
}

/// The one place the local model lives: which model this iPhone gets (tier),
/// its download (Wi‑Fi first, never paused by an editor), its loading and
/// release (memory, heat, background), and the brains Live gets. The app target
/// registers the runtime; Live sessions only ask for brains, which never waits
/// on the weights.
///
/// Only leaf views read `status` (download progress changes often).
@MainActor
@Observable
public final class LocalBrainHub {
    public static let shared = LocalBrainHub()

    /// Set once in PicshopApp.init, before AppEnvironment.
    @ObservationIgnored public var runtime: (any LocalModelRuntime)? {
        didSet { refreshStatus() }
    }

    public private(set) var status: LocalBrainStatus = .notInThisBuild

    /// The model is loaded and a Live turn can use it.
    public var isModelReady: Bool { status.phase == .ready }

    // MARK: State

    private enum Load: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String, reason: String)
    }

    @ObservationIgnored private weak var app: AppEnvironment?
    /// Install state of each Live model, from ModelManager.
    @ObservationIgnored private var installs: [String: ModelManager.State] = [:]
    @ObservationIgnored private var diskBytes: [String: Int64] = [:]
    @ObservationIgnored private var load: Load = .idle
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoadFailure: Date?
    @ObservationIgnored private var releaseTimer: Task<Void, Never>?
    @ObservationIgnored private var waitForWiFi: Task<Void, Never>?
    @ObservationIgnored private var isWaitingForWiFi = false
    /// The download the user asked for, retried when the network comes back.
    @ObservationIgnored private var requestedDownload: (id: String, allowCellular: Bool, retries: Int)?
    @ObservationIgnored private var plannerRegistered = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var modelObserver: UUID?
    /// Free memory when the app started, for the tier (the live figure gates each load).
    @ObservationIgnored private var launchAvailableMemory: UInt64?
    @ObservationIgnored private var liveBrains: [WeakModelBrain] = []

    private struct WeakModelBrain {
        weak var brain: LocalModelLiveBrain?
    }

    /// An editor closed: the weights stay this long in case another opens.
    static let releaseDelay: Double = 60
    /// After a failed load, the next preload waits this long.
    static let loadRetryDelay: Double = 30

    private enum Keys {
        static let loadedModel = "localBrain.loadedModel.v1"
        static let killedWithModel = "localBrain.killedWithModel.v1"
        static let speeds = "localBrain.speeds.v1"
    }

    init() {}

    // MARK: Attach

    /// Called from AppEnvironment.init: settings and model states come from there.
    public func attach(_ app: AppEnvironment) {
        guard self.app == nil else { return }
        self.app = app
        launchAvailableMemory = MemoryBudget.availableBytes.map { UInt64($0) }
        noteMemoryKill()
        observeLifecycle()
        refreshStatus()
        let models = app.models
        Task { [weak self] in
            var states: [String: ModelManager.State] = [:]
            var bytes: [String: Int64] = [:]
            for entry in LocalModelCatalog.all {
                states[entry.info.id] = await models.state(of: entry.info.id)
                bytes[entry.info.id] = await models.bytesOnDisk(entry.info.id)
            }
            let token = await models.observe { id, state in
                guard LocalModelCatalog.entry(id: id) != nil else { return }
                Task { @MainActor in LocalBrainHub.shared.receive(state, for: id) }
            }
            guard let self else { return }
            self.modelObserver = token
            self.installs.merge(states) { current, _ in current }
            self.diskBytes = bytes
            self.refreshStatus()
        }
    }

    /// The last session ended in the foreground while the model was loaded: most
    /// likely a memory kill. The tier drops one step from now on (until the user
    /// picks a quality in Settings).
    private func noteMemoryKill() {
        let defaults = UserDefaults.standard
        if let model = defaults.string(forKey: Keys.loadedModel), Diagnostics.shared.pendingReport?.kind == .uncleanExit {
            defaults.set(true, forKey: Keys.killedWithModel)
            Diagnostics.shared.note("local brain: the last session ended with \(model) loaded; one tier down")
            PSLog.error("local brain: unclean exit with \(model) loaded, dropping a tier", category: .models)
        }
        defaults.removeObject(forKey: Keys.loadedModel)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LocalBrainHub.shared.release(reason: "background") }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LocalBrainHub.shared.runtime?.stopGenerating() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LocalBrainHub.shared.returnedToForeground() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LocalBrainHub.shared.thermalChanged() }
        })
        observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in LocalBrainHub.shared.refreshStatus() }
        })
    }

    // MARK: Download

    /// Starts or resumes the model for this iPhone's tier. Without `allowCellular`
    /// it waits for Wi‑Fi (`.waitingForWiFi`) and never uses cellular data.
    public func download(allowCellular: Bool) {
        guard let app, runtime != nil, let entry = activeEntry() else { return }
        switch status.phase {
        case .notInstalled, .failed, .waitingForWiFi: break
        default: return
        }
        let id = entry.info.id
        guard let descriptor = ModelCatalog.descriptor(id: id) else { return }
        app.settings.setAutoInstallSkipped(false, for: id)
        if requestedDownload?.id != id || requestedDownload?.allowCellular != allowCellular {
            requestedDownload = (id, allowCellular, 0)
        }
        waitForWiFi?.cancel()
        let models = app.models
        waitForWiFi = Task { [weak self] in
            if !allowCellular {
                while !(await NetworkPath.isUnmetered()) {
                    self?.setWaitingForWiFi(true)
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { return }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.setWaitingForWiFi(false)
            PSLog.info("local brain: downloading \(id) (\(allowCellular ? "cellular allowed" : "Wi-Fi"))", category: .models)
            await models.install(descriptor, allowsCellular: allowCellular)
        }
    }

    public func cancelDownload() {
        waitForWiFi?.cancel()
        waitForWiFi = nil
        setWaitingForWiFi(false)
        guard let app else { return }
        let ids = requestedDownload.map { [$0.id] } ?? LocalModelCatalog.all.map(\.info.id)
        requestedDownload = nil
        let models = app.models
        for id in ids {
            // Not fetched again by itself; the download button still works.
            app.settings.setAutoInstallSkipped(true, for: id)
            Task { await models.cancelInstall(id) }
        }
        refreshStatus()
    }

    /// Removes the Live model's weights (both sizes), after unloading them.
    public func delete() async {
        cancelDownload()
        await unloadNow(reason: "deleted")
        guard let app else { return }
        for entry in LocalModelCatalog.all {
            app.settings.setAutoInstallSkipped(true, for: entry.info.id)
            try? await app.models.delete(entry.info.id)
            installs[entry.info.id] = .notInstalled
            diskBytes[entry.info.id] = 0
        }
        refreshStatus()
        await app.refreshEngines()
    }

    /// Settings › Intelligence › Qualité. An explicit choice also forgets a past
    /// memory kill (the choice wins within the memory limits).
    public func setQuality(_ quality: LocalModelQuality) async {
        guard let app else { return }
        let before = activeEntry()?.info.id
        app.settings.localModelQuality = quality
        UserDefaults.standard.removeObject(forKey: Keys.killedWithModel)
        refreshStatus()
        let after = activeEntry()?.info.id
        if before != after, case .ready(let loaded) = load, loaded != after {
            await unloadNow(reason: "quality")
            if app.isEditorOpen { preload(reason: "quality") }
        }
    }

    private func setWaitingForWiFi(_ waiting: Bool) {
        guard isWaitingForWiFi != waiting else { return }
        isWaitingForWiFi = waiting
        refreshStatus()
    }

    /// A state change from ModelManager for one of the Live models.
    private func receive(_ state: ModelManager.State, for id: String) {
        let previous = installs[id]
        installs[id] = state
        switch state {
        case .installed:
            requestedDownload = nil
            if previous != .installed {
                refreshDiskBytes()
                // The editor may already be open: load it now.
                if let app, app.isEditorOpen, app.settings.livePreparesOnOpen { preload(reason: "installed") }
            }
        case .failed(let code) where code == ModelManager.FailureCode.network:
            retryAfterNetworkLoss(id)
        case .notInstalled:
            if previous == .installed { refreshDiskBytes() }
        default:
            break
        }
        refreshStatus()
    }

    /// Wi‑Fi dropped mid-download: wait for it and go on from what was downloaded.
    private func retryAfterNetworkLoss(_ id: String) {
        guard var request = requestedDownload, request.id == id, request.retries < 5 else { return }
        request.retries += 1
        requestedDownload = request
        let allowCellular = request.allowCellular
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.requestedDownload?.id == id else { return }
            self.download(allowCellular: allowCellular)
        }
    }

    private func refreshDiskBytes() {
        guard let models = app?.models else { return }
        Task { [weak self] in
            var bytes: [String: Int64] = [:]
            for entry in LocalModelCatalog.all { bytes[entry.info.id] = await models.bytesOnDisk(entry.info.id) }
            self?.diskBytes = bytes
            self?.refreshStatus()
        }
    }

    // MARK: Loading and release (D13)

    /// Warms the local planner for `mode` once the weights are loaded (see `LocalModelRuntime.warmPlanner`).
    public func warmPlanner(mode: EditorMode) {
        guard isModelReady else { return }
        runtime?.warmPlanner(mode: mode)
    }

    /// Editor opened ("editor", only with "Préparer Live à l'ouverture") or Live
    /// started ("live"): loads the weights off the main actor when memory,
    /// thermal state and power allow it (D13).
    public func preload(reason: String) {
        releaseTimer?.cancel()
        releaseTimer = nil
        guard let runtime, runtime.isUsable, let entry = activeEntry(), installs[entry.info.id] == .installed else { return }
        let id = entry.info.id
        switch load {
        case .loading(let loading) where loading == id: return
        case .ready(let loaded) where loaded == id: return
        default: break
        }
        guard UIApplication.shared.applicationState != .background else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .critical, !(thermal == .serious && reason == "editor") else { return }
        if reason == "editor", ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        if let failed = lastLoadFailure, Date().timeIntervalSince(failed) < Self.loadRetryDelay, reason != "live", reason != "selftest" { return }
        if let available = MemoryBudget.availableBytes, UInt64(available) < entry.memoryNeededToLoad {
            PSLog.info("local brain: not loading \(id) (\(available / 1_000_000) MB free)", category: .models)
            lastLoadFailure = Date()
            return
        }
        guard let models = app?.models else { return }
        loadTask?.cancel()
        load = .loading(id)
        refreshStatus()
        PSLog.info("local brain: loading \(id) (\(reason))", category: .models)
        loadTask = Task { [weak self] in
            do {
                guard let directory = await models.languageModelDirectory(for: id) else {
                    throw LiveBrainError.modelUnavailable("files missing")
                }
                // Never on the main actor: the weights are gigabytes.
                try await Task.detached(priority: .userInitiated) {
                    try await runtime.load(entry.info, from: directory)
                }.value
                try Task.checkCancellation()
                await self?.loaded(id)
            } catch is CancellationError {
                return
            } catch {
                self?.loadFailed(id, error)
            }
        }
    }

    private func loaded(_ id: String) async {
        guard case .loading(let loading) = load, loading == id else { return }
        load = .ready(id)
        lastLoadFailure = nil
        UserDefaults.standard.set(id, forKey: Keys.loadedModel)
        refreshStatus()
        pushThermalState()
        guard let app else { return }
        if !plannerRegistered, let planner = runtime?.makePlanner() {
            plannerRegistered = true
            await app.router.register(planner)
        }
        await app.refreshEngines()
    }

    private func loadFailed(_ id: String, _ error: Error) {
        guard case .loading(let loading) = load, loading == id else { return }
        lastLoadFailure = Date()
        if let brainError = error as? LiveBrainError, brainError == .memoryPressure {
            // Not a fault: too little memory right now. The next preload tries again.
            load = .idle
        } else {
            load = .failed(id, reason: String(describing: error).prefix(80).description)
        }
        PSLog.error("local brain: load of \(id) failed: \(error)", category: .models)
        refreshStatus()
    }

    /// Memory warning, background, Stable Diffusion, heat, or the editor closed
    /// ("editor_closed": after 60 s, cancelled if an editor opens again).
    public func release(reason: String) {
        if reason == "editor_closed" {
            releaseTimer?.cancel()
            releaseTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.releaseDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.app?.isEditorOpen == true { return }
                await self.unloadNow(reason: reason)
            }
            return
        }
        Task { await unloadNow(reason: reason) }
    }

    /// Additive (phase 1): release(reason:) that returns once the weights are gone,
    /// for work that needs the memory right away (a Stable Diffusion fill).
    public func releaseNow(reason: String) async {
        await unloadNow(reason: reason)
    }

    private func unloadNow(reason: String) async {
        releaseTimer?.cancel()
        releaseTimer = nil
        loadTask?.cancel()
        loadTask = nil
        let wasActive = load != .idle
        if case .failed = load {} else { load = .idle }
        UserDefaults.standard.removeObject(forKey: Keys.loadedModel)
        refreshStatus()
        guard wasActive, let runtime else { return }
        PSLog.info("local brain: releasing (\(reason))", category: .models)
        await runtime.unload()
        await app?.refreshEngines()
    }

    private func returnedToForeground() {
        guard let app, app.isEditorOpen, app.settings.livePreparesOnOpen else { return }
        preload(reason: "foreground")
    }

    private func thermalChanged() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            release(reason: "thermal_critical")
        } else if let app, app.isEditorOpen, app.settings.livePreparesOnOpen, load == .idle {
            preload(reason: "cooled")
        }
        pushThermalState()
        refreshStatus()
    }

    /// Serious heat: the model brains answer shorter and skip ideas at session start.
    private func pushThermalState() {
        let serious = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        liveBrains.removeAll { $0.brain == nil }
        for brain in liveBrains.compactMap(\.brain) {
            Task { await brain.setThermalSerious(serious) }
        }
    }

    // MARK: Speed test and probe

    public func runSpeedTest() async -> LocalModelSpeed? {
        guard let runtime, let entry = activeEntry(), await waitUntilReady(reason: "speedtest", seconds: 25) else { return nil }
        do {
            let speed = try await runtime.benchmark()
            store(speed, for: entry.info.id)
            PSLog.info("local brain: \(entry.info.id) \(String(format: "%.1f", speed.tokensPerSecond)) tok/s, first token \(speed.firstTokenMs) ms", category: .models)
            refreshStatus()
            return speed
        } catch {
            PSLog.error("local brain: speed test failed: \(error)", category: .models)
            return nil
        }
    }

    /// The self-test's brain step: the model loads, answers "rends-la plus
    /// chaude" with a valid apply_edits call, and how fast. At most 11 s.
    public func probe() async -> LocalBrainProbe {
        let apple = Self.appleIntelligenceAvailability()
        guard let runtime else { return LocalBrainProbe(passed: false, summary: "Pas de cerveau local dans ce build", appleIntelligence: apple) }
        guard let entry = activeEntry() else {
            return LocalBrainProbe(passed: false, summary: "Pas de cerveau local sur cet iPhone (\(status.decision.reason.rawValue))", appleIntelligence: apple)
        }
        switch status.phase {
        case .notInThisBuild, .unsupported:
            return LocalBrainProbe(passed: false, summary: "Pas de cerveau local sur cet iPhone (\(status.decision.reason.rawValue))", appleIntelligence: apple)
        case .notInstalled, .waitingForWiFi, .failed:
            return LocalBrainProbe(passed: false, summary: "\(entry.info.displayName) pas installé", appleIntelligence: apple)
        case .downloading(let progress):
            return LocalBrainProbe(passed: false, summary: "\(entry.info.displayName) en téléchargement (\(Int(progress * 100)) %)", appleIntelligence: apple)
        case .verifying:
            return LocalBrainProbe(passed: false, summary: "\(entry.info.displayName) en vérification", appleIntelligence: apple)
        case .installed, .loading, .ready:
            break
        }
        let started = Date()
        guard await waitUntilReady(reason: "selftest", seconds: 8) else {
            return LocalBrainProbe(passed: false, summary: "\(entry.info.displayName) · chargement impossible", appleIntelligence: apple)
        }
        let remaining = max(1, 11 - Date().timeIntervalSince(started))
        let result = await Self.toolProbe(runtime: runtime, info: entry.info, seconds: remaining)
        var parts = [entry.info.displayName]
        if let speed = result.tokensPerSecond, speed > 0 { parts.append("\(Int(speed.rounded())) tok/s") }
        if let first = result.firstTokenMs { parts.append("1re réponse \(first) ms") }
        parts.append(result.toolOK ? "outil OK" : (result.timedOut ? "trop lent" : "outil ✗"))
        return LocalBrainProbe(passed: result.toolOK, summary: parts.joined(separator: " · "), appleIntelligence: apple)
    }

    private struct ToolProbeResult: Sendable {
        var toolOK = false
        var timedOut = false
        var firstTokenMs: Int?
        var tokensPerSecond: Double?
    }

    /// One real Live-shaped request, off the main actor, with a deadline.
    private nonisolated static func toolProbe(runtime: any LocalModelRuntime, info: LocalModelInfo, seconds: Double) async -> ToolProbeResult {
        let work = Task.detached(priority: .userInitiated) { () -> ToolProbeResult in
            var result = ToolProbeResult()
            // With the time for it, the Live history too: the probe then reads what a turn reads.
            let history = seconds >= 6 ? LocalModelLiveBrain.exampleHistory(mode: .photo, size: info.promptSize) : []
            let setup = LocalChatSetup(system: LocalLivePrompt.system(mode: .photo, size: info.promptSize), tools: LocalLivePrompt.toolSpecs(mode: .photo),
                                       history: history, imageMaxPixels: LocalModelCatalog.imageMaxPixels)
            guard let engine = try? await runtime.makeEngine(setup) else { return result }
            defer { Task { await engine.close() } }
            var state = LiveEditorState(mode: .photo, version: 1)
            state.canvasPixels = PSSize(width: 4032, height: 3024)
            let turn = LiveUserTurn(id: 0, kind: .speech, text: "rends-la plus chaude", language: .french, image: nil, editorState: state)
            var options = LocalGenerationOptions()
            options.maxTokens = 120
            let started = Date()
            var filter = LocalOutputFilter()
            var calls: [(String, JSONValue)] = []
            do {
                try await engine.prepare()
                for try await event in engine.send([.user(LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false), imageJPEG: nil)], options: options) {
                    if result.firstTokenMs == nil {
                        switch event {
                        case .finished: break
                        default: result.firstTokenMs = Int(Date().timeIntervalSince(started) * 1_000)
                        }
                    }
                    switch event {
                    case .text(let delta):
                        for case .toolCall(let name, let arguments) in filter.feed(delta) { calls.append((name, arguments)) }
                    case .toolCall(let call):
                        calls.append((call.name, call.arguments))
                    case .rejectedToolCall(let raw):
                        var reader = LocalOutputFilter()
                        for case .toolCall(let name, let arguments) in reader.feed(raw) + reader.finish() { calls.append((name, arguments)) }
                    case .finished(let stats, _):
                        result.tokensPerSecond = stats.tokensPerSecond
                    }
                }
                for case .toolCall(let name, let arguments) in filter.finish() { calls.append((name, arguments)) }
            } catch {
                return result
            }
            let validator = ToolInputValidator(mode: .photo)
            result.toolOK = calls.contains { call in
                guard call.0 == LiveToolName.applyEdits.rawValue else { return false }
                let use = ToolArgumentCoercer.rawToolUse(id: "probe", name: call.0, arguments: call.1)
                if case .success = validator.validate(use, context: IntentContext(mode: .photo)) { return true }
                return false
            }
            return result
        }
        let deadline = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            work.cancel()
        }
        var result = await work.value
        deadline.cancel()
        if !result.toolOK, work.isCancelled || result.firstTokenMs == nil { result.timedOut = true }
        return result
    }

    /// Loads the model if needed and waits for it, up to `seconds`.
    private func waitUntilReady(reason: String, seconds: Double) async -> Bool {
        if isModelReady { return true }
        preload(reason: reason)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isModelReady { return true }
            if case .loading = load {} else { return isModelReady }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return isModelReady
    }

    // MARK: Brains

    /// Diagnostic Live's understanding eval: the model brain, its weights loaded first (up to 25 s); nil when
    /// this iPhone has no model installed or it cannot load now.
    public func evalBrain(mode: EditorMode) async -> (any LiveBrain)? {
        guard await waitUntilReady(reason: "selftest", seconds: 25) else { return nil }
        return makeLiveBrains(mode: mode).model
    }

    /// Returns at once and never loads weights. A model brain whenever the model
    /// for this iPhone is installed and the runtime can run it: each turn still
    /// goes to it only while `isModelReady` (the session checks), so a model that
    /// finishes loading mid-conversation is used from the next turn on.
    public func makeLiveBrains(mode: EditorMode) -> LiveBrainSet {
        let local = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: mode)
        #if canImport(FoundationModels)
        let onDevice: (any LiveBrain)? = FoundationModelsLiveBrain(mode: mode)
        #else
        let onDevice: (any LiveBrain)? = nil
        #endif
        var model: (any LiveBrain)?
        if let runtime, runtime.isUsable, let entry = activeEntry(), installs[entry.info.id] == .installed {
            let brain = LocalModelLiveBrain(mode: mode, info: entry.info, makeEngine: { [runtime] setup in
                try await runtime.makeEngine(setup)
            }, fallback: local, log: LiveServices.shared.logSink)
            liveBrains.removeAll { $0.brain == nil }
            liveBrains.append(WeakModelBrain(brain: brain))
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Task { await brain.setThermalSerious(true) }
            }
            model = brain
        }
        return LiveBrainSet(model: model, onDevice: onDevice, local: local)
    }

    // MARK: Status

    /// The Live model this iPhone uses, loads and offers: the tier's model when it is installed;
    /// otherwise the model chosen without passing states (`downloadDecision`), installed or not.
    /// Low Power Mode or little memory free at launch never cost the installed model (a Max
    /// iPhone keeps its 4B, each load still checks memory) and never start a 2B download.
    private func activeEntry() -> LocalModelEntry? {
        let preferred = LocalModelCatalog.entry(for: currentDecision().tier)
        if let preferred, installs[preferred.info.id] == .installed { return preferred }
        return LocalModelCatalog.entry(for: downloadDecision().tier) ?? preferred
    }

    /// What to install: the tier with Low Power Mode off and the whole memory free, so a
    /// passing state never decides a download. A memory kill, a slow measured speed and the
    /// user's quality choice still count; each load is still gated by the memory it needs.
    private func downloadDecision() -> LocalTierDecision {
        #if targetEnvironment(simulator)
        return currentDecision()
        #else
        guard let runtime, runtime.isUsable else { return currentDecision() }
        var facts = currentFacts()
        facts.lowPowerMode = false
        facts.availableMemory = facts.physicalMemory
        return LocalModelTiering.decide(facts, quality: app?.settings.localModelQuality ?? .auto)
        #endif
    }

    private func currentDecision() -> LocalTierDecision {
        #if targetEnvironment(simulator)
        return LocalTierDecision(tier: .unsupported, reason: .simulator)
        #else
        guard let runtime else { return LocalTierDecision(tier: .unsupported, reason: .notInThisBuild) }
        guard runtime.isUsable else { return LocalTierDecision(tier: .unsupported, reason: .simulator) }
        return LocalModelTiering.decide(currentFacts(), quality: app?.settings.localModelQuality ?? .auto)
        #endif
    }

    private func currentFacts() -> LocalDeviceFacts {
        let process = ProcessInfo.processInfo
        let available = launchAvailableMemory ?? MemoryBudget.availableBytes.map { UInt64($0) } ?? process.physicalMemory / 2
        return LocalDeviceFacts(machine: Self.machine, physicalMemory: process.physicalMemory, availableMemory: available,
                                lowPowerMode: process.isLowPowerModeEnabled,
                                thermalSerious: process.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                                lastSessionMemoryKilledWithModel: UserDefaults.standard.bool(forKey: Keys.killedWithModel),
                                measuredTokensPerSecond: speeds()[LocalModelCatalog.max.info.id]?.tokensPerSecond)
    }

    /// Recomputes `status` from the runtime, the tier, the install and the load.
    func refreshStatus() {
        guard runtime != nil else {
            setStatus(.notInThisBuild)
            return
        }
        let decision = currentDecision()
        guard let entry = activeEntry() else {
            setStatus(LocalBrainStatus(phase: .unsupported, decision: decision))
            return
        }
        let id = entry.info.id
        let phase: LocalBrainStatus.Phase
        switch installs[id] {
        case .downloading(let progress)?:
            phase = .downloading(progress: progress)
        case .compiling?:
            phase = .verifying
        case .failed(let code)?:
            phase = isWaitingForWiFi ? .waitingForWiFi : .failed(Self.failureText(code))
        case .installed?:
            switch load {
            case .loading(let loading) where loading == id: phase = .loading
            case .ready(let loaded) where loaded == id: phase = .ready
            case .failed(let failed, _) where failed == id: phase = .failed(L("The model could not load. Close other apps, then try again."))
            default: phase = .installed
            }
        case .notInstalled?, nil:
            phase = isWaitingForWiFi ? .waitingForWiFi : .notInstalled
        }
        let onDisk = LocalModelCatalog.all.reduce(Int64(0)) { $0 + (diskBytes[$1.info.id] ?? 0) }
        setStatus(LocalBrainStatus(phase: phase, decision: decision, model: entry.info, downloadBytes: entry.downloadBytes, bytesOnDisk: onDisk,
                                   speed: speeds()[id]))
    }

    /// Assigned only on a change, so observers redraw only then.
    private func setStatus(_ new: LocalBrainStatus) {
        if status != new { status = new }
    }

    /// ModelManager's failure codes in words.
    static func failureText(_ code: String) -> String {
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case ModelManager.FailureCode.storage?:
            let needed = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
            let size = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return String(format: L("Not enough storage: %@ must be free."), size)
        case ModelManager.FailureCode.network?:
            return L("The download stopped with the connection. It picks up where it left off.")
        case ModelManager.FailureCode.verify?:
            return L("A downloaded file was damaged. Try again.")
        case ModelManager.FailureCode.server?:
            return L("The download server is not answering. Try again later.")
        case ModelManager.FailureCode.files?:
            return L("This model is incomplete on the server.")
        default:
            return code
        }
    }

    // MARK: Speeds

    private func speeds() -> [String: LocalModelSpeed] {
        guard let data = UserDefaults.standard.data(forKey: Keys.speeds) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalModelSpeed].self, from: data)) ?? [:]
    }

    private func store(_ speed: LocalModelSpeed, for id: String) {
        var all = speeds()
        all[id] = speed
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Keys.speeds) }
    }

    /// utsname's machine: "iPhone18,1".
    static let machine: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Apple Intelligence as the self-test reports it.
    static func appleIntelligenceAvailability() -> String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "deviceNotEligible"
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            @unknown default: return "unavailable"
            }
        }
        #else
        return "unavailable"
        #endif
    }
}
#endif
