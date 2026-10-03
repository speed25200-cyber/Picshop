import Foundation

/// Where each moment of a video timeline lands after an edit moved its clips:
/// a cut, a trim, a speed change, a clip moved, deleted, duplicated or inserted.
///
/// Titles, pictures, picture-in-picture videos, their keyframes and tracking
/// paths, sound tracks and caption words are placed in timeline seconds. They
/// are carried through this map, so each stays over the shot it was put on.
///
/// The map is built by comparing where the same source media sits before and
/// after the edit, so one rule covers every edit that rearranges clips: a moment
/// survives when the media under it is still on the timeline, and moves with it.
public struct TimeMap: Hashable, Sendable {
    /// One stretch of the old timeline that survives, moved and possibly rescaled.
    public struct Segment: Hashable, Sendable {
        /// The stretch, in old timeline seconds.
        public var old: TimeSpan
        /// Where `old.start` lands on the new timeline.
        public var newStart: Double
        /// New seconds per old second: 2 when the clip under it now plays at half speed.
        public var scale: Double

        public init(old: TimeSpan, newStart: Double, scale: Double = 1) {
            self.old = old
            self.newStart = newStart
            self.scale = max(0, scale)
        }

        public var newEnd: Double { newStart + old.duration * scale }

        /// The new time of an old time inside (or at the edges of) this stretch.
        public func map(_ time: Double) -> Double { newStart + (time - old.start) * scale }
    }

    /// Which side of a boundary a time belongs to. A start (a title's first
    /// frame) belongs to what follows it, an end to what precedes it.
    public enum Edge: Sendable { case start, end }

    /// Surviving stretches, in old-timeline order, never overlapping.
    public private(set) var segments: [Segment]
    public let oldDuration: Double
    public let newDuration: Double

    /// Tolerance for boundaries computed along different paths (split points, speeds).
    static let slack = 1e-6

    public init(segments: [Segment], oldDuration: Double, newDuration: Double) {
        self.segments = segments.filter { $0.old.duration > 1e-12 }.sorted { $0.old.start < $1.old.start }
        self.oldDuration = max(0, oldDuration)
        self.newDuration = max(0, newDuration)
    }

    /// Nothing moved.
    public static func identity(duration: Double) -> TimeMap {
        TimeMap(segments: duration > 0 ? [Segment(old: TimeSpan(start: 0, duration: duration), newStart: 0)] : [],
                oldDuration: duration, newDuration: duration)
    }

    /// True when every moment stays where it was.
    public var isIdentity: Bool {
        guard abs(oldDuration - newDuration) <= Self.slack else { return false }
        var covered = 0.0
        for segment in segments {
            guard abs(segment.newStart - segment.old.start) <= Self.slack, abs(segment.scale - 1) <= 1e-9 else { return false }
            covered += segment.old.duration
        }
        return abs(covered - oldDuration) <= Self.slack * Double(max(1, segments.count))
    }

    /// The old seconds that no longer exist on the new timeline.
    public var removed: [TimeSpan] {
        var gaps: [TimeSpan] = []
        var cursor = 0.0
        for segment in segments {
            if segment.old.start - cursor > Self.slack { gaps.append(TimeSpan(start: cursor, end: segment.old.start)) }
            cursor = max(cursor, segment.old.end)
        }
        if oldDuration - cursor > Self.slack { gaps.append(TimeSpan(start: cursor, end: oldDuration)) }
        return gaps
    }

    // MARK: Mapping

    /// The new time of an old time; nil when the media under it was cut out.
    /// Times before 0 or after the old end keep their distance to the first or last frame.
    public func map(_ time: Double, edge: Edge = .start) -> Double? {
        if time < -Self.slack {
            return map(0, edge: .start).map { $0 + time }
        }
        if time > oldDuration + Self.slack {
            return map(oldDuration, edge: .end).map { $0 + (time - oldDuration) }
        }
        if let segment = segment(containing: time, edge: edge) { return segment.map(time) }
        // The very first and last frames have nothing on their other side.
        if edge == .start, time >= oldDuration - Self.slack, let segment = segment(containing: time, edge: .end) { return segment.map(time) }
        if edge == .end, time <= Self.slack, let segment = segment(containing: time, edge: .start) { return segment.map(time) }
        return nil
    }

    /// Like `map`, but a time that was cut out lands where the cut closed up:
    /// right after what survives before it.
    public func clamp(_ time: Double, edge: Edge = .start) -> Double {
        if let mapped = map(time, edge: edge) { return mapped }
        let before = segments.filter { $0.old.end <= time + Self.slack }.max { $0.old.end < $1.old.end }
        if let before { return before.newEnd }
        let after = segments.filter { $0.old.start >= time - Self.slack }.min { $0.old.start < $1.old.start }
        return after?.newStart ?? 0
    }

    /// The first old time at or after `time` that survives the edit, nil when none does.
    public func firstSurviving(atOrAfter time: Double) -> Double? {
        if segment(containing: time, edge: .start) != nil { return time }
        return segments.filter { $0.old.start >= time - Self.slack }.map(\.old.start).min()
    }

    private func segment(containing time: Double, edge: Edge) -> Segment? {
        switch edge {
        case .start:
            return segments.first { $0.old.start - Self.slack <= time && time < $0.old.end - 1e-9 }
        case .end:
            return segments.first { $0.old.start + 1e-9 < time && time <= $0.old.end + Self.slack }
        }
    }

    // MARK: Building

    /// The map from one arrangement of clips to another.
    ///
    /// A moment of an old clip survives when the same media is still on the
    /// timeline: in the same clip, or in a clip this edit created from the same
    /// file (the second half of a split, a duplicate). The same clip given new
    /// media (a stabilised or reversed render) keeps its place, stretched to its
    /// new length. Under a transition, the incoming clip owns the overlap.
    public static func between(_ old: [VideoClip], _ new: [VideoClip]) -> TimeMap {
        let oldStarts = VideoTimeline.startTimes(of: old)
        let newStarts = VideoTimeline.startTimes(of: new)
        let oldIDs = Set(old.map(\.id))
        var segments: [Segment] = []
        for (index, clip) in old.enumerated() {
            let start = oldStarts[index]
            let ownedEnd = index + 1 < old.count ? oldStarts[index + 1] : start + clip.timelineDuration
            guard ownedEnd - start > 1e-9 else { continue }
            // Offsets inside the clip not yet placed on the new timeline.
            var open: [(lower: Double, upper: Double)] = [(0, ownedEnd - start)]
            let sameClip = new.indices.filter { new[$0].id == clip.id }
            let offspring = new.indices.filter {
                !oldIDs.contains(new[$0].id) && new[$0].renderAsset == clip.renderAsset && new[$0].isReversed == clip.isReversed
            }
            for target in sameClip + offspring where !open.isEmpty {
                guard let piece = piece(from: clip, to: new[target]) else { continue }
                var remaining: [(lower: Double, upper: Double)] = []
                for interval in open {
                    let lower = max(interval.lower, piece.lower), upper = min(interval.upper, piece.upper)
                    guard upper - lower > 1e-9 else { remaining.append(interval); continue }
                    let newOffset = piece.newOffset + (lower - piece.lower) * piece.scale
                    segments.append(Segment(old: TimeSpan(start: start + lower, end: start + upper),
                                            newStart: newStarts[target] + newOffset, scale: piece.scale))
                    if lower - interval.lower > 1e-9 { remaining.append((interval.lower, lower)) }
                    if interval.upper - upper > 1e-9 { remaining.append((upper, interval.upper)) }
                }
                open = remaining
            }
        }
        return TimeMap(segments: segments, oldDuration: VideoTimeline.duration(of: old), newDuration: VideoTimeline.duration(of: new))
    }

    /// Which offsets of `clip` show the same media in `target`, where the first
    /// of them lands inside `target`, and how much it is stretched.
    static func piece(from clip: VideoClip, to target: VideoClip) -> (lower: Double, upper: Double, newOffset: Double, scale: Double)? {
        if clip.renderAsset == target.renderAsset, clip.isReversed == target.isReversed {
            let overlapStart = max(clip.sourceRange.start, target.sourceRange.start)
            let overlapEnd = min(clip.sourceRange.end, target.sourceRange.end)
            guard overlapEnd - overlapStart > 1e-9 else { return nil }
            let scale = clip.speed / target.speed
            if clip.isReversed {
                // Played backwards: offset o shows source end − o × speed.
                return ((clip.sourceRange.end - overlapEnd) / clip.speed, (clip.sourceRange.end - overlapStart) / clip.speed,
                        (target.sourceRange.end - overlapEnd) / target.speed, scale)
            }
            return ((overlapStart - clip.sourceRange.start) / clip.speed, (overlapEnd - clip.sourceRange.start) / clip.speed,
                    (overlapStart - target.sourceRange.start) / target.speed, scale)
        }
        guard clip.id == target.id, clip.timelineDuration > 1e-9 else { return nil }
        return (0, clip.timelineDuration, 0, target.timelineDuration / clip.timelineDuration)
    }
}

// MARK: - Carrying what sits on the timeline

public extension TimelineOverlay {
    /// The overlay after an edit: over the same shot, as long as the part of it that
    /// survived. One whose whole span was cut keeps its length where the cut closed up,
    /// rather than disappearing.
    func carried(by map: TimeMap) -> TimelineOverlay {
        var overlay = self
        let start = map.map(span.start, edge: .start)
        var newStart = start ?? map.clamp(span.start, edge: .start)
        var newEnd = map.map(span.end, edge: .end) ?? map.clamp(span.end, edge: .end)
        if newEnd - newStart < 0.1 {
            // Cut out entirely, or its end moved before its start (clips reordered under it).
            newEnd = newStart + span.duration
        }
        newStart = max(0, newStart)
        overlay.span = TimeSpan(start: newStart, end: max(newStart, newEnd))
        // A picture-in-picture video whose first seconds were cut starts later in its file,
        // so it still plays in step with what is under it.
        if start == nil, case .video(let asset, let transform, let sourceStart) = content,
           let surviving = map.firstSurviving(atOrAfter: span.start), surviving < span.end {
            overlay.content = .video(asset, transform: transform, sourceStart: sourceStart + (surviving - span.start))
        }
        if let frames = keyframes {
            var moved: [MovedKeyframe] = []
            for (order, frame) in frames.enumerated() {
                var copy = frame
                copy.time = max(0, map.clamp(frame.time, edge: .start))
                moved.append(MovedKeyframe(order: order, frame: copy))
            }
            moved.sort(by: MovedKeyframe.precedes)
            // Keyframes squeezed together by a cut: the one that came later wins.
            var kept: [MovedKeyframe] = []
            for entry in moved {
                if let last = kept.last, abs(last.frame.time - entry.frame.time) < 0.05 {
                    if entry.order > last.order { kept[kept.count - 1] = entry }
                } else {
                    kept.append(entry)
                }
            }
            overlay.keyframes = kept.map(\.frame)
        }
        if let path = tracking {
            let samples = path.samples.compactMap { sample -> TrackSample? in
                guard let time = map.map(sample.time, edge: .start) ?? map.map(sample.time, edge: .end) else { return nil }
                return TrackSample(time: time, point: sample.point)
            }
            overlay.tracking = samples.count >= 2 ? TrackingPath(samples: samples, anchorTime: map.clamp(path.anchorTime)) : nil
        }
        return overlay
    }
}

/// A keyframe at its new time, with its place in the original list.
private struct MovedKeyframe {
    var order: Int
    var frame: OverlayKeyframe

    static func precedes(_ a: MovedKeyframe, _ b: MovedKeyframe) -> Bool {
        if a.frame.time != b.frame.time { return a.frame.time < b.frame.time }
        return a.order < b.order
    }
}

public extension AudioTrack {
    /// The sound after an edit: it starts with the moment it started on. A bed that
    /// starts with the video keeps starting with it. It plays through, uncut.
    func carried(by map: TimeMap) -> AudioTrack {
        guard timelineStart > 0.05 else { return self }
        var track = self
        track.timelineStart = max(0, map.clamp(timelineStart, edge: .start))
        return track
    }
}

public extension CaptionTrack {
    /// Captions after an edit: each word moves with the voice that says it; words cut out go.
    func carried(by map: TimeMap) -> CaptionTrack {
        var copy = self
        let words = cues.flatMap(\.words).compactMap { word -> CaptionWord? in
            guard let start = map.map(word.start, edge: .start), let end = map.map(word.end, edge: .end),
                  end >= start - TimeMap.slack else { return nil }
            return CaptionWord(text: word.text, start: start, end: max(start, end))
        }
        copy.cues = CaptionBuilder.cues(from: words, style: style)
        return copy
    }
}

public extension VideoTimeline {
    /// Moves overlays, keyframes, tracking paths, sound tracks and captions so each
    /// stays with the media it was placed over, after `clips` changed from `oldClips`.
    mutating func carryAttachments(from oldClips: [VideoClip]) {
        let map = TimeMap.between(oldClips, clips)
        guard !map.isIdentity else { return }
        apply(map)
    }

    /// Carries everything placed in timeline seconds through `map`.
    mutating func apply(_ map: TimeMap) {
        overlays = overlays.map { $0.carried(by: map) }
        audioTracks = audioTracks.map { $0.carried(by: map) }
        if let track = captions { captions = track.carried(by: map) }
    }

    /// Runs an edit of the clips, then carries what sits on the timeline along with
    /// them. `edit` changes clips only: overlays it adds would be moved too.
    mutating func ripple(_ edit: (inout VideoTimeline) -> Void) {
        let before = clips
        edit(&self)
        carryAttachments(from: before)
    }
}
