import Foundation

/// Automatic editing: a pile of clips and photos plus a song become a cut
/// that lands on the beat — the "Magic Movie" of the Home screen.
///
/// The planner is pure and deterministic. The video module supplies what it
/// measured (durations, how interesting each moment is, the song's beats) and
/// turns the plan into a timeline.
public enum MagicMovie {
    public enum Pace: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A cut every beat or two: sport, parties, short-form video.
        case energetic
        /// A cut every bar: travel, everyday memories.
        case balanced
        /// Long shots with dissolves: weddings, landscapes.
        case cinematic

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .energetic: return "Energetic"
            case .balanced: return "Balanced"
            case .cinematic: return "Cinematic"
            }
        }

        /// Beats per shot, cycled so the rhythm breathes instead of ticking.
        var beatPattern: [Int] {
            switch self {
            case .energetic: return [2, 2, 1, 1, 2, 4, 2, 2]
            case .balanced: return [4, 4, 2, 4, 4, 8]
            case .cinematic: return [8, 8, 4, 8]
            }
        }

        /// Shot length when there is no music to follow.
        var fallbackShot: Double {
            switch self {
            case .energetic: return 1.2
            case .balanced: return 2.4
            case .cinematic: return 4.2
            }
        }

        var transition: Transition? {
            switch self {
            case .energetic: return nil
            case .balanced: return nil
            case .cinematic: return Transition(kind: .crossDissolve, duration: 0.6)
            }
        }
    }

    /// One imported clip or photo.
    public struct Source: Hashable, Sendable {
        public var asset: MediaAsset
        /// Usable length in seconds (photos: how long they may stay on screen).
        public var duration: Double
        /// How interesting each moment is (time, 0…1), e.g. motion, faces, sharpness.
        public var interest: [(time: Double, score: Double)]
        public var isStill: Bool

        public init(asset: MediaAsset, duration: Double, interest: [(time: Double, score: Double)] = [], isStill: Bool = false) {
            self.asset = asset
            self.duration = max(0, duration)
            self.interest = interest.sorted { $0.time < $1.time }
            self.isStill = isStill
        }

        public static func == (lhs: Source, rhs: Source) -> Bool { lhs.asset == rhs.asset && lhs.duration == rhs.duration && lhs.isStill == rhs.isStill }
        public func hash(into hasher: inout Hasher) { hasher.combine(asset); hasher.combine(duration) }

        /// Mean interest over a window.
        func score(from start: Double, length: Double) -> Double {
            guard !interest.isEmpty else {
                // Without analysis prefer the middle of a clip: openings and endings are often shaky.
                let center = start + length / 2
                return 1 - abs(center / max(duration, 1e-6) - 0.5)
            }
            let inside = interest.filter { $0.time >= start && $0.time <= start + length }
            if inside.isEmpty {
                let nearest = interest.min { abs($0.time - start) < abs($1.time - start) }
                return nearest?.score ?? 0
            }
            return inside.map(\.score).reduce(0, +) / Double(inside.count)
        }
    }

    /// One shot of the finished movie.
    public struct Shot: Hashable, Sendable {
        public var sourceIndex: Int
        /// The part of the source used, in source seconds.
        public var sourceRange: TimeSpan
        /// Position of the shot on the movie's timeline.
        public var timelineStart: Double
        public var length: Double
    }

    public struct Plan: Sendable {
        public var shots: [Shot]
        public var duration: Double
        public var pace: Pace
    }

    /// Cuts the movie. Shot boundaries follow the beat pattern of the pace
    /// (or a fixed length without music); sources are used in their original
    /// order and each shot takes the most interesting unused window of its source.
    public static func plan(sources: [Source], beats: BeatGrid?, targetDuration: Double?, pace: Pace) -> Plan {
        let usable = sources.enumerated().filter { $0.element.duration >= 0.3 }
        guard !usable.isEmpty else { return Plan(shots: [], duration: 0, pace: pace) }
        let natural = usable.reduce(0.0) { $0 + min($1.element.duration, $1.element.isStill ? pace.fallbackShot * 1.5 : 6) }
        let target = max(1, targetDuration ?? min(60, natural))

        // 1. Boundaries on the timeline.
        var boundaries: [Double] = [0]
        if let beats, beats.beats.count >= 2 {
            let grid = beats.beats.filter { $0 >= 0 }
            // Start on the first downbeat so the first cut lands on a bar.
            var index = beats.downbeatOffset < grid.count ? beats.downbeatOffset : 0
            let origin = grid[index]
            var patternIndex = 0
            while index < grid.count {
                let step = pace.beatPattern[patternIndex % pace.beatPattern.count]
                patternIndex += 1
                index += step
                guard index < grid.count else { break }
                let time = grid[index] - origin
                if time > target + 0.01 { break }
                boundaries.append(time)
            }
            if (boundaries.last ?? 0) < target - beats.period / 2, boundaries.count == 1 {
                boundaries.append(target)
            }
        } else {
            var time = pace.fallbackShot
            while time < target - pace.fallbackShot / 3 {
                boundaries.append(time)
                time += pace.fallbackShot
            }
            boundaries.append(target)
        }
        let lengths = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.filter { $0 > 0.05 }

        // 2. Sources in order, cycling, each shot on its best unused window.
        var used: [Int: [TimeSpan]] = [:]
        var shots: [Shot] = []
        var timeline = 0.0
        for (shotIndex, length) in lengths.enumerated() {
            let (sourceIndex, source) = usable[shotIndex % usable.count]
            let window = min(length, source.duration)
            let start: Double
            if source.isStill || source.duration <= window + 0.05 {
                start = 0
            } else {
                let taken = used[sourceIndex] ?? []
                var best = 0.0
                var bestScore = -Double.infinity
                let candidates = max(1, Int(((source.duration - window) / 0.25).rounded(.down)))
                for step in 0...candidates {
                    let candidate = min(source.duration - window, Double(step) * 0.25)
                    let span = TimeSpan(start: candidate, duration: window)
                    let overlap = taken.reduce(0.0) { $0 + span.clamped(to: $1).duration }
                    let score = source.score(from: candidate, length: window) - overlap * 2
                    if score > bestScore {
                        bestScore = score
                        best = candidate
                    }
                }
                start = best
            }
            let range = TimeSpan(start: start, duration: window)
            used[sourceIndex, default: []].append(range)
            shots.append(Shot(sourceIndex: sourceIndex, sourceRange: range, timelineStart: timeline, length: window))
            timeline += window
        }
        return Plan(shots: shots, duration: timeline, pace: pace)
    }

    /// The timeline for a plan: one clip per shot, Ken Burns moves on photos,
    /// the song as a faded music track.
    public static func timeline(title: String, sources: [Source], plan: Plan, music: MediaAsset?, renderSize: PSSize, frameRate: Double = 30) -> VideoTimeline {
        var clips: [VideoClip] = []
        for (index, shot) in plan.shots.enumerated() {
            let source = sources[shot.sourceIndex]
            var clip = VideoClip(asset: source.asset, sourceRange: shot.sourceRange, name: "\(title) \(index + 1)")
            if source.isStill {
                clip.motion = ClipMotion.kenBurns(duration: shot.length, variant: index)
            }
            if let transition = plan.pace.transition, index < plan.shots.count - 1 {
                clip.transitionOut = transition
            }
            clips.append(clip)
        }
        var timeline = VideoTimeline(title: title, clips: clips, renderSize: renderSize, frameRate: frameRate, aspect: .original)
        if let music {
            let span = TimeSpan(start: 0, duration: min(music.duration > 0 ? music.duration : plan.duration, timeline.duration))
            timeline.audioTracks = [AudioTrack(asset: music, sourceRange: span, volume: 0.9, fadeIn: 0.3, fadeOut: 1.5, ducking: 0.25, name: "Music")]
        }
        return timeline
    }
}
