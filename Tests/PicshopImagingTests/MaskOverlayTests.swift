#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// The mask and selection overlays (W2, D17, §6 item 4), read back from the renderer's one-hop API.
final class MaskOverlayTests: XCTestCase {
    private let width = 256, height = 192

    private var options: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true)
    }

    /// The left 40 % with a hard edge.
    private let leftBlock = MaskStack.single(MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.399, y: 0.5), end: PSPoint(x: 0.401, y: 0.5)))))

    private func fixture() throws -> MaskTestFixtures.Project {
        try MaskTestFixtures.project(rgba: MaskTestFixtures.colourful(width: width, height: height), width: width, height: height)
    }

    private func overlay(_ style: MaskOverlayStyle, _ fixture: MaskTestFixtures.Project, opacity: Double = 0.5) async throws -> [UInt8] {
        let request = MaskOverlayRequest(target: .stack(leftBlock), style: style, opacity: opacity)
        let rendered = try await fixture.renderer.renderedRGBA(fixture.document, options: options, overlay: request)
        XCTAssertEqual(rendered.width, width)
        return try XCTUnwrap(rendered.overlay)
    }

    func testTintAndRubylithAreComplements() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tint = try await overlay(.tint, fixture)
        let ruby = try await overlay(.rubylith, fixture)
        for (x, y) in [(20, 100), (230, 100), (50, 10), (200, 180)] {
            let i = (y * width + x) * 4 + 3
            XCTAssertEqual(Int(tint[i]) + Int(ruby[i]), 128, accuracy: 3, "the two alphas add up to the opacity at (\(x), \(y))")
        }
        XCTAssertGreaterThan(tint[(100 * width + 20) * 4 + 3], 120, "tint where the mask is")
        XCTAssertLessThan(tint[(100 * width + 230) * 4 + 3], 4)
        XCTAssertGreaterThan(ruby[(100 * width + 230) * 4 + 3], 120, "rubylith where it is not")
    }

    func testTheOutlineIsOneToThreePixelsWide() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outline = try await overlay(.outline, fixture)
        for y in [40, 96, 150] {
            var white = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                if outline[i + 3] > 128, outline[i] > 200, outline[i + 1] > 200, outline[i + 2] > 200 { white += 1 }
            }
            XCTAssertGreaterThanOrEqual(white, 1, "row \(y)")
            XCTAssertLessThanOrEqual(white, 3, "row \(y)")
        }
        // Nothing far from the edge.
        XCTAssertEqual(outline[(96 * width + 10) * 4 + 3], 0)
        XCTAssertEqual(outline[(96 * width + 200) * 4 + 3], 0)
    }

    func testBlackAndWhiteIsTheMaskAndOnBlackIsThePictureTimesTheMask() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bw = try await overlay(.blackAndWhite, fixture)
        XCTAssertGreaterThan(bw[(96 * width + 20) * 4], 250)
        XCTAssertLessThan(bw[(96 * width + 200) * 4], 5)
        XCTAssertEqual(bw[(96 * width + 200) * 4 + 3], 255, "opaque")
        let onBlack = try await overlay(.onBlack, fixture)
        let frame = try await fixture.renderer.renderedRGBA(fixture.document, options: options).bytes
        let inside = (96 * width + 20) * 4
        XCTAssertEqual(Int(onBlack[inside]), Int(frame[inside]), accuracy: 2, "the picture inside")
        XCTAssertLessThan(onBlack[(96 * width + 200) * 4], 3, "black outside")
    }

    func testTheSelectionOverlayFollowsItsCorners() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raster = try MaskTestFixtures.raster(in: fixture, width: 128, height: 96, origin: .selection) { _, _ in 1 }
        var document = fixture.document
        let baseID = try XCTUnwrap(document.baseLayerID)
        var reference = raster.maskReference
        reference.feather = 0.003
        document.setSelection(PhotoSelection(mask: reference, layerID: baseID, coverage: 0.25, pixelWidth: 128, pixelHeight: 96,
                                             corners: [PSPoint(x: 0.5, y: 0.5), PSPoint(x: 1, y: 0.5), PSPoint(x: 1, y: 1), PSPoint(x: 0.5, y: 1)]))
        let rendered = try await fixture.renderer.renderedRGBA(document, options: options,
                                                              overlay: MaskOverlayRequest(target: .selection, style: .blackAndWhite))
        let bw = try XCTUnwrap(rendered.overlay)
        XCTAssertGreaterThan(bw[(150 * width + 200) * 4], 250, "bottom-right quarter selected")
        XCTAssertLessThan(bw[(40 * width + 40) * 4], 5, "top-left not")
    }

    func testNoTargetMeansNoOverlay() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rendered = try await fixture.renderer.renderedRGBA(fixture.document, options: options,
                                                              overlay: MaskOverlayRequest(target: .localAdjustment(UUID())))
        XCTAssertNil(rendered.overlay)
        let selection = try await fixture.renderer.renderedRGBA(fixture.document, options: options, overlay: MaskOverlayRequest(target: .selection))
        XCTAssertNil(selection.overlay)
    }
}
#endif
