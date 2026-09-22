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
        if case .expand(let placement) = kind, target == baseLayerID, placement.width > 0.05, placement.height > 0.05 {
            canvasSize = PSSize(width: (canvasSize.width / placement.width).rounded(), height: (canvasSize.height / placement.height).rounded())
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
    public var shapeLayers: [Layer] { layers.filter(\.isShape) }

    /// Aspect ratio of the current canvas.
    public var aspectRatio: Double { canvasSize.aspectRatio }
}

// MARK: - Text behind the subject

extension PhotoDocument {
    /// Name of the cut-out copy of the subject laid over the title.
    public static let subjectLayerName = "Subject"

    /// The Lock Screen depth effect: a big title, with the subject cut out and
    /// laid on top of it so the words pass behind the person. A given `text`
    /// makes a new title; without one the latest title is reused, or a
    /// `placeholder` is written. Returns the title layer's id.
    @discardableResult
    public mutating func placeTextBehindSubject(_ text: String?, subjectMask: MaskReference, placeholder: String) -> UUID? {
        guard let base = baseLayer, let asset = base.imageAsset else { return nil }
        layers.removeAll { $0.name == Self.subjectLayerName }
        var titleID = text == nil ? textLayers.last?.id : nil
        if titleID == nil {
            let words = (text?.isEmpty == false ? text : nil) ?? placeholder
            let element = TextElement(text: words, relativeSize: words.count > 8 ? 0.14 : 0.2, color: .white, style: .plain,
                                      center: PSPoint(x: 0.5, y: 0.32), letterSpacing: -0.03, lineSpacing: 0.9, maxRelativeWidth: 0.96)
            let layer = Layer(name: element.text, content: .text(element))
            addLayer(layer, select: false)
            titleID = layer.id
        }
        var subject = Layer(name: Self.subjectLayerName, content: .image(asset), isLocked: true, edits: base.edits)
        subject.edits.append(.removeBackground(subjectMask))
        addLayer(subject, select: false)
        selectedLayerID = titleID
        return titleID
    }
}
