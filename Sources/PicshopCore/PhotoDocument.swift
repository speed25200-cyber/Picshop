import Foundation

/// A complete, serialisable photo project.
public struct PhotoDocument: Hashable, Codable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var title: String
    /// Canvas size in pixels. Equals the base image size unless cropped/upscaled.
    public var canvasSize: PSSize
    public var backgroundColor: PSColor
    public var layers: [Layer]
    public var selectedLayerID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), title: String, canvasSize: PSSize, backgroundColor: PSColor = .clear,
                layers: [Layer] = [], selectedLayerID: UUID? = nil, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.formatVersion = Self.formatVersion
        self.title = title
        self.canvasSize = canvasSize
        self.backgroundColor = backgroundColor
        self.layers = layers
        self.selectedLayerID = selectedLayerID ?? layers.first?.id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Convenience: a document with a single image layer.
    public init(title: String, baseImage: MediaAsset) {
        let layer = Layer(name: "Photo", content: .image(baseImage))
        self.init(title: title, canvasSize: baseImage.pixelSize, layers: [layer], selectedLayerID: layer.id)
    }

    // MARK: Layer access

    public var baseLayer: Layer? { layers.first(where: { $0.isImage }) }
    public var baseLayerID: UUID? { baseLayer?.id }

    public var selectedLayer: Layer? {
        guard let selectedLayerID else { return baseLayer }
        return layers.first(where: { $0.id == selectedLayerID }) ?? baseLayer
    }

    /// The layer voice commands and tools act on: the selection if it is an image
    /// layer, otherwise the base photo.
    public var activeImageLayerID: UUID? {
        if let selected = selectedLayer, selected.isImage { return selected.id }
        return baseLayerID
    }

    public func layer(id: UUID) -> Layer? {
        layers.first(where: { $0.id == id })
    }

    public func index(of layerID: UUID) -> Int? {
        layers.firstIndex(where: { $0.id == layerID })
    }

    public mutating func update(layerID: UUID, _ body: (inout Layer) -> Void) {
        guard let index = index(of: layerID) else { return }
        body(&layers[index])
        touch()
    }

    /// Appends an operation to the active image layer.
    public mutating func apply(_ kind: EditOperation.Kind, label: String? = nil, to layerID: UUID? = nil) {
        guard let target = layerID ?? activeImageLayerID else { return }
        update(layerID: target) { layer in
            layer.edits.append(kind, label: label)
        }
        if case .crop(let rect) = kind, target == baseLayerID {
            canvasSize = PSSize(width: (canvasSize.width * rect.width).rounded(), height: (canvasSize.height * rect.height).rounded())
        }
        if case .upscale(let factor) = kind, target == baseLayerID {
            canvasSize = PSSize(width: (canvasSize.width * factor).rounded(), height: (canvasSize.height * factor).rounded())
        }
        if case .rotate(let degrees) = kind, target == baseLayerID, Int(degrees.rounded()) % 180 == 90 || Int(degrees.rounded()) % 180 == -90 {
            canvasSize = PSSize(width: canvasSize.height, height: canvasSize.width)
        }
    }

    public mutating func addLayer(_ layer: Layer, select: Bool = true) {
        layers.append(layer)
        if select { selectedLayerID = layer.id }
        touch()
    }

    @discardableResult
    public mutating func removeLayer(id: UUID) -> Layer? {
        guard let index = index(of: id), !(layers[index].isImage && index == 0) else { return nil }
        let removed = layers.remove(at: index)
        if selectedLayerID == id { selectedLayerID = baseLayerID }
        touch()
        return removed
    }

    public mutating func moveLayer(id: UUID, to newIndex: Int) {
        guard let index = index(of: id), newIndex >= 0, newIndex < layers.count, index != newIndex else { return }
        let layer = layers.remove(at: index)
        layers.insert(layer, at: newIndex)
        touch()
    }

    public mutating func touch() {
        modifiedAt = Date()
    }

    /// Effective adjustments of the active image layer (what the sliders show).
    public var activeAdjustments: Adjustments {
        guard let id = activeImageLayerID, let layer = layer(id: id) else { return .neutral }
        return layer.edits.resolvedAdjustments
    }

    public var textLayers: [Layer] { layers.filter(\.isText) }

    /// Aspect ratio of the current canvas.
    public var aspectRatio: Double { canvasSize.aspectRatio }
}
