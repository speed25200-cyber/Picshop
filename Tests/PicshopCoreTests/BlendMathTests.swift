import XCTest
@testable import PicshopCore

/// The 27 blend modes' reference formulas: W3C Compositing and Blending, plus Photoshop's
/// extra modes, on six colour pairs (values from an independent implementation of the
/// published formulas), the alpha mix, dissolve and the menu's sections.
final class BlendMathTests: XCTestCase {
    private static let pairs: [(backdrop: BlendMath.RGB, source: BlendMath.RGB)] = [
        (.init(bytes: 204, 128, 51), .init(bytes: 51, 153, 230)),
        (.init(bytes: 30, 60, 90), .init(bytes: 200, 180, 40)),
        (.init(bytes: 255, 255, 255), .init(bytes: 128, 64, 0)),
        (.init(bytes: 0, 0, 0), .init(bytes: 100, 150, 200)),
        (.init(bytes: 120, 200, 80), .init(bytes: 128, 128, 128)),
        (.init(bytes: 250, 20, 130), .init(bytes: 10, 240, 90)),
    ]

    /// B(Cb, Cs) for each pair, in the order of `pairs`.
    private static let expected: [BlendMode: [[Double]]] = [
        .normal: [[0.200000, 0.600000, 0.901961], [0.784314, 0.705882, 0.156863], [0.501961, 0.250980, 0.000000], [0.392157, 0.588235, 0.784314], [0.501961, 0.501961, 0.501961], [0.039216, 0.941176, 0.352941]],
        .multiply: [[0.160000, 0.301176, 0.180392], [0.092272, 0.166090, 0.055363], [0.501961, 0.250980, 0.000000], [0.000000, 0.000000, 0.000000], [0.236217, 0.393695, 0.157478], [0.038447, 0.073818, 0.179931]],
        .screen: [[0.840000, 0.800784, 0.921569], [0.809689, 0.775087, 0.454441], [1.000000, 1.000000, 1.000000], [0.392157, 0.588235, 0.784314], [0.736332, 0.892580, 0.658208], [0.981161, 0.945790, 0.682814]],
        .overlay: [[0.680000, 0.601569, 0.360784], [0.184544, 0.332180, 0.110727], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.472434, 0.785160, 0.314956], [0.962322, 0.147636, 0.365629]],
        .softLight: [[0.704000, 0.543267, 0.399373], [0.238710, 0.338214, 0.196214], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.471433, 0.784711, 0.314692], [0.962676, 0.227722, 0.436303]],
        .hardLight: [[0.320000, 0.601569, 0.843137], [0.619377, 0.550173, 0.110727], [1.000000, 0.501961, 0.000000], [0.000000, 0.176471, 0.568627], [0.472664, 0.785160, 0.316417], [0.076894, 0.891580, 0.359862]],
        .darken: [[0.200000, 0.501961, 0.200000], [0.117647, 0.235294, 0.156863], [0.501961, 0.250980, 0.000000], [0.000000, 0.000000, 0.000000], [0.470588, 0.501961, 0.313725], [0.039216, 0.078431, 0.352941]],
        .lighten: [[0.800000, 0.600000, 0.901961], [0.784314, 0.705882, 0.352941], [1.000000, 1.000000, 1.000000], [0.392157, 0.588235, 0.784314], [0.501961, 0.784314, 0.501961], [0.980392, 0.941176, 0.509804]],
        .difference: [[0.600000, 0.098039, 0.701961], [0.666667, 0.470588, 0.196078], [0.498039, 0.749020, 1.000000], [0.392157, 0.588235, 0.784314], [0.031373, 0.282353, 0.188235], [0.941176, 0.862745, 0.156863]],
        .luminosity: [[0.755059, 0.457020, 0.155059], [0.573725, 0.691373, 0.809020], [0.298667, 0.298667, 0.298667], [0.550980, 0.550980, 0.550980], [0.334118, 0.647843, 0.177255], [1.000000, 0.391222, 0.682377]],
        .color: [[0.244941, 0.644941, 0.946902], [0.260877, 0.228268, 0.000000], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.638431, 0.638431, 0.638431], [0.000000, 0.631060, 0.219499]],
        .hue: [[0.290436, 0.632336, 0.890436], [0.256176, 0.226765, 0.020882], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.638431, 0.638431, 0.638431], [0.000000, 0.631060, 0.219499]],
        .colorBurn: [[0.000000, 0.169935, 0.113043], [0.000000, 0.000000, 0.000000], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.000000, 0.570312, 0.000000], [0.500000, 0.020833, 0.000000]],
        .colorDodge: [[1.000000, 1.000000, 1.000000], [0.545455, 0.800000, 0.418605], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.944882, 1.000000, 0.629921], [1.000000, 1.000000, 0.787879]],
        .linearBurn: [[0.000000, 0.101961, 0.101961], [0.000000, 0.000000, 0.000000], [0.501961, 0.250980, 0.000000], [0.000000, 0.000000, 0.000000], [0.000000, 0.286275, 0.000000], [0.019608, 0.019608, 0.000000]],
        .linearDodge: [[1.000000, 1.000000, 1.000000], [0.901961, 0.941176, 0.509804], [1.000000, 1.000000, 1.000000], [0.392157, 0.588235, 0.784314], [0.972549, 1.000000, 0.815686], [1.000000, 1.000000, 0.862745]],
        .linearLight: [[0.200000, 0.701961, 1.000000], [0.686275, 0.647059, 0.000000], [1.000000, 0.501961, 0.000000], [0.000000, 0.176471, 0.568627], [0.474510, 0.788235, 0.317647], [0.058824, 0.960784, 0.215686]],
        .vividLight: [[0.500000, 0.627451, 1.000000], [0.272727, 0.400000, 0.000000], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.472441, 0.787402, 0.314961], [0.750000, 0.666667, 0.305556]],
        .pinLight: [[0.400000, 0.501961, 0.803922], [0.568627, 0.411765, 0.313725], [1.000000, 0.501961, 0.000000], [0.000000, 0.176471, 0.568627], [0.470588, 0.784314, 0.313725], [0.078431, 0.882353, 0.509804]],
        .hardMix: [[1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.000000, 1.000000, 0.000000], [1.000000, 1.000000, 0.000000]],
        .exclusion: [[0.680000, 0.499608, 0.741176], [0.717416, 0.608997, 0.399077], [0.498039, 0.749020, 1.000000], [0.392157, 0.588235, 0.784314], [0.500115, 0.498885, 0.500730], [0.942714, 0.871972, 0.502884]],
        .subtract: [[0.600000, 0.000000, 0.000000], [0.000000, 0.000000, 0.196078], [0.498039, 0.749020, 1.000000], [0.000000, 0.000000, 0.000000], [0.000000, 0.282353, 0.000000], [0.941176, 0.000000, 0.156863]],
        .divide: [[1.000000, 0.836601, 0.221739], [0.150000, 0.333333, 1.000000], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.937500, 1.000000, 0.625000], [1.000000, 0.083333, 1.000000]],
        .saturation: [[0.841098, 0.492411, 0.139137], [0.000000, 0.262890, 0.525781], [1.000000, 1.000000, 1.000000], [0.000000, 0.000000, 0.000000], [0.638431, 0.638431, 0.638431], [0.980392, 0.078431, 0.509804]],
        .darkerColor: [[0.800000, 0.501961, 0.200000], [0.117647, 0.235294, 0.352941], [0.501961, 0.250980, 0.000000], [0.000000, 0.000000, 0.000000], [0.501961, 0.501961, 0.501961], [0.039216, 0.941176, 0.352941]],
        .lighterColor: [[0.200000, 0.600000, 0.901961], [0.784314, 0.705882, 0.156863], [1.000000, 1.000000, 1.000000], [0.392157, 0.588235, 0.784314], [0.470588, 0.784314, 0.313725], [0.980392, 0.078431, 0.509804]],
        .dissolve: [[0.200000, 0.600000, 0.901961], [0.784314, 0.705882, 0.156863], [0.501961, 0.250980, 0.000000], [0.392157, 0.588235, 0.784314], [0.501961, 0.501961, 0.501961], [0.039216, 0.941176, 0.352941]],
    ]

    func testEveryModeMatchesTheReferenceOnSixPairs() {
        XCTAssertEqual(Set(Self.expected.keys), Set(BlendMode.allCases), "every mode has reference values")
        for mode in BlendMode.allCases {
            guard let rows = Self.expected[mode] else { continue }
            XCTAssertEqual(rows.count, Self.pairs.count)
            for (pair, row) in zip(Self.pairs, rows) {
                let result = BlendMath.blend(mode, backdrop: pair.backdrop, source: pair.source)
                XCTAssertEqual(result.r, row[0], accuracy: 1e-6, "\(mode) over \(pair.backdrop) of \(pair.source): \(result)")
                XCTAssertEqual(result.g, row[1], accuracy: 1e-6, "\(mode) over \(pair.backdrop) of \(pair.source): \(result)")
                XCTAssertEqual(result.b, row[2], accuracy: 1e-6, "\(mode) over \(pair.backdrop) of \(pair.source): \(result)")
            }
        }
    }

    func testWellKnownIdentities() {
        let grey = BlendMath.RGB(0.5, 0.5, 0.5), colour = BlendMath.RGB(0.2, 0.6, 0.9)
        let white = BlendMath.RGB(1, 1, 1), black = BlendMath.RGB(0, 0, 0)
        func assertEqual(_ a: BlendMath.RGB, _ b: BlendMath.RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(a.r, b.r, accuracy: 1e-9, message, file: file, line: line)
            XCTAssertEqual(a.g, b.g, accuracy: 1e-9, message, file: file, line: line)
            XCTAssertEqual(a.b, b.b, accuracy: 1e-9, message, file: file, line: line)
        }
        // Neutral sources leave the backdrop alone.
        assertEqual(BlendMath.blend(.multiply, backdrop: colour, source: white), colour, "multiply by white")
        assertEqual(BlendMath.blend(.screen, backdrop: colour, source: black), colour, "screen with black")
        assertEqual(BlendMath.blend(.overlay, backdrop: colour, source: grey), colour, "overlay with mid grey")
        assertEqual(BlendMath.blend(.softLight, backdrop: colour, source: grey), colour, "soft light with mid grey")
        assertEqual(BlendMath.blend(.linearLight, backdrop: colour, source: grey), colour, "linear light with mid grey")
        assertEqual(BlendMath.blend(.difference, backdrop: colour, source: black), colour, "difference with black")
        assertEqual(BlendMath.blend(.subtract, backdrop: colour, source: black), colour, "subtract black")
        assertEqual(BlendMath.blend(.divide, backdrop: colour, source: white), colour, "divide by white")
        // Difference with white inverts; exclusion with white too.
        assertEqual(BlendMath.blend(.difference, backdrop: colour, source: white), BlendMath.RGB(0.8, 0.4, 0.1), "difference with white")
        assertEqual(BlendMath.blend(.exclusion, backdrop: colour, source: white), BlendMath.RGB(0.8, 0.4, 0.1), "exclusion with white")
        // Luminosity of a grey keeps the backdrop's hue at that grey's lightness.
        let lifted = BlendMath.blend(.luminosity, backdrop: colour, source: grey)
        XCTAssertEqual(0.3 * lifted.r + 0.59 * lifted.g + 0.11 * lifted.b, 0.5, accuracy: 1e-9)
        // Hard mix is all or nothing.
        let mixed = BlendMath.blend(.hardMix, backdrop: colour, source: BlendMath.RGB(0.7, 0.3, 0.05))
        assertEqual(mixed, BlendMath.RGB(0, 0, 0.0), "0.2+0.7 < 1, 0.6+0.3 < 1, 0.9+0.05 < 1")
        assertEqual(BlendMath.blend(.hardMix, backdrop: colour, source: BlendMath.RGB(0.8, 0.5, 0.1)), BlendMath.RGB(1, 1, 1), "sums reach 1")
        // Every result stays in range.
        for mode in BlendMode.allCases {
            for pair in Self.pairs {
                let result = BlendMath.blend(mode, backdrop: pair.backdrop, source: pair.source)
                for value in [result.r, result.g, result.b] {
                    XCTAssertTrue((0...1).contains(value), "\(mode): \(result)")
                }
            }
        }
    }

    func testOpacityMixesTheBlendWithTheBackdrop() {
        let backdrop = BlendMath.RGB(0.8, 0.5, 0.2), source = BlendMath.RGB(0.2, 0.6, 0.9)
        for mode in BlendMode.allCases {
            let full = BlendMath.blend(mode, backdrop: backdrop, source: source)
            let none = BlendMath.composite(mode, backdrop: backdrop, source: source, alpha: 0)
            let half = BlendMath.composite(mode, backdrop: backdrop, source: source, alpha: 0.5)
            XCTAssertEqual(none, backdrop, "\(mode) at 0 %")
            XCTAssertEqual(BlendMath.composite(mode, backdrop: backdrop, source: source, alpha: 1), full)
            XCTAssertEqual(half.r, (backdrop.r + full.r) / 2, accuracy: 1e-12, "\(mode) at 50 %")
            XCTAssertEqual(half.b, (backdrop.b + full.b) / 2, accuracy: 1e-12, "\(mode) at 50 %")
        }
    }

    func testDissolveTakesTheSourceInProportionToItsCoverage() {
        var state: UInt64 = 12345
        var taken = 0
        let samples = 20_000
        for _ in 0..<samples {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(state >> 11) / Double(1 << 53)
            if BlendMath.dissolveTakesSource(alpha: 0.5, noise: noise) { taken += 1 }
        }
        XCTAssertEqual(Double(taken) / Double(samples), 0.5, accuracy: 0.02)
        XCTAssertFalse(BlendMath.dissolveTakesSource(alpha: 0, noise: 0))
        XCTAssertTrue(BlendMath.dissolveTakesSource(alpha: 1, noise: 0.999))
    }

    func testTheMenuSectionsHoldEveryModeOnce() {
        let listed = BlendMode.Group.allCases.flatMap(\.modes)
        XCTAssertEqual(listed.count, 27)
        XCTAssertEqual(Set(listed), Set(BlendMode.allCases))
        XCTAssertEqual(BlendMode.Group.allCases.first?.modes.first, .normal)
        XCTAssertEqual(BlendMode.multiply.group, .darken)
        XCTAssertEqual(BlendMode.overlay.group, .contrast)
        XCTAssertEqual(BlendMode.luminosity.group, .component)
        // Names: one per mode, in both languages.
        XCTAssertEqual(Set(BlendMode.allCases.map(\.displayName)).count, 27)
        XCTAssertEqual(Set(BlendMode.allCases.map(\.frenchName)).count, 27)
    }

    func testMovingATextLayerKeepsItsRasterKey() {
        var layer = Layer(name: "Title", content: .text(TextElement(text: "Bonjour")))
        let key = layer.overlayRasterKey
        XCTAssertNotNil(key)
        layer.textElement?.center = PSPoint(x: 0.2, y: 0.9)
        layer.textElement?.rotation = 30
        layer.transform.center = PSPoint(x: 0.1, y: 0.1)
        XCTAssertEqual(layer.overlayRasterKey, key, "where it sits is not part of the raster")
        layer.textElement?.text = "Salut"
        XCTAssertNotEqual(layer.overlayRasterKey, key, "what it says is")
        var shape = Layer(name: "Box", content: .shape(ShapeElement(kind: .rectangle)))
        let shapeKey = shape.overlayRasterKey
        shape.transform.center = PSPoint(x: 0.7, y: 0.3)
        shape.transform.rotation = 45
        XCTAssertEqual(shape.overlayRasterKey, shapeKey)
        shape.shapeElement?.fill = .red
        XCTAssertNotEqual(shape.overlayRasterKey, shapeKey)
        XCTAssertNil(Layer(name: "Fill", content: .fill(.black)).overlayRasterKey)
    }

    func testBlendModesKeepTheirRawValues() throws {
        // Saved projects store the raw value: the 12 first ones must never change.
        XCTAssertEqual(BlendMode.allCases.prefix(12).map(\.rawValue),
                       ["normal", "multiply", "screen", "overlay", "softLight", "hardLight", "darken", "lighten", "difference", "luminosity", "color", "hue"])
        let decoded = try JSONDecoder().decode([BlendMode].self, from: Data(#"["vividLight","dissolve","multiply"]"#.utf8))
        XCTAssertEqual(decoded, [.vividLight, .dissolve, .multiply])
    }
}
