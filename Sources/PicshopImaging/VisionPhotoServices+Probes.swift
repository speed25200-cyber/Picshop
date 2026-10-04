#if canImport(Vision) && canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore
import PicshopIntent

// W2 pixel postconditions (D14, §6 item 10): `before` and `after` rendered at 256 px without expensive work (earlier
// erase, generate or upscale results are reused from the renderer's cache, scaled, and none ever starts), read back
// in gamma sRGB, and measured in CIE Lab per region by Core's `PixelStats`. The executor runs the whole call inside
// its 2 s `Deadline`; a cancelled call answers unmeasured.
//
// Which mask measures which render:
// - `maskedParameter` and `selectionUse` compare the same pixels before and after: both renders are measured
//   through one mask, the region as it is after (or before, when the call removed it: a selection used and cleared);
// - the mask-shape probes (`maskCoverageInRange`, `maskCoverage`, `maskInverted`, `maskSoftness`, `maskPeak` and the
//   selection ones) measure each render through its own document's mask, so `Regions.coverage` (mean m) moves
//   with the edit; a region missing on one side is unmeasured there (nil).
extension VisionPhotoServices {
    /// The probe proxies' longest side.
    static let probeSide = 256

    public func pixelProbes(_ requests: [PixelProbeRequest], before: PhotoDocument, after: PhotoDocument) async -> [PixelProbeResult] {
        guard !requests.isEmpty else { return [] }
        let unmeasured = requests.map { PixelProbeResult(request: $0, before: nil, after: nil) }
        let signpost = PSSignpost.begin("probe.pixels", "\(requests.count)")
        defer { PSSignpost.end(signpost) }
        let options = Self.probeOptions
        guard let beforeFrame = try? await maskRenderer.renderedSRGB(before, options: options), !Task.isCancelled,
              let afterFrame = try? await maskRenderer.renderedSRGB(after, options: options), !Task.isCancelled else { return unmeasured }
        var results: [PixelProbeResult] = []
        // W3 (§4.8): the composite probes compare the two renders pixel by pixel, once for every such request.
        var delta: PixelStats.CompositeDelta?
        if requests.contains(where: { $0.probe == .compositeUnchanged || $0.probe == .compositeChanged }),
           beforeFrame.width == afterFrame.width, beforeFrame.height == afterFrame.height {
            delta = PixelStats.compositeDelta(before: beforeFrame.bytes, after: afterFrame.bytes, width: afterFrame.width, height: afterFrame.height)
        }
        for request in requests {
            guard !Task.isCancelled else {
                results.append(PixelProbeResult(request: request, before: nil, after: nil))
                continue
            }
            if request.probe == .layerMaskCoverageInRange {
                // W3: measured in the layer's own content space, so `coverage` is the share of the layer its mask keeps.
                results.append(await layerMaskProbe(request, before: before, after: after))
                continue
            }
            let masks = await probeMasks(request, before: before, after: after, beforeSize: (beforeFrame.width, beforeFrame.height),
                                         afterSize: (afterFrame.width, afterFrame.height))
            let beforeStats = masks.before.map { PixelStats.regions(rgba: beforeFrame.bytes, width: beforeFrame.width, height: beforeFrame.height, mask: $0) }
            let afterStats = masks.after.map { PixelStats.regions(rgba: afterFrame.bytes, width: afterFrame.width, height: afterFrame.height, mask: $0) }
            let isComposite = request.probe == .compositeUnchanged || request.probe == .compositeChanged
            results.append(PixelProbeResult(request: request, before: beforeStats, after: afterStats, compositeDelta: isComposite ? delta : nil))
        }
        return results
    }

    /// 256 px, no expensive work, no overlays beyond the document's own layers (they are part of the picture).
    static var probeOptions: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(probeSide), includeOverlays: true, allowExpensiveWork: false)
    }

    /// Whether a probe measures both renders through the same mask.
    static func usesOneMask(_ probe: PixelProbe) -> Bool {
        switch probe {
        case .maskedParameter, .selectionUse: return true
        case .maskCoverageInRange, .maskCoverage, .maskInverted, .maskSoftness, .maskPeak, .selectionCoverageInRange, .selectionCoverage: return false
        // W3: whole-composite and layer-mask probes are not measured through a shared region mask.
        case .compositeUnchanged, .compositeChanged, .layerMaskCoverageInRange: return false
        }
    }

    /// W3 `layerMaskCoverageInRange`: the layer whose mask the call made or changed (the selected one first), its
    /// content and mask in its content space at the probe size, measured on each side that has it.
    func layerMaskProbe(_ request: PixelProbeRequest, before: PhotoDocument, after: PhotoDocument) async -> PixelProbeResult {
        guard let layerID = Self.layerWithChangedMask(before: before, after: after) else { return PixelProbeResult(request: request, before: nil, after: nil) }
        func measure(_ document: PhotoDocument) async -> PixelStats.Regions? {
            guard let probe = try? await maskRenderer.layerMaskProbe(document, layerID: layerID, side: Self.probeSide) else { return nil }
            return PixelStats.regions(rgba: probe.bytes, width: probe.width, height: probe.height, mask: probe.values)
        }
        let beforeStats = await measure(before)
        let afterStats = await measure(after)
        return PixelProbeResult(request: request, before: beforeStats, after: afterStats)
    }

    /// The layer whose mask differs between the two documents (legacy, stack, enabled, linked): the selected layer
    /// when it is one of them, else the topmost; nil when no mask changed.
    static func layerWithChangedMask(before: PhotoDocument, after: PhotoDocument) -> UUID? {
        let changed = after.layers.filter { layer in
            let hasMask = layer.mask != nil || (layer.maskStack.map { !$0.isEmpty } ?? false)
            guard let old = before.layer(id: layer.id) else { return hasMask }
            return old.mask != layer.mask || old.maskStack != layer.maskStack || old.isMaskEnabled != layer.isMaskEnabled || old.isMaskLinked != layer.isMaskLinked
        }
        if let selected = after.selectedLayerID, changed.contains(where: { $0.id == selected }) { return selected }
        return changed.last?.id
    }

    /// W3 (compositeUnchanged): per-pixel CIE ΔE76 between two gamma sRGB RGBA8 renders of the same size: the mean and
    /// the 99th percentile; nil when the sizes differ. Core's `PixelStats.compositeDelta`, which `pixelProbes` uses.
    public static func compositeDelta(before: [UInt8], after: [UInt8], width: Int, height: Int) -> (mean: Double, p99: Double)? {
        PixelStats.compositeDelta(before: before, after: after, width: width, height: height).map { ($0.mean, $0.p99) }
    }

    /// The masks a probe measures `before` and `after` through, each at its render's size.
    func probeMasks(_ request: PixelProbeRequest, before: PhotoDocument, after: PhotoDocument,
                    beforeSize: (Int, Int), afterSize: (Int, Int)) async -> (before: [Float]?, after: [Float]?) {
        if Self.usesOneMask(request.probe) {
            var shared = await regionMask(request.region, in: after)
            if shared == nil { shared = await regionMask(request.region, in: before) }
            guard let shared else { return (nil, nil) }
            return (Self.fitted(shared, to: beforeSize), Self.fitted(shared, to: afterSize))
        }
        let beforeMask = await regionMask(request.region, in: before)
        let afterMask = await regionMask(request.region, in: after)
        return (beforeMask.map { Self.fitted($0, to: beforeSize) }, afterMask.map { Self.fitted($0, to: afterSize) })
    }

    /// A region's mask (0…1, row 0 at the top) in `document` at the probe size; nil when the document has no such
    /// region.
    func regionMask(_ region: PixelProbeRequest.Region, in document: PhotoDocument) async -> (values: [Float], width: Int, height: Int)? {
        let options = Self.probeOptions
        switch region {
        case .localAdjustment(let id):
            guard let adjustment = document.localAdjustments.first(where: { $0.id == id }) else { return nil }
            return try? await maskRenderer.maskValues(adjustment.stack, document: document, options: options)
        case .selection:
            guard let selection = document.selection else { return nil }
            return try? await maskRenderer.selectionValues(selection, document: document, options: options)
        case .box(let rect):
            guard let size = Self.probeSize(document) else { return nil }
            let box = rect.clampedToUnit()
            var values = [Float](repeating: 0, count: size.width * size.height)
            for y in 0..<size.height {
                let ny = (Double(y) + 0.5) / Double(size.height)
                guard ny >= box.minY, ny <= box.maxY else { continue }
                for x in 0..<size.width {
                    let nx = (Double(x) + 0.5) / Double(size.width)
                    if nx >= box.minX, nx <= box.maxX { values[y * size.width + x] = 1 }
                }
            }
            return (values, size.width, size.height)
        case .whole:
            guard let size = Self.probeSize(document) else { return nil }
            return ([Float](repeating: 1, count: size.width * size.height), size.width, size.height)
        }
    }

    /// The canvas size at the probe scale (the canvas follows the base layer's output).
    static func probeSize(_ document: PhotoDocument) -> (width: Int, height: Int)? {
        let canvas = document.canvasSize
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let fitted = canvas.limited(toLongestSide: Double(probeSide))
        return (max(1, Int(fitted.width.rounded())), max(1, Int(fitted.height.rounded())))
    }

    /// A mask resampled to a render's size when they differ (rounding of the base's output).
    static func fitted(_ mask: (values: [Float], width: Int, height: Int), to size: (Int, Int)) -> [Float] {
        if mask.width == size.0 && mask.height == size.1 { return mask.values }
        return DepthMath.resampled(mask.values, width: mask.width, height: mask.height, toWidth: size.0, toHeight: size.1)
    }
}
#endif
