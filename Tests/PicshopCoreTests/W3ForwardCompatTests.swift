import XCTest
@testable import PicshopCore

/// D2 forward compatibility inside format 2: a 2.1 document (a newer minor version) with an extra key on the
/// document, on a layer and on a transform, and a new content case, opened and saved by this build, keeps all four.
final class W3ForwardCompatTests: XCTestCase {
    func testA21DocumentKeepsWhatThisBuildDoesNotKnow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-w3fwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        let document = W3Documents.groupsIsolated
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        // A newer build wrote 2.1: patch the lossless file as it would have.
        let url = store.documentV2URL(for: project.id)
        var envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        envelope["minorVersion"] = 1
        var body = try XCTUnwrap(envelope["document"] as? [String: Any])
        body["zArtboards"] = [["name": "A1", "w": 1080]]
        var layers = try XCTUnwrap(body["layers"] as? [[String: Any]])
        layers[1]["zStyle"] = ["stroke": ["width": 3]]
        var transform = try XCTUnwrap(layers[1]["transform"] as? [String: Any])
        transform["zWarp"] = ["mesh": [0, 1, 2]]
        layers[1]["transform"] = transform
        layers.append(["id": W3Documents.id(199).uuidString, "name": "Vecteur", "opacity": 1, "blendMode": "normal", "isVisible": true,
                       "isLocked": false, "edits": ["operations": []],
                       "transform": ["center": ["x": 0.5, "y": 0.5], "scale": 1, "rotation": 0, "isFlippedHorizontally": false, "isFlippedVertically": false],
                       "content": ["vectorShape": ["_0": ["path": "M0 0 L1 1", "source": "media/vector.svg"]]]])
        body["layers"] = layers
        envelope["document"] = body
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url, options: .atomic)

        let (loaded, source) = try store.loadWithSource(id: project.id)
        XCTAssertEqual(source, .v2)
        let opened = try XCTUnwrap(loaded.photoDocument)
        XCTAssertNotNil(opened.retainedFields["zArtboards"])
        let vector = try XCTUnwrap(opened.layer(id: W3Documents.id(199)))
        guard case .unsupported = vector.content else { return XCTFail("a new content case is kept as unsupported") }
        XCTAssertTrue(opened.referencedPaths.contains("media/vector.svg"))
        // Saved by this build.
        try store.save(loaded)
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let savedBody = try XCTUnwrap(saved["document"] as? [String: Any])
        XCTAssertNotNil(savedBody["zArtboards"])
        let savedLayers = try XCTUnwrap(savedBody["layers"] as? [[String: Any]])
        let styled = try XCTUnwrap(savedLayers.first { ($0["id"] as? String) == (layers[1]["id"] as? String) })
        XCTAssertNotNil(styled["zStyle"])
        XCTAssertNotNil((styled["transform"] as? [String: Any])?["zWarp"])
        let kept = try XCTUnwrap(savedLayers.first { ($0["id"] as? String) == W3Documents.id(199).uuidString })
        XCTAssertNotNil((kept["content"] as? [String: Any])?["vectorShape"])
        // And project.json, the projection, has none of them and still opens in a W2 build.
        let manifest = try Data(contentsOf: store.manifestURL(for: project.id))
        let w2 = try W2Mirror.decoder().decode(W2Mirror.Project.self, from: manifest)
        XCTAssertFalse(w2.document.layers.contains { $0.id == W3Documents.id(199) })
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("zArtboards"))
    }
}
