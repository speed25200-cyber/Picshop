import Foundation

/// Where faces are at one moment of a clip, for anonymising them.
public struct FaceSample: Hashable, Codable, Sendable {
    /// Seconds in the clip's source file.
    public var time: Double
    /// Normalised boxes in the upright source frame, top-left origin.
    public var boxes: [PSRect]

    public init(time: Double, boxes: [PSRect]) {
        self.time = time
        self.boxes = boxes
    }
}

/// Faces blurred through a clip — for people who did not ask to be filmed.
public enum FaceBlur {
    /// The faces to hide at `time` (source seconds): the nearer of the two
    /// samples around it, both when they disagree, grown so hair and chin
    /// are covered too. A face seen in neither sample within `reach` is left.
    public static func boxes(in samples: [FaceSample], at time: Double, reach: Double = 0.3, growth: Double = 0.35) -> [PSRect] {
        guard !samples.isEmpty else { return [] }
        let before = samples.last { $0.time <= time }
        let after = samples.first { $0.time > time }
        var found: [PSRect] = []
        if let before, time - before.time <= reach { found += before.boxes }
        if let after, after.time - time <= reach {
            // A face appearing in the next sample is covered a little early rather than late.
            found += after.boxes.filter { box in !found.contains { $0.iou(box) > 0.3 } }
        }
        return found.map { box in
            box.insetBy(dx: -box.width * growth / 2, dy: -box.height * growth / 2).clampedToUnit()
        }
    }
}
