#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Select & Mask on the GPU equals its CPU reference (W2, §6 item 9): within a mean of 3/255.
final class EdgeRefineGPUTests: XCTestCase {
    private let width = 200, height = 120

    /// A mask image from values (raw, row 0 at the top).
    private func image(_ values: [Float]) throws -> CIImage {
        let bytes = values.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        let cg = try XCTUnwrap(ImageSupport.grayImage(width: width, height: height, bytes: bytes, colorSpace: RenderContext.maskColorSpace))
        return ImageSupport.rawMaskImage(cg)
    }

    private func values(_ image: CIImage) throws -> [Float] {
        try XCTUnwrap(ImageSupport.rawGrayValues(of: image, rect: CGRect(x: 0, y: 0, width: width, height: height)))
    }

    /// A soft, slightly misplaced edge and a jagged one, the kind an AI mask or a lasso gives.
    private func roughMask() -> [Float] {
        (0..<(width * height)).map { index in
            let x = Double(index % width) + 0.5, y = index / width
            let edge = 98.5 + ((y / 3) % 2 == 0 ? 0.5 : -0.5)
            let t = ((x - edge) / 6 + 0.5).clamped(to: 0...1)
            return Float(t * t * (3 - 2 * t))
        }
    }

    private func meanDifference(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(a.count)
    }

    func testSmoothFeatherContrastAndShiftMatchTheReference() throws {
        let rough = roughMask()
        let flat = [Float](repeating: 0.5, count: width * height)
        let guide = try image(flat)
        for refinement in [SelectionRefinement(radius: 0, smooth: 1), SelectionRefinement(radius: 0, feather: 0.6),
                           SelectionRefinement(radius: 0, contrast: 0.7), SelectionRefinement(radius: 0, shiftEdge: -0.6),
                           SelectionRefinement(radius: 0, smooth: 0.4, feather: 0.3, contrast: 0.3, shiftEdge: 0.2)] {
            let roughImage = try image(rough)
            let gpu = try values(EdgeRefine.refine(roughImage, guide: guide, refinement: refinement))
            let cpu = EdgeRefineReference.refine(mask: rough, guide: flat, width: width, height: height, refinement: refinement)
            XCTAssertLessThanOrEqual(meanDifference(gpu, cpu), 3.0 / 255, "\(refinement)")
        }
    }

    func testTheGuidedFilterMatchesTheReferenceOnATwoToneGuide() throws {
        // Two tones: any guide encoding is an affine map of the other, which the guided filter does not see.
        let guideValues = (0..<(width * height)).map { Float(($0 % width) < 100 ? 0.15 : 0.85) }
        let refinement = SelectionRefinement(radius: 1, contrast: 0.2)
        let roughImage = try image(roughMask())
        let guideImage = try image(guideValues)
        let gpu = try values(EdgeRefine.refine(roughImage, guide: guideImage, refinement: refinement))
        let cpu = EdgeRefineReference.refine(mask: roughMask(), guide: guideValues, width: width, height: height, refinement: refinement)
        XCTAssertLessThanOrEqual(meanDifference(gpu, cpu), 3.0 / 255)
        // The refined edge sits on the guide's within a pixel, on every row.
        for y in stride(from: 5, to: height - 5, by: 10) {
            var crossing: Int?
            for x in 1..<width where crossing == nil && gpu[y * width + x - 1] < 0.5 && gpu[y * width + x] >= 0.5 { crossing = x }
            let found = try XCTUnwrap(crossing, "row \(y)")
            XCTAssertEqual(Double(found), 100, accuracy: 1.5, "row \(y)")
        }
    }

    func testDecontaminationMovesTheFringeTowardsTheSubject() throws {
        // A red subject on green with a half-transparent band of mixed colour, 8 px wide: its middle (x = 100) is
        // 2σ (σ = 0.01 × 200) from the nearest hard-foreground pixel, within the blur's reach as the reference has it.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var alpha = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let a: Float = x < 96 ? 1 : (x < 104 ? Float(104 - x) / 8 : 0)
                alpha[y * width + x] = a
                let i = (y * width + x) * 4
                rgba[i] = UInt8((Float(220) * a + 30 * (1 - a)).rounded())
                rgba[i + 1] = UInt8((Float(30) * a + 200 * (1 - a)).rounded())
                rgba[i + 2] = 40
            }
        }
        let picture = try XCTUnwrap(ImageSupport.ciImage(rgba: rgba, width: width, height: height, colorSpace: MaskTestFixtures.sRGB))
        let alphaImage = try image(alpha)
        let cleaned = EdgeRefine.decontaminate(picture, alpha: alphaImage, amount: 1)
        let out = try XCTUnwrap(ImageSupport.rgbaBytes(of: cleaned, rect: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: MaskTestFixtures.sRGB))
        let edge = ((height / 2) * width + 100) * 4
        XCTAssertGreaterThan(Int(out[edge]), Int(rgba[edge]) + 40, "redder on the fringe")
        XCTAssertLessThan(Int(out[edge + 1]), Int(rgba[edge + 1]) - 40, "less green")
        let outside = ((height / 2) * width + 180) * 4
        XCTAssertEqual(Int(out[outside + 1]), Int(rgba[outside + 1]), accuracy: 2, "the background keeps its colour")
        let unchanged = EdgeRefine.decontaminate(picture, alpha: alphaImage, amount: 0)
        XCTAssertTrue(unchanged === picture, "amount 0 is the same image")
    }
}
#endif
