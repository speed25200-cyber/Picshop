import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// What holds from the phase 0 stubs on: the frozen defaults, the brain's
// identity, the catalog, and the scripted engine the brain tests rely on.

final class LocalBrainStubTests: XCTestCase {
    func testTextOnlyWeightsDoNotAskForPictures() {
        var info = LocalModelInfo.qwen2B
        info.supportsVision = false
        let brain = LocalModelLiveBrain(mode: .video, info: info, makeEngine: FakeEngineFactory().factory, fallback: nil)
        XCTAssertFalse(brain.capabilities.seesImages)
        XCTAssertTrue(brain.capabilities.opensSession)
    }

    func testFrozenDefaults() {
        let options = LocalGenerationOptions()
        XCTAssertEqual(options.maxTokens, 120)
        XCTAssertEqual(options.temperature, 0.55)
        XCTAssertEqual(options.topP, 0.8)
        XCTAssertEqual(options.topK, 20)
        XCTAssertEqual(options.presencePenalty, 0.3)
        let limits = LocalModelLiveBrain.Limits()
        XCTAssertEqual(limits.firstTokenTimeout, 6)
        XCTAssertEqual(limits.turnTimeout, 25)
        XCTAssertEqual(limits.maxRounds, 3)
        XCTAssertEqual(limits.maxApplyEdits, 2)
        XCTAssertEqual(limits.compactAt, 6_000)
        XCTAssertEqual(limits.maxImagesInContext, 2)
        XCTAssertEqual([limits.speechMaxTokens, limits.ideasMaxTokens, limits.hotMaxTokens], [120, 320, 80])
    }

    func testTierModelIDs() {
        XCTAssertEqual(LocalModelTiering.modelID(for: .max), "live-qwen35-4b")
        XCTAssertEqual(LocalModelTiering.modelID(for: .fast), "live-qwen35-2b")
        XCTAssertNil(LocalModelTiering.modelID(for: .unsupported))
        XCTAssertEqual(LocalModelQuality.allCases, [.auto, .max, .fast])
    }

    func testCatalogPinsBothModels() {
        XCTAssertEqual(LocalModelCatalog.all.map(\.info.id), ["live-qwen35-4b", "live-qwen35-2b"])
        XCTAssertEqual(LocalModelCatalog.max.repository, "mlx-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertEqual(LocalModelCatalog.max.info.revision, "32f3e8ecf65426fc3306969496342d504bfa13f3")
        XCTAssertEqual(LocalModelCatalog.max.info.promptSize, .full)
        XCTAssertEqual(LocalModelCatalog.fast.repository, "mlx-community/Qwen3.5-2B-MLX-4bit")
        XCTAssertEqual(LocalModelCatalog.fast.info.revision, "93760be4f1f69842a46bc13dbdc0f19e291392a3")
        XCTAssertEqual(LocalModelCatalog.fast.info.promptSize, .compact)
        XCTAssertTrue(LocalModelCatalog.all.allSatisfy { $0.info.contextTokens == 8_192 && $0.info.supportsVision })
        XCTAssertEqual(LocalModelCatalog.entry(for: .max), LocalModelCatalog.max)
        XCTAssertEqual(LocalModelCatalog.entry(for: .fast), LocalModelCatalog.fast)
        XCTAssertNil(LocalModelCatalog.entry(for: .unsupported))
        XCTAssertEqual(LocalModelCatalog.fileAllowlist.count, 10)
        XCTAssertTrue(LocalModelCatalog.isAllowed("model.safetensors"))
        XCTAssertFalse(LocalModelCatalog.isAllowed("README.md"))
        XCTAssertEqual(LocalModelCatalog.max.memoryNeededToLoad, 4_260_000_000)
        XCTAssertEqual(LocalModelCatalog.fast.storageNeededToDownload, 2_750_000_000)
        XCTAssertEqual(LocalModelCatalog.retiredModelIDs, ["qwen3-4b-4bit"])
    }

    func testScriptedEngineReplaysItsTurns() async throws {
        let stats = LiveGenerationStats(model: "Qwen3.5 4B", promptTokens: 40, cachedTokens: 2_000, generatedTokens: 6, firstTokenMs: 300, tokensPerSecond: 24)
        let call = LocalToolCall(id: "call_1", name: "undo", arguments: ["count": 1])
        let factory = FakeEngineFactory(scripts: [[[.text("Je reviens."), .toolCall(call), .finished(stats, .endOfTurn)]]])
        let setup = LocalChatSetup(system: "system", tools: LocalLivePrompt.toolSpecs(mode: .photo), history: [], imageMaxPixels: 196_608)
        let engine = try await factory.factory(setup)
        try await engine.prepare()
        var events: [LocalChatEvent] = []
        for try await event in engine.send([.user("c'est trop", imageJPEG: nil)], options: LocalGenerationOptions()) { events.append(event) }
        XCTAssertEqual(events, [.text("Je reviens."), .toolCall(call), .finished(stats, .endOfTurn)])
        let fake = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(fake.setup, setup)
        XCTAssertEqual(fake.sent, [[.user("c'est trop", imageJPEG: nil)]])
        XCTAssertEqual(fake.prepareCount, 1)
        await engine.close()
        XCTAssertTrue(fake.isClosed)
    }
}
