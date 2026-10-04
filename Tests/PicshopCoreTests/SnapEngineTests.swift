import XCTest
@testable import PicshopCore

/// D10 smart guides: threshold and hysteresis, one guide per axis, the canvas winning ties, layer targets, thirds on
/// demand, the haptic once per engagement, edge and scale snapping, equal spacing.
final class SnapEngineTests: XCTestCase {
    private let threshold = PSSize(width: 0.005, height: 0.005)
    private let canvasOnly = SnapTargets(vertical: [SnapLine(value: 0, source: .canvasEdge), SnapLine(value: 0.5, source: .canvasCenter),
                                                    SnapLine(value: 1, source: .canvasEdge)],
                                         horizontal: [SnapLine(value: 0, source: .canvasEdge), SnapLine(value: 0.5, source: .canvasCenter),
                                                      SnapLine(value: 1, source: .canvasEdge)])

    /// A 0.2 × 0.1 box whose centre is at (x, y).
    private func box(centredAt x: Double, _ y: Double = 0.27) -> PSRect {
        PSRect(x: x - 0.1, y: y - 0.05, width: 0.2, height: 0.1)
    }

    func testSnapsToTheCanvasCentreWithinTheThresholdOnly() throws {
        let near = SnapEngine.snapMove(box(centredAt: 0.504), targets: canvasOnly, threshold: threshold, previous: [])
        XCTAssertEqual(near.offset.x, -0.004, accuracy: 1e-12)
        XCTAssertEqual(near.offset.y, 0)
        let guide = try XCTUnwrap(near.guides.first)
        XCTAssertEqual(guide.axis, .vertical)
        XCTAssertEqual(guide.line, SnapLine(value: 0.5, source: .canvasCenter))
        XCTAssertTrue(near.didSnapNewly)
        let far = SnapEngine.snapMove(box(centredAt: 0.506), targets: canvasOnly, threshold: threshold, previous: [])
        XCTAssertEqual(far.offset.x, 0)
        XCTAssertTrue(far.guides.isEmpty)
        XCTAssertFalse(far.didSnapNewly)
    }

    func testHysteresisReleasesAtOneAndAHalfTimesTheThreshold() {
        let engaged = SnapEngine.snapMove(box(centredAt: 0.503), targets: canvasOnly, threshold: threshold, previous: [])
        // 0.007 away: beyond the threshold, within 1.5 × it: held.
        let held = SnapEngine.snapMove(box(centredAt: 0.507), targets: canvasOnly, threshold: threshold, previous: engaged.guides)
        XCTAssertEqual(held.offset.x, -0.007, accuracy: 1e-12)
        XCTAssertEqual(held.guides, engaged.guides)
        XCTAssertFalse(held.didSnapNewly)
        // 0.008 away: released.
        let released = SnapEngine.snapMove(box(centredAt: 0.508), targets: canvasOnly, threshold: threshold, previous: held.guides)
        XCTAssertEqual(released.offset.x, 0)
        XCTAssertTrue(released.guides.isEmpty)
    }

    func testOneGuidePerAxisTheNearest() {
        // The box's left edge is 0.003 from the canvas edge and its centre 0.002 from the centre line.
        let wide = PSRect(x: 0.003, y: 0.4, width: 0.99, height: 0.1)
        let result = SnapEngine.snapMove(wide, targets: canvasOnly, threshold: threshold, previous: [])
        XCTAssertEqual(result.guides.filter { $0.axis == .vertical }.count, 1)
        XCTAssertEqual(result.guides.first?.line.source, .canvasCenter)
        XCTAssertEqual(result.offset.x, 0.002, accuracy: 1e-12)
        // Both axes at once.
        let corner = SnapEngine.snapMove(PSRect(x: 0.002, y: 0.997, width: 0.2, height: 0.1), targets: canvasOnly, threshold: threshold, previous: [])
        XCTAssertEqual(corner.guides.count, 2)
        XCTAssertEqual(corner.offset.x, -0.002, accuracy: 1e-12)
        XCTAssertEqual(corner.offset.y, 0.003, accuracy: 1e-12)
    }

    func testTheCanvasWinsATie() {
        let layer = UUID()
        var targets = canvasOnly
        targets.vertical.insert(SnapLine(value: 0.5, source: .layer(layer)), at: 0)
        let result = SnapEngine.snapMove(box(centredAt: 0.503), targets: targets, threshold: threshold, previous: [])
        XCTAssertEqual(result.guides.first?.line.source, .canvasCenter)
        // A nearer layer line wins over the canvas.
        targets.vertical.append(SnapLine(value: 0.502, source: .layer(layer)))
        XCTAssertEqual(SnapEngine.snapMove(box(centredAt: 0.503), targets: targets, threshold: threshold, previous: []).guides.first?.line.source,
                       .layer(layer))
    }

    func testLayerEdgesAndCentresAndThirdsOnlyWhenAsked() throws {
        var document = W3Documents.base(90, title: "snap")
        let cup = W3Documents.image(9002, "Tasse", transform: LayerTransform(center: PSPoint(x: 0.3, y: 0.6), scale: 0.5))
        let hidden = Layer(id: W3Documents.id(9003), name: "Caché", content: .image(W3Documents.logo), isVisible: false)
        let text = W3Documents.text(9004, "Titre", center: PSPoint(x: 0.7, y: 0.2))
        document.layers += [cup, hidden, text, Layer(name: "Couleur", content: .fill(.red))]
        let targets = SnapEngine.targets(in: document, excluding: [], contentSizes: [text.id: PSSize(width: 800, height: 200)], includeThirds: false)
        let box = LayerPlacement.bounds(for: cup, contentSize: W3Documents.cup.pixelSize, canvasSize: document.canvasSize, isBase: false)
        let cupLines = targets.vertical.filter { $0.source == .layer(cup.id) }.map(\.value)
        XCTAssertEqual(cupLines.count, 3)
        XCTAssertEqual(cupLines[0], box.minX, accuracy: 1e-12)
        XCTAssertEqual(cupLines[1], box.midX, accuracy: 1e-12)
        XCTAssertEqual(cupLines[2], box.maxX, accuracy: 1e-12)
        XCTAssertEqual(targets.horizontal.filter { $0.source == .layer(cup.id) }.count, 3)
        // The text is measured by the caller; hidden layers, fills and the base add nothing; no thirds.
        XCTAssertEqual(targets.vertical.filter { $0.source == .layer(text.id) }.map(\.value)[1], 0.7, accuracy: 1e-12)
        XCTAssertFalse(targets.vertical.contains { $0.source == .layer(hidden.id) })
        XCTAssertEqual(targets.vertical.count, 3 + 3 + 3)
        XCTAssertFalse(targets.vertical.contains { $0.source == .canvasThird })
        // The moving layer is excluded; thirds when asked.
        let moving = SnapEngine.targets(in: document, excluding: [cup.id], contentSizes: [:], includeThirds: true)
        XCTAssertFalse(moving.vertical.contains { $0.source == .layer(cup.id) })
        XCTAssertFalse(moving.vertical.contains { $0.source == .layer(text.id) }, "a text without its measure adds nothing")
        XCTAssertEqual(moving.vertical.filter { $0.source == .canvasThird }.map(\.value), [1.0 / 3, 2.0 / 3])
        XCTAssertEqual(moving.horizontal.filter { $0.source == .canvasThird }.count, 2)
        // A layer in a hidden group adds nothing.
        var grouped = document
        grouped.layers.append(Layer(id: W3Documents.id(9009), name: "Groupe 1", content: .group(LayerFolder()), isVisible: false))
        grouped.update(layerID: cup.id) { $0.parentID = W3Documents.id(9009) }
        grouped.normalizeLayerTree()
        XCTAssertFalse(SnapEngine.targets(in: grouped, excluding: [], contentSizes: [:], includeThirds: false).vertical.contains { $0.source == .layer(cup.id) })
    }

    func testDidSnapNewlyOncePerEngagement() {
        var previous: [SnapGuide] = []
        var haptics: [Bool] = []
        for centre in [0.52, 0.503, 0.502, 0.501, 0.52, 0.504, 0.5] {
            let result = SnapEngine.snapMove(box(centredAt: centre), targets: canvasOnly, threshold: threshold, previous: previous)
            haptics.append(result.didSnapNewly)
            previous = result.guides
        }
        XCTAssertEqual(haptics, [false, true, false, false, false, true, false])
    }

    func testEdgeAndScaleSnapping() {
        let edge = SnapEngine.snapEdge(0.997, axis: .vertical, targets: canvasOnly, threshold: 0.005, previous: [])
        XCTAssertEqual(edge.value, 1, accuracy: 1e-12)
        XCTAssertEqual(edge.guide?.line.source, .canvasEdge)
        let free = SnapEngine.snapEdge(0.9, axis: .horizontal, targets: canvasOnly, threshold: 0.005, previous: [])
        XCTAssertEqual(free.value, 0.9)
        XCTAssertNil(free.guide)
        XCTAssertEqual(SnapEngine.snapScale(1.012).scale, 1)
        XCTAssertTrue(SnapEngine.snapScale(0.99).snapped)
        XCTAssertFalse(SnapEngine.snapScale(1.02).snapped)
        XCTAssertEqual(SnapEngine.snapScale(1.02).scale, 1.02)
    }

    func testEqualSpacing() throws {
        // Two neighbours on the same row at 0.1…0.2 and 0.6…0.7; a 0.2-wide box near the middle.
        let left = PSRect(x: 0.1, y: 0.4, width: 0.1, height: 0.1), right = PSRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1)
        let between = SnapEngine.equalSpacing(PSRect(x: 0.302, y: 0.42, width: 0.2, height: 0.1), neighbours: [left, right], threshold: threshold)
        XCTAssertEqual(between.offset.x, -0.002, accuracy: 1e-12)
        XCTAssertEqual(between.offset.y, 0)
        XCTAssertEqual(between.guides.count, 2)
        XCTAssertTrue(between.guides.allSatisfy { $0.line.source == .spacing && $0.axis == .vertical })
        XCTAssertEqual(between.guides.map(\.line.value).sorted()[0], 0.25, accuracy: 1e-12)
        // The gap two neighbours on one side already have.
        let sameSide = SnapEngine.equalSpacing(PSRect(x: 0.703, y: 0.4, width: 0.1, height: 0.1),
                                               neighbours: [PSRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1), PSRect(x: 0.45, y: 0.4, width: 0.1, height: 0.1)],
                                               threshold: threshold)
        XCTAssertEqual(sameSide.offset.x, -0.003, accuracy: 1e-12)
        // Neighbours that do not overlap on the other axis do not count.
        let apart = SnapEngine.equalSpacing(PSRect(x: 0.302, y: 0.8, width: 0.2, height: 0.1), neighbours: [left, right], threshold: threshold)
        XCTAssertEqual(apart.offset.x, 0)
        XCTAssertTrue(apart.guides.isEmpty)
    }
}
