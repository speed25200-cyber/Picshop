import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class DuckingTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func timeline(duration: Double = 10, withMusic: Bool = true) -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: duration, frameRate: 30)
        var timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: duration))], renderSize: PSSize(width: 1920, height: 1080))
        if withMusic {
            let song = MediaAsset(kind: .audio, relativePath: "media/song.m4a", pixelSize: .zero, duration: 60)
            timeline.audioTracks = [AudioTrack(asset: song, sourceRange: TimeSpan(start: 0, duration: duration), volume: 0.8, fadeIn: 0, fadeOut: 0)]
        }
        return timeline
    }

    // MARK: - Envelope

    func testMusicDipsUnderSpeechAndComesBack() {
        let points = Ducking.envelope(span: TimeSpan(start: 0, end: 10), level: 1, amount: 0.7, speech: [TimeSpan(start: 3, end: 5)])
        XCTAssertEqual(Ducking.value(of: points, at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(Ducking.value(of: points, at: 4), 0.3, accuracy: 0.001)
        XCTAssertEqual(Ducking.value(of: points, at: 8), 1, accuracy: 0.001)
        // The dip starts before the voice.
        XCTAssertLessThan(Ducking.value(of: points, at: 2.9), 1)
    }

    func testGapsBetweenWordsAreBridged() {
        let regions = Ducking.regions(from: [TimeSpan(start: 1, end: 2), TimeSpan(start: 2.4, end: 3), TimeSpan(start: 6, end: 7)])
        XCTAssertEqual(regions, [TimeSpan(start: 1, end: 3), TimeSpan(start: 6, end: 7)])
    }

    func testFadesStillApply() {
        let points = Ducking.envelope(span: TimeSpan(start: 0, end: 10), level: 1, amount: 0.5, speech: [], fadeIn: 2, fadeOut: 2)
        XCTAssertEqual(points.first?.level ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(Ducking.value(of: points, at: 5), 1, accuracy: 0.001)
        XCTAssertEqual(points.last?.level ?? 1, 0, accuracy: 0.001)
    }

    func testSpeechAtTheStartDucksFromTheFirstFrame() {
        let points = Ducking.envelope(span: TimeSpan(start: 0, end: 10), level: 1, amount: 0.6, speech: [TimeSpan(start: 0, end: 2)])
        XCTAssertEqual(points.first?.level ?? 1, 0.4, accuracy: 0.001)
    }

    // MARK: - Speech follows the edit

    func testSpeechStaysWithThePictureThroughEdits() {
        var edited = timeline()
        edited.setSpeech([TimeSpan(start: 4, end: 6)])
        XCTAssertEqual(edited.speechRanges, [TimeSpan(start: 4, end: 6)])
        // Cutting the first two seconds moves the voice earlier.
        edited.removeRange(TimeSpan(start: 0, end: 2))
        let moved = edited.speechRanges ?? []
        XCTAssertEqual(moved.first?.start ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(moved.first?.end ?? 0, 4, accuracy: 0.001)
        // Double speed halves it.
        edited.clips[0].speed = 2
        XCTAssertEqual(edited.speechRanges?.first?.end ?? 0, 2, accuracy: 0.001)
        // A muted clip does not speak.
        edited.clips[0].isMuted = true
        XCTAssertEqual(edited.speechRanges, [])
    }

    // MARK: - Grammar and executor

    func testGrammar() {
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 10)
        XCTAssertEqual(engine.parse("baisse la musique quand je parle", context: context).intents.first?.action, .autoDuck)
        XCTAssertEqual(engine.parse("duck the music under the voice", context: context).intents.first?.action, .autoDuck)
        let off = engine.parse("désactive le ducking", context: context).intents.first
        XCTAssertEqual(off?.action, .autoDuck)
        XCTAssertEqual(off?.amount?.value, 0)
        XCTAssertNotEqual(engine.parse("baisse la musique", context: context).intents.first?.action, .autoDuck)
    }

    func testExecutorUsesTheCaptionWords() async {
        var input = timeline()
        input.captions = CaptionTrack(cues: [CaptionCue(words: [CaptionWord(text: "salut", start: 2, end: 2.5), CaptionWord(text: "toi", start: 2.6, end: 3)])])
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(), language: .english)
        let (output, result) = await executor.execute(EditIntent(action: .autoDuck), on: input, context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 10))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(output.speechRanges?.count, 2)
        XCTAssertEqual(output.audioTracks[0].ducking, 0.7, accuracy: 0.001)

        var off = EditIntent(action: .autoDuck)
        off.amount = .absolute(0)
        let (cleared, _) = await executor.execute(off, on: output, context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 10))
        XCTAssertNil(cleared.speechRanges)
    }

    func testNeedsMusic() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(), language: .english)
        let (_, result) = await executor.execute(EditIntent(action: .autoDuck), on: timeline(withMusic: false), context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 10))
        XCTAssertFalse(result.outcome.isSuccess)
    }
}
