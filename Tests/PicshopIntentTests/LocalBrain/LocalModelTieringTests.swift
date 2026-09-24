import Foundation
import XCTest
@testable import PicshopIntent

// The tier table (contract §6): which iPhone gets Qwen3.5 4B, 2B or nothing,
// and how memory, Low Power Mode, a memory kill, the measured speed and the
// user's Qualité choice move it.

final class LocalModelTieringTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    private func facts(_ machine: String, ram: Double = 8, available: Double = 5.5, lowPower: Bool = false, killed: Bool = false,
                       speed: Double? = nil, hot: Bool = false) -> LocalDeviceFacts {
        LocalDeviceFacts(machine: machine, physicalMemory: UInt64(ram * 1e9), availableMemory: UInt64(available * 1e9), lowPowerMode: lowPower,
                         thermalSerious: hot, lastSessionMemoryKilledWithModel: killed, measuredTokensPerSecond: speed)
    }

    private func decide(_ facts: LocalDeviceFacts, _ quality: LocalModelQuality = .auto) -> LocalTierDecision {
        LocalModelTiering.decide(facts, quality: quality)
    }

    func testMaxIPhones() {
        // 16 Pro, 16 Pro Max (A18 Pro); 17 Pro, 17 Pro Max, 17, Air (A19 Pro / A19).
        for machine in ["iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4"] {
            let ram: Double = machine.hasPrefix("iPhone18,1") || machine.hasPrefix("iPhone18,2") || machine == "iPhone18,4" ? 12 : 8
            XCTAssertEqual(decide(facts(machine, ram: ram)), LocalTierDecision(tier: .max, reason: .recommended), machine)
        }
    }

    func testRapideIPhones() {
        // 15 Pro, 15 Pro Max (A17 Pro); 16, 16 Plus, 16e (A18).
        for machine in ["iPhone16,1", "iPhone16,2", "iPhone17,3", "iPhone17,4", "iPhone17,5"] {
            XCTAssertEqual(decide(facts(machine)), LocalTierDecision(tier: .fast, reason: .olderChip), machine)
        }
    }

    func testUnsupportedIPhones() {
        // 15, 15 Plus (6 GB), 14 Pro, 13.
        XCTAssertEqual(decide(facts("iPhone15,4", ram: 6)), LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory))
        XCTAssertEqual(decide(facts("iPhone15,5", ram: 6)), LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory))
        XCTAssertEqual(decide(facts("iPhone15,2", ram: 6)).tier, .unsupported)
        XCTAssertEqual(decide(facts("iPhone14,5", ram: 4)).tier, .unsupported)
        // An 8 GB phone reports a little under 8 GiB: still supported.
        XCTAssertEqual(decide(LocalDeviceFacts(machine: "iPhone17,1", physicalMemory: 7_999_995_904, availableMemory: 5_800_000_000, lowPowerMode: false,
                                               thermalSerious: false, lastSessionMemoryKilledWithModel: false, measuredTokensPerSecond: nil)).tier, .max)
        XCTAssertEqual(decide(LocalDeviceFacts(machine: "iPhone15,4", physicalMemory: 5_900_000_000, availableMemory: 3_000_000_000, lowPowerMode: false,
                                               thermalSerious: false, lastSessionMemoryKilledWithModel: false, measuredTokensPerSecond: nil)).tier, .unsupported)
    }

    func testFutureIPhones() {
        XCTAssertEqual(decide(facts("iPhone19,1", ram: 12)), LocalTierDecision(tier: .max, reason: .recommended))
        XCTAssertEqual(decide(facts("iPhone20,3", ram: 8)).tier, .max)
        XCTAssertEqual(decide(facts("iPhone19,2", ram: 6)).tier, .unsupported)
    }

    func testSimulatorAndOddMachines() {
        XCTAssertEqual(decide(facts("arm64", ram: 16)), LocalTierDecision(tier: .unsupported, reason: .simulator))
        XCTAssertEqual(decide(facts("x86_64", ram: 16)), LocalTierDecision(tier: .unsupported, reason: .simulator))
        XCTAssertEqual(decide(facts("iPad16,3", ram: 16)).tier, .fast)
        XCTAssertEqual(decide(facts("", ram: 16)).tier, .unsupported)
    }

    func testMaxDropsToRapide() {
        XCTAssertEqual(decide(facts("iPhone18,1", ram: 12, available: 4.0)), LocalTierDecision(tier: .fast, reason: .notEnoughMemory))
        XCTAssertEqual(decide(facts("iPhone18,1", ram: 12, lowPower: true)), LocalTierDecision(tier: .fast, reason: .lowPowerMode))
        XCTAssertEqual(decide(facts("iPhone17,1", killed: true)), LocalTierDecision(tier: .fast, reason: .memoryKillLastTime))
        XCTAssertEqual(decide(facts("iPhone17,1", speed: 9.5)), LocalTierDecision(tier: .fast, reason: .slowMeasured))
        XCTAssertEqual(decide(facts("iPhone17,1", speed: 18)).tier, .max)
        XCTAssertEqual(decide(facts("iPhone17,1", hot: true)).tier, .max, "heat shortens answers, it does not change the model")
    }

    func testRapideLimits() {
        XCTAssertEqual(decide(facts("iPhone16,1", available: 2.5)), LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory))
        XCTAssertEqual(decide(facts("iPhone18,1", ram: 12, available: 2.0)), LocalTierDecision(tier: .unsupported, reason: .notEnoughMemory))
        // One tier down from Rapide is no model.
        XCTAssertEqual(decide(facts("iPhone17,3", killed: true)), LocalTierDecision(tier: .unsupported, reason: .memoryKillLastTime))
    }

    func testQualityOverridesWithinMemoryLimits() {
        XCTAssertEqual(decide(facts("iPhone18,1", ram: 12), .fast), LocalTierDecision(tier: .fast, reason: .userChoseFast))
        XCTAssertEqual(decide(facts("iPhone16,1"), .max), LocalTierDecision(tier: .max, reason: .userChoseMax))
        XCTAssertEqual(decide(facts("iPhone17,1", lowPower: true, killed: true, speed: 8), .max), LocalTierDecision(tier: .max, reason: .userChoseMax))
        XCTAssertEqual(decide(facts("iPhone17,1", available: 3.5), .max), LocalTierDecision(tier: .fast, reason: .notEnoughMemory))
        XCTAssertEqual(decide(facts("iPhone17,3", killed: true), .fast), LocalTierDecision(tier: .fast, reason: .userChoseFast))
        XCTAssertEqual(decide(facts("iPhone15,4", ram: 6), .max).tier, .unsupported)
        XCTAssertEqual(decide(facts("iPhone16,1", available: 2.0), .fast).tier, .unsupported)
    }

    func testDecisionNamesTheCatalogModel() {
        XCTAssertEqual(LocalModelCatalog.entry(for: decide(facts("iPhone18,1", ram: 12)).tier)?.info.displayName, "Qwen3.5 4B")
        XCTAssertEqual(LocalModelCatalog.entry(for: decide(facts("iPhone17,3")).tier)?.info.displayName, "Qwen3.5 2B")
    }
}
