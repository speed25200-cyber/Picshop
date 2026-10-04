import Foundation
import PicshopCore

/// D19 re-grounding: after a step that changed the base geometry (a crop, a turn, a flip, a perspective), later steps'
/// canvas coordinates (`point`, `box`, `center`, `corners`, gradient handles, `EditIntent.region` and
/// `ObjectTarget.point`) are mapped from the old canvas to the new one through
/// M = inverse(old chain) ∘ new chain, the map D10b moves the layers with. A step whose point or box left the canvas
/// gives nil: the caller answers « Ce que tu visais n'est plus dans le cadre ». Stored refs (i2, a1, o1, l1) need
/// nothing: they name things, not places.
public enum RefRegrounder {
    /// What the caller says when a step's target left the canvas.
    public static func leftTheCanvas(french: Bool) -> String {
        french ? "Ce que tu visais n'est plus dans le cadre." : "What you pointed at is no longer in the frame."
    }

    /// Canvas-normalised before → after through the base's geometry chains; nil when unchanged (or when the base's
    /// pixels were replaced by a merge, which keeps the canvas).
    public static func geometryMap(from before: PhotoDocument, to after: PhotoDocument) -> PSHomography? {
        guard let old = before.baseLayer, let new = after.baseLayer, old.id == new.id,
              old.imageAsset?.relativePath == new.imageAsset?.relativePath else { return nil }
        let oldGeometry = old.edits.operations.filter(\.kind.isGeometric).map(\.kind)
        let newGeometry = new.edits.operations.filter(\.kind.isGeometric).map(\.kind)
        guard oldGeometry != newGeometry else { return nil }
        let aspect = sourceAspect(old)
        guard let back = old.edits.geometryChain(sourceAspect: aspect).map.inverse else { return nil }
        return back.then(new.edits.geometryChain(sourceAspect: aspect).map)
    }

    static func sourceAspect(_ layer: Layer) -> Double {
        guard let size = layer.imageAsset?.pixelSize, size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    /// Ops whose point lists are not canvas places (a curve's points are tones).
    static let nonCanvasPoints: Set<OpID> = ["curves"]

    /// The call with its canvas points and boxes mapped; nil when what it aimed at left the canvas.
    public static func regrounded(_ call: OperationCall, by map: PSHomography) -> OperationCall? {
        guard !nonCanvasPoints.contains(call.id), let spec = OperationCatalog.shared.spec(call.id) else { return call }
        var result = call
        for param in spec.params {
            guard let value = call.args[param.key] else { continue }
            switch param.kind {
            case .point:
                guard let mapped = point(value, by: map) else { return nil }
                result.args[param.key] = mapped
            case .box:
                guard let mapped = box(value, by: map) else { return nil }
                result.args[param.key] = mapped
            case .list(.point, _):
                guard case .list(let items) = value else { continue }
                var points: [OpValue] = []
                for item in items {
                    guard let mapped = point(item, by: map) else { return nil }
                    points.append(mapped)
                }
                result.args[param.key] = .list(points)
            case .enumeration, .number, .integer, .boolean, .color, .text, .ref, .list:
                continue
            }
        }
        return result
    }

    /// The intent with its target point, region and operation mapped; nil when what it aimed at left the canvas.
    public static func regrounded(_ intent: EditIntent, by map: PSHomography) -> EditIntent? {
        var result = intent
        if let point = intent.target?.point {
            let mapped = map.apply(point)
            guard inside(mapped) else { return nil }
            result.target?.point = clamped(mapped)
        }
        if let region = intent.region {
            guard let mapped = rect(region, by: map) else { return nil }
            result.region = mapped
        }
        if let call = intent.operation {
            guard let mapped = regrounded(call, by: map) else { return nil }
            result.operation = mapped
        }
        return result
    }

    // MARK: Maths

    /// A little slack for points on the edge (rounding).
    static let tolerance = 0.002

    static func inside(_ point: PSPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= -tolerance && point.x <= 1 + tolerance && point.y >= -tolerance && point.y <= 1 + tolerance
    }

    static func clamped(_ point: PSPoint) -> PSPoint {
        PSPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1))
    }

    /// A 0…1000 point through the map, nil when it lands off the canvas.
    static func point(_ value: OpValue, by map: PSHomography) -> OpValue? {
        let raw: PSPoint
        switch value {
        case .point(let point): raw = point
        case .list(let pair) where pair.count == 2:
            guard let x = pair[0].double, let y = pair[1].double else { return value }
            raw = PSPoint(x: x, y: y)
        default:
            return value
        }
        let mapped = map.apply(PSPoint(x: raw.x / 1000, y: raw.y / 1000))
        guard inside(mapped) else { return nil }
        let kept = clamped(mapped)
        return .point(PSPoint(x: kept.x * 1000, y: kept.y * 1000))
    }

    /// A 0…1000 box through the map (the bounding box of its mapped corners, cut to the canvas); nil when nothing of it
    /// is left on the canvas.
    static func box(_ value: OpValue, by map: PSHomography) -> OpValue? {
        let rect: PSRect
        switch value {
        case .box(let box): rect = box
        case .list(let items) where items.count == 4:
            let corners = items.compactMap(\.double)
            guard corners.count == 4 else { return value }
            rect = PSRect(x: corners[0], y: corners[1], width: corners[2] - corners[0], height: corners[3] - corners[1])
        default:
            return value
        }
        let unit = PSRect(x: rect.minX / 1000, y: rect.minY / 1000, width: rect.width / 1000, height: rect.height / 1000)
        guard let mapped = self.rect(unit, by: map) else { return nil }
        return .box(PSRect(x: mapped.minX * 1000, y: mapped.minY * 1000, width: mapped.width * 1000, height: mapped.height * 1000))
    }

    /// A normalised rect through the map, cut to the unit square; nil when less than 1 % of each side is left.
    static func rect(_ rect: PSRect, by map: PSHomography) -> PSRect? {
        let corners = [PSPoint(x: rect.minX, y: rect.minY), PSPoint(x: rect.maxX, y: rect.minY), PSPoint(x: rect.maxX, y: rect.maxY), PSPoint(x: rect.minX, y: rect.maxY)]
            .map(map.apply)
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let minX = max(0, corners.map(\.x).min()!), maxX = min(1, corners.map(\.x).max()!)
        let minY = max(0, corners.map(\.y).min()!), maxY = min(1, corners.map(\.y).max()!)
        guard maxX - minX > 0.01, maxY - minY > 0.01 else { return nil }
        return PSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
