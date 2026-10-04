import Foundation

// D10 smart guides and snapping: canvas edges, centre, thirds, other layers' bounds, equal spacing. Pure,
// Linux-tested; L3 draws the guides and fires the haptic. Every value is canvas-normalised; the caller converts the
// 6 pt threshold to canvas units at the current zoom, per axis.

public struct SnapLine: Hashable, Sendable {
    public enum Source: Hashable, Sendable { case canvasEdge, canvasCenter, canvasThird, layer(UUID), spacing }

    /// Canvas-normalised x (vertical line) or y (horizontal line).
    public var value: Double
    public var source: Source

    public init(value: Double, source: Source) {
        self.value = value
        self.source = source
    }

    /// The canvas's own lines win a tie over a layer's (D10).
    var isCanvas: Bool {
        switch source {
        case .canvasEdge, .canvasCenter, .canvasThird: return true
        case .layer, .spacing: return false
        }
    }
}

public struct SnapTargets: Hashable, Sendable {
    public var vertical: [SnapLine]
    public var horizontal: [SnapLine]

    public init(vertical: [SnapLine] = [], horizontal: [SnapLine] = []) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

public struct SnapGuide: Hashable, Sendable {
    public enum Axis: Hashable, Sendable { case vertical, horizontal }

    public var axis: Axis
    public var line: SnapLine
    /// Along the other axis, canvas-normalised, for drawing.
    public var span: ClosedRange<Double>

    public init(axis: Axis, line: SnapLine, span: ClosedRange<Double>) {
        self.axis = axis
        self.line = line
        self.span = span
    }
}

public struct SnapResult: Hashable, Sendable {
    /// Canvas-normalised correction to add.
    public var offset: PSPoint
    public var guides: [SnapGuide]
    /// A new guide engaged this frame (haptic).
    public var didSnapNewly: Bool

    public init(offset: PSPoint = PSPoint(x: 0, y: 0), guides: [SnapGuide] = [], didSnapNewly: Bool = false) {
        self.offset = offset
        self.guides = guides
        self.didSnapNewly = didSnapNewly
    }
}

public enum SnapEngine {
    /// 6 pt, converted to canvas units at the current zoom by the caller.
    public static let thresholdPoints = 6.0
    /// A snapped axis releases beyond 1.5 × the threshold.
    public static let releaseFactor = 1.5
    /// Scale snaps to 100 % of the natural fit within 1.5 % (D10).
    public static let scaleTolerance = 0.015

    /// Canvas edges and centre, thirds when asked, and the axis-aligned bounds (edges and centres) of every other
    /// visible layer (locked or not) whose size is known: images from their asset, shapes from their canvas-relative
    /// size, text from `contentSizes` (L2's measure). The base photo (it is the canvas) and canvas-covering layers
    /// (fills, adjustments, groups) add nothing; a layer in a hidden group is hidden.
    public static func targets(in document: PhotoDocument, excluding: Set<UUID>, contentSizes: [UUID: PSSize],
                               includeThirds: Bool) -> SnapTargets {
        var vertical = [SnapLine(value: 0, source: .canvasEdge), SnapLine(value: 0.5, source: .canvasCenter), SnapLine(value: 1, source: .canvasEdge)]
        var horizontal = vertical
        if includeThirds {
            let thirds = [SnapLine(value: 1.0 / 3, source: .canvasThird), SnapLine(value: 2.0 / 3, source: .canvasThird)]
            vertical += thirds
            horizontal += thirds
        }
        let baseID = document.baseLayerID
        for layer in document.layers where layer.isVisible && layer.id != baseID && !excluding.contains(layer.id) {
            if let parent = document.parent(of: layer.id), !parent.isVisible || excluding.contains(parent.id) { continue }
            switch layer.content {
            case .image, .text, .shape: break
            case .fill, .gradientFill, .adjustment, .group, .unsupported: continue
            }
            guard let size = contentSizes[layer.id] ?? LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize), !size.isEmpty else { continue }
            let box = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
            guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else { continue }
            vertical += [box.minX, box.midX, box.maxX].map { SnapLine(value: $0, source: .layer(layer.id)) }
            horizontal += [box.minY, box.midY, box.maxY].map { SnapLine(value: $0, source: .layer(layer.id)) }
        }
        return SnapTargets(vertical: vertical, horizontal: horizontal)
    }

    /// Snap a moving box (canvas-normalised): its edges and centre against the lines, at most one guide per axis, the
    /// nearest (a canvas line wins a tie). `threshold` is in canvas-normalised units per axis; `previous` (the last
    /// frame's guides) gives the hysteresis: a snapped line holds until the box is more than `releaseFactor` ×
    /// the threshold from it. `didSnapNewly` is true when a guide engaged that the last frame did not have.
    public static func snapMove(_ box: PSRect, targets: SnapTargets, threshold: PSSize, previous: [SnapGuide]) -> SnapResult {
        let x = snap(candidates: [box.minX, box.midX, box.maxX], lines: targets.vertical, threshold: threshold.width,
                     previous: previous.first { $0.axis == .vertical })
        let y = snap(candidates: [box.minY, box.midY, box.maxY], lines: targets.horizontal, threshold: threshold.height,
                     previous: previous.first { $0.axis == .horizontal })
        var guides: [SnapGuide] = []
        if let line = x?.line { guides.append(SnapGuide(axis: .vertical, line: line, span: 0...1)) }
        if let line = y?.line { guides.append(SnapGuide(axis: .horizontal, line: line, span: 0...1)) }
        return SnapResult(offset: PSPoint(x: x?.offset ?? 0, y: y?.offset ?? 0), guides: guides, didSnapNewly: engagedNewly(guides, previous))
    }

    /// Snap one dragged edge (scaling) to the lines of its axis (`.vertical` for an x value): the snapped value and its
    /// guide, with the same hysteresis.
    public static func snapEdge(_ value: Double, axis: SnapGuide.Axis, targets: SnapTargets, threshold: Double,
                                previous: [SnapGuide]) -> (value: Double, guide: SnapGuide?) {
        let lines = axis == .vertical ? targets.vertical : targets.horizontal
        guard let snapped = snap(candidates: [value], lines: lines, threshold: threshold, previous: previous.first { $0.axis == axis }) else {
            return (value, nil)
        }
        return (value + snapped.offset, SnapGuide(axis: axis, line: snapped.line, span: 0...1))
    }

    /// Scale snaps to 100 % of the natural fit within `scaleTolerance` (D10).
    public static func snapScale(_ scale: Double) -> (scale: Double, snapped: Bool) {
        guard scale.isFinite, abs(scale - 1) <= scaleTolerance else { return (scale, false) }
        return (1, true)
    }

    /// Equal spacing on each axis ("should"): the box centred between its nearest neighbours on both sides, or at the
    /// gap two neighbours on one side already have, within the threshold. Neighbours count on an axis when they overlap
    /// the box on the other axis. Guides are `.spacing` lines at the middle of each equal gap, spanning the overlap.
    public static func equalSpacing(_ box: PSRect, neighbours: [PSRect], threshold: PSSize) -> (offset: PSPoint, guides: [SnapGuide]) {
        let horizontal = spacing(box, neighbours: neighbours, horizontal: true, threshold: threshold.width)
        let vertical = spacing(box, neighbours: neighbours, horizontal: false, threshold: threshold.height)
        return (PSPoint(x: horizontal?.offset ?? 0, y: vertical?.offset ?? 0), (horizontal?.guides ?? []) + (vertical?.guides ?? []))
    }

    // MARK: Internals

    /// The best line for a set of candidate positions: the held one while within the release distance, else the
    /// nearest within the threshold (canvas lines first on a tie).
    static func snap(candidates: [Double], lines: [SnapLine], threshold: Double, previous: SnapGuide?) -> (line: SnapLine, offset: Double)? {
        guard threshold.isFinite, threshold > 0, !candidates.isEmpty else { return nil }
        let finite = candidates.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        func nearestOffset(to line: SnapLine) -> Double {
            finite.map { line.value - $0 }.min { abs($0) < abs($1) } ?? .infinity
        }
        if let held = previous?.line, lines.contains(held) {
            let offset = nearestOffset(to: held)
            if abs(offset) <= threshold * releaseFactor { return (held, offset) }
        }
        var best: (line: SnapLine, offset: Double)?
        for line in lines where line.value.isFinite {
            let offset = nearestOffset(to: line)
            guard abs(offset) <= threshold else { continue }
            if let current = best {
                let delta = abs(offset) - abs(current.offset)
                if delta < -1e-12 || (abs(delta) <= 1e-12 && line.isCanvas && !current.line.isCanvas) { best = (line, offset) }
            } else {
                best = (line, offset)
            }
        }
        return best
    }

    static func engagedNewly(_ guides: [SnapGuide], _ previous: [SnapGuide]) -> Bool {
        guides.contains { guide in !previous.contains { $0.axis == guide.axis && $0.line == guide.line } }
    }

    /// One axis of `equalSpacing`.
    static func spacing(_ box: PSRect, neighbours: [PSRect], horizontal: Bool, threshold: Double) -> (offset: Double, guides: [SnapGuide])? {
        guard threshold.isFinite, threshold > 0 else { return nil }
        func low(_ r: PSRect) -> Double { horizontal ? r.minX : r.minY }
        func high(_ r: PSRect) -> Double { horizontal ? r.maxX : r.maxY }
        func crossLow(_ r: PSRect) -> Double { horizontal ? r.minY : r.minX }
        func crossHigh(_ r: PSRect) -> Double { horizontal ? r.maxY : r.maxX }
        let overlapping = neighbours.filter { crossHigh($0) > crossLow(box) && crossLow($0) < crossHigh(box) }
        let before = overlapping.filter { high($0) <= low(box) + threshold }.sorted { high($0) > high($1) }
        let after = overlapping.filter { low($0) >= high(box) - threshold }.sorted { low($0) < low($1) }
        var options: [(offset: Double, gaps: [(from: Double, to: Double, cross: PSRect)])] = []
        let length = high(box) - low(box)
        if let left = before.first, let right = after.first {
            // Centred between its two nearest neighbours.
            let target = (high(left) + low(right) - length) / 2
            let gap = target - high(left)
            if gap >= 0 { options.append((target - low(box), [(high(left), target, left), (target + length, low(right), right)])) }
        }
        if before.count >= 2 {
            // The gap the two neighbours before it already have.
            let near = before[0], far = before[1]
            let gap = low(near) - high(far)
            if gap >= 0 { options.append((high(near) + gap - low(box), [(high(far), low(near), far), (high(near), high(near) + gap, near)])) }
        }
        if after.count >= 2 {
            let near = after[0], far = after[1]
            let gap = low(far) - high(near)
            if gap >= 0 { options.append((low(near) - gap - length - low(box), [(low(near) - gap, low(near), near), (high(near), low(far), far)])) }
        }
        guard let best = options.filter({ abs($0.offset) <= threshold }).min(by: { abs($0.offset) < abs($1.offset) }) else { return nil }
        let guides = best.gaps.map { gap -> SnapGuide in
            let lowCross = max(crossLow(box), crossLow(gap.cross)), highCross = min(crossHigh(box), crossHigh(gap.cross))
            return SnapGuide(axis: horizontal ? .vertical : .horizontal, line: SnapLine(value: (gap.from + gap.to) / 2, source: .spacing),
                             span: min(lowCross, highCross)...max(lowCross, highCross))
        }
        return (best.offset, guides)
    }
}
