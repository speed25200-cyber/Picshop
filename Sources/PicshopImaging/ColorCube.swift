#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// 3D LUTs on the GPU: colour matches ("make it look like that shot") and
/// imported `.cube` looks. Cubes are computed once per distinct input and kept
/// in a small cache, so scrubbing a matched clip costs one filter per frame.
public final class ColorCube: @unchecked Sendable {
    public static let shared = ColorCube()

    private let lock = NSLock()
    private var cubes: [Int: (dimension: Int, data: Data)] = [:]
    private var order: [Int] = []
    private let capacity = 24
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    private func cube(for key: Int, make: () -> (Int, [Float])) -> (dimension: Int, data: Data) {
        lock.lock()
        if let cached = cubes[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let (dimension, floats) = make()
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        cubes[key] = (dimension, data)
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            cubes.removeValue(forKey: evicted)
        }
        lock.unlock()
        return (dimension, data)
    }

    private func apply(dimension: Int, data: Data, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = data
        filter.colorSpace = sRGB
        return filter.outputImage ?? image
    }

    public func apply(_ match: ColorMatch, to image: CIImage) -> CIImage {
        guard match.strength > 0.001 else { return image }
        let entry = cube(for: match.hashValue) { (32, match.cube(dimension: 32)) }
        return apply(dimension: entry.dimension, data: entry.data, to: image)
    }

    /// HSL mixer and three-way grade, baked into one cube.
    public func apply(mixer: ColorMixer?, grade: ColorGrade?, to image: CIImage) -> CIImage {
        guard mixer?.isNeutral == false || grade?.isNeutral == false else { return image }
        var hasher = Hasher()
        hasher.combine("mixer-grade")
        hasher.combine(mixer)
        hasher.combine(grade)
        let entry = cube(for: hasher.finalize()) { (33, ColorEngine.cube(mixer: mixer, grade: grade, dimension: 33)) }
        return apply(dimension: entry.dimension, data: entry.data, to: image)
    }

    public func apply(_ lut: CubeLUT, intensity: Double = 1, to image: CIImage) -> CIImage {
        let entry = cube(for: lut.hashValue) { (lut.dimension, lut.data) }
        let graded = apply(dimension: entry.dimension, data: entry.data, to: image)
        guard intensity < 0.999 else { return graded }
        return AdjustmentPipeline.blend(graded, over: image, alpha: max(0, intensity))
    }
}
#endif
