#if canImport(AVFoundation) && canImport(CoreImage)
import XCTest
import AVFoundation
import CoreImage
import PicshopCore
@testable import PicshopVideo

/// W0 on the macOS runner: exact NTSC frame durations, cancelled requests
/// finish as cancelled, and overlays carried by the TimeMap reach the composition.
final class VideoTargetTests: XCTestCase {
    func testNTSCFrameDurationIsExact() {
        XCTAssertEqual(VideoTime.frameDuration(29.97), CMTime(value: 1001, timescale: 30000))
        XCTAssertEqual(VideoTime.frameDuration(29.970029), CMTime(value: 1001, timescale: 30000))
        XCTAssertEqual(VideoTime.frameDuration(23.976), CMTime(value: 1001, timescale: 24000))
        XCTAssertEqual(VideoTime.frameDuration(59.94), CMTime(value: 1001, timescale: 60000))
        XCTAssertEqual(VideoTime.frameDuration(30), CMTime(value: 1, timescale: 30))
        XCTAssertEqual(VideoTime.frameDuration(25), CMTime(value: 1, timescale: 25))
        // An hour of 29.97 is 107 892 frames: one second at 1/30 would drift 3.6 s.
        let hour = VideoTime.frameTime(107_892, fps: 29.97)
        XCTAssertEqual(CMTimeGetSeconds(hour), 107_892 * 1001.0 / 30000.0, accuracy: 1e-9)
    }

    func testPreviewSizeIsCappedAndEven() {
        XCTAssertEqual(VideoTime.fitted(CGSize(width: 3840, height: 2160), longestSide: 1920), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoTime.fitted(CGSize(width: 2160, height: 3840), longestSide: 1280), CGSize(width: 720, height: 1280))
        XCTAssertEqual(VideoTime.fitted(CGSize(width: 1280, height: 720), longestSide: 1920), CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoTime.fitted(CGSize(width: 3840, height: 2160), longestSide: nil), CGSize(width: 3840, height: 2160))
    }

    func testCancelMakesEarlierRequestsStale() {
        let generation = CompositorGeneration()
        let before = generation.current
        XCTAssertTrue(generation.isCurrent(before))
        generation.cancelAll()
        XCTAssertFalse(generation.isCurrent(before), "a frame queued before the cancel is finished as cancelled")
        XCTAssertTrue(generation.isCurrent(generation.current), "frames asked for after it are drawn")
    }

    // MARK: Built compositions

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-video-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A project holding one still movie of `seconds` at `fps`.
    private func project(seconds: Double, fps: Double) async throws -> (ProjectStore, UUID, MediaAsset) {
        let store = ProjectStore(rootURL: root)
        let id = UUID()
        try store.createPackage(for: id)
        let url = store.mediaURL(for: id).appendingPathComponent("still.mov")
        let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
        var asset = try await VideoTranscoder.writeStill(image, duration: seconds, frameRate: fps, to: url)
        asset.relativePath = "\(Project.mediaDirectory)/still.mov"
        return (store, id, asset)
    }

    func testBuiltCompositionUsesExactFrameDuration() async throws {
        let (store, id, asset) = try await project(seconds: 2, fps: 29.97)
        var timeline = VideoTimeline(title: "t", asset: asset)
        timeline.frameRate = 29.97
        let built = try await CompositionBuilder(store: store, projectID: id).build(timeline)
        XCTAssertEqual(built.videoComposition.frameDuration, CMTime(value: 1001, timescale: 30000))
    }

    func testOverlaysFollowACutIntoTheComposition() async throws {
        let (store, id, asset) = try await project(seconds: 6, fps: 30)
        var timeline = VideoTimeline(title: "t", asset: asset)
        timeline.overlays = [TimelineOverlay(content: .text(TextElement(text: "after")), span: TimeSpan(start: 4, end: 5))]
        timeline.removeRange(TimeSpan(start: 1, end: 2))
        let built = try await CompositionBuilder(store: store, projectID: id).build(timeline)
        let instruction = try XCTUnwrap(built.videoComposition.instructions.first as? PicshopCompositionInstruction)
        let span = try XCTUnwrap(instruction.overlays.first?.span)
        XCTAssertEqual(span.start, 3, accuracy: 1e-6)
        XCTAssertEqual(span.end, 4, accuracy: 1e-6)
    }

    func testPreviewBuildIsCappedAndExportIsNot() async throws {
        let (store, id, asset) = try await project(seconds: 1, fps: 30)
        var timeline = VideoTimeline(title: "t", asset: asset)
        timeline.renderSize = PSSize(width: 3840, height: 2160)
        let builder = CompositionBuilder(store: store, projectID: id)
        let preview = try await builder.build(timeline, maxRenderDimension: TimelinePlayer.previewLongestSide)
        XCTAssertEqual(preview.videoComposition.renderSize, CGSize(width: 1920, height: 1080))
        let export = try await builder.build(timeline)
        XCTAssertEqual(export.videoComposition.renderSize, CGSize(width: 3840, height: 2160))
    }
}
#endif
