import XCTest
@testable import PicshopCore

/// The canvas renders once per frame at most, follows a drag with exactly one
/// render per burst of changes, draws the sharp frame after 120 ms of stillness,
/// and asks for no frames at all when nothing moves.
final class FramePacerTests: XCTestCase {
    func testIdleWantsNoFrames() {
        var pacer = FramePacer()
        XCTAssertFalse(pacer.wantsFrames)
        XCTAssertEqual(pacer.tick(now: 0, renderInFlight: false), .none)
        XCTAssertEqual(pacer.phase, .idle)
    }

    func testDirtyingDuringARenderGivesExactlyOneFollowUp() {
        var pacer = FramePacer()
        pacer.markDirty(interactive: true, now: 0)
        XCTAssertEqual(pacer.tick(now: 0.001, renderInFlight: false), .renderInteractive)
        for step in 1...5 { pacer.markDirty(interactive: true, now: 0.001 * Double(step)) }
        XCTAssertEqual(pacer.tick(now: 0.008, renderInFlight: false), .none, "one render at a time")
        pacer.renderFinished(now: 0.009)
        XCTAssertEqual(pacer.tick(now: 0.010, renderInFlight: false), .renderInteractive)
        pacer.renderFinished(now: 0.012)
        XCTAssertEqual(pacer.tick(now: 0.016, renderInFlight: false), .none, "the five changes were one render")
    }

    func testSettledRenderFollowsStillness() {
        var pacer = FramePacer(settleDelay: 0.12)
        pacer.markDirty(interactive: true, now: 1.0)
        XCTAssertEqual(pacer.tick(now: 1.001, renderInFlight: false), .renderInteractive)
        pacer.renderFinished(now: 1.006)
        XCTAssertTrue(pacer.wantsFrames, "the settle deadline needs ticks")
        XCTAssertEqual(pacer.tick(now: 1.06, renderInFlight: false), .none)
        XCTAssertEqual(pacer.tick(now: 1.119, renderInFlight: false), .none)
        XCTAssertEqual(pacer.tick(now: 1.121, renderInFlight: false), .renderSettled)
        XCTAssertFalse(pacer.wantsFrames, "the sharp frame's completion wakes the pump")
        pacer.renderFinished(now: 1.2)
        XCTAssertEqual(pacer.phase, .idle)
        XCTAssertFalse(pacer.wantsFrames, "0 fps at idle")
        XCTAssertEqual(pacer.tick(now: 1.3, renderInFlight: false), .none)
    }

    func testAFinishedChangeIsDrawnSharpAtOnce() {
        var pacer = FramePacer()
        pacer.markDirty(interactive: false, now: 5)
        XCTAssertTrue(pacer.wantsFrames)
        XCTAssertEqual(pacer.tick(now: 5.008, renderInFlight: false), .renderSettled)
        pacer.renderFinished(now: 5.02)
        XCTAssertFalse(pacer.wantsFrames)
    }

    func testABurstOfChangesNeverHasTwoRendersInFlight() {
        var pacer = FramePacer()
        var inFlight = 0, maxInFlight = 0, renders = 0
        var now = 0.0
        for index in 0..<100 {
            pacer.markDirty(interactive: true, now: now)
            if index % 3 == 0 {
                let action = pacer.tick(now: now, renderInFlight: inFlight > 0)
                if action != .none { inFlight += 1; renders += 1 }
                maxInFlight = max(maxInFlight, inFlight)
            }
            if index % 7 == 6, inFlight > 0 {
                inFlight -= 1
                pacer.renderFinished(now: now)
            }
            now += 0.001
        }
        XCTAssertEqual(maxInFlight, 1)
        XCTAssertLessThan(renders, 100)
    }

    func testTheRenderLoopFlagAlsoHoldsBack() {
        var pacer = FramePacer()
        pacer.markDirty(interactive: true, now: 0)
        XCTAssertEqual(pacer.tick(now: 0, renderInFlight: true), .none, "a render started elsewhere counts")
        XCTAssertEqual(pacer.tick(now: 0, renderInFlight: false), .renderInteractive)
    }

    func testDraggingAgainDuringTheSharpFrameResumes() {
        var pacer = FramePacer()
        pacer.markDirty(interactive: false, now: 0)
        XCTAssertEqual(pacer.tick(now: 0, renderInFlight: false), .renderSettled)
        pacer.markDirty(interactive: true, now: 0.01)
        pacer.renderFinished(now: 0.02)
        XCTAssertEqual(pacer.phase, .interactive)
        XCTAssertEqual(pacer.tick(now: 0.02, renderInFlight: false), .renderInteractive)
    }
}
