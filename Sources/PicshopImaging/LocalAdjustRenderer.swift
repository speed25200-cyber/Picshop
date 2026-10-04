#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

/// Draws one local adjustment through its mask (W2, D2): the same engines as the layer's own develop recipe, then a
/// blend with mask × amount, so a local « Exposition +0,3 » looks exactly like the global one where the mask is 1.
public enum LocalAdjustRenderer {
    /// `image` with `adjustment` applied where `mask` (opaque, value in RGB, same extent) is white, scaled by the
    /// adjustment's amount. `scale` is the render's ratio to the full-resolution original (radius-based dials);
    /// `interactive` bakes the mixer and grade cube small, as the global colour panel does while a dial moves.
    public static func apply(_ adjustment: LocalAdjustment, mask: CIImage, to image: CIImage, scale: Double, interactive: Bool) -> CIImage {
        let amount = adjustment.amount.clamped(to: 0...1)
        guard amount > 0.0005, adjustment.isVisible, !adjustment.isNeutral else { return image }
        let adjusted = adjusted(image, by: adjustment, scale: scale, interactive: interactive)
        guard adjusted !== image else { return image }
        let weight = amount < 0.9995 ? MaskComponentImages.scaled(mask, by: amount) : mask
        return AdjustmentPipeline.blendWithMask(foreground: adjusted.cropped(to: image.extent), background: image, mask: weight)
    }

    /// The adjustment applied everywhere (before the mask): dials without the vignette, the curve through a tone
    /// table, the HSL subset and the local colour through one colour cube.
    public static func adjusted(_ image: CIImage, by adjustment: LocalAdjustment, scale: Double, interactive: Bool) -> CIImage {
        var result = image
        var dials = adjustment.adjustments
        dials[.vignette] = 0
        if !dials.isNeutral {
            result = AdjustmentPipeline.apply(dials, toneCurve: .identity, to: result, scale: scale)
        }
        if let curve = adjustment.curve, !curve.isIdentity {
            let table = ToneLUT.make(levels: .identity, curve: curve)
            result = ToneRenderer.apply(table, to: result)
        }
        let mixer = adjustment.mixer.flatMap { $0.isNeutral ? nil : $0 }
        let grade = adjustment.grade.flatMap { $0.isNeutral ? nil : $0 }
        if mixer != nil || grade != nil {
            result = ColorCube.shared.apply(mixer: mixer, grade: grade, to: result, interactive: interactive)
        }
        return result
    }
}
#endif
