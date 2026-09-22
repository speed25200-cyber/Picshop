import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class TitleAnimationTests: XCTestCase {
    let span = TimeSpan(start: 2, end: 6)

    func testEntrancesSettleAtRest() {
        for animation in TextAnimation.allCases where animation != .drift {
            XCTAssertEqual(animation.state(at: span.start + animation.entrance + 0.01, span: span), .rest, animation.rawValue)
        }
    }

    func testPopOvershootsThenSettles() {
        let start = TextAnimation.pop.state(at: 2, span: span)
        XCTAssertEqual(start.scale, 0.6, accuracy: 1e-9)
        let peak = (1...49).map { TextAnimation.pop.state(at: 2 + Double($0) * 0.01, span: span).scale }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.02)
    }

    func testRiseWipeFocusAndDrift() {
        XCTAssertGreaterThan(TextAnimation.rise.state(at: 2.1, span: span).offsetY, 0)
        XCTAssertLessThan(TextAnimation.wipe.state(at: 2.2, span: span).reveal, 0.5)
        XCTAssertGreaterThan(TextAnimation.focus.state(at: 2.05, span: span).blur, 0.5)
        XCTAssertEqual(TextAnimation.drift.state(at: 6, span: span).scale, 1.07, accuracy: 1e-9)
    }

    func testGrammarAndExecutor() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 3, timelineDuration: 10)
        let pop = engine.parse("anime le titre avec un rebond", context: context).intents.first
        XCTAssertEqual(pop?.action, .animateText)
        XCTAssertEqual(pop?.text, "pop")
        XCTAssertEqual(engine.parse("animate the title with a blur", context: context).intents.first?.text, "focus")
        XCTAssertNil(engine.parse("pas d'animation sur le texte", context: context).intents.first?.text)

        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10, frameRate: 30)
        let timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 10))], renderSize: PSSize(width: 1920, height: 1080))
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(), language: .english)
        let (titled, _) = await executor.execute(EditIntent(action: .addText, text: "Hello", placement: .bottom), on: timeline, context: context)
        XCTAssertEqual(titled.overlays.first?.animation, .rise)
        var intent = EditIntent(action: .animateText)
        intent.text = "wipe"
        let (animated, result) = await executor.execute(intent, on: titled, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(animated.overlays.first?.animation, .wipe)
    }
}
