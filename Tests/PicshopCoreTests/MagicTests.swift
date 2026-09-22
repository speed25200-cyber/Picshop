import XCTest
@testable import PicshopCore

final class AudioAnalysisTests: XCTestCase {
    /// Speech-like bursts (a modulated tone) separated by near-silence.
    private func speech(segments: [(start: Double, end: Double)], duration: Double, rate: Double = 16_000) -> AudioSignal {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        var generator = SystemRandomNumberGenerator()
        for index in samples.indices {
            let t = Double(index) / rate
            let noise = Float(Double.random(in: -1...1, using: &generator)) * 0.002
            let speaking = segments.contains { t >= $0.start && t < $0.end }
            let voice = speaking ? Float(0.4 * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 4 * t))) : 0
            samples[index] = voice + noise
        }
        return AudioSignal(samples: samples, sampleRate: rate)
    }

    func testLoudnessEnvelopeReadsLevels() {
        let signal = AudioSignal(samples: (0..<16_000).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / 16_000)) }, sampleRate: 16_000)
        let envelope = LoudnessEnvelope.measure(signal)
        XCTAssertEqual(envelope.duration, 1, accuracy: 0.02)
        // RMS of a 0.5 sine is 0.354 → about -9 dBFS.
        XCTAssertEqual(envelope.percentile(0.5), -9, accuracy: 0.6)
    }

    func testSilencesBetweenSentencesAreFound() {
        let signal = speech(segments: [(0.8, 1.4), (2.6, 4.0), (4.3, 5.5), (7.0, 7.6)], duration: 8.5)
        let ranges = SilenceDetector().silentRanges(in: signal)
        // The 1.2 s and 1.5 s pauses are cut, the 0.3 s breath is kept, and the edges too.
        guard ranges.count == 4 else { return XCTFail("\(ranges)") }
        XCTAssertEqual(ranges[0].start, 0, accuracy: 0.03)
        XCTAssertEqual(ranges[1].start, 1.4 + 0.12, accuracy: 0.06)
        XCTAssertEqual(ranges[1].end, 2.6 - 0.12, accuracy: 0.06)
        XCTAssertEqual(ranges[2].start, 5.5 + 0.12, accuracy: 0.06)
        XCTAssertEqual(ranges.last!.end, 8.5, accuracy: 0.03)
        XCTAssertFalse(ranges.contains { $0.start > 4.0 && $0.end < 4.3 })
    }

    func testNoCutsWithoutContrast() {
        let tone = AudioSignal(samples: (0..<32_000).map { Float(0.3 * sin(Double($0) * 0.1)) }, sampleRate: 16_000)
        XCTAssertTrue(SilenceDetector().silentRanges(in: tone).isEmpty)
        let silent = AudioSignal(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        XCTAssertTrue(SilenceDetector().silentRanges(in: silent).isEmpty)
    }

    func testFFTFindsTheToneBin() {
        let fft = FFT(size: 256)
        let frame = (0..<256).map { Float(sin(2 * .pi * 16 * Double($0) / 256)) }
        let magnitudes = fft.magnitudes(of: frame)
        XCTAssertEqual(magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] }, 16)
        XCTAssertEqual(magnitudes[16], 128, accuracy: 0.5)
    }

    /// A click track: short noise bursts on every beat, louder on the bar.
    private func clicks(bpm: Double, duration: Double, rate: Double = 11_025) -> AudioSignal {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        let period = 60 / bpm
        var beat = 0
        var time = 0.25
        var generator = SystemRandomNumberGenerator()
        while time < duration {
            let start = Int(time * rate)
            let gain: Float = beat % 4 == 0 ? 0.9 : 0.5
            for offset in 0..<Int(0.03 * rate) where start + offset < samples.count {
                let decay = Float(exp(-Double(offset) / (0.006 * rate)))
                samples[start + offset] += gain * decay * Float(Double.random(in: -1...1, using: &generator))
            }
            beat += 1
            time += period
        }
        return AudioSignal(samples: samples, sampleRate: rate)
    }

    func testBeatTrackerFindsTempoAndBeats() throws {
        for bpm in [96.0, 120.0, 140.0] {
            let grid = try XCTUnwrap(BeatTracker().analyze(clicks(bpm: bpm, duration: 20)))
            XCTAssertEqual(grid.bpm, bpm, accuracy: bpm * 0.04, "tempo for \(bpm)")
            let period = 60 / bpm
            // Every tracked beat sits on a click (within 40 ms).
            let interior = grid.beats.filter { $0 > 1 && $0 < 19 }
            XCTAssertGreaterThan(interior.count, Int(16 / period))
            for beat in interior {
                let phase = (beat - 0.25).truncatingRemainder(dividingBy: period)
                XCTAssertLessThan(min(phase, period - phase), 0.04, "beat at \(beat) for \(bpm) BPM")
            }
        }
    }

    func testMetronomeGrid() {
        let grid = BeatGrid.metronome(bpm: 120, duration: 2)
        XCTAssertEqual(grid.beats, [0, 0.5, 1, 1.5, 2])
        XCTAssertEqual(grid.downbeats, [0, 2])
        XCTAssertEqual(grid.nearestBeat(to: 1.2), 1)
    }
}

final class CaptionTests: XCTestCase {
    private func words(_ text: String, start: Double = 0, wordLength: Double = 0.3, gap: Double = 0.05) -> [CaptionWord] {
        var time = start
        return text.split(separator: " ").map { token in
            defer { time += wordLength + gap }
            return CaptionWord(text: String(token), start: time, end: time + wordLength)
        }
    }

    func testCuesBreakAtSentencesPausesAndLength() {
        var all = words("Bonjour tout le monde.")
        all += words("Aujourd'hui on part en voyage", start: 2.5)
        let cues = CaptionBuilder.cues(from: all, style: .classic)
        XCTAssertEqual(cues.map(\.text), ["Bonjour tout le monde.", "Aujourd'hui on part en voyage"])
        let short = CaptionBuilder.cues(from: all, style: .karaoke)
        XCTAssertTrue(short.allSatisfy { $0.text.count <= CaptionStyle.karaoke.maximumCharacters })
        XCTAssertGreaterThan(short.count, 2)
    }

    func testActiveWordAndCueLookup() {
        let track = CaptionTrack(cues: CaptionBuilder.cues(from: words("one two three"), style: .classic))
        let cue = try? XCTUnwrap(track.cue(at: 0.4))
        XCTAssertEqual(cue?.text, "one two three")
        XCTAssertEqual(cue?.activeWordIndex(at: 0.4), 1)
        XCTAssertNil(track.cue(at: 5))
    }

    func testRemovingARangeShiftsLaterWords() {
        let track = CaptionTrack(cues: CaptionBuilder.cues(from: words("a b c d"), style: .classic))
        // Words at 0, 0.35, 0.7, 1.05. Cut 0.3…0.7 removes "b" and moves c, d earlier.
        let cut = track.removing(TimeSpan(start: 0.3, end: 0.7))
        let remaining = cut.cues.flatMap(\.words)
        XCTAssertEqual(remaining.map(\.text), ["a", "c", "d"])
        XCTAssertEqual(remaining.last!.start, 1.05 - 0.4, accuracy: 1e-9)
    }

    func testEvenlyTimedWordsFromAPhrase() {
        let result = CaptionBuilder.words(in: "hello big world", span: TimeSpan(start: 1, duration: 3))
        XCTAssertEqual(result.map(\.text), ["hello", "big", "world"])
        XCTAssertEqual(result.first!.start, 1)
        XCTAssertEqual(result.last!.end, 4, accuracy: 1e-9)
        XCTAssertGreaterThan(result[0].duration, result[1].duration)
    }

    func testStyleMatching() {
        XCTAssertEqual(CaptionStyle.matching("sous-titres style tiktok"), .karaoke)
        XCTAssertEqual(CaptionStyle.matching("mot à mot"), .reveal)
    }

    func testTimelineCutKeepsCaptionsInSync() {
        let asset = MediaAsset(kind: .video, relativePath: "media/a.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10, frameRate: 30)
        var timeline = VideoTimeline(title: "t", asset: asset)
        timeline.captions = CaptionTrack(cues: CaptionBuilder.cues(from: words("x y", start: 5), style: .classic))
        timeline.removeRanges([TimeSpan(start: 1, end: 2), TimeSpan(start: 3, end: 3.5)])
        XCTAssertEqual(timeline.duration, 8.5, accuracy: 1e-6)
        XCTAssertEqual(timeline.captions!.cues.first!.words.first!.start, 3.5, accuracy: 1e-9)
    }

    func testOldProjectsDecodeWithoutTheNewFields() throws {
        let asset = MediaAsset(kind: .video, relativePath: "media/a.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10, frameRate: 30)
        let timeline = VideoTimeline(title: "t", asset: asset)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as! [String: Any]
        json.removeValue(forKey: "captions")
        json.removeValue(forKey: "beatGrid")
        let decoded = try JSONDecoder().decode(VideoTimeline.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.captions)
        XCTAssertNil(decoded.clips.first?.motion)
    }
}

final class MotionTests: XCTestCase {
    func testKeyframeInterpolation() {
        let motion = ClipMotion(kind: .manual, keyframes: [
            MotionKeyframe(time: 0, focus: PSPoint(x: 0.2, y: 0.5), zoom: 1, easing: .linear),
            MotionKeyframe(time: 2, focus: PSPoint(x: 0.8, y: 0.5), zoom: 4, easing: .linear),
        ])
        let middle = motion.sample(at: 1)
        XCTAssertEqual(middle.focus.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(middle.zoom, 2, accuracy: 1e-9) // geometric: √(1·4)
        XCTAssertEqual(motion.sample(at: -1).focus.x, 0.2)
        XCTAssertEqual(motion.sample(at: 9).zoom, 4)
    }

    func testWindowStaysInsideTheSource() {
        // 16:9 source into 9:16 output: the window is 0.316 wide.
        let window = ClipMotion.window(focus: PSPoint(x: 0.02, y: 0.5), zoom: 1, sourceAspect: 16.0 / 9.0, outputAspect: 9.0 / 16.0)
        XCTAssertEqual(window.width, (9.0 / 16.0) / (16.0 / 9.0), accuracy: 1e-9)
        XCTAssertEqual(window.minX, 0)
        XCTAssertEqual(window.height, 1)
        let zoomed = ClipMotion.window(focus: PSPoint(x: 0.9, y: 0.9), zoom: 2, sourceAspect: 1, outputAspect: 1)
        XCTAssertEqual(zoomed.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(zoomed.width, 0.5, accuracy: 1e-9)
    }

    func testSmartReframeFollowsCalmly() {
        // Subject walks from the left third to the right third over 6 s, with jitter.
        var samples: [FocusSample] = []
        for index in 0...60 {
            let t = Double(index) * 0.1
            let jitter = (index % 2 == 0 ? 0.01 : -0.01)
            samples.append(FocusSample(time: t, point: PSPoint(x: 0.3 + 0.4 * t / 6 + jitter, y: 0.5)))
        }
        let path = SmartReframe().path(samples: samples, duration: 6, sourceAspect: 16.0 / 9.0, outputAspect: 9.0 / 16.0)
        XCTAssertEqual(path.kind, .smartReframe)
        let start = path.sample(at: 0).focus.x
        let end = path.sample(at: 6).focus.x
        XCTAssertLessThan(start, 0.4)
        XCTAssertGreaterThan(end, 0.55)
        // Never moves backwards (the jitter is absorbed by the dead zone).
        var previous = start
        for step in 1...60 {
            let x = path.sample(at: Double(step) * 0.1).focus.x
            XCTAssertGreaterThanOrEqual(x, previous - 1e-6)
            previous = x
        }
        XCTAssertLessThan(path.keyframes.count, 40, "the path is simplified")
    }

    func testKenBurnsVariesPerClip() {
        let a = ClipMotion.kenBurns(duration: 3, variant: 0)
        let b = ClipMotion.kenBurns(duration: 3, variant: 1)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.keyframes.last!.time, 3)
        XCTAssertGreaterThan(a.sample(at: 3).zoom, a.sample(at: 0).zoom)
    }
}

final class MagicMovieTests: XCTestCase {
    private func source(_ name: String, duration: Double, still: Bool = false) -> MagicMovie.Source {
        MagicMovie.Source(asset: MediaAsset(kind: still ? .image : .video, relativePath: "media/\(name)", pixelSize: PSSize(width: 1920, height: 1080), duration: duration),
                          duration: duration, isStill: still)
    }

    func testCutsLandOnTheBeat() {
        let beats = BeatGrid.metronome(bpm: 120, duration: 30)
        let sources = [source("a", duration: 12), source("b", duration: 8), source("c", duration: 3, still: true)]
        let plan = MagicMovie.plan(sources: sources, beats: beats, targetDuration: 20, pace: .balanced)
        XCTAssertFalse(plan.shots.isEmpty)
        for shot in plan.shots {
            let beatsIn = shot.timelineStart / beats.period
            XCTAssertEqual(beatsIn, beatsIn.rounded(), accuracy: 1e-6, "shot starts on a beat")
            XCTAssertLessThanOrEqual(shot.sourceRange.end, sources[shot.sourceIndex].duration + 1e-9)
        }
        XCTAssertLessThanOrEqual(plan.duration, 20 + 1e-6)
        XCTAssertEqual(Set(plan.shots.map(\.sourceIndex)), [0, 1, 2])
    }

    func testRepeatedSourcesUseDifferentMoments() {
        let plan = MagicMovie.plan(sources: [source("a", duration: 20)], beats: nil, targetDuration: 8, pace: .energetic)
        let starts = plan.shots.map(\.sourceRange.start)
        XCTAssertEqual(Set(starts).count, starts.count, "no window used twice: \(starts)")
    }

    func testTimelineHasMusicAndKenBurnsOnStills() {
        let sources = [source("a", duration: 6), source("p", duration: 4, still: true)]
        let plan = MagicMovie.plan(sources: sources, beats: nil, targetDuration: 6, pace: .cinematic)
        let song = MediaAsset(kind: .audio, relativePath: "media/song.m4a", pixelSize: .zero, duration: 120)
        let timeline = MagicMovie.timeline(title: "Trip", sources: sources, plan: plan, music: song, renderSize: PSSize(width: 1080, height: 1920))
        XCTAssertEqual(timeline.clips.count, plan.shots.count)
        XCTAssertEqual(timeline.audioTracks.count, 1)
        XCTAssertNotNil(timeline.clips.first { $0.asset.kind == .image }?.motion)
        XCTAssertEqual(timeline.clips.first?.transitionOut?.kind, .crossDissolve)
    }
}

final class ColorTransferTests: XCTestCase {
    func testLabRoundTrip() {
        for rgb in [(0.2, 0.4, 0.6), (1.0, 1.0, 1.0), (0.9, 0.1, 0.05), (0.0, 0.0, 0.0)] {
            let back = ColorSpaceMath.sRGB(fromLab: ColorSpaceMath.lab(fromSRGB: rgb))
            XCTAssertEqual(back.0, rgb.0, accuracy: 1e-6)
            XCTAssertEqual(back.1, rgb.1, accuracy: 1e-6)
            XCTAssertEqual(back.2, rgb.2, accuracy: 1e-6)
        }
    }

    private func pixels(_ color: (UInt8, UInt8, UInt8), spread: Int = 30, count: Int = 400) -> [UInt8] {
        var bytes: [UInt8] = []
        for index in 0..<count {
            let d = (index % spread) - spread / 2
            bytes += [UInt8(clamping: Int(color.0) + d), UInt8(clamping: Int(color.1) + d), UInt8(clamping: Int(color.2) + d), 255]
        }
        return bytes
    }

    func testIdentityWhenSourceEqualsReference() {
        let stats = ColorStatistics.measure(rgba: pixels((120, 140, 90)))
        let match = ColorMatch(source: stats, reference: stats, strength: 1)
        let out = match.transfer((0.3, 0.5, 0.7))
        XCTAssertEqual(out.0, 0.3, accuracy: 1e-6)
        XCTAssertEqual(out.2, 0.7, accuracy: 1e-6)
    }

    func testWarmSourceMovesTowardsCoolReference() {
        let warm = ColorStatistics.measure(rgba: pixels((200, 140, 80)))
        let cool = ColorStatistics.measure(rgba: pixels((80, 130, 200)))
        XCTAssertGreaterThan(warm.mean[2], cool.mean[2], "warm has higher b*")
        let match = ColorMatch(source: warm, reference: cool, strength: 1)
        let out = match.transfer((200.0 / 255, 140.0 / 255, 80.0 / 255))
        XCTAssertGreaterThan(out.2, out.0, "the warm mean becomes blue-ish")
        let half = ColorMatch(source: warm, reference: cool, strength: 0)
        XCTAssertEqual(half.transfer((0.5, 0.5, 0.5)).0, 0.5, accuracy: 1e-6)
    }

    func testCubeLayout() {
        let stats = ColorStatistics(mean: [50, 0, 0], deviation: [20, 10, 10])
        let cube = ColorMatch(source: stats, reference: stats, strength: 1).cube(dimension: 4)
        XCTAssertEqual(cube.count, 4 * 4 * 4 * 4)
        // Entry (r=3, g=0, b=0) is pure red; red is the fastest axis.
        XCTAssertEqual(cube[3 * 4], 1, accuracy: 1e-5)
        XCTAssertEqual(cube[3 * 4 + 1], 0, accuracy: 1e-5)
    }

    func testCubeFileParsing() throws {
        let text = """
        # comment
        TITLE "Teal"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "Teal")
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.data.count, 32)
        XCTAssertEqual(Array(lut.data[4..<8]), [1, 0, 0, 1])
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 3\n0 0 0"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 3"))
    }
}

final class BeatSyncTests: XCTestCase {
    func testCutsMoveToTheNearestBeat() {
        let asset = MediaAsset(kind: .video, relativePath: "media/a.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 30, frameRate: 30)
        var timeline = VideoTimeline(title: "t", clips: [
            VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 2.3)),
            VideoClip(asset: asset, sourceRange: TimeSpan(start: 10, duration: 1.8)),
            VideoClip(asset: asset, sourceRange: TimeSpan(start: 20, duration: 2.6), speed: 2),
        ])
        timeline.clips[1].asset = MediaAsset(kind: .video, relativePath: "media/b.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 11.8, frameRate: 30)
        let beats = BeatGrid.metronome(bpm: 120, duration: 10).beats // every 0.5 s
        let (snapped, moved) = BeatSync.snap(timeline, to: beats)
        XCTAssertEqual(moved, 3)
        let ends = zip(snapped.clipStartTimes, snapped.clips).map { $0 + $1.timelineDuration }
        for end in ends {
            XCTAssertEqual((end * 2).rounded(), end * 2, accuracy: 1e-9, "cut at \(end) lands on a beat")
        }
        // Clip 2 has no media after its out-point, so it could only shrink (4.1 → 4.0).
        XCTAssertEqual(ends[1], 4.0, accuracy: 1e-9)
        XCTAssertEqual(snapped.clips[2].sourceRange.duration, snapped.clips[2].timelineDuration * 2, accuracy: 1e-9)
    }

    func testBeatsAreMappedIntoTimelineTime() {
        let song = MediaAsset(kind: .audio, relativePath: "media/s.m4a", pixelSize: .zero, duration: 60)
        let track = AudioTrack(asset: song, timelineStart: 2, sourceRange: TimeSpan(start: 10, duration: 20))
        let beats = BeatSync.timelineBeats(BeatGrid(bpm: 60, beats: [9, 10, 11, 31]), track: track)
        XCTAssertEqual(beats, [2, 3])
    }
}

final class ColorGradingTests: XCTestCase {
    func testHSLRoundTrip() {
        for rgb in [(0.9, 0.2, 0.1), (0.1, 0.6, 0.3), (0.2, 0.3, 0.8), (0.5, 0.5, 0.5), (1.0, 1.0, 0.0)] {
            let back = ColorEngine.rgb(fromHSL: ColorEngine.hsl(fromRGB: rgb))
            XCTAssertEqual(back.0, rgb.0, accuracy: 1e-9)
            XCTAssertEqual(back.1, rgb.1, accuracy: 1e-9)
            XCTAssertEqual(back.2, rgb.2, accuracy: 1e-9)
        }
    }

    func testBandWeightsArePartitionOfUnity() {
        for hue in stride(from: 0.0, to: 360.0, by: 7.5) {
            let total = ColorMixer.weights(forHue: hue).reduce(0) { $0 + $1.1 }
            XCTAssertEqual(total, 1, accuracy: 1e-9, "hue \(hue)")
        }
        XCTAssertEqual(ColorMixer.weights(forHue: 120).first?.0, ColorMixer.Band.green.rawValue)
        XCTAssertEqual(ColorMixer.Band.matching("désature les verts"), .green)
        XCTAssertEqual(ColorMixer.Band.matching("make the blues deeper"), .blue)
    }

    func testNeutralIsIdentity() {
        let color = (0.3, 0.6, 0.2)
        let out = ColorEngine.apply(mixer: .neutral, grade: .neutral, to: color)
        XCTAssertEqual(out.0, 0.3)
        XCTAssertEqual(out.1, 0.6)
    }

    func testDesaturatingRedsLeavesBluesAlone() {
        var mixer = ColorMixer()
        mixer[.red, .saturation] = -1
        let red = ColorEngine.apply(mixer: mixer, grade: nil, to: (0.85, 0.15, 0.12))
        XCTAssertLessThan(ColorEngine.hsl(fromRGB: red).1, 0.1, "reds turn grey")
        let blue = ColorEngine.apply(mixer: mixer, grade: nil, to: (0.1, 0.3, 0.9))
        XCTAssertEqual(blue.2, 0.9, accuracy: 1e-6)
        let grey = ColorEngine.apply(mixer: mixer, grade: nil, to: (0.5, 0.5, 0.5))
        XCTAssertEqual(grey.0, 0.5, accuracy: 1e-9)
    }

    func testHueShiftMovesGreensTowardsYellow() {
        var mixer = ColorMixer()
        mixer[.green, .hue] = -1
        let before = ColorEngine.hsl(fromRGB: (0.2, 0.7, 0.2)).0
        let after = ColorEngine.hsl(fromRGB: ColorEngine.apply(mixer: mixer, grade: nil, to: (0.2, 0.7, 0.2))).0
        XCTAssertLessThan(after, before - 20)
    }

    func testTealAndOrangeGradesByTone() {
        let dark = ColorEngine.apply(mixer: nil, grade: .tealAndOrange, to: (0.15, 0.15, 0.15))
        let bright = ColorEngine.apply(mixer: nil, grade: .tealAndOrange, to: (0.85, 0.85, 0.85))
        XCTAssertGreaterThan(dark.2, dark.0, "shadows go teal")
        XCTAssertGreaterThan(bright.0, bright.2, "highlights go warm")
    }

    func testCubeAndStackResolution() {
        XCTAssertEqual(ColorEngine.cube(mixer: nil, grade: .tealAndOrange, dimension: 5).count, 5 * 5 * 5 * 4)
        var stack = EditStack()
        var mixer = ColorMixer()
        mixer[.blue, .saturation] = 0.4
        stack.setColor(.colorMixer(mixer))
        mixer[.blue, .saturation] = 0.6
        stack.setColor(.colorMixer(mixer))
        XCTAssertEqual(stack.operations.count, 1, "dragging replaces the last mixer step")
        XCTAssertEqual(stack.resolvedColorMixer?[.blue, .saturation], 0.6)
        stack.setColor(.colorGrade(.tealAndOrange))
        XCTAssertEqual(stack.operations.count, 2)
        XCTAssertEqual(stack.resolvedColorGrade, .tealAndOrange)
        stack.setColor(.colorMixer(.neutral))
        XCTAssertNil(stack.resolvedColorMixer)
    }
}
