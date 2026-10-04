import Foundation

// D11: the only place the render order is decided. Pure; L2 executes it on CIImages (the actor render and the
// snapshot frames), L1's CompositeReference on small float rasters for the Linux tests.

/// How one layer is drawn: its opacity, fill, blend mode and whether a mask applies.
public struct LayerDraw: Hashable, Sendable {
    public var layerID: UUID
    public var opacity: Double
    public var fillOpacity: Double
    public var blendMode: BlendMode
    /// Legacy mask or an enabled stack.
    public var hasMask: Bool
    /// W3 (D5): a group used as a clipping base: its children's nodes, whose isolated composite (through the group's
    /// mask) is the base's content. Empty for every other draw.
    public var groupChildren: [CompositeNode]

    public init(layerID: UUID, opacity: Double, fillOpacity: Double, blendMode: BlendMode, hasMask: Bool, groupChildren: [CompositeNode] = []) {
        self.layerID = layerID
        self.opacity = opacity
        self.fillOpacity = fillOpacity
        self.blendMode = blendMode
        self.hasMask = hasMask
        self.groupChildren = groupChildren
    }

    /// The layer's own draw settings (a group's fill is 1, D4).
    public init(_ layer: Layer) {
        self.init(layerID: layer.id, opacity: layer.opacity, fillOpacity: layer.isGroup ? 1 : layer.fillOpacity, blendMode: layer.blendMode,
                  hasMask: layer.mask != nil || (layer.isMaskEnabled && layer.maskStack.map { !$0.isEmpty } == true))
    }
}

public indirect enum CompositeNode: Hashable, Sendable {
    case layer(LayerDraw)
    case adjustment(LayerDraw)
    /// clipped: .layer or .adjustment only (D5).
    case clippingGroup(base: LayerDraw, clipped: [CompositeNode])
    /// children: .layer, .adjustment, .clippingGroup (D4).
    case group(LayerDraw, passThrough: Bool, children: [CompositeNode])

    /// Every layer the node draws, bottom → top.
    public var layerIDs: [UUID] {
        switch self {
        case .layer(let draw), .adjustment(let draw): return [draw.layerID]
        case .clippingGroup(let base, let clipped): return base.groupChildren.flatMap(\.layerIDs) + [base.layerID] + clipped.flatMap(\.layerIDs)
        case .group(let draw, _, let children): return children.flatMap(\.layerIDs) + [draw.layerID]
        }
    }
}

public enum CompositePlan {
    /// D11: the visible document bottom → top, the base first. Per sibling list (the top level, then each group's
    /// children):
    /// - hidden layers and newer contents are skipped; a hidden group hides its children;
    /// - an adjustment layer is `.adjustment`; a group is `.group` (isolated or pass-through) over its children, or
    ///   nothing when none of them draws;
    /// - a layer with visible clipped layers resting on it (D5) is `.clippingGroup(base:clipped:)`; a hidden base
    ///   hides its clipped run, a hidden clipped layer is skipped, and a clipped layer whose base is invalid (an
    ///   adjustment layer, none) is drawn unclipped.
    public static func make(_ document: PhotoDocument) -> [CompositeNode] {
        var childrenByGroup: [UUID: [Layer]] = [:]
        var topLevel: [Layer] = []
        let groupIDs = Set(document.layers.filter(\.isGroup).map(\.id))
        for layer in document.layers {
            if let parentID = layer.parentID, parentID != layer.id, groupIDs.contains(parentID), !layer.isGroup {
                childrenByGroup[parentID, default: []].append(layer)
            } else {
                topLevel.append(layer)
            }
        }
        return nodes(for: topLevel, childrenByGroup: childrenByGroup)
    }

    /// One sibling list, bottom → top.
    static func nodes(for siblings: [Layer], childrenByGroup: [UUID: [Layer]]) -> [CompositeNode] {
        var result: [CompositeNode] = []
        var index = 0
        while index < siblings.count {
            let layer = siblings[index]
            index += 1
            // A clipped layer resting on a valid base was taken with that base's run (below).
            if PhotoDocument.clips(layer), base(below: index - 1, in: siblings) != nil { continue }
            guard layer.isVisible, !layer.content.isUnsupported else {
                // A hidden (or undrawable) base hides its clipped run: skip it with the base.
                if PhotoDocument.canBeClipBase(layer) || !layer.isVisible {
                    while index < siblings.count, PhotoDocument.clips(siblings[index]), base(below: index, in: siblings)?.id == layer.id { index += 1 }
                }
                continue
            }
            guard let node = node(for: layer, childrenByGroup: childrenByGroup) else {
                // An empty group: its clipped run still has a base that draws nothing.
                while index < siblings.count, PhotoDocument.clips(siblings[index]), base(below: index, in: siblings)?.id == layer.id { index += 1 }
                continue
            }
            // The clipped run on this layer.
            var clipped: [CompositeNode] = []
            if PhotoDocument.canBeClipBase(layer) {
                while index < siblings.count, PhotoDocument.clips(siblings[index]), base(below: index, in: siblings)?.id == layer.id {
                    let member = siblings[index]
                    index += 1
                    guard member.isVisible, !member.content.isUnsupported else { continue }
                    clipped.append(member.isAdjustment ? .adjustment(LayerDraw(member)) : .layer(LayerDraw(member)))
                }
            }
            if clipped.isEmpty {
                result.append(node)
            } else if case .group(let draw, _, let children) = node {
                // A group base: its isolated composite is the base's content (D5).
                var base = draw
                base.groupChildren = children
                result.append(.clippingGroup(base: base, clipped: clipped))
            } else {
                result.append(.clippingGroup(base: LayerDraw(layer), clipped: clipped))
            }
        }
        return result
    }

    /// A layer's own node (no clipping): nil for a group with nothing to draw.
    static func node(for layer: Layer, childrenByGroup: [UUID: [Layer]]) -> CompositeNode? {
        switch layer.content {
        case .group(let folder):
            let children = nodes(for: childrenByGroup[layer.id] ?? [], childrenByGroup: [:])
            guard !children.isEmpty else { return nil }
            return .group(LayerDraw(layer), passThrough: folder.passThrough, children: children)
        case .adjustment:
            return .adjustment(LayerDraw(layer))
        case .image, .text, .shape, .fill, .gradientFill:
            return .layer(LayerDraw(layer))
        case .unsupported:
            return nil
        }
    }

    /// D5 within one sibling list: the nearest unclipped sibling below `index` when it can be a base.
    static func base(below index: Int, in siblings: [Layer]) -> Layer? {
        var below = index - 1
        while below >= 0 {
            let candidate = siblings[below]
            if !PhotoDocument.clips(candidate) { return PhotoDocument.canBeClipBase(candidate) ? candidate : nil }
            below -= 1
        }
        return nil
    }
}
