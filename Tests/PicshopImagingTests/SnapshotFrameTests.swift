#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D13: a snapshot frame (graph construction off the actor) draws what the actor draws, for every scope; it never bakes
/// a cube on the calling thread; `covers` is cheap and strict; frames are cheap.
final class SnapshotFrameTests: XCTestCase {
    private let width = 160, height = 120
    private let options = PhotoRenderer.Options(targetLongestSide: 160)

    private func project() throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height,
                                  base: LayerFixtures.quadrants([(0.8, 0.3, 0.2), (0.25, 0.65, 0.35), (0.2, 0.3, 0.75), (0.85, 0.8, 0.3)], width: width, height: height))
    }

    private func imageLayer(_ fixture: LayerFixtures.Project, _ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, name: String,
                            centre: PSPoint, scale: Double = 1, rotation: Double = 0) throws -> Layer {
        let asset = try fixture.imageAsset(LayerFixtures.solid(r, g, b, alpha: alpha, width: 48, height: 36), width: 48, height: 36)
        return Layer(name: name, content: .image(asset), transform: LayerTransform(center: centre, scale: scale, rotation: rotation))
    }

    /// The frame against the actor's render of the same document: at most 0.2 % of the channels beyond `tolerance`
    /// (resampled edges), none beyond 4 × `tolerance`.
    @discardableResult
    private func assertFrameMatches(_ fixture: LayerFixtures.Project, _ snapshot: RenderSnapshot, _ document: PhotoDocument, tolerance: Int,
                                    _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        XCTAssertTrue(snapshot.covers(document), "\(label): covered", file: file, line: line)
        let frame: (bytes: [UInt8], width: Int, height: Int)? = {
            guard let image = snapshot.frame(document) else { return nil }
            let extent = image.extent.integral
            return ImageSupport.rgbaBytes(of: image, rect: extent).map { ($0, Int(extent.width), Int(extent.height)) }
        }()
        guard let frame else {
            XCTFail("\(label): no frame", file: file, line: line)
            return .max
        }
        let actor = try await fixture.renderer.renderedRGBA(document, options: options)
        XCTAssertEqual(frame.width, actor.width, label, file: file, line: line)
        XCTAssertEqual(frame.height, actor.height, label, file: file, line: line)
        guard frame.bytes.count == actor.bytes.count else { return .max }
        var worst = 0, beyond = 0
        for (a, b) in zip(frame.bytes, actor.bytes) {
            let difference = abs(Int(a) - Int(b))
            worst = max(worst, difference)
            if difference > tolerance { beyond += 1 }
        }
        XCTAssertLessThanOrEqual(Double(beyond) / Double(frame.bytes.count), 0.002, "\(label): \(beyond) channels beyond \(tolerance)/255 (worst \(worst))",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(worst, tolerance * 4, "\(label): worst \(worst)/255", file: file, line: line)
        return worst
    }

    // MARK: - Placement

    func testAPlacementFrameEqualsTheActorRenderFor20TransformsAndOpacities() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let below = try imageLayer(fixture, 0.2, 0.2, 0.9, alpha: 0.5, name: "Dessous", centre: PSPoint(x: 0.35, y: 0.4), scale: 1.5)
        let target = try imageLayer(fixture, 0.9, 0.5, 0.1, alpha: 0.8, name: "Cible", centre: PSPoint(x: 0.5, y: 0.5))
        var screen = try imageLayer(fixture, 0.3, 0.9, 0.6, name: "Écran", centre: PSPoint(x: 0.65, y: 0.55), scale: 1.2)
        screen.blendMode = .screen
        let top = try imageLayer(fixture, 0.95, 0.95, 0.95, alpha: 0.4, name: "Dessus", centre: PSPoint(x: 0.3, y: 0.7))
        document.layers += [below, target, screen, top]
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(target.id), options: options)
        var worst = 0
        for step in 0..<20 {
            let t = Double(step) / 19
            var moved = document
            moved.update(layerID: target.id) {
                $0.transform = LayerTransform(center: PSPoint(x: 0.2 + 0.6 * t, y: 0.3 + 0.4 * sin(t * 3)), scale: 0.6 + 0.9 * t, rotation: -40 + 80 * t,
                                              isFlippedHorizontally: step % 5 == 0)
                $0.opacity = 0.25 + 0.75 * t
                if step % 4 == 1 { $0.fillOpacity = 0.6 }
            }
            worst = max(worst, try await assertFrameMatches(fixture, snapshot, moved, tolerance: 2, "step \(step)"))
        }
        print("SNAPSHOT placement worst \(worst)/255")
    }

    func testCoversIsFalseAfterAChangeToAnotherLayer() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let target = try imageLayer(fixture, 0.9, 0.5, 0.1, name: "Cible", centre: PSPoint(x: 0.5, y: 0.5))
        let other = try imageLayer(fixture, 0.1, 0.5, 0.9, name: "Autre", centre: PSPoint(x: 0.3, y: 0.3))
        document.layers += [target, other]
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(target.id), options: options)
        XCTAssertTrue(snapshot.covers(document))
        var changed = document
        changed.update(layerID: other.id) { $0.opacity = 0.5 }
        XCTAssertFalse(snapshot.covers(changed), "another layer's opacity")
        XCTAssertNil(snapshot.frame(changed))
        var developed = document
        developed.update(layerID: target.id) { $0.edits.append(.adjust(.exposure, value: 0.5)) }
        XCTAssertFalse(snapshot.covers(developed), "the target's develop is not a placement field")
        var reordered = document
        reordered.layers.swapAt(1, 2)
        XCTAssertFalse(snapshot.covers(reordered), "the order")
        var background = document
        background.backgroundColor = PSColor(red: 0.1, green: 0.1, blue: 0.1)
        XCTAssertFalse(snapshot.covers(background), "the background")
        // A newer snapshot drops this one: its frames answer nil.
        _ = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(other.id), options: options)
        XCTAssertNil(snapshot.frame(document))
    }

    // MARK: - One case per scope

    func testALayerDevelopFrameWithALuminanceRangeAdjustmentStaysClose() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        let bright = MaskStack(components: [MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.45, high: 1)))])
        document.apply(.localAdjust(LocalAdjustment(stack: bright, adjustments: Adjustments([.exposure: 0.4]))), to: baseID)
        document.apply(.adjust(.contrast, value: 0.1), to: baseID)
        document.layers.append(try imageLayer(fixture, 0.2, 0.9, 0.3, alpha: 0.5, name: "Dessus", centre: PSPoint(x: 0.5, y: 0.5)))
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerDevelop(baseID), options: options)
        for exposure in [0.0, 0.02, 0.05, 0.1] {
            var dialled = document
            dialled.apply(.adjust(.exposure, value: exposure), to: baseID)
            // The local adjustment's mask is frozen at capture, so a small move stays within 4/255.
            try await assertFrameMatches(fixture, snapshot, dialled, tolerance: 4, "exposure \(exposure)")
        }
    }

    func testAnAdjustmentLayerFrame() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        var adjustment = Layer(name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.2])), recipeKind: .light)
        adjustment.maskStack = try fixture.stack(LayerFixtures.rampMask(width: width, height: height), width: width, height: height)
        document.layers += [try imageLayer(fixture, 0.5, 0.5, 0.5, name: "Gris", centre: PSPoint(x: 0.4, y: 0.4), scale: 1.4), adjustment]
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .adjustmentLayer(adjustment.id), options: options)
        for (exposure, opacity) in [(0.2, 1.0), (0.5, 1.0), (-0.4, 0.6), (0.8, 0.3)] {
            var dialled = document
            dialled.update(layerID: adjustment.id) {
                $0.content = .adjustment(Adjustments([.exposure: exposure]))
                $0.opacity = opacity
            }
            try await assertFrameMatches(fixture, snapshot, dialled, tolerance: 2, "exposure \(exposure), opacity \(opacity)")
        }
    }

    func testAFillLayerFrame() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        var fill = Layer(name: "Couleur", content: .fill(PSColor(red: 0.9, green: 0.2, blue: 0.4)), opacity: 0.7, blendMode: .multiply)
        fill.maskStack = try fixture.stack(LayerFixtures.halfMask(width: width, height: height), width: width, height: height)
        document.layers.append(fill)
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .fillLayer(fill.id), options: options)
        for (index, colour) in [PSColor(red: 0.2, green: 0.8, blue: 0.4), PSColor(red: 0.95, green: 0.9, blue: 0.1), PSColor(red: 0.1, green: 0.1, blue: 0.6)].enumerated() {
            var changed = document
            changed.update(layerID: fill.id) {
                $0.content = .fill(colour)
                $0.opacity = 0.4 + 0.2 * Double(index)
            }
            try await assertFrameMatches(fixture, snapshot, changed, tolerance: 2, "colour \(index)")
        }
    }

    func testALayerMaskFrameWithAStrokeAppended() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        var target = try imageLayer(fixture, 0.9, 0.85, 0.2, name: "Cible", centre: PSPoint(x: 0.5, y: 0.5), scale: 2, rotation: 15)
        let first = BrushStroke(points: (0...20).map { PSPoint(x: 0.1 + 0.04 * Double($0), y: 0.3) }, radius: 0.12, hardness: 0.8)
        target.maskStack = MaskStack(components: [MaskComponent(.brush(BrushSpec(strokes: [first])))])
        document.layers.append(target)
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerMask(target.id), options: options)
        var stroked = document
        for count in 1...3 {
            let stroke = BrushStroke(points: (0...20).map { PSPoint(x: 0.1 + 0.04 * Double($0), y: 0.3 + 0.2 * Double(count)) }, radius: 0.1, hardness: 0.8)
            stroked.update(layerID: target.id) { layer in
                guard var stack = layer.maskStack, case .brush(var spec) = stack.components[0].kind else { return }
                spec.strokes.append(stroke)
                stack.components[0].kind = .brush(spec)
                layer.maskStack = stack
            }
            try await assertFrameMatches(fixture, snapshot, stroked, tolerance: 3, "\(count) strokes appended")
        }
    }

    /// The layer-mask brush's frames carry their overlay from the `.layerMask` snapshot (no actor hop): the rubylith
    /// of the mask being painted, as the actor's render draws it; any other overlay is the actor's.
    func testALayerMaskSnapshotDrawsTheBrushOverlayAsTheActorDoes() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        var target = try imageLayer(fixture, 0.9, 0.85, 0.2, name: "Cible", centre: PSPoint(x: 0.5, y: 0.5), scale: 2, rotation: 15)
        let stroke = BrushStroke(points: (0...20).map { PSPoint(x: 0.1 + 0.04 * Double($0), y: 0.4) }, radius: 0.12, hardness: 0.8)
        target.maskStack = MaskStack(components: [MaskComponent(.brush(BrushSpec(strokes: [stroke])))])
        document.layers.append(target)
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerMask(target.id), options: options)
        XCTAssertNil(snapshot.frameAndOverlay(document, overlay: MaskOverlayRequest(target: .selection)), "another overlay: the actor's")
        let request = MaskOverlayRequest(target: .layerMask(target.id), style: .rubylith, opacity: 0.5)
        guard let drawn = snapshot.frameAndOverlay(document, overlay: request), let overlay = drawn.overlay else { return XCTFail("no overlay") }
        let extent = drawn.image.extent.integral
        guard let got = ImageSupport.rgbaBytes(of: overlay.composited(over: CIImage(color: .clear).cropped(to: extent)), rect: extent) else {
            return XCTFail("readback")
        }
        let actor = try await fixture.renderer.renderedRGBA(document, options: options, overlay: request)
        guard let want = actor.overlay else { return XCTFail("the actor's overlay") }
        XCTAssertEqual(got.count, want.count)
        guard got.count == want.count else { return }
        var worst = 0, beyond = 0
        for (a, b) in zip(got, want) {
            let difference = abs(Int(a) - Int(b))
            worst = max(worst, difference)
            if difference > 3 { beyond += 1 }
        }
        XCTAssertLessThanOrEqual(Double(beyond) / Double(got.count), 0.002, "\(beyond) channels beyond 3/255 (worst \(worst))")
        XCTAssertLessThanOrEqual(worst, 12, "worst \(worst)/255")
    }

    func testMovedGroupsAndAMovedClipBase() async throws {
        for passThrough in [false, true] {
            let fixture = try project()
            defer { fixture.cleanup() }
            var document = fixture.document
            let group = Layer(name: "Groupe", content: .group(LayerFolder(passThrough: passThrough)), opacity: passThrough ? 1 : 0.8)
            var multiply = try imageLayer(fixture, 0.9, 0.4, 0.3, name: "Multiplie", centre: PSPoint(x: 0.4, y: 0.4), scale: 1.3)
            multiply.blendMode = .multiply
            multiply.parentID = group.id
            var plain = try imageLayer(fixture, 0.3, 0.4, 0.9, alpha: 0.6, name: "Bleu", centre: PSPoint(x: 0.6, y: 0.6))
            plain.parentID = group.id
            document.layers += [multiply, plain, group, try imageLayer(fixture, 1, 1, 1, alpha: 0.3, name: "Voile", centre: PSPoint(x: 0.5, y: 0.5), scale: 2)]
            let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(group.id), options: options)
            for (index, centre) in [PSPoint(x: 0.5, y: 0.5), PSPoint(x: 0.6, y: 0.45), PSPoint(x: 0.35, y: 0.6)].enumerated() {
                var moved = document
                moved.update(layerID: group.id) { $0.transform = LayerTransform(center: centre, scale: 1 + 0.1 * Double(index), rotation: 8 * Double(index)) }
                try await assertFrameMatches(fixture, snapshot, moved, tolerance: 2, "\(passThrough ? "pass-through" : "isolated") group, move \(index)")
            }
        }
        // A clip base moved: its clipped layer stays, clipped by the base where it now is.
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let base = try imageLayer(fixture, 0.2, 0.7, 0.9, name: "Base", centre: PSPoint(x: 0.4, y: 0.5), scale: 1.5)
        var clipped = try imageLayer(fixture, 0.95, 0.85, 0.2, alpha: 0.7, name: "Écrêté", centre: PSPoint(x: 0.5, y: 0.5), scale: 3)
        clipped.isClipped = true
        clipped.blendMode = .overlay
        document.layers += [base, clipped]
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(base.id), options: options)
        for (index, centre) in [PSPoint(x: 0.6, y: 0.5), PSPoint(x: 0.3, y: 0.35)].enumerated() {
            var moved = document
            moved.update(layerID: base.id) { $0.transform = LayerTransform(center: centre, scale: 1.5, rotation: 20 * Double(index)) }
            try await assertFrameMatches(fixture, snapshot, moved, tolerance: 2, "clip base move \(index)")
        }
    }

    // MARK: - Never bakes on the calling thread

    func testAMixerDragNeverBakesOnTheCallingThread() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let cube = ColorCube()
        await fixture.renderer.setColorCube(cube)
        var document = fixture.document
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        document.apply(.colorMixer(ColorMixer(saturation: [0.3])), to: baseID)
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerDevelop(baseID), options: options)
        let atCapture = cube.bakeCounts.synchronous
        for step in 1...6 {
            var dragged = document
            dragged.apply(.colorMixer(ColorMixer(saturation: [0.3 + 0.1 * Double(step)], luminance: [0.02 * Double(step)])), to: baseID)
            guard let image = snapshot.frame(dragged) else { return XCTFail("no frame at step \(step)") }
            XCTAssertNotNil(ImageSupport.rgbaBytes(of: image, rect: image.extent.integral))
        }
        XCTAssertEqual(cube.bakeCounts.synchronous, atCapture, "frames never bake a cube on the calling thread")
        // The cube is baked on the utility queue meanwhile.
        let deadline = Date().addingTimeInterval(5)
        while cube.bakeCounts.background == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(cube.bakeCounts.background, 0)
    }

    // MARK: - Costs

    func testCoversAndFramesAreCheap() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let made = try TenLayerDocument.make(fixture, contentSide: 48, brushPoints: 500)
        let document = made.document
        let snapshot = try await fixture.renderer.interactiveSnapshot(document, scope: .layerPlacement(made.movingID), options: options)
        var moved = document
        moved.update(layerID: made.movingID) { $0.transform = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1, rotation: 5) }
        let coversStart = Date()
        var covered = 0
        for _ in 0..<1_000 where snapshot.covers(moved) { covered += 1 }
        let coversTime = Date().timeIntervalSince(coversStart)
        XCTAssertEqual(covered, 1_000)
        XCTAssertLessThan(coversTime, 0.1, "1,000 covers on 10 layers with 500-point brush masks")

        let framesStart = Date()
        var built = 0
        for step in 0..<100 {
            var dragged = document
            dragged.update(layerID: made.movingID) {
                $0.transform = LayerTransform(center: PSPoint(x: 0.3 + 0.004 * Double(step), y: 0.6), scale: 1, rotation: Double(step))
            }
            if snapshot.frame(dragged) != nil { built += 1 }
        }
        let framesTime = Date().timeIntervalSince(framesStart)
        XCTAssertEqual(built, 100)
        XCTAssertLessThan(framesTime, 2, "100 frames built")
        print("SNAPSHOT covers ×1000 \(Int(coversTime * 1000)) ms, 100 frames \(Int(framesTime * 1000)) ms")
        // And the last one draws what the actor draws.
        try await assertFrameMatches(fixture, snapshot, moved, tolerance: 3, "ten layers")
    }
}
#endif
