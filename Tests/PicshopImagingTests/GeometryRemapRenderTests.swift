#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Masks follow geometry (W2, D3): a radial mask made before a crop, a quarter turn, a flip or a straighten lands
/// within 1.5 px of where the picture under it went. The reference is the renderer itself: a red dot painted at
/// the mask's centre is found again in the rendered output.
final class GeometryRemapRenderTests: XCTestCase {
    private let width = 256, height = 192
    private let centre = PSPoint(x: 0.3, y: 0.4)
    private let radius = 0.08

    private func fixture() throws -> MaskTestFixtures.Project {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let cx = centre.x * Double(width), cy = centre.y * Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let dot = dx * dx + dy * dy <= 9
                rgba[i] = dot ? 255 : 90
                rgba[i + 1] = dot ? 0 : 90
                rgba[i + 2] = dot ? 0 : 90
            }
        }
        return try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
    }

    private var full: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: nil, includeOverlays: true, allowExpensiveWork: true)
    }

    /// The centroid (pixels) of the red dot in a render.
    private func dot(in document: PhotoDocument, _ fixture: MaskTestFixtures.Project) async throws -> (x: Double, y: Double) {
        let render = try await fixture.renderer.renderedSRGB(document, options: full)
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<render.height {
            for x in 0..<render.width {
                let i = (y * render.width + x) * 4
                if render.bytes[i] > 180, render.bytes[i + 1] < 90, render.bytes[i + 2] < 90 {
                    sx += Double(x) + 0.5
                    sy += Double(y) + 0.5
                    n += 1
                }
            }
        }
        XCTAssertGreaterThan(n, 5, "the dot is still in the picture")
        return (sx / max(1, n), sy / max(1, n))
    }

    /// The centroid and equivalent radius (pixels) of a mask's pixels above 0.5.
    private func blob(_ mask: (values: [Float], width: Int, height: Int)) -> (x: Double, y: Double, radius: Double) {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.values[y * mask.width + x] > 0.5 {
                sx += Double(x) + 0.5
                sy += Double(y) + 0.5
                n += 1
            }
        }
        return (sx / max(1, n), sy / max(1, n), (n / .pi).squareRoot())
    }

    func testARadialMaskFollowsCropTurnFlipAndStraighten() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = MaskStack.single(MaskComponent(.radial(RadialGradientSpec(center: centre, radiusX: radius, radiusY: radius, feather: 0))))
        var made = fixture.document
        let id = UUID()
        made.setLocalAdjustment(LocalAdjustment(id: id, stack: stack, adjustments: Adjustments([.exposure: 0.2])))
        let originalMask = try await fixture.renderer.maskValues(stack, document: fixture.document, options: full)
        let original = blob(originalMask)
        let edits: [(String, EditOperation.Kind)] = [
            ("crop", .crop(PSRect(x: 0.1, y: 0.05, width: 0.65, height: 0.9))),
            ("rotate", .rotate(90)),
            ("flip", .flip(.horizontal)),
            ("straighten", .straighten(5)),
        ]
        for (name, edit) in edits {
            var remapped = made
            remapped.apply(edit)
            var plain = fixture.document
            plain.apply(edit)
            let expected = try await dot(in: plain, fixture)
            guard let moved = remapped.localAdjustments.first(where: { $0.id == id }) else {
                XCTFail("\(name): the adjustment survives the edit")
                continue
            }
            let movedMask = try await fixture.renderer.maskValues(moved.stack, document: remapped, options: full)
            let mask = blob(movedMask)
            XCTAssertEqual(mask.x, expected.x, accuracy: 1.5, "\(name): x")
            XCTAssertEqual(mask.y, expected.y, accuracy: 1.5, "\(name): y")
            XCTAssertEqual(mask.radius, original.radius, accuracy: 1.5, "\(name): the radius in pixels")
        }
    }
}
#endif
