import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D23: the first-token percentiles per path, the measured rates, restores and compactions per 10 turns.
final class FirstTokenStatsTests: XCTestCase {
    private func sample(_ ms: Int, _ path: String, prefilled: Int = 200, cached: Int = 5_000) -> FirstTokenSample {
        FirstTokenSample(milliseconds: ms, path: path, prefilled: prefilled, cached: cached, picture: path == "picture")
    }

    func testNearestRankPercentilesPerPath() {
        var stats = FirstTokenStats()
        XCTAssertNil(stats.percentile(50, path: nil))
        for ms in [500, 300, 900, 700, 100] { stats.add(sample(ms, "warm")) }
        stats.add(sample(2_000, "cold", prefilled: 5_000, cached: 0))
        stats.add(sample(1_100, "picture"))
        XCTAssertEqual(stats.percentile(50, path: "warm"), 500)
        XCTAssertEqual(stats.percentile(95, path: "warm"), 900)
        XCTAssertEqual(stats.percentile(0, path: "warm"), 100)
        XCTAssertEqual(stats.percentile(100, path: "warm"), 900)
        XCTAssertEqual(stats.percentile(20, path: "warm"), 100, "rank ceil(0.2 × 5) = 1")
        XCTAssertEqual(stats.percentile(21, path: "warm"), 300)
        XCTAssertEqual(stats.percentile(50, path: "cold"), 2_000)
        XCTAssertEqual(stats.percentile(50, path: "picture"), 1_100)
        XCTAssertNil(stats.percentile(50, path: "restored"))
        XCTAssertEqual(stats.percentile(50, path: nil), 700, "every path: 100 300 500 700 900 1100 2000")
        XCTAssertEqual(stats.percentile(250, path: "warm"), 900, "p is clamped")
        XCTAssertEqual(stats.count(path: "warm"), 5)
        XCTAssertEqual(stats.count(path: nil), 7)
    }

    func testCompactionsPerTenTurns() {
        var stats = FirstTokenStats()
        XCTAssertEqual(stats.compactionsPer10Turns, 0)
        for turn in 0..<20 { stats.noteTurn(compacted: turn == 9) }
        XCTAssertEqual(stats.compactionsPer10Turns, 0.5, accuracy: 1e-9)
        stats.noteTurn(compacted: true)
        stats.noteTurn(compacted: true)
        XCTAssertEqual(stats.turns, 22)
        XCTAssertEqual(stats.compactions, 3)
        XCTAssertEqual(stats.compactionsPer10Turns, 30.0 / 22, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(0.5, FirstTokenTargets.compactionsPer10Turns)
    }

    func testPrefillAndDecodeRates() {
        var stats = FirstTokenStats()
        XCTAssertNil(stats.prefillTokensPerSecond(path: nil))
        XCTAssertNil(stats.decodeTokensPerSecond)
        stats.add(sample(500, "warm", prefilled: 250))     // 500 tok/s
        stats.add(sample(1_000, "warm", prefilled: 400))   // 400 tok/s
        stats.add(sample(400, "warm", prefilled: 360))     // 900 tok/s
        stats.add(sample(10, "warm", prefilled: 0))        // nothing prefilled: ignored
        XCTAssertEqual(stats.prefillTokensPerSecond(path: "warm") ?? 0, 500, accuracy: 1e-9)
        XCTAssertNil(stats.prefillTokensPerSecond(path: "cold"))
        for rate in [22.0, 25, 19, .nan, -3, 0] { stats.noteDecodeRate(rate) }
        XCTAssertEqual(stats.decodeTokensPerSecond ?? 0, 22, accuracy: 1e-9)
    }

    func testRestores() {
        var stats = FirstTokenStats()
        XCTAssertEqual(stats.restoreCount, 0)
        XCTAssertNil(stats.restorePercentile(50))
        for ms in [3, 8, 40, -5] { stats.noteRestore(milliseconds: ms) }
        XCTAssertEqual(stats.restoreCount, 4)
        XCTAssertEqual(stats.restorePercentile(50), 3, "0 3 8 40")
        XCTAssertEqual(stats.restorePercentile(100), 40)
        XCTAssertEqual(FirstTokenStats.meets(stats.restorePercentile(95), goal: FirstTokenTargets.restoreMs), true)
        XCTAssertNil(FirstTokenStats.meets(nil, goal: 1))
        XCTAssertEqual(FirstTokenStats.meets(701, goal: FirstTokenTargets.warmP50Ms), false)
    }

    func testTheStatsAreBounded() {
        var stats = FirstTokenStats()
        for ms in 0..<(FirstTokenStats.capacity + 50) { stats.add(sample(ms + 1, "warm")) }
        XCTAssertEqual(stats.count(path: nil), FirstTokenStats.capacity)
        XCTAssertEqual(stats.percentile(0, path: nil), 51, "the oldest went first")
    }

    func testASampleFromGenerationStats() {
        let kv = LiveGenerationStats(model: "Qwen3.5 4B", promptTokens: 230, cachedTokens: 6_100, generatedTokens: 40, firstTokenMs: 640,
                                     tokensPerSecond: 21, kvPath: "restored", prefixTokens: 4_300)
        XCTAssertEqual(FirstTokenSample(stats: kv, picture: false),
                       FirstTokenSample(milliseconds: 640, path: "restored", prefilled: 230, cached: 6_100, picture: false))
        XCTAssertEqual(FirstTokenSample(stats: kv, picture: false)?.signpostMetadata, "path=restored prefilled=230 cached=6100")
        // W2's engine reports no path: warm when it reused the cache, cold when not, picture with a look.
        var w2 = kv
        w2.kvPath = nil
        XCTAssertEqual(FirstTokenSample(stats: w2, picture: false)?.path, "warm")
        w2.cachedTokens = 0
        XCTAssertEqual(FirstTokenSample(stats: w2, picture: false)?.path, "cold")
        XCTAssertEqual(FirstTokenSample(stats: w2, picture: true)?.path, "picture")
        var pictured = kv
        pictured.kvPath = "picture"
        XCTAssertEqual(FirstTokenSample(stats: pictured, picture: false)?.picture, true)
        var none = kv
        none.firstTokenMs = 0
        XCTAssertNil(FirstTokenSample(stats: none, picture: false), "no first token, no sample")
    }

    func testTheTargets() {
        XCTAssertEqual(FirstTokenTargets.warmP50Ms, 700)
        XCTAssertEqual(FirstTokenTargets.warmWithCardsP50Ms, 1_000)
        XCTAssertEqual(FirstTokenTargets.warmP95Ms, 1_200)
        XCTAssertEqual(FirstTokenTargets.pictureP50Ms, 1_200)
        XCTAssertEqual(FirstTokenTargets.coldMs, 1_200)
        XCTAssertEqual(FirstTokenTargets.restoreMs, 50)
    }
}
