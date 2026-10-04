#if canImport(Vision) && canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore
import PicshopIntent

// W2 selections (D7, §6 item 8): the document's one selection is an 8-bit raster at the working size (the analysis
// image's, 1536 px on the source's longest side), changed through Core's `SelectionAlgebra` on the CPU and saved as
// a new file every time. Its `MaskReference` carries a hairline feather (0.003) like the W1 wand and lasso: the
// raster already holds its soft edge. Moved selections (non-unit corners) are baked back onto the canvas grid first.
extension VisionPhotoServices {
    // MARK: - Stacks as rasters

    /// Any stack → an 8-bit raster at the working size (selections from gradients and ranges, a flattened brush).
    public func rasterize(_ stack: MaskStack, in document: PhotoDocument) async throws -> AIMaskResult {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let drawn = try await maskRenderer.stackBytes(stack, document: document, longestSide: Self.analysisLongestSide)
        let raster = try maskStore.saveRaster(bytes: drawn.bytes, width: drawn.width, height: drawn.height, origin: Self.isBrushOnly(stack) ? .brush : .selection,
                                              stateKey: document.baseStateKey)
        return AIMaskResult(raster: raster, coverage: MaskStore.coverage(of: drawn.bytes), usedModel: false)
    }

    // MARK: - Selection algebra

    /// `new` combined into `current` with `mode` (nil: a new selection). Steps and the refinement carry over when
    /// combining; a new selection starts with none. The caller appends the step that made it.
    public func combineSelection(_ current: PhotoSelection?, with new: RasterRef, mode: CombineMode?, in document: PhotoDocument) async throws -> PhotoSelection {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        guard let layerID = document.baseLayerID else { throw PicshopError.renderFailed("no photo") }
        let size = try await workingSize(document)
        guard let bytes = await maskRenderer.rasterBytes(new, width: size.width, height: size.height) else { throw PicshopError.renderFailed("selection raster") }
        let incoming = GrayRaster(width: size.width, height: size.height, bytes: bytes)
        var base: GrayRaster?
        if let current, mode != nil, current.layerID == layerID,
           let existing = await maskRenderer.rasterBytes(current.raster, width: size.width, height: size.height) {
            base = GrayRaster(width: size.width, height: size.height, bytes: existing)
        }
        let combined = SelectionAlgebra.combine(base, incoming, mode: mode)
        let source: MaskSource
        if mode == nil || base == nil {
            switch new.origin {
            case .subject: source = .subject
            case .object: source = .object(label: new.label ?? "object", boundingBox: new.boundingBox)
            default: source = .region("selection")
            }
        } else {
            source = .region("selection")
        }
        let carried = mode == nil ? nil : current
        return try savedSelection(combined, source: source, layerID: layerID, steps: carried?.steps ?? [], refinement: carried?.refinement)
    }

    /// Select › Modify: invert, grow, shrink, feather, smooth. Pixels are at full resolution, scaled to the working
    /// size (× working side / full side); smooth 0…1 is a radius of up to 1.2 % of the longest side.
    public func modifySelection(_ selection: PhotoSelection, _ change: SelectionChange, in document: PhotoDocument) async throws -> PhotoSelection {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let raster = try await aligned(selection, document: document)
        let factor = workingScale(document)
        let changed: GrayRaster
        switch change {
        case .invert:
            changed = SelectionAlgebra.inverted(raster)
        case .grow(let pixels):
            changed = SelectionAlgebra.grown(raster, radius: max(1, Int((pixels * factor).rounded())))
        case .shrink(let pixels):
            changed = SelectionAlgebra.shrunk(raster, radius: max(1, Int((pixels * factor).rounded())))
        case .feather(let pixels):
            changed = SelectionAlgebra.feathered(raster, sigma: max(0.5, pixels * factor))
        case .smooth(let amount):
            let radius = Int((amount.clamped(to: 0...1) * 0.012 * Double(max(raster.width, raster.height))).rounded())
            changed = SelectionAlgebra.smoothed(raster, radius: max(1, radius))
        }
        return try savedSelection(changed, source: .region("selection"), layerID: selection.layerID, steps: selection.steps,
                                  refinement: selection.refinement, decontaminate: selection.mask.decontaminate)
    }

    /// Select & Mask, rendered at the working size on the GPU (`EdgeRefine`, guided by the pre-local picture) and
    /// saved; the refinement is kept, and its decontamination goes on the mask for cutout and background changes.
    public func refineSelection(_ selection: PhotoSelection, _ refinement: SelectionRefinement, in document: PhotoDocument) async throws -> PhotoSelection {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let raster = try await aligned(selection, document: document)
        let guide = try await maskRenderer.preLocalBase(document, longestSide: Self.analysisLongestSide)
        let rect = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        guard let cg = ImageSupport.grayImage(width: raster.width, height: raster.height, bytes: raster.bytes, colorSpace: RenderContext.maskColorSpace) else {
            throw PicshopError.renderFailed("selection raster")
        }
        let refined = EdgeRefine.refine(ImageSupport.rawMaskImage(cg), guide: guide.cropped(to: rect), refinement: refinement)
        guard let bytes = ImageSupport.rawGrayBytes(of: refined, rect: rect) else { throw PicshopError.renderFailed("refine readback") }
        let decontaminate = refinement.decontaminate > 0.001 ? refinement.decontaminate.clamped(to: 0...1) : nil
        return try savedSelection(GrayRaster(width: raster.width, height: raster.height, bytes: bytes), source: .region("selection"),
                                  layerID: selection.layerID, steps: selection.steps, refinement: refinement, decontaminate: decontaminate)
    }

    // MARK: - Sampling

    /// The Lab colour of a (2 × radius + 1)² window at each point (normalised, top-left) of the pre-local base at
    /// 1536: what a colour range will test (D2).
    public func sampleColors(at points: [PSPoint], radius: Int, in document: PhotoDocument) async throws -> [LabColor] {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let image = try await analysisImage(for: document)
        let rgba = Self.sRGBBytes(image)
        return ColorRangeSampler.labColors(rgba: rgba, width: image.width, height: image.height, at: points, radius: radius)
    }

    /// The Lab magic wand at `point` (normalised, top-left) of the pre-local base at the working size: what the panel's
    /// wand makes at the same tap (ΔE76 tolerance 0…1, contiguous or global, a 1/3/5 px sample, a soft edge, despeckled).
    public func wandMask(at point: PSPoint, tolerance: Double, contiguous: Bool, sampleSize: Int, in document: PhotoDocument) async throws -> AIMaskResult {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let image = try await analysisImage(for: document)
        let width = image.width, height = image.height
        let bytes = Selection.magicWandLab(rgba: Self.sRGBBytes(image), width: width, height: height, seed: (point.x, point.y),
                                           tolerance: tolerance.clamped(to: 0...1), contiguous: contiguous, sampleSize: sampleSize, antiAlias: true)
        // An empty picture gives no bytes at all.
        guard bytes.count == width * height else { throw PicshopError.renderFailed("wand") }
        let cleaned = Selection.despeckled(bytes, width: width, height: height, minimumPixels: max(4, width * height / 20000))
        guard MaskStore.coverage(of: cleaned) > 0 else { throw PicshopError.objectNotFound("selection") }
        return try saved(cleaned, image: image, origin: .selection, label: nil, document: document)
    }

    // MARK: - Helpers

    /// A stack made of one brush: its raster is a flattened brush (origin .brush, §7.4).
    static func isBrushOnly(_ stack: MaskStack) -> Bool {
        guard stack.components.count == 1, case .brush = stack.components[0].kind else { return false }
        return true
    }

    /// The working size: the analysis image's.
    func workingSize(_ document: PhotoDocument) async throws -> (width: Int, height: Int) {
        let image = try await analysisImage(for: document)
        return (image.width, image.height)
    }

    /// Working pixels per full-resolution pixel (1 when the source is under 1536 px).
    func workingScale(_ document: PhotoDocument) -> Double {
        guard let size = document.baseLayer?.imageAsset?.pixelSize else { return 1 }
        return min(1, Double(Self.analysisLongestSide) / max(1, max(size.width, size.height)))
    }

    /// The selection's raster on the canvas grid at the working size (a moved selection is baked here, D7).
    func aligned(_ selection: PhotoSelection, document: PhotoDocument) async throws -> GrayRaster {
        let size = try await workingSize(document)
        guard let bytes = await maskRenderer.rasterBytes(selection.raster, width: size.width, height: size.height) else {
            throw PicshopError.renderFailed("selection raster")
        }
        return GrayRaster(width: size.width, height: size.height, bytes: bytes)
    }

    /// Saves a selection raster as a new file and wraps it: unit corners, the coverage, the last 12 steps.
    func savedSelection(_ raster: GrayRaster, source: MaskSource, layerID: UUID, steps: [SelectionStep], refinement: SelectionRefinement?,
                        decontaminate: Double? = nil) throws -> PhotoSelection {
        var reference = try maskStore.save(bytes: raster.bytes, width: raster.width, height: raster.height, source: source, feather: 0.003)
        reference.decontaminate = decontaminate
        return PhotoSelection(mask: reference, layerID: layerID, steps: Array(steps.suffix(PhotoSelection.maxSteps)), refinement: refinement,
                              coverage: MaskStore.coverage(of: raster.bytes), pixelWidth: raster.width, pixelHeight: raster.height)
    }
}
#endif
