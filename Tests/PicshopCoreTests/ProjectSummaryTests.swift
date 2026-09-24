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
}
