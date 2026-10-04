#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Shared fixtures for the W2 mask tests on macOS: a project whose base photo is given as gamma sRGB bytes, Lab
/// helpers and a seeded generator.
enum MaskTestFixtures {
    struct Project: Sendable {
        let renderer: PhotoRenderer
        let document: PhotoDocument
        let store: ProjectStore
        let projectID: UUID
        let root: URL

        var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }
    }

    static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

    /// A project on disk whose base photo is `rgba` (top-down, gamma sRGB).
    static func project(rgba: [UInt8], width: Int, height: Int) throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-masks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let projectID = UUID()
        try store.createPackage(for: projectID)
        let path = "media/base.png"
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: sRGB) else {
            throw PicshopError.renderFailed("fixture")
        }
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        let document = PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: path,
                                                                         pixelSize: PSSize(width: Double(width), height: Double(height))))
        let renderer = PhotoRenderer(store: store, projectID: projectID, inpainting: InpaintingPipeline())
        return Project(renderer: renderer, document: document, store: store, projectID: projectID, root: root)
    }

    /// Hues across, tones down, and four flat blocks: every range has something to find.
    static func colourful(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let hue = Double(x) / Double(width) * 6
                let value = 0.15 + 0.8 * (1 - Double(y) / Double(height))
                let sector = Int(hue) % 6, f = hue - Double(Int(hue))
                let rgb: (Double, Double, Double)
                switch sector {
                case 0: rgb = (1, f, 0)
                case 1: rgb = (1 - f, 1, 0)
                case 2: rgb = (0, 1, f)
                case 3: rgb = (0, 1 - f, 1)
                case 4: rgb = (f, 0, 1)
                default: rgb = (1, 0, 1 - f)
                }
                // Half saturation, so tones and colours mix.
                let r = (0.5 + 0.5 * rgb.0) * value, g = (0.5 + 0.5 * rgb.1) * value, b = (0.5 + 0.5 * rgb.2) * value
                bytes[i] = UInt8((r * 255).rounded())
                bytes[i + 1] = UInt8((g * 255).rounded())
                bytes[i + 2] = UInt8((b * 255).rounded())
            }
        }
        let blocks: [(Int, Int, UInt8, UInt8, UInt8)] = [(16, 16, 200, 40, 40), (64, 140, 40, 160, 60), (150, 30, 230, 200, 160), (200, 120, 30, 60, 180)]
        for block in blocks {
            for y in block.1..<min(height, block.1 + 24) {
                for x in block.0..<min(width, block.0 + 24) {
                    let i = (y * width + x) * 4
                    bytes[i] = block.2
                    bytes[i + 1] = block.3
                    bytes[i + 2] = block.4
                }
            }
        }
        return bytes
    }

    static func lab(_ rgba: [UInt8], _ index: Int) -> Selection.Lab {
        Selection.Lab.of(r: rgba[index * 4], g: rgba[index * 4 + 1], b: rgba[index * 4 + 2])
    }

    /// The mean Lab of the pixels where `inside(x, y)` holds.
    static func meanLab(_ rgba: [UInt8], width: Int, height: Int, where inside: (Int, Int) -> Bool) -> Selection.Lab {
        var l = 0.0, a = 0.0, b = 0.0, n = 0.0
        for y in 0..<height {
            for x in 0..<width where inside(x, y) {
                let lab = Self.lab(rgba, y * width + x)
                l += lab.l
                a += lab.a
                b += lab.b
                n += 1
            }
        }
        return n == 0 ? Selection.Lab(l: 0, a: 0, b: 0) : Selection.Lab(l: l / n, a: a / n, b: b / n)
    }

    /// A raster saved in the project: `value(x, y)` 0…1 at width × height (8-bit, or 16-bit as a depth map). Imported by
    /// default, so settled renders draw it as it is (AI origins are re-guided when much enlarged).
    static func raster(in project: Project, width: Int, height: Int, depth: Bool = false, origin: RasterRef.Origin = .imported,
                       value: (Int, Int) -> Double) throws -> RasterRef {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { values[y * width + x] = Float(value(x, y)) } }
        if depth { return try project.maskStore.saveDepth(values: values, width: width, height: height, stateKey: UUID().uuidString) }
        return try project.maskStore.saveRaster(bytes: values.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }, width: width, height: height, origin: origin)
    }

    /// SplitMix64: the same random stacks on every run.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The CPU reference's view of a test project: the base's sRGB bytes and the rasters' samples.
struct ReferencePixels: MaskPixelSource {
    let rgba: [UInt8]?
    let rasters: [String: FloatRaster]

    func samples(of raster: RasterRef) -> FloatRaster? { rasters[raster.path] }

    static func load(_ refs: [RasterRef], project: MaskTestFixtures.Project, rgba: [UInt8]) -> ReferencePixels {
        var rasters: [String: FloatRaster] = [:]
        for ref in refs {
            guard let image = project.maskStore.loadRaw(ref) else { continue }
            let extent = image.extent.integral
            guard let values = ImageSupport.rawGrayValues(of: image, rect: extent) else { continue }
            rasters[ref.path] = FloatRaster(width: Int(extent.width), height: Int(extent.height), values: values)
        }
        return ReferencePixels(rgba: rgba, rasters: rasters)
    }
}

/// The GPU rasterizer equals Core's CPU reference (`MaskRaster.render`, D1) on every component kind (W2, §6 item 2):
/// within mean 2/255 and max 8/255 outside a 2 px band around edges (colour-cube ranges: mean 3/255, and the max
/// also outside the colours the 48³ cube itself cannot follow), mask values raw (a soft 0.5 edge stays 0.5), clear
/// outside a warped raster never read as "nothing" (D5).
final class MaskRasterizerParityTests: XCTestCase {
    private let width = 256, height = 192

    private struct Comparison {
        var mean: Double
        var max: Double
    }

    /// Mean and max |gpu − cpu| outside a 2 px band around the reference's edges; the max also outside `cubeBand`.
    private func compare(_ gpu: [Float], _ cpu: [Float], cubeBand: [Bool]? = nil) -> Comparison {
        var edge = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = cpu[y * width + x]
                for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < width && ny < height {
                    if abs(v - cpu[ny * width + nx]) > 0.08 { edge[y * width + x] = true; edge[ny * width + nx] = true }
                }
            }
        }
        let band = grown(edge, by: 2)
        var sum = 0.0, worst = 0.0, n = 0.0
        for index in 0..<(width * height) where !band[index] {
            let d = Double(abs(gpu[index] - cpu[index]))
            sum += d
            if cubeBand?[index] != true { worst = Swift.max(worst, d) }
            n += 1
        }
        return Comparison(mean: n == 0 ? 0 : sum / n, max: worst)
    }

    /// `marked` grown by `radius` px (a square).
    private func grown(_ marked: [Bool], by radius: Int) -> [Bool] {
        var band = marked
        for y in 0..<height {
            for x in 0..<width where marked[y * width + x] {
                for dy in -radius...radius { for dx in -radius...radius {
                    let px = x + dx, py = y + dy
                    if px >= 0, px < width, py >= 0, py < height { band[py * width + px] = true }
                } }
            }
        }
        return band
    }

    /// The pixels where the GPU's range cube itself differs from the exact range by more than 4/255, grown by 2 px
    /// plus the stack's expand radius and 3σ of its feather (how far those differences travel).
    ///
    /// The GPU reads colour and luminance ranges through a `MaskRasterizer.cubeDimension`³ cube with trilinear
    /// interpolation (CIColorCube), the CPU reference evaluates the function exactly. Where a range's soft edge is
    /// narrower than a cube cell (a preset's hue edge at low chroma, a tight sample, near black) the cube is off by
    /// up to ~0.3 on a few per cent of colours, at any affordable dimension (64³ still ~0.25): that is the cube's
    /// accuracy, bounded on its own by MaskMathTests (mean and 95th percentile), not a GPU fault. The max bound here
    /// holds everywhere the cube can follow the function; the mean still covers every pixel.
    private func cubeBand(_ stack: MaskStack, rgba: [UInt8]) -> [Bool] {
        let n = MaskRasterizer.cubeDimension
        var marked = [Bool](repeating: false, count: width * height)
        for component in stack.components {
            let cube: [Float]
            let exact: (UInt8, UInt8, UInt8) -> Double
            switch component.kind {
            case .colorRange(let spec):
                cube = MaskMath.labCube(dimension: n) { lab, chroma, hue in MaskMath.colorRange(lab, chroma: chroma, hue: hue, spec) }
                exact = { r, g, b in MaskMath.colorRange(MaskMath.lab(bytes: r, g, b), spec) }
            case .luminanceRange(let spec):
                cube = MaskMath.cube(dimension: n) { r, g, b in
                    MaskMath.trapezoid(MaskMath.luma(r: r, g: g, b: b), low: spec.low, high: spec.high, feather: spec.feather)
                }
                exact = { r, g, b in
                    MaskMath.trapezoid(MaskMath.luma(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255),
                                       low: spec.low, high: spec.high, feather: spec.feather)
                }
            default:
                continue
            }
            for index in 0..<(width * height) where !marked[index] {
                let r = rgba[index * 4], g = rgba[index * 4 + 1], b = rgba[index * 4 + 2]
                let looked = Self.trilinear(cube, n: n, r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
                if abs(looked - exact(r, g, b)) > 4.0 / 255 { marked[index] = true }
            }
        }
        let longest = Double(max(width, height))
        let expand = stack.expand.isFinite ? abs(stack.expand) * MaskStack.expandRadiusFraction * longest : 0
        let sigma = stack.feather.isFinite ? max(0, stack.feather) * MaskStack.featherSigmaFraction * longest : 0
        return grown(marked, by: 2 + Int(expand.rounded(.up)) + Int((3 * sigma).rounded(.up)))
    }

    /// A cube in `MaskMath.cube`'s layout (R fastest, value in R) read at gamma sRGB (r, g, b) as CIColorCube reads it.
    private static func trilinear(_ cube: [Float], n: Int, r: Double, g: Double, b: Double) -> Double {
        func value(_ ri: Int, _ gi: Int, _ bi: Int) -> Double { Double(cube[((bi * n + gi) * n + ri) * 4]) }
        let scale = Double(n - 1)
        let fr = r * scale, fg = g * scale, fb = b * scale
        let r0 = min(Int(fr), n - 2), g0 = min(Int(fg), n - 2), b0 = min(Int(fb), n - 2)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)
        var sum = 0.0
        for (dr, wr) in [(0, 1 - tr), (1, tr)] {
            for (dg, wg) in [(0, 1 - tg), (1, tg)] {
                for (db, wb) in [(0, 1 - tb), (1, tb)] {
                    sum += value(r0 + dr, g0 + dg, b0 + db) * wr * wg * wb
                }
            }
        }
        return sum
    }

    private func gpuMask(_ stack: MaskStack, _ project: MaskTestFixtures.Project, settled: Bool = true) async throws -> [Float] {
        let options = PhotoRenderer.Options(targetLongestSide: Double(max(width, height)), includeOverlays: false, allowExpensiveWork: settled,
                                            includesLocalAdjustments: false)
        let mask = try await project.renderer.maskValues(stack, document: project.document, options: options)
        XCTAssertEqual(mask.width, width)
        XCTAssertEqual(mask.height, height)
        return mask.values
    }

    private func randomStack(_ random: inout MaskTestFixtures.Generator, rasters: [RasterRef], depth: RasterRef, colours: [LabColor]) -> MaskStack {
        func unit() -> Double { Double.random(in: 0...1, using: &random) }
        func point() -> PSPoint { PSPoint(x: Double.random(in: 0.05...0.95, using: &random), y: Double.random(in: 0.05...0.95, using: &random)) }
        var components: [MaskComponent] = []
        for _ in 0..<Int.random(in: 1...3, using: &random) {
            let kind: MaskComponent.Kind
            switch Int.random(in: 0..<7, using: &random) {
            case 0:
                var raster = rasters[Int.random(in: 0..<rasters.count, using: &random)]
                if unit() < 0.5 {
                    raster.corners = [PSPoint(x: 0.1 + 0.1 * unit(), y: 0.1), PSPoint(x: 0.9, y: 0.1 + 0.1 * unit()),
                                      PSPoint(x: 0.85, y: 0.9), PSPoint(x: 0.15, y: 0.85)]
                }
                kind = .raster(raster)
            case 1:
                let strokes = (0..<Int.random(in: 1...3, using: &random)).map { _ in
                    BrushStroke(points: [point(), point(), point()], radius: Double.random(in: 0.02...0.08, using: &random),
                                hardness: unit(), mode: unit() < 0.2 ? .subtract : .add, flow: unit() < 0.5 ? nil : Double.random(in: 0.3...1, using: &random))
                }
                kind = .brush(BrushSpec(strokes: strokes))
            case 2:
                kind = .linear(LinearGradientSpec(start: point(), end: point()))
            case 3:
                kind = .radial(RadialGradientSpec(center: point(), radiusX: Double.random(in: 0.08...0.4, using: &random),
                                                  radiusY: Double.random(in: 0.08...0.4, using: &random), rotation: Double.random(in: -90...90, using: &random),
                                                  feather: unit()))
            case 4:
                kind = unit() < 0.5
                    ? .colorRange(ColorRangeSpec(samples: [colours[Int.random(in: 0..<colours.count, using: &random)]], fuzziness: Double.random(in: 0.1...0.9, using: &random)))
                    : .colorRange(ColorRangeSpec(preset: ColorRangeSpec.Preset.allCases[Int.random(in: 0..<ColorRangeSpec.Preset.allCases.count, using: &random)]))
            case 5:
                let low = Double.random(in: 0...0.7, using: &random)
                kind = .luminanceRange(LuminanceRangeSpec(low: low, high: min(1, low + Double.random(in: 0.1...0.5, using: &random)), feather: Double.random(in: 0...0.3, using: &random)))
            default:
                let low = Double.random(in: 0...0.6, using: &random)
                kind = .depthRange(DepthRangeSpec(depth: depth, low: low, high: min(1, low + 0.3), feather: Double.random(in: 0...0.2, using: &random)))
            }
            let mode = CombineMode.allCases[Int.random(in: 0..<CombineMode.allCases.count, using: &random)]
            components.append(MaskComponent(kind, mode: mode, isInverted: unit() < 0.25, opacity: unit() < 0.7 ? 1 : 0.6))
        }
        return MaskStack(components: components, isInverted: unit() < 0.2, feather: unit() < 0.5 ? 0 : Double.random(in: 0...0.5, using: &random),
                         expand: unit() < 0.6 ? 0 : Double.random(in: -0.5...0.5, using: &random), density: unit() < 0.7 ? 1 : 0.7)
    }

    func testFortyRandomStacksMatchTheReference() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let disc = try MaskTestFixtures.raster(in: project, width: 200, height: 150) { x, y in
            let dx = Double(x) - 100, dy = Double(y) - 75
            return (dx * dx + dy * dy).squareRoot() < 50 ? 1 : 0
        }
        let soft = try MaskTestFixtures.raster(in: project, width: 160, height: 120) { x, _ in Double(x) / 159 }
        let depth = try MaskTestFixtures.raster(in: project, width: 518, height: 392, depth: true) { x, y in Double(x + y) / Double(518 + 392) }
        let colours = [(16, 16), (64, 140), (150, 30), (200, 120)].map { MaskTestFixtures.lab(rgba, ($0.1 + 4) * width + $0.0 + 4) }
            .map { LabColor(l: $0.l, a: $0.a, b: $0.b) }
        let reference = ReferencePixels.load([disc, soft, depth], project: project, rgba: rgba)
        var random = MaskTestFixtures.Generator(state: 0x5EED)
        var failures: [String] = []
        for index in 0..<40 {
            let stack = randomStack(&random, rasters: [disc, soft], depth: depth, colours: colours)
            let gpu = try await gpuMask(stack, project)
            let cpu = MaskRaster.render(stack, width: width, height: height, source: reference).values
            let ranged = stack.components.contains { $0.isPixelDependent }
            let result = compare(gpu, cpu, cubeBand: ranged ? cubeBand(stack, rgba: rgba) : nil)
            let meanLimit = ranged ? 3.0 / 255 : 2.0 / 255
            if result.mean > meanLimit || result.max > 8.0 / 255 {
                failures.append("stack \(index): mean \(result.mean * 255)/255, max \(result.max * 255)/255, \(stack.components.map(\.kind))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testASoftHalfRasterIsNotGammaShifted() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let half = try MaskTestFixtures.raster(in: project, width: 64, height: 48) { _, _ in 0.5 }
        let gpu = try await gpuMask(.single(MaskComponent(.raster(half))), project)
        let mean = gpu.reduce(0, +) / Float(gpu.count)
        XCTAssertEqual(Double(mean), 128.0 / 255, accuracy: 2.0 / 255, "0.5 stays 0.5, never 0.21 or 0.73")
        // The same through the interactive (unmaterialised) path.
        let live = try await gpuMask(.single(MaskComponent(.raster(half))), project, settled: false)
        XCTAssertEqual(Double(live.reduce(0, +) / Float(live.count)), 128.0 / 255, accuracy: 2.0 / 255)
    }

    func testASubtractedWarpedRasterLeavesTheMaskOutsideItsQuadAlone() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let full = try MaskTestFixtures.raster(in: project, width: 32, height: 24) { _, _ in 1 }
        var hole = try MaskTestFixtures.raster(in: project, width: 32, height: 24) { _, _ in 1 }
        hole.corners = [PSPoint(x: 0.3, y: 0.3), PSPoint(x: 0.7, y: 0.35), PSPoint(x: 0.65, y: 0.7), PSPoint(x: 0.35, y: 0.65)]
        let stack = MaskStack(components: [MaskComponent(.raster(full)), MaskComponent(.raster(hole), mode: .subtract)])
        let gpu = try await gpuMask(stack, project)
        XCTAssertGreaterThan(gpu[10 * width + 10], 0.99, "outside the quad: still 1")
        XCTAssertLessThan(gpu[(height / 2) * width + width / 2], 0.01, "inside: removed")
        let cpu = MaskRaster.render(stack, width: width, height: height, source: ReferencePixels.load([full, hole], project: project, rgba: rgba)).values
        let result = compare(gpu, cpu)
        XCTAssertLessThanOrEqual(result.mean, 2.0 / 255)
        XCTAssertLessThanOrEqual(result.max, 8.0 / 255)
    }

    /// Expand and contract at fractional radii (1.7 px, and 2.5 px then feathered) move a soft edge exactly as far as
    /// the reference's disk: a footprint half a pixel off shows as 11 to 15/255 on this ramp.
    func testAFractionalExpandOrContractMovesASoftEdgeLikeTheReferenceDisk() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let radial = MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.45), radiusX: 0.12, radiusY: 0.35, rotation: 57, feather: 0.65)))
        for (expand, feather) in [(0.33, 0.0), (-0.33, 0.0), (0.4855, 0.375), (-0.4855, 0.375)] {
            let stack = MaskStack(components: [radial], feather: feather, expand: expand)
            let gpu = try await gpuMask(stack, project)
            let cpu = MaskRaster.render(stack, width: width, height: height, source: ReferencePixels(rgba: rgba, rasters: [:])).values
            let result = compare(gpu, cpu)
            XCTAssertLessThanOrEqual(result.mean, 1.0 / 255, "expand \(expand), feather \(feather)")
            XCTAssertLessThanOrEqual(result.max, 6.0 / 255, "expand \(expand), feather \(feather)")
        }
    }

    func testADepthRangeOnASixteenBitRampMatches() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let ramp = try MaskTestFixtures.raster(in: project, width: 518, height: 392, depth: true) { x, _ in Double(x) / 517 }
        XCTAssertEqual(ramp.bitDepth, 16)
        let stack = MaskStack.single(MaskComponent(.depthRange(DepthRangeSpec(depth: ramp, low: 0.3, high: 0.6, feather: 0.1))))
        let gpu = try await gpuMask(stack, project)
        let cpu = MaskRaster.render(stack, width: width, height: height, source: ReferencePixels.load([ramp], project: project, rgba: rgba)).values
        let result = compare(gpu, cpu)
        XCTAssertLessThanOrEqual(result.mean, 2.0 / 255)
        XCTAssertLessThanOrEqual(result.max, 8.0 / 255)
        XCTAssertGreaterThan(gpu[(height / 2) * width + Int(0.45 * Double(width))], 0.95, "inside the range")
        XCTAssertLessThan(gpu[(height / 2) * width + 5], 0.05, "far below it")
    }

    func testUnsupportedComponentsAreSkippedAndEmptyStacksAreBlack() async throws {
        let rgba = MaskTestFixtures.colourful(width: width, height: height)
        let project = try MaskTestFixtures.project(rgba: rgba, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let empty = try await gpuMask(MaskStack(), project)
        XCTAssertEqual(empty.max() ?? 1, 0)
        let skipped = try await gpuMask(MaskStack(components: [MaskComponent(.unsupported("{\"type\":\"future\"}")),
                                                               MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))]),
                                        project)
        XCTAssertGreaterThan(skipped[(height / 2) * width + width / 2], 0.99)
        let inverted = try await gpuMask(MaskStack(isInverted: true), project)
        XCTAssertEqual(inverted.min() ?? 0, 1, accuracy: 1.0 / 255)
    }
}
#endif
