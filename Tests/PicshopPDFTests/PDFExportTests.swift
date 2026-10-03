#if canImport(PDFKit) && canImport(Vision) && canImport(CoreText)
import XCTest
import PDFKit
import CoreText
@testable import PicshopPDF
import PicshopCore

/// W0 on the macOS runner: a redacted word cannot be extracted or found in the exported
/// file; the outline, links and metadata are kept when nothing is redacted; a password
/// fixture opens.
final class PDFExportTests: XCTestCase {
    private let pageSize = CGSize(width: 595, height: 842)

    /// Two pages of real text (Core Text into a PDF context), an outline, a link and an author.
    private func makeOriginal() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for line in ["Hello SECRET world", "Second page here"] {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let first = try XCTUnwrap(document.page(at: 0)), second = try XCTUnwrap(document.page(at: 1))
        let root = PDFOutline()
        for (index, (label, page)) in [("Intro", first), ("Suite", second)].enumerated() {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageSize.height))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 100, width: 120, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: pageSize.height))
        first.addAnnotation(link)
        document.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Jane Doe"]
        // Reopened from disk, as the editor reads it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString).pdf")
        XCTAssertTrue(document.write(to: url))
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func model(for original: PDFDocument, order: [Int] = [0, 1]) -> PDFDocumentModel {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.pdf", pixelSize: .zero)
        let pages = order.map { PDFPageModel(source: .original(index: $0), size: PSSize(width: 595, height: 842)) }
        return PDFDocumentModel(title: "Test", sourceAsset: asset, pages: pages)
    }

    private func export(_ model: PDFDocumentModel, original: PDFDocument, options: PDFExportOptions = PDFExportOptions()) throws -> PDFDocument {
        let plan = PDFExportPlan.make(model, options: options)
        var holders: [PDFDocument] = []
        var pages: [PDFAssembler.Page] = []
        for (index, pageModel) in model.pages.enumerated() {
            guard case .original(let source) = pageModel.source, let composed = original.page(at: source)?.copy() as? PDFPage else { continue }
            let holder = PDFDocument()
            holder.insert(composed, at: 0)
            holders.append(holder)
            pages.append(PDFAssembler.Page(index: index, composed: composed, kept: original.page(at: source)?.copy() as? PDFPage))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).pdf")
        try withExtendedLifetime(holders) { try PDFAssembler(model: model, original: original, plan: plan).write(pages, to: url) }
        return try XCTUnwrap(PDFDocument(url: url))
    }

    func testRedactedWordCannotBeFoundOrExtracted() throws {
        let original = try makeOriginal()
        let page = try XCTUnwrap(original.page(at: 0))
        let hit = try XCTUnwrap(original.findString("SECRET", withOptions: .caseInsensitive).first)
        let bounds = hit.bounds(for: page)
        let rect = PDFGeometry.baseNormalized(fromPagePoints: PSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                                              size: PSSize(width: 595, height: 842))
        var document = model(for: original)
        document.addMarkup(PDFMarkup(kind: .redaction(rects: [rect])), toPageAt: 0)

        let exported = try export(document, original: original, options: .defaults(for: document))
        XCTAssertEqual(exported.pageCount, 2)
        XCTAssertTrue(exported.findString("SECRET", withOptions: .caseInsensitive).isEmpty, "the redacted word must not be found")
        XCTAssertFalse((exported.string ?? "").localizedCaseInsensitiveContains("secret"), "nor extracted")
        XCTAssertTrue((exported.page(at: 0)?.string ?? "").localizedCaseInsensitiveContains("hello"), "the rest of the page is searchable again (OCR layer)")
        XCTAssertTrue((exported.page(at: 1)?.string ?? "").contains("Second"), "an untouched page keeps its own text")
        XCTAssertNil(exported.documentAttributes?[PDFDocumentAttribute.authorAttribute], "a redacted document leaves its metadata behind")
        XCTAssertEqual(exported.outlineRoot?.numberOfChildren, 2)
    }

    func testOutlineLinksAndMetadataAreKeptWithoutFlatten() throws {
        let original = try makeOriginal()
        let exported = try export(model(for: original), original: original)
        XCTAssertEqual(exported.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Jane Doe")
        let root = try XCTUnwrap(exported.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 1)?.label, "Suite")
        let target = try XCTUnwrap(root.child(at: 1)?.destination?.page)
        XCTAssertEqual(exported.index(for: target), 1)
        let links = (exported.page(at: 0)?.annotations ?? []).filter { ($0.type ?? "").contains("Link") }
        XCTAssertEqual(links.count, 1)
        let linked = try XCTUnwrap(links.first?.destination?.page)
        XCTAssertEqual(exported.index(for: linked), 1)
        XCTAssertTrue((exported.page(at: 0)?.string ?? "").contains("SECRET"), "nothing redacted: the text stays")
    }

    func testOutlineFollowsReorderedPages() throws {
        let original = try makeOriginal()
        let exported = try export(model(for: original, order: [1, 0]), original: original)
        let intro = try XCTUnwrap(exported.outlineRoot?.child(at: 0))
        XCTAssertEqual(intro.label, "Intro")
        XCTAssertEqual(intro.destination?.page.map { exported.index(for: $0) }, 1, "Intro was page 1; it is page 2 now")
    }

    func testPasswordFixtureOpens() throws {
        let original = try makeOriginal()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString).pdf")
        XCTAssertTrue(original.write(to: url, withOptions: [.userPasswordOption: "1234", .ownerPasswordOption: "owner-1234"]))
        let locked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(PDFProtection.unlock(locked, password: "0000"))
        XCTAssertTrue(PDFProtection.unlock(locked, password: "1234"))
        XCTAssertEqual(PDFProtection.pageSizes(of: locked).count, 2)
        XCTAssertTrue((locked.page(at: 1)?.string ?? "").contains("Second"))
    }
}
#endif
