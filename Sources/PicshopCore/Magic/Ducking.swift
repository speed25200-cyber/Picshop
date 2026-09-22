import Foundation

/// A music level at a moment of the timeline; the mixer ramps linearly between points.
public struct VolumePoint: Hashable, Sendable {
    public var time: Double
    public var level: Double

    public init(time: Double, level: Double) {
        self.time = time
        self.level = level
    }
}

/// Automatic ducking, as a broadcast mixer does it: the music sits at its
/// level while nobody talks, dips under every sentence and comes back
/// after it. Short gaps between words are bridged so the music does not
/// pump between them.
public enum Ducking {
    /// Speech ranges cleaned for ducking: sorted, gaps shorter than `bridge` joined, blips dropped.
    public static func regions(from speech: [TimeSpan], bridge: Double = 0.9, shortest: Double = 0.25) -> [TimeSpan] {
        var joined: [TimeSpan] = []
        for span in speech.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = joined.last, span.start - last.end < bridge {
                joined[joined.count - 1] = TimeSpan(start: last.start, end: max(last.end, span.end))
            } else {
                joined.append(span)
            }
        }
        return joined.filter { $0.duration >= shortest }
    }

    /// Levels for one music track over `span` (timeline seconds): `level` in
    /// the clear, `level × (1 − amount)` under speech, with the track's fades.
    /// The dip starts `attack` before the voice and recovers over `release`.
    public static func envelope(span: TimeSpan, level: Double, amount: Double, speech: [TimeSpan],
                                fadeIn: Double = 0, fadeOut: Double = 0, attack: Double = 0.25, release: Double = 0.6) -> [VolumePoint] {
        guard span.duration > 0 else { return [] }
        let ducked = level * (1 - amount.clamped(to: 0...1))
        let spoken = regions(from: speech, bridge: max(0.9, attack + release + 0.05))
            .compactMap { region -> TimeSpan? in
                let clipped = TimeSpan(start: max(region.start, span.start), end: min(region.end, span.end))
                return clipped.duration > 0 ? clipped : nil
            }

        // The ducking curve on its own, as breakpoints.
        var duck: [VolumePoint] = [VolumePoint(time: span.start, level: level)]
        for region in spoken {
            let dipStart = max(span.start, region.start - attack)
            if dipStart <= span.start {
                duck[0].level = ducked
            } else {
                duck.append(VolumePoint(time: dipStart, level: level))
            }
            duck.append(VolumePoint(time: max(region.start, dipStart), level: ducked))
            duck.append(VolumePoint(time: region.end, level: ducked))
            if region.end + release <= span.end {
                duck.append(VolumePoint(time: region.end + release, level: level))
            } else if region.end < span.end {
                // The track ends while the music is still coming back up.
                let recovered = release > 0 ? (span.end - region.end) / release : 1
                duck.append(VolumePoint(time: span.end, level: ducked + (level - ducked) * recovered))
            }
        }
        if let last = duck.last, last.time < span.end { duck.append(VolumePoint(time: span.end, level: level)) }

        // Fades multiply the curve; sampling at every corner of both keeps it exact enough.
        var times = Set(duck.map(\.time))
        if fadeIn > 0 { times.insert(min(span.end, span.start + fadeIn)) }
        if fadeOut > 0 { times.insert(max(span.start, span.end - fadeOut)) }
        let sorted = times.filter { $0 >= span.start && $0 <= span.end }.sorted()
        return sorted.map { time in
            var fade = 1.0
            if fadeIn > 0 { fade = min(fade, (time - span.start) / fadeIn) }
            if fadeOut > 0 { fade = min(fade, (span.end - time) / fadeOut) }
            return VolumePoint(time: time, level: max(0, fade.clamped(to: 0...1) * value(of: duck, at: time)))
        }
    }

    /// Linear interpolation over breakpoints; where two share a time, the later one wins after it.
    static func value(of points: [VolumePoint], at time: Double) -> Double {
        guard let first = points.first else { return 0 }
        if time <= first.time { return first.level }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            if time <= b.time {
                guard b.time > a.time else { return b.level }
                return a.level + (b.level - a.level) * (time - a.time) / (b.time - a.time)
            }
        }
        return points.last?.level ?? first.level
    }

    /// Voice ranges from a loudness envelope: everything that is not a pause.
    /// Nil when nobody seems to speak at all.
    public static func speech(in envelope: LoudnessEnvelope, duration: Double) -> [TimeSpan]? {
        guard envelope.percentile(0.95) > -55 else { return nil }
        let detector = SilenceDetector(minimumSilence: 0.35, padding: 0.05, sensitivity: 0.3)
        guard detector.threshold(for: envelope) != nil else {
            // No pauses at all: someone talks throughout.
            return [TimeSpan(start: 0, end: duration)]
        }
        var speech: [TimeSpan] = []
        var cursor = 0.0
        for silence in detector.silentRanges(in: envelope) {
            if silence.start > cursor { speech.append(TimeSpan(start: cursor, end: min(silence.start, duration))) }
            cursor = max(cursor, silence.end)
        }
        if cursor < duration { speech.append(TimeSpan(start: cursor, end: duration)) }
        return speech.filter { $0.duration > 0.05 }
    }
}
