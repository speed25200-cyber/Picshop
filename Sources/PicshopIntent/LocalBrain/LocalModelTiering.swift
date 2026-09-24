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

/// The tier table (contract §6), checked against Apple's model identifiers:
/// - Max: iPhone17,1 / 17,2 (16 Pro, 16 Pro Max: A18 Pro), every iPhone18,x
///   (17 Pro, 17 Pro Max, Air, 17: A19 Pro / A19), and an unknown iPhone19,x
///   or later with at least 7.5 GB.
/// - Rapide: iPhone16,1 / 16,2 (15 Pro, 15 Pro Max: A17 Pro) and
///   iPhone17,3 / 17,4 / 17,5 (16, 16 Plus, 16e: A18).
/// - None: under 7.5 GB of RAM (iPhone 15, 15 Plus and older), the simulator.
///
/// A Max iPhone drops to Rapide with under 4.3 GB available, in Low Power
/// Mode, after a memory kill with the model loaded, or below 12 tok/s measured.
/// Rapide needs 2.6 GB available; a memory kill there means no model. The
/// user's Qualité choice overrides all of this except the memory floors.
/// Heat is not a tier reason: a hot phone keeps its model and answers shorter.
public enum LocalModelTiering {
    public static let maxModelID = "live-qwen35-4b", fastModelID = "live-qwen35-2b"

    /// Decimal bytes: an 8 GB iPhone reports a little under 8 GiB.
    public static let minimumPhysicalMemory: UInt64 = 7_500_000_000
    public static let maxAvailableMemory: UInt64 = 4_300_000_000
    public static let fastAvailableMemory: UInt64 = 2_600_000_000
    public static let minimumMaxTokensPerSecond = 12.0

    public static func decide(_ facts: LocalDeviceFacts, quality: LocalModelQuality) -> LocalTierDecision {
        if isSimulator(facts.machine) { return LocalTierDecision(tier: .unsupported, reason: .simulator) }
        guard facts.physicalMemory >= minimumPhysicalMemory else { return LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory) }
        guard let chip = chipTier(facts.machine) else { return LocalTierDecision(tier: .unsupported, reason: .olderChip) }
        guard facts.availableMemory >= fastAvailableMemory else { return LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory) }
        let roomForMax = facts.availableMemory >= maxAvailableMemory
        switch quality {
        case .fast:
            return LocalTierDecision(tier: .fast, reason: .userChoseFast)
        case .max:
            return roomForMax ? LocalTierDecision(tier: .max, reason: .userChoseMax) : LocalTierDecision(tier: .fast, reason: .notEnoughMemory)
        case .auto:
            break
        }
        if chip == .fast {
            // One tier down from Rapide is no model at all.
            if facts.lastSessionMemoryKilledWithModel { return LocalTierDecision(tier: .unsupported, reason: .memoryKillLastTime) }
            return LocalTierDecision(tier: .fast, reason: .olderChip)
        }
        if !roomForMax { return LocalTierDecision(tier: .fast, reason: .notEnoughMemory) }
        if facts.lowPowerMode { return LocalTierDecision(tier: .fast, reason: .lowPowerMode) }
        if facts.lastSessionMemoryKilledWithModel { return LocalTierDecision(tier: .fast, reason: .memoryKillLastTime) }
        if let speed = facts.measuredTokensPerSecond, speed > 0, speed < minimumMaxTokensPerSecond {
            return LocalTierDecision(tier: .fast, reason: .slowMeasured)
        }
        return LocalTierDecision(tier: .max, reason: .recommended)
    }

    public static func modelID(for tier: LocalModelTier) -> String? {
        switch tier {
        case .max: return maxModelID
        case .fast: return fastModelID
        case .unsupported: return nil
        }
    }

    /// The chip's own tier, before memory and the user's choice: nil for an older chip.
    static func chipTier(_ machine: String) -> LocalModelTier? {
        guard let (family, major, minor) = parse(machine) else { return nil }
        guard family == "iPhone" else {
            // An iPad or anything else with the memory: the smaller model, to be safe.
            return .fast
        }
        switch major {
        case ..<16: return nil
        case 16: return .fast                      // 16,1 / 16,2: A17 Pro
        case 17: return [1, 2].contains(minor) ? .max : .fast   // A18 Pro, else A18
        default: return .max                        // 18,x: A19 / A19 Pro; 19 and later
        }
    }

    static func isSimulator(_ machine: String) -> Bool {
        ["x86_64", "arm64", "i386", "arm64e"].contains(machine)
    }

    /// "iPhone18,1" → ("iPhone", 18, 1).
    static func parse(_ machine: String) -> (String, Int, Int)? {
        guard let digitStart = machine.firstIndex(where: \.isNumber) else { return nil }
        let family = String(machine[..<digitStart])
        let numbers = machine[digitStart...].split(separator: ",")
        guard numbers.count == 2, let major = Int(numbers[0]), let minor = Int(numbers[1]) else { return nil }
        return (family, major, minor)
    }
}
