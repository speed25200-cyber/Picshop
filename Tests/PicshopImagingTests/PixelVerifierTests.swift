import XCTest
import PicshopCore
import PicshopIntent
@testable import PicshopImaging

/// Act-then-verify, the pixel side: what OCR read, held against what the step wrote. Runs on Linux.
final class PixelVerifierTests: XCTestCase {
    func testReadingToleratesOCRSwapsInNumbers() {
        XCTAssertTrue(PixelVerifier.reads("1", as: "1"))
        XCTAssertTrue(PixelVerifier.reads("l", as: "1"))
        XCTAssertTrue(PixelVerifier.reads("|", as: "1"))
        XCTAssertTrue(PixelVerifier.reads("8O.9%", as: "80.9%"))
        XCTAssertTrue(PixelVerifier.reads("87.3", as: "87,3"))
        XCTAssertTrue(PixelVerifier.reads("90 %", as: "90%"))
        XCTAssertFalse(PixelVerifier.reads("7", as: "1"))
        XCTAssertFalse(PixelVerifier.reads("12", as: "1"), "a whole number, never a digit inside another")
        XCTAssertFalse(PixelVerifier.reads("", as: "1"))
    }

    func testReadingWordsFoldsCaseAndAccents() {
        XCTAssertTrue(PixelVerifier.reads("SOLDES D'ETE", as: "Soldes d'été"))
        XCTAssertTrue(PixelVerifier.reads("Total 2025 net", as: "total 2025"))
        XCTAssertFalse(PixelVerifier.reads("Totals", as: "Total"))
        XCTAssertFalse(PixelVerifier.reads("Sole", as: "S0le"), "letters are not swapped outside numbers")
        XCTAssertTrue(PixelVerifier.reads("anything", as: ""), "nothing expected is always read")
    }

    func testTextInARegionReadsInOrder() {
        let words = [
            TableGridBuilder.Word(text: "again", box: PSRect(x: 0.1, y: 0.3, width: 0.1, height: 0.04), line: 1),
            TableGridBuilder.Word(text: "world", box: PSRect(x: 0.3, y: 0.2, width: 0.1, height: 0.04), line: 0),
            TableGridBuilder.Word(text: "Hello", box: PSRect(x: 0.1, y: 0.2, width: 0.1, height: 0.04), line: 0),
            TableGridBuilder.Word(text: "outside", box: PSRect(x: 0.7, y: 0.7, width: 0.1, height: 0.04), line: 2),
        ]
        XCTAssertEqual(PixelVerifier.text(in: PSRect(x: 0, y: 0, width: 0.5, height: 0.5), of: words), "Hello world again")
        XCTAssertEqual(PixelVerifier.text(in: PSRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), of: words), "")
    }

    // MARK: Checks

    private let cell = PSRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05)

    private func present(_ text: String, tag: String = "r1c2") -> VerificationCheck {
        VerificationCheck(kind: .textPresent, region: cell, text: text, tag: tag, layerID: UUID())
    }

    private func read(_ text: String, in rect: PSRect? = nil) -> [TableGridBuilder.Word] {
        let box = rect ?? PSRect(x: 0.43, y: 0.41, width: 0.03, height: 0.03)
        return [TableGridBuilder.Word(text: text, box: box, line: 0)]
    }

    func testTextPresentPassesWhenReadAndFailsWithWhatWasRead() {
        let check = present("1")
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(words: read("l"))).outcome, .passed)
        let wrong = PixelVerifier.evaluate(check, observation: .init(words: read("7")))
        XCTAssertEqual(wrong.outcome, .failed)
        XCTAssertEqual(wrong.observed, "7")
        // A word outside the region is not read there.
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(words: read("1", in: PSRect(x: 0.8, y: 0.8, width: 0.03, height: 0.03)))).outcome, .unverified)
    }

    /// A text written over other words ("Brouillon" on the « Gemini 3.5 Pro » header) fails as a collision, even
    /// though the expected word is read; the expected words alone (split by OCR) never do. Cells keep the plain read.
    func testANewTextOverOtherWordsIsACollision() {
        let region = PSRect(x: 0.6, y: 0.05, width: 0.35, height: 0.1)
        let check = VerificationCheck(kind: .textPresent, region: region, text: "Brouillon", tag: "text", layerID: UUID())
        let words = [
            TableGridBuilder.Word(text: "Brouillon", box: PSRect(x: 0.7, y: 0.08, width: 0.1, height: 0.02), line: 0),
            TableGridBuilder.Word(text: "Gemini", box: PSRect(x: 0.66, y: 0.12, width: 0.08, height: 0.02), line: 1),
        ]
        let collided = PixelVerifier.evaluate(check, observation: .init(words: words))
        XCTAssertEqual(collided.outcome, .failed)
        XCTAssertEqual(collided.observed, "Gemini")
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(words: [words[0]])).outcome, .passed)
        let split = VerificationCheck(kind: .textPresent, region: region, text: "Jusqu'au 31 août", tag: "text", layerID: UUID())
        let parts = ["Jusqu'au", "31", "août"].enumerated().map { TableGridBuilder.Word(text: $0.element, box: PSRect(x: 0.62 + Double($0.offset) * 0.1, y: 0.08, width: 0.08, height: 0.02), line: 0) }
        XCTAssertEqual(PixelVerifier.evaluate(split, observation: .init(words: parts)).outcome, .passed, "its own words, split")
        // A table cell next to its neighbours: no collision rule.
        XCTAssertEqual(PixelVerifier.evaluate(present("1"), observation: .init(words: read("1") + read("x", in: PSRect(x: 0.46, y: 0.41, width: 0.02, height: 0.03)))).outcome, .passed)
    }

    func testSilentOCRLetsTheInkDecide() {
        let check = present("1")
        let structural = VerificationReport.Item(check: check, outcome: .passed, observed: "1")
        // Ink where the text should be: the layer is there, OCR skipped a lone glyph.
        var inked = SyntheticPicture(width: 100, height: 100)
        inked.fill(x: 44, y: 41, width: 3, height: 7, level: 0x1C)
        let seen = PixelVerifier.Observation(patch: PixelVerifier.GrayPatch(bytes: inked.gray, width: 100, height: 100))
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: seen, structural: structural).outcome, .passed)
        // Nothing drawn at all (white on white): missing, whatever the document says.
        let blank = PixelVerifier.Observation(patch: PixelVerifier.GrayPatch(bytes: SyntheticPicture(width: 100, height: 100).gray, width: 100, height: 100))
        let missing = PixelVerifier.evaluate(check, observation: blank, structural: structural)
        XCTAssertEqual(missing.outcome, .failed)
        XCTAssertNil(missing.observed)
        // No pixels at all: the document's word stands.
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(), structural: structural).outcome, .passed)
    }

    func testAPatchCoversOnlyItsRegion() {
        var picture = SyntheticPicture(width: 50, height: 50)
        picture.fill(x: 20, y: 20, width: 10, height: 10, level: 0)
        let patch = PixelVerifier.GrayPatch(bytes: picture.gray, width: 50, height: 50, region: PSRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(patch.inkCoverage(in: PSRect(x: 0.65, y: 0.65, width: 0.2, height: 0.2)) ?? 0, 0.25, accuracy: 0.03)
        XCTAssertEqual(patch.inkCoverage(in: PSRect(x: 0.55, y: 0.55, width: 0.1, height: 0.1)) ?? 1, 0, accuracy: 0.01)
        XCTAssertNil(patch.inkCoverage(in: PSRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)), "outside the patch")
    }

    func testTextAbsent() {
        let old = VerificationCheck(kind: .textAbsent, region: cell, text: "Total", tag: "t3")
        XCTAssertEqual(PixelVerifier.evaluate(old, observation: .init(words: read("TOTAL"))).outcome, .failed)
        XCTAssertEqual(PixelVerifier.evaluate(old, observation: .init(words: read("Totals"))).outcome, .passed)
        XCTAssertEqual(PixelVerifier.evaluate(old, observation: .init()).outcome, .passed)
        let any = VerificationCheck(kind: .textAbsent, region: cell, tag: "area")
        let still = PixelVerifier.evaluate(any, observation: .init(words: read("x")))
        XCTAssertEqual(still.outcome, .failed)
        XCTAssertEqual(still.observed, "x")
    }

    func testObjectAbsent() {
        let dog = PSRect(x: 0.2, y: 0.3, width: 0.3, height: 0.3)
        let check = VerificationCheck(kind: .objectAbsent, region: dog, label: "dog", tag: "o1")
        let again = SceneMap.Object(id: "", label: "cat", box: PSRect(x: 0.22, y: 0.31, width: 0.27, height: 0.28), confidence: 0.7, kind: .animal)
        let elsewhere = SceneMap.Object(id: "", label: "dog", box: PSRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), confidence: 0.9, kind: .animal)
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(detections: [again])).outcome, .failed, "an animal still there")
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(detections: [elsewhere])).outcome, .passed)
        XCTAssertEqual(PixelVerifier.evaluate(check, observation: .init(objectsChecked: false)).outcome, .unverified)
        XCTAssertEqual(PixelVerifier.objectKind(of: "person"), .person)
        XCTAssertEqual(PixelVerifier.objectKind(of: "sign"), .object)
    }

    func testLongTextReadsWithAStrayWord() {
        XCTAssertTrue(PixelVerifier.readsMostOf("Rendez vous samedi a la plage de Nice", expected: "Rendez-vous samedi à la plage de Nice !"))
        XCTAssertFalse(PixelVerifier.readsMostOf("Rendez vous", expected: "Rendez-vous samedi à la plage de Nice"))
        XCTAssertFalse(PixelVerifier.readsMostOf("un deux", expected: "un deux"), "short texts must read exactly")
    }

    func testReportsKeepOrderAndSummariseFailures() {
        let first = VerificationRequest(intentID: UUID(), action: .fillCells, checks: [
            present("1", tag: "r1c1"), VerificationCheck(kind: .textPresent, region: PSRect(x: 0.6, y: 0.4, width: 0.1, height: 0.05), text: "1", tag: "r1c2"),
        ])
        let second = VerificationRequest(intentID: UUID(), action: .removeObject, checks: [
            VerificationCheck(kind: .objectAbsent, region: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), label: "person", tag: "person"),
        ])
        let words = read("1") + read("7", in: PSRect(x: 0.63, y: 0.41, width: 0.03, height: 0.03))
        let structural = [first, second].map { VerificationReport.unverified($0) }
        let reports = PixelVerifier.reports(for: [first, second], observation: .init(words: words), structural: structural)
        XCTAssertEqual(reports.map(\.intentID), [first.intentID, second.intentID])
        XCTAssertEqual(reports.map(\.method), [.pixels, .pixels])
        XCTAssertEqual(reports[0].status, .failed)
        XCTAssertEqual(reports[0].summary, "verify failed 1/2: r1c2 reads '7'")
        XCTAssertEqual(reports[1].status, .passed)
    }
}
