#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Subject/background compositing effects shared by photo and video.
public enum BackgroundEffects {
    /// Builds the backdrop image for a replaced background.
    public static func backdrop(for background: Background, original: CIImage, scale: Double, store: ProjectStore, projectID: UUID) -> CIImage {
        let extent = original.extent
        switch background {
        case .transparent:
            return CIImage(color: .clear).cropped(to: extent)
        case .solid(let color):
            return CIImage(color: color.ciColor).cropped(to: extent)
        case .gradient(let top, let bottom):
            let filter = CIFilter.linearGradient()
            filter.point0 = CGPoint(x: extent.midX, y: extent.maxY)
            filter.point1 = CGPoint(x: extent.midX, y: extent.minY)
            filter.color0 = top.ciColor
            filter.color1 = bottom.ciColor
            return filter.outputImage?.cropped(to: extent) ?? CIImage(color: top.ciColor).cropped(to: extent)
        case .blurredOriginal(let amount):
            let radius = 4 + amount * 40 * scale
            return original.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        case .image(let asset):
            let url = store.url(for: asset.relativePath, in: projectID)
            guard let image = try? ImageSupport.loadCIImage(at: url) else { return CIImage(color: .black).cropped(to: extent) }
            // Aspect-fill the backdrop.
            let fill = max(extent.width / image.extent.width, extent.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let dx = extent.midX - scaled.extent.midX
            let dy = extent.midY - scaled.extent.midY
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: extent)
        }
    }

    /// Depth-of-field style blur: the subject stays sharp, the background gets a
    /// graduated blur that increases with distance from the subject's mask edge.
    public static func portraitBlur(_ image: CIImage, subjectMask: CIImage, amount: Double, scale: Double) -> CIImage {
        let extent = image.extent
        let radius = (2 + amount * 30) * scale
        // Distance-like falloff: blur the mask itself so the transition starts sharp at the subject edge.
        let softMask = subjectMask.clampedToExtent().applyingGaussianBlur(sigma: 6 * scale).cropped(to: extent)
        let inverted = softMask.applyingFilter("CIColorInvert")
        let variable = CIFilter.maskedVariableBlur()
        variable.inputImage = image.clampedToExtent()
        variable.mask = inverted
        variable.radius = Float(radius)
        let blurred = variable.outputImage?.cropped(to: extent) ?? image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        // Protect subject edges from halo by compositing the sharp subject on top.
        return AdjustmentPipeline.blendWithMask(foreground: image, background: blurred, mask: subjectMask)
    }

    /// Changes the hue/saturation of the masked region while keeping its luminance
    /// (shading, folds and highlights survive), then blends by `strength`.
    public static func recolor(_ image: CIImage, mask: CIImage, color: PSColor, strength: Double) -> CIImage {
        let extent = image.extent
        let monochrome = CIFilter.colorMonochrome()
        monochrome.inputImage = image
        monochrome.color = color.ciColor
        monochrome.intensity = 1
        guard let tinted = monochrome.outputImage?.cropped(to: extent) else { return image }
        // Restore some contrast lost by the tint and keep true blacks/whites.
        let controls = CIFilter.colorControls()
        controls.inputImage = tinted
        controls.saturation = Float(1 + (1 - color.luminance) * 0.4)
        controls.contrast = 1.05
        let recolored = controls.outputImage?.cropped(to: extent) ?? tinted
        let blended = AdjustmentPipeline.blend(recolored, over: image, alpha: strength.clamped(to: 0...1))
        return AdjustmentPipeline.blendWithMask(foreground: blended, background: image, mask: mask)
    }

    /// Directional light overlay. `direction` -1 = left, 0 = front/top, 1 = right.
    public static func relight(_ image: CIImage, direction: Double, intensity: Double) -> CIImage {
        let extent = image.extent
        let filter = CIFilter.linearGradient()
        let from = CGPoint(x: extent.midX + CGFloat(direction) * extent.width * 0.6, y: extent.maxY)
        let to = CGPoint(x: extent.midX - CGFloat(direction) * extent.width * 0.4, y: extent.minY)
        filter.point0 = from
        filter.point1 = to
        filter.color0 = CIColor(red: 1, green: 0.97, blue: 0.92, alpha: CGFloat(intensity.clamped(to: 0...1) * 0.55))
        filter.color1 = CIColor(red: 0.1, green: 0.1, blue: 0.16, alpha: CGFloat(intensity.clamped(to: 0...1) * 0.35))
        guard let light = filter.outputImage?.cropped(to: extent) else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = light
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
#endif
