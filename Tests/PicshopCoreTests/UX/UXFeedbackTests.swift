import XCTest
@testable import PicshopCore

/// The feedback slot's order (ux-spec §4.7, AC-11), the panel session (§4.5) and the person-facing errors (§4.16).
final class UXFeedbackTests: XCTestCase {
    // MARK: FeedbackQueue

    func testTheHighestPriorityShowsAndTheRestWait() {
        var queue = FeedbackQueue<Int>()
        queue.post(1, kind: .receipt)
        XCTAssertEqual(queue.current?.id, 1)
        queue.post(2, kind: .job)
        XCTAssertEqual(queue.current?.id, 2)
        XCTAssertEqual(queue.waiting.map(\.id), [1])
        queue.post(3, kind: .error)
        XCTAssertEqual(queue.current?.id, 2)
        XCTAssertEqual(queue.waiting.map(\.id), [3, 1])
        XCTAssertTrue(queue.dismiss(2))
        XCTAssertEqual(queue.current?.id, 3)
        XCTAssertFalse(queue.dismiss(42))
    }

    func testAtMostThreeWaitAndTheLowestGoToTheConversation() {
        var queue = FeedbackQueue<Int>()
        queue.post(0, kind: .job)
        queue.post(1, kind: .notice)
        queue.post(2, kind: .reply)
        queue.post(3, kind: .receipt)
        let moved = queue.post(4, kind: .error)
        XCTAssertEqual(queue.waiting.map(\.id), [4, 3, 2])
        XCTAssertEqual(moved.map(\.id), [1])
    }

    func testAnUndoReceiptIsReplacedAndNeverQueuedForTheConversation() {
        var queue = FeedbackQueue<Int>()
        queue.post(1, kind: .undoReceipt)
        queue.post(2, kind: .undoReceipt)
        XCTAssertEqual(queue.all.map(\.id), [2])
        queue.post(3, kind: .receipt)
        XCTAssertEqual(queue.all.map(\.id), [3])
        queue.post(4, kind: .undoReceipt)
        queue.post(5, kind: .job)
        XCTAssertEqual(queue.current?.id, 5)
        XCTAssertEqual(queue.waiting.map(\.id), [3, 4])
    }

    func testStaleErrorsLeaveForTheConversationWhenSomethingNewStarts() {
        var queue = FeedbackQueue<Int>()
        queue.post(1, kind: .error)
        queue.post(2, kind: .clarification)
        queue.post(3, kind: .receipt)
        let moved = queue.userStartedAction()
        XCTAssertEqual(Set(moved.map(\.id)), [1, 2])
        XCTAssertEqual(queue.current?.id, 3)
        queue.post(4, kind: .job)
        XCTAssertEqual(queue.current?.id, 4, "a job shows at once, whatever was showing")
        XCTAssertFalse(queue.post(4, kind: .job).count > 0)
        queue.removeAll()
        XCTAssertNil(queue.current)
    }

    func testDurations() {
        XCTAssertEqual(FeedbackKind.receipt.duration(voiceOver: false), 6)
        XCTAssertEqual(FeedbackKind.receipt.duration(voiceOver: true), 12)
        XCTAssertEqual(FeedbackKind.undoReceipt.duration(voiceOver: false), 1.5)
        XCTAssertNil(FeedbackKind.error.duration(voiceOver: false))
        XCTAssertNil(FeedbackKind.job.duration(voiceOver: false))
        XCTAssertEqual(FeedbackKind.allCases.sorted().last, .job)
    }

    // MARK: PanelSessionLedger

    func testAnnulerPushesOneRestoringStepAndUndoBringsTheWorkBack() {
        var history = EditHistory(initial: 0)
        history.commit(1, label: "Avant")
        let ledger = PanelSessionLedger(toolID: "adjust.light", history: history)
        XCTAssertFalse(ledger.hasChanges(history))
        XCTAssertFalse(ledger.canUndoInside(history))
        history.commit(2, label: "Lumière")
        history.commit(3, label: "Lumière")
        XCTAssertTrue(ledger.hasChanges(history))
        XCTAssertTrue(ledger.canUndoInside(history))
        XCTAssertTrue(ledger.abandon(&history, label: "Modifications de Lumière abandonnées"))
        XCTAssertEqual(history.present, 1)
        XCTAssertEqual(history.count, 4, "history is never trimmed")
        XCTAssertEqual(history.undoLabel, "Modifications de Lumière abandonnées")
        history.undo()
        XCTAssertEqual(history.present, 3)
    }

    func testAnnulerWithoutChangesPushesNothing() {
        var history = EditHistory(initial: "a")
        let ledger = PanelSessionLedger(toolID: "crop.format", history: history)
        history.beginTransaction(label: "Recadrage")
        history.commit("b", label: "Recadrage")
        history.commit("a", label: "Recadrage")
        XCTAssertFalse(ledger.abandon(&history, label: "x"))
        XCTAssertEqual(history.count, 0)
    }

    // MARK: UserFacingError

    func testErrorsReadAsPeopleExpect() {
        XCTAssertEqual(UserFacingError(.generic).message(french: true), "Cette retouche n'a pas abouti.")
        XCTAssertEqual(UserFacingError(.generic).actions, [.retry, .close])
        let thermal = UserFacingError(.thermal)
        XCTAssertEqual(thermal.retryDelay, 30)
        XCTAssertEqual(thermal.retryTitle(secondsLeft: 30, french: true), "Réessayer dans 30\u{00A0}s")
        XCTAssertEqual(thermal.retryTitle(secondsLeft: 0, french: true), "Réessayer")
        XCTAssertEqual(UserFacingError(.noSpace(missingBytes: 1_200_000_000)).message(french: true),
                       "L'iPhone n'a plus assez d'espace\u{00A0}: il manque 1,2\u{00A0}Go.")
        XCTAssertEqual(UserFacingError.byteCount(850_000_000, french: false), "850 MB")
        XCTAssertEqual(UserFacingError.byteCount(2_000_000_000, french: true), "2\u{00A0}Go")
        XCTAssertTrue(UserFacingError(.cancelled).isSilent)
        for kind in [UserFacingError.Kind.generic, .thermal, .noSpace(missingBytes: nil), .iCloudUnavailable, .photosAccessDenied, .damagedProject,
                     .missingFeature(name: "Remplir avec l'IA", bytes: 1_900_000_000), .noMatch("chien"), .unsupported("changer la saison"),
                     .importFailed(reason: nil), .permissionDenied("au micro"), .pdfWithoutText] {
            let error = UserFacingError(kind)
            XCTAssertFalse(error.message(french: true).isEmpty)
            XCTAssertFalse(error.actions.isEmpty)
            // « vous » register only.
            XCTAssertFalse(error.message(french: true).contains(" tu "), error.message(french: true))
        }
    }

    func testInternalErrorsMapToPersonFacingOnes() {
        XCTAssertEqual(UserFacingError.from(PicshopError.cancelled).kind, .cancelled)
        XCTAssertEqual(UserFacingError.from(PicshopError.permissionDenied("Photos")).kind, .photosAccessDenied)
        XCTAssertEqual(UserFacingError.from(PicshopError.corruptProject("x")).kind, .damagedProject)
        XCTAssertEqual(UserFacingError.from(PicshopError.renderFailed("metal")).kind, .generic)
        XCTAssertEqual(UserFacingError.from(CancellationError()).kind, .cancelled)
        let space = NSError(domain: NSCocoaErrorDomain, code: 640)
        XCTAssertEqual(UserFacingError.from(space).kind, .noSpace(missingBytes: nil))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
        XCTAssertEqual(UserFacingError.from(wrapped).kind, .noSpace(missingBytes: nil))
        XCTAssertEqual(UserFacingError.from(UserFacingError.Wrapped(UserFacingError(.pdfWithoutText))).kind, .pdfWithoutText)
    }
}
