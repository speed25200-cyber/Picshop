import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The order of each turn (contract D3): the grammar's instant lane for a
/// confident command, then the local model, then Apple's on-device model, then
/// the grammar; a failure before any output re-runs the same turn on the next
/// brain, and a cancellation never counts.
final class BrainOrderTests: XCTestCase {
    private func inputs(_ now: Double, model: Bool = true, onDevice: Bool = true, hot: Bool = false) -> BrainSelector.Inputs {
        .init(modelReady: model, onDeviceAvailable: onDevice, thermalCritical: hot, now: now)
    }

    /// Where a committed turn goes, the way the session decides it.
    private func lane(_ text: String, selector: inout BrainSelector, _ inputs: BrainSelector.Inputs, fastLane: Bool = true) -> (LiveLane, LiveBrainKind) {
        let kind = selector.choose(inputs)
        let grammar = RuleBasedIntentEngine().parse(text, context: .photo)
        return (LiveTurnRouter.route(text, grammar: grammar, brain: kind, ideasOnScreen: 0, jobRunning: false, fastLane: fastLane), kind)
    }

    func testAConfidentCommandTakesTheInstantLaneEvenWithTheModelReady() {
        var selector = BrainSelector()
        let (instant, kind) = lane("plus lumineux", selector: &selector, inputs(0))
        XCTAssertEqual(kind, .model)
        guard case .local(let plan) = instant else { return XCTFail("\(instant)") }
        XCTAssertEqual(plan.intents.first?.action, .adjust)
        let (vague, _) = lane("fais-la plus poétique", selector: &selector, inputs(0))
        XCTAssertEqual(vague, .brain(isQuestion: false), "words the grammar lacks go to the model")
        let (question, _) = lane("tu en penses quoi ?", selector: &selector, inputs(0))
        XCTAssertEqual(question, .brain(isQuestion: true))
        let (noFastLane, _) = lane("plus lumineux", selector: &selector, inputs(0), fastLane: false)
        XCTAssertEqual(noFastLane, .brain(isQuestion: false), "the fast lane is a setting")
        let (grammarOnly, grammarKind) = lane("tu en penses quoi ?", selector: &selector, inputs(0, model: false, onDevice: false))
        XCTAssertEqual(grammarKind, .local)
        guard case .local = grammarOnly else { return XCTFail("the grammar brain answers everything itself: \(grammarOnly)") }
    }

    func testAFailureBeforeOutputReRunsTheTurnOnTheNextBrain() {
        var selector = BrainSelector()
        var failed: Set<LiveBrainKind> = []
        var tried: [LiveBrainKind] = []
        // The model times out on its first token, then Apple's model is unavailable: the grammar answers.
        let errors: [LiveBrainKind: LiveBrainError] = [.model: .timeout(stage: "first_token"), .onDevice: .unavailable("guardrail")]
        while true {
            let kind = selector.choose(inputs(10), excluding: failed)
            tried.append(kind)
            guard let error = errors[kind] else { break }
            selector.recordEnd(kind, error: error, now: 10)
            failed.insert(kind)
        }
        XCTAssertEqual(tried, [.model, .onDevice, .local])
        XCTAssertEqual(selector.choose(inputs(11)), .model, "one failure each: the next turn starts from the model again")
        XCTAssertEqual(selector.choose(inputs(11, hot: true)), .onDevice, "thermal critical skips the model")
    }

    func testCancellationsNeverCount() {
        var selector = BrainSelector()
        for time in stride(from: 0.0, to: 50, by: 1) {
            selector.recordEnd(.model, error: CancellationError(), now: time)
            selector.recordEnd(.onDevice, error: CancellationError(), now: time)
        }
        XCTAssertEqual(selector.choose(inputs(51)), .model)
        XCTAssertFalse(selector.isOffForSession(.model))
        XCTAssertFalse(selector.isOffForSession(.onDevice))
        XCTAssertNil(BrainSelector.countedError(CancellationError()))

        struct Odd: Error {}
        XCTAssertEqual(BrainSelector.countedError(Odd()), .unavailable("Odd"))
        XCTAssertEqual(BrainSelector.countedError(LiveBrainError.memoryPressure), .memoryPressure)
        selector.recordEnd(.model, error: Odd(), now: 60)
        selector.recordEnd(.model, error: LiveBrainError.streamTruncated, now: 61)
        XCTAssertEqual(selector.choose(inputs(62)), .onDevice, "two real failures in a row cool the model down")
        selector.recordEnd(.onDevice, error: nil, now: 63)
        XCTAssertEqual(selector.choose(inputs(122)), .model, "back after the cooldown")
        selector.recordEnd(.model, error: LiveBrainError.memoryPressure, now: 130)
        XCTAssertTrue(selector.isOffForSession(.model), "memory pressure: off for the session at once")
    }

    func testTheGrammarNeverCoolsDownAndIsAlwaysLast() {
        var selector = BrainSelector()
        for time in [0.0, 1, 2, 3, 4] { selector.recordEnd(.local, error: LiveBrainError.unavailable("x"), now: time) }
        XCTAssertFalse(selector.isOffForSession(.local))
        XCTAssertEqual(selector.choose(inputs(5, model: false, onDevice: false)), .local)
        XCTAssertEqual(selector.choose(inputs(5), excluding: [.model, .onDevice, .local]), .local)
    }
}
