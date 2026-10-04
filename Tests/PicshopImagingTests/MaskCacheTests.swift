#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Mask caching (W2, D6): static stacks are materialised on settled renders only and kept; interactive frames never
/// materialise; while one local adjustment is edited, the others' masks are materialised once and reused.
final class MaskCacheTests: XCTestCase {
    private let width = 256, height = 192

    private var settled: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true, isDisplayed: true)
    }

    private func interactive(target: UUID? = nil) -> PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: false, interactionTarget: target)
    }

    private func project() throws -> MaskTestFixtures.Project {
        try MaskTestFixtures.project(rgba: MaskTestFixtures.colourful(width: width, height: height), width: width, height: height)
    }

    private func radial(feather: Double = 0.5) -> MaskStack {
        MaskStack(components: [MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.4, y: 0.5), radiusX: 0.25, radiusY: 0.2)))], feather: feather)
    }

    func testASecondSettledRenderMaterialisesNothing() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        document.setLocalAdjustment(LocalAdjustment(stack: radial(), adjustments: Adjustments([.exposure: 0.4])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let first = await fixture.renderer.maskMaterializations
        XCTAssertEqual(first, 1)
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let second = await fixture.renderer.maskMaterializations
        XCTAssertEqual(second, first, "0 materialisations on the second settled render")
    }

    func testAnInteractiveRenderMaterialisesNothing() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        document.setLocalAdjustment(LocalAdjustment(stack: radial(), adjustments: Adjustments([.exposure: 0.4])))
        for step in 0..<5 {
            document.setLocalAdjustment(LocalAdjustment(id: document.localAdjustments[0].id, stack: radial(feather: 0.1 * Double(step)),
                                                        adjustments: Adjustments([.exposure: 0.4])))
            _ = try await fixture.renderer.renderedSRGB(document, options: interactive())
        }
        let count = await fixture.renderer.maskMaterializations
        XCTAssertEqual(count, 0)
    }

    func testChangingTheFeatherMaterialisesOnce() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let id = UUID()
        document.setLocalAdjustment(LocalAdjustment(id: id, stack: radial(feather: 0.2), adjustments: Adjustments([.exposure: 0.4])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let before = await fixture.renderer.maskMaterializations
        document.setLocalAdjustment(LocalAdjustment(id: id, stack: radial(feather: 0.6), adjustments: Adjustments([.exposure: 0.4])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let after = await fixture.renderer.maskMaterializations
        XCTAssertEqual(after - before, 1)
    }

    func testALocalDialDragFreezesTheOtherMasksOnce() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        // Eight range masks and the one being edited (a radial).
        for index in 0..<8 {
            let low = Double(index) / 10
            let stack = index % 2 == 0
                ? MaskStack.single(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: low, high: low + 0.2))))
                : MaskStack.single(MaskComponent(.colorRange(ColorRangeSpec(preset: ColorRangeSpec.Preset.allCases[index % ColorRangeSpec.Preset.allCases.count]))))
            document.setLocalAdjustment(LocalAdjustment(stack: stack, adjustments: Adjustments([.saturation: 0.2 + 0.05 * Double(index)])))
        }
        let target = UUID()
        document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(), adjustments: Adjustments([.exposure: 0.1])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let start = await fixture.renderer.maskMaterializations
        for frame in 1...30 {
            document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(), adjustments: Adjustments([.exposure: 0.1 + 0.02 * Double(frame)])))
            _ = try await fixture.renderer.renderedSRGB(document, options: interactive(target: target))
        }
        let end = await fixture.renderer.maskMaterializations
        XCTAssertEqual(end - start, 8, "the eight other masks, once each, over 30 frames")
    }

    /// Eight range masks and the radial being dragged (`target`).
    private func rangeMasksAndATarget(_ document: inout PhotoDocument) -> UUID {
        for index in 0..<8 {
            let low = Double(index) / 10
            let stack = index % 2 == 0
                ? MaskStack.single(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: low, high: low + 0.2))))
                : MaskStack.single(MaskComponent(.colorRange(ColorRangeSpec(preset: ColorRangeSpec.Preset.allCases[index % ColorRangeSpec.Preset.allCases.count]))))
            document.setLocalAdjustment(LocalAdjustment(stack: stack, adjustments: Adjustments([.saturation: 0.2 + 0.05 * Double(index)])))
        }
        let target = UUID()
        document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(), adjustments: Adjustments([.exposure: 0.1])))
        return target
    }

    /// The pacer settles after 120 ms of stillness with the finger still down: that frame keeps the freeze (the
    /// other masks are not materialised again when the finger moves on) and never materialises the stack under it.
    func testAPauseMidDragKeepsTheFreeze() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let target = rangeMasksAndATarget(&document)
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let start = await fixture.renderer.maskMaterializations
        for frame in 1...10 {
            document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(), adjustments: Adjustments([.exposure: 0.1 + 0.02 * Double(frame)])))
            _ = try await fixture.renderer.renderedSRGB(document, options: interactive(target: target))
        }
        let paused = PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true, isDisplayed: true,
                                           interactionTarget: target)
        _ = try await fixture.renderer.renderedSRGB(document, options: paused)
        for frame in 11...20 {
            document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(feather: 0.02 * Double(frame)), adjustments: Adjustments([.exposure: 0.3])))
            _ = try await fixture.renderer.renderedSRGB(document, options: interactive(target: target))
        }
        let end = await fixture.renderer.maskMaterializations
        XCTAssertEqual(end - start, 8, "the eight other masks once each, the pause and the moving stack none")
    }

    /// More static masks than the settled budget holds (12 at 2048 × 1536, 6.3 MB each, 64 MB kept): a mask the frame
    /// uses is never evicted for another one, the rest draw live, and a second settled render materialises none.
    func testMoreMasksThanTheBudgetNeverThrash() async throws {
        let side = (width: 2048, height: 1536)
        var rgba = [UInt8](repeating: 140, count: side.width * side.height * 4)
        for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 255 }
        let fixture = try MaskTestFixtures.project(rgba: rgba, width: side.width, height: side.height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        for index in 0..<12 {
            let x = 0.05 + 0.07 * Double(index)
            let gradient = LinearGradientSpec(start: PSPoint(x: x, y: 0.2), end: PSPoint(x: x + 0.1, y: 0.8))
            document.setLocalAdjustment(LocalAdjustment(stack: MaskStack(components: [MaskComponent(.linear(gradient))], feather: 0.2),
                                                        adjustments: Adjustments([.exposure: 0.02 * Double(index + 1)])))
        }
        let options = PhotoRenderer.Options(targetLongestSide: Double(side.width), includeOverlays: true, allowExpensiveWork: true, isDisplayed: true)
        _ = try await fixture.renderer.renderedSRGB(document, options: options)
        let first = await fixture.renderer.maskMaterializations
        XCTAssertGreaterThan(first, 0)
        let held = await fixture.renderer.settledMaskBytes
        XCTAssertLessThanOrEqual(held, MaskRasterizer.settledByteLimit)
        _ = try await fixture.renderer.renderedSRGB(document, options: options)
        let second = await fixture.renderer.maskMaterializations
        XCTAssertEqual(second, first, "a second settled render materialises nothing")
    }

    /// A colour range previewed while its tolerance is dragged builds its cube in a scratch slot: the document's
    /// range masks keep theirs in the LRU (the settled frame after the drag builds none).
    func testAPreviewDragKeepsTheDocumentsCubes() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        for (index, preset) in [ColorRangeSpec.Preset.reds, .greens, .blues].enumerated() {
            document.setLocalAdjustment(LocalAdjustment(stack: .single(MaskComponent(.colorRange(ColorRangeSpec(preset: preset)))),
                                                        adjustments: Adjustments([.saturation: 0.1 * Double(index + 1)])))
        }
        // Another adjustment under the finger: the three range masks are frozen, so the preview frames never touch
        // their cubes, and only the scratch slot keeps them in the LRU.
        let target = UUID()
        document.setLocalAdjustment(LocalAdjustment(id: target, stack: radial(), adjustments: Adjustments([.exposure: 0.1])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let built = await fixture.renderer.maskCubeBuilds
        XCTAssertEqual(built, 3)
        for step in 0..<12 {
            let preview = MaskStack.single(MaskComponent(.colorRange(ColorRangeSpec(samples: [LabColor(l: 50, a: 40, b: 20)], fuzziness: 0.2 + 0.05 * Double(step)))))
            // Read back as bytes: the frame and overlay CIImages would cross out of the renderer actor.
            _ = try await fixture.renderer.renderedRGBA(document, options: interactive(target: target), overlay: MaskOverlayRequest(target: .stack(preview)))
        }
        let dragged = await fixture.renderer.maskCubeBuilds
        XCTAssertEqual(dragged - built, 12, "one cube per preview frame")
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let after = await fixture.renderer.maskCubeBuilds
        XCTAssertEqual(after, dragged, "the document's cubes were never pushed out")
    }

    func testMemoryTrimPurgesTheMasks() async throws {
        let fixture = try project()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        document.setLocalAdjustment(LocalAdjustment(stack: radial(), adjustments: Adjustments([.exposure: 0.4])))
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let held = await fixture.renderer.settledMaskBytes
        XCTAssertGreaterThan(held, 0)
        await fixture.renderer.trimForMemoryPressure()
        let trimmed = await fixture.renderer.settledMaskBytes
        XCTAssertEqual(trimmed, 0)
        let before = await fixture.renderer.maskMaterializations
        _ = try await fixture.renderer.renderedSRGB(document, options: settled)
        let after = await fixture.renderer.maskMaterializations
        XCTAssertEqual(after - before, 1, "drawn again after the purge")
    }
}
#endif
