import XCTest
@testable import PicshopCore

/// D11: the node trees of 15 documents (the ten W3 fixtures and five small layouts): isolated and pass-through
/// groups, clipping runs (a hidden base hiding its run, a hidden clipped layer skipped, an adjustment clipped, a group
/// as a base), adjustments inside and outside groups, an invalid base, newer contents skipped, a W2 document.
final class CompositePlanTests: XCTestCase {
    private typealias W3 = W3Documents

    private func draw(_ document: PhotoDocument, _ n: Int, groupChildren: [CompositeNode] = []) -> LayerDraw {
        var result = LayerDraw(document.layer(id: W3.id(n))!)
        result.groupChildren = groupChildren
        return result
    }

    private func layer(_ document: PhotoDocument, _ n: Int) -> CompositeNode { .layer(draw(document, n)) }
    private func adjustment(_ document: PhotoDocument, _ n: Int) -> CompositeNode { .adjustment(draw(document, n)) }

    func testTheTenFixtures() {
        var d = W3.groupsIsolated
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 101), .group(draw(d, 104), passThrough: false, children: [layer(d, 102), layer(d, 103)])])
        XCTAssertTrue(draw(d, 103).hasMask)
        XCTAssertEqual(draw(d, 104).blendMode, .multiply)

        d = W3.groupsPassThrough
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 201)], "a hidden group hides its children")
        d.update(layerID: W3.id(204)) { $0.isVisible = true }
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 201), .group(draw(d, 204), passThrough: true, children: [layer(d, 202), adjustment(d, 203)])])

        d = W3.clipping
        XCTAssertEqual(CompositePlan.make(d), [
            layer(d, 301),
            .clippingGroup(base: draw(d, 302), clipped: [layer(d, 303), layer(d, 304)]),
            .clippingGroup(base: draw(d, 306, groupChildren: [layer(d, 305)]), clipped: [layer(d, 307)]),
            adjustment(d, 308),
            layer(d, 309),
        ], "a group as a base; a layer clipped over an adjustment drawn unclipped")

        d = W3.fillAndLocks
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 401), layer(d, 402), layer(d, 403), layer(d, 404),
                                               .group(draw(d, 406), passThrough: true, children: [layer(d, 405)])])
        XCTAssertEqual(draw(d, 402).fillOpacity, 0.5)

        d = W3.gradientsAndAdjustments
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 501), layer(d, 502), layer(d, 503)] + (0..<7).map { adjustment(d, 510 + $0) })

        d = W3.layerMasks
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 601), layer(d, 602), layer(d, 603), layer(d, 604), layer(d, 605), layer(d, 606)],
                       "an empty group draws nothing")
        XCTAssertEqual([602, 603, 604, 605, 606].map { draw(d, $0).hasMask }, [true, true, false, true, true], "a disabled stack is no mask")

        d = W3.transforms
        XCTAssertEqual(CompositePlan.make(d), [701, 702, 703, 704, 705].map { layer(d, $0) })

        d = W3.unsupportedAndRetained
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 801), layer(d, 802)], "a newer content is skipped, its group then empty")

        d = W3.refsAndBundles
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 901), layer(d, 902), layer(d, 903),
                                               .group(draw(d, 920), passThrough: false, children: (0..<6).map { layer(d, 910 + $0) })])

        d = W3.everything
        // Normalised: the text was listed between the group's children and the group, so it sits below the group.
        XCTAssertEqual(CompositePlan.make(d), [
            layer(d, 1001),
            layer(d, 1005),
            .group(draw(d, 1006), passThrough: false, children: [.clippingGroup(base: draw(d, 1002), clipped: [layer(d, 1003)]), adjustment(d, 1004)]),
        ])
    }

    func testAHiddenBaseHidesItsRunAndAHiddenClippedLayerIsSkipped() {
        var d = W3.base(11, title: "hidden base")
        d.layers += [Layer(id: W3.id(1102), name: "A", content: .image(W3.cup), isVisible: false),
                     Layer(id: W3.id(1103), name: "B", content: .fill(.red), isClipped: true),
                     Layer(id: W3.id(1104), name: "C", content: .fill(.blue))]
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 1101), layer(d, 1104)])

        var e = W3.base(12, title: "hidden clipped")
        e.layers += [W3.image(1202, "A"), Layer(id: W3.id(1203), name: "B", content: .fill(.red), isVisible: false, isClipped: true),
                     Layer(id: W3.id(1204), name: "C", content: .fill(.blue), isClipped: true)]
        XCTAssertEqual(CompositePlan.make(e), [layer(e, 1201), .clippingGroup(base: draw(e, 1202), clipped: [layer(e, 1204)])])
        // Every clipped layer hidden: the base alone.
        e.update(layerID: W3.id(1204)) { $0.isVisible = false }
        XCTAssertEqual(CompositePlan.make(e), [layer(e, 1201), layer(e, 1202)])
    }

    func testAnAdjustmentClippedOntoALayerAndInsideAndOutsideGroups() {
        var d = W3.base(13, title: "adjustments")
        var inside = Layer(id: W3.id(1305), name: "Dedans", content: .adjustment(Adjustments([.contrast: 0.2])))
        inside.parentID = W3.id(1306)
        d.layers += [W3.image(1302, "A"), Layer(id: W3.id(1303), name: "Clip", content: .adjustment(.neutral), isClipped: true),
                     W3.text(1304, "T"), inside, Layer(id: W3.id(1306), name: "Groupe 1", content: .group(LayerFolder(passThrough: true))),
                     Layer(id: W3.id(1307), name: "Dehors", content: .adjustment(.neutral))]
        XCTAssertEqual(CompositePlan.make(d), [
            layer(d, 1301),
            .clippingGroup(base: draw(d, 1302), clipped: [adjustment(d, 1303)]),
            layer(d, 1304),
            .group(draw(d, 1306), passThrough: true, children: [adjustment(d, 1305)]),
            adjustment(d, 1307),
        ])
    }

    func testAnEmptyGroupWithAClippedRunDrawsNothingAndTheBaseClipsNothing() {
        var d = W3.base(14, title: "empty group")
        d.layers += [Layer(id: W3.id(1402), name: "Groupe 1", content: .group(LayerFolder())),
                     Layer(id: W3.id(1403), name: "Teinte", content: .fill(.red), isClipped: true),
                     W3.text(1404, "Haut")]
        XCTAssertEqual(CompositePlan.make(d), [layer(d, 1401), layer(d, 1404)])
        // The base photo is never clipped (normalised), and a lone clipped layer at the bottom of a group has no base.
        var e = W3.base(15, title: "lone")
        var child = Layer(id: W3.id(1502), name: "Seul", content: .fill(.red), isClipped: true)
        child.parentID = W3.id(1503)
        e.layers += [child, Layer(id: W3.id(1503), name: "Groupe 1", content: .group(LayerFolder(passThrough: false)))]
        XCTAssertEqual(CompositePlan.make(e), [layer(e, 1501), .group(draw(e, 1503), passThrough: false, children: [layer(e, 1502)])])
    }

    func testAW2DocumentIsOneNodePerVisibleLayer() throws {
        for document in try W2Documents.decoded() + W2Documents.built() {
            let plan = CompositePlan.make(DocumentCodec.migrated(document))
            XCTAssertEqual(plan.flatMap(\.layerIDs), document.layers.filter(\.isVisible).map(\.id))
            XCTAssertEqual(plan.count, document.layers.filter(\.isVisible).count)
        }
        XCTAssertEqual(CompositeNode.clippingGroup(base: LayerDraw(layerID: W3.id(1), opacity: 1, fillOpacity: 1, blendMode: .normal, hasMask: false,
                                                                   groupChildren: [.layer(LayerDraw(layerID: W3.id(2), opacity: 1, fillOpacity: 1,
                                                                                                    blendMode: .normal, hasMask: false))]),
                                                   clipped: [.layer(LayerDraw(layerID: W3.id(3), opacity: 1, fillOpacity: 1, blendMode: .normal, hasMask: false))])
            .layerIDs, [W3.id(2), W3.id(1), W3.id(3)])
    }
}
