import XCTest
import PicshopCore
@testable import PicshopImaging

/// « Ciel » without a model (W2, D8): procedural pictures with a known sky. Pure Swift, runs on Linux.
///
/// The easy case (a blue sky over a building) must be near perfect. The four hard cases (an orange-to-violet
/// sunset, a grey overcast sky, a fractal tree line, a lake reflecting the sky) must reach IoU ≥ 0.85 on three
/// of four and never fall below 0.5; whenever one is under 0.85, the heuristic's own confidence must be under
/// the threshold that marks the result approximate. The reflection is never more than 10 % sky.
final class SkyMaskTests: XCTestCase {
    static let width = 320
    static let height = 240

    // MARK: - Fixtures

    /// A picture and its ground truth (true = sky), plus the lake's pixels for the reflection check.
    struct Scene {
        var name: String
        var rgba: [UInt8]
        var sky: [Bool]
        var water: [Bool] = []
        var building: [Bool] = []
    }

    /// Deterministic value noise in −1…1.
    static func hash(_ x: Int, _ y: Int, seed: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h % 10_000) / 5_000 - 1
    }

    static func smoothNoise(_ x: Double, seed: Int) -> Double {
        let x0 = Int(x.rounded(.down)), t = x - Double(x0)
        let a = hash(x0, 0, seed: seed), b = hash(x0 + 1, 0, seed: seed)
        let s = t * t * (3 - 2 * t)
        return a + (b - a) * s
    }

    /// 1-D fractal noise (five octaves), about −1…1.
    static func fractal(_ x: Double, seed: Int) -> Double {
        var total = 0.0, amplitude = 0.5, frequency = 1.0
        for octave in 0..<5 {
            total += smoothNoise(x * frequency, seed: seed + octave * 31) * amplitude
            amplitude *= 0.5
            frequency *= 2.2
        }
        return total
    }

    static func blank() -> [UInt8] { [UInt8](repeating: 255, count: width * height * 4) }

    static func put(_ rgba: inout [UInt8], _ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
        let i = (y * width + x) * 4
        rgba[i] = UInt8((min(1, max(0, r)) * 255).rounded())
        rgba[i + 1] = UInt8((min(1, max(0, g)) * 255).rounded())
        rgba[i + 2] = UInt8((min(1, max(0, b)) * 255).rounded())
        rgba[i + 3] = 255
    }

    static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// A blue gradient sky over a grey building with windows and a textured ground.
    static func blueSkyOverBuilding() -> Scene {
        var rgba = blank()
        var sky = [Bool](repeating: false, count: width * height), building = sky
        let horizon = Int(Double(height) * 0.55)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let inBuilding = x >= width * 30 / 100 && x < width * 65 / 100 && y >= height * 25 / 100
                if inBuilding {
                    building[index] = true
                    let window = (x / 8) % 2 == 0 && (y / 10) % 2 == 0
                    let n = hash(x, y, seed: 7) * 0.03
                    if window { put(&rgba, x, y, 0.2 + n, 0.22 + n, 0.26 + n) } else { put(&rgba, x, y, 0.47 + n, 0.44 + n, 0.41 + n) }
                } else if y < horizon {
                    sky[index] = true
                    let c = mix((0.22, 0.42, 0.82), (0.62, 0.76, 0.95), Double(y) / Double(horizon))
                    let n = hash(x, y, seed: 3) * 0.004
                    put(&rgba, x, y, c.0 + n, c.1 + n, c.2 + n)
                } else {
                    let n = hash(x, y, seed: 5) * 0.08
                    put(&rgba, x, y, 0.30 + n, 0.33 + n, 0.18 + n)
                }
            }
        }
        return Scene(name: "blue sky", rgba: rgba, sky: sky, building: building)
    }

    /// A violet-to-pink-to-orange sunset over dark jagged hills.
    static func sunset() -> Scene {
        var rgba = blank()
        var sky = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            let ridge = Int(Double(height) * (0.66 + 0.06 * fractal(Double(x) / 40, seed: 11)))
            for y in 0..<height {
                let index = y * width + x
                if y < ridge {
                    sky[index] = true
                    let t = Double(y) / (Double(height) * 0.7)
                    let c = t < 0.5 ? mix((0.36, 0.25, 0.56), (0.86, 0.45, 0.56), t / 0.5) : mix((0.86, 0.45, 0.56), (0.98, 0.62, 0.26), min(1, (t - 0.5) / 0.5))
                    let n = hash(x, y, seed: 13) * 0.004
                    put(&rgba, x, y, c.0 + n, c.1 + n, c.2 + n)
                } else {
                    let n = hash(x, y, seed: 17) * 0.03
                    put(&rgba, x, y, 0.09 + n, 0.06 + n, 0.09 + n)
                }
            }
        }
        return Scene(name: "sunset", rgba: rgba, sky: sky)
    }

    /// A low-saturation grey sky over a muted, textured landscape.
    static func overcast() -> Scene {
        var rgba = blank()
        var sky = [Bool](repeating: false, count: width * height)
        let horizon = Int(Double(height) * 0.6)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if y < horizon {
                    sky[index] = true
                    let c = mix((0.74, 0.75, 0.78), (0.86, 0.87, 0.88), Double(y) / Double(horizon))
                    let n = hash(x, y, seed: 23) * 0.01
                    put(&rgba, x, y, c.0 + n, c.1 + n, c.2 + n)
                } else {
                    let n = hash(x, y, seed: 29) * 0.07
                    let field = (x / 40 + y / 20) % 2 == 0
                    if field { put(&rgba, x, y, 0.36 + n, 0.41 + n, 0.29 + n) } else { put(&rgba, x, y, 0.42 + n, 0.38 + n, 0.30 + n) }
                }
            }
        }
        return Scene(name: "overcast", rgba: rgba, sky: sky)
    }

    /// A blue sky behind a fractal tree line, with sky seen through gaps in the branches.
    static func treeLine() -> Scene {
        var rgba = blank()
        var sky = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            let top = Int(Double(height) * (0.52 + 0.12 * fractal(Double(x) / 18, seed: 41)))
            for y in 0..<height {
                let index = y * width + x
                let c = mix((0.25, 0.48, 0.86), (0.6, 0.76, 0.94), Double(y) / Double(height))
                // Branches thin out near the crown: holes of sky within 10 % of the height below it.
                let hole = y >= top && y < top + height / 10 && hash(x / 3, y / 3, seed: 43) > 0.55
                if y < top || hole {
                    sky[index] = true
                    let n = hash(x, y, seed: 47) * 0.004
                    put(&rgba, x, y, c.0 + n, c.1 + n, c.2 + n)
                } else {
                    let n = hash(x, y, seed: 53) * 0.09
                    put(&rgba, x, y, 0.12 + n, 0.25 + n, 0.10 + n)
                }
            }
        }
        return Scene(name: "tree line", rgba: rgba, sky: sky)
    }

    /// A sky over a dark shore line, and below it a lake reflecting the sky (darker, rippled). Two gaps in the shore
    /// let the water meet the sky, one of them through a soft, misty blend.
    static func lake() -> Scene {
        var rgba = blank()
        var sky = [Bool](repeating: false, count: width * height), water = sky
        let shoreTop = Int(Double(height) * 0.45), shoreBottom = Int(Double(height) * 0.48)
        func skyColour(_ y: Int) -> (Double, Double, Double) {
            mix((0.24, 0.45, 0.84), (0.66, 0.79, 0.95), Double(y) / Double(shoreTop))
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let sharpGap = x >= 60 && x < 64
                let mistyGap = x >= 200 && x < 208
                if y < shoreTop {
                    sky[index] = true
                    let c = skyColour(y)
                    let n = hash(x, y, seed: 61) * 0.004
                    put(&rgba, x, y, c.0 + n, c.1 + n, c.2 + n)
                } else if y < shoreBottom && !(sharpGap || mistyGap) {
                    let n = hash(x, y, seed: 67) * 0.08
                    put(&rgba, x, y, 0.15 + n, 0.18 + n, 0.12 + n)
                } else {
                    water[index] = true
                    // The mirror image of the sky, darker, with ripples.
                    let mirrored = max(0, min(shoreTop - 1, shoreTop - 1 - (y - shoreBottom)))
                    var c = skyColour(mirrored)
                    let darkening = 0.86 + 0.02 * sin(Double(y) * 1.3 + Double(x) * 0.05)
                    c = (c.0 * darkening, c.1 * darkening, c.2 * darkening)
                    if mistyGap && y < shoreBottom + 6 {
                        // Mist: the sky's last row fades into the water.
                        let t = Double(y - shoreTop) / Double(shoreBottom + 6 - shoreTop)
                        c = mix(skyColour(shoreTop - 1), c, t)
                    }
                    put(&rgba, x, y, c.0, c.1, c.2)
                }
            }
        }
        return Scene(name: "lake", rgba: rgba, sky: sky, water: water)
    }

    // MARK: - Measures

    static func iou(_ mask: [UInt8], _ truth: [Bool]) -> Double {
        var intersection = 0, union = 0
        for index in truth.indices {
            let selected = mask[index] > 127
            if selected && truth[index] { intersection += 1 }
            if selected || truth[index] { union += 1 }
        }
        return union == 0 ? 1 : Double(intersection) / Double(union)
    }

    static func share(of mask: [UInt8], within region: [Bool]) -> Double {
        var inside = 0, total = 0
        for index in region.indices where region[index] {
            total += 1
            if mask[index] > 127 { inside += 1 }
        }
        return total == 0 ? 0 : Double(inside) / Double(total)
    }

    static func parts(_ scene: Scene) -> String {
        let result = SkyMask.estimate(rgba: scene.rgba, width: width, height: height, refineEdge: false)
        let p = SkyMask.confidenceParts(result.mask, features: SkyMask.Features(rgba: scene.rgba, width: width, height: height))
        return String(format: "colour %.2f top %.2f edge %.2f", p.colour, p.top, p.edge)
    }

    // MARK: - Tests

    func testBlueSkyOverABuildingIsNearlyExact() {
        let scene = Self.blueSkyOverBuilding()
        let result = SkyMask.estimate(rgba: scene.rgba, width: Self.width, height: Self.height)
        let recall = Self.share(of: result.mask, within: scene.sky)
        let leak = Self.share(of: result.mask, within: scene.building)
        XCTAssertGreaterThanOrEqual(recall, 0.95, "sky pixels found")
        XCTAssertLessThanOrEqual(leak, 0.02, "building pixels taken for sky")
        XCTAssertFalse(result.isApproximate, "confidence \(result.confidence) \(Self.parts(scene))")
    }

    func testHardCasesReachTheirIoUOrSayTheyAreApproximate() {
        let scenes = [Self.sunset(), Self.overcast(), Self.treeLine(), Self.lake()]
        var good = 0
        for scene in scenes {
            let result = SkyMask.estimate(rgba: scene.rgba, width: Self.width, height: Self.height)
            let iou = Self.iou(result.mask, scene.sky)
            print("SKY \(scene.name): IoU \(String(format: "%.3f", iou)), confidence \(String(format: "%.2f", result.confidence)) \(Self.parts(scene))")
            XCTAssertGreaterThanOrEqual(iou, 0.5, "\(scene.name) never below 0.5")
            if iou >= 0.85 {
                good += 1
            } else {
                XCTAssertTrue(result.isApproximate, "\(scene.name): IoU \(iou) must come with a low confidence (\(result.confidence))")
            }
        }
        XCTAssertGreaterThanOrEqual(good, 3, "IoU ≥ 0.85 on three of four hard cases")
    }

    func testTheLakeReflectionIsNotSky() {
        let scene = Self.lake()
        let result = SkyMask.estimate(rgba: scene.rgba, width: Self.width, height: Self.height)
        XCTAssertLessThanOrEqual(Self.share(of: result.mask, within: scene.water), 0.10)
    }

    func testForegroundInstancesAndNearDepthAreCutOut() {
        let scene = Self.blueSkyOverBuilding()
        let count = Self.width * Self.height
        // A kite in the sky (a foreground instance) and a near band on the left (depth).
        var foreground = [UInt8](repeating: 0, count: count)
        for y in 20..<40 { for x in 200..<230 { foreground[y * Self.width + x] = 255 } }
        var depth = [Float](repeating: 0.05, count: count)
        for y in 0..<Self.height { for x in 0..<40 { depth[y * Self.width + x] = 0.9 } }
        let result = SkyMask.estimate(rgba: scene.rgba, width: Self.width, height: Self.height, foreground: foreground, depth: depth)
        XCTAssertLessThan(result.mask[30 * Self.width + 215], 64, "the kite is not sky")
        XCTAssertLessThan(result.mask[30 * Self.width + 10], 64, "near pixels are not sky")
        XCTAssertGreaterThan(result.mask[30 * Self.width + 150], 191, "far sky stays")
    }

    func testAPictureWithoutSkyFindsNone() {
        var rgba = Self.blank()
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let n = Self.hash(x, y, seed: 71) * 0.1
                Self.put(&rgba, x, y, 0.2 + n, 0.35 + n, 0.12 + n)
            }
        }
        let result = SkyMask.estimate(rgba: rgba, width: Self.width, height: Self.height)
        XCTAssertTrue(result.isEmpty, "coverage \(result.coverage)")
    }

    func testColourScores() {
        XCTAssertEqual(SkyMask.colourScore(r: 0.3, g: 0.5, b: 0.9), 1)
        XCTAssertGreaterThan(SkyMask.colourScore(r: 0.8, g: 0.81, b: 0.83), 0.8, "overcast")
        XCTAssertGreaterThan(SkyMask.colourScore(r: 0.98, g: 0.62, b: 0.26), 0.5, "a bright orange sunset")
        XCTAssertEqual(SkyMask.colourScore(r: 0.2, g: 0.5, b: 0.15), 0, "foliage")
        XCTAssertEqual(SkyMask.colourScore(r: 0.05, g: 0.05, b: 0.08), 0, "night")
        XCTAssertLessThan(SkyMask.colourScore(r: 0.55, g: 0.3, b: 0.2), 0.3, "brick")
    }
}
