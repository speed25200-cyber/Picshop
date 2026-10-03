#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Brush hardness reaches the picture: a hard brush paints a crisp edge, a soft one a wide falloff.
final class MaskHardnessTests: XCTestCase {
    private let side = 128

    /// The red channel along the middle row after painting white over black with one dot.
    private func paintedRow(hardness: Double) async throws -> [Int] {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(0, width: side, height: side), width: side, height: side)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let dot = BrushStroke(points: [PSPoint(x: 0.5, y: 0.5)], radius: 0.25, hardness: hardness)
        document.apply(.pixelPaint(strokes: [dot], color: .white))
        let rendered = try await fixture.renderer.renderedRGBA(document)
        let row = side / 2
        return (0..<side).map { Int(rendered.bytes[(row * side + $0) * 4]) }
    }

    /// Pixels between 5 % and 95 % of white on the way out from the centre.
    private func edgeWidth(_ row: [Int]) -> Int {
        row[(side / 2)...].filter { $0 > 12 && $0 < 243 }.count
    }

    func testHardAndSoftBrushesGiveTheirEdges() async throws {
        let hard = try await paintedRow(hardness: 1)
        let soft = try await paintedRow(hardness: 0)
        // 32 px radius: the hard dot is white to its edge and black past it, with at most two pixels between.
        XCTAssertGreaterThan(hard[side / 2 + 28], 243)
        XCTAssertLessThan(hard[side / 2 + 36], 12)
        XCTAssertLessThanOrEqual(edgeWidth(hard), 2)
        // The soft one fades over most of its radius.
        XCTAssertGreaterThanOrEqual(edgeWidth(soft), 20)
        XCTAssertLessThan(soft[side / 2 + 28], hard[side / 2 + 28])
        for x in (side / 2 + 1)..<side { XCTAssertLessThanOrEqual(soft[x], soft[x - 1] + 1, "the falloff never rises outwards") }
    }

    func testMaskStoreRasterizeHonoursHardness() {
        var hard = [UInt8](repeating: 0, count: side * side), soft = hard
        let stroke = { (h: Double) in BrushStroke(points: [PSPoint(x: 0.5, y: 0.5)], radius: 0.25, hardness: h) }
        MaskStore.rasterize(strokes: [stroke(1)], width: side, height: side, into: &hard)
        MaskStore.rasterize(strokes: [stroke(0)], width: side, height: side, into: &soft)
        let row = (side / 2) * side + side / 2
        XCTAssertEqual(hard[row + 20], 255)
        XCTAssertLessThan(soft[row + 20], 128)
        XCTAssertGreaterThan(soft[row + 20], 0)
    }
}
#endif
