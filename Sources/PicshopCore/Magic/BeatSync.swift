import Foundation

/// Moves the cuts of an edit onto the beats of its music.
public enum BeatSync {
    /// Beat times of an audio track, converted to timeline seconds.
    public static func timelineBeats(_ grid: BeatGrid, track: AudioTrack) -> [Double] {
        grid.beats
            .filter { $0 >= track.sourceRange.start && $0 <= track.sourceRange.end }
            .map { track.timelineStart + ($0 - track.sourceRange.start) }
    }

    /// Retimes every cut to the nearest beat by trimming or extending the
    /// outgoing clip's out-point. A clip is only extended into media it
    /// actually has, never shorter than `minimumClip`, and the last clip ends on
    /// the last beat that fits.
    public static func snap(_ input: VideoTimeline, to beats: [Double], minimumClip: Double = 0.4) -> (timeline: VideoTimeline, moved: Int) {
        var timeline = input
        let beats = beats.sorted()
        guard beats.count >= 2, !timeline.clips.isEmpty else { return (timeline, 0) }
        var moved = 0
        for index in timeline.clips.indices {
            let starts = timeline.clipStartTimes
            let clip = timeline.clips[index]
            let start = starts[index]
            let end = start + clip.timelineDuration
            // Seconds of media available after the current out-point (on the timeline).
            let sourceLimit = clip.renderAsset.duration > 0 ? clip.renderAsset.duration : clip.sourceRange.end
            let headroom = clip.isReversed ? 0 : max(0, (sourceLimit - clip.sourceRange.end) / clip.speed)
            let candidates = beats.filter { $0 >= start + minimumClip && $0 <= end + headroom + 1e-9 }
            guard let target = candidates.min(by: { abs($0 - end) < abs($1 - end) }) else { continue }
            let delta = target - end
            guard abs(delta) > 0.01 else { continue }
            timeline.clips[index].sourceRange = TimeSpan(start: clip.sourceRange.start, duration: clip.sourceRange.duration + delta * clip.speed)
            moved += 1
        }
        timeline.touch()
        return (timeline, moved)
    }
}
