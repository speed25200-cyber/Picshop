import XCTest
@testable import PicshopCore

/// D17 storage: unreferenced old files under media/ and masks/ go; files referenced by the document or a history
/// document stay, so do files younger than 24 h and anything outside those two directories; paths inside retained
/// fields and unknown contents count as referenced.
final class ProjectGarbageTests: XCTestCase {
    func testOnlyUnreferencedOldMediaAndMasksGo() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("picshop-gc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        var document = W3Documents.unsupportedAndRetained
        document.retainedFields["zExtra"] = #"{"asset":"media/retained.png"}"#
        document.layers.append(Layer(id: W3Documents.id(899), name: "Futur", content: .unsupported(#"{"vector":{"_0":{"file":"masks/future.png"}}}"#)))
        var history = document
        history.layers.append(W3Documents.image(898, "Ancien", MediaAsset(kind: .image, relativePath: "media/history.png", pixelSize: PSSize(width: 10, height: 10))))
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        let old = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        func make(_ path: String, date: Date = old) throws {
            let url = store.url(for: path, in: project.id)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 100).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let kept = ["media/base.heic", "media/cup.png", "media/retained.png", "masks/future.png", "media/history.png", "media/x.psb"]
        for path in kept { try make(path) }
        try make("media/orphan.png")
        try make("masks/orphan-mask.png")
        try make("media/sub/orphan-deep.png")
        try make("media/fresh.png", date: Date(timeIntervalSinceNow: -3600))
        try make("other/untouched.png")
        let keeping = document.referencedPaths.union(history.referencedPaths)
        for path in ["media/base.heic", "media/cup.png", "media/retained.png", "masks/future.png", "media/history.png", "media/x.psb"] {
            XCTAssertTrue(keeping.contains(path), path)
        }
        let result = try store.collectGarbage(projectID: project.id, keeping: keeping)
        XCTAssertEqual(result.files, 3)
        XCTAssertEqual(result.bytes, 300)
        for path in kept + ["media/fresh.png", "other/untouched.png", Project.manifestName, Project.documentV2Name] {
            XCTAssertTrue(fm.fileExists(atPath: store.url(for: path, in: project.id).path), path)
        }
        for path in ["media/orphan.png", "masks/orphan-mask.png", "media/sub/orphan-deep.png"] {
            XCTAssertFalse(fm.fileExists(atPath: store.url(for: path, in: project.id).path), path)
        }
        // A second pass finds nothing; a later clock sweeps the fresh file too.
        XCTAssertEqual(try store.collectGarbage(projectID: project.id, keeping: keeping).files, 0)
        XCTAssertEqual(try store.collectGarbage(projectID: project.id, keeping: keeping, now: Date(timeIntervalSinceNow: 2 * 24 * 3600)).files, 1)
    }

    func testANewerBuildsDocumentKeepsItsFiles() throws {
        // D2: this build opens the v1 projection of a format-3 document-v2.json and never rewrites it; closing the
        // editor must not sweep the files only that newer file references.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("picshop-gc-newer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        let document = W3Documents.unsupportedAndRetained
        let project = Project(id: document.id, content: .photo(document))
        try store.save(project)
        let newer = #"{"format":"picshop.photo","formatVersion":3,"document":{"layers":[{"content":{"video":{"src":"media/x.png"}}},{"mask":"masks/newer.png"}]}}"#
        try Data(newer.utf8).write(to: store.documentV2URL(for: project.id))
        let old = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        for path in ["media/x.png", "masks/newer.png", "media/orphan.png"] {
            let url = store.url(for: path, in: project.id)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 10).write(to: url)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let loaded = try store.loadWithSource(id: project.id)
        XCTAssertEqual(loaded.source, .newerFormat)
        guard case .photo(let projection) = loaded.project.content else { return XCTFail("a photo project") }
        XCTAssertFalse(projection.referencedPaths.contains("media/x.png"))
        XCTAssertEqual(try store.collectGarbage(projectID: project.id, keeping: projection.referencedPaths).files, 1)
        XCTAssertEqual(try store.collectGarbage(projectID: project.id, keeping: []).files, 0, "project.json's own files stay too")
        for path in ["media/x.png", "masks/newer.png"] {
            XCTAssertTrue(fm.fileExists(atPath: store.url(for: path, in: project.id).path), path)
        }
        XCTAssertFalse(fm.fileExists(atPath: store.url(for: "media/orphan.png", in: project.id).path))
    }
}
