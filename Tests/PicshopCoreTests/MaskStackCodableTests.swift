import XCTest
@testable import PicshopCore

/// MaskStack and its components on disk (D1, D4, §4.1): every kind round-trips byte for byte, components a newer
/// build wrote are kept, skipped when rendering and written back as read, and the parametric defaults follow
/// §5 item 9.
final class MaskStackCodableTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private let raster = RasterRef(path: "masks/0A1B2C3D-0000-4000-8000-0000000000AA.png", origin: .person, pixelWidth: 1536, pixelHeight: 1024,
                                   boundingBox: PSRect(x: 0.2, y: 0.1, width: 0.3, height: 0.8), label: "2", stateKey: "00112233aabbccdd")

    private var everyKind: [MaskComponent.Kind] {
        [
            .raster(raster),
            .brush(BrushSpec(strokes: [BrushStroke(points: [PSPoint(x: 0.1, y: 0.2), PSPoint(x: 0.3, y: 0.25)], radius: 0.03, hardness: 0.4, mode: .subtract, flow: 0.6)],
                             autoMask: true)),
            .linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 1), end: PSPoint(x: 0.5, y: 0.5))),
            .radial(RadialGradientSpec(center: PSPoint(x: 0.4, y: 0.6), radiusX: 0.2, radiusY: 0.1, rotation: -30, feather: 0.7)),
            .colorRange(ColorRangeSpec(samples: [LabColor(l: 70, a: 10, b: 20), LabColor(l: 30, a: -5, b: 0)], fuzziness: 0.25)),
            .colorRange(ColorRangeSpec(preset: .greens)),
            .luminanceRange(LuminanceRangeSpec(low: 0.33, high: 0.66, feather: 0.1)),
            .depthRange(DepthRangeSpec(depth: RasterRef(path: "masks/depth-0011223344556677.png", origin: .depth, pixelWidth: 518, pixelHeight: 392, bitDepth: 16),
                                       low: 0.6, high: 1, feather: 0.2)),
        ]
    }

    func testEveryKindRoundTripsByteForByte() throws {
        for kind in everyKind {
            for mode in CombineMode.allCases {
                let component = MaskComponent(kind, mode: mode, isInverted: mode == .subtract, opacity: 0.75)
                let data = try encoder().encode(component)
                let decoded = try JSONDecoder().decode(MaskComponent.self, from: data)
                XCTAssertEqual(decoded, component)
                XCTAssertEqual(try encoder().encode(decoded), data)
            }
        }
        let stack = MaskStack(components: everyKind.map { MaskComponent($0) }, isInverted: true, feather: 0.4, expand: 0.2, density: 0.6)
        let data = try encoder().encode(stack)
        XCTAssertEqual(try JSONDecoder().decode(MaskStack.self, from: data), stack)
        XCTAssertEqual(try encoder().encode(try JSONDecoder().decode(MaskStack.self, from: data)), data)
    }

    func testTheTypeNamesAreFrozen() throws {
        let names = try everyKind.map { kind -> String in
            let object = try JSONSerialization.jsonObject(with: try encoder().encode(MaskComponent(kind))) as? [String: Any]
            return object?["type"] as? String ?? "?"
        }
        XCTAssertEqual(names, ["raster", "brush", "linear", "radial", "colorRange", "colorRange", "luminanceRange", "depthRange"])
        let brush = String(decoding: try encoder().encode(BrushSpec(strokes: [], autoMask: true)), as: UTF8.self)
        XCTAssertEqual(brush, #"{"autoMask":true,"strokes":[]}"#)
        let radial = String(decoding: try encoder().encode(RadialGradientSpec(center: .zero, radiusX: 0.1, radiusY: 0.2)), as: UTF8.self)
        XCTAssertEqual(radial, #"{"center":{"x":0,"y":0},"feather":0.5,"radiusX":0.1,"radiusY":0.2,"rotation":0}"#)
        let color = String(decoding: try encoder().encode(ColorRangeSpec(samples: [LabColor(l: 1, a: 2, b: 3)], preset: .reds)), as: UTF8.self)
        XCTAssertEqual(color, #"{"fuzziness":0.4,"preset":"reds","samples":[{"a":2,"b":3,"l":1}]}"#)
    }

    /// A stack with an unknown component type and an unknown mode decodes, renders with those skipped, and
    /// writes back byte for byte.
    func testComponentsFromANewerBuildAreKeptSkippedAndWrittenBack() throws {
        let original = [
            #"{"components":["#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000011","inverted":false,"mode":"add","opacity":1,"spec":{"end":{"x":0.5,"y":0.5},"start":{"x":0.5,"y":1}},"type":"linear"},"#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000012","inverted":false,"mode":"add","opacity":1,"spec":{"field":"hologram"},"type":"lidar"},"#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000013","inverted":false,"mode":"exclude","opacity":1,"spec":{"end":{"x":0.5,"y":0},"start":{"x":0.5,"y":0.5}},"type":"linear"},"#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000014","inverted":false,"mode":"add","opacity":1,"spec":{"center":"middle"},"type":"radial"}"#,
            #"],"density":1,"expand":0,"feather":0,"inverted":false}"#,
        ].joined()
        let stack = try JSONDecoder().decode(MaskStack.self, from: Data(original.utf8))
        XCTAssertEqual(stack.components.count, 4)
        for index in 1...3 {
            guard case .unsupported = stack.components[index].kind else { return XCTFail("component \(index): \(stack.components[index].kind)") }
            XCTAssertFalse(stack.components[index].isPixelDependent)
        }
        // Rendering skips them: the same as the bottom gradient alone.
        let source = MaskTestSource()
        let alone = MaskStack(components: [stack.components[0]])
        XCTAssertEqual(MaskRaster.render(stack, width: 20, height: 20, source: source), MaskRaster.render(alone, width: 20, height: 20, source: source))
        XCTAssertEqual(String(decoding: try encoder().encode(stack), as: UTF8.self), original)
        // Remapping and editing other parts leave them as they are.
        let flipped = stack.remapped(by: EditOperation.Kind.flip(.horizontal).geometryMap(aspectBefore: 1)!, aspectBefore: 1, aspectAfter: 1)
        XCTAssertEqual(Array(flipped.components[1...]), Array(stack.components[1...]))
        // A component that is not even an object fails the stack (a broken document, not a newer one).
        XCTAssertThrowsError(try JSONDecoder().decode(MaskStack.self, from: Data(#"{"components":[42]}"#.utf8)))
    }

    func testLenientComponentFields() throws {
        let json = #"{"spec":{"low":0.1,"high":0.2},"type":"luminanceRange"}"#
        let component = try JSONDecoder().decode(MaskComponent.self, from: Data(json.utf8))
        XCTAssertEqual(component.kind, .luminanceRange(LuminanceRangeSpec(low: 0.1, high: 0.2)))
        XCTAssertEqual(component.mode, .add)
        XCTAssertFalse(component.isInverted)
        XCTAssertEqual(component.opacity, 1)
        XCTAssertTrue(component.isPixelDependent)
    }

    func testContentKeyAndAccessors() {
        let stack = MaskStack(components: everyKind.map { MaskComponent(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000020")!, $0) })
        XCTAssertEqual(stack.contentKey, stack.contentKey)
        XCTAssertEqual(stack.contentKey.count, 16)
        var feathered = stack
        feathered.feather = 0.1
        XCTAssertNotEqual(feathered.contentKey, stack.contentKey)
        XCTAssertTrue(stack.hasPixelDependentComponents)
        XCTAssertEqual(stack.rasterRefs.map(\.path), [raster.path, "masks/depth-0011223344556677.png"])
        XCTAssertFalse(stack.isEmpty)
        XCTAssertTrue(MaskStack().isEmpty)
        XCTAssertFalse(MaskStack.single(MaskComponent(.linear(LinearGradientSpec(start: .zero, end: PSPoint(x: 1, y: 1))))).hasPixelDependentComponents)
        XCTAssertEqual(MaskStack.maxComponents, 12)
        XCTAssertEqual(MaskStack.featherSigmaFraction, 0.03)
        XCTAssertEqual(MaskStack.expandRadiusFraction, 0.02)
    }

    func testRegions() {
        let ai: Set<MaskRegion> = [.subject, .background, .sky, .people, .person, .object, .vegetation, .water,
                                   .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin, .selection]
        for region in MaskRegion.allCases {
            XCTAssertEqual(region.isAI, ai.contains(region), "\(region)")
        }
        XCTAssertEqual(MaskRegion.allCases.count, 29)
        XCTAssertEqual(RasterRef.Origin.allCases.count, 14)
    }

    /// §5 item 9, for three aspects.
    func testTheParametricDefaults() {
        for aspect in [0.75, 1, 1.5] {
            let widthShare = min(1, aspect), heightShare = min(1, 1 / aspect)
            XCTAssertEqual(MaskStack.defaultComponent(for: .top, aspect: aspect)?.kind, .linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0), end: PSPoint(x: 0.5, y: 0.5))))
            XCTAssertEqual(MaskStack.defaultComponent(for: .bottom, aspect: aspect)?.kind, .linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 1), end: PSPoint(x: 0.5, y: 0.5))))
            XCTAssertEqual(MaskStack.defaultComponent(for: .left, aspect: aspect)?.kind, .linear(LinearGradientSpec(start: PSPoint(x: 0, y: 0.5), end: PSPoint(x: 0.5, y: 0.5))))
            XCTAssertEqual(MaskStack.defaultComponent(for: .right, aspect: aspect)?.kind, .linear(LinearGradientSpec(start: PSPoint(x: 1, y: 0.5), end: PSPoint(x: 0.5, y: 0.5))))
            let center = MaskStack.defaultComponent(for: .center, aspect: aspect)
            XCTAssertEqual(center?.kind, .radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.4 * widthShare, radiusY: 0.4 * heightShare, feather: 0.5)))
            XCTAssertEqual(center?.isInverted, false)
            let edges = MaskStack.defaultComponent(for: .edges, aspect: aspect)
            XCTAssertEqual(edges?.kind, center?.kind)
            XCTAssertEqual(edges?.isInverted, true)
            XCTAssertEqual(MaskStack.defaultComponent(for: .shadows, aspect: aspect)?.kind, .luminanceRange(LuminanceRangeSpec(low: 0, high: 0.25, feather: 0.15)))
            XCTAssertEqual(MaskStack.defaultComponent(for: .midtones, aspect: aspect)?.kind, .luminanceRange(LuminanceRangeSpec(low: 0.33, high: 0.66, feather: 0.15)))
            XCTAssertEqual(MaskStack.defaultComponent(for: .highlights, aspect: aspect)?.kind, .luminanceRange(LuminanceRangeSpec(low: 0.75, high: 1, feather: 0.15)))
            XCTAssertEqual(MaskStack.defaultComponent(for: .skinTones, aspect: aspect)?.kind, .colorRange(ColorRangeSpec(preset: .skinTones)))
            let red = LabColor(l: 53, a: 80, b: 67)
            XCTAssertEqual(MaskStack.defaultComponent(for: .color, aspect: aspect, color: red)?.kind, .colorRange(ColorRangeSpec(samples: [red], fuzziness: 0.4)))
            XCTAssertNil(MaskStack.defaultComponent(for: .color, aspect: aspect))
            for region in [MaskRegion.sky, .subject, .near, .far, .selection, .teeth, .object] {
                XCTAssertNil(MaskStack.defaultComponent(for: region, aspect: aspect), "\(region)")
            }
        }
        // The centre ellipse is round on the photo: 0.4 × W wide and 0.4 × H tall, rendered.
        let center = MaskStack.defaultComponent(for: .center, aspect: 2)!
        let raster = MaskRaster.evaluate(center, width: 200, height: 100, source: MaskTestSource())!
        let across = (0..<200).filter { raster[$0, 50] > 0.5 }.count, down = (0..<100).filter { raster[100, $0] > 0.5 }.count
        XCTAssertEqual(Double(across) / 200, Double(down) / 100, accuracy: 0.03)
        // A broken aspect counts as square.
        XCTAssertEqual(MaskStack.defaultComponent(for: .center, aspect: .nan)?.kind, MaskStack.defaultComponent(for: .center, aspect: 1)?.kind)
    }
}
