import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class TrackingTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func timeline() -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10, frameRate: 30)
        var timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 10))], renderSize: PSSize(width: 1920, height: 1080))
        var element = TextElement(text: "Léa")
        element.center = PSPoint(x: 0.3, y: 0.2)
        timeline.overlays = [TimelineOverlay(content: .text(element), span: TimeSpan(start: 1, end: 6))]
        return timeline
    }

    private var context: IntentContext { IntentContext(mode: .video, clipCount: 1, playheadSeconds: 2, timelineDuration: 10) }

    // MARK: - Path

    func testOffsetIsRelativeToTheAnchor() {
        let path = TrackingPath(samples: [TrackSample(time: 1, point: PSPoint(x: 0.2, y: 0.5)), TrackSample(time: 3, point: PSPoint(x: 0.6, y: 0.5))], anchorTime: 1)
        XCTAssertEqual(path.offset(at: 1).x, 0, accuracy: 1e-9)
        XCTAssertEqual(path.offset(at: 2).x, 0.2, accuracy: 1e-9)
        // Held after the subject is lost.
        XCTAssertEqual(path.offset(at: 9).x, 0.4, accuracy: 1e-9)
    }

    func testSmoothingKeepsMotionAndDropsJitter() {
        let samples = (0..<20).map { index in TrackSample(time: Double(index) * 0.1, point: PSPoint(x: 0.1 + Double(index) * 0.02 + (index.isMultiple(of: 2) ? 0.01 : -0.01), y: 0.5)) }
        let smooth = TrackingPath.smoothed(samples)
        let jitter = zip(smooth.dropFirst(), smooth).map { abs(($0.point.x - $1.point.x) - 0.02) }.dropFirst(2).dropLast(2).max() ?? 1
        XCTAssertLessThan(jitter, 0.01)
        XCTAssertEqual(smooth[10].point.x, samples[10].point.x, accuracy: 0.012)
    }

    // MARK: - Grammar

    func testGrammar() {
        XCTAssertEqual(engine.parse("fais suivre le texte à la personne", context: context).intents.first?.action, .trackSubject)
        XCTAssertEqual(engine.parse("make the sticker follow his face", context: context).intents.first?.action, .trackSubject)
        XCTAssertEqual(engine.parse("le titre suit le visage", context: context).intents.first?.target?.label, "text")
        let stop = engine.parse("arrête de suivre avec le texte", context: context).intents.first
        XCTAssertEqual(stop?.action, .trackSubject)
        XCTAssertEqual(stop?.amount?.value, 0)
        // Reframing still means reframing.
        XCTAssertEqual(engine.parse("passe en vertical en suivant le sujet", context: context).intents.first?.action, .smartReframe)
        // Writing text that follows is not tracking.
        XCTAssertNotEqual(engine.parse("ajoute le texte qui suit bonjour", context: context).intents.first?.action, .trackSubject)
    }

    // MARK: - Executor

    func testTrackingAttachesThePath() async {
        let path = [TrackSample(time: 2, point: PSPoint(x: 0.3, y: 0.2)), TrackSample(time: 4, point: PSPoint(x: 0.5, y: 0.25))]
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(trackPath: path), language: .english)
        var intent = EditIntent(action: .trackSubject)
        intent.target = ObjectTarget(label: "text")
        let (output, result) = await executor.execute(intent, on: timeline(), context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        let tracking = output.overlays.first?.tracking
        XCTAssertEqual(tracking?.anchorTime, 2)
        XCTAssertEqual(tracking?.offset(at: 4).x ?? 0, 0.2, accuracy: 1e-9)

        var stop = EditIntent(action: .trackSubject)
        stop.amount = .absolute(0)
        let (released, _) = await executor.execute(stop, on: output, context: context)
        XCTAssertNil(released.overlays.first?.tracking)
    }

    func testNothingToTrackFails() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(trackPath: []), language: .french)
        let (_, result) = await executor.execute(EditIntent(action: .trackSubject), on: timeline(), context: context)
        XCTAssertFalse(result.outcome.isSuccess)
        var empty = timeline()
        empty.overlays = []
        let (_, none) = await executor.execute(EditIntent(action: .trackSubject), on: empty, context: context)
        XCTAssertFalse(none.outcome.isSuccess)
    }
}
