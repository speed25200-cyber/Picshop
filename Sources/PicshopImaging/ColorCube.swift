#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// 3D LUTs on the GPU: colour matches ("make it look like that shot"), the HSL
/// mixer and grade, green-screen keys and imported `.cube` looks.
///
/// Cubes are computed once per distinct input and kept in a least-recently-used
/// cache (a hit moves to the back of the line), so a clip's match or an imported
/// look survives a drag that bakes a new mixer cube every frame. While a dial is
/// dragged the mixer and grade are baked at 17³ (about 2 ms instead of 12 at 33³)
/// into one scratch slot that never evicts anything; the frame after the drag
/// bakes 33³. Parsed `.cube` files are kept for good, per path, outside the LRU.
public final class ColorCube: @unchecked Sendable {
    public static let shared = ColorCube()

    /// Edge of the cubes baked while a dial moves, and once it settles.
    public static let interactiveDimension = 17
    public static let settledDimension = 33

    typealias Entry = (dimension: Int, data: Data)

    private let lock = NSLock()
    private var cubes: [Int: Entry] = [:]
    /// Least recently used first.
    private var order: [Int] = []
    let capacity: Int
    /// The latest drag cube: one slot, replaced every frame, never in the LRU.
    private var scratch: (key: Int, entry: Entry)?
    /// Parsed `.cube` files by path, kept for the session.
    private var files: [String: Entry] = [:]
    /// How many `.cube` files were read and parsed (tests).
    private(set) var fileParses = 0
    /// Edge of the last cube applied (tests).
    private(set) var lastDimension = 0
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
    }

    /// The cached cube for `key`, made (outside the lock) when missing.
    func cube(for key: Int, make: () -> (Int, [Float])) -> Entry {
        if let cached = lookup(key) { return cached }
        let (dimension, floats) = PSSignpost.measure("color.cube") { make() }
        let entry: Entry = (dimension, floats.withUnsafeBufferPointer { Data(buffer: $0) })
        insert(entry, for: key)
        return entry
    }

    /// A hit moves the key to the most recently used end.
    private func lookup(_ key: Int) -> Entry? {
        lock.withLock {
            guard let cached = cubes[key] else { return nil }
            if let index = order.firstIndex(of: key), index != order.count - 1 {
                order.remove(at: index)
                order.append(key)
            }
            return cached
        }
    }

    private func insert(_ entry: Entry, for key: Int) {
        lock.withLock {
            if cubes[key] == nil { order.append(key) }
            cubes[key] = entry
            while order.count > capacity {
                cubes.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Whether `key` is cached (tests).
    func contains(_ key: Int) -> Bool { lock.withLock { cubes[key] != nil } }

    private func apply(dimension: Int, data: Data, to image: CIImage) -> CIImage {
        lock.withLock { lastDimension = dimension }
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

    /// HSL mixer and three-way grade, baked into one cube. `interactive`: the frame is part
    /// of a drag, baked at 17³ into the scratch slot unless the sharp cube is already there.
    public func apply(mixer: ColorMixer?, grade: ColorGrade?, to image: CIImage, interactive: Bool = false) -> CIImage {
        guard mixer?.isNeutral == false || grade?.isNeutral == false else { return image }
        var hasher = Hasher()
        hasher.combine("mixer-grade")
        hasher.combine(mixer)
        hasher.combine(grade)
        let key = hasher.finalize()
        if interactive, lock.withLock({ cubes[key] == nil }) {
            let entry = scratchCube(for: key) { ColorEngine.cube(mixer: mixer, grade: grade, dimension: Self.interactiveDimension) }
            return apply(dimension: entry.dimension, data: entry.data, to: image)
        }
        let entry = cube(for: key) { (Self.settledDimension, Self.bakeConcurrently(mixer: mixer, grade: grade, dimension: Self.settledDimension)) }
        return apply(dimension: entry.dimension, data: entry.data, to: image)
    }

    /// The drag's cube: reused while the dial holds still, replaced when it moves.
    private func scratchCube(for key: Int, make: () -> [Float]) -> Entry {
        if let scratch = lock.withLock({ scratch }), scratch.key == key { return scratch.entry }
        let floats = PSSignpost.measure("color.cube") { make() }
        let entry: Entry = (Self.interactiveDimension, floats.withUnsafeBufferPointer { Data(buffer: $0) })
        lock.withLock { scratch = (key, entry) }
        return entry
    }

    /// The 33³ cube with its blue slices baked in parallel.
    static func bakeConcurrently(mixer: ColorMixer?, grade: ColorGrade?, dimension n: Int) -> [Float] {
        let slice = n * n * 4
        var data = [Float](repeating: 0, count: n * slice)
        let scale = 1 / Double(n - 1)
        data.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let address = UInt(bitPattern: base)
            DispatchQueue.concurrentPerform(iterations: n) { b in
                // Each iteration writes its own slice only.
                let pointer = UnsafeMutablePointer<Float>(bitPattern: address)!
                var offset = b * slice
                for g in 0..<n {
                    for r in 0..<n {
                        let out = ColorEngine.apply(mixer: mixer, grade: grade, to: (Double(r) * scale, Double(g) * scale, Double(b) * scale))
                        pointer[offset] = Float(out.0)
                        pointer[offset + 1] = Float(out.1)
                        pointer[offset + 2] = Float(out.2)
                        pointer[offset + 3] = 1
                        offset += 4
                    }
                }
            }
        }
        return data
    }

    /// Green-screen key: the cube writes alpha.
    public func apply(_ key: ChromaKey, to image: CIImage) -> CIImage {
        let entry = cube(for: key.hashValue) { (32, key.cube(dimension: 32)) }
        return apply(dimension: entry.dimension, data: entry.data, to: image)
    }

    /// A `.cube` file from the project, read and parsed once per path and kept for
    /// the session. A file that does not parse leaves the picture as it is.
    public func apply(lutAt url: URL, intensity: Double = 1, to image: CIImage) -> CIImage {
        let entry = file(at: url)
        let graded = apply(dimension: entry.dimension, data: entry.data, to: image)
        guard intensity < 0.999 else { return graded }
        return AdjustmentPipeline.blend(graded, over: image, alpha: max(0, intensity))
    }

    private func file(at url: URL) -> Entry {
        let path = url.standardizedFileURL.path
        if let cached = lock.withLock({ files[path] }) { return cached }
        let parsed: Entry
        if let text = try? String(contentsOf: url, encoding: .utf8), let lut = try? CubeLUT.parse(text) {
            parsed = (lut.dimension, lut.data.withUnsafeBufferPointer { Data(buffer: $0) })
        } else {
            parsed = (2, Self.identity2.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        lock.withLock {
            fileParses += 1
            files[path] = parsed
        }
        return parsed
    }

    /// The 2 × 2 × 2 cube that changes nothing.
    static let identity2: [Float] = {
        var values: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { values += [Float(r), Float(g), Float(b), 1] } } }
        return values
    }()

    public func apply(_ lut: CubeLUT, intensity: Double = 1, to image: CIImage) -> CIImage {
        let entry = cube(for: lut.hashValue) { (lut.dimension, lut.data) }
        let graded = apply(dimension: entry.dimension, data: entry.data, to: image)
        guard intensity < 0.999 else { return graded }
        return AdjustmentPipeline.blend(graded, over: image, alpha: max(0, intensity))
    }
}
#endif
