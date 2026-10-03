import XCTest
@testable import PicshopCore

/// PSBackdrop's palette: deterministic k-means, the OKLCH band, and text
/// contrast over every colour the backdrop can show.
final class PaletteTests: XCTestCase {
    /// #0A0A0C, the app's base surface.
    private let base = PSColor(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
    private let primaryText = PSColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    private let secondaryText = PSColor(red: 1, green: 1, blue: 1, alpha: 0.62)

    /// A small deterministic generator, so the property tests are the same on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A thumbnail of a few random blobs over a random ground, like a small photo.
    private func randomThumbnail(_ random: inout SeededGenerator, width: Int = 32, height: Int = 24) -> [UInt8] {
        let ground = (UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = ground.0
            pixels[index * 4 + 1] = ground.1
            pixels[index * 4 + 2] = ground.2
            pixels[index * 4 + 3] = 255
        }
        for _ in 0..<Int.random(in: 1...5, using: &random) {
            let color = (UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random))
            let cx = Int.random(in: 0..<width, using: &random), cy = Int.random(in: 0..<height, using: &random)
            let radius = Int.random(in: 2...12, using: &random)
            for y in max(0, cy - radius)..<min(height, cy + radius) {
                for x in max(0, cx - radius)..<min(width, cx + radius) {
                    let index = (y * width + x) * 4
                    pixels[index] = color.0
                    pixels[index + 1] = color.1
                    pixels[index + 2] = color.2
                }
            }
        }
        return pixels
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 16, height: Int = 16) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { pixels += [r, g, b, 255] }
        return pixels
    }

    // MARK: k-means

    func testDeriveIsDeterministicForAFixedSeed() {
        var random = SeededGenerator(state: 7)
        for _ in 0..<20 {
            let pixels = randomThumbnail(&random)
            let first = PSPalette.derive(rgba: pixels, width: 32, height: 24, seed: 42)
            let second = PSPalette.derive(rgba: pixels, width: 32, height: 24, seed: 42)
            XCTAssertEqual(first, second)
        }
    }

    func testDeriveGivesFourStopsDarkestFirst() {
        var random = SeededGenerator(state: 11)
        for _ in 0..<50 {
            let palette = PSPalette.derive(rgba: randomThumbnail(&random), width: 32, height: 24)
            XCTAssertEqual(palette.stops.count, PSPalette.stopCount)
            let lightness = palette.stops.map { OKLCH($0).l }
            XCTAssertEqual(lightness, lightness.sorted(), "stops must be darkest first")
        }
    }

    func testKMeansFindsTheTwoHalvesOfAPicture() {
        // Left half red, right half blue: the two largest clusters sit on those colours.
        var pixels: [UInt8] = []
        for _ in 0..<16 {
            for x in 0..<16 { pixels += x < 8 ? [220, 30, 30, 255] : [30, 40, 220, 255] }
        }
        let points = PSPalette.samples(rgba: pixels, width: 16, height: 16)
        let clusters = KMeans.run(points, k: 6, passes: 5, seed: 1)
        XCTAssertEqual(clusters.count, 2, "two colours make two non-empty clusters")
        XCTAssertEqual(clusters.map(\.count).reduce(0, +), 256)
        let red = OKLab(PSColor(red: 220 / 255, green: 30 / 255, blue: 30 / 255))
        XCTAssertTrue(clusters.contains { KMeans.distance($0.center, red) < 1e-9 })
    }

    func testTheGlowKeepsTheDominantHue() {
        let palette = PSPalette.derive(rgba: solid(40, 90, 200), width: 16, height: 16)
        let source = OKLCH(PSColor(red: 40 / 255, green: 90 / 255, blue: 200 / 255))
        let glow = OKLCH(palette.glow)
        XCTAssertEqual(glow.l, PSPalette.glowLightness, accuracy: 0.002)
        XCTAssertLessThanOrEqual(glow.c, PSPalette.glowMaxChroma + 1e-3)
        XCTAssertEqual(glow.h, source.h, accuracy: 2)
        // A single colour still gives four distinct stops.
        XCTAssertEqual(Set(palette.stops).count, 4)
    }

    func testNothingToReadGivesTheFallback() {
        XCTAssertEqual(PSPalette.derive(rgba: [], width: 0, height: 0), .fallback)
        XCTAssertEqual(PSPalette.derive(rgba: [1, 2, 3], width: 4, height: 4), .fallback, "too few bytes")
        let transparent = [UInt8](repeating: 0, count: 8 * 8 * 4)
        XCTAssertEqual(PSPalette.derive(rgba: transparent, width: 8, height: 8), .fallback)
    }

    func testLargeImagesAreSampledDown() {
        let pixels = solid(128, 128, 128, width: 256, height: 256)
        let samples = PSPalette.samples(rgba: pixels, width: 256, height: 256)
        XCTAssertLessThanOrEqual(samples.count, 4096)
        XCTAssertGreaterThan(samples.count, 1000)
    }

    // MARK: The band

    func testTheClampKeepsLightnessAndChromaInTheBand() {
        var random = SeededGenerator(state: 3)
        for _ in 0..<200 {
            let palette = PSPalette.derive(rgba: randomThumbnail(&random), width: 32, height: 24, seed: random.next())
            for stop in palette.stops {
                let lch = OKLCH(stop)
                XCTAssertGreaterThanOrEqual(lch.l, PSPalette.lightnessRange.lowerBound - 1e-3)
                XCTAssertLessThanOrEqual(lch.l, PSPalette.lightnessRange.upperBound + 1e-3)
                XCTAssertLessThanOrEqual(lch.c, PSPalette.maxChroma + 1e-3)
            }
        }
    }

    func testExtremeColoursStayInTheBand() {
        for color in [(255, 255, 255), (0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255)] {
            let palette = PSPalette.derive(rgba: solid(UInt8(color.0), UInt8(color.1), UInt8(color.2)), width: 16, height: 16)
            for stop in palette.stops {
                let lch = OKLCH(stop)
                XCTAssertTrue(PSPalette.lightnessRange.contains(lch.l.rounded(toPlaces: 3)), "\(color): L \(lch.l)")
                XCTAssertLessThanOrEqual(lch.c, PSPalette.maxChroma + 1e-3, "\(color)")
            }
        }
    }

    func testFittedColoursAreInGamutAndKeepLightnessAndHue() {
        let wild = OKLCH(l: 0.2, c: 0.4, h: 140)
        let fitted = wild.fitted()
        XCTAssertTrue(fitted.lab.isInGamut())
        XCTAssertLessThan(fitted.c, wild.c)
        XCTAssertEqual(fitted.l, wild.l)
        XCTAssertEqual(fitted.h, wild.h)
        let tame = OKLCH(l: 0.2, c: 0.02, h: 140)
        XCTAssertEqual(tame.fitted(), tame)
    }

    func testOKLabRoundTripsSRGB() {
        var random = SeededGenerator(state: 99)
        for _ in 0..<500 {
            let color = PSColor(red: Double.random(in: 0...1, using: &random), green: Double.random(in: 0...1, using: &random),
                                blue: Double.random(in: 0...1, using: &random))
            let back = OKLCH(color).color
            // The published matrices are inverses to about 1e-7; the sRGB toe multiplies that by 12.92.
            XCTAssertEqual(back.red, color.red, accuracy: 1e-5)
            XCTAssertEqual(back.green, color.green, accuracy: 1e-5)
            XCTAssertEqual(back.blue, color.blue, accuracy: 1e-5)
        }
        XCTAssertEqual(OKLab(.white).l, 1, accuracy: 1e-4)
        XCTAssertEqual(OKLab(.black).l, 0, accuracy: 1e-9)
    }

    // MARK: Contrast

    func testContrastRatioMatchesWCAG() {
        XCTAssertEqual(PSPalette.contrastRatio(.white, .black), 21, accuracy: 1e-9)
        XCTAssertEqual(PSPalette.contrastRatio(.black, .white), 21, accuracy: 1e-9)
        XCTAssertEqual(PSPalette.contrastRatio(.white, .white), 1, accuracy: 1e-9)
        // #767676 on white is the classic 4.54:1.
        let grey = PSColor(hex: "#767676")!
        XCTAssertEqual(PSPalette.contrastRatio(grey, .white), 4.54, accuracy: 0.01)
    }

    func testTranslucentTextIsCompositedFirst() {
        // White at 62 % over the base is lighter than the base, so the ratio is the composite's.
        let ratio = PSPalette.contrastRatio(secondaryText, base)
        let composite = secondaryText.composited(over: base)
        XCTAssertEqual(ratio, PSPalette.contrastRatio(composite, base), accuracy: 1e-12)
        XCTAssertGreaterThan(ratio, 4.5)
    }

    func testTextKeepsAAContrastOverEveryStopAcrossRandomThumbnails() {
        var random = SeededGenerator(state: 2024)
        var worst = Double.greatestFiniteMagnitude
        for _ in 0..<200 {
            let palette = PSPalette.derive(rgba: randomThumbnail(&random), width: 32, height: 24, seed: random.next())
            for stop in palette.stops + [base] {
                let primary = PSPalette.contrastRatio(primaryText, stop)
                let secondary = PSPalette.contrastRatio(secondaryText, stop)
                XCTAssertGreaterThanOrEqual(primary, 4.5, "95 % white over \(stop.hexString)")
                XCTAssertGreaterThanOrEqual(secondary, 4.5, "62 % white over \(stop.hexString)")
                worst = min(worst, secondary)
            }
        }
        XCTAssertGreaterThan(worst, 4.5)
    }

    func testTheFallbackIsValid() {
        let fallback = PSPalette.fallback
        XCTAssertEqual(fallback.stops.count, PSPalette.stopCount)
        let lightness = fallback.stops.map { OKLCH($0).l }
        XCTAssertEqual(lightness, lightness.sorted())
        for stop in fallback.stops {
            let lch = OKLCH(stop)
            XCTAssertTrue(PSPalette.lightnessRange.contains(lch.l.rounded(toPlaces: 3)))
            XCTAssertLessThanOrEqual(lch.c, PSPalette.maxChroma + 1e-3)
            XCTAssertGreaterThanOrEqual(PSPalette.contrastRatio(secondaryText, stop), 4.5)
        }
        XCTAssertEqual(OKLCH(fallback.glow).l, PSPalette.glowLightness, accuracy: 0.002)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
