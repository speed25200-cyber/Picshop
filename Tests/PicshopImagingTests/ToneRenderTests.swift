#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import PicshopCore
@testable import PicshopImaging

/// Pictures and projects for the tone, blend and stroke tests.
enum ToneTestImages {
    /// A 256 × 1 grey ramp, value = column, in gamma-encoded Display P3.
    static func ramp() -> CIImage? {
        var bytes = [UInt8](repeating: 255, count: 256 * 4)
        for x in 0..<256 { for c in 0..<3 { bytes[x * 4 + c] = UInt8(x) } }
        return ImageSupport.ciImage(rgba: bytes, width: 256, height: 1, colorSpace: RenderContext.colorSpace)
    }

    /// An opaque solid colour from 8-bit Display P3 values.
    static func solid(_ rgb: BlendMath.RGB, side: Int = 8) -> CIImage {
        let color = CIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1, colorSpace: RenderContext.colorSpace) ?? CIColor(red: rgb.r, green: rgb.g, blue: rgb.b)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// Top-down RGBA8 bytes in Display P3.
    static func bytes(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        ImageSupport.rgbaBytes(of: image, rect: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: RenderContext.colorSpace) ?? []
    }

    /// A project on disk whose base photo is `rgba` (top-down, Display P3), with its renderer.
    static func project(rgba: [UInt8], width: Int, height: Int) throws -> (renderer: PhotoRenderer, document: PhotoDocument, store: ProjectStore, projectID: UUID, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-tone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let projectID = UUID()
        try store.createPackage(for: projectID)
        let path = "media/base.png"
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: RenderContext.colorSpace) else {
            throw PicshopError.renderFailed("fixture")
        }
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        let document = PhotoDocument(title: "Tone", baseImage: MediaAsset(kind: .image, relativePath: path, pixelSize: PSSize(width: Double(width), height: Double(height))))
        let renderer = PhotoRenderer(store: store, projectID: projectID, inpainting: InpaintingPipeline())
        return (renderer, document, store, projectID, root)
    }

    /// A flat grey photo.
    static func grey(_ value: UInt8, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) { for c in 0..<3 { bytes[index * 4 + c] = value } }
        return bytes
    }
}

/// Levels and curves on the GPU match the Core tone table, channel by channel; a look's
/// 5-point curve still renders exactly as Core Image's tone curve did before W1.
final class ToneRenderTests: XCTestCase {
    private typealias P = ToneCurve.Point

    private func assertRampMatches(_ lut: ToneLUT, tolerance: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let ramp = try XCTUnwrap(ToneTestImages.ramp())
        let bytes = ToneTestImages.bytes(ToneRenderer.apply(lut, to: ramp), width: 256, height: 1)
        XCTAssertEqual(bytes.count, 256 * 4, file: file, line: line)
        var worst = 0
        for x in 0..<256 {
            let input = Double(x) / 255
            for (offset, channel) in [ToneCurve.Channel.red, .green, .blue].enumerated() {
                let expected = Int((lut.value(input, channel: channel) * 255).rounded())
                let got = Int(bytes[x * 4 + offset])
                worst = max(worst, abs(got - expected))
                XCTAssertEqual(got, expected, accuracy: tolerance, "\(channel) at \(x)", file: file, line: line)
            }
        }
        print("TONE-RAMP worst difference \(worst)/255")
    }

    func testARampThroughTheRendererMatchesTheToneTable() throws {
        var curve = ToneCurve.identity
        curve.setPoints([P(0, 0), P(0.25, 0.15), P(0.6, 0.7), P(1, 1)], for: .rgb)
        curve.setPoints([P(0, 0.05), P(1, 0.95)], for: .blue)
        let levels = Levels(rgb: Levels.Channel(inBlack: 0.05, inWhite: 0.9, gamma: 1.3), green: Levels.Channel(outWhite: 0.92))
        try assertRampMatches(ToneLUT.make(levels: levels, curve: curve), tolerance: 2)
        // A plain S curve and a strong gamma too.
        var s = ToneCurve.identity
        s.setPoints(ToneCurve.Preset.strongS.points(strength: 1), for: .rgb)
        try assertRampMatches(ToneLUT.make(levels: .identity, curve: s), tolerance: 2)
        try assertRampMatches(ToneLUT.make(levels: Levels(rgb: Levels.Channel(gamma: 2.2)), curve: .identity), tolerance: 2)
    }

    func testARedOnlyCurveLeavesGreenAndBlueAlone() throws {
        var curve = ToneCurve.identity
        curve.setPoints([P(0, 0), P(0.5, 0.8), P(1, 1)], for: .red)
        let ramp = try XCTUnwrap(ToneTestImages.ramp())
        let bytes = ToneTestImages.bytes(ToneRenderer.apply(ToneLUT.make(levels: .identity, curve: curve), to: ramp), width: 256, height: 1)
        for x in 0..<256 {
            XCTAssertEqual(Int(bytes[x * 4 + 1]), x, accuracy: 1, "green at \(x)")
            XCTAssertEqual(Int(bytes[x * 4 + 2]), x, accuracy: 1, "blue at \(x)")
        }
        XCTAssertGreaterThan(Int(bytes[128 * 4]), 128 + 40, "red is lifted")
    }

    func testAnIdentityTableDrawsNothing() throws {
        let ramp = try XCTUnwrap(ToneTestImages.ramp())
        XCTAssertTrue(ToneRenderer.apply(ToneLUT.make(levels: .identity, curve: .identity), to: ramp) === ramp)
    }

    func testALooksFivePointCurveRendersAsBefore() throws {
        // What AdjustmentPipeline did before W1 for a look's curve: CIToneCurve with its five points.
        let ramp = try XCTUnwrap(ToneTestImages.ramp())
        for curve in [ToneCurve.sCurve(strength: 0.7), .matte(lift: 0.8), .matte(lift: 0.35)] {
            let filter = CIFilter.toneCurve()
            filter.inputImage = ramp
            filter.point0 = CGPoint(x: curve.rgb[0].input, y: curve.rgb[0].output)
            filter.point1 = CGPoint(x: curve.rgb[1].input, y: curve.rgb[1].output)
            filter.point2 = CGPoint(x: curve.rgb[2].input, y: curve.rgb[2].output)
            filter.point3 = CGPoint(x: curve.rgb[3].input, y: curve.rgb[3].output)
            filter.point4 = CGPoint(x: curve.rgb[4].input, y: curve.rgb[4].output)
            let before = ToneTestImages.bytes(try XCTUnwrap(filter.outputImage), width: 256, height: 1)
            let now = ToneTestImages.bytes(AdjustmentPipeline.apply(.neutral, toneCurve: curve, to: ramp), width: 256, height: 1)
            for index in before.indices { XCTAssertEqual(Int(now[index]), Int(before[index]), accuracy: 1, "byte \(index)") }
        }
    }

    func testFadeStillAppliesUnderACurveOfAnotherShape() throws {
        // Before W1 a curve without five points reset the adjustments' tone (fade, blacks…) too.
        let ramp = try XCTUnwrap(ToneTestImages.ramp())
        let odd = ToneCurve(rgb: [P(0, 0), P(1, 1)])
        let faded = ToneTestImages.bytes(AdjustmentPipeline.apply(Adjustments([.fade: 1]), toneCurve: odd, to: ramp), width: 256, height: 1)
        XCTAssertGreaterThan(faded[0], 10, "fade lifts the blacks")
    }

    func testTheRendererAppliesTheLayersLevels() async throws {
        let width = 32, height = 8
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 { rgba[(y * width + x) * 4 + c] = UInt8(x * 8) } } }
        let fixture = try ToneTestImages.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let plain = try await fixture.renderer.renderedRGBA(document)
        // Levels' white point at 128 doubles every value below it.
        document.apply(.levels(Levels(rgb: Levels.Channel(inWhite: 128.0 / 255))))
        let leveled = try await fixture.renderer.renderedRGBA(document)
        for x in 0..<16 {
            let before = Int(plain.bytes[x * 4]), after = Int(leveled.bytes[x * 4])
            XCTAssertEqual(after, min(255, Int((Double(before) * 255 / 128).rounded())), accuracy: 2, "column \(x)")
        }
    }
}
#endif
