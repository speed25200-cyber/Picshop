import XCTest
@testable import PicshopCore

final class TimelineTests: XCTestCase {
    private func makeTimeline(duration: Double = 10) -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: duration, frameRate: 30)
        return VideoTimeline(title: "Clip", asset: asset)
    }

    func testSplitProducesTwoContiguousClips() {
        var timeline = makeTimeline()
        XCTAssertEqual(timeline.duration, 10)
        let ids = timeline.split(at: 4)
        XCTAssertNotNil(ids)
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.clips[0].sourceRange.end, 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.clips[1].sourceRange.start, 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.duration, 10, accuracy: 1e-9)
        XCTAssertEqual(timeline.clipStartTimes[1], 4, accuracy: 1e-9)
        XCTAssertNil(timeline.split(at: 0.01), "cannot split at the very edge")
    }

    func testSpeedAffectsTimelineDurationAndMapping() {
        var timeline = makeTimeline()
        timeline.update(clipID: timeline.clips[0].id) { $0.speed = 2 }
        XCTAssertEqual(timeline.duration, 5)
        XCTAssertEqual(timeline.clips[0].sourceTime(forClipOffset: 1), 2)
        timeline.split(at: 2)
        XCTAssertEqual(timeline.clips[0].sourceRange.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.clips[1].sourceRange.start, 4, accuracy: 1e-9)
    }

    func testTrimAndRemoveRange() {
        var timeline = makeTimeline()
        timeline.trim(clipID: timeline.clips[0].id, startOffset: 2, endOffset: 8)
        XCTAssertEqual(timeline.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.clips[0].sourceRange.start, 2)
        timeline.removeRange(TimeSpan(start: 1, end: 3))
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.clips[0].sourceRange, TimeSpan(start: 2, end: 3))
        XCTAssertEqual(timeline.clips[1].sourceRange, TimeSpan(start: 5, end: 8))
    }

    func testTransitionsShortenTimeline() {
        var timeline = makeTimeline()
        timeline.split(at: 5)
        timeline.setTransition(Transition(kind: .crossDissolve, duration: 1), afterClipID: timeline.clips[0].id)
        XCTAssertEqual(timeline.duration, 9, accuracy: 1e-9)
        XCTAssertEqual(timeline.clipStartTimes[1], 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.clipIndex(at: 4.5), 0, "outgoing clip owns the overlap")
        XCTAssertEqual(timeline.clipIndex(at: 6), 1)
    }

    func testAspectChangeKeepsEvenDimensions() {
        var timeline = makeTimeline()
        timeline.setAspect(.ratio9x16)
        XCTAssertEqual(Int(timeline.renderSize.width) % 2, 0)
        XCTAssertEqual(timeline.renderSize.aspectRatio, 9.0 / 16.0, accuracy: 0.01)
        timeline.setAspect(.original)
        XCTAssertEqual(timeline.renderSize, PSSize(width: 1920, height: 1080))
    }

    func testTransitionMatching() {
        XCTAssertEqual(TransitionKind.matching("fondu enchaîné"), .crossDissolve)
        XCTAssertEqual(TransitionKind.matching("fade to black"), .fadeToBlack)
        XCTAssertEqual(TransitionKind.matching("un volet"), .wipeLeft)
    }
}

final class OverlayKeyframeTests: XCTestCase {
    func testTravelsBetweenTheRecordedPlaces() {
        let asset = MediaAsset(kind: .image, relativePath: "media/sticker.png", pixelSize: PSSize(width: 100, height: 100))
        var overlay = TimelineOverlay(content: .image(asset, transform: LayerTransform(center: PSPoint(x: 0.2, y: 0.5), scale: 0.3)), span: TimeSpan(start: 0, end: 10))
        XCTAssertNil(overlay.keyframeAdjustment(at: 1))
        overlay.setKeyframe(at: 1)
        overlay.transform?.center = PSPoint(x: 0.8, y: 0.5)
        overlay.transform?.scale = 0.6
        overlay.setKeyframe(at: 3)
        XCTAssertEqual(overlay.keyframes?.count, 2)
        // Placed at the second keyframe now: at 1 s it is 0.6 to the left and half the size.
        let early = overlay.keyframeAdjustment(at: 0.5)
        XCTAssertEqual(early?.offset.x ?? 0, -0.6, accuracy: 1e-9)
        XCTAssertEqual(early?.scale ?? 0, 0.5, accuracy: 1e-9)
        let middle = overlay.keyframeAdjustment(at: 2)
        XCTAssertEqual(middle?.offset.x ?? 0, -0.3, accuracy: 1e-9)
        XCTAssertEqual(overlay.keyframeAdjustment(at: 9)?.offset.x ?? 1, 0, accuracy: 1e-9)
        // Recording again at the same time replaces it.
        overlay.setKeyframe(at: 3.02)
        XCTAssertEqual(overlay.keyframes?.count, 2)
    }
}
