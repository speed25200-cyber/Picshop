#if canImport(CoreImage) && canImport(Metal) && canImport(Vision)
import XCTest
import CoreImage
import PicshopCore
import PicshopIntent
@testable import PicshopImaging

/// The voice and Live wand (`select what: wand`, W2): VisionPhotoServices answers `wandMask` with the panel's Lab wand,
/// so « baguette magique ici » takes the touching region, not every alike colour of the photo.
final class WandServiceTests: XCTestCase {
    private let width = 240, height = 160

    /// Grey, with two identical red blocks apart: (20…80, 50…110) and (160…220, 50…110).
    private func fixture() throws -> MaskTestFixtures.Project {
        var rgba = [UInt8](repeating: 128, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i + 3] = 255
                guard y >= 50, y < 110, (x >= 20 && x < 80) || (x >= 160 && x < 220) else { continue }
                rgba[i] = 210
                rgba[i + 1] = 30
                rgba[i + 2] = 35
            }
        }
        return try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
    }

    func testContiguousTakesOneBlockAndGlobalTakesBoth() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let services = VisionPhotoServices(renderer: fixture.renderer, store: fixture.store, projectID: fixture.projectID)
        let seed = PSPoint(x: 50 / Double(width), y: 80 / Double(height))
        let block = 60.0 * 60.0 / Double(width * height)
        let touching = try await services.wandMask(at: seed, tolerance: 0.2, contiguous: true, sampleSize: 3, in: fixture.document)
        XCTAssertEqual(touching.coverage, block, accuracy: block * 0.3, "one block")
        XCTAssertFalse(touching.usedModel)
        XCTAssertEqual(touching.raster.origin, .selection)
        let alike = try await services.wandMask(at: seed, tolerance: 0.2, contiguous: false, sampleSize: 3, in: fixture.document)
        XCTAssertEqual(alike.coverage, 2 * block, accuracy: block * 0.6, "both blocks")
    }
}
#endif
