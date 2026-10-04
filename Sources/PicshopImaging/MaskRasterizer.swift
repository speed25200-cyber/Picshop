#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Draws a `MaskStack` on the GPU (W2, D1, D5, D6), owned by the `PhotoRenderer` actor and only used inside it.
///
/// Composition is D1 exactly, with built-ins: each component's image (`MaskComponentImages`), inverted and scaled by
/// its opacity, then add = max, intersect = min, subtract = min with 1 − v; then expand or contract (morphology,
/// radius |expand| × 0.02 × L), feather (Gaussian, σ = feather × 0.03 × L), invert and density. A first component
/// that subtracts starts from white; unsupported components (written by a newer build) are skipped.
///
/// Caches (D6):
/// - decoded rasters by path (LRU), so a drag never decodes a PNG;
/// - static stacks (no colour or luminance range) materialised as 16-bit gray on settled renders only, by
///   `<stack hash>|WxH`, least recently used out past 64 MB but never one the frame being drawn uses (past the
///   budget, the frame's other masks draw live); an interactive frame reuses one of another size, scaled;
/// - the interaction freeze: while a local adjustment X is under the finger, every other adjustment's mask (range
///   masks included) is materialised once at the interactive size and reused until the interaction ends or the
///   target changes; a settled frame while the finger rests (the pacer's pause frame) keeps it;
/// - mask colour cubes by their spec (LRU 8, the stack under the finger and previews in one scratch slot of their
///   own), and brush strokes in their own `StrokeRasterCache` (appended to as a stroke list grows).
final class MaskRasterizer {
    /// How a frame uses the caches.
    enum Mode: Equatable {
        /// A settled frame: static stacks are materialised and kept. `target` is the local adjustment still under the
        /// finger when the frame is a pause mid-drag: its stack draws live and the freeze holds.
        case settled(target: UUID?)
        /// A frame under a moving finger; `target` is the local adjustment being edited, if any.
        case interactive(target: UUID?)

        var isSettled: Bool {
            if case .settled = self { return true }
            return false
        }
    }

    private let maskStore: MaskStore
    /// Static masks drawn into bitmaps since the rasterizer was made (settled and frozen alike).
    private(set) var materializations = 0

    private var rasters: [String: CIImage] = [:]
    private var rasterOrder: [String] = []
    private static let rasterLimit = 24

    private struct Materialized {
        let image: CIImage
        let width: Int
        let height: Int
        let bytes: Int
    }

    private var settled: [String: Materialized] = [:]
    private var settledOrder: [String] = []
    private var settledBytes = 0
    static let settledByteLimit = 64 * 1_048_576
    /// The settled keys the layer being drawn uses: never evicted while it draws.
    private var frameKeys: Set<String> = []

    private var frozen: [String: CIImage] = [:]
    private var frozenTarget: UUID?

    private var cubes: [Int: Data] = [:]
    private var cubeOrder: [Int] = []
    private static let cubeLimit = 8
    static let cubeDimension = 48
    /// The one cube of a spec that changes every frame (a « Tolérance » drag, a sheet preview): it never pushes a
    /// document mask's cube out of the LRU.
    private var scratchCube: (key: Int, data: Data)?
    /// Cubes built since the rasterizer was made (tests).
    private(set) var cubeBuilds = 0

    private var strokes = StrokeRasterCache(byteLimit: 32 * 1_048_576)
    private var strokeImages: [String: CIImage] = [:]

    init(maskStore: MaskStore) {
        self.maskStore = maskStore
    }

    // MARK: - Frames

    /// Called once per layer render before its masks: the end of the interaction (a settled frame with no target)
    /// or a new target ends the freeze; a settled frame while the finger rests keeps it.
    func begin(_ mode: Mode) {
        switch mode {
        case .settled(let target):
            if target == nil || target != frozenTarget { dropFreeze() }
            frameKeys.removeAll(keepingCapacity: true)
        case .interactive(let target?):
            if target != frozenTarget { dropFreeze() }
            frozenTarget = target
        case .interactive(.none):
            // A frame without a local target (a global dial, a probe, a thumbnail) leaves the freeze alone.
            break
        }
    }

    private func dropFreeze() {
        frozen.removeAll()
        frozenTarget = nil
    }

    /// The mask of `stack` at `extent` (opaque, value in RGB), for the adjustment `owner` (nil: a stack drawn for an
    /// overlay or a selection). `preLocal` is the layer before any local adjustment, for colour and luminance ranges.
    func mask(_ stack: MaskStack, extent rawExtent: CGRect, preLocal: CIImage?, mode: Mode, owner: UUID?) -> CIImage {
        let extent = rawExtent.integral
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return MaskComponentImages.black(rawExtent) }
        let width = Int(extent.width), height = Int(extent.height)
        let isStatic = !stack.hasPixelDependentComponents
        let origin = CGAffineTransform(translationX: extent.minX, y: extent.minY)
        // The stack under the finger (moving or resting) and a stack with no owner (an overlay, a sheet's preview)
        // change from frame to frame: their colour cubes go to the scratch slot.
        let underFinger = owner != nil && (mode == .interactive(target: owner) || mode == .settled(target: owner))
        let transientCubes = owner == nil || underFinger

        // An export-sized mask is drawn once, live: a bitmap that big would only push the screen's masks out.
        let materialisable = width * height * 2 <= Self.settledByteLimit / 4
        switch mode {
        case .settled(let target) where isStatic && materialisable && (target == nil || owner != target):
            let key = "\(contentKey(stack))|\(width)x\(height)"
            frameKeys.insert(key)
            if let hit = settledHit(key) { return hit.transformed(by: origin) }
            let graph = compose(stack, extent: CGRect(x: 0, y: 0, width: width, height: height), preLocal: preLocal.map { $0.transformed(by: origin.inverted()) },
                                guideUpsampledRasters: true, transientCubes: transientCubes)
            // Past the budget, this frame's other masks stay and this one draws live: evicting a mask the frame
            // still uses would make every settled frame miss on every mask.
            let held = frameKeys.reduce(0) { $0 + (settled[$1]?.bytes ?? 0) }
            guard held + width * height * 2 <= Self.settledByteLimit, let bitmap = materialize(graph, width: width, height: height) else {
                return graph.transformed(by: origin)
            }
            storeSettled(bitmap, key: key, width: width, height: height)
            return bitmap.transformed(by: origin)

        case .interactive(let target?) where owner != nil && owner != target:
            // Frozen: the pre-local image cannot change during a local interaction.
            let content = contentKey(stack)
            let frozenKey = "\(content)|\(width)x\(height)|\(target.uuidString)"
            if let hit = frozen[frozenKey] { return hit.transformed(by: origin) }
            if isStatic, let reused = scaledSettled(contentKey: content, width: width, height: height) {
                frozen[frozenKey] = reused
                return reused.transformed(by: origin)
            }
            let graph = compose(stack, extent: CGRect(x: 0, y: 0, width: width, height: height), preLocal: preLocal.map { $0.transformed(by: origin.inverted()) },
                                transientCubes: transientCubes)
            // Normal priority: the canvas frame is waiting on these readbacks.
            let bitmap = materialize(graph, width: width, height: height, context: RenderContext.shared) ?? graph
            frozen[frozenKey] = bitmap
            return bitmap.transformed(by: origin)

        default:
            // Interactive, live: parametric graphs and cached brushes; a static stack settled at another size is
            // reused scaled. A settled render too large to keep, or the stack under a resting finger, draws live,
            // with its AI edges re-guided.
            if case .interactive = mode, isStatic, let reused = scaledSettled(contentKey: contentKey(stack), width: width, height: height) {
                return reused.transformed(by: origin)
            }
            return compose(stack, extent: extent, preLocal: preLocal, guideUpsampledRasters: mode.isSettled, transientCubes: transientCubes)
        }
    }

    /// A process-local key for the stack's content (D6: in-memory caches only, never persisted). Hashing costs
    /// microseconds; `MaskStack.contentKey` encodes the whole stack to sorted-keys JSON, which takes milliseconds
    /// for a long brush, on every frame of a stroke.
    private func contentKey(_ stack: MaskStack) -> String {
        var hasher = Hasher()
        hasher.combine(stack)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16) + "-\(stack.components.count)"
    }

    // MARK: - Composition (D1)

    /// The stack's graph at `extent`. `transientCubes`: the stack changes from frame to frame (its colour cubes go to
    /// the scratch slot rather than the LRU).
    func compose(_ stack: MaskStack, extent: CGRect, preLocal: CIImage?, guideUpsampledRasters: Bool = false, transientCubes: Bool = false) -> CIImage {
        let active = stack.components.filter {
            if case .unsupported = $0.kind { return false }
            return true
        }
        var m = active.first?.mode == .subtract ? MaskComponentImages.white(extent) : MaskComponentImages.black(extent)
        for component in active {
            guard var v = image(for: component, extent: extent, preLocal: preLocal, guideUpsampled: guideUpsampledRasters,
                                transientCubes: transientCubes) else { continue }
            if component.isInverted { v = MaskComponentImages.inverted(v) }
            let opacity = component.opacity.clamped(to: 0...1)
            if opacity < 0.9999 { v = MaskComponentImages.scaled(v, by: opacity) }
            switch component.mode {
            case .add: m = MaskComponentImages.maximum(v, m)
            case .intersect: m = MaskComponentImages.minimum(v, m)
            case .subtract: m = MaskComponentImages.minimum(MaskComponentImages.inverted(v), m)
            }
        }
        let longest = Double(max(extent.width, extent.height))
        let expand = stack.expand.clamped(to: -1...1)
        if abs(expand) > 0.0005 {
            let radius = Float(abs(expand) * MaskStack.expandRadiusFraction * longest)
            if radius >= 0.5 {
                if expand > 0 {
                    let filter = CIFilter.morphologyMaximum()
                    filter.inputImage = m.clampedToExtent()
                    filter.radius = radius
                    m = filter.outputImage?.cropped(to: extent) ?? m
                } else {
                    let filter = CIFilter.morphologyMinimum()
                    filter.inputImage = m.clampedToExtent()
                    filter.radius = radius
                    m = filter.outputImage?.cropped(to: extent) ?? m
                }
            }
        }
        let feather = stack.feather.clamped(to: 0...1)
        if feather > 0.0005 {
            let sigma = feather * MaskStack.featherSigmaFraction * longest
            if sigma >= 0.3 { m = m.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent) }
        }
        if stack.isInverted { m = MaskComponentImages.inverted(m) }
        let density = stack.density.clamped(to: 0...1)
        if density < 0.9999 { m = MaskComponentImages.scaled(m, by: density) }
        return m
    }

    /// One component's image (opaque, cropped to `extent`), or nil when it cannot be drawn (a missing raster file,
    /// a range without the pre-local image): such a component is skipped, as an unsupported one is.
    func image(for component: MaskComponent, extent: CGRect, preLocal: CIImage?, guideUpsampled: Bool = false, transientCubes: Bool = false) -> CIImage? {
        switch component.kind {
        case .raster(let raster):
            guard let raw = rawRaster(raster) else { return nil }
            let placed = MaskComponentImages.placed(raw, corners: raster.corners, extent: extent)
            // Settled renders far above the raster's size (an export): an AI edge follows the full-resolution
            // picture rather than the 1536 px one's, through the guided filter (D6, "should").
            guard guideUpsampled, let preLocal, Self.followsPicture(raster.origin) else { return placed }
            let upsampling = Double(max(extent.width, extent.height)) / Double(max(1, max(raster.pixelWidth, raster.pixelHeight)))
            guard upsampling >= 1.5 else { return placed }
            let radius = max(2, 0.003 * Double(max(extent.width, extent.height)))
            return EdgeRefine.guided(placed, guide: preLocal.cropped(to: extent), radius: radius, epsilon: 1e-3)
        case .brush(let spec):
            return brush(spec, extent: extent)
        case .linear(let spec):
            return MaskComponentImages.linear(spec, extent: extent)
        case .radial(let spec):
            return MaskComponentImages.radial(spec, extent: extent)
        case .colorRange(let spec):
            guard let preLocal else { return nil }
            // The grid's Lab, chroma and hue are computed once (Core): a spec costs its scoring only.
            let data = cube(key: Self.cubeKey("colorRange", spec), transient: transientCubes) {
                MaskMath.labCube(dimension: Self.cubeDimension) { lab, chroma, hue in MaskMath.colorRange(lab, chroma: chroma, hue: hue, spec) }
            }
            return MaskComponentImages.cube(data, dimension: Self.cubeDimension, on: preLocal, extent: extent)
        case .luminanceRange(let spec):
            guard let preLocal else { return nil }
            let data = cube(key: Self.cubeKey("luminanceRange", spec), transient: transientCubes) {
                MaskMath.cube(dimension: Self.cubeDimension) { r, g, b in
                    MaskMath.trapezoid(MaskMath.luma(r: r, g: g, b: b), low: spec.low, high: spec.high, feather: spec.feather)
                }
            }
            return MaskComponentImages.cube(data, dimension: Self.cubeDimension, on: preLocal, extent: extent)
        case .depthRange(let spec):
            guard let raw = rawRaster(spec.depth) else { return nil }
            let placed = MaskComponentImages.placed(raw, corners: spec.depth.corners, extent: extent)
            return MaskComponentImages.depthRange(placed, spec: spec, extent: extent)
        case .unsupported:
            return nil
        }
    }

    // MARK: - Rasters, brushes and cubes

    /// AI rasters whose edge is the picture's: worth re-guiding when drawn much larger than they were made.
    static func followsPicture(_ origin: RasterRef.Origin) -> Bool {
        switch origin {
        case .subject, .background, .people, .person, .object, .sky, .selection, .facePart, .matte: return true
        case .vegetation, .water, .depth, .brush, .imported: return false
        }
    }

    /// A raster file decoded once (raw values, its own size), least recently used out first.
    func rawRaster(_ raster: RasterRef) -> CIImage? {
        if let cached = rasters[raster.path] {
            if let index = rasterOrder.lastIndex(of: raster.path) { rasterOrder.remove(at: index) }
            rasterOrder.append(raster.path)
            return cached
        }
        guard let image = maskStore.loadRaw(raster) else { return nil }
        rasters[raster.path] = image
        rasterOrder.append(raster.path)
        while rasterOrder.count > Self.rasterLimit { rasters[rasterOrder.removeFirst()] = nil }
        return image
    }

    /// The brush's strokes at the extent's size: drawn once per list, appended to when the list grows (each dab ×
    /// its stroke's flow, in Core's BrushRaster).
    func brush(_ spec: BrushSpec, extent: CGRect) -> CIImage? {
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        guard !spec.strokes.isEmpty else { return MaskComponentImages.black(extent) }
        let raster = strokes.mask(for: spec.strokes, width: width, height: height)
        let origin = CGAffineTransform(translationX: extent.minX, y: extent.minY)
        if !raster.isNew, let image = strokeImages[raster.key] { return image.transformed(by: origin) }
        guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: raster.bytes, colorSpace: RenderContext.maskColorSpace) else { return nil }
        let image = ImageSupport.rawMaskImage(cg)
        strokeImages[raster.key] = image
        if strokeImages.count > strokes.count {
            let live = strokes.keys
            strokeImages = strokeImages.filter { live.contains($0.key) }
        }
        return image.transformed(by: origin)
    }

    static func cubeKey<Spec: Hashable>(_ kind: String, _ spec: Spec) -> Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(spec)
        return hasher.finalize()
    }

    /// A mask cube (48³, value in R, G and B) built on the CPU from Core's function, kept by its spec: in the LRU,
    /// or, for a `transient` spec (one that changes every frame), in the scratch slot. Both are looked in first, so
    /// an unchanged component of the stack under the finger still hits the cube its settled frame kept.
    func cube(key: Int, transient: Bool = false, build: () -> [Float]) -> Data {
        if let cached = cubes[key] {
            if let index = cubeOrder.lastIndex(of: key) { cubeOrder.remove(at: index) }
            cubeOrder.append(key)
            return cached
        }
        if let scratch = scratchCube, scratch.key == key { return scratch.data }
        let data = PSSignpost.measure("mask.cube") { Data(floats: build()) }
        cubeBuilds += 1
        if transient {
            scratchCube = (key: key, data: data)
        } else {
            cubes[key] = data
            cubeOrder.append(key)
            while cubeOrder.count > Self.cubeLimit { cubes[cubeOrder.removeFirst()] = nil }
        }
        return data
    }

    // MARK: - Materialisation

    /// The mask drawn now into a 16-bit linear gray bitmap at the origin, and read back tagged the same way. Settled
    /// masks read back on the low-priority context; the freeze, which a canvas frame waits on, on the shared one.
    private func materialize(_ graph: CIImage, width: Int, height: Int, context: CIContext = RenderContext.background) -> CIImage? {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let signpost = PSSignpost.begin("mask.materialize", "\(width)x\(height)")
        defer { PSSignpost.end(signpost) }
        guard let cg = context.createCGImage(graph, from: rect, format: .L16, colorSpace: RenderContext.maskColorSpace, deferred: false) else {
            return nil
        }
        materializations += 1
        return CIImage(cgImage: cg)
    }

    private func settledHit(_ key: String) -> CIImage? {
        guard let hit = settled[key] else { return nil }
        if let index = settledOrder.lastIndex(of: key) { settledOrder.remove(at: index) }
        settledOrder.append(key)
        return hit.image
    }

    private func storeSettled(_ image: CIImage, key: String, width: Int, height: Int) {
        let bytes = width * height * 2
        if let old = settled[key] { settledBytes -= old.bytes }
        settled[key] = Materialized(image: image, width: width, height: height, bytes: bytes)
        settledOrder.removeAll { $0 == key }
        settledOrder.append(key)
        settledBytes += bytes
        // Least recently used out first, never a mask the frame being drawn uses.
        while settledBytes > Self.settledByteLimit, let victim = settledOrder.first(where: { !frameKeys.contains($0) }) {
            settledOrder.removeAll { $0 == victim }
            settledBytes -= settled.removeValue(forKey: victim)?.bytes ?? 0
        }
    }

    /// A settled bitmap of the same stack at another size with the same framing, scaled to width × height.
    private func scaledSettled(contentKey: String, width: Int, height: Int) -> CIImage? {
        let prefix = contentKey + "|"
        let aspect = Double(width) / Double(height)
        var best: Materialized?
        for key in settledOrder.reversed() where key.hasPrefix(prefix) {
            guard let entry = settled[key], abs(Double(entry.width) / Double(entry.height) - aspect) < 0.01 else { continue }
            if best.map({ entry.width > $0.width }) ?? true { best = entry }
        }
        guard let best else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(width) / CGFloat(best.width), y: CGFloat(height) / CGFloat(best.height))
        return best.image.clampedToExtent().transformed(by: scale).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - Memory

    /// Everything goes (memory warning, media changed).
    func purge() {
        rasters.removeAll()
        rasterOrder.removeAll()
        settled.removeAll()
        settledOrder.removeAll()
        settledBytes = 0
        dropFreeze()
        cubes.removeAll()
        cubeOrder.removeAll()
        scratchCube = nil
        strokes.removeAll()
        strokeImages.removeAll()
        frameKeys.removeAll()
    }

    /// A gesture's per-frame segments were merged into one polyline (the same pixels): the stroke rasters drawn for
    /// the segments are kept under the merged list, so the next stroke does not redraw the brush's history.
    func alias(_ drawn: [BrushStroke], as coalesced: [BrushStroke]) {
        strokes.alias(drawn, as: coalesced)
    }

    /// Bytes held by settled bitmaps (tests).
    var settledBytesHeld: Int { settledBytes }
}
#endif
