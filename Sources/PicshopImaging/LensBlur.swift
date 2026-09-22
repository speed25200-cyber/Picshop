#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Refocusing after the shot: a variable blur whose strength grows with
/// the distance from the focal plane — measured on the camera's disparity map
/// for Portrait photos, or read from the subject mask otherwise (the side of
/// the mask that was tapped stays sharp).
public enum LensBlur {
    /// Largest blur radius, as a fraction of the picture's longest side, at full aperture.
    static let maximumRadius: CGFloat = 0.028

    public static func apply(to image: CIImage, disparity: CIImage, focus: PSPoint, aperture: Double) -> CIImage {
        let extent = image.extent
        let focalPoint = CGPoint(x: extent.minX + CGFloat(focus.x) * extent.width, y: extent.minY + CGFloat(1 - focus.y) * extent.height)
        let focal = Double(average(of: disparity, around: focalPoint, radius: max(4, extent.width * 0.02)) ?? 0.5)
        // Distance from the focal plane, relative to it: |d − f| / (0.6 f), in both directions.
        let gain = 1 / max(0.04, focal * 0.6)
        let nearer = ramp(disparity, slope: gain, offset: -focal * gain)
        let farther = ramp(disparity, slope: -gain, offset: focal * gain)
        let mask = nearer.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: farther]).cropped(to: extent)
        return blur(image, mask: mask, aperture: aperture)
    }

    public static func apply(to image: CIImage, subjectMask: CIImage, focus: PSPoint, aperture: Double) -> CIImage {
        let extent = image.extent
        let point = CGPoint(x: extent.minX + CGFloat(focus.x) * extent.width, y: extent.minY + CGFloat(1 - focus.y) * extent.height)
        let tappedSubject = (average(of: subjectMask, around: point, radius: max(3, extent.width * 0.01)) ?? 1) > 0.5
        // Soften the mask edge so the transition reads like depth, not a cut-out.
        let soft = subjectMask.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.width) * 0.006).cropped(to: extent)
        let mask = tappedSubject ? soft.applyingFilter("CIColorInvert") : soft
        return blur(image, mask: mask, aperture: aperture)
    }

    static func blur(_ image: CIImage, mask: CIImage, aperture: Double) -> CIImage {
        let extent = image.extent
        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = image.clampedToExtent()
        filter.mask = mask
        filter.radius = Float(max(extent.width, extent.height) * maximumRadius * CGFloat(aperture.clamped(to: 0...1)))
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    /// `slope · value + offset`, clamped to 0…1, on all three channels.
    static func ramp(_ image: CIImage, slope: Double, offset: Double) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        let s = CGFloat(slope)
        matrix.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: s, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: s, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let o = CGFloat(offset)
        matrix.biasVector = CIVector(x: o, y: o, z: o, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = matrix.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? image
    }

    /// Mean of the red channel in a square around a point.
    static func average(of image: CIImage, around point: CGPoint, radius: CGFloat) -> Float? {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2).intersection(image.extent)
        guard !rect.isEmpty else { return nil }
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = rect
        guard let output = average.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        RenderContext.shared.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return pixel[0]
    }
}
#endif
