#if canImport(CoreML) && canImport(Vision) && canImport(CoreImage)
import XCTest
import CoreML
import PicshopCore
@testable import PicshopImaging

/// Depth Anything V2 Small on CI (W2, §10), with the packages `PICSHOP_MASK_MODELS` points at (see
/// `PinnedModelPackages`): skipped when it is unset, failed when it is set and the package is missing. CPU only.
final class DepthPipelineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DepthEstimator.computeUnitsOverride = .cpuOnly
    }

    override func tearDown() {
        DepthEstimator.computeUnitsOverride = nil
        super.tearDown()
    }

    func testTheModelHasTheDocumentedFeatures() async throws {
        let compiled = try await PinnedModelPackages.compiled(MaskModelCatalog.depthSmall)
        let modelURL = try XCTUnwrap(compiled[DepthEstimator.package])
        let model = try PinnedModelPackages.load(modelURL)
        let input = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        XCTAssertEqual(input.pixelsWide, DepthMath.modelWidth)
        XCTAssertEqual(input.pixelsHigh, DepthMath.modelHeight)
        let output = try XCTUnwrap(model.modelDescription.outputDescriptionsByName["depth"]?.imageConstraint)
        XCTAssertEqual(output.pixelsWide, DepthMath.modelWidth)
        XCTAssertEqual(output.pixelsHigh, DepthMath.modelHeight)
    }

    /// A floor of shrinking tiles towards a hazy horizon, under a plain sky: nearer at the bottom.
    private func floor(width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let horizon = Double(height) * 0.35
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if Double(y) < horizon {
                    rgba[i] = 170; rgba[i + 1] = 195; rgba[i + 2] = 230
                    continue
                }
                // Perspective: the tile size grows linearly with the distance below the horizon.
                let depth = (Double(y) - horizon + 1) / (Double(height) - horizon)
                let u = (Double(x) - Double(width) / 2) / depth, v = 1 / depth
                let checker = (Int((u / 24).rounded(.down)) + Int((v * 6).rounded(.down))) % 2 == 0
                let haze = 1 - depth
                let base: Double = checker ? 200 : 60
                let value = UInt8(min(255, base * (1 - 0.5 * haze) + 180 * 0.5 * haze))
                rgba[i] = value; rgba[i + 1] = value; rgba[i + 2] = UInt8(min(255, Int(value) + 10))
            }
        }
        return rgba
    }

    func testDepthOnAFloorGrowsTowardsTheCamera() async throws {
        let compiled = try await PinnedModelPackages.compiled(MaskModelCatalog.depthSmall)
        let estimator = DepthEstimator(locate: { package in compiled[package] })
        let width = 640, height = 480
        let depth = try await estimator.estimate(rgba: floor(width: width, height: height), width: width, height: height)
        XCTAssertEqual(depth.width, DepthMath.modelWidth)
        XCTAssertEqual(depth.height, DepthMath.modelHeight)
        // Mean depth of five bands below the horizon, top to bottom: monotone, near (1) at the bottom.
        let top = Int(Double(depth.height) * 0.4)
        let bands = 5
        var means: [Double] = []
        for band in 0..<bands {
            let y0 = top + (depth.height - top) * band / bands, y1 = top + (depth.height - top) * (band + 1) / bands
            var sum = 0.0, n = 0.0
            for y in y0..<y1 { for x in 0..<depth.width { sum += Double(depth.values[y * depth.width + x]); n += 1 } }
            means.append(sum / n)
        }
        for index in 1..<bands { XCTAssertGreaterThan(means[index], means[index - 1], "band \(index): \(means)") }
        let inferences = await estimator.inferenceCount
        XCTAssertEqual(inferences, 1)
    }

    func testAPortraitPictureComesBackPortrait() async throws {
        let compiled = try await PinnedModelPackages.compiled(MaskModelCatalog.depthSmall)
        let estimator = DepthEstimator(locate: { package in compiled[package] })
        let width = 300, height = 400
        let depth = try await estimator.estimate(rgba: floor(width: width, height: height), width: width, height: height)
        XCTAssertEqual(depth.width, DepthMath.modelHeight)
        XCTAssertEqual(depth.height, DepthMath.modelWidth)
        XCTAssertGreaterThan(depth.values.max() ?? 0, 0.9)
        XCTAssertLessThan(depth.values.min() ?? 1, 0.1)
    }
}
#endif
