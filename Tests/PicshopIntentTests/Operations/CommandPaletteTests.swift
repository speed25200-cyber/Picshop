import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 (D16, §8.9): the Ask field's palette backend.
final class CommandPaletteTests: XCTestCase {
    func testCourbesOpensTheCurvesTool() {
        let matches = CommandPalette.matches("courbes", domain: .photo, language: .fr)
        XCTAssertEqual(matches.first?.target, .tool("curves"))
        XCTAssertEqual(matches.first?.title, "Courbes")
        XCTAssertGreaterThanOrEqual(matches.first?.score ?? 0, CommandPalette.threshold)
    }

    func testAPartialPhraseFindsTheReadyOperation() {
        let matches = CommandPalette.matches("inverse la sél", domain: .photo, language: .fr)
        guard case .operation(let call)? = matches.first?.target else { return XCTFail("\(matches)") }
        XCTAssertEqual(call.id, "selectionModify")
        XCTAssertEqual(call.args["invert"], .bool(true))
        XCTAssertEqual(matches.first?.title, "Inverser la sélection")
    }

    func testASentenceOrAQuestionSuggestsNothing() {
        XCTAssertFalse(CommandPalette.shouldSuggest("rends le ciel un peu plus bleu"))
        XCTAssertEqual(CommandPalette.matches("rends le ciel un peu plus bleu", domain: .photo, language: .fr), [])
        XCTAssertFalse(CommandPalette.shouldSuggest("pourquoi c'est sombre ?"))
        XCTAssertFalse(CommandPalette.shouldSuggest("un texte beaucoup trop long pour la palette"))
        XCTAssertFalse(CommandPalette.shouldSuggest("   "))
        XCTAssertTrue(CommandPalette.shouldSuggest("masques"))
    }

    func testMatchesAreFewRankedAndAboveTheThreshold() {
        for text in ["masq", "select", "niveaux", "calques", "lasso", "sélectionner le sujet", "deselect", "ciel"] {
            let matches = CommandPalette.matches(text, domain: .photo, language: .fr)
            XCTAssertLessThanOrEqual(matches.count, 3, text)
            XCTAssertEqual(matches.map(\.score), matches.map(\.score).sorted(by: >), text)
            XCTAssertTrue(matches.allSatisfy { $0.score >= CommandPalette.threshold }, text)
            XCTAssertEqual(Set(matches.map(\.id)).count, matches.count, text)
        }
        XCTAssertEqual(CommandPalette.matches("masq", domain: .photo, language: .fr).first?.target, .tool("masks"))
        XCTAssertEqual(CommandPalette.matches("niveaux", domain: .photo, language: .fr).first?.target, .tool("levels"))
        XCTAssertEqual(CommandPalette.matches("levels", domain: .photo, language: .en).first?.title, "Levels")
        guard case .operation(let call)? = CommandPalette.matches("sélectionner le sujet", domain: .photo, language: .fr).first?.target else {
            return XCTFail("select subject")
        }
        XCTAssertEqual(call.args["what"], "subject")
    }

    /// Every ready operation the palette offers validates as it is.
    func testReadyOperationsValidate() {
        for ready in CommandPalette.readyOperations {
            guard case .object(var object) = OperationArguments.json(OperationCall(ready.id, args: ready.args)) else { return XCTFail() }
            object["action"] = nil
            var problems: [String] = []
            XCTAssertNotNil(OperationArguments.validate(ready.id, object, domain: .photo, path: "step", problems: &problems), "\(ready.fr) \(problems)")
        }
    }

    func testVideoAndPDFOfferTheirPanels() {
        XCTAssertEqual(CommandPalette.matches("audio", domain: .video, language: .fr).first?.target, .tool("audio"))
        XCTAssertEqual(CommandPalette.matches("signature", domain: .pdf, language: .fr).first?.target, .tool("signature"))
        XCTAssertFalse(CommandPalette.matches("masques", domain: .video, language: .fr).contains { $0.target == .tool("masks") })
    }
}
