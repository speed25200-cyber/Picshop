import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D2 (§8.2): W1's selectiveAdjust lowered onto one local adjustment, flags on, SAM absent.
final class SelectiveLoweringTests: XCTestCase {
    static let oneFace = [PSRect(x: 0.4, y: 0.25, width: 0.15, height: 0.18)]
    static let twoFaces = [PSRect(x: 0.15, y: 0.25, width: 0.15, height: 0.18), PSRect(x: 0.6, y: 0.25, width: 0.15, height: 0.18)]

    static func services(faces: [PSRect]) -> OperationPhotoServices {
        var services = OperationPhotoServices()
        services.faces = faces
        services.masks = MaskSimulation(samInstalled: false, faces: faces, objects: [OperationFixtures.dog, OperationFixtures.person])
        return services
    }

    func run(_ text: String, services: some PhotoAIServices, on document: PhotoDocument = OperationFixtures.photo()) async throws
        -> (document: PhotoDocument, result: ExecutionResult) {
        let plan = RuleBasedIntentEngine().parse(text, context: IntentContext(mode: .photo))
        let intent = try XCTUnwrap(plan.intents.first, text)
        XCTAssertEqual(intent.action, .selectiveAdjust, text)
        let executor = PhotoCommandExecutor(services: services, language: .french)
        return await executor.execute(intent, on: document, context: OperationFixtures.photoContext(document))
    }

    static func hasLegacySelective(_ document: PhotoDocument) -> Bool {
        document.layers.flatMap(\.edits.operations).contains { operation in
            if case .selectiveAdjust = operation.kind { return true }
            return false
        }
    }

    static let phrases: [(text: String, region: MaskRegion)] = [("blanchis les dents", .teeth), ("lisse la peau", .faceSkin), ("éclaircis les yeux", .eyes)]

    func testTwoFacesAsk() async throws {
        for (text, _) in Self.phrases {
            let (after, result) = try await run(text, services: Self.services(faces: Self.twoFaces))
            guard case .needsClarification(let request) = result.outcome else { return XCTFail("\(text): \(result.outcome)") }
            XCTAssertEqual(request.candidates.count, 2, text)
            XCTAssertTrue(after.localAdjustments.isEmpty, text)
        }
    }

    func testOneFaceLowersOntoTheLandmarkMask() async throws {
        for (text, region) in Self.phrases {
            let (after, result) = try await run(text, services: Self.services(faces: Self.oneFace))
            XCTAssertTrue(result.outcome.isSuccess, "\(text): \(result.outcome)")
            XCTAssertEqual(after.localAdjustments.count, 1, text)
            let adjustment = try XCTUnwrap(after.localAdjustments.first)
            XCTAssertEqual(adjustment.region, region, text)
            guard case .raster(let raster)? = adjustment.stack.components.first?.kind else { return XCTFail("\(text): not a raster") }
            XCTAssertEqual(raster.origin, .facePart, "\(text): the landmark mask, never a person instance")
            XCTAssertNotEqual(raster.origin, .person)
            XCTAssertFalse(adjustment.adjustments.activeParameters.isEmpty, text)
            // The legacy op is not applied as well.
            XCTAssertFalse(Self.hasLegacySelective(after), text)
        }
    }

    func testTheTeethRuleDesaturates() async throws {
        let (after, _) = try await run("blanchis les dents", services: Self.services(faces: Self.oneFace))
        let teeth = try XCTUnwrap(after.localAdjustments.first)
        XCTAssertLessThan(teeth.adjustments[.saturation], 0, "the teeth rule's desaturation")
    }

    /// A host without mask rasters (FakePhotoServices): the W1 selectiveAdjust, exactly as before.
    func testWithoutMaskRastersTheLegacyStepApplies() async throws {
        let smile = ObjectCandidate(label: "teeth", boundingBox: PSRect(x: 0.45, y: 0.6, width: 0.1, height: 0.03), confidence: 0.9)
        let (after, result) = try await run("blanchis les dents", services: FakePhotoServices(candidates: [smile]))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertTrue(after.localAdjustments.isEmpty)
        XCTAssertTrue(Self.hasLegacySelective(after))
    }

    /// The sky (an AI region) needs no candidate: one local adjustment on the sky raster.
    func testTheSkyLowersOntoTheSkyMask() async throws {
        let (after, result) = try await run("éclaircis le ciel", services: Self.services(faces: Self.oneFace))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        let sky = try XCTUnwrap(after.localAdjustments.first)
        XCTAssertEqual(sky.region, .sky)
        XCTAssertGreaterThan(sky.adjustments[.exposure] + sky.adjustments[.brightness], 0)
    }
}
