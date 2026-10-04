import Foundation

// The rows the Layers column and the Layers inspector list, and where a dragged row lands (D17). Shared by both
// views so they agree; pure, Linux-tested.

public struct LayerRowModel: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// 0 top level, 1 inside a group.
    public var depth: Int
    public var isGroup: Bool
    public var isClipped: Bool
    /// Hidden by a collapsed group.
    public var isCollapsedChild: Bool
    /// A table bundle row (D1): its member count; nil otherwise.
    public var bundleCount: Int?

    public init(id: UUID, depth: Int = 0, isGroup: Bool = false, isClipped: Bool = false, isCollapsedChild: Bool = false,
                bundleCount: Int? = nil) {
        self.id = id
        self.depth = depth
        self.isGroup = isGroup
        self.isClipped = isClipped
        self.isCollapsedChild = isCollapsedChild
        self.bundleCount = bundleCount
    }
}

public enum LayerReorder {
    /// Rows top → bottom as the UI lists them: a group's row, then its children (depth 1, `isCollapsedChild` when
    /// the group is collapsed: the views leave those out); one row per table bundle at its topmost member's place, with
    /// that member's id and the bundle's size (D1); the base photo last.
    public static func rows(for document: PhotoDocument) -> [LayerRowModel] {
        var bundleSizes: [UUID: Int] = [:]
        var bundleTops: [UUID: UUID] = [:]
        for layer in document.layers {
            guard let group = layer.group else { continue }
            bundleSizes[group.id, default: 0] += 1
            bundleTops[group.id] = layer.id
        }
        var rows: [LayerRowModel] = []
        for layer in document.layers.reversed() {
            var bundleCount: Int?
            if let group = layer.group {
                guard bundleTops[group.id] == layer.id else { continue }
                bundleCount = bundleSizes[group.id]
            }
            let parent = document.parent(of: layer.id)
            rows.append(LayerRowModel(id: layer.id, depth: parent == nil ? 0 : 1, isGroup: layer.isGroup, isClipped: layer.isClipped,
                                      isCollapsedChild: parent?.folder?.isCollapsed == true, bundleCount: bundleCount))
        }
        return rows
    }

    /// Where a dragged row lands when dropped at row index `slot` (0 = above the top row; k = above the k-th row), with
    /// slots counted over the rows the views show (collapsed children left out), the dragged row still in the list.
    /// The row below the slot decides: above it, in its group when it is a child; right under an expanded empty group's
    /// row, into that group. Nil when not allowed or nothing would move: the base photo, a slot under the base, a
    /// group into a group, an order lock, or the dragged block's own place. A clip base moves with its clipped run and
    /// a bundle as a whole (`applyStructureEdit(.move)`).
    public static func drop(_ dragged: UUID, atRowSlot slot: Int, in document: PhotoDocument) -> LayerPlacementSpec? {
        guard document.layer(id: dragged) != nil, dragged != document.baseLayerID else { return nil }
        let visible = rows(for: document).filter { !$0.isCollapsedChild }
        guard slot >= 0, slot <= visible.count else { return nil }
        // The block that moves and the rows it covers.
        let block = Set(document.block(of: dragged))
        let blockRows = visible.indices.filter { index in
            let id = visible[index].id
            return block.contains(id) || document.bundle(containing: id).map { $0.memberIDs.contains(dragged) } == true
        }
        if let first = blockRows.first, let last = blockRows.last, slot >= first, slot <= last + 1 { return nil }
        // Under the base photo (the last row): never.
        if slot == visible.count, let base = document.baseLayerID, visible.last?.id == base { return nil }
        let spec: LayerPlacementSpec
        if slot == 0 {
            spec = .top
        } else if let group = document.layer(id: visible[slot - 1].id), group.isGroup, group.folder?.isCollapsed != true,
                  document.children(of: group.id).isEmpty {
            spec = .into(groupID: group.id)
        } else if slot < visible.count {
            spec = .above(visible[slot].id)
        } else {
            return nil
        }
        var trial = document
        guard case .applied = trial.applyStructureEdit(.move(dragged, to: spec)).outcome else { return nil }
        return spec
    }
}
