#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// The mask and selection overlays (W2, D17, §6 item 4), drawn from the mask m at the frame's extent. Never baked
/// into the preview: the canvas composites the overlay over the image (`MetalCanvasView.maskOverlay`), so the
/// histogram, thumbnails and Live snapshots read the picture alone.
///
/// - tint: the colour × opacity where m;
/// - rubylith: the colour × opacity where 1 − m (Photoshop's quick mask);
/// - outline: the mask's 0.5 edge in white, over the same edge one pixel down and right in black;
/// - onBlack / onWhite: the picture × m over black or white (opaque);
/// - blackAndWhite: m itself (opaque).
public enum MaskOverlayRenderer {
    /// The overlay for `mask` (opaque, value in RGB) over `frame`, cropped to `extent`.
    public static func overlay(mask: CIImage, frame: CIImage, style: MaskOverlayStyle, color: PSColor, opacity: Double, extent: CGRect) -> CIImage {
        let alpha = opacity.clamped(to: 0...1)
        switch style {
        case .tint:
            return colourWash(color, weight: MaskComponentImages.scaled(mask, by: alpha), extent: extent)
        case .rubylith:
            return colourWash(color, weight: MaskComponentImages.scaled(MaskComponentImages.inverted(mask), by: alpha), extent: extent)
        case .outline:
            return outline(mask, extent: extent)
        case .onBlack:
            return AdjustmentPipeline.blendWithMask(foreground: frame.cropped(to: extent), background: MaskComponentImages.black(extent), mask: mask)
        case .onWhite:
            return AdjustmentPipeline.blendWithMask(foreground: frame.cropped(to: extent), background: MaskComponentImages.white(extent), mask: mask)
        case .blackAndWhite:
            return mask.cropped(to: extent)
        }
    }

    /// `color` with alpha = weight (premultiplied by Core Image), clear elsewhere.
    static func colourWash(_ color: PSColor, weight: CIImage, extent: CGRect) -> CIImage {
        let solid = CIImage(color: PSColor(red: color.red, green: color.green, blue: color.blue).ciColor).cropped(to: extent)
        return AdjustmentPipeline.applyingAlpha(mask: weight, to: solid)
    }

    /// The outline's half-width in pixels at a frame's longest side: about 1.5 screen pixels when the frame is
    /// shown fitted on a phone, never under one pixel.
    public static func outlineRadius(longestSide: CGFloat) -> CGFloat {
        max(1, 1.5 * longestSide / 1600)
    }

    /// White where the hard (0.5) edge of the mask is, over a black copy offset by one pixel; clear elsewhere.
    static func outline(_ mask: CIImage, extent: CGRect) -> CIImage {
        let radius = outlineRadius(longestSide: max(extent.width, extent.height))
        // Hard mask, then the morphological gradient: dilation − erosion, a band about 2r wide across the edge, built
        // as min(dilated, 1 − eroded) (equal for a 0/1 mask), every step opaque with the value in RGB. The square
        // morphologies take an odd width (documented as rounded to the nearest odd integer), so the reach is exactly
        // ⌊r⌉ ≥ 1 pixel each way; the circular ones (and `CIMorphologyGradient`) leave the pixel footprint of a radius
        // near 1 unspecified, and at the radius the outline usually has (1) the gradient filter drew no band at all.
        let hard = MaskComponentImages.line(mask, slope: 64, bias: -31.5).clampedToExtent()
        let size = Float(2 * max(1, Int(radius.rounded())) + 1)
        let dilate = CIFilter.morphologyRectangleMaximum()
        dilate.inputImage = hard
        dilate.width = size
        dilate.height = size
        let erode = CIFilter.morphologyRectangleMinimum()
        erode.inputImage = hard
        erode.width = size
        erode.height = size
        guard let dilated = dilate.outputImage?.cropped(to: extent), let eroded = erode.outputImage?.cropped(to: extent) else {
            return CIImage.empty()
        }
        let band = MaskComponentImages.minimum(dilated, MaskComponentImages.inverted(eroded))
        let white = AdjustmentPipeline.applyingAlpha(mask: band, to: MaskComponentImages.white(extent))
        let shadow = AdjustmentPipeline.applyingAlpha(mask: band, to: MaskComponentImages.black(extent))
            .transformed(by: CGAffineTransform(translationX: 1, y: -1))
        return white.composited(over: shadow).cropped(to: extent)
    }
}
#endif
