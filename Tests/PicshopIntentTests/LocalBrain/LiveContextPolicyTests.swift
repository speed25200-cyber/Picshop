import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D23: the compaction limits per model and engine, and the suffix budgets.
final class LiveContextPolicyTests: XCTestCase {
    private let fourB = LocalModelCatalog.max.info
    private let twoB = LocalModelCatalog.fast.info

    private func limits(_ info: LocalModelInfo, _ engine: LocalEngineKind, _ media: Bool) -> LiveContextLimits {
        LiveContextPolicy.limits(for: info, engine: engine, mediaAppendVerified: media)
    }

    func testTheSixRows() {
        XCTAssertEqual(limits(fourB, .kvEngine, true), LiveContextLimits(compactAt: 9_500, maxImagesInContext: 5, firstLookMaxPixel: 768, verifyLookMaxPixel: 512))
        XCTAssertEqual(limits(fourB, .kvEngine, false), LiveContextLimits(compactAt: 9_500, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768))
        XCTAssertEqual(limits(fourB, .chatSession, false), LiveContextLimits(compactAt: 7_000, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768))
        XCTAssertEqual(limits(twoB, .kvEngine, true), LiveContextLimits(compactAt: 8_500, maxImagesInContext: 5, firstLookMaxPixel: 768, verifyLookMaxPixel: 512))
        XCTAssertEqual(limits(twoB, .kvEngine, false), LiveContextLimits(compactAt: 8_500, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768))
        XCTAssertEqual(limits(twoB, .chatSession, false), LiveContextLimits(compactAt: 7_000, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768))
    }

    func testChatSessionKeepsW2WhateverTheMediaBit() {
        // W2's engine rebuilds on every picture turn: its row never depends on the KV self-test.
        XCTAssertEqual(limits(fourB, .chatSession, true), LiveContextPolicy.chatSession)
        XCTAssertEqual(limits(twoB, .chatSession, true), LiveContextPolicy.chatSession)
        // And it is exactly the W2 brain's fixed limits.
        let w2 = LocalModelLiveBrain.Limits()
        XCTAssertEqual(LiveContextPolicy.chatSession.compactAt, w2.compactAt)
        XCTAssertEqual(LiveContextPolicy.chatSession.maxImagesInContext, w2.maxImagesInContext)
        XCTAssertFalse(w2.adaptive, "tests keep the fixed limits; the app sets adaptive")
    }

    func testAnUnknownModelGetsTheSmallerKVRow() {
        var other = fourB
        other.id = "live-other"
        XCTAssertEqual(limits(other, .kvEngine, true).compactAt, 8_500)
        XCTAssertEqual(limits(other, .chatSession, true).compactAt, 7_000)
    }

    func testTheKVRowsStayInsideTheMemoryBudget() {
        // D15: KV ≈ 32 KB a token for the 4B's attention layers; at compactAt plus a worst-case turn (a picture, three
        // generations of 320 tokens) it stays under 400 MB.
        let worstTurn = 192 + 3 * 320 + 1_000
        for info in [fourB, twoB] {
            for media in [true, false] {
                let row = limits(info, .kvEngine, media)
                XCTAssertLessThanOrEqual((row.compactAt + worstTurn) * 32 * 1_024, 400 * 1_048_576, "\(info.id) media \(media)")
                XCTAssertGreaterThan(row.compactAt, LiveContextPolicy.chatSession.compactAt, "KV compacts later than ChatSession")
                XCTAssertGreaterThanOrEqual(row.firstLookMaxPixel, row.verifyLookMaxPixel)
            }
        }
    }

    func testTheSuffixBudgets() {
        XCTAssertEqual(LiveContextPolicy.warmSuffixBudget, 250)
        XCTAssertEqual(LiveContextPolicy.warmSuffixBudgetWithCards, 450)
        XCTAssertLessThan(LiveContextPolicy.warmSuffixBudget, LiveContextPolicy.warmSuffixBudgetWithCards)
    }

    func testTheEngineKindDefaultsToChatSession() async {
        let engine = PlainEngine(info: fourB)
        XCTAssertEqual(engine.engineKind, .chatSession)
        XCTAssertFalse(engine.mediaAppendVerified)
        XCTAssertEqual(LocalEngineKind(rawValue: "kvEngine"), .kvEngine)
        XCTAssertEqual(LocalEngineKind.chatSession.rawValue, "chatSession")
    }
}

/// An engine that implements only W2's requirements: the W3 ones come from the protocol's defaults.
private struct PlainEngine: LocalChatEngine {
    let info: LocalModelInfo
    func prepare() async throws {}
    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func contextTokens() async -> Int { 0 }
    func close() async {}
}
