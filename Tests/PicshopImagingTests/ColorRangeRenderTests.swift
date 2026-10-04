#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Colour ranges on the GPU (W2, D5): six swatches, each found by its own preset and by a sample of itself, and
/// left alone by the others; the sampled colour is exactly what the range tests (pre-local, Lab from sRGB).
final class ColorRangeRenderTests: XCTestCase {
    private let width = 240, height = 160

    /// Six swatches side by side: red, orange, yellow, green, blue, magenta (sRGB).
    private let swatches: [(preset: ColorRangeSpec.Preset, rgb: (UInt8, UInt8, UInt8))] = [
        (.reds, (210, 30, 35)), (.oranges, (235, 120, 25)), (.yellows, (230, 210, 40)),
        (.greens, (50, 170, 60)), (.blues, (40, 80, 210)), (.magentas, (200, 40, 170)),
    ]

    private func fixture() throws -> MaskTestFixtures.Project {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let swatch = swatches[min(swatches.count - 1, x / (width / swatches.count))].rgb
                let i = (y * width + x) * 4
                rgba[i] = swatch.0
                rgba[i + 1] = swatch.1
                rgba[i + 2] = swatch.2
            }
        }
        return try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
    }

    private var options: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: false, allowExpensiveWork: true, includesLocalAdjustments: false)
    }

    /// The mask's mean over swatch `index` (its middle).
    private func level(_ mask: (values: [Float], width: Int, height: Int), swatch index: Int) -> Double {
        let band = width / swatches.count
        var sum = 0.0, n = 0.0
        for y in (height / 4)..<(height * 3 / 4) {
            for x in (index * band + band / 4)..<(index * band + band * 3 / 4) {
                sum += Double(mask.values[y * mask.width + x])
                n += 1
            }
        }
        return sum / n
    }

    func testEachPresetFindsItsSwatchOnly() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (index, swatch) in swatches.enumerated() {
            let stack = MaskStack.single(MaskComponent(.colorRange(ColorRangeSpec(preset: swatch.preset))))
            let mask = try await fixture.renderer.maskValues(stack, document: fixture.document, options: options)
            XCTAssertGreaterThan(level(mask, swatch: index), 0.8, "\(swatch.preset) finds its swatch")
            for other in swatches.indices where other != index {
                XCTAssertLessThan(level(mask, swatch: other), 0.2, "\(swatch.preset) leaves \(swatches[other].preset)")
            }
        }
    }

    func testASampledColourFindsItself() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let services = VisionPhotoServices(renderer: fixture.renderer, store: fixture.store, projectID: fixture.projectID)
        let band = 1.0 / Double(swatches.count)
        let points = swatches.indices.map { PSPoint(x: band * (Double($0) + 0.5), y: 0.5) }
        let samples = try await services.sampleColors(at: points, radius: 2, in: fixture.document)
        XCTAssertEqual(samples.count, swatches.count)
        for (index, sample) in samples.enumerated() {
            let stack = MaskStack.single(MaskComponent(.colorRange(ColorRangeSpec(samples: [sample], fuzziness: 0.2))))
            let mask = try await fixture.renderer.maskValues(stack, document: fixture.document, options: options)
            XCTAssertGreaterThan(level(mask, swatch: index), 0.95, "swatch \(index) found by its own sample")
            for other in swatches.indices where other != index {
                XCTAssertLessThan(level(mask, swatch: other), 0.05)
            }
        }
    }
}
#endif
