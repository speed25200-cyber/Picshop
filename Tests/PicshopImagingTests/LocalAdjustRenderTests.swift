#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Local adjustments render after the develop recipe, through their mask (W2, D2): inside changes, outside does not,
/// and amount 0 changes nothing.
final class LocalAdjustRenderTests: XCTestCase {
    private let width = 256, height = 192

    /// A mid-grey picture with a colour block on each side, so dials, curves, mixers and colour all have work.
    private func fixture() throws -> MaskTestFixtures.Project {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let block = (y / 32) % 2 == 0
                rgba[i] = block ? 180 : 110
                rgba[i + 1] = block ? 120 : 110
                rgba[i + 2] = block ? 70 : 110
            }
        }
        return try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
    }

    /// Full effect left of x = 0.45, none right of x = 0.5.
    private let leftHalf = MaskStack.single(MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.45, y: 0.5), end: PSPoint(x: 0.5, y: 0.5)))))

    private func render(_ document: PhotoDocument, _ project: MaskTestFixtures.Project) async throws -> [UInt8] {
        let options = PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true)
        return try await project.renderer.renderedSRGB(document, options: options).bytes
    }

    private func left(_ x: Int, _ y: Int) -> Bool { x < width * 40 / 100 }
    private func right(_ x: Int, _ y: Int) -> Bool { x > width * 55 / 100 }

    private func delta(_ a: [UInt8], _ b: [UInt8], where inside: (Int, Int) -> Bool) -> (dl: Double, de: Double) {
        let before = MaskTestFixtures.meanLab(a, width: width, height: height, where: inside)
        let after = MaskTestFixtures.meanLab(b, width: width, height: height, where: inside)
        return (after.l - before.l, after.distance(to: before))
    }

    func testExposureOnTheLeftHalfBrightensOnlyTheLeft() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let before = try await render(project.document, project)
        var document = project.document
        document.setLocalAdjustment(LocalAdjustment(stack: leftHalf, adjustments: Adjustments([.exposure: 0.5])))
        let after = try await render(document, project)
        XCTAssertGreaterThanOrEqual(delta(before, after, where: left).dl, 5)
        XCTAssertLessThanOrEqual(delta(before, after, where: right).de, 0.5)
    }

    func testCurveMixerAndColourActOnlyInside() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let before = try await render(project.document, project)
        let curve = ToneCurve(rgb: [ToneCurve.Point(0, 0), ToneCurve.Point(0.25, 0.4), ToneCurve.Point(0.5, 0.7), ToneCurve.Point(0.75, 0.9),
                                    ToneCurve.Point(1, 1)])
        // The HSL subset: every band to grey.
        let mixer = ColorMixer(saturation: [Double](repeating: -1, count: ColorMixer.Band.allCases.count))
        // « Couleur »: one wheel written to all three.
        let wheel = ColorWheel(hue: 220, amount: 0.8)
        let grade = ColorGrade(shadows: wheel, midtones: wheel, highlights: wheel)
        for (name, adjustment) in [("curve", LocalAdjustment(stack: leftHalf, curve: curve)),
                                   ("mixer", LocalAdjustment(stack: leftHalf, mixer: mixer)),
                                   ("colour", LocalAdjustment(stack: leftHalf, grade: grade))] {
            var document = project.document
            document.setLocalAdjustment(adjustment)
            let after = try await render(document, project)
            XCTAssertGreaterThan(delta(before, after, where: left).de, 2, "\(name) changes the inside")
            XCTAssertLessThanOrEqual(delta(before, after, where: right).de, 0.5, "\(name) leaves the outside")
        }
    }

    func testAmountZeroIsTheIdentity() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let before = try await render(project.document, project)
        var document = project.document
        document.setLocalAdjustment(LocalAdjustment(stack: leftHalf, adjustments: Adjustments([.exposure: 1, .saturation: 0.5]), amount: 0))
        let after = try await render(document, project)
        let worst = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 1)
    }

    func testHalfAmountIsHalfwayAndHiddenIsNothing() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let before = try await render(project.document, project)
        var full = project.document
        let id = UUID()
        full.setLocalAdjustment(LocalAdjustment(id: id, stack: leftHalf, adjustments: Adjustments([.exposure: 0.5])))
        var half = full
        half.setLocalAdjustment(LocalAdjustment(id: id, stack: leftHalf, adjustments: Adjustments([.exposure: 0.5]), amount: 0.5))
        var hidden = full
        hidden.setLocalAdjustment(LocalAdjustment(id: id, stack: leftHalf, adjustments: Adjustments([.exposure: 0.5]), isVisible: false))
        let fullRender = try await render(full, project)
        let halfRender = try await render(half, project)
        let hiddenRender = try await render(hidden, project)
        let fullDelta = delta(before, fullRender, where: left).dl
        let halfDelta = delta(before, halfRender, where: left).dl
        XCTAssertLessThan(halfDelta, fullDelta * 0.8)
        XCTAssertGreaterThan(halfDelta, fullDelta * 0.2)
        XCTAssertLessThanOrEqual(abs(delta(before, hiddenRender, where: left).dl), 0.3)
    }

    func testTheAnalysisImageHasNoLocalAdjustment() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(at: project.root) }
        var document = project.document
        document.setLocalAdjustment(LocalAdjustment(stack: leftHalf, adjustments: Adjustments([.exposure: 1])))
        let withLocals = PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true)
        var withoutLocals = withLocals
        withoutLocals.includesLocalAdjustments = false
        let drawn = try await project.renderer.renderedSRGB(document, options: withLocals).bytes
        let preLocal = try await project.renderer.renderedSRGB(document, options: withoutLocals).bytes
        let plain = try await project.renderer.renderedSRGB(project.document, options: withLocals).bytes
        XCTAssertEqual(preLocal, plain, "without local adjustments, the document renders as if it had none")
        XCTAssertNotEqual(drawn, plain)
    }
}

#endif
