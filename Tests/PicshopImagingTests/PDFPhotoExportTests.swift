#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import CoreGraphics
import PicshopCore
@testable import PicshopImaging

/// Progress values reported from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// D16: a one-page PDF, its media box the picture at 300 ppi (pixels × 72 / 300), the title in the document info.
final class PDFPhotoExportTests: XCTestCase {
    func testOnePageAt300PPIWithTheTitle() async throws {
        let width = 600, height = 450
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.8, 0.2, 0.2), (0.2, 0.8, 0.2), (0.2, 0.2, 0.8), (0.9, 0.9, 0.2)], width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        document.title = "Vacances à Nice"
        let log = ProgressLog()
        let url = try await PhotoExporter.export(document, renderer: fixture.renderer, options: ExportOptions(format: .pdf, saveToPhotos: false),
                                                 progress: { value in log.append(value) })
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "pdf")
        guard let pdf = CGPDFDocument(url as CFURL) else { return XCTFail("not a PDF") }
        XCTAssertEqual(pdf.numberOfPages, 1)
        guard let page = pdf.page(at: 1) else { return XCTFail("no page") }
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, CGFloat(width) * 72 / 300, accuracy: 0.01)
        XCTAssertEqual(box.height, CGFloat(height) * 72 / 300, accuracy: 0.01)
        XCTAssertEqual(PDFPhotoWriter.mediaBox(width: width, height: height), CGRect(x: 0, y: 0, width: 144, height: 108))
        var title: CGPDFStringRef?
        guard let info = pdf.info, CGPDFDictionaryGetString(info, "Title", &title), let title,
              let text = CGPDFStringCopyTextString(title) as String? else { return XCTFail("no title in the document info") }
        XCTAssertEqual(text, "Vacances à Nice")
        let reported = log.values
        XCTAssertEqual(reported.last ?? 0, 1, accuracy: 1e-9, "progress ends at 1")
        XCTAssertEqual(reported, reported.sorted(), "progress never goes back")
    }
}
#endif
