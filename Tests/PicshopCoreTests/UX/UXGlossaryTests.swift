import XCTest
@testable import PicshopCore

/// The glossary (ux-spec §5.2): one meaning per word, no banned label, search by label and synonym.
final class UXGlossaryTests: XCTestCase {
    func testIDsAreUniqueAndNoFrenchWordHasTwoMeanings() {
        let ids = UXGlossary.terms.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids")
        var english: [String: String] = [:]
        for term in UXGlossary.terms {
            if let other = english[term.fr] {
                XCTFail("« \(term.fr) » means both “\(other)” and “\(term.en)”")
            }
            english[term.fr] = term.en
            XCTAssertFalse(term.fr.isEmpty, term.id)
            XCTAssertFalse(term.en.isEmpty, term.id)
        }
    }

    func testNoLabelIsBanned() {
        for term in UXGlossary.terms {
            for banned in UXGlossary.banned {
                XCTAssertNotEqual(UXGlossary.fold(term.fr), UXGlossary.fold(banned), "« \(term.fr) » is banned")
            }
        }
        // « Annuler » means cancel only; undo is « Annuler la modification » in full.
        XCTAssertEqual(UXGlossary.term("cancel")?.fr, "Annuler")
        XCTAssertEqual(UXGlossary.term("undo")?.fr, "Annuler la modification")
        XCTAssertEqual(UXGlossary.term("ok")?.fr, "OK")
        XCTAssertEqual(UXGlossary.term("before")?.fr, "Avant")
    }

    func testSearchFindsLabelsThenSynonymsIgnoringAccents() {
        let lumi = UXGlossary.matches("lumi").map(\.id)
        XCTAssertTrue(lumi.contains("light"))
        XCTAssertTrue(lumi.contains("brightness"))
        XCTAssertEqual(UXGlossary.matches("liquify").first?.id, "reshape")
        XCTAssertEqual(UXGlossary.matches("ETALONNAGE").first?.id, "colorGrading")
        XCTAssertTrue(UXGlossary.matches("  ").isEmpty)
    }

    func testTextFallsBackToTheIDAndPicksTheLanguage() {
        XCTAssertEqual(UXGlossary.text("crop", french: true), "Recadrer")
        XCTAssertEqual(UXGlossary.text("crop", french: false), "Crop")
        XCTAssertEqual(UXGlossary.text("missing.term", french: true), "missing.term")
    }
}
