#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
import PicshopCore

/// Turns the phone's thermal state, Low Power Mode and the user's preference
/// into one render and animation budget that every screen reads.
///
/// The goal is a UI that stays at the display's refresh rate and a phone that
/// stays cool: previews shrink before the frame rate drops, glow and blur go
/// first, and heavy neural work waits when the device is already hot.
@MainActor
@Observable
public final class PerformanceGovernor {
    /// How much of the device the app may use right now, best first.
    public enum Tier: Int, Comparable, Sendable {
        case full = 0
        case balanced
        case conserve
        case critical

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The user's choice in Settings › Performance.
    public enum Preference: String, CaseIterable, Identifiable, Sendable {
        /// Follow the thermal state (default).
        case automatic
        /// Always render at the highest quality; only critical heat throttles.
        case quality
        /// Keep the phone cool and the battery full: one step below automatic.
        case efficiency

        public var id: String { rawValue }
    }

    public private(set) var thermalState: ProcessInfo.ThermalState
    public private(set) var isLowPowerMode: Bool
    public var preference: Preference = .automatic
    /// Mirrors the system Reduce Motion setting; continuous animations pause when set.
    public private(set) var reduceMotion: Bool
    /// Refresh rate of the main display (60 or 120).
    public let displayRefreshRate: Int
    /// Native scale of the main display (2 or 3).
    public let displayScale: CGFloat

    private var tokens: [NSObjectProtocol] = []

    public init() {
        let process = ProcessInfo.processInfo
        thermalState = process.thermalState
        isLowPowerMode = process.isLowPowerModeEnabled
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        displayRefreshRate = max(60, UIScreen.main.maximumFramesPerSecond)
        displayScale = UIScreen.main.scale
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    private func refresh() {
        let process = ProcessInfo.processInfo
        let previous = tier
        thermalState = process.thermalState
        isLowPowerMode = process.isLowPowerModeEnabled
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        if tier != previous {
            PSLog.info("performance tier \(previous) → \(tier) (thermal \(thermalState.rawValue), low power \(isLowPowerMode))", category: .ui)
        }
    }

    // MARK: - Budget

    /// The active tier, combining thermal state, Low Power Mode and the preference.
    public var tier: Tier {
        let thermal: Tier
        switch thermalState {
        case .nominal: thermal = .full
        case .fair: thermal = .balanced
        case .serious: thermal = .conserve
        case .critical: thermal = .critical
        @unknown default: thermal = .balanced
        }
        switch preference {
        case .quality:
            return thermal == .critical ? .conserve : (isLowPowerMode ? .balanced : .full)
        case .efficiency:
            let base = max(thermal, .balanced)
            return isLowPowerMode ? max(base, .conserve) : base
        case .automatic:
            return isLowPowerMode ? max(thermal, .balanced) : thermal
        }
    }

    /// Longest side of the on-screen preview once an interaction settles.
    public var previewLongestSide: Double {
        switch tier {
        case .full: return 2048
        case .balanced: return 1600
        case .conserve: return 1200
        case .critical: return 900
        }
    }

    /// Longest side of the preview while a dial or slider is being dragged.
    public var interactivePreviewSide: Double {
        switch tier {
        case .full: return 1280
        case .balanced: return 1024
        case .conserve: return 768
        case .critical: return 512
        }
    }

    /// Pause before the sharp frame replaces the interactive one.
    public var settleDelay: Duration {
        switch tier {
        case .full: return .milliseconds(320)
        case .balanced: return .milliseconds(420)
        case .conserve: return .milliseconds(600)
        case .critical: return .milliseconds(900)
        }
    }

    /// Minimum spacing between two interactive renders (frame coalescing).
    public var interactiveRenderInterval: Duration {
        switch tier {
        case .full: return .milliseconds(8)
        case .balanced: return .milliseconds(16)
        case .conserve: return .milliseconds(33)
        case .critical: return .milliseconds(66)
        }
    }

    /// Frame-rate cap for the Metal canvas.
    public var maxFrameRate: Int {
        switch tier {
        case .full: return displayRefreshRate
        case .balanced: return min(displayRefreshRate, 80)
        case .conserve: return 60
        case .critical: return 30
        }
    }

    /// Cap on the drawable scale of the Metal canvas (3× panels drop to 2× when hot).
    public var maxContentScale: CGFloat {
        switch tier {
        case .full, .balanced: return displayScale
        case .conserve: return min(displayScale, 2)
        case .critical: return min(displayScale, 2)
        }
    }

    /// Whether glow, drop shadows and blurred halos may be drawn.
    public var allowsAmbientEffects: Bool { tier <= .balanced }

    /// Whether looping animations (waveforms, pulsing rings) may run.
    public var allowsContinuousAnimation: Bool { !reduceMotion && tier <= .conserve }

    /// Whether heavy neural work (upscaling, generative fill, model compiles) should start now.
    public var allowsHeavyWork: Bool { tier < .critical }

    /// Side used for look thumbnails and library posters.
    public var thumbnailSide: Double { tier <= .balanced ? 160 : 112 }

    /// Effects level handed to the design system.
    public var effectsLevel: PSEffectsLevel {
        switch tier {
        case .full: return .rich
        case .balanced: return .rich
        case .conserve: return .reduced
        case .critical: return .minimal
        }
    }

    /// Localised, user-facing status line.
    public var statusTitle: String {
        switch thermalState {
        case .nominal: return isLowPowerMode ? L("Low Power Mode") : L("Cool")
        case .fair: return L("Warm")
        case .serious: return L("Hot")
        case .critical: return L("Very hot")
        @unknown default: return L("Warm")
        }
    }

    public var statusSymbol: String {
        switch thermalState {
        case .nominal: return isLowPowerMode ? "battery.25percent" : "snowflake"
        case .fair: return "thermometer.low"
        case .serious: return "thermometer.medium"
        case .critical: return "thermometer.high"
        @unknown default: return "thermometer.medium"
        }
    }

    public var statusTint: Color {
        switch thermalState {
        case .nominal: return isLowPowerMode ? PSTheme.warning : PSTheme.success
        case .fair: return PSTheme.success
        case .serious: return PSTheme.warning
        case .critical: return PSTheme.danger
        @unknown default: return PSTheme.warning
        }
    }
}

/// How much visual richness the design system may spend right now.
public enum PSEffectsLevel: Int, Comparable, Sendable {
    /// Glass, glow, shadows, sheen.
    case rich
    /// Glass and sheen; no glow or drop shadows.
    case reduced
    /// Flat surfaces only.
    case minimal

    public static func < (lhs: PSEffectsLevel, rhs: PSEffectsLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct PSEffectsLevelKey: EnvironmentKey {
    static let defaultValue: PSEffectsLevel = .rich
}

private struct PSReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Set once at the root from `PerformanceGovernor.effectsLevel`.
    var psEffects: PSEffectsLevel {
        get { self[PSEffectsLevelKey.self] }
        set { self[PSEffectsLevelKey.self] = newValue }
    }

    /// Mirrors the system Reduce Motion setting. Anything that moves without
    /// the user touching it — a level meter, a breathing ring, an iterating
    /// symbol — holds still when this is on.
    var psReducedMotion: Bool {
        get { self[PSReducedMotionKey.self] }
        set { self[PSReducedMotionKey.self] = newValue }
    }
}
#endif
