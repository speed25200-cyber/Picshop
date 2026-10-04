import XCTest
@testable import PicshopCore

/// D2's merge: an older build saved project.json after the last W3 save, so v1 is the truth, and v2-only state comes
/// back where the older build left a layer untouched. Both sides go through JSON, as the files do.
final class DocumentMergeTests: XCTestCase {
    /// The two files a W3 save writes, read back: the projection as a W2 build's struct and the lossless document.
    private func saved(_ document: PhotoDocument) throws -> (v1: W2Mirror.Document, v2: PhotoDocument) {
        let v1 = try W2Mirror.decode(try W3Documents.encoder().encode(DocumentCodec.v1Projection(of: document)))
        return (v1, try W3Documents.reloaded(document))
    }

    /// What this build reads back from project.json after the older build's edit.
    private func reread(_ mirror: W2Mirror.Document) throws -> PhotoDocument {
        try W3Documents.decoder().decode(PhotoDocument.self, from: try W2Mirror.encoder().encode(mirror))
    }

    private func merged(_ document: PhotoDocument, olderBuild edit: (inout W2Mirror.Document) -> Void) throws -> PhotoDocument {
        var files = try saved(document)
        edit(&files.v1)
        return DocumentCodec.merge(v1: try reread(files.v1), v2: files.v2)
    }

    func testNoChangeGivesTheV2Document() throws {
        for (name, document) in W3Documents.all {
            let result = try merged(document) { _ in }
            XCTAssertEqual(result, try W3Documents.reloaded(document), name)
        }
    }

    func testAnOpacityChangedByAnOlderBuildComesFromV1AndTheRestFromV2() throws {
        let document = W3Documents.everything
        let text = W3Documents.id(1005)
        let result = try merged(document) { v1 in
            v1.layers[v1.layers.firstIndex { $0.id == text }!].opacity = 0.3
        }
        XCTAssertEqual(result.layer(id: text)?.opacity, 0.3)
        let reloaded = try W3Documents.reloaded(document)
        for layer in reloaded.layers where layer.id != text {
            XCTAssertEqual(result.layer(id: layer.id), layer, layer.name)
        }
        XCTAssertEqual(result.retainedFields, reloaded.retainedFields)
        XCTAssertEqual(result.layers.map(\.id), reloaded.layers.map(\.id))
    }

    func testDeletingAGroupsOnlyChildDropsTheGroup() throws {
        let document = W3Documents.groupsPassThrough
        // The group 204 has a child image and a child adjustment; leave it one, then none.
        let result = try merged(document) { v1 in
            v1.layers.removeAll { $0.id == W3Documents.id(202) || $0.id == W3Documents.id(203) }
        }
        XCTAssertNil(result.layer(id: W3Documents.id(204)))
        XCTAssertTrue(result.isNormalizedLayerTree)
    }

    func testDeletingOneOfTwoChildrenKeepsTheGroupWithOne() throws {
        let document = W3Documents.groupsIsolated
        let result = try merged(document) { v1 in
            v1.layers.removeAll { $0.id == W3Documents.id(102) }
        }
        let group = try XCTUnwrap(result.layer(id: W3Documents.id(104)))
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(result.children(of: group.id).map(\.id), [W3Documents.id(103)])
        XCTAssertEqual(result.layer(id: W3Documents.id(103))?.maskStack, W3Documents.stack, "the untouched child is the v2 one")
    }

    func testALayerAnOlderBuildAddedIsKeptAtItsPlaceAndNumbered() throws {
        let document = W3Documents.everything
        let added = W2Mirror.Layer(id: W3Documents.id(1099), name: "Ajout", content: .text(TextElement(text: "Ajout")),
                                   transform: W2Mirror.Transform(center: PSPoint(x: 0.5, y: 0.5), scale: 1, rotation: 0,
                                                                 isFlippedHorizontally: false, isFlippedVertically: false),
                                   opacity: 1, blendMode: .normal, isVisible: true, isLocked: false, mask: nil, edits: EditStack(), group: nil)
        let result = try merged(document) { v1 in
            v1.layers.insert(added, at: 1)
        }
        let index = try XCTUnwrap(result.index(of: added.id))
        XCTAssertEqual(index, 1)
        let layer = try XCTUnwrap(result.layer(id: added.id))
        XCTAssertNil(layer.parentID)
        XCTAssertEqual(layer.refNumber, document.nextRefNumber(prefix: "l"))
        XCTAssertTrue(result.isNormalizedLayerTree)
    }

    func testAReorderByAnOlderBuildWinsAndGroupsStayValid() throws {
        let document = W3Documents.clipping
        // Swap the text (304) and the image under it (302) in v1.
        let result = try merged(document) { v1 in
            let a = v1.layers.firstIndex { $0.id == W3Documents.id(302) }!
            let b = v1.layers.firstIndex { $0.id == W3Documents.id(304) }!
            v1.layers.swapAt(a, b)
        }
        let order = result.layers.map(\.id)
        XCTAssertLessThan(order.firstIndex(of: W3Documents.id(304))!, order.firstIndex(of: W3Documents.id(302))!)
        XCTAssertTrue(result.isNormalizedLayerTree)
        // The group survived with its child directly below it.
        XCTAssertEqual(result.children(of: W3Documents.id(306)).map(\.id), [W3Documents.id(305)])
        XCTAssertEqual(result.index(of: W3Documents.id(305)).map { $0 + 1 }, result.index(of: W3Documents.id(306)))
    }

    func testALayerWithANewerContentSurvivesAW2StyleRewriteInPlaceAndInItsGroup() throws {
        let document = W3Documents.unsupportedAndRetained
        let newer = W3Documents.id(803)
        let result = try merged(document) { v1 in
            // The older build changed the base's opacity: project.json is rewritten.
            v1.layers[0].opacity = 0.9
        }
        let layer = try XCTUnwrap(result.layer(id: newer))
        guard case .unsupported = layer.content else { return XCTFail("the newer content is kept") }
        XCTAssertEqual(layer.parentID, W3Documents.id(804))
        let order = result.layers.map(\.id)
        XCTAssertEqual(order.firstIndex(of: newer).map { $0 + 1 }, order.firstIndex(of: W3Documents.id(804)))
        XCTAssertEqual(result.layers[0].opacity, 0.9)
        XCTAssertEqual(result.retainedFields, ["zGuides": "[0.25,0.75]"])
        XCTAssertEqual(result.layer(id: W3Documents.id(802))?.retainedFields, ["zStyles": #"{"dropShadow":{"opacity":0.5}}"#])
        XCTAssertEqual(result.layer(id: W3Documents.id(802))?.transform.retainedFields, ["zWarp": "[1,2,3]"])
    }

    func testDocumentFieldsComeFromV1() throws {
        let document = W3Documents.everything
        let result = try merged(document) { v1 in
            v1.title = "Renommé"
            v1.canvasSize = PSSize(width: 2000, height: 1500)
        }
        XCTAssertEqual(result.title, "Renommé")
        XCTAssertEqual(result.canvasSize, PSSize(width: 2000, height: 1500))
        XCTAssertEqual(result.formatVersion, 2)
    }
}
