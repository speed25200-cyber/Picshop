import Foundation

/// How good one moment of a clip looks and sounds (0…1), at an offset along the clip's span.
public struct MomentScore: Hashable, Codable, Sendable {
    public var time: Double
    public var score: Double

    public init(time: Double, score: Double) {
        self.time = time
        self.score = score.clamped(to: 0...1)
    }
}

/// The best moments of long footage, as an editor would pull them for a
/// recap: the strongest shots first, each cut inside one camera shot, spread
/// across the whole recording, then put back in the order they happened.
public enum HighlightPlanner {
    public struct Clip: Sendable {
        public var duration: Double
        public var moments: [MomentScore]
        /// Shot changes inside the clip (offsets), so a pick does not straddle one.
        public var cuts: [Double]

        public init(duration: Double, moments: [MomentScore], cuts: [Double] = []) {
            self.duration = duration
            self.moments = moments.sorted { $0.time < $1.time }
            self.cuts = cuts
        }

        func score(of window: TimeSpan) -> Double {
            let inside = moments.filter { $0.time >= window.start - 0.01 && $0.time <= window.end + 0.01 }
            let base: Double
            if inside.isEmpty {
                base = moments.min { abs($0.time - window.start) < abs($1.time - window.start) }?.score ?? 0.5
            } else {
                // The mean, lifted by the best instant: one great second carries a shot.
                let mean = inside.map(\.score).reduce(0, +) / Double(inside.count)
                base = 0.7 * mean + 0.3 * (inside.map(\.score).max() ?? mean)
            }
            let straddles = cuts.contains { $0 > window.start + 0.3 && $0 < window.end - 0.3 }
            return straddles ? base * 0.45 : base
        }
    }

    public struct Pick: Hashable, Sendable {
        public var clipIndex: Int
        /// Offsets along the clip's span on the timeline.
        public var span: TimeSpan
    }

    /// Shot length for a recap of `target` seconds: short recaps cut faster.
    public static func shotLength(for target: Double) -> Double {
        (target / 9).clamped(to: 1.8...4.5)
    }

    public static func pick(clips: [Clip], target: Double) -> [Pick] {
        let length = shotLength(for: target)
        struct Candidate { var clipIndex: Int; var span: TimeSpan; var score: Double }
        var candidates: [Candidate] = []
        for (index, clip) in clips.enumerated() where clip.duration > 0.5 {
            if clip.duration <= length {
                candidates.append(Candidate(clipIndex: index, span: TimeSpan(start: 0, end: clip.duration), score: clip.score(of: TimeSpan(start: 0, end: clip.duration))))
                continue
            }
            var start = 0.0
            while start + length <= clip.duration + 0.001 {
                let span = TimeSpan(start: start, duration: length)
                candidates.append(Candidate(clipIndex: index, span: span, score: clip.score(of: span)))
                start += 0.5
            }
        }
        var picks: [Pick] = []
        var total = 0.0
        while total < target - 0.25, !candidates.isEmpty {
            guard let bestIndex = candidates.indices.max(by: { candidates[$0].score < candidates[$1].score }) else { break }
            let best = candidates[bestIndex]
            var span = best.span
            // The last shot only takes what the recap still needs.
            if total + span.duration > target + 0.5 { span = TimeSpan(start: span.start, duration: max(1.2, target - total)) }
            picks.append(Pick(clipIndex: best.clipIndex, span: span))
            total += span.duration
            // No overlaps, a breath between picks, and the rest of the recording gets its turn.
            candidates.removeAll { $0.clipIndex == best.clipIndex && $0.span.start < best.span.end + 1 && $0.span.end > best.span.start - 1 }
            for index in candidates.indices where candidates[index].clipIndex == best.clipIndex {
                let distance = abs(candidates[index].span.start - best.span.start)
                if distance < 12 { candidates[index].score *= 0.85 }
            }
        }
        return picks.sorted { ($0.clipIndex, $0.span.start) < ($1.clipIndex, $1.span.start) }
    }
}
