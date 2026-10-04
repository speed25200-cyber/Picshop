#if canImport(CoreML) && canImport(Vision) && canImport(CoreImage)
import XCTest
import CoreML
import PicshopCore
import PicshopIntent
@testable import PicshopImaging

/// The pinned mask models on CI (W2, §10): the packages `Scripts/fetch-mask-models.sh` downloaded and verified are
/// compiled here and run on the CPU (the VM has no Neural Engine). Skipped when `PICSHOP_MASK_MODELS` is unset;
/// failed, never skipped, when it is set and a package is missing, so a CI misconfiguration cannot pass silently.
enum PinnedModelPackages {
    /// The compiled packages of a pinned set, by package name.
    static func compiled(_ set: PinnedModelPackageSet) async throws -> [String: URL] {
        guard let root = ProcessInfo.processInfo.environment["PICSHOP_MASK_MODELS"], !root.isEmpty else {
            throw XCTSkip("PICSHOP_MASK_MODELS is not set: the pinned mask models are not on this machine")
        }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        var compiled: [String: URL] = [:]
        for package in set.packages {
            let candidates = [base.appendingPathComponent(package + ".mlpackage"),
                              base.appendingPathComponent(set.id).appendingPathComponent(package + ".mlpackage")]
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                XCTFail("PICSHOP_MASK_MODELS is set but \(package).mlpackage is missing under \(root)")
                throw PicshopError.modelUnavailable(set.id)
            }
            compiled[package] = try await MLModel.compileModel(at: source)
        }
        return compiled
    }

    static func load(_ url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    static func shape(_ description: MLFeatureDescription?) -> [Int]? {
        description?.multiArrayConstraint?.shape.map(\.intValue)
    }
}

final class SAMPipelineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SAMSegmenter.computeUnitsOverride = .cpuOnly
    }

    override func tearDown() {
        SAMSegmenter.computeUnitsOverride = nil
        super.tearDown()
    }

    func testTheModelsHaveTheDocumentedFeatures() async throws {
        let compiled = try await PinnedModelPackages.compiled(MaskModelCatalog.samTiny)
        let names = SAMSegmenter.packages()
        let encoderURL = try XCTUnwrap(compiled[names.encoder])
        let encoder = try PinnedModelPackages.load(encoderURL)
        let encoderImage = try XCTUnwrap(encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        XCTAssertEqual(encoderImage.pixelsWide, 1024)
        XCTAssertEqual(encoderImage.pixelsHigh, 1024)
        XCTAssertEqual(PinnedModelPackages.shape(encoder.modelDescription.outputDescriptionsByName["image_embedding"]), [1, 256, 64, 64])
        XCTAssertEqual(PinnedModelPackages.shape(encoder.modelDescription.outputDescriptionsByName["feats_s0"]), [1, 32, 256, 256])
        XCTAssertEqual(PinnedModelPackages.shape(encoder.modelDescription.outputDescriptionsByName["feats_s1"]), [1, 64, 128, 128])

        let promptURL = try XCTUnwrap(compiled[names.prompt])
        let prompt = try PinnedModelPackages.load(promptURL)
        XCTAssertNotNil(prompt.modelDescription.inputDescriptionsByName["points"])
        XCTAssertNotNil(prompt.modelDescription.inputDescriptionsByName["labels"])
        XCTAssertNotNil(prompt.modelDescription.outputDescriptionsByName["sparse_embeddings"])
        XCTAssertNotNil(prompt.modelDescription.outputDescriptionsByName["dense_embeddings"])

        let decoderURL = try XCTUnwrap(compiled[names.decoder])
        let decoder = try PinnedModelPackages.load(decoderURL)
        for input in ["image_embedding", "sparse_embedding", "dense_embedding", "feats_s0", "feats_s1"] {
            XCTAssertNotNil(decoder.modelDescription.inputDescriptionsByName[input], input)
        }
        XCTAssertEqual(PinnedModelPackages.shape(decoder.modelDescription.outputDescriptionsByName["low_res_masks"]), [1, 3, 256, 256])
        XCTAssertEqual(PinnedModelPackages.shape(decoder.modelDescription.outputDescriptionsByName["scores"]), [1, 3])
    }

    /// A red disc on a grey, lightly textured background.
    private func disc(width: Int, height: Int, centre: (Double, Double), radius: Double) -> (rgba: [UInt8], truth: [Bool]) {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var truth = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let dx = Double(x) - centre.0, dy = Double(y) - centre.1
                let inside = dx * dx + dy * dy <= radius * radius
                truth[y * width + x] = inside
                let noise = UInt8((x * 7 + y * 13) % 9)
                rgba[i] = inside ? 210 : 120 + noise
                rgba[i + 1] = inside ? 40 : 125 + noise
                rgba[i + 2] = inside ? 45 : 130 + noise
            }
        }
        return (rgba, truth)
    }

    func testABoxOnADiscFindsTheDiscAndASecondPromptEncodesNothing() async throws {
        let compiled = try await PinnedModelPackages.compiled(MaskModelCatalog.samTiny)
        let segmenter = SAMSegmenter(locate: { package in compiled[package] })
        let width = 512, height = 384
        let fixture = disc(width: width, height: height, centre: (220, 180), radius: 80)
        let box = PSRect(x: (220.0 - 90) / 512, y: (180.0 - 90) / 384, width: 180.0 / 512, height: 180.0 / 384)
        let output = try await segmenter.segment(rgba: fixture.rgba, width: width, height: height, key: "disc", prompts: [], box: box)
        var both = 0, either = 0
        for index in fixture.truth.indices {
            let selected = output.bytes[index] > 127
            if selected && fixture.truth[index] { both += 1 }
            if selected || fixture.truth[index] { either += 1 }
        }
        let iou = Double(both) / Double(max(1, either))
        XCTAssertGreaterThanOrEqual(iou, 0.85, "IoU \(iou)")
        let encodes = await segmenter.encodeCount
        XCTAssertEqual(encodes, 1)
        // A tap on the same picture state: no second encoding.
        _ = try await segmenter.segment(rgba: fixture.rgba, width: width, height: height, key: "disc",
                                        prompts: [MaskPrompt(PSPoint(x: 220.0 / 512, y: 180.0 / 384))], box: nil)
        let after = await segmenter.encodeCount
        XCTAssertEqual(after, 1)
        await segmenter.unload()
        let loaded = await segmenter.isLoaded
        XCTAssertFalse(loaded)
    }
}
#endif
