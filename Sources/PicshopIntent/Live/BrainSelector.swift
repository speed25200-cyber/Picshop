import Foundation
import PicshopCore

/// Picks the brain for each turn: Claude, then the on-device model, then the
/// local grammar. Live never goes silent.
public struct BrainSelector: Sendable {
    public struct Inputs: Sendable, Equatable {
        /// key && consent && liveUseClaude && not disabled
        public var claudeAllowed: Bool
        public var online: Bool
        public var onDeviceAvailable: Bool
        public var now: Double

        public init(claudeAllowed: Bool, online: Bool, onDeviceAvailable: Bool, now: Double) {
            self.claudeAllowed = claudeAllowed
            self.online = online
            self.onDeviceAvailable = onDeviceAvailable
            self.now = now
        }
    }

    public private(set) var claudeDisabledReason: LiveProblem?

    public init() {}

    public mutating func choose(_ inputs: Inputs) -> LiveBrainKind {
        // Phase 0 stub: priority only, no cooldowns.
        if inputs.claudeAllowed, inputs.online, claudeDisabledReason == nil { return .claude }
        return inputs.onDeviceAvailable ? .onDevice : .local
    }

    public mutating func recordFailure(_ error: LiveBrainError, now: Double) {
        // Phase 0 stub.
    }

    public mutating func recordSuccess() {
        // Phase 0 stub.
    }

    /// Key changed.
    public mutating func resetClaude() {
        claudeDisabledReason = nil
    }
}
