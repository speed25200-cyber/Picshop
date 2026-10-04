#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore
@testable import PicshopImaging

/// D14: a 6,000 × 4,000 document drawn in strips of 512 rows equals the whole render, with a Gaussian blur, a dissolve
/// layer and a perspective transform across the strip boundaries.
final class StripRenderTests: XCTestCase {
    private let width = 6_000, height = 4_000

    /// A 24 MP base: a checkerboard over a ramp, written once as JPEG (fast to write, eagerly decoded like a camera file).
    private func writeBase(to url: URL) throws {
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0.85, green: 0.35, blue: 0.2)
        checker.color1 = CIColor(red: 0.2, green: 0.45, blue: 0.8)
        checker.width = 61
        checker.sharpness = 1
        let ramp = CIFilter.linearGradient()
        ramp.point0 = .zero
        ramp.point1 = CGPoint(x: width, y: height)
        ramp.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        ramp.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let checkers = checker.outputImage, let shade = ramp.outputImage else { throw PicshopError.renderFailed("fixture") }
        try ImageSupport.write(shade.composited(over: checkers).cropped(to: rect), to: url, type: .jpeg, quality: 0.95)
    }

    func testStripsEqualTheWholeRender() async throws {
        let small = LayerFixtures.solid(0.5, 0.5, 0.5, width: 8, height: 8)
        let fixture = try LayerFixtures.project(width: 8, height: 8, base: small)
        defer { fixture.cleanup() }
        let path = "media/big.jpg"
        try writeBase(to: fixture.store.url(for: path, in: fixture.projectID))
        var document = PhotoDocument(title: "Bandes", baseImage: MediaAsset(kind: .image, relativePath: path,
                                                                            pixelSize: PSSize(width: Double(width), height: Double(height))))
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        // A Gaussian blur over a band that spans strips 3 to 5 (rows 1,200…2,800).
        var band = [UInt8](repeating: 0, count: 600 * 400)
        for y in 120..<280 { for x in 0..<600 { band[y * 600 + x] = 255 } }
        let mask = try MaskStore(store: fixture.store, projectID: fixture.projectID).save(bytes: band, width: 600, height: 400, source: .brush, feather: 0)
        document.apply(.blurRegion(mask, amount: 0.3), to: baseID)
        // A dissolve layer across the middle strips.
        let dots = try fixture.imageAsset(LayerFixtures.solid(0.95, 0.9, 0.1, width: 400, height: 400), width: 400, height: 400)
        document.layers.append(Layer(name: "Dissolution", content: .image(dots), transform: LayerTransform(center: PSPoint(x: 0.3, y: 0.5), scale: 0.5),
                                     opacity: 0.5, blendMode: .dissolve))
        // A perspective quad from row 600 to row 3,400.
        let card = try fixture.imageAsset(LayerFixtures.quadrants([(0.9, 0.1, 0.1), (0.1, 0.9, 0.1), (0.1, 0.1, 0.9), (0.9, 0.9, 0.9)], width: 300, height: 200),
                                          width: 300, height: 200)
        document.layers.append(Layer(name: "Perspective", content: .image(card),
                                     transform: LayerTransform(quad: [PSPoint(x: 0.55, y: 0.15), PSPoint(x: 0.9, y: 0.25),
                                                                      PSPoint(x: 0.85, y: 0.85), PSPoint(x: 0.6, y: 0.7)])))

        let strips = try await fixture.renderer.stripRendered(document, options: .full)
        let whole = try await fixture.renderer.stripRendered(document, options: .full, rowsPerStrip: nil)
        XCTAssertEqual(strips.width, width)
        XCTAssertEqual(strips.height, height)
        XCTAssertEqual(strips.strips, 8, "4,000 rows in strips of 512")
        XCTAssertEqual(whole.strips, 1)
        XCTAssertEqual(strips.bytes.count, whole.bytes.count)
        var worst = 0
        var worstIndex = 0
        strips.bytes.withUnsafeBufferPointer { a in
            whole.bytes.withUnsafeBufferPointer { b in
                for index in 0..<min(a.count, b.count) {
                    let difference = abs(Int(a[index]) - Int(b[index]))
                    if difference > worst {
                        worst = difference
                        worstIndex = index
                    }
                }
            }
        }
        let row = worstIndex / (width * 4)
        XCTAssertLessThanOrEqual(worst, 1, "strips equal the whole render (worst at row \(row))")
    }
}
#endif
