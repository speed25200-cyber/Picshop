import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D23: at most one compaction per 10 turns on the W3 dialogue corpus (L4's 12 layer dialogues, each extended to 10
/// turns with filler turns) under the 4B KV engine's limits (media append verified), with realistic edit turns (the
/// call, its tool result and its check) and a look whenever `needsFreshLook` says so. ChatSession's limits are
/// reported, not asserted: they are W2's, unchanged.
final class CompactionBudgetTests: XCTestCase {
    private let fourB = LocalModelCatalog.max.info

    func testTheKVEngineCompactsAtMostOncePerTenTurns() {
        let limits = LiveContextPolicy.limits(for: fourB, engine: .kvEngine, mediaAppendVerified: true)
        var total = 0
        var turns = 0
        var peak = 0
        for dialogue in W3LiveScript.dialogues {
            let run = W3LiveScript.simulate(dialogue, limits: limits)
            peak = max(peak, run.peakTokens)
            XCTAssertEqual(run.turns.count, 10, dialogue.name)
            XCTAssertLessThanOrEqual(run.compactions, 1, "\(dialogue.name): \(run.compactions) compactions, peak \(run.peakTokens) tokens")
            total += run.compactions
            turns += run.turns.count
        }
        let rate = Double(total) * 10 / Double(turns)
        print("kvEngine 4B: \(total) compactions over \(turns) turns (\(String(format: "%.2f", rate)) per 10 turns), peak \(peak) tokens")
        XCTAssertLessThanOrEqual(rate, FirstTokenTargets.compactionsPer10Turns)
    }

    func testTheOtherRowsAreReported() {
        let rows: [(String, LiveContextLimits)] = [
            ("4B kvEngine without media append", LiveContextPolicy.limits(for: fourB, engine: .kvEngine, mediaAppendVerified: false)),
            ("4B ChatSession", LiveContextPolicy.limits(for: fourB, engine: .chatSession, mediaAppendVerified: false)),
        ]
        for (name, limits) in rows {
            var total = 0
            var turns = 0
            for dialogue in W3LiveScript.dialogues {
                let run = W3LiveScript.simulate(dialogue, limits: limits)
                total += run.compactions
                turns += run.turns.count
            }
            print("\(name): \(total) compactions over \(turns) turns")
            XCTAssertEqual(turns, 120)
        }
    }

    func testTheConversationFitsTheContextBetweenCompactions() {
        let limits = LiveContextPolicy.limits(for: fourB, engine: .kvEngine, mediaAppendVerified: true)
        for dialogue in W3LiveScript.dialogues {
            let run = W3LiveScript.simulate(dialogue, limits: limits)
            // A compaction happens at the start of a turn, so one turn can end above compactAt, never by a whole turn's worth.
            XCTAssertLessThan(run.peakTokens, limits.compactAt + 2_500, dialogue.name)
            XCTAssertGreaterThan(run.turns.first?.contextTokens ?? 0, 1_000, "the prefix is counted")
            XCTAssertEqual(run.turns.first?.picture, true, "the session start looks")
        }
    }
}
