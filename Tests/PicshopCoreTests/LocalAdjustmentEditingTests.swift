import XCTest
@testable import PicshopCore

/// `PhotoDocument.applyLocalEdit(_:to:)`: the one path the UI and the voice handlers take to change a local
/// adjustment. In place, capped, idempotent, clamped.
final class LocalAdjustmentEditingTests: XCTestCase {
    private let raster = RasterRef(path: "masks/0A1B2C3D-0000-4000-8000-0000000000AA.png", origin: .sky, pixelWidth: 1536, pixelHeight: 1152)

    private func setUp(_ adjustment: LocalAdjustment) -> PhotoDocument {
        var document = PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000)))
        document.apply(.adjust(.contrast, value: 0.1))
        document.setLocalAdjustment(adjustment, label: "Mask: Ciel")
        document.apply(.adjust(.saturation, value: 0.1))
        return document
    }

    private func sky() -> LocalAdjustment {
        LocalAdjustment(region: .sky, stack: .single(MaskComponent(.raster(raster))), adjustments: Adjustments([.exposure: 0.3]))
    }

    func testEveryEditInPlace() throws {
        let adjustment = sky()
        var document = setUp(adjustment)
        let operation = document.baseLayer!.edits.operations[1]
        let linear = MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 1), end: PSPoint(x: 0.5, y: 0.5))))
        let edits: [LocalAdjustmentEdit] = [
            .addComponent(linear),
            .setComponentMode(linear.id, .subtract),
            .invertComponent(linear.id, true),
            .setComponentKind(linear.id, .radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2))),
            .setStack(feather: 0.4, expand: -0.2, density: 0.8, isInverted: true),
            .setDial(.temperature, 0.25),
            .setCurve(.sCurve(strength: 0.6)),
            .setMixer(ColorMixer(saturation: [0.2, 0, 0, 0, 0, 0, 0, 0])),
            .setGrade(ColorGrade(shadows: ColorWheel(hue: 40, amount: 0.2), midtones: ColorWheel(hue: 40, amount: 0.2), highlights: ColorWheel(hue: 40, amount: 0.2))),
            .setAmount(0.7),
            .setVisible(false),
            .rename("  Ciel du soir "),
            .removeComponent(linear.id),
        ]
        for edit in edits {
            XCTAssertTrue(document.applyLocalEdit(edit, to: adjustment.id), "\(edit)")
            // One operation per id, at the same place, with its id and label.
            let operations = document.baseLayer!.edits.operations
            XCTAssertEqual(operations.count, 3)
            XCTAssertEqual(operations[1].id, operation.id)
            XCTAssertEqual(operations[1].label, "Mask: Ciel")
        }
        let result = try XCTUnwrap(document.localAdjustment(id: adjustment.id))
        XCTAssertEqual(result.stack.components.map(\.id), [adjustment.stack.components[0].id])
        XCTAssertEqual(result.stack.feather, 0.4)
        XCTAssertEqual(result.stack.expand, -0.2)
        XCTAssertEqual(result.stack.density, 0.8)
        XCTAssertTrue(result.stack.isInverted)
        XCTAssertEqual(result.adjustments[.temperature], 0.25)
        XCTAssertEqual(result.adjustments[.exposure], 0.3)
        XCTAssertEqual(result.curve, .sCurve(strength: 0.6))
        XCTAssertNotNil(result.mixer)
        XCTAssertNotNil(result.grade)
        XCTAssertEqual(result.amount, 0.7)
        XCTAssertFalse(result.isVisible)
        XCTAssertEqual(result.name, "Ciel du soir")
        // The component edits happened in order before the removal.
        var replay = sky()
        replay.id = adjustment.id
        for edit in edits.prefix(4) { replay = try XCTUnwrap(replay.applying(edit)) }
        XCTAssertEqual(replay.stack.components[1].mode, .subtract)
        XCTAssertTrue(replay.stack.components[1].isInverted)
        guard case .radial = replay.stack.components[1].kind else { return XCTFail("the kind was not replaced") }
    }

    func testIdempotentSetsChangeNothing() {
        let adjustment = sky()
        var document = setUp(adjustment)
        XCTAssertTrue(document.applyLocalEdit(.setAmount(0.5), to: adjustment.id))
        let before = document
        document.modifiedAt = before.modifiedAt
        XCTAssertFalse(document.applyLocalEdit(.setAmount(0.5), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setDial(.exposure, 0.3), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setVisible(true), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.rename(nil), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.rename("   "), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setStack(feather: nil, expand: nil, density: nil, isInverted: nil), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setComponentMode(adjustment.stack.components[0].id, .add), to: adjustment.id))
        // Nothing changed: the same document, not even touched.
        XCTAssertEqual(document, before)
    }

    func testRefusals() {
        let adjustment = sky()
        var document = setUp(adjustment)
        let before = document
        // Vignette is never local; an unknown adjustment or component changes nothing; NaN is refused.
        XCTAssertFalse(document.applyLocalEdit(.setDial(.vignette, 0.5), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setAmount(0.5), to: UUID()))
        XCTAssertFalse(document.applyLocalEdit(.removeComponent(UUID()), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setComponentMode(UUID(), .intersect), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.invertComponent(UUID(), true), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setComponentKind(UUID(), .brush(BrushSpec())), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setDial(.exposure, .nan), to: adjustment.id))
        XCTAssertFalse(document.applyLocalEdit(.setAmount(.infinity), to: adjustment.id))
        XCTAssertEqual(document, before)
    }

    func testValuesAreClamped() {
        let adjustment = sky()
        var document = setUp(adjustment)
        document.applyLocalEdit(.setAmount(3), to: adjustment.id)
        document.applyLocalEdit(.setDial(.exposure, 9), to: adjustment.id)
        document.applyLocalEdit(.setStack(feather: -1, expand: 4, density: 2, isInverted: nil), to: adjustment.id)
        let result = document.localAdjustment(id: adjustment.id)!
        XCTAssertEqual(result.amount, 1)
        XCTAssertEqual(result.adjustments[.exposure], 1)
        XCTAssertEqual(result.stack.feather, 0)
        XCTAssertEqual(result.stack.expand, 1)
        XCTAssertEqual(result.stack.density, 1)
        var opaque = MaskComponent(.brush(BrushSpec()), opacity: 7)
        opaque.id = UUID()
        document.applyLocalEdit(.addComponent(opaque), to: adjustment.id)
        XCTAssertEqual(document.localAdjustment(id: adjustment.id)!.stack.components.last?.opacity, 1)
    }

    func testTwelveComponents() {
        let adjustment = sky()
        var document = setUp(adjustment)
        for _ in 1..<MaskStack.maxComponents {
            XCTAssertTrue(document.applyLocalEdit(.addComponent(MaskComponent(.brush(BrushSpec()))), to: adjustment.id))
        }
        XCTAssertEqual(document.localAdjustment(id: adjustment.id)?.stack.components.count, 12)
        XCTAssertFalse(document.applyLocalEdit(.addComponent(MaskComponent(.brush(BrushSpec()))), to: adjustment.id))
        XCTAssertEqual(document.localAdjustment(id: adjustment.id)?.stack.components.count, 12)
        // A component id already in the stack gets a fresh one, so ids stay unique.
        let existing = document.localAdjustment(id: adjustment.id)!.stack.components[0]
        XCTAssertTrue(document.applyLocalEdit(.removeComponent(existing.id), to: adjustment.id))
        let second = document.localAdjustment(id: adjustment.id)!.stack.components[0]
        XCTAssertTrue(document.applyLocalEdit(.addComponent(second), to: adjustment.id))
        let ids = document.localAdjustment(id: adjustment.id)!.stack.components.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDuplicateGivesFreshIDsAndSharesRasters() throws {
        let adjustment = sky()
        var document = setUp(adjustment)
        XCTAssertTrue(document.applyLocalEdit(.duplicate, to: adjustment.id))
        let all = document.localAdjustments
        XCTAssertEqual(all.count, 2)
        let copy = try XCTUnwrap(all.last)
        XCTAssertNotEqual(copy.id, adjustment.id)
        XCTAssertNotEqual(copy.stack.components[0].id, adjustment.stack.components[0].id)
        XCTAssertEqual(copy.stack.rasterRefs, adjustment.stack.rasterRefs)
        XCTAssertEqual(copy.adjustments, adjustment.adjustments)
        XCTAssertEqual(copy.region, .sky)
        // Appended after every other operation.
        guard case .localAdjust(let last) = document.baseLayer!.edits.operations.last!.kind else { return XCTFail() }
        XCTAssertEqual(last.id, copy.id)
        // The original is untouched.
        XCTAssertEqual(document.localAdjustment(id: adjustment.id), adjustment)
    }

    func testSixteenAdjustments() {
        let adjustment = sky()
        var document = setUp(adjustment)
        for _ in 1..<LocalAdjustment.maxPerLayer {
            XCTAssertTrue(document.applyLocalEdit(.duplicate, to: adjustment.id))
        }
        XCTAssertEqual(document.localAdjustments.count, 16)
        XCTAssertFalse(document.applyLocalEdit(.duplicate, to: adjustment.id))
        XCTAssertEqual(document.localAdjustments.count, 16)
        // Edits of existing ones still work at the cap.
        XCTAssertTrue(document.applyLocalEdit(.setAmount(0.2), to: adjustment.id))
    }

    func testTheBrushFlattenThreshold() {
        let stroke = BrushStroke(points: [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.2, y: 0.2)], radius: 0.02, flow: 0.8)
        XCTAssertFalse(BrushSpec(strokes: Array(repeating: stroke, count: BrushSpec.maxStrokes)).needsFlatten)
        XCTAssertTrue(BrushSpec(strokes: Array(repeating: stroke, count: BrushSpec.maxStrokes + 1)).needsFlatten)
        XCTAssertFalse(BrushSpec().needsFlatten)
        // Long gestures flatten sooner: the worst-case redraw is bounded by points too.
        let long = BrushStroke(points: (0..<1_001).map { PSPoint(x: Double($0) / 1_000, y: 0.5) }, radius: 0.02)
        XCTAssertFalse(BrushSpec(strokes: Array(repeating: long, count: 3)).needsFlatten)
        XCTAssertTrue(BrushSpec(strokes: Array(repeating: long, count: 4)).needsFlatten, "4,004 points")
        // Strokes land through setComponentKind (the brush gesture's path).
        let brush = MaskComponent(.brush(BrushSpec()))
        var adjustment = LocalAdjustment(stack: .single(brush), adjustments: Adjustments([.exposure: 0.2]))
        adjustment.id = UUID()
        var document = setUp(adjustment)
        XCTAssertTrue(document.applyLocalEdit(.setComponentKind(brush.id, .brush(BrushSpec(strokes: [stroke]))), to: adjustment.id))
        guard case .brush(let spec) = document.localAdjustment(id: adjustment.id)!.stack.components[0].kind else { return XCTFail() }
        XCTAssertEqual(spec.strokes, [stroke])
    }
}
