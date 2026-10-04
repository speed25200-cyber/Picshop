#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// A 10-layer document: 2 groups (isolated and pass-through), 2 clipped layers, an adjustment layer, a gradient and 3
/// image layers over the photo, every mask optional (shared by the frame tests and the budget tests).
enum TenLayerDocument {
    struct Made {
        var document: PhotoDocument
        /// The image layer a placement drag moves (top level, normal).
        var movingID: UUID
        var imageIDs: [UUID]
    }

    /// A brush stack of `points` points (content space), for mask-heavy documents.
    static func brushStack(points: Int, seed: Double) -> MaskStack {
        let line = (0..<points).map { index -> PSPoint in
            let t = Double(index) / Double(max(1, points - 1))
            return PSPoint(x: 0.1 + 0.8 * t, y: 0.5 + 0.3 * sin(t * 9 + seed))
        }
        return MaskStack(components: [MaskComponent(.brush(BrushSpec(strokes: [BrushStroke(points: line, radius: 0.08, hardness: 0.7)])))])
    }

    static func make(_ fixture: LayerFixtures.Project, contentSide: Int = 96, brushPoints: Int? = nil) throws -> Made {
        var document = fixture.document
        let side = contentSide
        func image(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, name: String, centre: PSPoint, scale: Double = 1, rotation: Double = 0) throws -> Layer {
            let asset = try fixture.imageAsset(LayerFixtures.solid(r, g, b, alpha: alpha, width: side, height: side * 3 / 4), width: side, height: side * 3 / 4)
            var layer = Layer(name: name, content: .image(asset), transform: LayerTransform(center: centre, scale: scale, rotation: rotation))
            if let brushPoints { layer.maskStack = brushStack(points: brushPoints, seed: Double(document.layers.count)) }
            return layer
        }
        // 1–2: an isolated group with a multiply child.
        let isolated = Layer(name: "Groupe isolé", content: .group(LayerFolder(passThrough: false)), opacity: 0.9)
        var multiply = try image(0.8, 0.4, 0.2, name: "Multiplie", centre: PSPoint(x: 0.3, y: 0.35))
        multiply.blendMode = .multiply
        multiply.parentID = isolated.id
        document.layers += [multiply, isolated]
        // 3–4: a clip base and its clipped layer.
        let clipBase = try image(0.2, 0.6, 0.9, name: "Base de masque", centre: PSPoint(x: 0.6, y: 0.4), scale: 1.2, rotation: 10)
        var clipped = try image(0.95, 0.9, 0.3, alpha: 0.6, name: "Écrêté", centre: PSPoint(x: 0.55, y: 0.45), scale: 1.6)
        clipped.isClipped = true
        clipped.blendMode = .overlay
        document.layers += [clipBase, clipped]
        // 5: an adjustment layer.
        var edits = EditStack()
        edits.append(.toneCurve(ToneCurve(rgb: [ToneCurve.Point(0, 0.05), ToneCurve.Point(0.5, 0.55), ToneCurve.Point(1, 0.95)])))
        var adjustment = Layer(name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.1])), edits: edits, recipeKind: .light)
        adjustment.opacity = 0.8
        document.layers.append(adjustment)
        // 6: a gradient at half opacity.
        let gradient = GradientFill(style: .linear, stops: [GradientStop(location: 0, color: PSColor(red: 0.9, green: 0.3, blue: 0.2)),
                                                            GradientStop(location: 1, color: PSColor(red: 0.1, green: 0.3, blue: 0.9))],
                                    angle: 45, dither: false)
        var gradientLayer = Layer(name: "Dégradé", content: .gradientFill(gradient), opacity: 0.35)
        gradientLayer.blendMode = .softLight
        document.layers.append(gradientLayer)
        // 7–9: a pass-through group with an image layer and a second clip.
        let passThrough = Layer(name: "Groupe", content: .group(LayerFolder(passThrough: true)))
        var inGroup = try image(0.3, 0.8, 0.4, alpha: 0.7, name: "Dans le groupe", centre: PSPoint(x: 0.7, y: 0.7), rotation: -15)
        inGroup.parentID = passThrough.id
        var secondClip = try image(0.9, 0.2, 0.7, name: "Écrêté 2", centre: PSPoint(x: 0.7, y: 0.7), scale: 0.8)
        secondClip.isClipped = true
        secondClip.parentID = passThrough.id
        document.layers += [inGroup, secondClip, passThrough]
        // 10: the moving image layer, on top.
        let moving = try image(0.95, 0.95, 0.95, alpha: 0.8, name: "Dessus", centre: PSPoint(x: 0.4, y: 0.65), scale: 0.9, rotation: 20)
        document.layers.append(moving)
        return Made(document: document, movingID: moving.id, imageIDs: [multiply.id, clipBase.id, clipped.id, inGroup.id, secondClip.id, moving.id])
    }
}

/// D13 and D15 budgets on the CI VM (orders of magnitude; the device numbers are in §10): a settled 2048 frame of a
/// 10-layer document well under 2 s, an interactive snapshot frame well under 50 ms.
final class TenLayerFrameBudgetTests: XCTestCase {
    func testASettledFrameAndASnapshotFrameStayInBudget() async throws {
        // A 12 MP-like aspect at 4032 × 3024 would be slow to write in a test; 2400 × 1800 rendered at 2048 keeps the
        // same path (downsampled base, contents at their density).
        let width = 2400, height = 1800
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.7, 0.5, 0.4), (0.3, 0.6, 0.5), (0.5, 0.4, 0.7), (0.8, 0.8, 0.6)], width: width, height: height))
        defer { fixture.cleanup() }
        let made = try TenLayerDocument.make(fixture, contentSide: 800)
        XCTAssertEqual(made.document.layers.count, 11, "the photo and 10 layers")
        let options = PhotoRenderer.Options(targetLongestSide: 2048)
        // Warm: decode once (the first frame pays the file reads).
        _ = try await fixture.renderer.renderedRGBA(made.document, options: options)
        var moved = made.document
        moved.update(layerID: made.movingID) { $0.opacity = 0.6 }
        let start = Date()
        let settled = try await fixture.renderer.renderedRGBA(moved, options: options)
        let settledTime = Date().timeIntervalSince(start)
        XCTAssertEqual(max(settled.width, settled.height), 2048)
        XCTAssertLessThan(settledTime, 2, "a settled 2048 frame of 10 layers")

        let snapshot = try await fixture.renderer.interactiveSnapshot(made.document, scope: .layerPlacement(made.movingID),
                                                                      options: PhotoRenderer.Options(targetLongestSide: 1024))
        var buildTimes: [TimeInterval] = []
        var drawTimes: [TimeInterval] = []
        for step in 0..<10 {
            var dragged = made.document
            dragged.update(layerID: made.movingID) {
                $0.transform = LayerTransform(center: PSPoint(x: 0.4 + 0.02 * Double(step), y: 0.65), scale: 0.9, rotation: 20)
            }
            let frameStart = Date()
            guard let image = snapshot.frame(dragged) else { return XCTFail("no frame") }
            buildTimes.append(Date().timeIntervalSince(frameStart))
            // Drawn: the frame's pixels read back, as the canvas would draw them (a VM GPU, so only an order of magnitude).
            let drawStart = Date()
            let bytes = ImageSupport.rgbaBytes(of: image, rect: image.extent.integral)
            drawTimes.append(Date().timeIntervalSince(drawStart))
            XCTAssertNotNil(bytes)
        }
        let build = buildTimes.sorted()[buildTimes.count / 2]
        let draw = drawTimes.sorted()[drawTimes.count / 2]
        XCTAssertLessThan(build, 0.05, "an interactive frame's graph")
        XCTAssertLessThan(draw, 0.5, "an interactive frame drawn at 1024")
        print("TEN-LAYER settled \(Int(settledTime * 1000)) ms, snapshot frame \(Int(build * 1000)) ms built, \(Int(draw * 1000)) ms drawn")
    }
}
#endif
