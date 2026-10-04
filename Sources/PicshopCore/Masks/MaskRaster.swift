import Foundation

/// An 8-bit gray raster, row 0 at the top (selections, AI masks).
public struct GrayRaster: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// All zero (nothing selected) at that size.
    public init(width: Int, height: Int) {
        self.init(width: max(0, width), height: max(0, height), bytes: [UInt8](repeating: 0, count: max(0, width) * max(0, height)))
    }

    /// The size and the byte count agree, and there is at least one pixel.
    public var isValid: Bool { width > 0 && height > 0 && bytes.count == width * height }
}

/// A float raster 0…1, row 0 at the top (the reference's mask values).
public struct FloatRaster: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// All zero at that size.
    public init(width: Int, height: Int) {
        self.init(width: max(0, width), height: max(0, height), values: [Float](repeating: 0, count: max(0, width) * max(0, height)))
    }

    public var isValid: Bool { width > 0 && height > 0 && values.count == width * height }

    /// The value at a pixel, 0 outside.
    public subscript(x: Int, y: Int) -> Float {
        guard x >= 0, y >= 0, x < width, y < height, isValid else { return 0 }
        return values[y * width + x]
    }

    /// Rounded to 8 bits (0…1 → 0…255, clamped; NaN is 0).
    public var grayRaster: GrayRaster {
        GrayRaster(width: width, height: height, bytes: values.map { $0.isNaN ? 0 : UInt8((Double($0).clamped(to: 0...1) * 255).rounded()) })
    }

    /// Bytes as 0…1.
    public init(_ raster: GrayRaster) {
        self.init(width: raster.width, height: raster.height, values: raster.bytes.map { Float($0) / 255 })
    }
}

/// What the CPU reference reads besides the stack: the layer's pixels and the rasters' samples.
public protocol MaskPixelSource {
    /// The layer's gamma sRGB RGBA8 at the raster size (row 0 top); nil when no component reads pixels.
    var rgba: [UInt8]? { get }
    /// A raster's samples 0…1 at its own size (row 0 top), or nil when missing.
    func samples(of raster: RasterRef) -> FloatRaster?
}

/// The CPU reference rasterizer: D1 exactly. Every GPU path (M2) is tested against it.
///
/// Conventions the GPU path matches:
/// - pixel centres sit at ((x + 0.5) / width, (y + 0.5) / height), top-left origin;
/// - an `.unsupported` component is skipped and does not count as the first component;
/// - a component whose input is missing (a raster file, the pixels for a range) evaluates to 0 everywhere;
/// - every component is 0 outside its raster's quad (the GPU composites over opaque black, D5 item 4).
public enum MaskRaster {
    /// The reference: D1 exactly, at width × height, pixel centres at (x + 0.5) / width.
    public static func render(_ stack: MaskStack, width: Int, height: Int, source: any MaskPixelSource) -> FloatRaster {
        guard width > 0, height > 0 else { return FloatRaster(width: width, height: height) }
        let count = width * height
        var mask = [Float](repeating: 0, count: count)
        var isFirst = true
        for component in stack.components {
            if case .unsupported = component.kind { continue }
            let evaluated = evaluate(component, width: width, height: height, source: source)
            let opacity = Float(component.opacity.isFinite ? component.opacity.clamped(to: 0...1) : 1)
            let inverted = component.isInverted
            // D1: a first component in subtract mode starts from everything.
            if isFirst {
                isFirst = false
                if component.mode == .subtract { mask = [Float](repeating: 1, count: count) }
            }
            // A missing input is an empty component (v = 0 everywhere).
            let values = evaluated?.values ?? [Float](repeating: 0, count: count)
            let mode = component.mode
            values.withUnsafeBufferPointer { input in
                mask.withUnsafeMutableBufferPointer { m in
                    for index in 0..<count {
                        var v = input[index]
                        if inverted { v = 1 - v }
                        v *= opacity
                        switch mode {
                        case .add: m[index] = max(m[index], v)
                        case .subtract: m[index] = min(m[index], 1 - v)
                        case .intersect: m[index] = min(m[index], v)
                        }
                    }
                }
            }
        }
        var raster = FloatRaster(width: width, height: height, values: mask)
        let longest = Double(max(width, height))
        // 1. Expand or contract: a disk of radius |expand| × 0.02 × L px.
        if stack.expand.isFinite, stack.expand != 0 {
            let radius = abs(stack.expand) * MaskStack.expandRadiusFraction * longest
            raster = stack.expand > 0 ? Morphology.dilate(raster, radius: radius) : Morphology.erode(raster, radius: radius)
        }
        // 2. Feather: a Gaussian of σ = feather × 0.03 × L px.
        if stack.feather.isFinite, stack.feather > 0 {
            raster = Morphology.gaussian(raster, sigma: stack.feather * MaskStack.featherSigmaFraction * longest)
        }
        // 3. Invert, 4. density.
        let density = Float(stack.density.isFinite ? stack.density.clamped(to: 0...1) : 1)
        let invert = stack.isInverted
        raster.values.withUnsafeMutableBufferPointer { values in
            for index in 0..<count {
                var v = min(1, max(0, values[index]))
                if invert { v = 1 - v }
                values[index] = v * density
            }
        }
        return raster
    }

    /// The component's own value v (before its inversion and opacity) at width × height; nil for an
    /// `.unsupported` component or a missing input.
    public static func evaluate(_ component: MaskComponent, width: Int, height: Int, source: any MaskPixelSource) -> FloatRaster? {
        guard width > 0, height > 0 else { return nil }
        switch component.kind {
        case .raster(let raster):
            guard let samples = source.samples(of: raster), samples.isValid else { return nil }
            return placed(samples, corners: raster.corners, width: width, height: height) { $0 }
        case .depthRange(let spec):
            guard let samples = source.samples(of: spec.depth), samples.isValid else { return nil }
            return placed(samples, corners: spec.depth.corners, width: width, height: height) { depth in
                Float(MaskMath.trapezoid(Double(depth), low: spec.low, high: spec.high, feather: spec.feather))
            }
        case .brush(let spec):
            var bytes = [UInt8](repeating: 0, count: width * height)
            BrushRaster.draw(spec.strokes, width: width, height: height, into: &bytes)
            return FloatRaster(width: width, height: height, values: bytes.map { Float($0) / 255 })
        case .linear(let spec):
            return linear(spec, width: width, height: height)
        case .radial(let spec):
            return radial(spec, width: width, height: height)
        case .colorRange(let spec):
            return pixels(source, width: width, height: height) { r, g, b in
                MaskMath.colorRange(MaskMath.lab(bytes: r, g, b), spec)
            }
        case .luminanceRange(let spec):
            return pixels(source, width: width, height: height) { r, g, b in
                MaskMath.trapezoid(MaskMath.luma(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255),
                                   low: spec.low, high: spec.high, feather: spec.feather)
            }
        case .unsupported:
            return nil
        }
    }

    // MARK: Kinds

    /// t = ((p − s)·(e − s)) / |e − s|² in pixel units, v = 1 − smoothstep(0, 1, t). Start and end on the same
    /// pixel select nothing.
    static func linear(_ spec: LinearGradientSpec, width: Int, height: Int) -> FloatRaster {
        let w = Double(width), h = Double(height)
        let sx = spec.start.x * w, sy = spec.start.y * h
        let dx = spec.end.x * w - sx, dy = spec.end.y * h - sy
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-18, lengthSquared.isFinite else { return FloatRaster(width: width, height: height) }
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let py = Double(y) + 0.5 - sy
                for x in 0..<width {
                    let t = ((Double(x) + 0.5 - sx) * dx + py * dy) / lengthSquared
                    out[y * width + x] = Float(1 - MaskMath.smoothstep(0, 1, t))
                }
            }
        }
        return FloatRaster(width: width, height: height, values: values)
    }

    /// d = |R(−θ)(p − c)| scaled by 1/(rx·L), 1/(ry·L); v = 1 − smoothstep(1 − f, 1, d), and a hard edge
    /// (v = 1 for d ≤ 1) when f = 0.
    static func radial(_ spec: RadialGradientSpec, width: Int, height: Int) -> FloatRaster {
        let longest = Double(max(width, height))
        let rx = spec.radiusX * longest, ry = spec.radiusY * longest
        guard rx > 0, ry > 0, rx.isFinite, ry.isFinite else { return FloatRaster(width: width, height: height) }
        let cx = spec.center.x * Double(width), cy = spec.center.y * Double(height)
        let theta = (spec.rotation.isFinite ? spec.rotation : 0) * .pi / 180
        let c = cos(theta), s = sin(theta)
        let feather = spec.feather.isFinite ? spec.feather.clamped(to: 0...1) : 0
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let dy = Double(y) + 0.5 - cy
                for x in 0..<width {
                    let dx = Double(x) + 0.5 - cx
                    // R(−θ) in y-down space: undo the clockwise turn.
                    let u = (c * dx + s * dy) / rx
                    let v = (-s * dx + c * dy) / ry
                    let d = (u * u + v * v).squareRoot()
                    let value = feather <= 0 ? (d <= 1 ? 1 : 0) : 1 - MaskMath.smoothstep(1 - feather, 1, d)
                    out[y * width + x] = Float(value)
                }
            }
        }
        return FloatRaster(width: width, height: height, values: values)
    }

    /// A raster placed by its corners: each output pixel centre goes through the inverse of
    /// quad(unit corners → corners) into raster space, sampled bilinearly (centres at (i + 0.5) / size, edges
    /// clamped) and passed through `transfer`; 0 outside the quad.
    static func placed(_ samples: FloatRaster, corners: [PSPoint], width: Int, height: Int, transfer: (Float) -> Float) -> FloatRaster? {
        let toRaster: PSHomography
        if corners == RasterRef.unitCorners {
            toRaster = .identity
        } else {
            guard let forward = PSHomography.quad(from: RasterRef.unitCorners, to: corners), let inverse = forward.inverse else {
                return FloatRaster(width: width, height: height)
            }
            toRaster = inverse
        }
        let sw = samples.width, sh = samples.height
        var values = [Float](repeating: 0, count: width * height)
        samples.values.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let ny = (Double(y) + 0.5) / Double(height)
                    for x in 0..<width {
                        let point = toRaster.apply(PSPoint(x: (Double(x) + 0.5) / Double(width), y: ny))
                        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { continue }
                        let fx = (point.x * Double(sw) - 0.5).clamped(to: 0...Double(sw - 1))
                        let fy = (point.y * Double(sh) - 0.5).clamped(to: 0...Double(sh - 1))
                        let x0 = Int(fx), y0 = Int(fy)
                        let x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1)
                        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
                        let top = input[y0 * sw + x0] * (1 - tx) + input[y0 * sw + x1] * tx
                        let bottom = input[y1 * sw + x0] * (1 - tx) + input[y1 * sw + x1] * tx
                        out[y * width + x] = transfer(top * (1 - ty) + bottom * ty)
                    }
                }
            }
        }
        return FloatRaster(width: width, height: height, values: values)
    }

    /// A per-pixel function of the layer's gamma sRGB bytes; nil without pixels of the right size.
    private static func pixels(_ source: any MaskPixelSource, width: Int, height: Int,
                               _ value: (UInt8, UInt8, UInt8) -> Double) -> FloatRaster? {
        guard let rgba = source.rgba, rgba.count >= width * height * 4 else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        rgba.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { out in
                for index in 0..<(width * height) {
                    out[index] = Float(value(input[4 * index], input[4 * index + 1], input[4 * index + 2]))
                }
            }
        }
        return FloatRaster(width: width, height: height, values: values)
    }
}

// MARK: - Morphology and blur on float rasters (the reference's expand and feather)

/// Disk dilation and erosion, and a separable Gaussian with clamped edges. Shared by MaskRaster (floats) and
/// SelectionAlgebra (bytes, through FloatRaster).
enum Morphology {
    /// Max over a disk of `radius` px (pixel offsets with dx² + dy² ≤ r²). Below half a pixel, nothing changes.
    static func dilate(_ raster: FloatRaster, radius: Double) -> FloatRaster {
        disk(raster, radius: radius, takeMax: true)
    }

    /// Min over a disk of `radius` px.
    static func erode(_ raster: FloatRaster, radius: Double) -> FloatRaster {
        disk(raster, radius: radius, takeMax: false)
    }

    /// Separable Gaussian of `sigma` px, kernel radius ⌈3σ⌉, edges clamped. Below 0.05 px, nothing changes.
    static func gaussian(_ raster: FloatRaster, sigma: Double) -> FloatRaster {
        guard raster.isValid, sigma.isFinite, sigma >= 0.05 else { return raster }
        let radius = min(Int((3 * sigma).rounded(.up)), max(raster.width, raster.height))
        guard radius >= 1 else { return raster }
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        let width = raster.width, height = raster.height
        var horizontal = [Float](repeating: 0, count: width * height)
        var result = [Float](repeating: 0, count: width * height)
        raster.values.withUnsafeBufferPointer { input in
            horizontal.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var sum: Float = 0
                        for k in -radius...radius {
                            let sx = min(width - 1, max(0, x + k))
                            sum += input[row + sx] * kernel[k + radius]
                        }
                        out[row + x] = sum
                    }
                }
            }
        }
        horizontal.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    for x in 0..<width {
                        var sum: Float = 0
                        for k in -radius...radius {
                            let sy = min(height - 1, max(0, y + k))
                            sum += input[sy * width + x] * kernel[k + radius]
                        }
                        out[y * width + x] = sum
                    }
                }
            }
        }
        return FloatRaster(width: width, height: height, values: result)
    }

    /// Disk max or min, row by row: for each vertical offset dy the disk is a horizontal run of half-width
    /// ⌊√(r² − dy²)⌋, so each distinct half-width gets one sliding window pass, then the rows are combined.
    /// Pixels outside the raster do not take part (edges are not padded).
    private static func disk(_ raster: FloatRaster, radius: Double, takeMax: Bool) -> FloatRaster {
        guard raster.isValid, radius.isFinite, radius >= 0.5 else { return raster }
        let width = raster.width, height = raster.height
        let reach = min(Int(radius.rounded(.down)), max(width, height))
        guard reach >= 1 else { return raster }
        let halfWidths = (0...reach).map { dy in Int((radius * radius - Double(dy * dy)).squareRoot().rounded(.down)) }
        var runs: [Int: [Float]] = [:]
        for half in Set(halfWidths) {
            runs[half] = slidingWindow(raster, half: half, takeMax: takeMax)
        }
        // The centre row of the disk first: a pixel always sees itself.
        var result = runs[halfWidths[0]] ?? raster.values
        result.withUnsafeMutableBufferPointer { out in
            for dy in -reach...reach where dy != 0 {
                guard let run = runs[halfWidths[abs(dy)]] else { continue }
                run.withUnsafeBufferPointer { input in
                    for y in 0..<height {
                        let sy = y + dy
                        guard sy >= 0, sy < height else { continue }
                        let row = y * width, sourceRow = sy * width
                        for x in 0..<width {
                            let v = input[sourceRow + x]
                            if takeMax {
                                if v > out[row + x] { out[row + x] = v }
                            } else if v < out[row + x] {
                                out[row + x] = v
                            }
                        }
                    }
                }
            }
        }
        return FloatRaster(width: width, height: height, values: result)
    }

    /// The max (or min) over [x − half, x + half] on each row, edges not padded (van Herk / Gil–Werman).
    private static func slidingWindow(_ raster: FloatRaster, half: Int, takeMax: Bool) -> [Float] {
        let width = raster.width, height = raster.height
        guard half > 0 else { return raster.values }
        let size = 2 * half + 1
        var out = [Float](repeating: 0, count: width * height)
        var prefix = [Float](repeating: 0, count: width)
        var suffix = [Float](repeating: 0, count: width)
        let pick: (Float, Float) -> Float = takeMax ? { max($0, $1) } : { min($0, $1) }
        raster.values.withUnsafeBufferPointer { input in
            for y in 0..<height {
                let row = y * width
                // Running extrema inside blocks of `size`, forwards and backwards.
                for x in 0..<width {
                    prefix[x] = x % size == 0 ? input[row + x] : pick(prefix[x - 1], input[row + x])
                }
                for x in stride(from: width - 1, through: 0, by: -1) {
                    suffix[x] = (x == width - 1 || (x + 1) % size == 0) ? input[row + x] : pick(suffix[x + 1], input[row + x])
                }
                for x in 0..<width {
                    let lo = max(0, x - half), hi = min(width - 1, x + half)
                    // [lo, hi] spans at most two blocks: the suffix of lo's block and the prefix of hi's.
                    if lo / size == hi / size {
                        var value = input[row + lo]
                        if hi > lo { for k in (lo + 1)...hi { value = pick(value, input[row + k]) } }
                        out[row + x] = value
                    } else {
                        out[row + x] = pick(suffix[lo], prefix[hi])
                    }
                }
            }
        }
        return out
    }
}
