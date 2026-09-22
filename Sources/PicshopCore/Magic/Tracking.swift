import Foundation

/// Where a tracked thing is at one instant of the timeline.
public struct TrackSample: Hashable, Codable, Sendable {
    public var time: Double
    /// Normalised frame position, top-left origin.
    public var point: PSPoint

    public init(time: Double, point: PSPoint) {
        self.time = time
        self.point = point
    }
}

/// The path of something moving in the picture, so an overlay can stay
/// attached to it: a name above a face, an arrow on a ball, a sticker on
/// a hat. The overlay keeps the place it was given at `anchorTime` and
/// moves by however far the subject has moved since.
public struct TrackingPath: Hashable, Codable, Sendable {
    public var samples: [TrackSample]
    public var anchorTime: Double

    public init(samples: [TrackSample], anchorTime: Double) {
        self.samples = samples.sorted { $0.time < $1.time }
        self.anchorTime = anchorTime
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var span: TimeSpan { TimeSpan(start: samples.first?.time ?? 0, end: samples.last?.time ?? 0) }

    /// The subject's position at `time`; held at the ends of the path.
    public func point(at time: Double) -> PSPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.point }
        if time >= last.time { return last.point }
        // Binary search for the pair around `time`.
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high]
        let t = b.time > a.time ? (time - a.time) / (b.time - a.time) : 0
        return PSPoint(x: a.point.x + (b.point.x - a.point.x) * t, y: a.point.y + (b.point.y - a.point.y) * t)
    }

    /// How far the subject has moved since the anchor, in normalised frame units.
    public func offset(at time: Double) -> PSPoint {
        guard let here = point(at: time), let anchor = point(at: anchorTime) else { return PSPoint(x: 0, y: 0) }
        return PSPoint(x: here.x - anchor.x, y: here.y - anchor.y)
    }

    /// Tracker output with the jitter taken out: a centred moving average
    /// over `radius` samples each side, which keeps real motion and drops
    /// the pixel-level wobble a tracker adds.
    public static func smoothed(_ samples: [TrackSample], radius: Int = 2) -> [TrackSample] {
        let sorted = samples.sorted { $0.time < $1.time }
        guard sorted.count > 2, radius > 0 else { return sorted }
        return sorted.indices.map { index in
            let window = sorted[max(0, index - radius)...min(sorted.count - 1, index + radius)]
            let x = window.reduce(0) { $0 + $1.point.x } / Double(window.count)
            let y = window.reduce(0) { $0 + $1.point.y } / Double(window.count)
            return TrackSample(time: sorted[index].time, point: PSPoint(x: x, y: y))
        }
    }
}
