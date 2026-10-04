import XCTest
@testable import PicshopCore

/// D3: the v1 projection, always decodable by a W2 build (the frozen mirror), the identity on v1 documents, with the
/// documented folding; D2 migration and needsV2.
final class DocumentCodecTests: XCTestCase {
    private func projectedJSON(_ document: PhotoDocument) throws -> Data {
        try W3Documents.encoder().encode(DocumentCodec.v1Projection(of: document))
    }

    func testEveryW3DocumentProjectsToSomethingAW2BuildDecodes() throws {
        for (name, document) in W3Documents.all {
            let data = try projectedJSON(document)
            let mirror = try W2Mirror.decode(data)
            XCTAssertEqual(mirror.formatVersion, 1, name)
            // Only W1/W2 keys on the document, each layer, each transform and each content.
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], name)
            XCTAssertNil(body["zGuides"], name)
            for layer in try XCTUnwrap(body["layers"] as? [[String: Any]], name) {
                XCTAssertTrue(Set(layer.keys).isSubset(of: Layer.v1Keys), "\(name): \(layer.keys.sorted())")
                let transform = try XCTUnwrap(layer["transform"] as? [String: Any], name)
                XCTAssertTrue(Set(transform.keys).isSubset(of: ["center", "scale", "rotation", "isFlippedHorizontally", "isFlippedVertically"]),
                              "\(name): \(transform.keys.sorted())")
                let content = try XCTUnwrap(layer["content"] as? [String: Any], name)
                XCTAssertTrue(Set(content.keys).isSubset(of: ["image", "text", "shape", "adjustment", "fill"]), "\(name): \(content.keys.sorted())")
            }
            // Groups and newer contents are dropped; every other layer stays, in order.
            let kept = document.layers.filter { !$0.isGroup && !$0.content.isUnsupported }.map(\.id)
            XCTAssertEqual(mirror.layers.map(\.id), kept, name)
        }
    }

    func testAV1DocumentProjectsToItselfByteForByte() throws {
        for fixture in W2Documents.json {
            let decoded = try W2Documents.decoder().decode(PhotoDocument.self, from: Data(fixture.utf8))
            let migrated = DocumentCodec.migrated(decoded)
            XCTAssertEqual(migrated.formatVersion, 2)
            XCTAssertFalse(DocumentCodec.needsV2(migrated))
            XCTAssertEqual(String(decoding: try projectedJSON(migrated), as: UTF8.self), fixture)
        }
        for document in W2Documents.built() where !document.layers.contains(where: { $0.name == PhotoDocument.subjectLayerName }) {
            let original = try W2Documents.encoder().encode(document)
            XCTAssertEqual(try projectedJSON(DocumentCodec.migrated(document)), original)
        }
    }

    func testGroupOpacityAndVisibilityFoldIntoTheChildren() throws {
        let isolated = W3Documents.groupsIsolated
        let projected = DocumentCodec.v1Projection(of: isolated)
        XCTAssertNil(projected.layer(id: W3Documents.id(104)), "the group is dropped")
        XCTAssertEqual(projected.layer(id: W3Documents.id(102))?.opacity ?? 0, 0.8, accuracy: 1e-12)
        XCTAssertNil(projected.layer(id: W3Documents.id(102))?.parentID)
        let hidden = DocumentCodec.v1Projection(of: W3Documents.groupsPassThrough)
        XCTAssertEqual(hidden.layer(id: W3Documents.id(202))?.isVisible, false)
        XCTAssertEqual(hidden.layer(id: W3Documents.id(202))?.opacity ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(hidden.layer(id: W3Documents.id(203))?.isVisible, false)
    }

    func testFillFoldsIntoOpacityAndLocksClippingAndKindsGo() {
        let projected = DocumentCodec.v1Projection(of: W3Documents.fillAndLocks)
        let logo = projected.layer(id: W3Documents.id(402))
        XCTAssertEqual(logo?.opacity ?? 0, 0.45, accuracy: 1e-12)
        XCTAssertEqual(logo?.fillOpacity, 1)
        XCTAssertEqual(projected.layer(id: W3Documents.id(403))?.lockOptions, [])
        XCTAssertEqual(projected.layer(id: W3Documents.id(403))?.isLocked, false)
        // A locked group: its lock goes with it (isLocked is the group's own; children keep theirs).
        XCTAssertEqual(projected.layer(id: W3Documents.id(405))?.isLocked, false)
        let clipping = DocumentCodec.v1Projection(of: W3Documents.clipping)
        XCTAssertTrue(clipping.layers.allSatisfy { !$0.isClipped })
        let gradients = DocumentCodec.v1Projection(of: W3Documents.gradientsAndAdjustments)
        XCTAssertEqual(gradients.layer(id: W3Documents.id(502))?.content, .fill(.black), "a gradient becomes its first stop's colour")
        XCTAssertTrue(gradients.layers.allSatisfy { $0.recipeKind == nil && $0.refNumber == nil })
    }

    func testAPureRotationScaleQuadBecomesCentreScaleAndRotation() throws {
        var document = W3Documents.base(50, title: "quad")
        // The logo (800 × 400) at scale 0.5, turned 30°, written as a quad.
        let affine = LayerTransform(center: PSPoint(x: 0.45, y: 0.55), scale: 0.5, rotation: 30)
        var layer = W3Documents.image(5002, "Logo", W3Documents.logo, transform: affine)
        let size = W3Documents.logo.pixelSize
        let quad = LayerPlacement.quad(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        layer.transform = LayerTransform(quad: quad)
        document.layers.append(layer)
        let projected = try XCTUnwrap(DocumentCodec.v1Projection(of: document).layer(id: layer.id))
        XCTAssertEqual(projected.transform.center.x, 0.45, accuracy: 1e-6)
        XCTAssertEqual(projected.transform.center.y, 0.55, accuracy: 1e-6)
        XCTAssertEqual(projected.transform.scale, 0.5, accuracy: 1e-6)
        XCTAssertEqual(projected.transform.rotation, 30, accuracy: 1e-6)
        XCTAssertNil(projected.transform.quad)
        // Non-uniform scale folds into the uniform one.
        var wide = W3Documents.image(5003, "Large", transform: LayerTransform(scale: 0.5, scaleX: 2, scaleY: 0.5, skewX: 10))
        document.layers.append(wide)
        wide = try XCTUnwrap(DocumentCodec.v1Projection(of: document).layer(id: wide.id))
        XCTAssertEqual(wide.transform, LayerTransform(scale: 0.5))
    }

    func testALumiereLayerKeepsItsDialsInContentWhatAW2BuildDraws() throws {
        var document = W3Documents.base(51, title: "light")
        let light = Layer(id: W3Documents.id(5102), name: "Lumière", content: .adjustment(.neutral), recipeKind: .light)
        XCTAssertEqual(document.applyStructureEdit(.add(light, placement: .top)).outcome, .applied)
        let dials = Adjustments([.exposure: 0.3, .contrast: -0.1])
        XCTAssertEqual(document.applyLayerEdit(.adjustments(dials), to: light.id), .applied)
        let edited = try XCTUnwrap(document.layer(id: light.id))
        XCTAssertEqual(edited.content, .adjustment(dials))
        XCTAssertTrue(edited.edits.isEmpty)
        let projected = try XCTUnwrap(DocumentCodec.v1Projection(of: document).layer(id: light.id))
        XCTAssertEqual(projected.content, .adjustment(dials))
        let mirror = try W2Mirror.decode(try projectedJSON(document))
        XCTAssertEqual(mirror.layers.last?.content, .adjustment(dials))
    }

    func testABakedMaskIsProjectedOnlyWhenItsFileExistsAndIsFresh() throws {
        let document = W3Documents.layerMasks
        let bakedID = W3Documents.id(605)
        let baked = try XCTUnwrap(document.layer(id: bakedID)?.bakedMask)
        XCTAssertNil(DocumentCodec.v1Projection(of: document).layer(id: bakedID)?.mask)
        let present = DocumentCodec.v1Projection(of: document, maskFileExists: { $0 == baked.relativePath })
        XCTAssertEqual(present.layer(id: bakedID)?.mask, baked)
        // A stale bake (the stack changed since): dropped.
        var changed = document
        changed.update(layerID: bakedID) { $0.maskStack?.feather = 0.5 }
        XCTAssertNil(DocumentCodec.v1Projection(of: changed, maskFileExists: { _ in true }).layer(id: bakedID)?.mask)
        // A disabled mask is dropped, the legacy one kept.
        XCTAssertNil(present.layer(id: W3Documents.id(604))?.mask)
        XCTAssertNotNil(present.layer(id: W3Documents.id(606))?.mask)
        // Masks never reach v1 as a stack.
        XCTAssertTrue(present.layers.allSatisfy { $0.maskStack == nil && $0.isMaskLinked && $0.isMaskEnabled })
    }

    func testNeedsV2() throws {
        for (name, document) in W3Documents.all {
            XCTAssertTrue(DocumentCodec.needsV2(document), name)
        }
        for document in try W2Documents.decoded() + W2Documents.built() where !document.layers.contains(where: { $0.name == PhotoDocument.subjectLayerName }) {
            XCTAssertFalse(DocumentCodec.needsV2(DocumentCodec.migrated(document)))
        }
        // Ref numbers alone: only when they are no longer the positional ones.
        var numbered = DocumentCodec.migrated(W2Documents.built()[0])
        XCTAssertFalse(DocumentCodec.needsV2(numbered))
        numbered.layers.remove(at: 1)
        XCTAssertFalse(DocumentCodec.needsV2(numbered), "removing a text layer keeps the image layers positional")
        let logo = try XCTUnwrap(numbered.layers.last)
        numbered.layers.removeLast()
        numbered.layers.insert(Layer(name: "Second", content: .image(W3Documents.cup)), at: 1)
        numbered.layers.append(logo)
        numbered.assignMissingRefNumbers()
        XCTAssertTrue(DocumentCodec.needsV2(numbered), "the logo kept i1 but now sits above i2")
        // Retained document fields too.
        var retained = DocumentCodec.migrated(W2Documents.built()[0])
        retained.retainedFields = ["zGuides": "[]"]
        XCTAssertTrue(DocumentCodec.needsV2(retained))
    }

    func testMigrationIsIdempotentAndUnlocksTheSubjectToAPositionLock() throws {
        let subject = W2Documents.built()[2]
        let migrated = DocumentCodec.migrated(subject)
        let cutout = try XCTUnwrap(migrated.layers.first { $0.name == PhotoDocument.subjectLayerName })
        XCTAssertFalse(cutout.isLocked)
        XCTAssertEqual(cutout.lockOptions, [.position])
        XCTAssertEqual(DocumentCodec.migrated(migrated), migrated)
        XCTAssertEqual(migrated.formatVersion, 2)
        for (_, document) in W3Documents.all { XCTAssertEqual(DocumentCodec.migrated(document), document) }
        // The base photo is i0, the others numbered bottom → top per prefix.
        XCTAssertEqual(migrated.layers.map(\.refNumber), [0, 1, 1])
    }

    func testTheDigestIsTheByteCountAndFNV() {
        let data = Data("{\"a\":1}".utf8)
        XCTAssertEqual(DocumentCodec.digest(data), "7-" + StableHash.hex(bytes: data))
        XCTAssertNotEqual(DocumentCodec.digest(data), DocumentCodec.digest(Data("{\"a\":2}".utf8)))
    }
}
