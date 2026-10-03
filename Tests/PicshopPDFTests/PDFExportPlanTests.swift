import XCTest
@testable import PicshopPDF
import PicshopCore

/// The export plan is pure: these run on Linux too.
final class PDFExportPlanTests: XCTestCase {
    private func model(_ markups: [[PDFMarkup.Kind]]) -> PDFDocumentModel {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.pdf", pixelSize: .zero)
        var document = PDFDocumentModel(title: "Contrat", sourceAsset: asset, pageSizes: markups.map { _ in PSSize(width: 595, height: 842) })
        for (index, kinds) in markups.enumerated() {
            for kind in kinds { document.addMarkup(PDFMarkup(kind: kind), toPageAt: index) }
        }
        return document
    }

    private let box = PSRect(x: 0.2, y: 0.3, width: 0.1, height: 0.02)

    func testRedactedPagesAreRasterizedAndTheDocumentLosesItsMetadata() {
        let document = model([[.redaction(rects: [box])], [.highlight(rects: [box], color: .yellow)], []])
        let plan = PDFExportPlan.make(document, options: .defaults(for: document))
        XCTAssertEqual(plan.pages, [.rasterize(excluded: [box]), .keep, .keep])
        XCTAssertTrue(plan.stripsMetadata)
    }

    func testMarksPDFKitCannotWriteAreDrawnAndAplatirDrawsEveryMarkedPage() {
        let signature = MediaAsset(kind: .image, relativePath: "/sig.png", pixelSize: PSSize(width: 900, height: 300))
        let document = model([[.signature(signature, frame: box)], [.ink(strokes: [], color: .red, width: 0.004)], []])
        XCTAssertEqual(PDFExportPlan.make(document, options: PDFExportOptions()).pages, [.flatten, .keep, .keep])
        XCTAssertFalse(PDFExportPlan.make(document, options: PDFExportOptions()).stripsMetadata)
        XCTAssertEqual(PDFExportPlan.make(document, options: PDFExportOptions(flattenAnnotations: true)).pages, [.flatten, .flatten, .keep],
                       "'Aplatir' burns in every mark; an untouched page stays as it is")
    }

    func testReplacedWordsLeaveTheFileUnlessTheUserTurnsTheFlattenOff() {
        let element = TextElement(text: "Madame", fontName: "Helvetica", relativeSize: 0.014)
        let document = model([[.replacement(rects: [box], text: element, background: nil)], []])
        let defaults = PDFExportOptions.defaults(for: document)
        XCTAssertTrue(defaults.flattenModifiedPages, "on by default when words were replaced")
        XCTAssertEqual(PDFExportPlan.make(document, options: defaults).pages, [.rasterize(excluded: []), .keep])
        XCTAssertFalse(PDFExportPlan.keepsReplacedWords(document, options: defaults))
        let off = PDFExportOptions(flattenModifiedPages: false)
        XCTAssertEqual(PDFExportPlan.make(document, options: off).pages, [.flatten, .keep])
        XCTAssertTrue(PDFExportPlan.keepsReplacedWords(document, options: off), "the export warns: the old words stay in the file")
        XCTAssertFalse(PDFExportOptions.defaults(for: model([[]])).flattenModifiedPages)
    }

    func testOCRWordsUnderARedactionNeverReachTheTextLayer() {
        XCTAssertFalse(PDFExportPlan.keeps(PSRect(x: 0.21, y: 0.305, width: 0.05, height: 0.01), excluded: [box]))
        XCTAssertFalse(PDFExportPlan.keeps(PSRect(x: 0.15, y: 0.3, width: 0.06, height: 0.02), excluded: [box]), "a word half under the box goes too")
        XCTAssertTrue(PDFExportPlan.keeps(PSRect(x: 0.5, y: 0.3, width: 0.1, height: 0.02), excluded: [box]))
        XCTAssertTrue(PDFExportPlan.keeps(PSRect(x: 0.5, y: 0.3, width: 0.1, height: 0.02), excluded: []))
    }

    func testRasterSizeIs300DpiCapped() {
        let a4 = PDFExportPlan.rasterPixels(for: PSSize(width: 595, height: 842))
        XCTAssertEqual(a4.width, 2479, accuracy: 1)
        XCTAssertEqual(a4.height, 3508, accuracy: 1)
        let poster = PDFExportPlan.rasterPixels(for: PSSize(width: 2384, height: 3370))
        XCTAssertEqual(max(poster.width, poster.height), PDFExportPlan.maxRasterSide)
    }

    func testOutlineLabelsNamingARedactedWordAreDropped() {
        XCTAssertTrue(PDFExportPlan.mentionsRedacted("Annexe : salaire de Dupont", redacted: ["dupont"]))
        XCTAssertTrue(PDFExportPlan.mentionsRedacted("Société Générale", redacted: ["societe generale"]))
        XCTAssertFalse(PDFExportPlan.mentionsRedacted("Sommaire", redacted: ["Dupont", " "]))
    }
}
