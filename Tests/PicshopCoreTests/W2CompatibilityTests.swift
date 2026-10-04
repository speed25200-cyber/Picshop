import XCTest
@testable import PicshopCore

/// D2 through ProjectStore: project.json (the v1 projection) and document-v2.json (lossless), the load sources, a W2
/// build's rewrite merged back, a newer build's file never overwritten, a corrupt one ignored; every W1/W2 document
/// still loads and draws as before.
final class W2CompatibilityTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-w2compat-\(UUID().uuidString)")
        store = ProjectStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheStoreWritesBothFilesAndLoadsTheV2Document() throws {
        let document = W3Documents.everything
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.manifestURL(for: project.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.documentV2URL(for: project.id).path))
        // project.json is what a W2 build opens.
        let manifest = try Data(contentsOf: store.manifestURL(for: project.id))
        let w2 = try W2Mirror.decoder().decode(W2Mirror.Project.self, from: manifest)
        XCTAssertEqual(w2.document.formatVersion, 1)
        let header = try XCTUnwrap(store.documentV2Header(for: project.id))
        XCTAssertEqual(header.formatVersion, 2)
        XCTAssertEqual(header.v1Digest, DocumentCodec.digest(manifest))
        let (loaded, source) = try store.loadWithSource(id: project.id)
        XCTAssertEqual(source, .v2)
        XCTAssertEqual(loaded.photoDocument, try W3Documents.reloaded(document))
        // A v1-only document writes no document-v2.json.
        let plain = DocumentCodec.migrated(W2Documents.built()[0])
        try store.save(Project(id: plain.id, content: .photo(plain)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.documentV2URL(for: plain.id).path))
        XCTAssertEqual(try store.loadWithSource(id: plain.id).source, .v1)
    }

    func testAnOlderBuildsRewriteIsMerged() throws {
        let document = W3Documents.everything
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        // A W2 build opens project.json, changes the text's opacity and saves it its way.
        let url = store.manifestURL(for: project.id)
        var w2 = try W2Mirror.decoder().decode(W2Mirror.Project.self, from: try Data(contentsOf: url))
        let text = W3Documents.id(1005)
        let index = try XCTUnwrap(w2.document.layers.firstIndex { $0.id == text })
        w2.document.layers[index].opacity = 0.25
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(w2).write(to: url, options: .atomic)
        let (loaded, source) = try store.loadWithSource(id: project.id)
        XCTAssertEqual(source, .merged)
        let merged = try XCTUnwrap(loaded.photoDocument)
        XCTAssertEqual(merged.layer(id: text)?.opacity, 0.25)
        XCTAssertEqual(merged.layer(id: W3Documents.id(1006))?.isGroup, true, "the untouched group comes back")
        XCTAssertEqual(merged.layer(id: W3Documents.id(1002))?.maskStack, W3Documents.stack)
        // The merge saved again: both files agree.
        try store.save(loaded)
        XCTAssertEqual(try store.loadWithSource(id: project.id).source, .v2)
    }

    func testANewerBuildsFileIsReadAsV1AndNeverOverwritten() throws {
        let document = W3Documents.everything
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        // A format 3 envelope whose document is not a v2 document (a required key renamed).
        let newer = #"{"document":{"identifier":"x","formatVersion":3,"pages":[]},"format":"picshop.photo","formatVersion":3,"minorVersion":0,"#
            + #""v1Digest":"1-0000000000000000","writer":"PicShop 9.0 (900)"}"#
        let v2URL = store.documentV2URL(for: project.id)
        try Data(newer.utf8).write(to: v2URL)
        let (loaded, source) = try store.loadWithSource(id: project.id)
        XCTAssertEqual(source, .newerFormat)
        XCTAssertEqual(loaded.photoDocument?.layers.map(\.id), DocumentCodec.migrated(DocumentCodec.v1Projection(of: document)).layers.map(\.id))
        try store.save(loaded)
        XCTAssertEqual(try Data(contentsOf: v2URL), Data(newer.utf8), "the newer file's bytes are untouched")
        XCTAssertEqual(store.documentV2Header(for: project.id)?.formatVersion, 3)
    }

    func testACorruptDocumentV2LoadsV1() throws {
        let document = W3Documents.everything
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        try Data("{\"format\":\"picshop.photo\",\"formatVersion\":2,\"document\":{\"broken\":true}}".utf8).write(to: store.documentV2URL(for: project.id))
        XCTAssertEqual(try store.loadWithSource(id: project.id).source, .v1)
        try Data("not json".utf8).write(to: store.documentV2URL(for: project.id))
        XCTAssertEqual(try store.loadWithSource(id: project.id).source, .v1)
        try Data("{\"format\":\"other\",\"formatVersion\":2}".utf8).write(to: store.documentV2URL(for: project.id))
        XCTAssertEqual(try store.loadWithSource(id: project.id).source, .v1)
    }

    func testEveryW1AndW2DocumentLoadsAndDrawsTheSamePlan() throws {
        for document in try W2Documents.decoded() + W2Documents.built() {
            let project = Project(id: document.id, content: .photo(document))
            try store.save(project)
            let (loaded, source) = try store.loadWithSource(id: project.id)
            XCTAssertEqual(source, .v1)
            let migrated = try XCTUnwrap(loaded.photoDocument)
            // One node per visible layer, in order, adjustments as adjustments (W2's compositing).
            let plan = CompositePlan.make(migrated)
            XCTAssertEqual(plan.flatMap(\.layerIDs), document.layers.filter(\.isVisible).map(\.id))
            for node in plan {
                switch node {
                case .layer(let draw): XCTAssertFalse(migrated.layer(id: draw.layerID)?.isAdjustment ?? true)
                case .adjustment(let draw): XCTAssertTrue(migrated.layer(id: draw.layerID)?.isAdjustment ?? false)
                case .clippingGroup, .group: XCTFail("a W2 document has no groups and no clipping")
                }
            }
        }
    }
}
