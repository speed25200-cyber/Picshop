import XCTest
@testable import PicshopCore

/// D10 align and distribute: each alignment against hand-computed boxes (to their union, or to the canvas for one),
/// distribution keeping the outer two, and position-locked layers left where they are.
final class LayerAlignmentTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func assertTranslations(_ result: [UUID: PSPoint], _ expected: [UUID: PSPoint], _ name: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(result.keys), Set(expected.keys), name, file: file, line: line)
        for (id, want) in expected {
            XCTAssertEqual(result[id]?.x ?? .nan, want.x, accuracy: 1e-12, "\(name) x", file: file, line: line)
            XCTAssertEqual(result[id]?.y ?? .nan, want.y, accuracy: 1e-12, "\(name) y", file: file, line: line)
        }
    }

    func testEachAlignmentToTheUnionOfTheBoxes() {
        let boxes = [a: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), b: PSRect(x: 0.4, y: 0.3, width: 0.1, height: 0.2),
                     c: PSRect(x: 0.7, y: 0.5, width: 0.2, height: 0.3)]
        // The union: x 0.1…0.9 (centre 0.5), y 0.1…0.8 (centre 0.45).
        let expected: [(LayerAlignment, [UUID: PSPoint])] = [
            (.left, [a: PSPoint(x: 0, y: 0), b: PSPoint(x: -0.3, y: 0), c: PSPoint(x: -0.6, y: 0)]),
            (.centerH, [a: PSPoint(x: 0.3, y: 0), b: PSPoint(x: 0.05, y: 0), c: PSPoint(x: -0.3, y: 0)]),
            (.right, [a: PSPoint(x: 0.6, y: 0), b: PSPoint(x: 0.4, y: 0), c: PSPoint(x: 0, y: 0)]),
            (.top, [a: PSPoint(x: 0, y: 0), b: PSPoint(x: 0, y: -0.2), c: PSPoint(x: 0, y: -0.4)]),
            (.centerV, [a: PSPoint(x: 0, y: 0.3), b: PSPoint(x: 0, y: 0.05), c: PSPoint(x: 0, y: -0.2)]),
            (.bottom, [a: PSPoint(x: 0, y: 0.6), b: PSPoint(x: 0, y: 0.3), c: PSPoint(x: 0, y: 0)]),
        ]
        for (alignment, translations) in expected {
            assertTranslations(LayerPlacement.alignment(alignment, boxes: boxes, canvas: false), translations, alignment.rawValue)
        }
    }

    func testOneLayerAlignsToTheCanvas() {
        let box = [d: PSRect(x: 0.2, y: 0.3, width: 0.2, height: 0.2)]
        let expected: [(LayerAlignment, PSPoint)] = [
            (.left, PSPoint(x: -0.2, y: 0)), (.centerH, PSPoint(x: 0.2, y: 0)), (.right, PSPoint(x: 0.6, y: 0)),
            (.top, PSPoint(x: 0, y: -0.3)), (.centerV, PSPoint(x: 0, y: 0.1)), (.bottom, PSPoint(x: 0, y: 0.5)),
        ]
        for (alignment, translation) in expected {
            assertTranslations(LayerPlacement.alignment(alignment, boxes: box, canvas: true), [d: translation], alignment.rawValue)
        }
        XCTAssertEqual(LayerPlacement.alignment(.left, boxes: [:], canvas: true), [:])
    }

    func testDistributionKeepsTheOuterTwoAndEqualisesTheGaps() {
        let boxes = [a: PSRect(x: 0, y: 0.4, width: 0.1, height: 0.1), b: PSRect(x: 0.15, y: 0.2, width: 0.2, height: 0.1),
                     c: PSRect(x: 0.5, y: 0.6, width: 0.05, height: 0.1), d: PSRect(x: 0.8, y: 0.4, width: 0.2, height: 0.1)]
        // Span 0.1…0.8 between the outer two, 0.25 of inner widths: three gaps of 0.15.
        let horizontal = LayerPlacement.alignment(.distributeH, boxes: boxes, canvas: false)
        assertTranslations(horizontal, [a: PSPoint(x: 0, y: 0), b: PSPoint(x: 0.1, y: 0), c: PSPoint(x: 0.1, y: 0), d: PSPoint(x: 0, y: 0)], "distributeH")
        // After the move every gap is equal.
        let moved = boxes.mapValues { $0 }.map { id, box in (id, PSRect(x: box.minX + horizontal[id]!.x, y: box.minY, width: box.width, height: box.height)) }
            .sorted { $0.1.minX < $1.1.minX }.map(\.1)
        let gaps = zip(moved, moved.dropFirst()).map { $1.minX - $0.maxX }
        XCTAssertTrue(gaps.allSatisfy { abs($0 - 0.15) < 1e-12 }, "\(gaps)")
        // Vertically: by centre, b (0.25), a and d (0.45), c (0.65): b and c fixed; a and d are inner.
        let vertical = LayerPlacement.alignment(.distributeV, boxes: boxes, canvas: false)
        XCTAssertEqual(vertical[b]?.y, 0)
        XCTAssertEqual(vertical[c]?.y, 0)
        XCTAssertTrue(vertical.values.allSatisfy { $0.x == 0 })
        // Fewer than three boxes: nothing moves.
        let two = LayerPlacement.alignment(.distributeH, boxes: [a: boxes[a]!, d: boxes[d]!], canvas: false)
        assertTranslations(two, [a: PSPoint(x: 0, y: 0), d: PSPoint(x: 0, y: 0)], "two boxes")
    }

    /// What the handler does: skip position-locked layers, align the rest to their union, one `.transform` each.
    private func align(_ alignment: LayerAlignment, _ ids: [UUID], in document: inout PhotoDocument) -> [UUID] {
        let movable = ids.filter { LayerLockPolicy.allows(.placement, on: $0, in: document) }
        var boxes: [UUID: PSRect] = [:]
        for id in movable {
            guard let layer = document.layer(id: id), let size = LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize) else { continue }
            boxes[id] = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        }
        for (id, delta) in LayerPlacement.alignment(alignment, boxes: boxes, canvas: movable.count == 1) {
            guard var transform = document.layer(id: id).map(LayerPlacement.effectiveTransform(of:)) else { continue }
            transform.center = PSPoint(x: transform.center.x + delta.x, y: transform.center.y + delta.y)
            document.applyLayerEdit(.transform(transform), to: id)
        }
        return ids.filter { !movable.contains($0) }
    }

    func testPositionLockedLayersAreSkipped() throws {
        var document = W3Documents.base(96, title: "align")
        let one = W3Documents.image(9602, "Un", W3Documents.logo, transform: LayerTransform(center: PSPoint(x: 0.3, y: 0.3), scale: 0.2))
        let two = W3Documents.image(9603, "Deux", W3Documents.cup, transform: LayerTransform(center: PSPoint(x: 0.6, y: 0.5), scale: 0.2))
        let locked = Layer(id: W3Documents.id(9604), name: "Fixe", content: .shape(ShapeElement(kind: .ellipse)),
                           transform: LayerTransform(center: PSPoint(x: 0.8, y: 0.7)), lockOptions: [.position])
        document.layers += [one, two, locked]
        let skipped = align(.left, [one.id, two.id, locked.id], in: &document)
        XCTAssertEqual(skipped, [locked.id])
        XCTAssertEqual(document.layer(id: locked.id)?.transform, locked.transform)
        func box(_ id: UUID) -> PSRect {
            let layer = document.layer(id: id)!
            return LayerPlacement.bounds(for: layer, contentSize: LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize)!,
                                         canvasSize: document.canvasSize, isBase: false)
        }
        XCTAssertEqual(box(one.id).minX, box(two.id).minX, accuracy: 1e-12)
        // And a direct transform on the locked layer is refused.
        XCTAssertEqual(document.applyLayerEdit(.transform(LayerTransform(center: PSPoint(x: 0.1, y: 0.1))), to: locked.id), .refused(.locked))
        // One movable layer aligns to the canvas.
        var single = document
        _ = align(.right, [two.id, locked.id], in: &single)
        let layer = try XCTUnwrap(single.layer(id: two.id))
        let size = try XCTUnwrap(LayerPlacement.contentSize(of: layer, canvasSize: single.canvasSize))
        XCTAssertEqual(LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: single.canvasSize, isBase: false).maxX, 1, accuracy: 1e-12)
    }
}
