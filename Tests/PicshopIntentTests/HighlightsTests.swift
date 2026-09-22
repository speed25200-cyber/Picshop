import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class HighlightsTests: XCTestCase {
    /// A two-minute clip where 20–26 s and 80–84 s are the good parts.
    private let moments: [MomentScore] = (0..<120).map { second in
        let t = Double(second)
        let good = (20...26).contains(t) || (80...84).contains(t)
        return MomentScore(time: t, score: good ? 0.9 : 0.3)
    }

    func testPicksTheBestMomentsInOrder() {
        let picks = HighlightPlanner.pick(clips: [HighlightPlanner.Clip(duration: 120, moments: moments)], target: 12)
        let total = picks.reduce(0) { $0 + $1.span.duration }
        XCTAssertEqual(total, 12, accuracy: 1.5)
        XCTAssertTrue(picks.contains { $0.span.start >= 19 && $0.span.end <= 27.5 })
        XCTAssertTrue(picks.contains { $0.span.start >= 79 && $0.span.end <= 85.5 })
        XCTAssertEqual(picks.map(\.span.start), picks.map(\.span.start).sorted())
        // No overlaps.
        for (a, b) in zip(picks, picks.dropFirst()) { XCTAssertLessThanOrEqual(a.span.end, b.span.start) }
    }

    func testAvoidsStraddlingAShotChange() {
        let flat = (0..<60).map { MomentScore(time: Double($0), score: 0.5) }
        let picks = HighlightPlanner.pick(clips: [HighlightPlanner.Clip(duration: 60, moments: flat, cuts: [10, 20, 30, 40, 50])], target: 6)
        for pick in picks {
            XCTAssertFalse([10.0, 20, 30, 40, 50].contains { $0 > pick.span.start + 0.3 && $0 < pick.span.end - 0.3 }, "\(pick.span)")
        }
    }

    func testGrammarAndExecutor() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 120)
        let recap = engine.parse("fais un résumé de 20 secondes", context: context).intents.first
        XCTAssertEqual(recap?.action, .highlights)
        XCTAssertEqual(recap?.amount?.value ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(engine.parse("keep the best moments", context: context).intents.first?.action, .highlights)
        XCTAssertNotEqual(engine.parse("resume playback", context: context).intents.first?.action, .highlights)

        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 120, frameRate: 30)
        let timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 120))], renderSize: PSSize(width: 1920, height: 1080))
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(moments: moments), language: .french)
        var intent = EditIntent(action: .highlights)
        intent.amount = .absolute(12)
        let (cut, result) = await executor.execute(intent, on: timeline, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertGreaterThan(cut.clips.count, 1)
        XCTAssertLessThan(cut.duration, 14)
        XCTAssertNil(cut.clips.last?.transitionOut)
    }
}

final class SpeedRampTests: XCTestCase {
    func testRampEasesIntoSlowMotionAndBack() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 5, timelineDuration: 10)
        XCTAssertEqual(engine.parse("ralenti progressif ici", context: context).intents.first?.action, .speedRamp)
        XCTAssertEqual(engine.parse("speed ramp", context: context).intents.first?.action, .speedRamp)
        XCTAssertEqual(engine.parse("ralenti", context: context).intents.first?.action, .setSpeed)

        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10, frameRate: 30)
        let timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 10))], renderSize: PSSize(width: 1920, height: 1080))
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(), language: .english)
        let (ramped, result) = await executor.execute(EditIntent(action: .speedRamp), on: timeline, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(ramped.clips.map(\.speed), [1, 0.65, 0.3, 0.65, 1])
        // Nothing of the source is lost; the slow part just lasts longer.
        XCTAssertEqual(ramped.clips.reduce(0) { $0 + $1.sourceRange.duration }, 10, accuracy: 0.001)
        XCTAssertGreaterThan(ramped.duration, 11)
    }
}
