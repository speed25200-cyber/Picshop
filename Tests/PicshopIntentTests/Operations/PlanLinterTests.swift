import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class PlanLinterTests: XCTestCase {
    private let crop = EditIntent(action: .crop, aspect: .square)
    private let warmer = EditIntent(action: .adjust, parameter: .temperature, amount: .relative(0.15))
    private let title = EditIntent(action: .addText, text: "Été")

    func testStepsSortByPhaseUnlessTheUserGaveAnOrder() {
        let sorted = PlanLinter.lint([title, warmer, crop], utterance: "un titre Été, plus chaud et recadre en carré").steps.map(\.action)
        XCTAssertEqual(sorted, [.crop, .adjust, .addText], "geometry, then tone, then text")
        let kept = PlanLinter.lint([title, warmer, crop], utterance: "ajoute le titre Été puis réchauffe, ensuite recadre").steps.map(\.action)
        XCTAssertEqual(kept, [.addText, .adjust, .crop], "puis / ensuite: the user's order")
        XCTAssertTrue(PlanLinter.saysOrder("first crop it, then add the title"))
        XCTAssertFalse(PlanLinter.saysOrder("recadre en carré et plus chaud"))
    }

    func testStepsThatNameAPlaceRunBeforeAGeometryChange() {
        let erase = EditIntent(action: .eraseRegion, ref: .text(3))
        let linted = PlanLinter.lint([crop, erase], utterance: "recadre et efface t3")
        XCTAssertEqual(linted.steps.map(\.action), [.eraseRegion, .crop], "t3 is read on the picture before the crop")
        let ordered = PlanLinter.lint([crop, erase], utterance: "recadre puis efface ce texte")
        XCTAssertEqual(ordered.steps.map(\.action), [.crop, .eraseRegion])
        XCTAssertFalse(ordered.notes.isEmpty, "the note says the place was read before the crop")
    }

    func testDuplicateSettingsMerge() {
        let more = EditIntent(action: .adjust, parameter: .temperature, amount: .relative(0.1))
        let merged = PlanLinter.lint([warmer, more], utterance: "plus chaud, encore plus chaud").steps
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.amount?.value ?? 0, 0.25, accuracy: 1e-9, "relative amounts add")
        let set = EditIntent(action: .adjust, parameter: .temperature, amount: .absolute(0.3))
        XCTAssertEqual(PlanLinter.lint([warmer, set], utterance: "x").steps.first?.amount, .absolute(0.3), "an absolute one wins")
        let blues = EditIntent(action: .operation, operation: OperationCall("hsl", args: ["band": .string("blue"), "saturation": .number(-20)]))
        let bluesLighter = EditIntent(action: .operation, operation: OperationCall("hsl", args: ["band": .string("blue"), "luminance": .number(10)]))
        let reds = EditIntent(action: .operation, operation: OperationCall("hsl", args: ["band": .string("red"), "saturation": .number(10)]))
        let calls = PlanLinter.lint([blues, bluesLighter, reds], utterance: "x").steps.compactMap(\.operation)
        XCTAssertEqual(calls.count, 2, "same band merged, another band kept")
        XCTAssertEqual(calls.first?.args["saturation"], .number(-20))
        XCTAssertEqual(calls.first?.args["luminance"], .number(10))
    }

    func testOnlyTheLaterBackgroundStepStays() {
        let cut = EditIntent(action: .removeBackground)
        let blur = EditIntent(action: .blurBackground, amount: .absolute(0.6))
        let linted = PlanLinter.lint([cut, blur], utterance: "détoure puis floute le fond")
        XCTAssertEqual(linted.steps.map(\.action), [.blurBackground])
        XCTAssertFalse(linted.notes.isEmpty)
    }

    func testASingleStepIsLeftAlone() {
        XCTAssertEqual(PlanLinter.lint([title], utterance: "x").steps, [title])
        XCTAssertTrue(PlanLinter.lint([title], utterance: "x").notes.isEmpty)
    }
}
