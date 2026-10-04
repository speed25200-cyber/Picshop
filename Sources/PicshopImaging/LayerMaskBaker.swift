import Foundation
import PicshopCore
#if canImport(CoreImage)
import CoreImage
#endif

/// D8 ("should"): after an autosave, bakes each changed layer-mask stack into masks/layer-<id>-<contentKey>.png
/// (≤ 2048 px, 8-bit) for the v1 projection, so a W2 build sees masked layers.
public enum LayerMaskBaker {
    /// The longest side of a baked mask.
    public static let maxSide = 2048
    /// Past this many layers with stacks, nothing is baked (the projection drops the masks).
    public static let maxLayers = 8
    /// One pass's time budget.
    public static let timeBudget: TimeInterval = 2

    /// The file a stack bakes to.
    public static func path(layerID: UUID, stack: MaskStack) -> String {
        "masks/layer-\(layerID.uuidString)-\(stack.contentKey).png"
    }

    /// Whether `layer.bakedMask` already holds its current stack (the projection then uses it, D3).
    public static func isFresh(_ layer: Layer) -> Bool {
        guard let stack = layer.maskStack, let baked = layer.bakedMask else { return false }
        return baked.relativePath == path(layerID: layer.id, stack: stack)
    }

    /// Deletes the layer's previous baked file. The session stores the results in Layer.bakedMask with amendPresent.
    /// Linked stacks (and the base's) are drawn in the layer's content space, where a W2 build applies a layer's
    /// mask; unlinked ones on other layers are not baked. Colour and luminance range components need the layer's
    /// pixels and are left out of the bake.
    public static func bake(_ document: PhotoDocument, store: ProjectStore, projectID: UUID) async -> [UUID: MaskReference] {
        #if canImport(CoreImage)
        let candidates = document.layers.filter { $0.maskStack.map { !$0.isEmpty } ?? false }
        guard !candidates.isEmpty, candidates.count <= maxLayers else { return [:] }
        let started = Date()
        let maskStore = MaskStore(store: store, projectID: projectID)
        let rasterizer = MaskRasterizer(maskStore: maskStore)
        var baked: [UUID: MaskReference] = [:]
        for layer in candidates where !isFresh(layer) || !FileManager.default.fileExists(atPath: store.url(for: layer.bakedMask?.relativePath ?? "", in: projectID).path) {
            guard Date().timeIntervalSince(started) < timeBudget, !Task.isCancelled else { break }
            guard let stack = layer.maskStack, layer.isMaskLinked || layer.id == document.baseLayerID || layer.isFill else { continue }
            let space = layer.isFill || layer.isAdjustment || layer.isGroup ? document.canvasSize
                : (LayerPlacement.contentSize(of: layer) ?? layer.imageAsset?.pixelSize ?? document.canvasSize)
            guard space.width > 0, space.height > 0 else { continue }
            let fitted = space.limited(toLongestSide: Double(maxSide))
            let width = max(1, Int(fitted.width.rounded())), height = max(1, Int(fitted.height.rounded()))
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            var mask = rasterizer.mask(stack, extent: rect, preLocal: nil, mode: .settled(target: nil), owner: layer.id)
            if let legacy = layer.mask, let legacyImage = maskStore.load(legacy, fitting: rect) {
                mask = PhotoRenderer.multiply(legacyImage, mask)
            }
            guard let bytes = ImageSupport.rawGrayBytes(of: mask, rect: rect),
                  let image = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else { continue }
            let reference = MaskReference(relativePath: path(layerID: layer.id, stack: stack), source: .brush,
                                          boundingBox: MaskStore.boundingBox(of: bytes, width: width, height: height), feather: 0)
            do {
                try maskStore.save(image, as: reference)
            } catch {
                continue
            }
            if let previous = layer.bakedMask?.relativePath, previous != reference.relativePath, previous.hasPrefix("masks/layer-") {
                try? FileManager.default.removeItem(at: store.url(for: previous, in: projectID))
            }
            baked[layer.id] = reference
        }
        return baked
        #else
        return [:]
        #endif
    }
}
