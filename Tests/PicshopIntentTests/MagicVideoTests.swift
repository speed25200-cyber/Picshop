import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Video services with the magic tools answered from canned data.
struct FakeMagicVideoServices: VideoAIServices {
    var words: [CaptionWord] = []
    var dialogue = AudioSignal(samples: [], sampleRate: 16_000)
    var music = AudioSignal(samples: [], sampleRate: 11_025)
    var focus: [FocusSample] = []
    var trackPath: [TrackSample] = []
    var sceneOffsets: [Double] = []
    var moments: [MomentScore] = []

    func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate] { [] }
    func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset { clip.asset }
    func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset { clip.asset }
    func reverse(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset { clip.asset }
    func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset { timeline.clips[0].asset }
    func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset { timeline.clips[0].asset }
    func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset { clip.asset }

    func transcribe(timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> (words: [CaptionWord], language: String?) { (words, "fr-FR") }
    func dialogueSignal(timeline: VideoTimeline) async throws -> AudioSignal { dialogue }
    func musicSignal(track: AudioTrack) async throws -> AudioSignal { music }
    func focusSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FocusSample] { focus }
    func isolateVoice(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        MediaAsset(kind: .audio, relativePath: "media/voice.m4a", pixelSize: .zero, duration: clip.sourceRange.duration, origin: .generated)
    }
    func track(point: PSPoint, at time: Double, within span: TimeSpan, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [TrackSample] { trackPath }
    func sceneCuts(for clip: VideoClip, timeline: VideoTimeline, sensitivity: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] { sceneOffsets }
    func momentScores(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [MomentScore] { moments }
    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] { texts.map { "[\(target)] " + $0 } }
    var faces: [FaceSample] = []
    func faceSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FaceSample] { faces }
    func colorStatistics(clip: VideoClip, timeline: VideoTimeline) async throws -> ColorStatistics {
        clip.name == "warm" ? ColorStatistics(mean: [60, 10, 30], deviation: [20, 8, 12]) : ColorStatistics(mean: [50, -5, -20], deviation: [18, 6, 9])
    }
}

final class MagicVideoTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func timeline(clips: Int = 1, duration: Double = 12) -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: duration * Double(clips), frameRate: 30)
        let parts = (0..<clips).map { VideoClip(asset: asset, sourceRange: TimeSpan(start: Double($0) * duration, duration: duration), name: $0 == 0 ? "warm" : "cool") }
        return VideoTimeline(title: "t", clips: parts, renderSize: PSSize(width: 1920, height: 1080))
    }

    private func context(_ timeline: VideoTimeline, playhead: Double = 0) -> IntentContext {
        IntentContext(mode: .video, clipCount: timeline.clips.count, playheadSeconds: playhead, timelineDuration: timeline.duration, frameRate: 30)
    }

    private func actions(_ text: String) -> [IntentAction] {
        engine.parse(text, context: IntentContext(mode: .video, clipCount: 2, playheadSeconds: 1, timelineDuration: 20)).intents.map(\.action)
    }

    func testGrammar() {
        XCTAssertEqual(actions("ajoute des sous-titres"), [.autoCaptions])
        XCTAssertEqual(actions("add captions"), [.autoCaptions])
        XCTAssertEqual(actions("enlève les sous-titres"), [.removeCaptions])
        XCTAssertEqual(actions("enlève les blancs"), [.removeSilences])
        XCTAssertEqual(actions("coupe les silences"), [.removeSilences])
        XCTAssertEqual(actions("remove the pauses"), [.removeSilences])
        XCTAssertEqual(actions("coupe sur le rythme de la musique"), [.syncToBeat])
        XCTAssertEqual(actions("cut to the beat"), [.syncToBeat])
        XCTAssertEqual(actions("passe en vertical en suivant le sujet"), [.smartReframe])
        XCTAssertEqual(actions("isole la voix"), [.enhanceVoice])
        XCTAssertEqual(actions("remove background noise"), [.enhanceVoice])
        XCTAssertEqual(actions("ajoute un effet ken burns partout"), [.kenBurns])
        XCTAssertEqual(actions("harmonise les couleurs sur le clip 1"), [.matchColor])
        XCTAssertEqual(actions("enlève les blancs et ajoute des sous-titres style karaoké"), [.removeSilences, .autoCaptions])
        let styled = engine.parse("sous-titres mot à mot", context: .video).intents.first
        XCTAssertEqual(styled?.text, CaptionStyle.reveal.rawValue)
        let reframe = engine.parse("smart reframe en carré", context: .video).intents.first
        XCTAssertEqual(reframe?.aspect, .square)
        // Plain muting still works.
        XCTAssertEqual(actions("coupe le son"), [.mute])
    }

    func testCaptionsAreWrittenThenRestyled() async {
        var words: [CaptionWord] = []
        for (index, token) in "bienvenue dans ma cuisine aujourd'hui on fait des crêpes".split(separator: " ").enumerated() {
            words.append(CaptionWord(text: String(token), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35))
        }
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(words: words), language: .french)
        var video = timeline()
        let (captioned, result) = await executor.execute(EditIntent(action: .autoCaptions), on: video, context: context(video))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(captioned.captions?.style, .karaoke)
        XCTAssertEqual(captioned.captions?.language, "fr-FR")
        XCTAssertEqual(captioned.captions?.transcript, words.map(\.text).joined(separator: " "))
        video = captioned
        var restyle = EditIntent(action: .autoCaptions)
        restyle.text = "classic"
        let (restyled, _) = await executor.execute(restyle, on: video, context: context(video))
        XCTAssertEqual(restyled.captions?.style, .classic)
        XCTAssertLessThan(restyled.captions!.cues.count, captioned.captions!.cues.count)
        let (removed, _) = await executor.execute(EditIntent(action: .removeCaptions), on: restyled, context: context(restyled))
        XCTAssertNil(removed.captions)
    }

    func testSilencesAreCut() async {
        let rate = 16_000.0
        var samples = [Float](repeating: 0.0005, count: Int(12 * rate))
        for (start, end) in [(0.0, 3.0), (5.0, 8.0), (10.0, 12.0)] {
            for index in Int(start * rate)..<Int(end * rate) { samples[index] = Float(0.4 * sin(Double(index) * 0.07)) }
        }
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(dialogue: AudioSignal(samples: samples, sampleRate: rate)))
        let video = timeline()
        let (cut, result) = await executor.execute(EditIntent(action: .removeSilences), on: video, context: context(video))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        // Two 2 s pauses minus 0.12 s of breath on each side.
        XCTAssertEqual(cut.duration, 12 - 2 * (2 - 0.24), accuracy: 0.08)
        XCTAssertEqual(cut.clips.count, 3)
    }

    func testCutsSnapToTheSongsBeat() async {
        // 120 BPM click track, 16 s.
        let rate = 11_025.0
        var samples = [Float](repeating: 0, count: Int(16 * rate))
        var time = 0.0
        while time < 16 {
            let start = Int(time * rate)
            for offset in 0..<300 where start + offset < samples.count { samples[start + offset] = Float(exp(-Double(offset) / 60)) * (offset % 2 == 0 ? 0.8 : -0.8) }
            time += 0.5
        }
        var video = timeline(clips: 3, duration: 3.3)
        video.clips = video.clips.map { var clip = $0; clip.asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 60, frameRate: 30); return clip }
        video.audioTracks = [AudioTrack(asset: MediaAsset(kind: .audio, relativePath: "media/s.wav", pixelSize: .zero, duration: 16))]
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(music: AudioSignal(samples: samples, sampleRate: rate)))
        let (synced, result) = await executor.execute(EditIntent(action: .syncToBeat), on: video, context: context(video))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        let grid = try? XCTUnwrap(synced.beatGrid)
        XCTAssertEqual(grid?.bpm ?? 0, 120, accuracy: 5)
        for (start, clip) in zip(synced.clipStartTimes, synced.clips).dropLast() {
            let end = start + clip.timelineDuration
            let nearest = grid?.nearestBeat(to: end) ?? 0
            XCTAssertEqual(end, nearest, accuracy: 0.001, "cut at \(end)")
        }
    }

    func testSmartReframeSetsAspectAndMotion() async {
        let focus = (0...20).map { FocusSample(time: Double($0) * 0.5, point: PSPoint(x: 0.2 + 0.03 * Double($0), y: 0.5)) }
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(focus: focus))
        let video = timeline()
        var intent = EditIntent(action: .smartReframe)
        intent.aspect = .ratio9x16
        let (reframed, result) = await executor.execute(intent, on: video, context: context(video))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(reframed.aspect, .ratio9x16)
        XCTAssertLessThan(reframed.renderSize.aspectRatio, 1)
        let motion = try? XCTUnwrap(reframed.clips[0].motion)
        XCTAssertEqual(motion?.kind, .smartReframe)
        XCTAssertLessThan(motion!.sample(at: 0).focus.x, motion!.sample(at: 10).focus.x)
    }

    func testVoiceKenBurnsAndColourMatch() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices())
        var video = timeline(clips: 2, duration: 4)
        var ctx = context(video)
        let (voiced, voice) = await executor.execute(EditIntent(action: .enhanceVoice, scope: .all), on: video, context: ctx)
        XCTAssertTrue(voice.outcome.isSuccess)
        XCTAssertTrue(voiced.clips.allSatisfy { $0.enhancedAudio != nil })
        video = voiced
        let (moving, _) = await executor.execute(EditIntent(action: .kenBurns, scope: .all), on: video, context: ctx)
        XCTAssertTrue(moving.clips.allSatisfy { $0.motion?.kind == .kenBurns })
        XCTAssertNotEqual(moving.clips[0].motion, moving.clips[1].motion)
        video = moving
        ctx = context(video)
        var match = EditIntent(action: .matchColor, scope: .all)
        match.clipIndex = 1
        let (matched, result) = await executor.execute(match, on: video, context: ctx)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertNil(matched.clips[0].colorMatch)
        XCTAssertEqual(matched.clips[1].colorMatch?.reference.mean, [60, 10, 30])
    }

    func testUnsupportedBackEndsFailPolitely() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices(), language: .english)
        let video = timeline()
        let (_, result) = await executor.execute(EditIntent(action: .autoCaptions), on: video, context: context(video))
        XCTAssertFalse(result.outcome.isSuccess)
    }
}

final class SceneSplitTests: XCTestCase {
    func testGrammarAndSplit() async {
        let engine = RuleBasedIntentEngine()
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 12)
        XCTAssertEqual(engine.parse("coupe à chaque changement de plan", context: context).intents.first?.action, .splitScenes)
        XCTAssertEqual(engine.parse("detect scenes", context: context).intents.first?.action, .splitScenes)
        XCTAssertNotEqual(engine.parse("floute l'arrière-plan", context: context).intents.first?.action, .splitScenes)

        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 12, frameRate: 30)
        let timeline = VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 12))], renderSize: PSSize(width: 1920, height: 1080))
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(sceneOffsets: [3, 7.5]), language: .english)
        let (split, result) = await executor.execute(EditIntent(action: .splitScenes, scope: .all), on: timeline, context: context)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(split.clips.count, 3)
        XCTAssertEqual(split.clips[1].sourceRange.start, 3, accuracy: 0.001)
        XCTAssertEqual(split.duration, 12, accuracy: 0.001)
    }
}
