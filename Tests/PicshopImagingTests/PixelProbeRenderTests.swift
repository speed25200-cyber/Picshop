#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
import PicshopIntent
@testable import PicshopImaging

/// Pixel probes on real renders (W2, D14, §8.7): the calibration set. Correct local edits (every verifiable dial ×
/// both signs × five region kinds × four procedural pictures) must never read as failed; sabotaged ones (wrong
/// sign, wrong region, a leak, a no-op) are caught at least 90 % of the time. A probe never starts an expensive pass.
///
/// The verdict below mirrors §8.7's table (the thresholds `PixelPostconditions` applies in Intent); the renders, the
/// masks and the Lab statistics are the real ones.
final class PixelProbeRenderTests: XCTestCase {
    private let width = 256, height = 192

    // MARK: - Verdict (§8.7)

    enum Verdict: Equatable { case passed, failed(String), unverifiable }

    static func verdict(_ parameter: AdjustmentParameter, sign: Double, _ result: PixelProbeResult) -> Verdict {
        guard let before = result.before, let after = result.after else { return .unverifiable }
        let dIn = after.inside.meanL - before.inside.meanL
        let dOut = after.outside.meanL - before.outside.meanL
        if outsideWeightIsMeaningful(after), abs(dOut) > max(0.6, 0.25 * abs(dIn)) { return .failed("leaks outside the mask") }
        switch parameter {
        case .exposure, .brightness, .shadows, .highlights, .whites, .blacks:
            return sign * dIn >= 0.8 && sign * (dIn - dOut) >= 0.5 ? .passed : .failed("ΔL*in \(dIn)")
        case .contrast, .clarity:
            return sign * (after.inside.stdL - before.inside.stdL) >= 0.4 ? .passed : .failed("Δstd \(after.inside.stdL - before.inside.stdL)")
        case .saturation, .vibrance:
            return sign * (after.inside.meanChroma - before.inside.meanChroma) >= 0.8 ? .passed : .failed("ΔC* \(after.inside.meanChroma - before.inside.meanChroma)")
        case .temperature:
            return sign * (after.inside.meanB - before.inside.meanB) >= 0.5 ? .passed : .failed("Δb* \(after.inside.meanB - before.inside.meanB)")
        case .tint:
            return sign * (after.inside.meanA - before.inside.meanA) >= 0.5 ? .passed : .failed("Δa* \(after.inside.meanA - before.inside.meanA)")
        case .hue, .sharpness, .noiseReduction, .grain, .fade, .skinTone, .vignette:
            return .unverifiable
        }
    }

    static func outsideWeightIsMeaningful(_ regions: PixelStats.Regions) -> Bool { regions.outside.weight >= 50 }

    // MARK: - Fixtures

    /// Four procedural pictures, each with every tone and some colour in every region.
    private func picture(_ kind: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                // A tone ramp that repeats across the picture, so every region holds shadows to highlights.
                let tone = 0.1 + 0.8 * (0.5 + 0.5 * sin(Double(x + y * (kind + 1)) * 0.11))
                let rgb: (Double, Double, Double)
                switch kind {
                case 0: rgb = (tone * (0.8 + 0.2 * u), tone * 0.7, tone * (0.6 + 0.3 * v))
                case 1: rgb = (tone * 0.55, tone * (0.6 + 0.4 * v), tone * 0.9)
                case 2: rgb = (tone, tone * 0.85, tone * 0.5)
                default: rgb = (tone * (0.5 + 0.5 * v), tone * (0.9 - 0.4 * u), tone * 0.7)
                }
                rgba[i] = UInt8((min(1, rgb.0) * 255).rounded())
                rgba[i + 1] = UInt8((min(1, rgb.1) * 255).rounded())
                rgba[i + 2] = UInt8((min(1, rgb.2) * 255).rounded())
            }
        }
        return rgba
    }

    private func regions(_ project: MaskTestFixtures.Project, rgba: [UInt8]) throws -> [(name: String, stack: MaskStack)] {
        let disc = try MaskTestFixtures.raster(in: project, width: 128, height: 96) { x, y in
            let dx = Double(x) - 40, dy = Double(y) - 48
            return dx * dx + dy * dy < 900 ? 1 : 0
        }
        let sample = MaskTestFixtures.lab(rgba, (height / 2) * width + width / 2)
        return [
            ("AI raster", .single(MaskComponent(.raster(disc)))),
            ("linear", .single(MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0), end: PSPoint(x: 0.5, y: 0.45)))))),
            ("radial", .single(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.65, y: 0.6), radiusX: 0.2, radiusY: 0.15, feather: 0.3))))),
            ("luminance", .single(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.3, high: 0.7))))),
            ("colour", .single(MaskComponent(.colorRange(ColorRangeSpec(samples: [LabColor(l: sample.l, a: sample.a, b: sample.b)], fuzziness: 0.6))))),
        ]
    }

    private static let parameters: [AdjustmentParameter] = [.exposure, .brightness, .shadows, .highlights, .whites, .blacks,
                                                            .contrast, .clarity, .saturation, .vibrance, .temperature, .tint]

    /// An amount that moves each dial clearly (its range is −1…1 or 0…1).
    private static func amount(_ parameter: AdjustmentParameter, sign: Double) -> Double {
        switch parameter {
        case .clarity where sign < 0: return -0.8
        default: return 0.6 * sign
        }
    }

    // MARK: - The calibration set

    func testCorrectEditsNeverFailAndSabotagedOnesAreCaught() async throws {
        var correct = 0, falseFailures: [String] = []
        var sabotaged = 0, caught = 0
        var unverifiable = 0
        for kind in 0..<4 {
            let rgba = picture(kind)
            let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
            defer { try? FileManager.default.removeItem(at: project.root) }
            let services = VisionPhotoServices(renderer: project.renderer, store: project.store, projectID: project.projectID)
            let regionList = try regions(project, rgba: rgba)
            for (regionIndex, region) in regionList.enumerated() {
                for parameter in Self.parameters {
                    for sign in [1.0, -1.0] {
                        let id = UUID()
                        let edited = Adjustments([parameter: Self.amount(parameter, sign: sign)])
                        var after = project.document
                        after.setLocalAdjustment(LocalAdjustment(id: id, stack: region.stack, adjustments: edited))
                        let request = PixelProbeRequest(.maskedParameter, region: .localAdjustment(id))
                        let result = await services.pixelProbes([request], before: project.document, after: after).first
                        let verdict = result.map { Self.verdict(parameter, sign: sign, $0) } ?? .unverifiable
                        correct += 1
                        switch verdict {
                        case .failed(let why): falseFailures.append("picture \(kind), \(region.name), \(parameter) \(sign > 0 ? "+" : "−"): \(why)")
                        case .unverifiable: unverifiable += 1
                        case .passed: break
                        }
                        // Sabotage, one kind per case in turn, on a quarter of the cases.
                        guard (regionIndex + Self.parameters.firstIndex(of: parameter)! + kind) % 4 == 0 else { continue }
                        var broken = project.document
                        switch (regionIndex + kind) % 4 {
                        case 0:
                            // Wrong sign.
                            broken.setLocalAdjustment(LocalAdjustment(id: id, stack: region.stack, adjustments: Adjustments([parameter: -Self.amount(parameter, sign: sign)])))
                        case 1:
                            // Wrong region: the edit lands in another mask, the probe measures the one asked for.
                            broken.setLocalAdjustment(LocalAdjustment(id: id, stack: region.stack, adjustments: Adjustments()))
                            broken.setLocalAdjustment(LocalAdjustment(stack: regionList[(regionIndex + 2) % regionList.count].stack.inverted, adjustments: edited))
                        case 2:
                            // A leak: the edit applied to the whole picture.
                            broken.setLocalAdjustment(LocalAdjustment(id: id, stack: region.stack, adjustments: Adjustments()))
                            broken.apply(.adjustments(edited))
                        default:
                            // A no-op.
                            broken.setLocalAdjustment(LocalAdjustment(id: id, stack: region.stack, adjustments: Adjustments()))
                        }
                        let sabotage = await services.pixelProbes([request], before: project.document, after: broken).first
                        let judged = sabotage.map { Self.verdict(parameter, sign: sign, $0) } ?? .unverifiable
                        guard judged != .unverifiable else { continue }
                        sabotaged += 1
                        if case .failed = judged { caught += 1 }
                    }
                }
            }
            let inFlight = await project.renderer.hasHeavyWorkInFlight
            XCTAssertFalse(inFlight, "a probe never starts an expensive pass")
        }
        print("PROBES correct \(correct) (unverifiable \(unverifiable)), false failed \(falseFailures.count); sabotaged \(sabotaged), caught \(caught)")
        XCTAssertGreaterThanOrEqual(correct, 160)
        XCTAssertTrue(falseFailures.isEmpty, falseFailures.prefix(20).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(sabotaged, 40)
        XCTAssertGreaterThanOrEqual(Double(caught), 0.9 * Double(sabotaged))
    }

    func testExposureOnTheSkyOfASyntheticImage() async throws {
        // Sky (top 45 %) over ground; +0.5 exposure on a mask of the sky.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let sky = y < height * 45 / 100
                rgba[i] = sky ? 110 : 70
                rgba[i + 1] = sky ? 150 : 90
                rgba[i + 2] = sky ? 210 : 50
            }
        }
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let skyRaster = try MaskTestFixtures.raster(in: project, width: width, height: height, origin: .sky) { _, y in y < height * 45 / 100 ? 1 : 0 }
        let id = UUID()
        var after = project.document
        after.setLocalAdjustment(LocalAdjustment(id: id, region: .sky, stack: .single(MaskComponent(.raster(skyRaster))), adjustments: Adjustments([.exposure: 0.5])))
        let services = VisionPhotoServices(renderer: project.renderer, store: project.store, projectID: project.projectID)
        let result = await services.pixelProbes([PixelProbeRequest(.maskedParameter, region: .localAdjustment(id))], before: project.document, after: after)
        let probe = try XCTUnwrap(result.first)
        let before = try XCTUnwrap(probe.before), afterStats = try XCTUnwrap(probe.after)
        XCTAssertGreaterThanOrEqual(afterStats.inside.meanL - before.inside.meanL, 2)
        XCTAssertLessThanOrEqual(abs(afterStats.outside.meanL - before.outside.meanL), 0.5)
        XCTAssertEqual(before.coverage, 0.45, accuracy: 0.02)
    }

    func testMaskShapeProbesMeasureEachDocumentsOwnMask() async throws {
        let project = try MaskTestFixtures.project(rgba: picture(0), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let id = UUID()
        let radial = MaskStack.single(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, feather: 0))))
        var before = project.document
        before.setLocalAdjustment(LocalAdjustment(id: id, stack: radial, adjustments: Adjustments([.exposure: 0.3])))
        var grown = radial
        grown.expand = 0.5
        var after = before
        after.setLocalAdjustment(LocalAdjustment(id: id, stack: grown, adjustments: Adjustments([.exposure: 0.3])))
        let services = VisionPhotoServices(renderer: project.renderer, store: project.store, projectID: project.projectID)
        let result = await services.pixelProbes([PixelProbeRequest(.maskCoverage, region: .localAdjustment(id))], before: before, after: after)
        let probe = try XCTUnwrap(result.first)
        let coverageBefore = try XCTUnwrap(probe.before?.coverage), coverageAfter = try XCTUnwrap(probe.after?.coverage)
        XCTAssertGreaterThan(coverageAfter, coverageBefore + 0.002, "expand grew the mask")
        // A region missing on one side is unmeasured there.
        let removed = await services.pixelProbes([PixelProbeRequest(.maskCoverage, region: .localAdjustment(id))], before: project.document, after: after)
        XCTAssertNil(removed.first?.before)
        XCTAssertNotNil(removed.first?.after)
    }
}

private extension MaskStack {
    /// The complement (the « wrong region » sabotage).
    var inverted: MaskStack {
        var copy = self
        copy.isInverted.toggle()
        return copy
    }
}
#endif
