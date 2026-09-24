import Foundation
import PicshopCore

/// Picks the brain for each turn: the local model, then Apple's on-device
/// model, then the local grammar. Everything runs on the iPhone, and Live never
/// goes silent: the grammar is always there.
///
/// Per brain kind, two failed turns in a row cool it down for 60 s, and three
/// failures within 10 minutes keep it off for the rest of the editor session.
/// The model is off for the session at once after a load failure or memory
/// pressure. The grammar never cools down. Cancellations (barge-in, a tap,
/// typing) are not failures: the session never records them.
public struct BrainSelector: Sendable {
    public struct Inputs: Sendable, Equatable {
        /// The model is loaded and its brain exists.
        public var modelReady: Bool
        public var onDeviceAvailable: Bool
        /// Thermal state critical: the model is skipped.
        public var thermalCritical: Bool
        public var now: Double

        public init(modelReady: Bool, onDeviceAvailable: Bool, thermalCritical: Bool = false, now: Double) {
            self.modelReady = modelReady
            self.onDeviceAvailable = onDeviceAvailable
            self.thermalCritical = thermalCritical
            self.now = now
        }
    }

    /// After 2 failures in a row.
    public static let cooldown: Double = 60
    /// 3 failures within the window: off for the editor session.
    public static let failureWindow: Double = 600

    private var failuresInARow: [LiveBrainKind: Int] = [:]
    private var failureTimes: [LiveBrainKind: [Double]] = [:]
    private var cooldownUntil: [LiveBrainKind: Double] = [:]
    private var offForSession: Set<LiveBrainKind> = []

    public init() {}

    /// model -> onDevice -> local, skipping `excluding`, cooled-down and switched-off kinds.
    /// The local grammar is the answer of last resort, even when excluded.
    public mutating func choose(_ inputs: Inputs, excluding: Set<LiveBrainKind> = []) -> LiveBrainKind {
        for (kind, until) in cooldownUntil where inputs.now >= until { cooldownUntil[kind] = nil }
        if inputs.modelReady, !inputs.thermalCritical, usable(.model, excluding: excluding) { return .model }
        if inputs.onDeviceAvailable, usable(.onDevice, excluding: excluding) { return .onDevice }
        return .local
    }

    public mutating func recordFailure(_ kind: LiveBrainKind, _ error: LiveBrainError, now: Double) {
        guard kind != .local else { return }
        if kind == .model {
            switch error {
            case .memoryPressure, .modelUnavailable:
                offForSession.insert(.model)
                return
            default:
                break
            }
        }
        let streak = (failuresInARow[kind] ?? 0) + 1
        failuresInARow[kind] = streak
        let times = (failureTimes[kind] ?? []).filter { now - $0 < Self.failureWindow } + [now]
        failureTimes[kind] = times
        if streak >= 2 { cooldownUntil[kind] = max(cooldownUntil[kind] ?? now, now + Self.cooldown) }
        if times.count >= 3 { offForSession.insert(kind) }
    }

    public mutating func recordSuccess(_ kind: LiveBrainKind) {
        failuresInARow[kind] = 0
    }

    public func isOffForSession(_ kind: LiveBrainKind) -> Bool {
        offForSession.contains(kind)
    }

    /// The problem shown and spoken for a failure.
    public static func problem(for error: LiveBrainError) -> LiveProblem {
        switch error {
        case .modelNotReady, .modelUnavailable, .memoryPressure: return .modelUnavailable
        case .timeout: return .brainTimeout
        case .streamTruncated: return .unavailable("stream")
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    /// A log token: model_not_ready, timeout_first_token…
    public static func errorName(_ error: LiveBrainError) -> String {
        switch error {
        case .modelNotReady: return "model_not_ready"
        case .modelUnavailable: return "model_unavailable"
        case .memoryPressure: return "memory_pressure"
        case .timeout(let stage): return "timeout_\(stage)"
        case .streamTruncated: return "stream_truncated"
        case .unavailable: return "unavailable"
        }
    }

    private func usable(_ kind: LiveBrainKind, excluding: Set<LiveBrainKind>) -> Bool {
        !excluding.contains(kind) && !offForSession.contains(kind) && cooldownUntil[kind] == nil
    }
}
