#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import PicshopCore
#if os(iOS)
import os
#endif

/// How much memory the process may still use before the system reclaims it.
public enum MemoryBudget {
    /// Below this, heavy jobs purge caches first and work a step smaller.
    public static let lowThreshold = 700 * 1_048_576

    /// Bytes still available to the app; nil where the system does not say (macOS).
    public static var availableBytes: Int? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? Int(available) : nil
        #else
        return nil
        #endif
    }

    public static var isLow: Bool { availableBytes.map { $0 < lowThreshold } ?? false }

    /// "812 MB", or "?" where unknown.
    public static var availableDescription: String {
        availableBytes.map { "\($0 / 1_048_576) MB" } ?? "?"
    }
}

/// Where the imaging layer reports its heavy steps (erase, upscale…) for the
/// crash breadcrumbs kept by the app. Thread-safe.
public enum ImagingBreadcrumbs {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (String) -> Void)?
    }

    private static let box = Box()

    public static func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        box.lock.lock()
        box.handler = handler
        box.lock.unlock()
    }

    public static func note(_ message: String) {
        box.lock.lock()
        let handler = box.handler
        box.lock.unlock()
        handler?(message)
    }
}

/// Turns a `PhotoDocument` into a `CIImage`.
///
/// W3: every render goes through the compositing plan (`CompositePlan.make`, D11) and its executor
/// (`CompositeExecutor`, the same code a snapshot frame runs): groups, clipping, fill and opacity, the 27 modes in
/// gamma-encoded Display P3, adjustment and fill layers, layer masks, and the non-uniform placement map (D10).
/// Expensive results (erase, generate, expand, upscale) are cached by content keys (D12): a key chains the source and
/// every operation the loop transforms, so a dial drag never recomputes one and reordering an earlier step never
/// reuses a stale one. Caches are byte-bounded (D15).
public actor PhotoRenderer {
    public struct Options: Sendable {
        /// Longest side of the rendered canvas in pixels. `nil` renders at full resolution.
        public var targetLongestSide: Double?
        /// Show the untouched base image (before/after compare).
        public var showOriginal: Bool
        public var includeOverlays: Bool
        /// Skip expensive operations that are not cached yet (fast interactive preview).
        public var allowExpensiveWork: Bool
        /// The picture on screen: the expensive results it uses survive memory trimming.
        public var isDisplayed: Bool
        /// Local adjustments drawn (W2, D2). False for the analysis image, colour sampling, the eyedropper and
        /// every AI input, so no mask depends on another mask's adjustment.
        public var includesLocalAdjustments: Bool
        /// The local adjustment under the finger (W2, D6): the other adjustments' masks are frozen meanwhile.
        public var interactionTarget: UUID?
        /// W3 (D14): the canvas-normalised region a detail tile renders; nil renders the whole canvas.
        public var regionOfInterest: PSRect?
        /// W3 (D14): a full-resolution export pass. Its expensive results are pinned until `endExportPass()`, and every
        /// 8-bit non-HEIC source is decoded once, eagerly, at the density the output needs (strips then never decode
        /// again); HEIC, RAW and deep sources stay lazy (tiled decode).
        public var isExportPass: Bool

        public init(targetLongestSide: Double? = nil, showOriginal: Bool = false, includeOverlays: Bool = true, allowExpensiveWork: Bool = true, isDisplayed: Bool = false,
                    includesLocalAdjustments: Bool = true, interactionTarget: UUID? = nil, regionOfInterest: PSRect? = nil, isExportPass: Bool = false) {
            self.targetLongestSide = targetLongestSide
            self.showOriginal = showOriginal
            self.includeOverlays = includeOverlays
            self.allowExpensiveWork = allowExpensiveWork
            self.isDisplayed = isDisplayed
            self.includesLocalAdjustments = includesLocalAdjustments
            self.interactionTarget = interactionTarget
            self.regionOfInterest = regionOfInterest
            self.isExportPass = isExportPass
        }

        public static let preview = Options(targetLongestSide: 2048, isDisplayed: true)
        public static let thumbnail = Options(targetLongestSide: 512, includeOverlays: true, allowExpensiveWork: false)
        public static let full = Options()
    }

    let store: ProjectStore
    let projectID: UUID
    private let inpainting: InpaintingPipeline
    /// Set again once the model is located: the first frame never waits for it.
    private var upscaler: Upscaler
    /// Decoded sources by "<path>@<side|full|lazy>", least recently used first in `sourceOrder`, byte-bounded (D15).
    private var sourceCache: [String: (image: CIImage, bytes: Int)] = [:]
    private var sourceOrder: [String] = []
    private var sourceBytes = 0
    /// D15: 160 MB of decoded sources; a detail tile may use 200 MB, evicting the preview's first (least recent).
    static let sourceByteLimit = 160 * 1_048_576
    static let detailSourceByteLimit = 200 * 1_048_576
    private static let sourceEntryLimit = 32
    /// Feathered masks rendered once per size ("path|WxH|feather|inverted"), least recently used first.
    private var maskCache: [String: CIImage] = [:]
    private var maskOrder: [String] = []
    private static let maskCacheLimit = 12
    /// Expensive results by "<content key>@WxH" (D12), least recently used first; byte-bounded (D15).
    private var operationCache: [String: CIImage] = [:]
    private var operationBytes: [String: Int] = [:]
    private var operationTotalBytes = 0
    /// Least recently used first: a hit moves its key to the end.
    private var operationOrder: [String] = []
    /// D15: 256 MB of expensive results (was 24 entries), and never more than 64 of them.
    static let operationByteLimit = 256 * 1_048_576
    private static let operationCacheLimit = 64
    /// Keys the last settled on-screen render used: never trimmed, so a memory
    /// warning does not make the open photo redo its erases.
    private var displayedKeys: Set<String> = []
    /// D14: the keys an export pass uses, exempt from eviction until it ends.
    private var exportPins: Set<String> = []
    /// Bytes an export pass holds besides its strips: pinned results and eagerly decoded sources.
    private var exportSourceBytes = 0
    private var displayGeneration = 0
    /// Operation id of each chained key (the part before "@"), so `purgeOperationCache(for:)` finds them.
    private var chainOwners: [String: UUID] = [:]
    /// Rasterised text and shape layers per content and size. A table fill adds one text layer per cell
    /// (45 to 400): they all stay, so a render after the fill rasterises nothing again. Least recently
    /// used out first past `overlayCacheLimit` entries or `overlayByteLimit` bytes.
    private var overlayCache: [String: CIImage] = [:]
    private var overlayUse: [String: Int] = [:]
    private var overlayTick = 0
    private var overlayBytes = 0
    private static let overlayCacheLimit = 600
    private static let overlayByteLimit = 96 * 1_048_576
    /// Expensive results being computed, keyed like `operationCache`: a second render of
    /// the same step (compare, a panel, the analysis image) awaits the running job instead
    /// of starting another PatchMatch or neural pass.
    private var inFlight: [String: Task<CIImage, Error>] = [:]
    /// Renders currently awaiting each job; the job is cancelled when the last one leaves.
    private var inFlightWaiters: [String: Set<UUID>] = [:]
    /// Clone, paint and heal masks per stroke list and size: a render after the first draws no
    /// stroke, and a list that grows draws only its new strokes. Their images, by the same keys.
    private var strokeRasters = StrokeRasterCache()
    private var strokeMasks: [String: CIImage] = [:]
    /// Tone tables (Levels and the person's curves) by their inputs: a drag elsewhere rebuilds none.
    private var toneTables: [Int: ToneLUT?] = [:]
    /// Text and shape rasters drawn since the renderer was made: moving or turning a layer draws none.
    private(set) var overlayRasterizations = 0
    /// Brush strokes drawn into masks since the renderer was made.
    var strokeRasterizations: Int { strokeRasters.strokesDrawn }
    /// Local adjustments' masks (W2, D6): rasters, settled bitmaps, the interaction freeze, cubes and brushes.
    /// W3: layer masks too (owner = the layer's id).
    let rasterizer: MaskRasterizer
    /// W3 (D12, D15): materialised image-layer contents by content key.
    let contentCache = LayerContentCache()
    /// Content keys and chained operation keys, recomputed only when the layer's relevant fields change (equality of
    /// unchanged values is cheap; their sorted-keys JSON is not).
    private var contentKeyMemo: [UUID: (layer: Layer, key: String)] = [:]
    private var operationKeyMemo: [UUID: (source: MediaAsset, operations: [EditOperation], keys: [UUID: String])] = [:]
    /// The cubes the develop step bakes into (tests swap in their own to count bakes).
    var colorCube: ColorCube = .shared
    /// D13: the live interactive snapshot's store; a new snapshot or a memory trim empties it.
    var liveSnapshot: SnapshotStore?
    /// D14: the last detail tiles (LRU of 4), dropped on any document change.
    var detailTiles: [(key: String, image: CIImage)] = []
    /// Layer and mask thumbnails by content key, transform and side.
    var thumbnails: [String: CGImage] = [:]
    var thumbnailOrder: [String] = []
    /// Expensive steps started since the renderer was made (tests: a dial drag recomputes nothing).
    private(set) var expensiveRuns = 0

    public init(store: ProjectStore, projectID: UUID, inpainting: InpaintingPipeline, upscaler: Upscaler = Upscaler()) {
        self.store = store
        self.projectID = projectID
        self.inpainting = inpainting
        self.upscaler = upscaler
        rasterizer = MaskRasterizer(maskStore: MaskStore(store: store, projectID: projectID))
    }

    /// The upscaler with its model, once the model manager has located it.
    public func setUpscaler(_ upscaler: Upscaler) {
        self.upscaler = upscaler
    }

    public var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    /// Tests: the cubes the develop step bakes into.
    func setColorCube(_ cube: ColorCube) {
        colorCube = cube
    }

    /// Cache keys one render read or produced.
    final class KeyLog {
        var keys: Set<String> = []
    }

    // MARK: - Expensive-result cache (D12, D15)

    private func cacheOperation(_ image: CIImage, for key: String) {
        if let old = operationBytes[key] { operationTotalBytes -= old }
        let bytes = Self.rasterBytes(of: image)
        operationCache[key] = image
        operationBytes[key] = bytes
        operationTotalBytes += bytes
        touch(key)
        evict(downTo: Self.operationCacheLimit, bytes: Self.operationByteLimit) { _ in false }
    }

    /// Marks a cached result as just used.
    private func touch(_ key: String) {
        if let index = operationOrder.lastIndex(of: key) { operationOrder.remove(at: index) }
        operationOrder.append(key)
    }

    /// Drops least recently used results until at most `limit` remain within `bytes`, those matching `preferring`
    /// first; what is on screen and what an export pass pinned stay.
    private func evict(downTo limit: Int, bytes byteLimit: Int = Int.max, preferring first: (String) -> Bool) {
        let candidates = operationOrder.filter { !displayedKeys.contains($0) && !exportPins.contains($0) }
        let ranked = candidates.filter(first) + candidates.filter { !first($0) }
        var excess = operationOrder.count - limit
        for key in ranked where excess > 0 || operationTotalBytes > byteLimit {
            removeOperation(key)
            excess -= 1
        }
        operationOrder.removeAll { operationCache[$0] == nil }
    }

    private func removeOperation(_ key: String) {
        operationCache[key] = nil
        operationTotalBytes -= operationBytes.removeValue(forKey: key) ?? 0
    }

    /// Drops all cached intermediates (call when memory is tight or media changed).
    /// Jobs still running finish for the renders awaiting them.
    public func purgeCaches() {
        clearSources()
        maskCache.removeAll()
        maskOrder.removeAll()
        operationCache.removeAll()
        operationBytes.removeAll()
        operationTotalBytes = 0
        operationOrder.removeAll()
        displayedKeys.removeAll()
        exportPins.removeAll()
        clearOverlays()
        disparityCache.removeAll()
        clearStrokeMasks()
        rasterizer.purge()
        contentCache.removeAll()
        dropSnapshot()
        detailTiles.removeAll()
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
    }

    /// Memory warning: drops what is cheap to rebuild and the least recently used
    /// expensive results, other sizes (export, analysis) first. The results the
    /// picture on screen uses always stay, so its erases are not redone. W3 adds the layer contents, the snapshot
    /// and the detail tiles (D15).
    public func trimForMemoryPressure(keepingRecent keep: Int = 4) {
        clearSources()
        maskCache.removeAll()
        maskOrder.removeAll()
        clearOverlays()
        disparityCache.removeAll()
        clearStrokeMasks()
        rasterizer.purge()
        contentCache.removeAll()
        dropSnapshot()
        detailTiles.removeAll()
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        let displayedSizes = Set(displayedKeys.compactMap(Self.sizeSuffix(ofKey:)))
        evict(downTo: keep) { key in Self.sizeSuffix(ofKey: key).map { !displayedSizes.contains($0) } ?? true }
        RenderContext.shared.clearCaches()
    }

    /// "WxH" of a cache key ("<key>@WxH").
    private static func sizeSuffix(ofKey key: String) -> Substring? {
        key.lastIndex(of: "@").map { key[key.index(after: $0)...] }
    }

    /// The chained key of a cache key (the part before "@").
    private static func chainKey(ofKey key: String) -> Substring {
        key.lastIndex(of: "@").map { key[..<$0] } ?? Substring(key)
    }

    /// Whether an expensive step is being computed right now.
    public var hasHeavyWorkInFlight: Bool { !inFlight.isEmpty }

    /// Drops the results of these operations: their current content keys (D12) and the W2 id keys alike.
    public func purgeOperationCache(for operationIDs: Set<UUID>) {
        let ids = Set(operationIDs.map(\.uuidString))
        for key in Array(operationCache.keys) {
            let chain = String(Self.chainKey(ofKey: key))
            if let owner = chainOwners[chain], operationIDs.contains(owner) { removeOperation(key); continue }
            if ids.contains(chain) { removeOperation(key) }
        }
        operationOrder = operationOrder.filter { operationCache[$0] != nil }
        displayedKeys = displayedKeys.filter { operationCache[$0] != nil }
        exportPins = exportPins.filter { operationCache[$0] != nil }
    }

    // MARK: - Export passes (D14)

    /// Ends an export pass: its pinned results become ordinary cache entries again, its eager sources go.
    public func endExportPass() {
        exportPins.removeAll()
        exportSourceBytes = 0
        for key in sourceOrder where key.hasSuffix("#export") { removeSource(key) }
        evict(downTo: Self.operationCacheLimit, bytes: Self.operationByteLimit) { _ in false }
    }

    /// Bytes the current export pass holds besides its strips (D14 `pinnedBytes`).
    public var exportPinnedBytes: Int {
        exportSourceBytes + exportPins.reduce(0) { $0 + (operationBytes[$1] ?? 0) }
    }

    // MARK: - Rendering

    public func render(_ document: PhotoDocument, options: Options = .preview) async throws -> CIImage {
        try await render(document, options: options, capture: nil)
    }

    /// The render, with the masks of the capture's layer for an overlay recorded in `capture` (W2, D17; W3: any
    /// image layer, or a layer mask).
    func render(_ document: PhotoDocument, options: Options, capture: MaskCapture?) async throws -> CIImage {
        let timer = PSTimer("render")
        defer { timer.log(category: .imaging) }
        // A settled on-screen render records the results it uses; the newest one to finish wins. An export pass
        // records them too, to pin them (D14).
        let records = (options.isDisplayed && options.allowExpensiveWork && !options.showOriginal) || options.isExportPass
        let log = records ? KeyLog() : nil
        let displayed = options.isDisplayed && options.allowExpensiveWork && !options.showOriginal
        if displayed { displayGeneration += 1 }
        let generation = displayGeneration

        let frame = try await prepareFrame(document, options: options, log: log, capture: capture)
        var image: CIImage
        if let original = frame.original {
            image = original
        } else {
            image = CompositeExecutor.render(frame.plan, inputs: frame.inputs(colorCube: colorCube, lutURL: lutURLMaker()))
        }
        if let roi = options.regionOfInterest {
            // D14: the plan's output cropped to the region before any scaling.
            let rect = roi.clampedToUnit().ciRect(in: frame.canvas).integral.intersection(frame.canvas)
            if !rect.isEmpty { image = image.cropped(to: rect) }
        }
        if let log {
            if displayed, generation == displayGeneration { displayedKeys = log.keys }
            if options.isExportPass { exportPins.formUnion(log.keys) }
        }
        // A settled picture on screen is drawn again for every zoom, pan and glide:
        // Core Image keeps the finished bitmap instead of replaying the edit graph.
        if displayed { return image.insertingIntermediate(cache: true) }
        return image
    }

    /// Renders only the base photo with its edits (used by tools that need the pixels, e.g. segmentation).
    public func renderBase(_ document: PhotoDocument, options: Options = .preview) async throws -> CIImage {
        guard let base = document.baseLayer, let asset = base.imageAsset else { throw PicshopError.renderFailed("no photo") }
        let scale = Self.renderScale(document, options: options)
        let image = try await renderImageLayer(base, asset: asset, scale: scale, options: options)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// The render's scale relative to the base photo's full resolution.
    static func renderScale(_ document: PhotoDocument, options: Options) -> Double {
        guard let asset = document.baseLayer?.imageAsset else { return 1 }
        let fullLongest = max(asset.pixelSize.width, asset.pixelSize.height)
        return options.targetLongestSide.map { min(1, $0 / max(1, fullLongest)) } ?? 1
    }

    /// The compositor's space (D6): gamma-encoded, unless the proTone kill switch is off.
    static var compositeSpace: CompositeSpace { FeatureFlags.isOn(.proTone) ? .encoded : .linear }

    /// Turns a LUT's project path into its file (the develop step runs off the actor too).
    nonisolated func lutURLMaker() -> @Sendable (String) -> URL {
        let store = self.store, projectID = self.projectID
        return { store.url(for: $0, in: projectID) }
    }

    // MARK: - Frames (D11)

    /// What one render draws, prepared on the actor: the plan, each layer placed on the canvas with its masks, the
    /// adjustment and group masks, the adjustment recipes. The executor then builds the graph from it.
    struct PreparedFrame {
        var plan: [CompositeNode] = []
        var canvas: CGRect = .null
        /// The document's canvas at full resolution (the placement maps are normalised to it).
        var canvasSize = PSSize(width: 1, height: 1)
        var scale: Double = 1
        var background: PSColor = .clear
        var space: CompositeSpace = .encoded
        var cubes: DevelopRenderer.Cubes = .settled
        var pieces: [UUID: LayerPieces] = [:]
        var masks: [UUID: CIImage] = [:]
        var recipes: [UUID: DevelopRenderer.Recipe] = [:]
        /// `showOriginal`: the untouched base over the background, drawn as it is.
        var original: CIImage?

        func placed(_ id: UUID) -> CIImage? {
            pieces[id].flatMap { $0.placed(on: canvas) }
        }

        func inputs(colorCube: ColorCube, lutURL: @escaping @Sendable (String) -> URL) -> CompositeInputs {
            let pieces = self.pieces, masks = self.masks, recipes = self.recipes, canvas = self.canvas
            let scale = self.scale, cubes = self.cubes
            return CompositeInputs(canvas: canvas, background: background, space: space,
                                   content: { id in pieces[id].flatMap { $0.placed(on: canvas) } },
                                   mask: { masks[$0] },
                                   adjust: { id, backdrop in
                                       guard let recipe = recipes[id], !recipe.isNeutral else { return backdrop }
                                       return DevelopRenderer.apply(recipe, to: backdrop, scale: scale, cubes: cubes, colorCube: colorCube, lutURL: lutURL)
                                   })
        }
    }

    /// One layer's pixels before placement, and how they land on the canvas (D10, D8).
    struct LayerPieces {
        /// Content space, linear values, premultiplied, the legacy mask and a linked stack applied; nil draws nothing.
        var content: CIImage?
        /// Content unit square (top-left) → canvas-normalised (top-left), a group's transform included.
        var map: PSHomography = .identity
        /// A stack in canvas space (unlinked), gray.
        var canvasMask: CIImage?
        /// The content's full-resolution size the map was made for.
        var contentSize = PSSize(width: 1, height: 1)

        func placed(on canvas: CGRect) -> CIImage? {
            guard let content else { return nil }
            var image = ContentPlacement.place(content, map: map, canvas: canvas)
            if let canvasMask { image = AdjustmentPipeline.applyingAlpha(mask: canvasMask, to: image) }
            return image.cropped(to: canvas)
        }
    }

    /// The prepared frame of a render (`render` and the snapshot's capture share it).
    func prepareFrame(_ document: PhotoDocument, options: Options, log: KeyLog?, capture: MaskCapture?) async throws -> PreparedFrame {
        guard let base = document.baseLayer, let baseAsset = base.imageAsset else {
            throw PicshopError.renderFailed("document has no photo")
        }
        let scale = Self.renderScale(document, options: options)
        var frame = PreparedFrame()
        frame.scale = scale
        frame.background = document.backgroundColor
        frame.space = Self.compositeSpace
        frame.cubes = options.allowExpensiveWork ? .settled : .interactive
        let rasterMode: MaskRasterizer.Mode = options.allowExpensiveWork ? .settled(target: options.interactionTarget)
                                                                          : .interactive(target: options.interactionTarget)
        rasterizer.begin(rasterMode)

        if options.showOriginal {
            let original = try await renderImageLayer(base, asset: baseAsset, scale: scale, options: options)
            let canvas = CGRect(origin: .zero, size: original.extent.size)
            let placed = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
            frame.canvas = canvas
            frame.original = placed.composited(over: CIImage(color: document.backgroundColor.ciColor).cropped(to: canvas)).cropped(to: canvas)
            return frame
        }

        var plan = CompositePlan.make(document)
        if !options.includeOverlays { plan = [.layer(LayerDraw(base))] }
        frame.plan = plan
        let ids = plan.flatMap(\.layerIDs)
        let materializes = ids.count > 1

        // A layer mask's overlay reads only the content's extent and placement (set below): its layer's content stays
        // in the content cache instead of being rebuilt every brush frame.
        let contentCapture: MaskCapture?
        if case .layerMask? = capture?.target { contentCapture = nil } else { contentCapture = capture }
        // The base defines the canvas (its output at this scale).
        let captureBase = capture != nil && (capture?.layerID == nil || capture?.layerID == base.id)
        let baseContent = try await imageContent(base, asset: baseAsset, density: scale, options: options, log: log,
                                                 capture: captureBase ? contentCapture : nil, canMaterialize: materializes)
        let canvas = CGRect(origin: .zero, size: baseContent.extent.size)
        frame.canvas = canvas
        let canvasSize = document.canvasSize.width > 0 && document.canvasSize.height > 0
            ? document.canvasSize : PSSize(width: Double(canvas.width) / scale, height: Double(canvas.height) / scale)
        frame.canvasSize = canvasSize
        if let capture, captureBase {
            capture.layerID = base.id
            if capture.extent.isNull, contentCapture == nil { capture.extent = baseContent.extent }
            if !capture.extent.isNull { capture.canvasOffset = CGAffineTransform(translationX: -capture.extent.minX, y: -capture.extent.minY) }
            capture.canvasRect = canvas
            capture.map = .identity
        }
        let region = options.regionOfInterest.map { $0.clampedToUnit().ciRect(in: canvas).integral.intersection(canvas) }
        let canvasPixels = PSSize(width: Double(canvas.width), height: Double(canvas.height))

        for id in ids {
            guard let layer = document.layer(id: id) else { continue }
            let groupMap = groupPlacement(of: layer, in: document, canvasSize: canvasSize)
            switch layer.content {
            case .image(let asset):
                if layer.id == base.id {
                    let masked = layerMasked(layer, content: baseContent, canvas: canvas, mode: rasterMode)
                    frame.pieces[id] = LayerPieces(content: masked.content, map: .identity, canvasMask: masked.canvasMask, contentSize: canvasSize)
                    continue
                }
                let contentSize = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
                var map = LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
                if let groupMap { map = map.then(groupMap) }
                let wantsCapture = capture?.layerID == id
                if let region, !wantsCapture, ContentPlacement.bounds(map, canvas: canvas).intersection(region).isEmpty { continue }
                // Decoded at the density the placement needs (never denser than the source), in √2 steps.
                let need = ContentPlacement.density(map, contentPixels: contentSize, canvasPixels: canvasPixels)
                let density = Self.quantizedDensity(need * contentSize.width / max(1, asset.pixelSize.width))
                let content = try await imageContent(layer, asset: asset, density: density, options: options, log: log,
                                                     capture: wantsCapture ? contentCapture : nil, canMaterialize: materializes)
                let masked = layerMasked(layer, content: content, canvas: canvas, mode: rasterMode)
                if let capture, wantsCapture {
                    capture.map = map
                    capture.canvasRect = canvas
                }
                frame.pieces[id] = LayerPieces(content: masked.content, map: map, canvasMask: masked.canvasMask, contentSize: contentSize)
            case .text, .shape:
                guard let raster = overlayContent(layer, canvas: canvas) else { continue }
                let k = Double(canvas.width) / max(1, canvasSize.width)
                let contentSize = PSSize(width: Double(raster.extent.width) / max(1e-9, k), height: Double(raster.extent.height) / max(1e-9, k))
                var map = LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
                if let groupMap { map = map.then(groupMap) }
                if let region, ContentPlacement.bounds(map, canvas: canvas).intersection(region).isEmpty { continue }
                let masked = layerMasked(layer, content: raster, canvas: canvas, mode: rasterMode)
                frame.pieces[id] = LayerPieces(content: masked.content, map: map, canvasMask: masked.canvasMask, contentSize: contentSize)
            case .fill(let color):
                let masked = layerMasked(layer, content: CIImage(color: color.ciColor).cropped(to: canvas), canvas: canvas, mode: rasterMode)
                frame.pieces[id] = LayerPieces(content: masked.content, map: .identity, canvasMask: masked.canvasMask, contentSize: canvasSize)
            case .gradientFill(let gradient):
                let masked = layerMasked(layer, content: GradientRenderer.image(gradient, canvas: canvas), canvas: canvas, mode: rasterMode)
                frame.pieces[id] = LayerPieces(content: masked.content, map: .identity, canvasMask: masked.canvasMask, contentSize: canvasSize)
            case .adjustment(let adjustments):
                frame.masks[id] = canvasMask(of: layer, canvas: canvas, map: nil, mode: rasterMode)
                frame.recipes[id] = DevelopRenderer.Recipe(edits: layer.edits, extra: adjustments, tone: toneTable(for: layer.edits))
            case .group:
                let ownMap = layer.transform == .identity ? nil : LayerPlacement.map(for: layer, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
                frame.masks[id] = canvasMask(of: layer, canvas: canvas, map: layer.isMaskLinked ? ownMap : nil, mode: rasterMode)
            case .unsupported:
                continue
            }
        }
        if let capture, let id = capture.layerID, id != base.id, let pieces = frame.pieces[id] {
            // Text, shape and fill layers too (a layer mask's overlay).
            capture.map = pieces.map
            capture.canvasRect = canvas
            if capture.extent.isNull, let content = pieces.content { capture.extent = content.extent }
        }
        return frame
    }

    /// A child's extra placement from its group's own transform (canvas-normalised → canvas-normalised); nil when the
    /// layer is not in a group or the group is not transformed.
    func groupPlacement(of layer: Layer, in document: PhotoDocument, canvasSize: PSSize) -> PSHomography? {
        guard let parentID = layer.parentID, let group = document.layer(id: parentID), group.isGroup, group.transform != .identity else { return nil }
        return LayerPlacement.map(for: group, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
    }

    /// Decode densities in √2 steps (a scaling drag re-decodes only when it crosses one), at most 1.
    static func quantizedDensity(_ need: Double) -> Double {
        guard need.isFinite, need > 0 else { return 1 }
        guard need < 0.999 else { return 1 }
        let step = (log2(need) * 2).rounded(.up) / 2
        return min(1, max(1.0 / 64, pow(2, step)))
    }

    /// An image layer's content (its develop, local adjustments), from the content cache when it holds it (D12), else
    /// rendered and, on a settled on-screen frame, materialised for the next ones.
    func imageContent(_ layer: Layer, asset: MediaAsset, density: Double, options: Options, log: KeyLog?, capture: MaskCapture?,
                      canMaterialize: Bool) async throws -> CIImage {
        let usesCache = FeatureFlags.isOn(.contentHashCache) && capture == nil && !options.isExportPass && options.regionOfInterest == nil
        let key = usesCache ? cacheContentKey(layer, options: options) : nil
        if let key {
            if let hit = contentCache.image(content: key, density: density) { return hit }
            if !options.allowExpensiveWork, let scaled = contentCache.scaled(content: key, density: density) { return scaled }
        }
        let image = try await renderImageLayer(layer, asset: asset, scale: density, options: options, log: log, capture: capture)
        let atOrigin = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let key, canMaterialize, options.isDisplayed, options.allowExpensiveWork,
           let bitmap = contentCache.materialize(atOrigin, content: key, density: density) {
            return bitmap
        }
        return atOrigin
    }

    /// The content cache's key: D12's content key and what the render options change in the pixels.
    func cacheContentKey(_ layer: Layer, options: Options) -> String {
        "\(contentKey(of: layer))|L\(options.includesLocalAdjustments ? 1 : 0)|T\(options.interactionTarget?.uuidString ?? "-")"
    }

    /// The id the content key hashes in place of the layer's own, so a duplicated layer shares its materialised pixels.
    static let contentKeyID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    /// The content cache's key of a layer: a process-local hash of what its pixels depend on before placement and
    /// masks (its content, operations, develop recipe and local adjustments; not its placement, opacity, blend, masks,
    /// name or locks), recomputed only when those change. The content cache and the thumbnails live in memory only,
    /// so a hash is enough: `RenderKeys.layerContentKey`'s JSON (milliseconds for a long brush) never runs per frame.
    /// `layerMasked` applies the masks after the cached content, so a mask edit keeps it.
    func contentKey(of layer: Layer) -> String {
        var relevant = layer
        relevant.transform = .identity
        relevant.opacity = 1
        relevant.fillOpacity = 1
        relevant.blendMode = .normal
        relevant.isVisible = true
        relevant.isClipped = false
        relevant.parentID = nil
        relevant.name = ""
        relevant.refNumber = nil
        relevant.bakedMask = nil
        relevant.lockOptions = []
        relevant.isLocked = false
        relevant.maskStack = nil
        relevant.mask = nil
        relevant.isMaskEnabled = true
        relevant.isMaskLinked = true
        relevant.id = Self.contentKeyID
        if let memo = contentKeyMemo[layer.id], memo.layer == relevant { return memo.key }
        var hasher = Hasher()
        hasher.combine(relevant)
        // The operation count guards against a collision between two states of one layer (MaskRasterizer's convention).
        let key = String(UInt(bitPattern: hasher.finalize()), radix: 36) + "-\(relevant.edits.operations.count)"
        contentKeyMemo[layer.id] = (relevant, key)
        if contentKeyMemo.count > 256 { contentKeyMemo.removeAll() }
        return key
    }

    /// D12: the chained keys of an image layer's operations, by operation id; W2's ids with the flag off.
    func operationKeys(for layer: Layer, asset: MediaAsset) -> [UUID: String] {
        guard FeatureFlags.isOn(.contentHashCache) else {
            return Dictionary(layer.edits.operations.map { ($0.id, $0.id.uuidString) }, uniquingKeysWith: { _, last in last })
        }
        // The chain hashes only the operations that move pixels: a dial drag (a develop or local operation) keeps it.
        let placed = RenderSnapshot.placedOperations(layer.edits)
        if let memo = operationKeyMemo[layer.id], memo.source == asset, memo.operations == placed { return memo.keys }
        let keys = RenderKeys.operationKeys(source: asset, edits: layer.edits)
        operationKeyMemo[layer.id] = (asset, placed, keys)
        if operationKeyMemo.count > 256 { operationKeyMemo.removeAll() }
        for (id, key) in keys { chainOwners[key] = id }
        if chainOwners.count > 4096 { chainOwners.removeAll() }
        return keys
    }

    /// The legacy mask and a linked stack applied to `content` (content space); an unlinked stack returned apart, in
    /// canvas space (D8). Content alpha × legacy × stack, raw mask values. Fill layers' content space is the canvas.
    func layerMasked(_ layer: Layer, content: CIImage, canvas: CGRect, mode: MaskRasterizer.Mode) -> (content: CIImage, canvasMask: CIImage?) {
        var image = content
        let extent = content.extent
        if let legacy = layer.mask, let mask = loadMask(legacy, fitting: extent) {
            image = AdjustmentPipeline.applyingAlpha(mask: mask, to: image)
        }
        guard layer.isMaskEnabled, let stack = layer.maskStack, !stack.isEmpty else { return (image, nil) }
        if layer.isMaskLinked || layer.isFill {
            let mask = rasterizer.mask(stack, extent: extent, preLocal: content, mode: mode, owner: layer.id)
            return (AdjustmentPipeline.applyingAlpha(mask: mask, to: image), nil)
        }
        return (image, rasterizer.mask(stack, extent: canvas, preLocal: nil, mode: mode, owner: layer.id))
    }

    /// An adjustment layer's or a group's mask on the canvas (legacy × stack), placed through `map` when linked to a
    /// transformed group; nil without one.
    func canvasMask(of layer: Layer, canvas: CGRect, map: PSHomography?, mode: MaskRasterizer.Mode) -> CIImage? {
        var mask: CIImage?
        if let legacy = layer.mask { mask = loadMask(legacy, fitting: canvas) }
        if layer.isMaskEnabled, let stack = layer.maskStack, !stack.isEmpty {
            let drawn = rasterizer.mask(stack, extent: canvas, preLocal: nil, mode: mode, owner: layer.id)
            mask = mask.map { Self.multiply($0, drawn) } ?? drawn
        }
        guard let mask else { return nil }
        if let map { return ContentPlacement.placeMask(mask, map: map, canvas: canvas) }
        return mask.cropped(to: canvas)
    }

    /// Two gray masks multiplied (raw values).
    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    /// A text or shape layer's raster at the canvas size, from the overlay cache (keyed without where it sits).
    func overlayContent(_ layer: Layer, canvas: CGRect) -> CIImage? {
        switch layer.content {
        case .text(let element):
            // Keyed without where the text sits: a drag or a turn places the same raster.
            return overlayImage(key: "\(layer.overlayRasterKey ?? "text-\(layer.id)")-\(Int(canvas.width))") {
                #if canImport(UIKit)
                return TextRasterizer.image(for: element, canvasSize: canvas.size).map { CIImage(cgImage: $0) }
                #else
                _ = element
                return nil
                #endif
            }
        case .shape(let shape):
            return overlayImage(key: "\(layer.overlayRasterKey ?? "shape-\(layer.id)")-\(Int(canvas.width))") {
                #if canImport(UIKit)
                return TextRasterizer.image(for: shape, canvasSize: canvas.size).map { CIImage(cgImage: $0) }
                #else
                _ = shape
                return nil
                #endif
            }
        default:
            return nil
        }
    }

    // MARK: - Layers

    private var disparityCache: [String: CIImage?] = [:]

    /// The capture's disparity map (Portrait photos), oriented like the image and scaled to `extent`.
    private func disparityMap(for asset: MediaAsset, fitting extent: CGRect) -> CIImage? {
        let entry: CIImage?
        if let cached = disparityCache[asset.relativePath] {
            entry = cached
        } else {
            let url = store.url(for: asset.relativePath, in: projectID)
            entry = CIImage(contentsOf: url, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true]).map(Self.materialized)
            disparityCache[asset.relativePath] = entry
        }
        guard let disparity = entry, disparity.extent.width > 1 else { return nil }
        let scaled = disparity.transformed(by: CGAffineTransform(scaleX: extent.width / disparity.extent.width, y: extent.height / disparity.extent.height))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX - scaled.extent.minX, y: extent.minY - scaled.extent.minY))
    }

    /// The disparity map decoded once, here, rather than lazily inside a draw on the main thread.
    /// Half-float in a linear space, so the depth values come back as they were.
    private static func materialized(_ disparity: CIImage) -> CIImage {
        let extent = disparity.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = RenderContext.shared.createCGImage(disparity, from: extent, format: .RGBAh, colorSpace: space, deferred: false) else { return disparity }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// A preview decodes its source eagerly, here, at the size it needs, never inside a draw on the main thread.
    /// A full-resolution render that is not displayed keeps the lazy full decode (HDR, RAW), except in an export
    /// pass, where an 8-bit JPEG or PNG is decoded once, eagerly, so its strips never decode it again (D14). A detail
    /// tile opens a source above 24 MP lazily (ROI-driven, tiled for HEIC) and anything else at its density.
    private func source(for asset: MediaAsset, scale: Double, isFullResolution: Bool, options: Options) throws -> CIImage {
        let longest = max(asset.pixelSize.width, asset.pixelSize.height)
        let targetSide = max(1, Int((longest * scale).rounded()))
        let url = store.url(for: asset.relativePath, in: projectID)
        let megapixels = asset.pixelSize.width * asset.pixelSize.height / 1_000_000
        let lazyDetail = options.regionOfInterest != nil && megapixels > ExportBudget.streamingThresholdMegapixels
        let eagerExport = isFullResolution && options.isExportPass && ImageSupport.decodesEagerly(at: url)
        let tag: String
        if lazyDetail || (isFullResolution && !eagerExport) {
            tag = "lazy"
        } else if eagerExport {
            tag = "full#export"
        } else {
            tag = String(targetSide)
        }
        let key = "\(asset.relativePath)@\(tag)"
        if let cached = sourceCache[key] {
            if let index = sourceOrder.lastIndex(of: key) { sourceOrder.remove(at: index) }
            sourceOrder.append(key)
            return cached.image
        }
        let image: CIImage
        let bytes: Int
        if tag == "lazy" {
            image = try ImageSupport.loadCIImage(at: url)
            bytes = 0
        } else if eagerExport {
            // The file's own samples, as the lazy full-resolution render reads them (a thumbnail redraws them).
            let decoded = try ImageSupport.loadDecodedImage(at: url)
            image = decoded.image
            bytes = decoded.bytes
            exportSourceBytes += bytes
        } else {
            let cg = try ImageSupport.loadCGImage(at: url, maxPixelSize: targetSide)
            image = CIImage(cgImage: cg)
            bytes = cg.bytesPerRow * cg.height
        }
        sourceCache[key] = (image, bytes)
        sourceOrder.append(key)
        sourceBytes += bytes
        let limit = options.regionOfInterest != nil ? Self.detailSourceByteLimit : Self.sourceByteLimit
        // Least recently used out first (the preview's before a tile's), never the source just decoded.
        while sourceOrder.count > 1, sourceBytes > limit || sourceOrder.count > Self.sourceEntryLimit {
            guard let victim = sourceOrder.first(where: { $0 != key && !$0.hasSuffix("#export") }) else { break }
            removeSource(victim)
        }
        return image
    }

    private func removeSource(_ key: String) {
        sourceBytes -= sourceCache.removeValue(forKey: key)?.bytes ?? 0
        sourceOrder.removeAll { $0 == key }
    }

    private func clearSources() {
        sourceCache.removeAll()
        sourceOrder.removeAll()
        sourceBytes = 0
        exportSourceBytes = 0
    }

    /// Bytes of decoded sources held (tests).
    var sourceBytesHeld: Int { sourceBytes }

    /// A mask at `extent`, feathered and inverted as stored. Rendered once per size
    /// and kept (least recently used out first), so a dial drag over a masked edit
    /// never decodes a PNG or re-runs the feather blur. Fractional frames (placed
    /// layers) and very large ones (export) are loaded as they are.
    func loadMask(_ mask: MaskReference, fitting extent: CGRect) -> CIImage? {
        guard extent == extent.integral, extent.width * extent.height <= 4096 * 4096, !extent.isEmpty else {
            return maskStore.load(mask, fitting: extent)
        }
        let key = "\(mask.relativePath)|\(Int(extent.width))x\(Int(extent.height))|\(mask.feather)|\(mask.isInverted)"
        let origin = CGAffineTransform(translationX: extent.minX, y: extent.minY)
        if let cached = maskCache[key] {
            if let index = maskOrder.lastIndex(of: key) { maskOrder.remove(at: index) }
            maskOrder.append(key)
            return cached.transformed(by: origin)
        }
        let size = CGRect(origin: .zero, size: extent.size)
        guard let loaded = maskStore.load(mask, fitting: size) else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let cg = RenderContext.shared.createCGImage(loaded, from: size, format: .L8, colorSpace: gray, deferred: false) else {
            return loaded.transformed(by: origin)
        }
        let flat = CIImage(cgImage: cg)
        maskCache[key] = flat
        maskOrder.append(key)
        while maskOrder.count > Self.maskCacheLimit {
            maskCache[maskOrder.removeFirst()] = nil
        }
        return flat.transformed(by: origin)
    }

    func renderImageLayer(_ layer: Layer, asset: MediaAsset, scale: Double, options: Options, log: KeyLog? = nil, capture: MaskCapture? = nil) async throws -> CIImage {
        let image = try await preDevelopImage(layer, asset: asset, scale: scale, options: options, log: log)
        if options.showOriginal { return image }
        let effectiveScale = image.extent.width / max(1, asset.pixelSize.width)
        let developed = DevelopRenderer.apply(developRecipe(for: layer), to: image, scale: effectiveScale,
                                              cubes: options.allowExpensiveWork ? .settled : .interactive, colorCube: colorCube,
                                              lutURL: { self.store.url(for: $0, in: self.projectID) })
        // Local adjustments come last, each through its mask, Lightroom-style (W2, D2).
        return applyLocalAdjustments(of: layer, to: developed, scale: effectiveScale, options: options, capture: capture)
    }

    /// The image layer's pixels after its operation loop, before the develop step: what a `.layerDevelop` snapshot
    /// captures (D13). `showOriginal` returns the source as decoded.
    func preDevelopImage(_ layer: Layer, asset: MediaAsset, scale: Double, options: Options, log: KeyLog? = nil) async throws -> CIImage {
        // Only an off-screen full-size render (export) keeps the lazy decode; what is drawn is decoded here.
        var image = try source(for: asset, scale: scale, isFullResolution: scale >= 0.999 && !options.isDisplayed, options: options)
        // Actual ratio between this render and the original (thumbnail loader rounds).
        let effectiveScale = image.extent.width / max(1, asset.pixelSize.width)
        if options.showOriginal { return image }

        // Focus from the camera's depth map happens on the capture itself, before any other edit.
        if let lens = layer.edits.resolvedLensBlur, !layer.edits.hasGeometry, let disparity = disparityMap(for: asset, fitting: image.extent) {
            image = LensBlur.apply(to: image, disparity: disparity, focus: lens.focus, aperture: lens.aperture)
        }
        let keys = operationKeys(for: layer, asset: asset)
        for operation in layer.edits.operations {
            image = try await apply(operation, to: image, layer: layer, chainKey: keys[operation.id] ?? operation.id.uuidString,
                                    scale: effectiveScale, options: options, log: log)
        }
        return image
    }

    /// The develop recipe of an image layer, its tone table from the renderer's cache.
    func developRecipe(for layer: Layer) -> DevelopRenderer.Recipe {
        DevelopRenderer.Recipe(edits: layer.edits, extra: nil, tone: toneTable(for: layer.edits))
    }

    /// The layer's tone table, nil when Levels and its curve change nothing. Kept by its inputs.
    func toneTable(for edits: EditStack) -> ToneLUT? {
        let levels = edits.resolvedLevels
        let curve = edits.resolvedUserToneCurve
        guard !levels.isIdentity || curve != nil else { return nil }
        var hasher = Hasher()
        hasher.combine(levels)
        hasher.combine(curve)
        let key = hasher.finalize()
        if let cached = toneTables[key] { return cached }
        let table = edits.resolvedToneLUT
        if toneTables.count >= 8 { toneTables.removeAll() }
        toneTables[key] = table
        return table
    }

    /// The mask of brush strokes at `extent` (linear grey, so a soft edge is the brush's own
    /// falloff), drawn once per stroke list and size; with its bytes for a bounding box.
    private func strokeMask(_ strokes: [BrushStroke], extent: CGRect) -> (image: CIImage, bytes: [UInt8])? {
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        let raster = strokeRasters.mask(for: strokes, width: width, height: height)
        let origin = CGAffineTransform(translationX: extent.minX, y: extent.minY)
        if !raster.isNew, let image = strokeMasks[raster.key] { return (image.transformed(by: origin), raster.bytes) }
        guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: raster.bytes, colorSpace: RenderContext.maskColorSpace) else { return nil }
        let image = CIImage(cgImage: cg)
        strokeMasks[raster.key] = image
        if strokeMasks.count > strokeRasters.count {
            let live = strokeRasters.keys
            strokeMasks = strokeMasks.filter { live.contains($0.key) }
        }
        return (image.transformed(by: origin), raster.bytes)
    }

    private func clearStrokeMasks() {
        strokeRasters.removeAll()
        strokeMasks.removeAll()
        toneTables.removeAll()
    }

    // MARK: - Expensive work

    /// The result for `key` when it is cached or being computed, else the same
    /// operation's result at another size, scaled. A larger result stands in for a
    /// smaller one at no loss; a smaller one only while interacting (no expensive work).
    private func reusedResult(key: String, chainKey: String, extent: CGRect, options: Options, log: KeyLog?) async throws -> CIImage? {
        if let cached = operationCache[key] {
            touch(key)
            log?.keys.insert(key)
            return cached
        }
        if options.allowExpensiveWork {
            // The same step is running, at this size or a larger one: wait for it rather than start another.
            let running = inFlight[key].map { (key: key, value: $0) }
                ?? inFlight.first { Self.isResult(of: chainKey, key: $0.key, reusableFor: extent, allowUpscale: false) }
            if let running {
                do {
                    let image = try await join(running.value, key: running.key)
                    if running.key == key {
                        log?.keys.insert(key)
                        return image
                    }
                } catch let error as CancellationError {
                    // Abandoned by every other render: this one computes it below.
                    if Task.isCancelled { throw error }
                }
            }
        }
        return scaledResult(of: chainKey, to: extent, allowUpscale: !options.allowExpensiveWork, log: log)
    }

    /// Input size encoded in a cache key ("<key>@WxH").
    private static func inputSize(inKey key: String) -> CGSize? {
        guard let at = key.lastIndex(of: "@") else { return nil }
        let parts = key[key.index(after: at)...].split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Whether `key` holds the result of the step whose chained key is `chainKey` (D12: by the prefix before "@"),
    /// at a size that can stand in for `extent`.
    static func isResult(of chainKey: String, key: String, reusableFor extent: CGRect, allowUpscale: Bool) -> Bool {
        guard key.hasPrefix(chainKey + "@"), let size = inputSize(inKey: key) else { return false }
        guard extent.width > 0, extent.height > 0 else { return false }
        // Same framing only: a result for a different crop is not this one resized.
        guard abs(size.width / size.height - extent.width / extent.height) < 0.01 else { return false }
        return allowUpscale || size.width >= extent.width - 0.5
    }

    private func scaledResult(of chainKey: String, to extent: CGRect, allowUpscale: Bool, log: KeyLog?) -> CIImage? {
        var best: (key: String, size: CGSize, image: CIImage)?
        for key in operationOrder where Self.isResult(of: chainKey, key: key, reusableFor: extent, allowUpscale: allowUpscale) {
            guard let image = operationCache[key], let size = Self.inputSize(inKey: key) else { continue }
            let resultExtent = image.extent
            guard !resultExtent.isInfinite, resultExtent.width.isFinite, resultExtent.height.isFinite, resultExtent.width > 0, resultExtent.height > 0 else { continue }
            if best.map({ size.width > $0.size.width }) ?? true { best = (key, size, image) }
        }
        guard let best else { return nil }
        touch(best.key)
        log?.keys.insert(best.key)
        let sx = extent.width / best.size.width, sy = extent.height / best.size.height
        let source = best.image.extent
        // Most steps keep their input's frame; an expand grows it by the same ratio.
        let keepsFrame = abs(source.width - best.size.width) < 0.5 && abs(source.height - best.size.height) < 0.5
        let target = keepsFrame
            ? extent
            : CGRect(x: (source.minX * sx).rounded(), y: (source.minY * sy).rounded(), width: (source.width * sx).rounded(), height: (source.height * sy).rounded())
        guard target.width >= 1, target.height >= 1 else { return nil }
        let transform = CGAffineTransform(translationX: target.minX, y: target.minY)
            .scaledBy(x: target.width / source.width, y: target.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
        return best.image.transformed(by: transform).cropped(to: target)
    }

    /// Computes an expensive result once for every render that asks for it and caches it.
    /// A job that everyone stopped waiting for is cancelled and never cached.
    private func runExpensive(key: String, step: String, log: KeyLog?, work: @escaping @Sendable () async throws -> CIImage) async throws -> CIImage {
        log?.keys.insert(key)
        var attempts = 0
        while true {
            attempts += 1
            let job: Task<CIImage, Error>
            if let running = inFlight[key] {
                job = running
            } else {
                relieveMemoryIfNeeded(before: step)
                ImagingBreadcrumbs.note("\(step) started · \(MemoryBudget.availableDescription) free")
                expensiveRuns += 1
                job = Task<CIImage, Error> {
                    let image = try await work()
                    try Task.checkCancellation()
                    return image
                }
                inFlight[key] = job
            }
            do {
                return try await join(job, key: key)
            } catch let error as CancellationError {
                // Abandoned by the renders that were waiting just before this one joined: start again once.
                guard !Task.isCancelled, attempts < 2 else { throw error }
            }
        }
    }

    private func join(_ job: Task<CIImage, Error>, key: String) async throws -> CIImage {
        let token = UUID()
        inFlightWaiters[key, default: []].insert(token)
        let outcome = await withTaskCancellationHandler {
            await job.result
        } onCancel: {
            Task { await self.leave(key, token: token, cancelling: job) }
        }
        leave(key, token: token, cancelling: nil)
        switch outcome {
        case .success(let image):
            if inFlight[key] == job {
                inFlight[key] = nil
                cacheOperation(image, for: key)
                ImagingBreadcrumbs.note("step finished · \(MemoryBudget.availableDescription) free")
            }
            return image
        case .failure(let error):
            if inFlight[key] == job { inFlight[key] = nil }
            throw error
        }
    }

    private func leave(_ key: String, token: UUID, cancelling job: Task<CIImage, Error>?) {
        inFlightWaiters[key]?.remove(token)
        if inFlightWaiters[key]?.isEmpty == true { inFlightWaiters[key] = nil }
        guard let job, inFlightWaiters[key] == nil, inFlight[key] == job else { return }
        // The render that replaces a cancelled one usually asks for the same step right
        // away (a slider settled, a panel opened): give it a moment to join first.
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.cancelIfAbandoned(job, key: key)
        }
    }

    private func cancelIfAbandoned(_ job: Task<CIImage, Error>, key: String) {
        guard inFlightWaiters[key] == nil, inFlight[key] == job else { return }
        job.cancel()
        inFlight[key] = nil
        ImagingBreadcrumbs.note("step cancelled")
    }

    /// Before a heavy job: when the system is short of memory, free what can be rebuilt.
    private func relieveMemoryIfNeeded(before step: String) {
        guard MemoryBudget.isLow else { return }
        PSLog.info("low memory before \(step) (\(MemoryBudget.availableDescription)): trimming caches", category: .imaging)
        trimForMemoryPressure()
    }

    /// One operation of the loop. `chainKey` is D12's content key after it (the operation id with the flag off).
    private func apply(_ operation: EditOperation, to input: CIImage, layer: Layer, chainKey: String, scale: Double, options: Options, log: KeyLog?) async throws -> CIImage {
        let extent = input.extent
        // An unbounded or non-finite extent would trap in the Int conversions below.
        guard !extent.isInfinite, extent.width.isFinite, extent.height.isFinite else { return input }
        let cacheKey = "\(chainKey)@\(Int(extent.width))x\(Int(extent.height))"
        switch operation.kind {
        case .adjust, .adjustments, .toneCurve, .levels, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut:
            return input

        case .unsupported:
            // A kind from a newer build: kept in the document, drawn as nothing.
            return input

        case .localAdjust:
            // Rendered after the layer's develop recipe, through its mask (W2, D2): never in the operation loop.
            return input

        case .lensBlur(let focus, let aperture, let mask):
            // Done with the depth map at the source when there is one; the subject mask is the fallback.
            guard layer.edits.resolvedLensBlur?.focus == focus else { return input }
            if !layer.edits.hasGeometry, let asset = layer.imageAsset, disparityMap(for: asset, fitting: extent) != nil { return input }
            guard let mask, let maskImage = loadMask(mask, fitting: extent) else { return input }
            return LensBlur.apply(to: input, subjectMask: maskImage, focus: focus, aperture: aperture)

        case .crop(let rect):
            // The whole pixels Core counts (the document's canvas, D10b), top-left origin turned to Core Image's, on the
            // image's own rounded pixel grid: a non-quarter rotate leaves a fractional extent, which Core rounds, and a
            // whole-pixel crop rect and translation never resample the picture.
            let grid = CGRect(x: extent.minX.rounded(), y: extent.minY.rounded(), width: extent.width.rounded(), height: extent.height.rounded())
            guard let pixels = EditOperation.Kind.pixelCrop(rect, in: PSSize(width: Double(grid.width), height: Double(grid.height))) else { return input }
            let cropRect = CGRect(x: grid.minX + CGFloat(pixels.minX), y: grid.maxY - CGFloat(pixels.maxY), width: CGFloat(pixels.width), height: CGFloat(pixels.height))
            return input.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        case .rotate(let degrees):
            return rotated(input, degrees: degrees, cropToContent: false)

        case .straighten(let degrees):
            return rotated(input, degrees: degrees, cropToContent: true)

        case .flip(let axis):
            let transform = axis == .horizontal ? CGAffineTransform(scaleX: -1, y: 1) : CGAffineTransform(scaleX: 1, y: -1)
            let flipped = input.transformed(by: transform)
            return flipped.transformed(by: CGAffineTransform(translationX: -flipped.extent.minX, y: -flipped.extent.minY))

        case .perspective(let horizontal, let vertical):
            return perspective(input, horizontal: horizontal, vertical: vertical)

        case .expand(let placement):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard placement.width > 0.05, placement.height > 0.05 else { return input }
            let canvas = CGRect(x: 0, y: 0, width: (extent.width / placement.width).rounded(), height: (extent.height / placement.height).rounded())
            let origin = CGPoint(x: (placement.minX * canvas.width).rounded(), y: ((1 - placement.maxY) * canvas.height).rounded())
            let placed = input.transformed(by: CGAffineTransform(translationX: origin.x - extent.minX, y: origin.y - extent.minY))
            // Edge pixels stretched outwards: a seed the filler continues, and the live preview meanwhile.
            let seed = placed.clampedToExtent().cropped(to: canvas)
            guard options.allowExpensiveWork else {
                return placed.composited(over: seed.clampedToExtent().applyingGaussianBlur(sigma: 0.02 * max(canvas.width, canvas.height)).cropped(to: canvas))
            }
            let hole = CIImage(color: .white).cropped(to: canvas)
            let keep = CIImage(color: .black).cropped(to: placed.extent.insetBy(dx: 2, dy: 2))
            let mask = keep.composited(over: hole)
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "expand", log: log) {
                if inpainting.hasGenerativeEngine {
                    return try await inpainting.generate(image: seed, mask: mask, boundingBox: .unit, prompt: "seamless continuation of the scene, same light, same style")
                }
                return try await inpainting.fill(image: seed, mask: mask, boundingBox: .unit, feather: 0.01)
            }

        case .blurRegion(let mask, let amount):
            guard let maskImage = loadMask(mask, fitting: extent) else { return input }
            let sigma = max(4, 0.025 * max(extent.width, extent.height) * amount)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            let soft = maskImage.clampedToExtent().applyingGaussianBlur(sigma: max(1, 2 * scale)).cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: blurred, background: input, mask: soft)

        case .moveObject(let mask, let offset):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard let maskImage = loadMask(mask, fitting: extent) else { return input }
            // The object lifted with a soft edge, carried to its new place.
            let edge = maskImage.clampedToExtent().applyingGaussianBlur(sigma: max(0.8, 1.4 * scale)).cropped(to: extent)
            let lifted = AdjustmentPipeline.applyingAlpha(mask: edge, to: input)
            let moved = lifted.transformed(by: CGAffineTransform(translationX: offset.x * extent.width, y: -offset.y * extent.height)).cropped(to: extent)
            // While a slider moves, the object is shown at its new place over the untouched picture.
            guard options.allowExpensiveWork else { return moved.composited(over: input) }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "move", log: log) {
                let filled = try await inpainting.fill(image: input, mask: maskImage, boundingBox: mask.boundingBox, feather: mask.feather)
                return moved.composited(over: filled)
            }

        case .removeObject(let mask):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork, let maskImage = loadMask(mask, fitting: extent) else { return input }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "erase", log: log) {
                try await inpainting.fill(image: input, mask: maskImage, boundingBox: mask.boundingBox, feather: mask.feather)
            }

        case .heal(let strokes):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork else { return input }
            // A hole to fill has no soft edge: the erase brush is drawn hard, whatever its hardness.
            let hard = strokes.map { BrushStroke(id: $0.id, points: $0.points, radius: $0.radius, hardness: 1, mode: $0.mode) }
            guard let raster = strokeMask(hard, extent: extent) else { return input }
            let maskImage = raster.image
            let box = MaskStore.boundingBox(of: raster.bytes, width: Int(extent.width), height: Int(extent.height))
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "heal", log: log) {
                try await inpainting.fill(image: input, mask: maskImage, boundingBox: box, feather: 0.01)
            }

        case .removeBackground(let mask):
            guard let mask, let maskImage = loadMask(mask, fitting: extent) else { return input }
            // Select & Mask's colour decontamination first (W2): the fringe takes the subject's colour.
            let source = EdgeRefine.decontaminate(input, alpha: maskImage, amount: mask.decontaminate ?? 0)
            return AdjustmentPipeline.applyingAlpha(mask: maskImage, to: source)

        case .replaceBackground(let background, let mask):
            guard let mask, let maskImage = loadMask(mask, fitting: extent) else { return input }
            let backdrop = BackgroundEffects.backdrop(for: background, original: input, scale: scale, store: store, projectID: projectID)
            let source = EdgeRefine.decontaminate(input, alpha: maskImage, amount: mask.decontaminate ?? 0)
            return AdjustmentPipeline.blendWithMask(foreground: source, background: backdrop, mask: maskImage)

        case .blurBackground(let amount, let mask):
            guard let mask, let maskImage = loadMask(mask, fitting: extent) else { return input }
            return BackgroundEffects.portraitBlur(input, subjectMask: maskImage, amount: amount, scale: scale)

        case .selectiveAdjust(let mask, let adjustments):
            guard let maskImage = loadMask(mask, fitting: extent) else { return input }
            let adjusted = AdjustmentPipeline.apply(adjustments, toneCurve: .identity, to: input, scale: scale)
            return AdjustmentPipeline.blendWithMask(foreground: adjusted, background: input, mask: maskImage)

        case .upscale(let factor):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork else { return input }
            let upscaler = self.upscaler
            return try await runExpensive(key: cacheKey, step: "upscale", log: log) {
                try await upscaler.upscale(input, factor: factor)
            }

        case .denoise(let amount):
            let filter = CIFilter.noiseReduction()
            filter.inputImage = input
            filter.noiseLevel = Float(amount * 0.1)
            filter.sharpness = 0.4
            return filter.outputImage?.cropped(to: extent) ?? input

        case .sharpen(let amount):
            let filter = CIFilter.unsharpMask()
            filter.inputImage = input
            filter.radius = Float(2.5 * scale)
            filter.intensity = Float(amount * 1.5)
            return filter.outputImage?.cropped(to: extent) ?? input

        case .relight(let direction, let intensity):
            return BackgroundEffects.relight(input, direction: direction, intensity: intensity)

        case .generativeFill(let mask, let prompt):
            let reused = try await reusedResult(key: cacheKey, chainKey: chainKey, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork, let maskImage = loadMask(mask, fitting: extent) else { return input }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "generate", log: log) {
                try await inpainting.generate(image: input, mask: maskImage, boundingBox: mask.boundingBox, prompt: prompt)
            }

        case .recolor(let mask, let color, let strength):
            guard let maskImage = loadMask(mask, fitting: extent) else { return input }
            return BackgroundEffects.recolor(input, mask: maskImage, color: color, strength: strength)

        case .cloneStamp(let strokes, let offset):
            // The strokes' mask is drawn once (hardness honoured), then reused by every render.
            guard let raster = strokeMask(strokes, extent: extent) else { return input }
            let maskImage = raster.image.clampedToExtent().applyingGaussianBlur(sigma: 1.5 * scale).cropped(to: extent)
            // Source pixels come from the image shifted by the (normalised) offset; y flips because CI is bottom-up.
            let shifted = input.transformed(by: CGAffineTransform(translationX: -CGFloat(offset.x) * extent.width, y: CGFloat(offset.y) * extent.height)).clampedToExtent().cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: shifted, background: input, mask: maskImage)

        case .pixelPaint(let strokes, let color):
            guard let raster = strokeMask(strokes, extent: extent) else { return input }
            let maskImage = raster.image
            let paint = CIImage(color: color.ciColor).cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: paint, background: input, mask: maskImage)
        }
    }

    // MARK: - Geometry

    private func rotated(_ image: CIImage, degrees: Double, cropToContent: Bool) -> CIImage {
        guard degrees != 0 else { return image }
        let radians = -degrees * .pi / 180 // our degrees are clockwise; Core Image rotates counter-clockwise
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: CGFloat(radians))
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        var rotated = image.transformed(by: transform)
        if cropToContent {
            // Largest axis-aligned rectangle with the original aspect that fits inside the rotated image.
            let angle = abs(radians.truncatingRemainder(dividingBy: .pi / 2))
            let w = extent.width, h = extent.height
            let sinA = abs(sin(angle)), cosA = abs(cos(angle))
            let scale = min(w / (w * cosA + h * sinA), h / (w * sinA + h * cosA))
            let cropSize = CGSize(width: w * scale, height: h * scale)
            let cropRect = CGRect(x: rotated.extent.midX - cropSize.width / 2, y: rotated.extent.midY - cropSize.height / 2, width: cropSize.width, height: cropSize.height).integral
            rotated = rotated.cropped(to: cropRect)
        }
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    private func perspective(_ image: CIImage, horizontal: Double, vertical: Double) -> CIImage {
        guard horizontal != 0 || vertical != 0 else { return image }
        let extent = image.extent
        let w = extent.width, h = extent.height
        var tl = CGPoint(x: extent.minX, y: extent.maxY)
        var tr = CGPoint(x: extent.maxX, y: extent.maxY)
        var bl = CGPoint(x: extent.minX, y: extent.minY)
        var br = CGPoint(x: extent.maxX, y: extent.minY)
        let hAmount = CGFloat(horizontal.clamped(to: -1...1)) * h * 0.15
        let vAmount = CGFloat(vertical.clamped(to: -1...1)) * w * 0.15
        if hAmount > 0 { tl.y -= hAmount; bl.y += hAmount } else { tr.y += hAmount; br.y -= hAmount }
        if vAmount > 0 { tl.x += vAmount; tr.x -= vAmount } else { bl.x -= vAmount; br.x += vAmount }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomLeft = bl
        filter.bottomRight = br
        guard let output = filter.outputImage else { return image }
        let cropped = output.cropped(to: output.extent.integral)
        return cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
    }

    // MARK: - Overlay rasters

    private func overlayImage(key: String, make: () -> CIImage?) -> CIImage? {
        overlayTick += 1
        if let cached = overlayCache[key] {
            overlayUse[key] = overlayTick
            return cached
        }
        overlayRasterizations += 1
        guard let image = make() else { return nil }
        overlayCache[key] = image
        overlayUse[key] = overlayTick
        overlayBytes += Self.rasterBytes(of: image)
        if overlayCache.count > Self.overlayCacheLimit || overlayBytes > Self.overlayByteLimit {
            // Out go the least recently used, down to three quarters of the limits (one sort per eviction).
            for old in overlayUse.sorted(by: { $0.value < $1.value }).map(\.key) where old != key {
                guard overlayCache.count > Self.overlayCacheLimit * 3 / 4 || overlayBytes > Self.overlayByteLimit * 3 / 4 else { break }
                if let evicted = overlayCache.removeValue(forKey: old) { overlayBytes -= Self.rasterBytes(of: evicted) }
                overlayUse[old] = nil
            }
        }
        return image
    }

    private func clearOverlays() {
        overlayCache.removeAll()
        overlayUse.removeAll()
        overlayBytes = 0
    }

    /// Bytes of a rasterised image (RGBA of its extent).
    static func rasterBytes(of image: CIImage) -> Int {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, !extent.isEmpty else { return 0 }
        return Int(extent.width * extent.height) * 4
    }

    /// Dissolve's noise offset for a layer, from its id: the same grain on every frame and every launch.
    static func dissolveSeed(for id: UUID) -> UInt64 {
        let b = id.uuid
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The rendered document read back as top-down RGBA8 in Display P3 (tests, pixel probes).
    func renderedRGBA(_ document: PhotoDocument, options: Options = .full) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let image = try await render(document, options: options)
        let extent = image.extent.integral
        guard let bytes = ImageSupport.rgbaBytes(of: image, rect: extent) else { throw PicshopError.renderFailed("readback") }
        return (bytes, Int(extent.width), Int(extent.height))
    }
}
#endif
