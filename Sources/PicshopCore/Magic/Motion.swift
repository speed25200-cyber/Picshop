import Foundation

/// Easing between two keyframes.
public enum MotionEasing: String, Codable, Sendable, CaseIterable {
    case linear
    case easeInOut
    case easeOut

    public func apply(_ t: Double) -> Double {
        let t = t.clamped(to: 0...1)
        switch self {
        case .linear: return t
        case .easeInOut: return t * t * (3 - 2 * t)
        case .easeOut: return 1 - (1 - t) * (1 - t)
        }
    }
}

/// Where the virtual camera looks at one moment of a clip.
///
/// `focus` is the point of the source frame (0…1, y down) placed at the centre
/// of the output; `zoom` multiplies the scale that fills the output frame.
public struct MotionKeyframe: Hashable, Codable, Sendable {
    /// Seconds from the start of the clip on the timeline.
    public var time: Double
    public var focus: PSPoint
    public var zoom: Double
    public var easing: MotionEasing

    public init(time: Double, focus: PSPoint = PSPoint(x: 0.5, y: 0.5), zoom: Double = 1, easing: MotionEasing = .easeInOut) {
        self.time = max(0, time)
        self.focus = PSPoint(x: focus.x.clamped(to: 0...1), y: focus.y.clamped(to: 0...1))
        self.zoom = zoom.clamped(to: 1...6)
        self.easing = easing
    }
}

/// Animated framing of a clip: Ken Burns moves, subject-following reframes
/// and hand-set keyframes all use the same description.
public struct ClipMotion: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case kenBurns
        case smartReframe
        case manual
        /// A still, tighter frame after a jump cut (zoom cuts).
        case punchIn
    }

    public var kind: Kind
    /// Keyframes sorted by time.
    public var keyframes: [MotionKeyframe]

    public init(kind: Kind, keyframes: [MotionKeyframe]) {
        self.kind = kind
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public var isEmpty: Bool { keyframes.isEmpty }

    /// Interpolated framing at `time` seconds into the clip.
    public func sample(at time: Double) -> (focus: PSPoint, zoom: Double) {
        guard let first = keyframes.first else { return (PSPoint(x: 0.5, y: 0.5), 1) }
        guard keyframes.count > 1, time > first.time else { return (first.focus, first.zoom) }
        guard let last = keyframes.last, time < last.time else { return (keyframes[keyframes.count - 1].focus, keyframes[keyframes.count - 1].zoom) }
        let upper = keyframes.firstIndex { $0.time > time } ?? keyframes.count - 1
        let a = keyframes[upper - 1]
        let b = keyframes[upper]
        let t = b.easing.apply((time - a.time) / max(1e-6, b.time - a.time))
        let focus = PSPoint(x: a.focus.x + (b.focus.x - a.focus.x) * t, y: a.focus.y + (b.focus.y - a.focus.y) * t)
        // Zoom interpolates geometrically so a push-in feels constant-speed.
        let zoom = exp(log(a.zoom) + (log(b.zoom) - log(a.zoom)) * t)
        return (focus, zoom)
    }

    /// The output-frame crop (in source units, 0…1) for a framing, given the
    /// source and output aspect ratios. The window never leaves the source.
    public static func window(focus: PSPoint, zoom: Double, sourceAspect: Double, outputAspect: Double) -> PSRect {
        // Fill: the window has the output's aspect and touches the source on one axis.
        var width = 1.0
        var height = 1.0
        if outputAspect < sourceAspect {
            width = outputAspect / sourceAspect
        } else {
            height = sourceAspect / outputAspect
        }
        width /= max(1, zoom)
        height /= max(1, zoom)
        let x = (focus.x - width / 2).clamped(to: 0...(1 - width))
        let y = (focus.y - height / 2).clamped(to: 0...(1 - height))
        return PSRect(x: x, y: y, width: width, height: height)
    }

    /// A slow, cinematic push with a gentle drift, different for every clip
    /// (`variant` picks the direction) so a sequence of stills never repeats.
    public static func kenBurns(duration: Double, variant: Int = 0, strength: Double = 1) -> ClipMotion {
        let amount = 0.12 * strength.clamped(to: 0...2)
        let directions: [(PSPoint, PSPoint, Bool)] = [
            (PSPoint(x: 0.45, y: 0.5), PSPoint(x: 0.55, y: 0.46), true),
            (PSPoint(x: 0.56, y: 0.46), PSPoint(x: 0.46, y: 0.54), false),
            (PSPoint(x: 0.5, y: 0.56), PSPoint(x: 0.5, y: 0.44), true),
            (PSPoint(x: 0.46, y: 0.44), PSPoint(x: 0.54, y: 0.52), false),
        ]
        let (from, to, zoomIn) = directions[((variant % directions.count) + directions.count) % directions.count]
        let start = MotionKeyframe(time: 0, focus: from, zoom: zoomIn ? 1 : 1 + amount, easing: .linear)
        let end = MotionKeyframe(time: max(0.1, duration), focus: to, zoom: zoomIn ? 1 + amount : 1, easing: .linear)
        return ClipMotion(kind: .kenBurns, keyframes: [start, end])
    }
}

/// Where the subject is in one analysed frame.
public struct FocusSample: Hashable, Codable, Sendable {
    public var time: Double
    public var point: PSPoint
    /// 0 = nothing found (hold the camera), 1 = sure.
    public var confidence: Double

    public init(time: Double, point: PSPoint, confidence: Double = 1) {
        self.time = time
        self.point = point
        self.confidence = confidence.clamped(to: 0...1)
    }
}

/// Turns per-frame subject positions into a calm camera path, the way a
/// camera operator reframes a landscape shot for a vertical screen: hold still
/// while the subject stays in the middle of the frame, glide when it leaves,
/// never jitter.
public struct SmartReframe: Sendable {
    /// Fraction of the output window the subject may wander in before the camera moves.
    public var deadZone: Double
    /// Seconds for the camera to settle on a new position.
    public var responsiveness: Double
    /// Fastest pan, in output widths per second.
    public var maximumSpeed: Double

    public init(deadZone: Double = 0.18, responsiveness: Double = 0.6, maximumSpeed: Double = 0.9) {
        self.deadZone = deadZone
        self.responsiveness = max(0.05, responsiveness)
        self.maximumSpeed = max(0.05, maximumSpeed)
    }

    public func path(samples: [FocusSample], duration: Double, sourceAspect: Double, outputAspect: Double) -> ClipMotion {
        let window = ClipMotion.window(focus: PSPoint(x: 0.5, y: 0.5), zoom: 1, sourceAspect: sourceAspect, outputAspect: outputAspect)
        let halfWidth = window.width / 2
        let halfHeight = window.height / 2
        let rangeX = halfWidth...(1 - halfWidth)
        let rangeY = halfHeight...(1 - halfHeight)
        let sorted = samples.sorted { $0.time < $1.time }
        guard !sorted.isEmpty, duration > 0 else {
            return ClipMotion(kind: .smartReframe, keyframes: [MotionKeyframe(time: 0)])
        }

        // 1. Resample onto a regular 10 Hz grid, holding the last confident position.
        let step = 0.1
        let count = max(2, Int((duration / step).rounded(.up)) + 1)
        var targets: [PSPoint] = []
        targets.reserveCapacity(count)
        var held = sorted.first { $0.confidence > 0.2 }?.point ?? PSPoint(x: 0.5, y: 0.5)
        var cursor = 0
        for index in 0..<count {
            let time = Double(index) * step
            while cursor < sorted.count, sorted[cursor].time <= time + step / 2 {
                if sorted[cursor].confidence > 0.2 { held = sorted[cursor].point }
                cursor += 1
            }
            targets.append(held)
        }

        // 2. Dead zone: the camera only chases the subject once it leaves the calm centre.
        let zoneX = window.width * deadZone
        let zoneY = window.height * deadZone
        var camera = PSPoint(x: targets[0].x.clamped(to: rangeX), y: targets[0].y.clamped(to: rangeY))
        var desired: [PSPoint] = []
        for target in targets {
            var next = camera
            if target.x > camera.x + zoneX { next.x = target.x - zoneX } else if target.x < camera.x - zoneX { next.x = target.x + zoneX }
            if target.y > camera.y + zoneY { next.y = target.y - zoneY } else if target.y < camera.y - zoneY { next.y = target.y + zoneY }
            camera = PSPoint(x: next.x.clamped(to: rangeX), y: next.y.clamped(to: rangeY))
            desired.append(camera)
        }

        // 3. Zero-phase exponential smoothing (forward then backward) and a speed limit.
        let alpha = 1 - exp(-step / responsiveness)
        var smoothed = desired
        for index in 1..<smoothed.count {
            smoothed[index].x = smoothed[index - 1].x + alpha * (smoothed[index].x - smoothed[index - 1].x)
            smoothed[index].y = smoothed[index - 1].y + alpha * (smoothed[index].y - smoothed[index - 1].y)
        }
        for index in stride(from: smoothed.count - 2, through: 0, by: -1) {
            smoothed[index].x = smoothed[index + 1].x + alpha * (smoothed[index].x - smoothed[index + 1].x)
            smoothed[index].y = smoothed[index + 1].y + alpha * (smoothed[index].y - smoothed[index + 1].y)
        }
        let maximumStep = maximumSpeed * window.width * step
        for index in 1..<smoothed.count {
            let dx = (smoothed[index].x - smoothed[index - 1].x).clamped(to: -maximumStep...maximumStep)
            let dy = (smoothed[index].y - smoothed[index - 1].y).clamped(to: -maximumStep...maximumStep)
            smoothed[index] = PSPoint(x: (smoothed[index - 1].x + dx).clamped(to: rangeX), y: (smoothed[index - 1].y + dy).clamped(to: rangeY))
        }

        // 4. Keep only the keyframes needed to describe the path.
        let points = smoothed.enumerated().map { (Double($0.offset) * step, $0.element) }
        let kept = Self.simplify(points, tolerance: 0.004)
        let keyframes = kept.map { MotionKeyframe(time: min($0.0, duration), focus: $0.1, zoom: 1, easing: .linear) }
        return ClipMotion(kind: .smartReframe, keyframes: keyframes)
    }

    /// Ramer–Douglas–Peucker on (time, point) with distance measured in frame units.
    static func simplify(_ points: [(Double, PSPoint)], tolerance: Double) -> [(Double, PSPoint)] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let (t0, p0) = points[first]
            let (t1, p1) = points[last]
            var worst = 0.0
            var worstIndex = first
            for index in first + 1..<last {
                let (t, p) = points[index]
                let u = (t - t0) / max(1e-9, t1 - t0)
                let x = p0.x + (p1.x - p0.x) * u
                let y = p0.y + (p1.y - p0.y) * u
                let distance = max(abs(p.x - x), abs(p.y - y))
                if distance > worst {
                    worst = distance
                    worstIndex = index
                }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((first, worstIndex))
                stack.append((worstIndex, last))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }
}
