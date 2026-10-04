import XCTest
@testable import PicshopCore

/// D2: the layer coders. Every v2 field round-trips at its default (absent from the JSON) and set; a v1-only layer
/// encodes byte for byte as the W2 build's synthesized encoding; unknown keys and contents survive; malformed v2 values
/// fall back to their defaults without failing the layer; the gradient maths (D9).
final class LayerCodableTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try W3Documents.encoder().encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try W3Documents.decoder().decode(type, from: Data(text.utf8))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try W3Documents.encoder().encode(value)
        let decoded = try W3Documents.decoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
        XCTAssertEqual(try W3Documents.encoder().encode(decoded), data, file: file, line: line)
    }

    private var plain: Layer { W3Documents.image(1, "Tasse") }

    func testEveryV2FieldRoundTripsAloneAndIsAbsentAtItsDefault() throws {
        var variants: [(String, Layer)] = []
        var layer = plain
        layer.fillOpacity = 0.25
        variants.append(("\"fill\":0.25", layer))
        layer = plain
        layer.maskStack = W3Documents.stack
        variants.append(("\"maskStack\":", layer))
        layer = plain
        layer.isMaskEnabled = false
        variants.append(("\"maskEnabled\":false", layer))
        layer = plain
        layer.isMaskLinked = false
        variants.append(("\"maskLinked\":false", layer))
        layer = plain
        layer.isClipped = true
        variants.append(("\"clipped\":true", layer))
        layer = plain
        layer.lockOptions = [.pixels]
        variants.append(("\"lock\":2", layer))
        layer = plain
        layer.parentID = W3Documents.id(9)
        variants.append(("\"parent\":", layer))
        layer = Layer(id: W3Documents.id(1), name: "Courbes", content: .adjustment(.neutral), recipeKind: .curves)
        variants.append(("\"recipeKind\":\"curves\"", layer))
        layer = plain
        layer.bakedMask = MaskReference(id: W3Documents.id(7), source: .region("layer"))
        variants.append(("\"bakedMask\":", layer))
        layer = plain
        layer.refNumber = 4
        variants.append(("\"ref\":4", layer))
        for (key, value) in [("scaleX", 1.5), ("scaleY", 0.5), ("skewX", 12.0), ("skewY", -7.0)] {
            layer = plain
            switch key {
            case "scaleX": layer.transform.scaleX = value
            case "scaleY": layer.transform.scaleY = value
            case "skewX": layer.transform.skewX = value
            default: layer.transform.skewY = value
            }
            variants.append(("\"\(key)\":", layer))
        }
        layer = plain
        layer.transform.quad = [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.9, y: 0.2), PSPoint(x: 0.8, y: 0.9), PSPoint(x: 0.2, y: 0.8)]
        variants.append(("\"quad\":", layer))
        for (key, variant) in variants {
            try roundTrip(variant)
            XCTAssertTrue(try json(variant).contains(key), key)
        }
        // At their defaults none of them is written.
        let text = try json(plain)
        for key in ["\"fill\"", "maskStack", "maskEnabled", "maskLinked", "clipped", "\"lock\"", "\"parent\"", "recipeKind", "bakedMask", "\"ref\"",
                    "scaleX", "scaleY", "skewX", "skewY", "quad"] {
            XCTAssertFalse(text.contains(key), key)
        }
        try roundTrip(plain)
    }

    func testAV1LayerEncodesLikeTheW2SynthesizedEncoding() throws {
        for document in try W2Documents.decoded() + W2Documents.built() {
            for layer in document.layers {
                let ours = try W3Documents.encoder().encode(layer)
                let mirror = try W3Documents.decoder().decode(W2Mirror.Layer.self, from: ours)
                XCTAssertEqual(try W2Mirror.encoder().encode(mirror), ours, layer.name)
                XCTAssertFalse(layer.usesV2State, layer.name)
            }
        }
    }

    func testAnUnknownContentAndUnknownKeysSurviveVerbatim() throws {
        let original = #"{"blendMode":"normal","content":{"hologram":{"_0":{"depth":[1,2,3],"source":"media\/h.bin"}}},"edits":{"operations":[]},"#
            + #""id":"00000000-0000-4000-8000-000000000001","isLocked":false,"isVisible":true,"name":"Holo","opacity":1,"#
            + #""transform":{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1,"zCurve":7},"#
            + #""zAnchor":"top","zBevel":{"size":3},"zGlow":[0.5]}"#
        let layer = try decode(Layer.self, original)
        guard case .unsupported = layer.content else { return XCTFail("expected .unsupported") }
        XCTAssertEqual(Set(layer.retainedFields.keys), ["zAnchor", "zBevel", "zGlow"])
        XCTAssertEqual(layer.transform.retainedFields, ["zCurve": "7"])
        XCTAssertEqual(try json(layer), original)
        XCTAssertTrue(layer.usesV2State)
        XCTAssertTrue(layer.referencedPathsForTest.contains("media/h.bin"))
    }

    func testMalformedV2ValuesFallBackToTheirDefaults() throws {
        let text = try json(plain).dropLast()
            + #","clipped":"yes","fill":"x","lock":"pixels","maskEnabled":3,"maskStack":"junk","parent":5,"recipeKind":"posterize","ref":"two"}"#
        let layer = try decode(Layer.self, String(text))
        XCTAssertEqual(layer.fillOpacity, 1)
        XCTAssertNil(layer.maskStack)
        XCTAssertTrue(layer.isMaskEnabled)
        XCTAssertFalse(layer.isClipped)
        XCTAssertEqual(layer.lockOptions, [])
        XCTAssertNil(layer.parentID)
        XCTAssertNil(layer.recipeKind)
        XCTAssertNil(layer.refNumber)
        XCTAssertEqual(layer.retainedFields, [:], "a known key is never retained")
        let transform = try decode(LayerTransform.self, #"{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"#
                                       + #""quad":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1}],"rotation":0,"scale":1,"scaleX":"wide","skewY":"x"}"#)
        XCTAssertNil(transform.quad)
        XCTAssertEqual(transform.scaleX, 1)
        XCTAssertEqual(transform.skewY, 0)
        // A v1 key stays required: a layer without "name" is broken.
        XCTAssertThrowsError(try decode(Layer.self, try json(plain).replacingOccurrences(of: "\"name\"", with: "\"nom\"")))
    }

    func testLockOptionsKeepUnknownBitsAndCodeAsAnInt() throws {
        XCTAssertEqual(try json(LayerLockOptions([.position, .transparency])), "5")
        let read = try decode(LayerLockOptions.self, "45")
        XCTAssertEqual(read.rawValue, 45)
        XCTAssertTrue(read.contains(.position))
        XCTAssertEqual(try json(read), "45")
        var layer = plain
        layer.lockOptions = read
        try roundTrip(layer)
    }

    // MARK: Gradients (D9)

    func testGradientStopsAreNormalisedOnDecode() throws {
        let red = #"{"alpha":1,"blue":0,"green":0,"red":1}"#
        let one = try decode(GradientFill.self, #"{"stops":[{"at":0.3,"color":\#(red)}]}"#)
        XCTAssertEqual(one.stops.map(\.location), [0.3, 1])
        XCTAssertEqual(one.stops.map(\.color), [.init(red: 1, green: 0, blue: 0), .init(red: 1, green: 0, blue: 0)])
        let atEnd = try decode(GradientFill.self, #"{"stops":[{"at":1,"color":\#(red)}]}"#)
        XCTAssertEqual(atEnd.stops.map(\.location), [0, 1])
        let clamped = try decode(GradientFill.self, #"{"stops":[{"at":1.5,"color":\#(red)},{"at":-2,"color":\#(red)}],"angle":"x","style":"radial"}"#)
        XCTAssertEqual(clamped.stops.map(\.location), [0, 1])
        XCTAssertEqual(clamped.angle, 90)
        XCTAssertEqual(clamped.style, .radial)
        let many = (0..<11).map { #"{"at":\#(Double(10 - $0) / 10),"color":\#(red)}"# }.joined(separator: ",")
        let capped = try decode(GradientFill.self, "{\"stops\":[\(many)]}")
        XCTAssertEqual(capped.stops.count, 8)
        XCTAssertEqual(capped.stops.map(\.location), [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7])
    }

    func testGradientColourIsAPremultipliedMixAfterReverse() {
        let gradient = GradientFill.twoColor(PSColor(red: 1, green: 0, blue: 0), PSColor(red: 0, green: 0, blue: 1))
        assertColor(gradient.color(at: 0), PSColor(red: 1, green: 0, blue: 0))
        assertColor(gradient.color(at: 0.25), PSColor(red: 0.75, green: 0, blue: 0.25))
        assertColor(gradient.color(at: 1), PSColor(red: 0, green: 0, blue: 1))
        assertColor(gradient.color(at: -1), PSColor(red: 1, green: 0, blue: 0))
        var reversed = gradient
        reversed.reverse = true
        assertColor(reversed.color(at: 0.25), PSColor(red: 0.25, green: 0, blue: 0.75))
        // Red to clear keeps red as it fades (no dark fringe).
        let fade = GradientFill.twoColor(PSColor(red: 1, green: 0, blue: 0), .clear)
        assertColor(fade.color(at: 0.5), PSColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        // Three stops: piecewise.
        let three = GradientFill(stops: [GradientStop(location: 0, color: .black), GradientStop(location: 0.5, color: .white),
                                         GradientStop(location: 1, color: .black)])
        assertColor(three.color(at: 0.25), PSColor(red: 0.5, green: 0.5, blue: 0.5))
        assertColor(three.color(at: 0.75), PSColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    func testGradientParameterFollowsTheStyleAngleScaleAndCentre() {
        // Linear, 90°: bottom → top over the diagonal; 0.5 at the centre.
        var linear = GradientFill.twoColor(.black, .white)
        XCTAssertEqual(linear.parameter(at: PSPoint(x: 0.5, y: 0.5), aspect: 4.0 / 3), 0.5, accuracy: 1e-12)
        let diagonal = (pow(4.0 / 3, 2) + 1).squareRoot()
        XCTAssertEqual(linear.parameter(at: PSPoint(x: 0.5, y: 0.4), aspect: 4.0 / 3), 0.5 + 0.1 / diagonal, accuracy: 1e-12)
        XCTAssertGreaterThan(linear.parameter(at: PSPoint(x: 0.5, y: 0.2), aspect: 1), linear.parameter(at: PSPoint(x: 0.5, y: 0.8), aspect: 1))
        // 0°: left → right, scale halves the span.
        linear.angle = 0
        linear.scale = 50
        XCTAssertEqual(linear.parameter(at: PSPoint(x: 0.6, y: 0.9), aspect: 1), 0.5 + 0.1 / (0.5 * 2.0.squareRoot()), accuracy: 1e-12)
        XCTAssertEqual(linear.parameter(at: PSPoint(x: 1, y: 0.5), aspect: 1), 1)
        // Radial: 0 at the centre, 1 at the half diagonal (a corner at 100 %), in square units.
        let radial = GradientFill(style: .radial, stops: GradientFill.blackToTransparent.stops, center: PSPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(radial.parameter(at: PSPoint(x: 0.5, y: 0.5), aspect: 2), 0)
        XCTAssertEqual(radial.parameter(at: PSPoint(x: 1, y: 1), aspect: 2), 1, accuracy: 1e-12)
        XCTAssertEqual(radial.parameter(at: PSPoint(x: 0.75, y: 0.5), aspect: 2), 0.5 / (5.0.squareRoot() / 2), accuracy: 1e-12)
        // Reflected: the centre is 0, both sides rise.
        let reflected = GradientFill(style: .reflected, stops: GradientFill.blackToTransparent.stops, angle: 0)
        XCTAssertEqual(reflected.parameter(at: PSPoint(x: 0.5, y: 0.5), aspect: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(reflected.parameter(at: PSPoint(x: 0.3, y: 0.5), aspect: 1), reflected.parameter(at: PSPoint(x: 0.7, y: 0.5), aspect: 1), accuracy: 1e-12)
    }

    private func assertColor(_ a: PSColor, _ b: PSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(a.alpha, b.alpha, accuracy: 1e-12, file: file, line: line)
    }
}

private extension Layer {
    /// The paths a document holding only this layer references.
    var referencedPathsForTest: Set<String> {
        var document = PhotoDocument(title: "t", canvasSize: PSSize(width: 10, height: 10))
        document.layers = [self]
        return document.referencedPaths
    }
}
