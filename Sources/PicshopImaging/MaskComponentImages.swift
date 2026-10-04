#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// One Core Image chain per mask component kind (W2, §6 item 1), and the built-ins the rasterizer composes them
/// with (D1). Every image here is opaque, cropped to the layer's `extent`, with the mask value in R, G and B.
///
/// D5's raw-value rule binds every chain: rasters are read with no colour space, gradients interpolate 0 and 1
/// (which every space keeps), tables apply through `CIColorCurves` in linear sRGB (neutral against linear P3) or
/// `CIColorCube` with no colour space, and invert, opacity and density are colour matrices. `CIToneCurve` is not
/// used: it applies its curve in a gamma-2 version of the working space, which would bend mask values.
enum MaskComponentImages {
    // MARK: - Space

    /// A normalised point (top-left origin, y down) in Core Image space (bottom-left origin) for `extent`.
    static func ciPoint(_ point: PSPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(point.x) * extent.width, y: extent.minY + CGFloat(1 - point.y) * extent.height)
    }

    static func black(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    static func white(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
    }

    /// Cropped to `extent` over opaque black (D5 item 4): clear outside a warped raster reads 0, never "no value".
    static func opaque(_ image: CIImage, extent: CGRect) -> CIImage {
        image.cropped(to: extent).composited(over: black(extent))
    }

    static func isUnit(_ corners: [PSPoint]) -> Bool {
        guard corners.count == 4 else { return true }
        return zip(corners, RasterRef.unitCorners).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 }
    }

    // MARK: - Rasters

    /// A raw raster (its own pixel size, origin zero) placed by its four corners in `extent`: an affine scale for
    /// the unit corners (edges clamped, so the border keeps its value), a perspective warp otherwise (0 outside).
    static func placed(_ raw: CIImage, corners: [PSPoint], extent: CGRect) -> CIImage {
        let source = raw.extent
        guard source.width >= 1, source.height >= 1, !source.isInfinite else { return black(extent) }
        if isUnit(corners) {
            let transform = CGAffineTransform(translationX: -source.minX, y: -source.minY)
                .concatenating(CGAffineTransform(scaleX: extent.width / source.width, y: extent.height / source.height))
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
            return raw.clampedToExtent().transformed(by: transform).cropped(to: extent)
        }
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = raw
        warp.topLeft = ciPoint(corners[0], in: extent)
        warp.topRight = ciPoint(corners[1], in: extent)
        warp.bottomRight = ciPoint(corners[2], in: extent)
        warp.bottomLeft = ciPoint(corners[3], in: extent)
        guard let output = warp.outputImage else { return black(extent) }
        return opaque(output, extent: extent)
    }

    // MARK: - Gradients

    /// Linear: full effect at and beyond `start`, none at and beyond `end`, smoothstep between (pixel space).
    /// `CILinearGradient` gives 1 − t clamped, and v = 1 − smoothstep(t) = smoothstep(1 − t).
    static func linear(_ spec: LinearGradientSpec, extent: CGRect) -> CIImage {
        let start = ciPoint(spec.start, in: extent), end = ciPoint(spec.end, in: extent)
        guard hypot(end.x - start.x, end.y - start.y) > 1e-3 else { return black(extent) }
        let gradient = CIFilter.linearGradient()
        gradient.point0 = start
        gradient.point1 = end
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        guard let ramp = gradient.outputImage else { return black(extent) }
        return curves(ramp.cropped(to: extent), table: smoothstepTable)
    }

    /// Radial: full inside (1 − feather) of the ellipse, smoothstep to its edge. A circle of radius rx (longest-side
    /// pixels) ramps from (1 − f) × rx to rx, is squashed to ry, turned clockwise by `rotation` and moved to the
    /// centre. Feather 0 keeps a one-pixel anti-aliased edge.
    static func radial(_ spec: RadialGradientSpec, extent: CGRect) -> CIImage {
        let longest = max(extent.width, extent.height)
        let rx = CGFloat(max(0, spec.radiusX)) * longest, ry = CGFloat(max(0, spec.radiusY)) * longest
        guard rx >= 0.5, ry >= 0.5 else { return black(extent) }
        let feather = CGFloat(spec.feather.clamped(to: 0...1))
        var inner = (1 - feather) * rx, outer = rx
        if outer - inner < 1 {
            inner = max(0, rx - 0.5)
            outer = rx + 0.5
        }
        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(outer)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        guard let ramp = gradient.outputImage else { return black(extent) }
        let centre = ciPoint(spec.center, in: extent)
        // Clockwise on screen (y down) is counter-clockwise negative in Core Image's y-up space.
        let radians = -CGFloat(spec.rotation) * .pi / 180
        let transform = CGAffineTransform(scaleX: 1, y: ry / rx)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        return curves(ramp.transformed(by: transform).cropped(to: extent), table: smoothstepTable)
    }

    // MARK: - Ranges

    /// Colour and luminance ranges: the pre-local image as gamma sRGB numbers through a mask cube with no colour
    /// space, so the cube's output is the raw mask value (D5 item 2).
    static func cube(_ data: Data, dimension: Int, on preLocal: CIImage, extent: CGRect) -> CIImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return black(extent) }
        let encoded = preLocal.matchedFromWorkingSpace(to: sRGB) ?? preLocal
        let filter = CIFilter.colorCube()
        filter.inputImage = encoded
        filter.cubeDimension = Float(dimension)
        filter.cubeData = data
        guard let output = filter.outputImage else { return black(extent) }
        return opaque(output.settingAlphaOne(in: extent), extent: extent)
    }

    /// Depth range: the raw depth raster, placed, through the trapezoid table (D5 item 3).
    static func depthRange(_ placedDepth: CIImage, spec: DepthRangeSpec, extent: CGRect) -> CIImage {
        let table = MaskMath.trapezoidTable(low: spec.low, high: spec.high, feather: spec.feather)
        guard table.count >= 6 else { return black(extent) }
        return opaque(curves(placedDepth, table: Data(floats: table)), extent: extent)
    }

    // MARK: - Tables

    /// `CIColorCurves` in linear sRGB: a neutral value goes through the table as the number it is.
    static func curves(_ image: CIImage, table: Data) -> CIImage {
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = table
        filter.curvesDomain = CIVector(x: 0, y: 1)
        if let linear = CGColorSpace(name: CGColorSpace.linearSRGB) { filter.colorSpace = linear }
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    /// smoothstep(0, 1, x) as 256 RGB triplets.
    static let smoothstepTable: Data = {
        let count = 256
        var values: [Float] = []
        values.reserveCapacity(count * 3)
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            let y = Float(x * x * (3 - 2 * x))
            values += [y, y, y]
        }
        return Data(floats: values)
    }()

    // MARK: - Arithmetic (colour matrices: linear on working-space numbers)

    /// 1 − v.
    static func inverted(_ image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        return matrix.outputImage?.cropped(to: image.extent) ?? image
    }

    /// k × v (opacity, density, amount).
    static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        let k = CGFloat(factor)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage?.cropped(to: image.extent) ?? image
    }

    /// slope × v + bias, clamped to 0…1 (thresholds, contrast).
    static func line(_ image: CIImage, slope: Double, bias: Double) -> CIImage {
        let k = CGFloat(slope), c = CGFloat(bias)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: c, y: c, z: c, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = matrix.outputImage ?? image
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage?.cropped(to: image.extent) ?? image
    }

    /// max(a, b) per channel.
    static func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage?.cropped(to: b.extent) ?? b
    }

    /// min(a, b) per channel.
    static func minimum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.minimumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage?.cropped(to: b.extent) ?? b
    }
}

extension Data {
    /// The bytes of a Float array, as Core Image's cube and curve data take them.
    init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
#endif
