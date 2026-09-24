import Foundation
import PicshopCore

/// Picks the brain for each turn: Claude, then the on-device model, then the
/// local grammar. Live never goes silent.
///
/// A rejected key, no credit, no permission or no model access turn Claude off
/// until resetClaude(); a rate limit without a short retry, or two failed turns
/// in a row, cool Claude down for 60 s; three failures within 10 minutes keep
/// it off for the rest of the editor session.
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

    public static let cooldown: Double = 60
    public static let failureWindow: Double = 600

    public private(set) var claudeDisabledReason: LiveProblem?
    /// Until when Claude rests after a rate limit or failed turns.
    public private(set) var cooldownUntil: Double?
    private var failuresInARow = 0
    private var failureTimes: [Double] = []
    /// Three failures within 10 minutes: off for the rest of the editor session (a new key does not bring it back).
    public private(set) var offForSession = false

    public init() {}

    public mutating func choose(_ inputs: Inputs) -> LiveBrainKind {
        if let until = cooldownUntil, inputs.now >= until { cooldownUntil = nil }
        if inputs.claudeAllowed, inputs.online, claudeDisabledReason == nil, !offForSession, cooldownUntil == nil { return .claude }
        return inputs.onDeviceAvailable ? .onDevice : .local
    }

    public mutating func recordFailure(_ error: LiveBrainError, now: Double) {
        switch error {
        case .invalidKey, .missingKey:
            claudeDisabledReason = .keyInvalid
            return
        case .noCredit:
            claudeDisabledReason = .noCredit
            return
        case .forbidden, .modelUnavailable:
            claudeDisabledReason = .noAccess
            return
        case .rateLimited(let retryAfter):
            cooldownUntil = max(cooldownUntil ?? now, now + max(Self.cooldown, retryAfter ?? 0))
        default:
            break
        }
        failuresInARow += 1
        failureTimes = failureTimes.filter { now - $0 < Self.failureWindow } + [now]
        if failuresInARow >= 2 { cooldownUntil = max(cooldownUntil ?? now, now + Self.cooldown) }
        if failureTimes.count >= 3 {
            offForSession = true
            claudeDisabledReason = claudeDisabledReason ?? .unavailable("repeated failures")
        }
    }

    public mutating func recordSuccess() {
        failuresInARow = 0
    }

    /// Key changed.
    public mutating func resetClaude() {
        switch claudeDisabledReason {
        case .keyInvalid?, .noCredit?, .noAccess?: claudeDisabledReason = nil
        default: break
        }
        cooldownUntil = nil
        failuresInARow = 0
    }

    /// The problem to show for a failure, or nil when it is not worth a notice.
    public static func problem(for error: LiveBrainError) -> LiveProblem {
        switch error {
        case .missingKey, .invalidKey: return .keyInvalid
        case .noCredit: return .noCredit
        case .forbidden, .modelUnavailable: return .noAccess
        case .rateLimited: return .rateLimited
        case .network: return .offline
        case .overloaded, .server, .timeout, .streamTruncated, .badRequest, .requestTooLarge: return .unavailable("claude")
        case .unavailable(let reason): return .unavailable(reason)
        }
    }
}
