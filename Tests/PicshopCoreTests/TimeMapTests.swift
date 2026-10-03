import XCTest
@testable import PicshopCore

/// Titles, pictures, keyframes, tracking paths, sounds and captions stay over the
/// shot they were placed on when clips are cut, trimmed, sped up or reordered.
final class TimeMapTests: XCTestCase {
    // MARK: Fixtures

    private func asset(_ name: String, duration: Double) -> MediaAsset {
        MediaAsset(kind: .video, relativePath: "media/\(name).mov", pixelSize: PSSize(width: 1920, height: 1080), duration: duration, frameRate: 30)
    }

    /// Three shots from three files: 0–4 s (a), 4–10 s (b), 10–15 s (c).
    private func threeShots() -> VideoTimeline {
        let clips = [VideoClip(asset: asset("a", duration: 4), name: "a"),
                     VideoClip(asset: asset("b", duration: 6), name: "b"),
                     VideoClip(asset: asset("c", duration: 5), name: "c")]
        return VideoTimeline(title: "t", clips: clips)
    }

    private func title(_ text: String, from start: Double, to end: Double) -> TimelineOverlay {
        TimelineOverlay(content: .text(TextElement(text: text)), span: TimeSpan(start: start, end: end))
    }

    private func overlay(_ timeline: VideoTimeline, _ text: String) -> TimelineOverlay {
        timeline.overlays.first { $0.textElement?.text == text }!
    }

    /// The media under a timeline second: every clip whose span holds it (two under a transition).
    private func content(at time: Double, in timeline: VideoTimeline) -> [(path: String, source: Double)] {
        let starts = timeline.clipStartTimes
        return timeline.clips.indices.compactMap { index in
            let clip = timeline.clips[index]
            let offset = time - starts[index]
            guard offset >= -1e-6, offset <= clip.timelineDuration + 1e-6 else { return nil }
            return (clip.renderAsset.relativePath, clip.sourceTime(forClipOffset: offset))
        }
    }

    // MARK: The map itself

    func testSameClipsMapToThemselves() {
        let timeline = threeShots()
        let map = TimeMap.between(timeline.clips, timeline.clips)
        XCTAssertTrue(map.isIdentity)
        XCTAssertEqual(map.map(7.5), 7.5)
        XCTAssertTrue(map.removed.isEmpty)
    }

    func testSplittingMovesNothing() {
        var timeline = threeShots()
        let before = timeline.clips
        timeline.split(at: 6)
        XCTAssertTrue(TimeMap.between(before, timeline.clips).isIdentity)
    }

    func testCutClosesUpAndReportsWhatWent() {
        var timeline = threeShots()
        let before = timeline.clips
        timeline.removeRange(TimeSpan(start: 5, end: 7))
        let map = TimeMap.between(before, timeline.clips)
        XCTAssertEqual(map.map(4.5)!, 4.5, accuracy: 1e-9)
        XCTAssertNil(map.map(6))
        XCTAssertEqual(map.map(8)!, 6, accuracy: 1e-9)
        XCTAssertEqual(map.clamp(6), 5, accuracy: 1e-9, "a cut-out moment lands where the cut closed up")
        XCTAssertEqual(map.removed.count, 1)
        XCTAssertEqual(map.removed[0].start, 5, accuracy: 1e-9)
        XCTAssertEqual(map.removed[0].end, 7, accuracy: 1e-9)
        XCTAssertEqual(map.newDuration, 13, accuracy: 1e-9)
    }

    func testEdgesBelongToTheirSide() {
        var timeline = threeShots()
        let before = timeline.clips
        timeline.removeRange(TimeSpan(start: 4, end: 10))
        let map = TimeMap.between(before, timeline.clips)
        // 4 s is both the end of a and the start of the cut-out b.
        XCTAssertEqual(map.map(4, edge: .end)!, 4, accuracy: 1e-9)
        XCTAssertNil(map.map(4, edge: .start))
        XCTAssertEqual(map.map(10, edge: .start)!, 4, accuracy: 1e-9)
        XCTAssertNil(map.map(10, edge: .end))
        XCTAssertEqual(map.map(15, edge: .start)!, 9, accuracy: 1e-9, "the last frame maps to the new end")
        XCTAssertEqual(map.map(16)!, 10, accuracy: 1e-9, "after the end keeps its distance")
    }

    // MARK: Overlays follow their shot

    func testTitlesAfterACutMoveEarlier() {
        var timeline = threeShots()
        timeline.overlays = [title("before", from: 1, to: 3), title("after", from: 11, to: 13), title("across", from: 4, to: 8), title("inside", from: 5.5, to: 6.5)]
        timeline.removeRange(TimeSpan(start: 5, end: 7))
        XCTAssertEqual(overlay(timeline, "before").span, TimeSpan(start: 1, end: 3))
        XCTAssertEqual(overlay(timeline, "after").span.start, 9, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "after").span.duration, 2, accuracy: 1e-9)
        let across = overlay(timeline, "across").span
        XCTAssertEqual(across.start, 4, accuracy: 1e-9)
        XCTAssertEqual(across.end, 6, accuracy: 1e-9, "a title over the cut loses the part that went")
        let inside = overlay(timeline, "inside").span
        XCTAssertEqual(inside.start, 5, accuracy: 1e-9, "a title wholly cut out stays where the cut closed")
        XCTAssertEqual(inside.duration, 1, accuracy: 1e-9)
    }

    func testRemovingSilencesKeepsTitlesOnTheirWords() {
        var timeline = threeShots()
        timeline.overlays = [title("t", from: 12, to: 14)]
        timeline.removeRanges([TimeSpan(start: 1, end: 1.5), TimeSpan(start: 6, end: 7), TimeSpan(start: 11, end: 11.5)])
        XCTAssertEqual(overlay(timeline, "t").span.start, 10, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "t").span.end, 12, accuracy: 1e-9)
    }

    func testSlowingAClipStretchesWhatIsOnItAndPushesWhatFollows() {
        var timeline = threeShots()
        timeline.overlays = [title("on b", from: 5, to: 6), title("on c", from: 11, to: 12)]
        let b = timeline.clips[1].id
        timeline.update(clipID: b) { $0.speed = 0.5 }
        XCTAssertEqual(timeline.duration, 21, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on b").span.start, 6, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on b").span.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on c").span.start, 17, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on c").span.duration, 1, accuracy: 1e-9)
    }

    func testMovingAClipTakesItsTitlesAlong() {
        var timeline = threeShots()
        timeline.overlays = [title("on c", from: 11, to: 12), title("on a", from: 1, to: 2)]
        timeline.moveClip(id: timeline.clips[2].id, to: 0)
        XCTAssertEqual(overlay(timeline, "on c").span.start, 1, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on a").span.start, 6, accuracy: 1e-9)
    }

    func testTrimmingTheHeadPullsLaterTitlesIn() {
        var timeline = threeShots()
        timeline.overlays = [title("on c", from: 11, to: 12)]
        timeline.trim(clipID: timeline.clips[1].id, startOffset: 2)
        XCTAssertEqual(overlay(timeline, "on c").span.start, 9, accuracy: 1e-9)
    }

    func testSourceRangeSetFromTheTimelineHandlesFollows() {
        var timeline = threeShots()
        timeline.overlays = [title("on c", from: 11, to: 12)]
        timeline.update(clipID: timeline.clips[0].id) { $0.sourceRange = TimeSpan(start: 1, end: 3) }
        XCTAssertEqual(overlay(timeline, "on c").span.start, 9, accuracy: 1e-9)
    }

    func testDeletingAClipPullsTheRestIn() {
        var timeline = threeShots()
        timeline.overlays = [title("on b", from: 5, to: 6), title("on c", from: 11, to: 12)]
        timeline.removeClip(id: timeline.clips[1].id)
        XCTAssertEqual(overlay(timeline, "on c").span.start, 5, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on b").span.start, 4, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on b").span.duration, 1, accuracy: 1e-9)
    }

    func testDuplicatingAClipPushesTheRestOut() {
        var timeline = threeShots()
        timeline.overlays = [title("on a", from: 1, to: 2), title("on b", from: 5, to: 6)]
        timeline.duplicateClip(id: timeline.clips[0].id)
        XCTAssertEqual(overlay(timeline, "on a").span.start, 1, accuracy: 1e-9, "stays on the original, not the copy")
        XCTAssertEqual(overlay(timeline, "on b").span.start, 9, accuracy: 1e-9)
    }

    func testInsertingClipsAtThePlayheadSplitsAndPushes() {
        var timeline = threeShots()
        timeline.overlays = [title("on b", from: 8, to: 9)]
        let inserted = VideoClip(asset: asset("new", duration: 3), name: "new")
        let index = timeline.insert([inserted], at: 6)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(timeline.clips.map(\.name), ["a", "b", "new", "b", "c"])
        XCTAssertEqual(timeline.duration, 18, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on b").span.start, 11, accuracy: 1e-9)
        XCTAssertEqual(timeline.insert([VideoClip(asset: asset("end", duration: 1), name: "end")], at: nil), 5, "nil appends")
        XCTAssertEqual(timeline.insert([VideoClip(asset: asset("head", duration: 1), name: "head")], at: 0), 0)
        XCTAssertEqual(overlay(timeline, "on b").span.start, 12, accuracy: 1e-9)
    }

    func testAddingATransitionPullsLaterTitlesIn() {
        var timeline = threeShots()
        timeline.overlays = [title("on c", from: 11, to: 12)]
        timeline.setTransition(Transition(kind: .crossDissolve, duration: 1), afterClipID: timeline.clips[1].id)
        XCTAssertEqual(timeline.duration, 14, accuracy: 1e-9)
        XCTAssertEqual(overlay(timeline, "on c").span.start, 10, accuracy: 1e-9)
    }

    func testANewRenderOfTheSameClipKeepsItsPlace() {
        var timeline = threeShots()
        timeline.overlays = [title("on b", from: 5, to: 7), title("on c", from: 11, to: 12)]
        let render = asset("b-reversed", duration: 6)
        timeline.update(clipID: timeline.clips[1].id) { clip in
            clip.processedAsset = render
            clip.sourceRange = TimeSpan(start: 0, duration: render.duration)
        }
        XCTAssertEqual(overlay(timeline, "on b").span, TimeSpan(start: 5, end: 7))
        XCTAssertEqual(overlay(timeline, "on c").span, TimeSpan(start: 11, end: 12))
    }

    func testSpeedRampStepsKeepLaterTitlesOnTheirShot() {
        var timeline = threeShots()
        timeline.overlays = [title("on c", from: 11, to: 12)]
        let before = content(at: 11, in: timeline)
        // What the executor does: four cuts, then three slower pieces.
        for time in [5.0, 6.0, 8.0, 9.0].reversed() { timeline.split(at: time) }
        let pieces = [5.5, 7.0, 8.5].compactMap { timeline.clip(at: $0)?.id }
        for (id, factor) in zip(pieces, [0.65, 0.3, 0.65]) { timeline.update(clipID: id) { $0.speed *= factor } }
        let start = overlay(timeline, "on c").span.start
        let after = content(at: start, in: timeline)
        XCTAssertEqual(after.first?.path, before.first?.path)
        XCTAssertEqual(after.first!.source, before.first!.source, accuracy: 1e-6)
    }

    // MARK: Keyframes, tracking, sound, captions

    func testKeyframesAndTrackingFollowTheCut() {
        var timeline = threeShots()
        var moving = title("moving", from: 10, to: 14)
        moving.keyframes = [OverlayKeyframe(time: 10, center: PSPoint(x: 0.2, y: 0.5)), OverlayKeyframe(time: 13, center: PSPoint(x: 0.8, y: 0.5))]
        moving.tracking = TrackingPath(samples: [TrackSample(time: 6.5, point: PSPoint(x: 0, y: 0)), TrackSample(time: 10.5, point: PSPoint(x: 0.1, y: 0)),
                                                 TrackSample(time: 12, point: PSPoint(x: 0.2, y: 0))], anchorTime: 10.5)
        timeline.overlays = [moving]
        timeline.removeRange(TimeSpan(start: 6, end: 8))
        let moved = overlay(timeline, "moving")
        XCTAssertEqual(moved.keyframes!.map(\.time)[0], 8, accuracy: 1e-9)
        XCTAssertEqual(moved.keyframes!.map(\.time)[1], 11, accuracy: 1e-9)
        XCTAssertEqual(moved.tracking!.samples.count, 2, "the sample over the cut goes")
        XCTAssertEqual(moved.tracking!.samples[0].time, 8.5, accuracy: 1e-9)
        XCTAssertEqual(moved.tracking!.anchorTime, 8.5, accuracy: 1e-9)
    }

    func testKeyframesSqueezedByACutKeepTheLaterOne() {
        var timeline = threeShots()
        var moving = title("moving", from: 4, to: 10)
        moving.keyframes = [OverlayKeyframe(time: 5, center: PSPoint(x: 0.1, y: 0.5)), OverlayKeyframe(time: 6, center: PSPoint(x: 0.9, y: 0.5)),
                            OverlayKeyframe(time: 8, center: PSPoint(x: 0.5, y: 0.5))]
        timeline.overlays = [moving]
        timeline.removeRange(TimeSpan(start: 4.5, end: 7))
        let frames = overlay(timeline, "moving").keyframes!
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].center.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(frames[0].time, 4.5, accuracy: 1e-9)
    }

    func testPictureInPictureStartingInACutStartsLaterInItsFile() {
        var timeline = threeShots()
        let pip = asset("pip", duration: 20)
        timeline.overlays = [TimelineOverlay(content: .video(pip, transform: LayerTransform(), sourceStart: 2), span: TimeSpan(start: 5, end: 9))]
        timeline.removeRange(TimeSpan(start: 4, end: 6))
        let moved = timeline.overlays[0]
        XCTAssertEqual(moved.span.start, 4, accuracy: 1e-9)
        XCTAssertEqual(moved.span.end, 7, accuracy: 1e-9)
        guard case .video(_, _, let sourceStart) = moved.content else { return XCTFail("still a video") }
        XCTAssertEqual(sourceStart, 3, accuracy: 1e-9)
    }

    func testSoundsFollowTheirMomentAndBedsStayAtTheStart() {
        var timeline = threeShots()
        let music = MediaAsset(kind: .audio, relativePath: "media/m.m4a", pixelSize: .zero, duration: 30)
        timeline.audioTracks = [AudioTrack(asset: music, timelineStart: 0, name: "bed"), AudioTrack(asset: music, timelineStart: 11, sourceRange: TimeSpan(start: 0, duration: 1), name: "door")]
        timeline.moveClip(id: timeline.clips[2].id, to: 0)
        XCTAssertEqual(timeline.audioTracks[0].timelineStart, 0)
        XCTAssertEqual(timeline.audioTracks[1].timelineStart, 1, accuracy: 1e-9, "the door slam stays on its shot")
        XCTAssertEqual(timeline.audioTracks[1].sourceRange, TimeSpan(start: 0, duration: 1), "sounds play through, uncut")
    }

    func testCaptionsFollowSpeedAndOrder() {
        var timeline = threeShots()
        let words = [CaptionWord(text: "hello", start: 1, end: 1.5), CaptionWord(text: "world", start: 11, end: 11.5)]
        timeline.captions = CaptionTrack(cues: CaptionBuilder.cues(from: words, style: .classic))
        timeline.update(clipID: timeline.clips[0].id) { $0.speed = 2 }
        var moved = timeline.captions!.cues.flatMap(\.words)
        XCTAssertEqual(moved[0].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(moved[0].end, 0.75, accuracy: 1e-9)
        XCTAssertEqual(moved[1].start, 9, accuracy: 1e-9)
        timeline.moveClip(id: timeline.clips[2].id, to: 0)
        moved = timeline.captions!.cues.flatMap(\.words)
        XCTAssertEqual(moved.map(\.text), ["world", "hello"], "re-cued in their new order")
        XCTAssertEqual(moved[0].start, 1, accuracy: 1e-9)
    }

    // MARK: Properties over random edits

    /// Over random edit sequences, every moment that survives still shows the
    /// same frame of the same file, and edits that only cut keep the order.
    func testRandomEditsKeepEveryMomentOnItsFrame() {
        var random = SplitMix(seed: 0x5EED)
        for _ in 0..<300 {
            var timeline = threeShots()
            if random.chance(0.4) { timeline.setTransition(Transition(kind: .crossDissolve, duration: 0.6), afterClipID: timeline.clips[0].id) }
            for _ in 0..<Int(random.next() % 4) + 1 {
                let before = timeline
                let monotone = edit(&timeline, random: &random)
                let map = TimeMap.between(before.clips, timeline.clips)
                var previous = -Double.infinity
                for step in 0...60 {
                    let time = before.duration * Double(step) / 60
                    guard let mapped = map.map(time) else { continue }
                    let old = content(at: time, in: before)
                    let new = content(at: mapped, in: timeline)
                    // The media owned by the map (the incoming clip under a transition) is among what shows there now.
                    let owner = old.last!
                    XCTAssertTrue(new.contains { $0.path == owner.path && abs($0.source - owner.source) < 1e-6 },
                                  "\(owner) at \(time) lost after an edit (now \(new) at \(mapped))")
                    // Under a transition two shots share the screen, so order only holds without one.
                    if monotone, !before.clips.contains(where: { $0.transitionOut != nil }) {
                        XCTAssertGreaterThanOrEqual(mapped, previous - 1e-9, "cuts and speed changes keep the order")
                        previous = mapped
                    }
                }
            }
        }
    }

    /// One random edit, as the editor makes them; true when it cannot reorder moments.
    private func edit(_ timeline: inout VideoTimeline, random: inout SplitMix) -> Bool {
        let duration = timeline.duration
        let clip = timeline.clips[Int(random.next() % UInt64(timeline.clips.count))]
        switch random.next() % 7 {
        case 0:
            let start = random.unit() * duration * 0.8
            timeline.removeRange(TimeSpan(start: start, duration: random.unit() * duration * 0.2 + 0.05))
            return true
        case 1:
            timeline.update(clipID: clip.id) { $0.speed = [0.25, 0.5, 1.5, 2, 3][Int(random.next() % 5)] }
            return true
        case 2:
            timeline.trim(clipID: clip.id, startOffset: random.unit() * clip.timelineDuration * 0.4, endOffset: clip.timelineDuration * (0.6 + random.unit() * 0.4))
            return true
        case 3:
            timeline.split(at: random.unit() * duration)
            return true
        case 4:
            guard timeline.clips.count > 1 else { return true }
            timeline.removeClip(id: clip.id)
            return true
        case 5:
            timeline.moveClip(id: clip.id, to: Int(random.next() % UInt64(timeline.clips.count)))
            return false
        default:
            timeline.duplicateClip(id: clip.id)
            return true
        }
    }
}

/// A small deterministic generator, the same on every platform.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// Exact frame durations (NTSC rates are 1001/30000 s, not 1/30), straightening and
/// playing a reversed clip forwards again.
final class FrameRateTests: XCTestCase {
    func testNTSCRatesAreExact() {
        XCTAssertEqual(FrameRate.frameDuration(29.97).value, 1001)
        XCTAssertEqual(FrameRate.frameDuration(29.97).timescale, 30000)
        XCTAssertEqual(FrameRate.frameDuration(29.970_029).timescale, 30000)
        XCTAssertEqual(FrameRate.frameDuration(23.976).timescale, 24000)
        XCTAssertEqual(FrameRate.frameDuration(59.94).timescale, 60000)
        XCTAssertEqual(FrameRate.frameDuration(119.88).timescale, 120000)
        XCTAssertEqual(FrameRate.exact(29.97), 30000.0 / 1001.0, accuracy: 1e-12)
    }

    func testWholeAndOddRates() {
        XCTAssertEqual(FrameRate.frameDuration(30).value, 1)
        XCTAssertEqual(FrameRate.frameDuration(30).timescale, 30)
        XCTAssertEqual(FrameRate.frameDuration(25).timescale, 25)
        XCTAssertEqual(FrameRate.frameDuration(0).timescale, 30, "no rate falls back to 30")
        XCTAssertEqual(FrameRate.frameDuration(12.5).value, 1000)
        XCTAssertEqual(FrameRate.frameDuration(12.5).timescale, 12500)
    }

    func testQuarterTurnsAreWhatAStraightenKeeps() {
        XCTAssertEqual(VideoClip.quarterTurns(of: 2.4), 0)
        XCTAssertEqual(VideoClip.quarterTurns(of: 92.4), 90)
        XCTAssertEqual(VideoClip.quarterTurns(of: -88), -90)
        XCTAssertEqual(VideoClip.quarterTurns(of: 180), 180)
    }

    func testPlayingForwardsRestoresTheMediaItHad() {
        let original = MediaAsset(kind: .video, relativePath: "media/a.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10)
        var clip = VideoClip(asset: original, sourceRange: TimeSpan(start: 2, end: 6))
        let forwards = VideoClip.ForwardState(clip)
        clip.isReversed = true
        clip.processedAsset = MediaAsset(kind: .video, relativePath: "media/reversed.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 4)
        clip.sourceRange = TimeSpan(start: 0, duration: 4)
        clip.beforeReverse = forwards
        clip.restoreForwards(forwards)
        XCTAssertFalse(clip.isReversed)
        XCTAssertNil(clip.processedAsset)
        XCTAssertEqual(clip.sourceRange, TimeSpan(start: 2, end: 6))
        XCTAssertNil(clip.beforeReverse)
        XCTAssertEqual(clip.renderAsset, original)
    }

    func testOldClipsDecodeWithoutTheReverseMemory() throws {
        let asset = MediaAsset(kind: .video, relativePath: "media/a.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 10)
        let clip = VideoClip(asset: asset)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
        json.removeValue(forKey: "beforeReverse")
        let decoded = try JSONDecoder().decode(VideoClip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.beforeReverse)
        XCTAssertEqual(decoded.id, clip.id)
    }
}
