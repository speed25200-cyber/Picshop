#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// W3 test fixtures shared by the layer, snapshot and export tests: a project on disk with its renderer, image
/// assets and mask rasters written into it, and byte helpers (premultiplied readbacks turned straight).
enum LayerFixtures {
    struct Project: Sendable {
        let renderer: PhotoRenderer
        var document: PhotoDocument
        let store: ProjectStore
        let projectID: UUID
        let root: URL
        let width: Int
        let height: Int

        /// An image asset under media/ from top-down premultiplied RGBA8 bytes (Display P3).
        func imageAsset(_ rgba: [UInt8], width: Int, height: Int, name: String = UUID().uuidString) throws -> MediaAsset {
            let path = "media/\(name).png"
            guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: RenderContext.colorSpace) else {
                throw PicshopError.renderFailed("fixture")
            }
            try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
            return MediaAsset(kind: .image, relativePath: path, pixelSize: PSSize(width: Double(width), height: Double(height)))
        }

        /// A mask raster (raw 8-bit values, row 0 at the top).
        func raster(_ bytes: [UInt8], width: Int, height: Int) throws -> RasterRef {
            try MaskStore(store: store, projectID: projectID).saveRaster(bytes: bytes, width: width, height: height, origin: .brush)
        }

        func stack(_ bytes: [UInt8], width: Int, height: Int) throws -> MaskStack {
            MaskStack(components: [MaskComponent(.raster(try raster(bytes, width: width, height: height)))])
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A project whose base photo is `base` (premultiplied RGBA8, Display P3).
    static func project(width: Int, height: Int, base: [UInt8], inpainting: InpaintingPipeline = InpaintingPipeline()) throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-w3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let projectID = UUID()
        try store.createPackage(for: projectID)
        let path = "media/base.png"
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: base, colorSpace: RenderContext.colorSpace) else {
            throw PicshopError.renderFailed("fixture")
        }
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        let document = PhotoDocument(title: "Layers", baseImage: MediaAsset(kind: .image, relativePath: path, pixelSize: PSSize(width: Double(width), height: Double(height))))
        let renderer = PhotoRenderer(store: store, projectID: projectID, inpainting: inpainting)
        return Project(renderer: renderer, document: document, store: store, projectID: projectID, root: root, width: width, height: height)
    }

    /// A solid colour (straight 0…1 values) as premultiplied RGBA8 bytes.
    static func solid(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, width: Int, height: Int) -> [UInt8] {
        let pixel = premultipliedPixel(r, g, b, alpha)
        return Array([[UInt8]](repeating: pixel, count: width * height).joined())
    }

    static func premultipliedPixel(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> [UInt8] {
        func byte(_ v: Double) -> UInt8 { UInt8(clamping: Int((v * 255).rounded())) }
        return [byte(r * a), byte(g * a), byte(b * a), byte(a)]
    }

    /// Four quadrants of colours (top-left, top-right, bottom-left, bottom-right), opaque.
    static func quadrants(_ colors: [(Double, Double, Double)], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let c = colors[index % colors.count]
                let pixel = premultipliedPixel(c.0, c.1, c.2, 1)
                for k in 0..<4 { bytes[(y * width + x) * 4 + k] = pixel[k] }
            }
        }
        return bytes
    }

    /// Straight RGBA 0…1 from premultiplied RGBA8.
    static func straight(_ bytes: [UInt8]) -> [Float] {
        var values = [Float](repeating: 0, count: bytes.count)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[index + 3]) / 255
            values[index + 3] = a
            guard a > 0 else { continue }
            for c in 0..<3 { values[index + c] = min(1, Float(bytes[index + c]) / 255 / a) }
        }
        return values
    }

    /// Straight RGBA 0…1 of a straight-colour raster from premultiplied bytes' colours (the CPU reference's input).
    static func raster(_ bytes: [UInt8], width: Int, height: Int) -> RGBARaster {
        RGBARaster(width: width, height: height, pixels: straight(bytes))
    }

    /// A gray mask: 255 left of `split` (a fraction of the width), 0 right of it.
    static func halfMask(width: Int, height: Int, split: Double = 0.5) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let edge = Int(Double(width) * split)
        for y in 0..<height { for x in 0..<edge { bytes[y * width + x] = 255 } }
        return bytes
    }

    /// A horizontal ramp mask, 0 at the left to 255 at the right.
    static func rampMask(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = UInt8(clamping: x * 255 / max(1, width - 1)) } }
        return bytes
    }

    /// The straight colour at (x, y) of straight values.
    static func pixel(_ values: [Float], width: Int, x: Int, y: Int) -> [Float] {
        let i = (y * width + x) * 4
        return Array(values[i..<(i + 4)])
    }

    /// Premultiplied RGBA8 at (x, y), as Ints.
    static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3])]
    }

    /// The sRGB/P3 transfer curve (Display P3 shares it).
    static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func toGamma(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
}

/// D11: the GPU executor against Core's CPU reference (`CompositeReference.render`) on random v2 documents of up to 6
/// layers at 128 × 96: groups (isolated and pass-through), clipping, fill and opacity, the 27 modes, raster masks,
/// adjustment layers with exposure and a curve; clear and coloured backgrounds, 50 %-alpha layers.
final class CompositeParityTests: XCTestCase {
    static let width = 128, height = 96
    /// Modes whose thresholds or noise make per-pixel parity meaningless; tested apart below.
    static let special: Set<BlendMode> = [.hardMix, .dissolve, .darkerColor, .lighterColor]
    static let exposure = 0.15
    static let curve = ToneCurve(rgb: [ToneCurve.Point(0, 0), ToneCurve.Point(0.3, 0.24), ToneCurve.Point(0.7, 0.78), ToneCurve.Point(1, 1)])

    /// A seeded generator so a failure is reproducible.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// One random document and what the CPU reference needs for it.
    struct Case {
        var document: PhotoDocument
        var contents: [UUID: RGBARaster] = [:]
        var masks: [UUID: [Float]] = [:]
        var adjustments: Set<UUID> = []
    }

    func makeCase(_ fixture: LayerFixtures.Project, seed: UInt64, modes: [BlendMode]) throws -> Case {
        var random = Seeded(state: seed)
        let w = Self.width, h = Self.height
        func unit() -> Double { Double.random(in: 0...1, using: &random) }
        func colour() -> (Double, Double, Double) { (0.1 + 0.8 * unit(), 0.1 + 0.8 * unit(), 0.1 + 0.8 * unit()) }
        var document = fixture.document
        var result = Case(document: document)
        if unit() < 0.5 { document.backgroundColor = PSColor(red: unit(), green: unit(), blue: unit()) }
        let baseBytes = LayerFixtures.quadrants([colour(), colour(), colour(), colour()], width: w, height: h)
        // The base's own pixels (the fixture's base is replaced by this case's).
        let baseAsset = try fixture.imageAsset(baseBytes, width: w, height: h)
        document.layers[0].content = .image(baseAsset)
        result.contents[document.layers[0].id] = LayerFixtures.raster(baseBytes, width: w, height: h)

        func pixelLayer(parent: UUID?) throws -> Layer {
            let alpha = unit() < 0.4 ? 0.5 : 1
            let bytes: [UInt8]
            if unit() < 0.3 {
                // Left half coloured, right half clear.
                var half = LayerFixtures.solid(0, 0, 0, alpha: 0, width: w, height: h)
                let c = colour()
                let pixel = LayerFixtures.premultipliedPixel(c.0, c.1, c.2, alpha)
                for y in 0..<h { for x in 0..<(w / 2) { for k in 0..<4 { half[(y * w + x) * 4 + k] = pixel[k] } } }
                bytes = half
            } else {
                let c = colour()
                bytes = LayerFixtures.solid(c.0, c.1, c.2, alpha: alpha, width: w, height: h)
            }
            var layer = Layer(name: "Layer", content: .image(try fixture.imageAsset(bytes, width: w, height: h)))
            layer.blendMode = modes[Int(unit() * Double(modes.count)) % modes.count]
            layer.opacity = [1, 0.75, 0.5][Int(unit() * 3) % 3]
            layer.fillOpacity = unit() < 0.3 ? 0.6 : 1
            layer.parentID = parent
            if unit() < 0.3 {
                let mask = unit() < 0.5 ? LayerFixtures.halfMask(width: w, height: h) : LayerFixtures.rampMask(width: w, height: h)
                layer.maskStack = try fixture.stack(mask, width: w, height: h)
                result.masks[layer.id] = mask.map { Float($0) / 255 }
            }
            layer.isVisible = unit() > 0.08
            result.contents[layer.id] = LayerFixtures.raster(bytes, width: w, height: h)
            return layer
        }
        func adjustmentLayer(parent: UUID?) throws -> Layer {
            var edits = EditStack()
            edits.append(.toneCurve(Self.curve))
            var layer = Layer(name: "Adjust", content: .adjustment(Adjustments([.exposure: Self.exposure])), edits: edits, recipeKind: .light)
            layer.opacity = unit() < 0.5 ? 1 : 0.6
            layer.parentID = parent
            if unit() < 0.4 {
                let mask = LayerFixtures.rampMask(width: w, height: h)
                layer.maskStack = try fixture.stack(mask, width: w, height: h)
                result.masks[layer.id] = mask.map { Float($0) / 255 }
            }
            result.adjustments.insert(layer.id)
            return layer
        }

        let extra = 1 + Int(unit() * 5) % 5
        var added = 0
        while added < extra {
            let roll = unit()
            if roll < 0.45 {
                var layer = try pixelLayer(parent: nil)
                // A clipped layer needs a pixel base just below it at the top level.
                if let last = document.layers.last, last.isImage || last.isFill, last.parentID == nil, unit() < 0.35 { layer.isClipped = true }
                document.layers.append(layer)
                added += 1
            } else if roll < 0.6 {
                document.layers.append(try adjustmentLayer(parent: nil))
                added += 1
            } else if roll < 0.75 {
                let c = colour()
                var fill = Layer(name: "Fill", content: .fill(PSColor(red: c.0, green: c.1, blue: c.2)))
                fill.blendMode = modes[Int(unit() * Double(modes.count)) % modes.count]
                fill.opacity = 0.5
                result.contents[fill.id] = RGBARaster.filled(width: w, height: h, color: PSColor(red: c.0, green: c.1, blue: c.2))
                document.layers.append(fill)
                added += 1
            } else {
                // A group of one or two children (its children directly below it).
                let passThrough = unit() < 0.5
                var group = Layer(name: "Group", content: .group(LayerFolder(passThrough: passThrough)))
                group.opacity = unit() < 0.5 ? 1 : 0.7
                if !passThrough { group.blendMode = modes[Int(unit() * Double(modes.count)) % modes.count] }
                let children = 1 + Int(unit() * 2) % 2
                for _ in 0..<children { document.layers.append(try pixelLayer(parent: group.id)) }
                // Adjustment layers only inside pass-through groups (their backdrop there is the opaque canvas).
                if passThrough, unit() < 0.4 { document.layers.append(try adjustmentLayer(parent: group.id)) }
                document.layers.append(group)
                added += children + 1
            }
        }
        result.document = document
        return result
    }

    /// The CPU reference's adjustment: exposure in linear light, then the curve's table on gamma values.
    static func adjust(_ backdrop: RGBARaster) -> RGBARaster {
        let lut = ToneLUT.make(levels: .identity, curve: curve)
        let gain = pow(2, exposure * 2)
        var out = backdrop
        for index in stride(from: 0, to: out.pixels.count, by: 4) {
            for (c, channel) in [ToneCurve.Channel.red, .green, .blue].enumerated() {
                let exposed = LayerFixtures.toGamma(min(1, LayerFixtures.toLinear(Double(out.pixels[index + c])) * gain))
                out.pixels[index + c] = Float(lut.value(exposed, channel: channel))
            }
        }
        return out
    }

    func compare(_ c: Case, fixture: LayerFixtures.Project, label: String, meanLimit: Double, maxLimit: Double) async throws -> (mean: Double, max: Double) {
        let w = Self.width, h = Self.height
        let gpu = try await fixture.renderer.renderedRGBA(c.document, options: .full)
        XCTAssertEqual(gpu.width, w, label)
        XCTAssertEqual(gpu.height, h, label)
        let plan = CompositePlan.make(c.document)
        let reference = CompositeReference.render(plan, width: w, height: h, background: c.document.backgroundColor,
                                                  content: { c.contents[$0] }, mask: { c.masks[$0] },
                                                  adjust: { _, backdrop in Self.adjust(backdrop) })
        let straight = LayerFixtures.straight(gpu.bytes)
        var total = 0.0, count = 0, worst = 0.0
        for y in 0..<h where abs(y - h / 2) > 1 {
            for x in 0..<w where abs(x - w / 2) > 1 && x > 0 && x < w - 1 {
                let i = (y * w + x) * 4
                let alpha = Double(reference.pixels[i + 3])
                let channels = alpha >= 0.1 ? 0..<4 : 3..<4
                for k in channels {
                    let difference = abs(Double(straight[i + k]) - Double(reference.pixels[i + k]))
                    total += difference
                    count += 1
                    worst = max(worst, difference)
                }
            }
        }
        let mean = count > 0 ? total / Double(count) : 0
        XCTAssertLessThanOrEqual(mean, meanLimit, "\(label): mean \(mean * 255)/255")
        XCTAssertLessThanOrEqual(worst, maxLimit, "\(label): max \(worst * 255)/255")
        return (mean, worst)
    }

    func testRandomDocumentsMatchTheCPUReference() async throws {
        let fixture = try LayerFixtures.project(width: Self.width, height: Self.height,
                                                base: LayerFixtures.solid(0.5, 0.5, 0.5, width: Self.width, height: Self.height))
        defer { fixture.cleanup() }
        let modes = BlendMode.allCases.filter { !Self.special.contains($0) }
        var worstMean = 0.0, worstMax = 0.0
        for seed in 1...30 {
            let c = try makeCase(fixture, seed: UInt64(seed) * 7919, modes: modes)
            let result = try await compare(c, fixture: fixture, label: "seed \(seed) (\(c.document.layers.count) layers)", meanLimit: 2.0 / 255, maxLimit: 8.0 / 255)
            worstMean = max(worstMean, result.mean)
            worstMax = max(worstMax, result.max)
        }
        print("COMPOSITE-PARITY worst mean \(worstMean * 255)/255, worst max \(worstMax * 255)/255")
    }

    /// hardMix (a threshold at Cb + Cs = 1, where a rounding step flips a channel), darker and lighter colour (a whole
    /// pixel chosen by channel sums, equal sums flip) and dissolve (noise): documented tolerances, means only.
    func testThresholdAndNoiseModesStayClose() async throws {
        let fixture = try LayerFixtures.project(width: Self.width, height: Self.height,
                                                base: LayerFixtures.solid(0.5, 0.5, 0.5, width: Self.width, height: Self.height))
        defer { fixture.cleanup() }
        for mode in [BlendMode.hardMix, .darkerColor, .lighterColor] {
            for seed in 1...4 {
                let c = try makeCase(fixture, seed: UInt64(seed) * 104_729, modes: [mode])
                _ = try await compare(c, fixture: fixture, label: "\(mode) seed \(seed)", meanLimit: 6.0 / 255, maxLimit: 1.0)
            }
        }
        // Dissolve: about the layer's coverage of its pixels show it (the reference has its own noise).
        let w = Self.width, h = Self.height
        var document = fixture.document
        let red = try fixture.imageAsset(LayerFixtures.solid(1, 0, 0, width: w, height: h), width: w, height: h)
        document.layers[0].content = .image(try fixture.imageAsset(LayerFixtures.solid(0, 0, 1, width: w, height: h), width: w, height: h))
        document.layers.append(Layer(name: "Dissolve", content: .image(red), opacity: 0.5, blendMode: .dissolve))
        let gpu = try await fixture.renderer.renderedRGBA(document, options: .full)
        let reds = stride(from: 0, to: gpu.bytes.count, by: 4).filter { gpu.bytes[$0] > 200 && gpu.bytes[$0 + 2] < 50 }.count
        XCTAssertEqual(Double(reds) / Double(w * h), 0.5, accuracy: 0.08)
    }
}
#endif
