#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreGraphics
import Observation
import PicshopCore
#if canImport(UIKit)
import QuartzCore
#endif

/// AVPlayer wrapper for the video editor. Rebuilds the composition when the
/// timeline changes and publishes the playhead for the UI.
///
/// Scrubbing chases the finger (Apple QA1820): one seek in flight at a time,
/// within a frame either way, and when it lands the player seeks again only if
/// the finger moved meanwhile; `endScrub()` makes the last one exact. The
/// playhead is published when it moves by a frame or more, and `isPlaying`
/// follows the player's timeControlStatus rather than every tick.
///
/// The preview is drawn at most 1920 px on its longest side (1280 while the
/// finger scrubs); export builds its own composition at full size. While it
/// plays, `displayTime` follows the item's clock at the display's rate (up to
/// 120 Hz), for the views that slide with the playhead.
@MainActor
@Observable
public final class TimelinePlayer {
    /// Longest side of the preview frames while playing or paused, and while scrubbing.
    nonisolated public static let previewLongestSide: CGFloat = 1920
    nonisolated public static let scrubLongestSide: CGFloat = 1280

    public let player = AVPlayer()
    public private(set) var currentTime: Double = 0
    /// The playhead at display rate while playing (else `currentTime`). Only the
    /// strip offset and the timeline scroll read it.
    public private(set) var displayTime: Double = 0
    /// The governor's cap on the playhead's frame rate.
    @ObservationIgnored public var maxFrameRate: Int = 120
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public private(set) var isReady = false

    private let observers: PlaybackObservers
    @ObservationIgnored private var builder: CompositionBuilder
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var lastBuiltHash: Int?
    /// Frame rate of the loaded timeline: one frame is the scrub tolerance and the publish step.
    @ObservationIgnored private var frameRate: Double = 30
    /// Where the finger wants the playhead; the seek in flight chases it.
    @ObservationIgnored private var chaseTime: CMTime = .zero
    @ObservationIgnored private var isSeekInProgress = false
    /// Bumped by every exact seek: a chase seek it cancelled does not start another.
    @ObservationIgnored private var chaseGeneration = 0
    /// Between the first scrub(to:) and endScrub(): the periodic observer leaves the playhead to the finger.
    @ObservationIgnored public private(set) var isScrubbing = false
    /// The preview composition as built, and its smaller copy for scrubbing.
    @ObservationIgnored private var previewComposition: AVVideoComposition?
    @ObservationIgnored private var scrubComposition: AVVideoComposition?

    public init(store: ProjectStore, projectID: UUID) {
        builder = CompositionBuilder(store: store, projectID: projectID)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        observers = PlaybackObservers(player: player)
        observers.time = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            // Delivered on the main queue: no task per tick.
            MainActor.assumeIsolated {
                self?.playerTimeChanged(CMTimeGetSeconds(time))
            }
        }
        observers.end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setPlaying(false)
            }
        }
        observers.status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in self?.setPlaying(playing) }
        }
    }

    private var frameDuration: Double { 1 / max(1, frameRate) }

    private func playerTimeChanged(_ seconds: Double) {
        guard seconds.isFinite, !isScrubbing else { return }
        if abs(seconds - currentTime) >= frameDuration * 0.999 {
            currentTime = seconds
            if observers.displayLink == nil, displayTime != seconds { displayTime = seconds }
        }
    }

    private func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
        playing ? startDisplayLink() : stopDisplayLink()
    }

    private func setCurrentTime(_ seconds: Double) {
        if currentTime != seconds { currentTime = seconds }
        if displayTime != seconds { displayTime = seconds }
    }

    // MARK: Display-rate playhead

    /// While playing, a display link reads the item's clock every refresh, so the
    /// strip and the timeline glide at 120 Hz instead of stepping at the video's 30.
    private func startDisplayLink() {
        #if canImport(UIKit)
        guard observers.displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] in self?.displayLinkTick() }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        let cap = Float(max(60, min(120, maxFrameRate)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, cap), maximum: cap, preferred: cap)
        link.add(to: .main, forMode: .common)
        observers.displayLink = link
        #endif
    }

    private func stopDisplayLink() {
        #if canImport(UIKit)
        observers.displayLink?.invalidate()
        observers.displayLink = nil
        #endif
        if displayTime != currentTime { displayTime = currentTime }
    }

    private func displayLinkTick() {
        guard isPlaying, !isScrubbing, let item = player.currentItem else { return }
        let seconds = CMTimeGetSeconds(item.currentTime())
        guard seconds.isFinite, seconds != displayTime else { return }
        displayTime = seconds
    }

    // MARK: Preview size

    /// The finger scrubs: frames are drawn smaller so each seek lands sooner.
    private func useScrubSize(_ scrubbing: Bool) {
        guard let item = player.currentItem, let full = previewComposition else { return }
        if scrubbing {
            guard max(full.renderSize.width, full.renderSize.height) > Self.scrubLongestSide else { return }
            if scrubComposition == nil, let copy = full.mutableCopy() as? AVMutableVideoComposition {
                copy.renderSize = VideoTime.fitted(full.renderSize, longestSide: Self.scrubLongestSide)
                scrubComposition = copy
            }
            if let small = scrubComposition, item.videoComposition !== small { item.videoComposition = small }
        } else if item.videoComposition !== full {
            item.videoComposition = full
        }
    }

    /// Rebuilds the player item if the timeline changed. Keeps the playhead.
    public func load(_ timeline: VideoTimeline) {
        let hash = timeline.hashValue
        guard hash != lastBuiltHash else { return }
        lastBuiltHash = hash
        frameRate = timeline.frameRate
        buildTask?.cancel()
        let wasPlaying = isPlaying
        let resumeTime = currentTime
        buildTask = Task { [builder] in
            let signpost = PSSignpost.begin("video.itemReady")
            defer { PSSignpost.end(signpost) }
            do {
                let built = try await builder.build(timeline, maxRenderDimension: Self.previewLongestSide)
                guard !Task.isCancelled else { return }
                let item = built.playerItem()
                previewComposition = item.videoComposition
                scrubComposition = nil
                player.replaceCurrentItem(with: item)
                if isScrubbing { useScrubSize(true) }
                if duration != timeline.duration { duration = timeline.duration }
                if !isReady { isReady = true }
                await seek(to: min(resumeTime, timeline.duration))
                if wasPlaying { play() }
            } catch {
                PSLog.error("player build failed: \(error)", category: .video)
                isReady = false
            }
        }
    }

    public func play() {
        if isScrubbing { useScrubSize(false) }
        isScrubbing = false
        if currentTime >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
        setPlaying(true)
    }

    public func pause() {
        player.pause()
        setPlaying(false)
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// An exact seek. Cancels the chase: the playhead lands exactly here.
    public func seek(to seconds: Double) async {
        let clamped = seconds.clamped(to: 0...max(0, duration))
        let time = VideoTime.cm(clamped)
        if isScrubbing { useScrubSize(false) }
        isScrubbing = false
        chaseGeneration += 1
        chaseTime = time
        isSeekInProgress = false
        setCurrentTime(clamped)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Follows a finger (the filmstrip, the timeline): the playhead is published at
    /// once, and the picture follows with at most one seek in flight.
    public func scrub(to seconds: Double) {
        let clamped = seconds.clamped(to: 0...max(0, duration))
        if !isScrubbing { useScrubSize(true) }
        isScrubbing = true
        setCurrentTime(clamped)
        let time = VideoTime.cm(clamped)
        guard CMTimeCompare(time, chaseTime) != 0 else { return }
        chaseTime = time
        if !isSeekInProgress { seekToChaseTime() }
    }

    /// The finger let go: one exact seek to where it stopped.
    public func endScrub() {
        guard isScrubbing else { return }
        useScrubSize(false)
        isScrubbing = false
        let target = CMTimeGetSeconds(chaseTime)
        Task { await seek(to: target) }
    }

    private func seekToChaseTime() {
        isSeekInProgress = true
        let target = chaseTime
        let generation = chaseGeneration
        let tolerance = CMTime(seconds: frameDuration, preferredTimescale: VideoTime.timescale)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.chaseGeneration else { return }
                if CMTimeCompare(target, self.chaseTime) == 0 {
                    self.isSeekInProgress = false
                } else {
                    self.seekToChaseTime()
                }
            }
        }
    }

    /// The picture the timeline shows at `seconds` (every edit, as it plays), at most
    /// `maxPixel` on its longest side, within 0.1 s. Picshop Live's frame.
    public func frame(at seconds: Double, maxPixel: Int) async -> CGImage? {
        guard let item = player.currentItem else { return nil }
        // The composition is mutable: the generator works on a copy.
        let asset = (item.asset.copy() as? AVAsset) ?? item.asset
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: VideoTime.timescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = VideoTime.cm(seconds.clamped(to: 0...max(0, duration)))
        return try? await generator.image(at: time).image
    }

    public func step(frames: Int, frameRate: Double) async {
        await seek(to: currentTime + Double(frames) / max(1, frameRate))
    }
}
/// Owns the AVPlayer observation tokens so they can be released from a
/// nonisolated `deinit` without touching main-actor state.
private final class PlaybackObservers: @unchecked Sendable {
    let player: AVPlayer
    var time: Any?
    var end: NSObjectProtocol?
    var status: NSKeyValueObservation?
    #if canImport(UIKit)
    /// The playhead's display link while playing; it retains its target, so it is invalidated here too.
    var displayLink: CADisplayLink?
    #else
    var displayLink: AnyObject? { nil }
    #endif

    init(player: AVPlayer) {
        self.player = player
    }

    deinit {
        if let time { player.removeTimeObserver(time) }
        if let end { NotificationCenter.default.removeObserver(end) }
        status?.invalidate()
        #if canImport(UIKit)
        displayLink?.invalidate()
        #endif
    }
}

#if canImport(UIKit)
/// The display link's target: it calls back on the main run loop.
private final class DisplayLinkTarget: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func tick() {
        MainActor.assumeIsolated { action() }
    }
}
#endif

#endif
