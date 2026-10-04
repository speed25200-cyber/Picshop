import Foundation

/// Selection maths on 8-bit rasters (CPU): combine, invert, grow, shrink, feather, smooth, resample, measure.
/// All functions are total: empty input gives empty output, never a trap. A raster whose byte count does not
/// match its size counts as empty (all zero at its size).
///
/// Combining follows D1 on bytes (255 = 1): add = max, subtract = min(a, 255 − b), intersect = min.
public enum SelectionAlgebra {
    /// nil mode: `new` replaces `base`. `new` is resampled (bilinear) to `base`'s size when they differ.
    /// Without a base, add gives `new`, and subtract and intersect give nothing (there was nothing to cut from).
    public static func combine(_ base: GrayRaster?, _ new: GrayRaster, mode: CombineMode?) -> GrayRaster {
        let incoming = sanitized(new)
        guard let mode else { return incoming }
        guard let base = base.map(sanitized), base.width > 0, base.height > 0 else {
            return mode == .add ? incoming : GrayRaster(width: incoming.width, height: incoming.height)
        }
        let other = (incoming.width == base.width && incoming.height == base.height) ? incoming
            : resampled(incoming, width: base.width, height: base.height)
        var bytes = base.bytes
        other.bytes.withUnsafeBufferPointer { b in
            bytes.withUnsafeMutableBufferPointer { a in
                for index in 0..<a.count {
                    switch mode {
                    case .add: a[index] = max(a[index], b[index])
                    case .subtract: a[index] = min(a[index], 255 - b[index])
                    case .intersect: a[index] = min(a[index], b[index])
                    }
                }
            }
        }
        return GrayRaster(width: base.width, height: base.height, bytes: bytes)
    }

    public static func inverted(_ raster: GrayRaster) -> GrayRaster {
        let raster = sanitized(raster)
        return GrayRaster(width: raster.width, height: raster.height, bytes: raster.bytes.map { 255 - $0 })
    }

    /// Disk max of `radius` px.
    public static func grown(_ raster: GrayRaster, radius: Int) -> GrayRaster {
        let raster = sanitized(raster)
        guard radius > 0, raster.isValid else { return raster }
        return Morphology.dilate(FloatRaster(raster), radius: Double(radius)).grayRaster
    }

    /// Disk min of `radius` px.
    public static func shrunk(_ raster: GrayRaster, radius: Int) -> GrayRaster {
        let raster = sanitized(raster)
        guard radius > 0, raster.isValid else { return raster }
        return Morphology.erode(FloatRaster(raster), radius: Double(radius)).grayRaster
    }

    /// Separable Gaussian of `sigma` px (kernel radius ⌈3σ⌉, edges clamped).
    public static func feathered(_ raster: GrayRaster, sigma: Double) -> GrayRaster {
        let raster = sanitized(raster)
        guard sigma.isFinite, sigma > 0, raster.isValid else { return raster }
        return Morphology.gaussian(FloatRaster(raster), sigma: sigma).grayRaster
    }

    /// Close (grow, then shrink) by `radius`, then open (shrink, then grow), then a 3×3 majority: fills pin
    /// holes and notches, drops specks, and keeps soft edges (the majority is a 3×3 median, which is the
    /// majority vote on a hard mask).
    public static func smoothed(_ raster: GrayRaster, radius: Int) -> GrayRaster {
        let raster = sanitized(raster)
        guard raster.isValid else { return raster }
        var values = FloatRaster(raster)
        if radius > 0 {
            let r = Double(radius)
            values = Morphology.erode(Morphology.dilate(values, radius: r), radius: r)
            values = Morphology.dilate(Morphology.erode(values, radius: r), radius: r)
        }
        return median3(values.grayRaster)
    }

    /// Bilinear at pixel centres; when shrinking an axis, each output pixel averages the source pixels it
    /// covers (area weights), so thin shapes and coverage survive a large reduction.
    public static func resampled(_ raster: GrayRaster, width: Int, height: Int) -> GrayRaster {
        let raster = sanitized(raster)
        guard width > 0, height > 0 else { return GrayRaster(width: width, height: height) }
        guard raster.isValid else { return GrayRaster(width: width, height: height) }
        if raster.width == width, raster.height == height { return raster }
        // Rows first, then columns: each pass is a 1-D resample.
        let horizontal = resample1D(FloatRaster(raster), to: width, alongX: true)
        let both = resample1D(horizontal, to: height, alongX: false)
        return both.grayRaster
    }

    /// The fraction of pixels > 127.
    public static func coverage(_ raster: GrayRaster) -> Double {
        guard raster.isValid else { return 0 }
        var selected = 0
        for value in raster.bytes where value > 127 { selected += 1 }
        return Double(selected) / Double(raster.bytes.count)
    }

    /// The normalised box of the pixels above `threshold`, top-left origin; .zero when there are none.
    public static func boundingBox(_ raster: GrayRaster, threshold: UInt8 = 32) -> PSRect {
        guard raster.isValid else { return .zero }
        var minX = raster.width, minY = raster.height, maxX = -1, maxY = -1
        raster.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<raster.height {
                let row = y * raster.width
                for x in 0..<raster.width where bytes[row + x] > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        let w = Double(raster.width), h = Double(raster.height)
        return PSRect(x: Double(minX) / w, y: Double(minY) / h, width: Double(maxX - minX + 1) / w, height: Double(maxY - minY + 1) / h)
    }

    // MARK: Internals

    /// The raster itself, or all zero at its size when its bytes do not match it.
    static func sanitized(_ raster: GrayRaster) -> GrayRaster {
        raster.isValid ? raster : GrayRaster(width: raster.width, height: raster.height)
    }

    /// The 3×3 median, edges clamped.
    static func median3(_ raster: GrayRaster) -> GrayRaster {
        guard raster.isValid else { return raster }
        let width = raster.width, height = raster.height
        var out = raster.bytes
        var window = [UInt8](repeating: 0, count: 9)
        raster.bytes.withUnsafeBufferPointer { input in
            for y in 0..<height {
                for x in 0..<width {
                    var k = 0
                    for dy in -1...1 {
                        let sy = min(height - 1, max(0, y + dy))
                        for dx in -1...1 {
                            let sx = min(width - 1, max(0, x + dx))
                            window[k] = input[sy * width + sx]
                            k += 1
                        }
                    }
                    window.sort()
                    out[y * width + x] = window[4]
                }
            }
        }
        return GrayRaster(width: width, height: height, bytes: out)
    }

    /// One axis to `size` samples: bilinear (pixel centres) when growing, area-weighted when shrinking.
    private static func resample1D(_ raster: FloatRaster, to size: Int, alongX: Bool) -> FloatRaster {
        let source = alongX ? raster.width : raster.height
        guard source != size else { return raster }
        let outWidth = alongX ? size : raster.width, outHeight = alongX ? raster.height : size
        let lines = alongX ? raster.height : raster.width
        // Per output sample: the source indices and weights.
        var taps: [[(Int, Float)]] = []
        taps.reserveCapacity(size)
        let ratio = Double(source) / Double(size)
        for index in 0..<size {
            if size > source {
                let position = ((Double(index) + 0.5) * ratio - 0.5).clamped(to: 0...Double(source - 1))
                let lower = Int(position), upper = min(lower + 1, source - 1)
                let t = Float(position - Double(lower))
                let pair: [(Int, Float)] = upper == lower ? [(lower, Float(1))] : [(lower, 1 - t), (upper, t)]
                taps.append(pair)
            } else {
                let start = Double(index) * ratio, end = Double(index + 1) * ratio
                var weights: [(Int, Float)] = []
                var cell = Int(start)
                while Double(cell) < end, cell < source {
                    let overlap = min(end, Double(cell + 1)) - max(start, Double(cell))
                    if overlap > 0 { weights.append((cell, Float(overlap / ratio))) }
                    cell += 1
                }
                taps.append(weights)
            }
        }
        var values = [Float](repeating: 0, count: outWidth * outHeight)
        raster.values.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { out in
                for line in 0..<lines {
                    for index in 0..<size {
                        var sum: Float = 0
                        for (tap, weight) in taps[index] {
                            let sourceIndex = alongX ? line * raster.width + tap : tap * raster.width + line
                            sum += input[sourceIndex] * weight
                        }
                        out[alongX ? line * outWidth + index : index * outWidth + line] = sum
                    }
                }
            }
        }
        return FloatRaster(width: outWidth, height: outHeight, values: values)
    }
}
