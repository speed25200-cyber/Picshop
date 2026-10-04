#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Gradient fill layers (W3, D9) on the GPU, with Core's `GradientFill.parameter(at:aspect:)` and `color(at:)` as
/// the shared maths (CPU reference = GPU).
///
/// One path for every style and stop count: a grey ramp holding t (linear in position), mapped through a 256 × 1 strip
/// that `color(at:)` fills on the CPU, with `CIColorMap`. So the stops, their alpha, `reverse` and the gamma-encoded
/// interpolation are Core's exactly, whatever the stop count.
/// - The ramp's geometry is read from `parameter(at:aspect:)` itself (its slope around an unclamped point), so the
///   GPU follows Core's definition of the axis, the span and the aspect rather than a second copy of it.
/// - Linear: `CILinearGradient` black → white between the points where t = 0 and 1 (not the smooth variant, whose
///   S-curve would bend t). Radial: `CIRadialGradient` out to where t = 1, scaled per axis when Core's metric is not
///   round in pixels. Reflected: the linear ramp through a colour matrix (2t − 1) and `CIColorAbsoluteDifference`.
/// - Dither: ±½ step of noise from `CIRandomGenerator`, which is seeded by absolute coordinates, so strips and tiles
///   agree (D6).
public enum GradientRenderer {
    /// Entries of the colour strip.
    static let stripWidth = 256

    /// The gradient over `canvas` (Core Image coordinates; the canvas's top-left is canvas-normalised (0, 0)), linear
    /// working-space values, premultiplied, cropped to the canvas.
    public static func image(_ gradient: GradientFill, canvas: CGRect) -> CIImage {
        guard canvas.width >= 1, canvas.height >= 1, !canvas.isInfinite else { return CIImage.empty() }
        let aspect = Double(canvas.width / canvas.height)
        guard let ramp = ramp(gradient, canvas: canvas, aspect: aspect) else {
            // A degenerate gradient (every point clamped): the colour Core gives the centre.
            let t = gradient.parameter(at: gradient.center, aspect: aspect)
            return CIImage(color: gradient.color(at: t).ciColor).cropped(to: canvas)
        }
        let map = CIFilter.colorMap()
        map.inputImage = ramp.cropped(to: canvas)
        map.gradientImage = strip(gradient)
        var result = (map.outputImage ?? ramp).cropped(to: canvas)
        if gradient.dither { result = dithered(result, canvas: canvas) }
        return result
    }

    /// The 256 × 1 strip: `color(at: k / 255)` in gamma-encoded Display P3, premultiplied, so Core Image brings it to
    /// its working space exactly as it brings a P3 photo.
    static func strip(_ gradient: GradientFill) -> CIImage {
        var floats = [Float](repeating: 0, count: stripWidth * 4)
        for index in 0..<stripWidth {
            let color = gradient.color(at: Double(index) / Double(stripWidth - 1))
            let alpha = Float(color.alpha.clamped(to: 0...1))
            floats[index * 4] = Float(color.red) * alpha
            floats[index * 4 + 1] = Float(color.green) * alpha
            floats[index * 4 + 2] = Float(color.blue) * alpha
            floats[index * 4 + 3] = alpha
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: stripWidth * 16, size: CGSize(width: stripWidth, height: 1), format: .RGBAf,
                       colorSpace: RenderContext.colorSpace)
    }

    /// The grey ramp (value t, linear in position) over the canvas; nil when the gradient has no slope anywhere.
    static func ramp(_ gradient: GradientFill, canvas: CGRect, aspect: Double) -> CIImage? {
        switch gradient.style {
        case .linear:
            return linearRamp(gradient, canvas: canvas, aspect: aspect)
        case .radial:
            return radialRamp(gradient, canvas: canvas, aspect: aspect)
        case .reflected:
            var linear = gradient
            linear.style = .linear
            guard let ramp = linearRamp(linear, canvas: canvas, aspect: aspect) else { return nil }
            let stretch = CIFilter.colorMatrix()
            stretch.inputImage = ramp
            stretch.rVector = CIVector(x: 2, y: 0, z: 0, w: 0)
            stretch.gVector = CIVector(x: 0, y: 2, z: 0, w: 0)
            stretch.bVector = CIVector(x: 0, y: 0, z: 2, w: 0)
            stretch.biasVector = CIVector(x: -1, y: -1, z: -1, w: 0)
            let mirror = CIFilter.colorAbsoluteDifference()
            mirror.inputImage = stretch.outputImage ?? ramp
            mirror.inputImage2 = CIImage(color: .black).cropped(to: canvas)
            return (mirror.outputImage ?? ramp).cropped(to: canvas).settingAlphaOne(in: canvas)
        }
    }

    // MARK: - Geometry from Core's parameter

    /// A canvas-normalised point → Core Image pixel coordinates on `canvas`.
    static func pixel(_ point: PSPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX + CGFloat(point.x) * canvas.width, y: canvas.minY + (1 - CGFloat(point.y)) * canvas.height)
    }

    /// A point near the centre where t is strictly inside 0…1 (the slope is readable there), nil when none is.
    static func unclampedPoint(_ gradient: GradientFill, aspect: Double) -> PSPoint? {
        let center = gradient.center
        let t = gradient.parameter(at: center, aspect: aspect)
        if t > 0.01, t < 0.99 { return center }
        var best: (point: PSPoint, distance: Double)?
        for row in 0...16 {
            for column in 0...16 {
                let point = PSPoint(x: Double(column) / 16, y: Double(row) / 16)
                let value = gradient.parameter(at: point, aspect: aspect)
                guard value > 0.01, value < 0.99 else { continue }
                let distance = hypot(point.x - center.x, point.y - center.y)
                if best.map({ distance < $0.distance }) ?? true { best = (point, distance) }
            }
        }
        return best?.point
    }

    static func linearRamp(_ gradient: GradientFill, canvas: CGRect, aspect: Double) -> CIImage? {
        guard let origin = unclampedPoint(gradient, aspect: aspect) else { return nil }
        let epsilon = 1e-4
        func t(_ dx: Double, _ dy: Double) -> Double { gradient.parameter(at: PSPoint(x: origin.x + dx, y: origin.y + dy), aspect: aspect) }
        let t0 = t(0, 0)
        // Slope per canvas-normalised unit (central differences), then per Core Image pixel (y up).
        let slopeX = (t(epsilon, 0) - t(-epsilon, 0)) / (2 * epsilon)
        let slopeY = (t(0, epsilon) - t(0, -epsilon)) / (2 * epsilon)
        let gx = slopeX / Double(canvas.width), gy = -slopeY / Double(canvas.height)
        let squared = gx * gx + gy * gy
        guard squared > 1e-18, squared.isFinite else { return nil }
        let at = pixel(origin, canvas: canvas)
        // Where t = 0 and t = 1 along the slope.
        let start = CGPoint(x: at.x + CGFloat((0 - t0) * gx / squared), y: at.y + CGFloat((0 - t0) * gy / squared))
        let end = CGPoint(x: at.x + CGFloat((1 - t0) * gx / squared), y: at.y + CGFloat((1 - t0) * gy / squared))
        let filter = CIFilter.linearGradient()
        filter.point0 = start
        filter.point1 = end
        filter.color0 = CIColor(red: 0, green: 0, blue: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1)
        return filter.outputImage?.cropped(to: canvas)
    }

    static func radialRamp(_ gradient: GradientFill, canvas: CGRect, aspect: Double) -> CIImage? {
        let center = gradient.center
        let epsilon = 1e-3
        // t grows from 0 at the centre: its rate along each axis gives the radius where it reaches 1, in pixels.
        let tx = (gradient.parameter(at: PSPoint(x: center.x + epsilon, y: center.y), aspect: aspect)
                  + gradient.parameter(at: PSPoint(x: center.x - epsilon, y: center.y), aspect: aspect)) / 2
        let ty = (gradient.parameter(at: PSPoint(x: center.x, y: center.y + epsilon), aspect: aspect)
                  + gradient.parameter(at: PSPoint(x: center.x, y: center.y - epsilon), aspect: aspect)) / 2
        guard tx > 1e-9, ty > 1e-9, tx < 1, ty < 1 else { return nil }
        let radiusX = epsilon * Double(canvas.width) / tx
        let radiusY = epsilon * Double(canvas.height) / ty
        guard radiusX.isFinite, radiusY.isFinite, radiusX > 0.01, radiusY > 0.01 else { return nil }
        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = 0
        filter.radius1 = Float(radiusX)
        filter.color0 = CIColor(red: 0, green: 0, blue: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard var circle = filter.outputImage else { return nil }
        if abs(radiusY - radiusX) > 0.25 {
            circle = circle.transformed(by: CGAffineTransform(scaleX: 1, y: CGFloat(radiusY / radiusX)))
        }
        let at = pixel(center, canvas: canvas)
        return circle.transformed(by: CGAffineTransform(translationX: at.x, y: at.y)).cropped(to: canvas)
    }

    // MARK: - Dither

    /// ±½ of an 8-bit step of noise on the colour (alpha untouched), from Core Image's coordinate-seeded generator.
    static func dithered(_ image: CIImage, canvas: CGRect) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let step = CGFloat(1.0 / 255.0)
        let scaled = CIFilter.colorMatrix()
        scaled.inputImage = noise
        scaled.rVector = CIVector(x: step, y: 0, z: 0, w: 0)
        scaled.gVector = CIVector(x: 0, y: step, z: 0, w: 0)
        scaled.bVector = CIVector(x: 0, y: 0, z: step, w: 0)
        scaled.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        scaled.biasVector = CIVector(x: -step / 2, y: -step / 2, z: -step / 2, w: 0)
        guard let grain = scaled.outputImage?.cropped(to: canvas) else { return image }
        let add = CIFilter.additionCompositing()
        add.inputImage = grain
        add.backgroundImage = image
        return (add.outputImage ?? image).cropped(to: canvas)
    }
}
#endif
