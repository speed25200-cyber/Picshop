import XCTest
@testable import PicshopCore

final class ProjectSummaryTests: XCTestCase {
    private func photoProject(width: Double = 3000, height: Double = 4000) -> Project {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.jpg", pixelSize: PSSize(width: width, height: height))
        return Project(content: .photo(PhotoDocument(title: "Plage", baseImage: asset)))
    }

    private func videoProject() -> Project {
        let asset = MediaAsset(kind: .video, relativePath: "media/original.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 12, frameRate: 30)
        return Project(content: .video(VideoTimeline(title: "Vacances", asset: asset)))
    }

    private func pdfProject() -> Project {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.pdf", pixelSize: .zero)
        let model = PDFDocumentModel(title: "Facture", sourceAsset: asset, pageSizes: [PSSize(width: 595, height: 842), PSSize(width: 842, height: 595), PSSize(width: 595, height: 842)])
        return Project(id: model.id, content: .pdf(model))
    }

    private func makeStore() throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-summary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootURL: root), root)
    }

    func testPhotoSummary() {
        let project = photoProject()
        let summary = ProjectSummary(project: project)
        XCTAssertEqual(summary.id, project.id)
        XCTAssertEqual(summary.kind, .photo)
        XCTAssertEqual(summary.title, "Plage")
        XCTAssertEqual(summary.createdAt, project.createdAt)
        XCTAssertEqual(summary.modifiedAt, project.modifiedAt)
        XCTAssertNil(summary.duration)
        XCTAssertNil(summary.pageCount)
        XCTAssertEqual(summary.aspectRatio, 0.75, accuracy: 1e-9)
    }

    func testVideoSummary() {
        let summary = ProjectSummary(project: videoProject())
        XCTAssertEqual(summary.kind, .video)
        XCTAssertEqual(summary.title, "Vacances")
        XCTAssertEqual(summary.duration ?? 0, 12, accuracy: 1e-9)
        XCTAssertNil(summary.pageCount)
        XCTAssertEqual(summary.aspectRatio, 16.0 / 9.0, accuracy: 1e-9)
    }

    func testPDFSummaryUsesTheFirstPage() {
        let summary = ProjectSummary(project: pdfProject())
        XCTAssertEqual(summary.kind, .pdf)
        XCTAssertEqual(summary.pageCount, 3)
        XCTAssertNil(summary.duration)
        XCTAssertEqual(summary.aspectRatio, 595.0 / 842.0, accuracy: 1e-9)
    }

    func testDegenerateSizeFallsBackToSquare() {
        XCTAssertEqual(ProjectSummary(project: photoProject(width: 0, height: 0)).aspectRatio, 1)
    }

    func testSummaryCodableRoundTrip() throws {
        let summary = ProjectSummary(project: videoProject())
        let decoded = try JSONDecoder().decode(ProjectSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded, summary)
    }

    func testWriteSummaryAndListSummaries() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = photoProject()
        let pdf = pdfProject()
        try store.save(photo)
        try store.save(pdf)
        let summaries = store.listSummaries()
        XCTAssertEqual(Set(summaries.map(\.id)), [photo.id, pdf.id])
        XCTAssertEqual(summaries.map(\.modifiedAt), summaries.map(\.modifiedAt).sorted(by: >), "newest first")

        let summary = ProjectSummary(project: photo)
        try store.writeSummary(summary)
        let data = try Data(contentsOf: store.summaryURL(for: photo.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ProjectSummary.self, from: data).id, photo.id)
    }
    // MARK: Store: summaries next to the manifests

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func decodeSummary(at url: URL) throws -> ProjectSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectSummary.self, from: Data(contentsOf: url))
    }

    func testSaveWritesTheSummaryAfterTheManifest() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = videoProject()
        let returned = try store.saveWithSummary(project)
        let written = try decodeSummary(at: store.summaryURL(for: project.id))
        XCTAssertEqual(written, returned)
        XCTAssertEqual(written.modifiedAt, try store.load(id: project.id).modifiedAt, "the summary carries the saved date")
        XCTAssertEqual(store.listSummaries(), [returned], "what the save returns is what a reload reads")
        XCTAssertEqual(written.duration ?? 0, 12, accuracy: 1e-9)
    }

    func testListSummariesBackfillsAMissingSummary() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = photoProject()
        try store.save(project)
        try FileManager.default.removeItem(at: store.summaryURL(for: project.id))

        let summaries = store.listSummaries()
        XCTAssertEqual(summaries.map(\.id), [project.id])
        XCTAssertEqual(summaries.first?.title, "Plage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.summaryURL(for: project.id).path), "written back")
        XCTAssertEqual(try decodeSummary(at: store.summaryURL(for: project.id)).id, project.id)
    }

    func testAStaleSummaryIsRebuiltFromTheManifest() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = photoProject()
        try store.save(project)
        // Another path rewrites the manifest without the summary.
        project.content = .photo(PhotoDocument(title: "Montagne", baseImage: MediaAsset(kind: .image, relativePath: "media/original.jpg", pixelSize: PSSize(width: 4000, height: 2000))))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: store.manifestURL(for: project.id))
        try setModificationDate(Date().addingTimeInterval(60), of: store.manifestURL(for: project.id))

        let summary = try XCTUnwrap(store.listSummaries().first)
        XCTAssertEqual(summary.title, "Montagne")
        XCTAssertEqual(summary.aspectRatio, 2, accuracy: 1e-9)
        XCTAssertEqual(try decodeSummary(at: store.summaryURL(for: project.id)).title, "Montagne", "rewritten")
    }

    func testACurrentSummaryIsReadWithoutDecodingTheManifest() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = pdfProject()
        try store.save(project)
        // A manifest that cannot decode, older than its summary: never read.
        try Data("not json".utf8).write(to: store.manifestURL(for: project.id))
        try setModificationDate(Date().addingTimeInterval(-3600), of: store.manifestURL(for: project.id))

        let summaries = store.listSummaries()
        XCTAssertEqual(summaries.map(\.id), [project.id])
        XCTAssertEqual(summaries.first?.pageCount, 3)
    }

    func testADamagedManifestKeepsItsLastSummary() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = photoProject()
        try store.save(project)
        try Data("{".utf8).write(to: store.manifestURL(for: project.id))
        try setModificationDate(Date().addingTimeInterval(60), of: store.manifestURL(for: project.id))

        XCTAssertEqual(store.listSummaries().map(\.title), ["Plage"])
        XCTAssertThrowsError(try store.load(id: project.id))
    }

    func testPackagesWithNothingReadableAreSkipped() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.createPackage(for: UUID())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-uuid.picshop"), withIntermediateDirectories: true)
        let project = videoProject()
        try store.save(project)
        XCTAssertEqual(store.listSummaries().map(\.id), [project.id])
    }

    func testListSummariesIsNewestFirst() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = photoProject()
        let newer = videoProject()
        try store.save(older)
        try store.save(newer)
        var summary = try XCTUnwrap(store.summary(for: older.id))
        summary.modifiedAt = Date().addingTimeInterval(-86_400)
        try store.writeSummary(summary)
        XCTAssertEqual(store.listSummaries().map(\.id), [newer.id, older.id])
    }

    func testPrettyAndCompactManifestsBothDecode() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let compact = videoProject()
        try store.save(compact)
        let data = try Data(contentsOf: store.manifestURL(for: compact.id))
        XCTAssertFalse(data.contains(UInt8(ascii: "\n")), "manifests are written compact")
        XCTAssertEqual(try store.load(id: compact.id).title, "Vacances")

        // A manifest written by an earlier build: pretty and sorted.
        let pretty = photoProject()
        try store.createPackage(for: pretty.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pretty).write(to: store.manifestURL(for: pretty.id))
        let loaded = try store.load(id: pretty.id)
        XCTAssertEqual(loaded.id, pretty.id)
        XCTAssertEqual(loaded.photoDocument?.canvasSize, pretty.photoDocument?.canvasSize)
        XCTAssertEqual(Set(store.listSummaries().map(\.id)), [compact.id, pretty.id], "the earlier build's project is backfilled")
    }

    func testAspectRatioFollowsWhatTheCardShows() {
        XCTAssertEqual(ProjectSummary(project: photoProject(width: 4032, height: 3024)).aspectRatio, 4.0 / 3.0, accuracy: 1e-9)
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1080, height: 1920), duration: 5, frameRate: 30)
        XCTAssertEqual(ProjectSummary(project: Project(content: .video(VideoTimeline(title: "Story", asset: asset)))).aspectRatio, 9.0 / 16.0, accuracy: 1e-9)
    }
}
