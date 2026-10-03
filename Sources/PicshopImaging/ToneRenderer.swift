#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Applies a ToneLUT (Levels and the person's curves, baked) in one CIColorCurves pass.
///
/// The table acts on gamma-encoded Display P3 values, as Levels and Curves do in a photo
/// editor: Core Image converts from its extended-linear working space into that space for
/// the lookup and back. In the linear working space a midtone curve would land in the
/// shadows and Levels' gamma would mean something else.
public enum ToneRenderer {
    /// Display P3 with its sRGB-like transfer curve: perceptual values.
    public static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    public static func apply(_ lut: ToneLUT, to image: CIImage) -> CIImage {
        let entries = min(lut.red.count, lut.green.count, lut.blue.count)
        guard entries >= 2, !lut.isIdentity else { return image }
        let values = lut.interleaved
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = colorSpace
        guard let output = filter.outputImage else { return image }
        return image.extent.isInfinite ? output : output.cropped(to: image.extent)
    }
}
#endif
