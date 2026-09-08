import XCTest
@testable import PicshopIntent
@testable import PicshopCore

struct FakePDFServices: PDFAIServices {
    var hits: [PDFTextHit] = []
    var signature: MediaAsset? = nil

    func findText(_ query: String, in document: PDFDocumentModel, pageIndex: Int?) async throws -> [PDFTextHit] {
        hits.filter { pageIndex == nil || $0.pageIndex == pageIndex }
    }

    func extractPage(_ pageIndex: Int, from document: PDFDocumentModel) async throws -> MediaAsset {
        MediaAsset(kind: .image, relativePath: "media/page.jpg", pixelSize: PSSize(width: 1200, height: 1600), origin: .generated)
    }

    func signatureAsset() async -> MediaAsset? { signature }
}

final class PDFGrammarTests: XCTestCase {
    let engine = RuleBasedIntentEngine()
    let context = IntentContext(mode: .pdf, pageCount: 6, currentPage: 3)

    private func first(_ utterance: String) -> EditIntent {
        engine.parse(utterance, context: context).intents.first ?? EditIntent(action: .unknown)
    }

    func testPageNavigation() {
        XCTAssertEqual(first("va à la page 5").action, .goToPage)
        XCTAssertEqual(first("va à la page 5").index, 5)
        XCTAssertEqual(first("next page").index, 4)
        XCTAssertEqual(first("page précédente").index, 2)
        XCTAssertEqual(first("dernière page").index, -1)
        XCTAssertEqual(first("go to the first page").index, 1)
    }

    func testPageManagement() {
        let delete = first("supprime la page 3")
        XCTAssertEqual(delete.action, .deletePage)
        XCTAssertEqual(delete.index, 3)
        XCTAssertEqual(first("delete this page").action, .deletePage)
        XCTAssertNil(first("delete this page").index)
        let range = engine.parse("supprime les pages 2 à 4", context: context).intents
        XCTAssertEqual(range.map(\.index), [2, 3, 4])
        let rotate = first("tourne la page vers la gauche")
        XCTAssertEqual(rotate.action, .rotatePage)
        XCTAssertEqual(rotate.degrees, -90)
        XCTAssertEqual(first("rotate all pages").scope, .all)
        let move = first("déplace la page 4 au début")
        XCTAssertEqual(move.action, .movePage)
        XCTAssertEqual(move.index, 4)
        XCTAssertEqual(move.clipIndex, 1)
        XCTAssertEqual(first("move this page to the end").clipIndex, -1)
        XCTAssertEqual(first("duplique la page").action, .duplicatePage)
        XCTAssertEqual(first("insère une page blanche après").action, .insertBlankPage)
        XCTAssertEqual(first("ajoute des numéros de page").action, .addPageNumbers)
        XCTAssertEqual(first("fusionne avec un autre pdf").action, .mergeDocument)
        XCTAssertEqual(first("extrais la page 2 en photo").action, .extractPage)
        XCTAssertEqual(first("extrais la page 2 en photo").index, 2)
        let two = engine.parse("delete pages 2 and 5", context: context).intents
        XCTAssertEqual(two.map(\.index), [2, 5])
        let after = first("déplace cette page après la page 6")
        XCTAssertEqual(after.action, .movePage)
        XCTAssertEqual(after.clipIndex, 7)
        XCTAssertEqual(first("envoie la page 2 à la fin").action, .movePage)
        XCTAssertEqual(first("ajoute une page vide à la fin").action, .insertBlankPage)
        XCTAssertEqual(first("page 7").index, 7)
        XCTAssertEqual(first("insère une photo").action, .mergeDocument)
        XCTAssertEqual(first("insère une photo").text, "image")
        XCTAssertEqual(first("supprime la signature").text, "signature")
    }

    func testTextMarkup() {
        let highlight = first("surligne « montant total »")
        XCTAssertEqual(highlight.action, .highlightText)
        XCTAssertEqual(highlight.text, "montant total")
        let plain = first("highlight the word invoice")
        XCTAssertEqual(plain.text, "invoice")
        XCTAssertEqual(first("underline every occurrence of total").scope, .all)
        XCTAssertEqual(first("caviarde le nom").action, .redactText)
        XCTAssertEqual(first("cherche facture").action, .findText)
        XCTAssertEqual(first("cherche facture").text, "facture")
        XCTAssertEqual(first("trouve le mot signature").action, .findText)
        let green = first("surligne en vert le mot total")
        XCTAssertEqual(green.text, "total")
        XCTAssertEqual(green.color, .green)
        XCTAssertEqual(first("signe en bas à droite").action, .addSignature)
        XCTAssertEqual(first("signe en bas à droite").placement, .bottomTrailing)
        XCTAssertEqual(first("add my signature").action, .addSignature)
        let text = first("ajoute le texte « Approuvé » en haut")
        XCTAssertEqual(text.action, .addText)
        XCTAssertEqual(text.text, "Approuvé")
        XCTAssertEqual(first("annule").action, .undo)
        XCTAssertEqual(first("exporte").action, .export)
    }
}

final class PDFExecutorTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    func makeDocument() -> PDFDocumentModel {
        PDFDocumentModel(title: "Doc", sourceAsset: MediaAsset(kind: .image, relativePath: "media/original.pdf", pixelSize: .zero), pageSizes: Array(repeating: PSSize(width: 595, height: 842), count: 5))
    }

    func testDeleteAndRotate() async {
        let executor = PDFCommandExecutor(services: FakePDFServices())
        var document = makeDocument()
        let context = IntentContext(mode: .pdf, pageCount: 5, currentPage: 1)
        let plan = engine.parse("supprime les pages 2 à 3 puis tourne la page", context: context)
        for intent in plan.intents.reversed() where intent.action == .deletePage {
            (document, _) = await executor.execute(intent, on: document, context: context)
        }
        XCTAssertEqual(document.pageCount, 3)
        let rotate = plan.intents.first { $0.action == .rotatePage }!
        let (rotated, result) = await executor.execute(rotate, on: document, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(rotated.pages[0].rotation, 90)
    }

    func testHighlightAddsMarkupAndFindNavigates() async {
        let hit = PDFTextHit(pageIndex: 2, rects: [PSRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02)], text: "Total")
        let executor = PDFCommandExecutor(services: FakePDFServices(hits: [hit]), language: .french)
        let document = makeDocument()
        let context = IntentContext(mode: .pdf, pageCount: 5, currentPage: 1)
        let highlight = engine.parse("surligne total partout", context: context).intents[0]
        let (updated, result) = await executor.execute(highlight, on: document, context: context)
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertEqual(updated.pages[2].markups.count, 1)
        let find = engine.parse("cherche total", context: context).intents[0]
        let (navigated, findResult) = await executor.execute(find, on: updated, context: context)
        XCTAssertEqual(navigated.currentPageIndex, 2)
        if case .info = findResult.outcome {} else { XCTFail("expected info") }
    }

    func testSignatureRequiresDrawing() async {
        let executor = PDFCommandExecutor(services: FakePDFServices())
        let (_, result) = await executor.execute(EditIntent(action: .addSignature), on: makeDocument(), context: .pdf)
        XCTAssertEqual(result.effects, [.message("signature")])
        let signed = PDFCommandExecutor(services: FakePDFServices(signature: MediaAsset(kind: .image, relativePath: "/sig.png", pixelSize: PSSize(width: 900, height: 300))))
        let (document, ok) = await signed.execute(EditIntent(action: .addSignature, placement: .bottomTrailing), on: makeDocument(), context: .pdf)
        XCTAssertTrue(ok.outcome.isSuccess)
        XCTAssertEqual(document.pages[0].markups.count, 1)
    }
}

final class GenerativeGrammarTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func first(_ utterance: String, context: IntentContext = .photo) -> EditIntent {
        engine.parse(utterance, context: context).intents.first ?? EditIntent(action: .unknown)
    }

    func testReplaceWithPrompt() {
        let sky = first("remplace le ciel par un coucher de soleil")
        XCTAssertEqual(sky.action, .generativeFill)
        XCTAssertEqual(sky.target?.label, "sky")
        XCTAssertEqual(sky.text, "un coucher de soleil")
        let car = first("turn the car into a boat")
        XCTAssertEqual(car.action, .generativeFill)
        XCTAssertEqual(car.target?.label, "car")
        XCTAssertEqual(car.text, "a boat")
    }

    func testRecolor() {
        let red = first("change the shirt to red")
        XCTAssertEqual(red.action, .recolor)
        XCTAssertEqual(red.color, .red)
        let voiture = first("rends la voiture bleue")
        XCTAssertEqual(voiture.action, .recolor)
        XCTAssertEqual(voiture.target?.label, "car")
        XCTAssertEqual(voiture.color, .blue)
        XCTAssertEqual(first("mets le fond en blanc").action, .replaceBackground)
    }

    func testAddObject() {
        var context = IntentContext.photo
        context.lastTapPoint = PSPoint(x: 0.5, y: 0.3)
        let hat = first("ajoute un chapeau sur la personne", context: context)
        XCTAssertEqual(hat.action, .generativeFill)
        XCTAssertEqual(hat.target?.label, "person")
        XCTAssertEqual(hat.text, "un chapeau")
        let dragon = first("génère un dragon", context: context)
        XCTAssertEqual(dragon.action, .generativeFill)
        XCTAssertEqual(dragon.target?.point, PSPoint(x: 0.5, y: 0.3))
        XCTAssertEqual(first("ajoute le texte bonjour").action, .addText, "text commands stay text")
        XCTAssertEqual(first("ajoute une vignette").action, .adjust)
    }
}
