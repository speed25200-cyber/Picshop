#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import PicshopCore

/// AVPlayer wrapper for the video editor. Rebuilds the composition when the
/// timeline changes and publishes the playhead for the UI.
@MainActor
@Observable
public final class TimelinePlayer {
    public let player = AVPlayer()
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public private(set) var isReady = false

    private var timeObserver: Any?
    private var builder: CompositionBuilder
    private var buildTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var lastBuiltHash: Int?

    public init(store: ProjectStore, projectID: UUID) {
        builder = CompositionBuilder(store: store, projectID: projectID)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isPlaying = false }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Rebuilds the player item if the timeline changed. Keeps the playhead.
    public func load(_ timeline: VideoTimeline) {
        let hash = timeline.hashValue
        guard hash != lastBuiltHash else { return }
        lastBuiltHash = hash
        buildTask?.cancel()
        let wasPlaying = isPlaying
        let resumeTime = currentTime
        buildTask = Task { [builder] in
            do {
                let built = try await builder.build(timeline)
                guard !Task.isCancelled else { return }
                let item = built.playerItem()
                player.replaceCurrentItem(with: item)
                duration = timeline.duration
                isReady = true
                await seek(to: min(resumeTime, timeline.duration))
                if wasPlaying { play() }
            } catch {
                PSLog.error("player build failed: \(error)", category: .video)
                isReady = false
            }
        }
    }

    public func play() {
        if currentTime >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: Double) async {
        let time = VideoTime.cm(seconds.clamped(to: 0...max(0, duration)))
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    public func scrub(to seconds: Double) {
        let time = VideoTime.cm(seconds.clamped(to: 0...max(0, duration)))
        player.seek(to: time, toleranceBefore: CMTime(value: 1, timescale: 30), toleranceAfter: CMTime(value: 1, timescale: 30))
        currentTime = seconds
    }

    public func step(frames: Int, frameRate: Double) async {
        await seek(to: currentTime + Double(frames) / max(1, frameRate))
    }
}
#endif
