import Foundation

// Which local model this iPhone runs: Max (Qwen3.5 4B), Rapide (Qwen3.5 2B)
// or none. Pure, so the tier table is tested on Linux.

/// The user's choice in Settings › Intelligence.
public enum LocalModelQuality: String, Sendable, CaseIterable, Codable { case auto, max, fast }

public enum LocalModelTier: String, Sendable, Equatable { case max, fast, unsupported }

/// Why a tier was chosen. The UI maps each reason to its own text.
public enum LocalTierReason: String, Sendable, Equatable {
    case recommended, olderChip, notEnoughMemory, lowPowerMode, hot, userChoseFast, userChoseMax, memoryKillLastTime, slowMeasured, simulator, notInThisBuild
}

/// What the tier depends on, read by the app at launch and before each load.
public struct LocalDeviceFacts: Sendable, Equatable {
    /// utsname, "iPhone18,1".
    public var machine: String
    public var physicalMemory: UInt64
    /// os_proc_available_memory().
    public var availableMemory: UInt64
    public var lowPowerMode: Bool
    public var thermalSerious: Bool
    public var lastSessionMemoryKilledWithModel: Bool
    public var measuredTokensPerSecond: Double?

    public init(machine: String, physicalMemory: UInt64, availableMemory: UInt64, lowPowerMode: Bool, thermalSerious: Bool,
                lastSessionMemoryKilledWithModel: Bool, measuredTokensPerSecond: Double?) {
        self.machine = machine
        self.physicalMemory = physicalMemory
        self.availableMemory = availableMemory
        self.lowPowerMode = lowPowerMode
        self.thermalSerious = thermalSerious
        self.lastSessionMemoryKilledWithModel = lastSessionMemoryKilledWithModel
        self.measuredTokensPerSecond = measuredTokensPerSecond
    }
}

public struct LocalTierDecision: Sendable, Equatable {
    public var tier: LocalModelTier
    public var reason: LocalTierReason

    public init(tier: LocalModelTier, reason: LocalTierReason) {
        self.tier = tier
        self.reason = reason
    }
}

/// Phase 0: the frozen signatures. `decide` reports no local model until the
/// tier table lands in phase 1.
public enum LocalModelTiering {
    public static let maxModelID = "live-qwen35-4b", fastModelID = "live-qwen35-2b"

    public static func decide(_ facts: LocalDeviceFacts, quality: LocalModelQuality) -> LocalTierDecision {
        LocalTierDecision(tier: .unsupported, reason: .notInThisBuild)
    }

    public static func modelID(for tier: LocalModelTier) -> String? {
        switch tier {
        case .max: return maxModelID
        case .fast: return fastModelID
        case .unsupported: return nil
        }
    }
}
