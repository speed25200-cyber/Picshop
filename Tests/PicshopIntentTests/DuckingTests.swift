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

final class MusicFitTests: XCTestCase {
    /// 120 BPM: a beat every half second, a bar every two seconds.
    let grid = BeatGrid(bpm: 120, beats: stride(from: 0.0, through: 180, by: 0.5).map { $0 }, downbeatOffset: 0)

    func testEndsOnABarBeforeTheVideoEnds() {
        let ending = MusicFit.ending(grid: grid, sourceStart: 10, sourceEnd: 180, needed: 25.3)
        XCTAssertEqual(ending?.end ?? 0, 34, accuracy: 1e-9)   // the bar at 34 s, 1.3 s before the video's end at 35.3
        XCTAssertEqual(ending?.fade ?? 0, 2, accuracy: 1e-9)
        XCTAssertNil(MusicFit.ending(grid: grid, sourceStart: 170, sourceEnd: 180, needed: 30))
    }

    func testExecutorAndGrammar() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 25.3)
        XCTAssertEqual(engine.parse("adapte la musique à la vidéo", context: context).intents.first?.action, .fitMusic)
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 25.3, frameRate: 30)
        var timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 25.3))], renderSize: PSSize(width: 1920, height: 1080))
        let song = MediaAsset(kind: .audio, relativePath: "media/song.m4a", pixelSize: .zero, duration: 180)
        timeline.audioTracks = [AudioTrack(asset: song, sourceRange: TimeSpan(start: 10, end: 180))]
        timeline.beatGrid = grid
        let (fitted, result) = await VideoCommandExecutor(services: FakeMagicVideoServices(), language: .english).execute(EditIntent(action: .fitMusic), on: timeline, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(fitted.audioTracks[0].sourceRange.end, 34, accuracy: 1e-9)
    }
}

final class FaceBlurTests: XCTestCase {
    func testNearestSamplesAndGrowth() {
        let face = PSRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        let samples = [FaceSample(time: 1.0, boxes: [face]), FaceSample(time: 1.1, boxes: []), FaceSample(time: 2.0, boxes: [PSRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)])]
        let at = FaceBlur.boxes(in: samples, at: 1.05)
        XCTAssertEqual(at.count, 1)
        XCTAssertGreaterThan(at[0].width, face.width)
        XCTAssertTrue(FaceBlur.boxes(in: samples, at: 1.5).isEmpty)
        XCTAssertEqual(FaceBlur.boxes(in: samples, at: 1.8).count, 1, "a face about to appear is covered early")
    }

    func testGrammarAndExecutor() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 5)
        XCTAssertEqual(engine.parse("floute les visages", context: context).intents.first?.action, .blurFaces)
        XCTAssertEqual(engine.parse("défloute les visages", context: context).intents.first?.amount?.value, 0)
        XCTAssertEqual(engine.parse("zoom sur le visage", context: context).intents.first?.action, .zoom)
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 5, frameRate: 30)
        let timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 5))], renderSize: PSSize(width: 1920, height: 1080))
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(faces: [FaceSample(time: 0, boxes: [PSRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)])]), language: .english)
        let (blurred, result) = await executor.execute(EditIntent(action: .blurFaces, scope: .all), on: timeline, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(blurred.clips[0].blurredFaces?.count, 1)
    }
}
