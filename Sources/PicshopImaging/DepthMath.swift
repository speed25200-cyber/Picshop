import Foundation
import PicshopCore

/// The arithmetic around Depth Anything V2 Small and the camera's disparity (W2, D10). Pure Swift, Linux-tested.
///
/// Depth maps are normalised between their 1st and 99th percentile to 0 (far) … 1 (near), stored as 16-bit gray
/// PNGs (big-endian samples, row 0 at the top) at their own size: the model's 518 × 392, rotated back for a
/// portrait picture, or the disparity map's size. The model's input is landscape, so a portrait picture is turned
/// 90° clockwise before inference and its depth turned back after.
public enum DepthMath {
    /// The model's input and output: 518 wide, 392 high (from the pinned spec).
    public static let modelWidth = 518
    public static let modelHeight = 392
    /// The percentiles mapped to 0 and 1.
    public static let lowPercentile = 0.01
    public static let highPercentile = 0.99

    /// Whether a picture of this size is turned before inference (portrait).
    public static func needsRotation(width: Int, height: Int) -> Bool { height > width }

    // MARK: - Normalisation

    /// The value below which `fraction` of the finite values lie (nearest rank on a sorted copy; NaNs ignored).
    public static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return 0 }
        let sorted = finite.sorted()
        let rank = Int((fraction.clamped(to: 0...1) * Double(sorted.count - 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    /// Values mapped linearly so the low percentile is 0 and the high one 1, clamped. `nearIsLarger` says which
    /// way the source runs (model depth and disparity both grow towards the camera); otherwise the result is
    /// flipped so 1 is always near. A flat map gives 0.5 everywhere; NaNs become 0 (far).
    public static func normalized(_ values: [Float], nearIsLarger: Bool = true,
                                  low: Double = lowPercentile, high: Double = highPercentile) -> [Float] {
        guard !values.isEmpty else { return [] }
        let p0 = percentile(values, low), p1 = percentile(values, high)
        let span = p1 - p0
        guard span > 1e-9, span.isFinite else { return [Float](repeating: 0.5, count: values.count) }
        return values.map { value in
            guard value.isFinite else { return 0 }
            let t = min(1, max(0, (value - p0) / span))
            return nearIsLarger ? t : 1 - t
        }
    }

    // MARK: - Rotation

    /// A row-major plane turned 90° clockwise: the result is `height` wide and `width` high; the source's
    /// top-left pixel lands top-right.
    public static func rotatedClockwise<T>(_ values: [T], width: Int, height: Int) -> [T] {
        guard width > 0, height > 0, values.count >= width * height else { return values }
        var out = values
        // Source (x, y) → destination (height − 1 − y, x) in a plane `height` wide.
        for y in 0..<height {
            for x in 0..<width {
                out[x * height + (height - 1 - y)] = values[y * width + x]
            }
        }
        return out
    }

    /// The inverse of `rotatedClockwise`: a plane `width` × `height` turned 90° counter-clockwise, giving
    /// `height` wide and `width` high.
    public static func rotatedCounterClockwise<T>(_ values: [T], width: Int, height: Int) -> [T] {
        guard width > 0, height > 0, values.count >= width * height else { return values }
        var out = values
        // Source (x, y) → destination (y, width − 1 − x) in a plane `height` wide.
        for y in 0..<height {
            for x in 0..<width {
                out[(width - 1 - x) * height + y] = values[y * width + x]
            }
        }
        return out
    }

    // MARK: - 16-bit samples

    /// 0…1 values as big-endian 16-bit samples (PNG's byte order), clamped; NaN is 0.
    public static func pack16(_ values: [Float]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: values.count * 2)
        for (index, value) in values.enumerated() {
            let clamped = value.isFinite ? min(1, max(0, value)) : 0
            let sample = UInt16((clamped * 65535).rounded())
            bytes[index * 2] = UInt8(sample >> 8)
            bytes[index * 2 + 1] = UInt8(sample & 0xFF)
        }
        return bytes
    }

    /// Big-endian 16-bit samples back to 0…1.
    public static func unpack16(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / 2
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let sample = UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1])
            values[index] = Float(sample) / 65535
        }
        return values
    }

    /// An IEEE 754 half-precision value (the model's GRAY_FLOAT16 output) from its bits, without the `Float16`
    /// type (unavailable on x86_64 macOS).
    public static func float(fromHalf bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x03FF)
        let result: UInt32
        switch exponent {
        case 0:
            guard mantissa != 0 else { result = sign; break }
            // Subnormal: normalise the mantissa.
            var m = mantissa
            var e = -14
            while m & 0x0400 == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            result = sign | UInt32(e + 127) << 23 | m << 13
        case 0x1F:
            // Infinity or NaN.
            result = sign | 0x7F80_0000 | mantissa << 13
        default:
            result = sign | UInt32(exponent - 15 + 127) << 23 | mantissa << 13
        }
        return Float(bitPattern: result)
    }

    /// A plane of half-precision samples (host byte order), row stride in samples.
    public static func floats(fromHalfPlane samples: [UInt16], width: Int, height: Int, rowStride: Int) -> [Float] {
        guard width > 0, height > 0, rowStride >= width, samples.count >= (height - 1) * rowStride + width else { return [] }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = float(fromHalf: samples[y * rowStride + x]) }
        }
        return values
    }

    // MARK: - Resampling

    /// Bilinear resampling of a row-major plane (pixel centres aligned), for depth gates at another size.
    public static func resampled(_ values: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        guard width > 0, height > 0, toWidth > 0, toHeight > 0, values.count >= width * height else { return [] }
        if width == toWidth && height == toHeight { return Array(values.prefix(width * height)) }
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        let sx = Double(width) / Double(toWidth), sy = Double(height) / Double(toHeight)
        for y in 0..<toHeight {
            let fy = min(Double(height - 1), max(0, (Double(y) + 0.5) * sy - 0.5))
            let y0 = Int(fy), y1 = min(height - 1, y0 + 1)
            let ty = Float(fy - Double(y0))
            for x in 0..<toWidth {
                let fx = min(Double(width - 1), max(0, (Double(x) + 0.5) * sx - 0.5))
                let x0 = Int(fx), x1 = min(width - 1, x0 + 1)
                let tx = Float(fx - Double(x0))
                let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
                let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
                out[y * toWidth + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }
}
