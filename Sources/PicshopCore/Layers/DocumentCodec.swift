import Foundation

// D2 and D3: the document-v2.json envelope (lossless), its header (read first), the lossy v1 projection written to
// project.json, the digest that detects an older build's save, the merge, and the migration to format 2.

/// document-v2.json: `{"format":"picshop.photo","formatVersion":2,"minorVersion":0,"writer":…,"v1Digest":…,"document":{…}}`.
public struct PhotoDocumentEnvelope: Codable, Sendable {
    public static let fileName = "document-v2.json"
    public static let format = "picshop.photo"

    public var format: String
    public var formatVersion: Int
    public var minorVersion: Int
    /// "PicShop <version> (<build>)", "PicShop" alone on Linux.
    public var writer: String
    /// `DocumentCodec.digest` of project.json's bytes when this file was written.
    public var v1Digest: String
    public var document: PhotoDocument

    public init(document: PhotoDocument, v1Digest: String, writer: String) {
        self.format = Self.format
        self.formatVersion = PhotoDocument.formatVersion
        self.minorVersion = 0
        self.writer = writer
        self.v1Digest = v1Digest
        self.document = document
    }

    /// The writer string for this build (Bundle.main's short version and build number).
    static var currentWriter: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "PicShop" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "PicShop \(version) (\($0))" } ?? "PicShop \(version)"
    }
}

/// D2: decoded before the document, so a newer build's file is recognised whatever its document holds.
public struct PhotoDocumentEnvelopeHeader: Decodable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var minorVersion: Int?
    public var v1Digest: String?

    public init(format: String, formatVersion: Int, minorVersion: Int? = nil, v1Digest: String? = nil) {
        self.format = format
        self.formatVersion = formatVersion
        self.minorVersion = minorVersion
        self.v1Digest = v1Digest
    }
}

public enum DocumentCodec {
    /// Where a loaded photo document came from (D2).
    public enum LoadSource: String, Sendable, Equatable { case v2, merged, v1, newerFormat }

    /// D3: what project.json holds, always decodable by a W2 build. Groups and newer contents are dropped (their
    /// children stay, folded), gradients become their first stop's colour, fill folds into opacity, clipping, partial
    /// locks, layer masks (unless freshly baked, `maskFileExists`), skew, quads, kinds, ref numbers and retained
    /// fields go. Every projected field is at its default, so the encoders write no v2 key. A document using no v2
    /// feature projects to itself (format 1).
    public static func v1Projection(of document: PhotoDocument) -> PhotoDocument {
        v1Projection(of: document, maskFileExists: { _ in false })
    }

    /// `v1Projection(of:)` where a baked layer mask (D8) is kept as the v1 `mask` when its file exists in the package
    /// (`maskFileExists` gets its relative path). ProjectStore passes the package check.
    public static func v1Projection(of document: PhotoDocument, maskFileExists: (String) -> Bool) -> PhotoDocument {
        var projected = document
        projected.formatVersion = 1
        projected.retainedFields = [:]
        projected.layers = document.layers.compactMap { projectLayer($0, in: document, maskFileExists: maskFileExists) }
        if let selected = projected.selectedLayerID, projected.layer(id: selected) == nil { projected.selectedLayerID = projected.baseLayerID }
        return projected
    }

    /// D3 per layer, with its group's folding (nil: dropped). Baked masks are not kept (see the overload).
    public static func projectLayer(_ layer: Layer, in document: PhotoDocument) -> Layer? {
        projectLayer(layer, in: document, maskFileExists: { _ in false })
    }

    /// D3 per layer; the merge compares an older build's layer with this, field by field.
    public static func projectLayer(_ layer: Layer, in document: PhotoDocument, maskFileExists: (String) -> Bool) -> Layer? {
        var projected = layer
        switch layer.content {
        case .group, .unsupported:
            return nil
        case .gradientFill(let gradient):
            projected.content = .fill(gradient.stops.first?.color ?? .clear)
        case .image, .text, .shape, .adjustment, .fill:
            break
        }
        // The group folds into its children: opacity multiplies, a hidden group hides them, its mask goes.
        if let parent = document.parent(of: layer.id) {
            projected.opacity *= parent.opacity
            if !parent.isVisible { projected.isVisible = false }
        }
        projected.opacity = (projected.opacity * (layer.isGroup ? 1 : layer.fillOpacity)).clamped(to: 0...1)
        projected.fillOpacity = 1
        projected.parentID = nil
        projected.isClipped = false
        projected.lockOptions = []
        // Masks: an enabled stack shows in a W2 build only through its fresh baked raster.
        if let stack = layer.maskStack, !stack.isEmpty {
            if layer.isMaskEnabled, let baked = layer.bakedMask, baked.relativePath.contains(stack.contentKey), maskFileExists(baked.relativePath) {
                projected.mask = baked
            }
        }
        if !layer.isMaskEnabled { projected.mask = nil }
        projected.maskStack = nil
        projected.isMaskEnabled = true
        projected.isMaskLinked = true
        projected.bakedMask = nil
        projected.recipeKind = nil
        projected.refNumber = nil
        projected.retainedFields = [:]
        projectTransform(&projected, in: document)
        return projected
    }

    /// "<byte count>-<16 hex FNV-1a 64>" of project.json's bytes.
    public static func digest(_ data: Data) -> String {
        "\(data.count)-\(StableHash.hex(bytes: data))"
    }

    /// D2, used when the digests differ (an older build saved project.json after the last W3 save): v1 is the truth,
    /// and v2-only state comes back where the older build left a layer untouched.
    public static func merge(v1: PhotoDocument, v2: PhotoDocument) -> PhotoDocument {
        merge(v1: v1, v2: v2, maskFileExists: { _ in false })
    }

    /// The merge, with the mask-file check the projection used when saving.
    public static func merge(v1: PhotoDocument, v2: PhotoDocument, maskFileExists: (String) -> Bool) -> PhotoDocument {
        var result = v1
        result.formatVersion = PhotoDocument.formatVersion
        result.retainedFields = v2.retainedFields
        let v2ByID = Dictionary(v2.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 1–2. A layer the older build left as it was projected takes its v2 self back.
        var fromV2: Set<UUID> = []
        result.layers = v1.layers.map { v1Layer in
            guard let v2Layer = v2ByID[v1Layer.id], projectLayer(v2Layer, in: v2, maskFileExists: maskFileExists) == v1Layer else { return v1Layer }
            fromV2.insert(v1Layer.id)
            return v2Layer
        }
        // 3b. Layers the projection dropped that are not groups (newer contents) come back first, above their nearest
        // lower v2 neighbour that survives (else at their v2 index), with their parent: they keep their group alive.
        for (v2Index, layer) in v2.layers.enumerated() where !layer.isGroup && projectLayer(layer, in: v2, maskFileExists: maskFileExists) == nil {
            guard !result.layers.contains(where: { $0.id == layer.id }) else { continue }
            insert(layer, after: v2.layers[..<v2Index], v2Index: v2Index, into: &result.layers)
            fromV2.insert(layer.id)
        }
        // 3. A group comes back above its topmost surviving child; a group that had children is dropped when none
        // survives, one that had none in v2 comes back at its v2 place. A parent left dangling is cleared by the
        // normalisation in step 4.
        for (v2Index, group) in v2.layers.enumerated() where group.isGroup {
            let children = v2.layers.filter { $0.parentID == group.id }.map(\.id)
            guard !children.isEmpty else {
                insert(group, after: v2.layers[..<v2Index], v2Index: v2Index, into: &result.layers)
                continue
            }
            let survivors = children.filter { id in result.layers.contains { $0.id == id } }
            guard let topmost = survivors.compactMap({ id in result.layers.firstIndex { $0.id == id } }).max() else { continue }
            for id in survivors {
                guard let index = result.layers.firstIndex(where: { $0.id == id }) else { continue }
                if !fromV2.contains(id) {
                    // An older build edited it: its opacity carries the group's folded in (D3); unfold it.
                    if group.opacity > 1e-9 { result.layers[index].opacity = (result.layers[index].opacity / group.opacity).clamped(to: 0...1) }
                }
                result.layers[index].parentID = group.id
            }
            result.layers.insert(group, at: topmost + 1)
        }
        // 4. Document fields come from v1 (the struct is v1's); layers an older build added get the next free numbers.
        result = migrated(result)
        if let selected = result.selectedLayerID, result.layer(id: selected) == nil { result.selectedLayerID = result.baseLayerID }
        return result
    }

    /// D2, D7, D19: format 2 in memory (idempotent). The text-behind « Subject » cut-out locked in v1 keeps following
    /// the base with a position lock only; the tree is normalised; layers without a stored ref number get one, bottom
    /// → top per prefix, which for a v1 document is the W2 positional numbering.
    public static func migrated(_ document: PhotoDocument) -> PhotoDocument {
        var migrated = document
        migrated.formatVersion = PhotoDocument.formatVersion
        let baseID = migrated.baseLayerID
        for index in migrated.layers.indices {
            let layer = migrated.layers[index]
            if layer.name == PhotoDocument.subjectLayerName, layer.isLocked, layer.isImage, layer.id != baseID {
                migrated.layers[index].isLocked = false
                migrated.layers[index].lockOptions.insert(.position)
            }
        }
        migrated.normalizeLayerTree()
        migrated.assignMissingRefNumbers()
        return migrated
    }

    /// Whether document-v2.json must be written (D2, D19): any layer using v2-only state (newer contents included),
    /// retained document fields, or stored ref numbers that differ from the positional numbering a reload would give.
    public static func needsV2(_ document: PhotoDocument) -> Bool {
        if !document.retainedFields.isEmpty || document.layers.contains(where: \.usesV2State) { return true }
        guard document.layers.contains(where: { $0.refNumber != nil }) else { return false }
        let positional = document.positionalRefNumbers
        return document.layers.contains { layer in
            guard let number = layer.refNumber else { return false }
            return positional[layer.id] != number
        }
    }

    // MARK: Internals

    /// Puts a v2 layer back above its nearest lower v2 neighbour already in `layers`, else at its v2 index.
    static func insert(_ layer: Layer, after lowerNeighbours: ArraySlice<Layer>, v2Index: Int, into layers: inout [Layer]) {
        let lower = lowerNeighbours.reversed().first { candidate in layers.contains { $0.id == candidate.id } }
        if let lower, let index = layers.firstIndex(where: { $0.id == lower.id }) {
            layers.insert(layer, at: index + 1)
        } else {
            layers.insert(layer, at: min(v2Index, layers.count))
        }
    }

    /// D3's transform: scaleX/Y folded into the uniform scale (√|sx·sy|), skew dropped; a quad becomes its centroid,
    /// the angle of its top edge and the scale of its area over the fitted content's (flips off). A text layer's centre
    /// and rotation live in its element.
    static func projectTransform(_ layer: inout Layer, in document: PhotoDocument) {
        let transform = layer.transform
        var projected = LayerTransform(center: transform.center, scale: transform.scale, rotation: transform.rotation,
                                       isFlippedHorizontally: transform.isFlippedHorizontally, isFlippedVertically: transform.isFlippedVertically)
        if let quad = transform.quad, quad.count == 4 {
            let canvas = document.canvasSize
            let width = max(canvas.width, 1), height = max(canvas.height, 1)
            let center = PSPoint(x: quad.reduce(0) { $0 + $1.x } / 4, y: quad.reduce(0) { $0 + $1.y } / 4)
            let rotation = atan2((quad[1].y - quad[0].y) * height, (quad[1].x - quad[0].x) * width) * 180 / .pi
            projected.isFlippedHorizontally = false
            projected.isFlippedVertically = false
            projected.center = center
            projected.rotation = abs(rotation) < 1e-12 ? 0 : rotation
            if let size = LayerPlacement.contentSize(of: layer, canvasSize: canvas), !size.isEmpty {
                let fit = LayerPlacement.fitScale(contentSize: size, canvasSize: canvas)
                let area = PhotoSelection.quadArea(quad.map { PSPoint(x: $0.x * width, y: $0.y * height) })
                let scale = (area / (fit * size.width * fit * size.height)).squareRoot()
                if scale.isFinite, scale > 0 { projected.scale = scale }
            }
            if case .text(var element) = layer.content {
                element.center = center
                element.rotation = projected.rotation
                layer.content = .text(element)
                projected.center = transform.center
                projected.rotation = transform.rotation
            }
        } else {
            let product = abs(transform.scaleX * transform.scaleY)
            if product.isFinite, product > 0 { projected.scale = transform.scale * product.squareRoot() }
        }
        layer.transform = projected
    }
}
