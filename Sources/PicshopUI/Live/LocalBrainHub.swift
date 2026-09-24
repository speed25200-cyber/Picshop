#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopCore
import PicshopIntent
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

/// The one place the local model lives: its status, download, loading and
/// release, and the brains Live gets. The app target registers the runtime;
/// Live sessions only ask for brains, which never waits on the weights.
///
/// Only leaf views read `status` (download progress changes often).
///
/// Phase 0: the frozen surface. The status is `.notInThisBuild` (`.unsupported`
/// on the simulator once a runtime registers), and `makeLiveBrains` returns
/// Apple's on-device model and the rules-only grammar. Downloads, loading, the
/// speed test and the model brain arrive in phase 1.
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

    @ObservationIgnored private weak var app: AppEnvironment?

    init() {}

    /// Called from AppEnvironment.init: settings and model states come from there.
    public func attach(_ app: AppEnvironment) {
        self.app = app
        refreshStatus()
    }

    /// Starts or resumes the model for this iPhone's tier. Cellular only when allowed.
    public func download(allowCellular: Bool) {
        PSLog.info("local brain: download asked (\(allowCellular ? "cellular allowed" : "Wi-Fi")) while \(status.phase)", category: .models)
    }

    public func cancelDownload() {}

    public func delete() async {}

    public func setQuality(_ quality: LocalModelQuality) async {
        refreshStatus()
    }

    /// Editor opened ("editor", only with "Préparer Live à l'ouverture") or Live
    /// started ("live"): loads the weights off the main actor when memory,
    /// thermal state and power allow it (D13).
    public func preload(reason: String) {}

    /// Memory warning, background, Stable Diffusion, or the editor closed for 60 s.
    public func release(reason: String) {}

    public func runSpeedTest() async -> LocalModelSpeed? { nil }

    /// Returns at once and never loads weights: a model brain only when the model is ready.
    public func makeLiveBrains(mode: EditorMode) -> LiveBrainSet {
        let local = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: mode)
        #if canImport(FoundationModels)
        let onDevice: (any LiveBrain)? = FoundationModelsLiveBrain(mode: mode)
        #else
        let onDevice: (any LiveBrain)? = nil
        #endif
        return LiveBrainSet(model: nil, onDevice: onDevice, local: local)
    }

    public func probe() async -> LocalBrainProbe {
        let summary: String
        switch status.phase {
        case .notInThisBuild: summary = "Pas de cerveau local dans ce build"
        case .unsupported: summary = "Cerveau local non pris en charge sur cet iPhone"
        default: summary = "Cerveau local pas encore prêt"
        }
        return LocalBrainProbe(passed: false, summary: summary, appleIntelligence: Self.appleIntelligenceAvailability())
    }

    // MARK: Status

    /// Phase 0: no runtime loads weights yet, so the model is not in this build,
    /// or unsupported on the simulator. Phase 1 adds the tier decision, the
    /// catalog model and its install state.
    private func refreshStatus() {
        #if targetEnvironment(simulator)
        if runtime != nil {
            setStatus(LocalBrainStatus(phase: .unsupported, decision: LocalTierDecision(tier: .unsupported, reason: .simulator)))
            return
        }
        #endif
        setStatus(.notInThisBuild)
    }

    /// Assigned only on a change, so observers redraw only then.
    private func setStatus(_ new: LocalBrainStatus) {
        if status != new { status = new }
    }

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
