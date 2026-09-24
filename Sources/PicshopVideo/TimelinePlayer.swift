#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreGraphics
import Observation
import PicshopCore

/// AVPlayer wrapper for the video editor. Rebuilds the composition when the
/// timeline changes and publishes the playhead for the UI.
///
/// Scrubbing chases the finger (Apple QA1820): one seek in flight at a time,
/// within a frame either way, and when it lands the player seeks again only if
/// the finger moved meanwhile; `endScrub()` makes the last one exact. The
/// playhead is published when it moves by a frame or more, and `isPlaying`
/// follows the player's timeControlStatus rather than every tick.
@MainActor
@Observable
public final class TimelinePlayer {
    public let player = AVPlayer()
    public private(set) var currentTime: Double = 0
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
        if abs(seconds - currentTime) >= frameDuration * 0.999 { currentTime = seconds }
    }

    private func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
    }

    private func setCurrentTime(_ seconds: Double) {
        if currentTime != seconds { currentTime = seconds }
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
            do {
                let built = try await builder.build(timeline)
                guard !Task.isCancelled else { return }
                let item = built.playerItem()
                player.replaceCurrentItem(with: item)
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

    init(player: AVPlayer) {
        self.player = player
    }

    deinit {
        if let time { player.removeTimeObserver(time) }
        if let end { NotificationCenter.default.removeObserver(end) }
        status?.invalidate()
    }
}

#endif
