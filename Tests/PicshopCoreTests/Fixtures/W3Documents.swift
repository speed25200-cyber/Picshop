import Foundation
@testable import PicshopCore

/// Ten format 2 documents that together use every v2 feature (D2, D3): isolated, pass-through and collapsed groups,
/// clipping runs (on a layer and on a group, an invalid base), fill opacity, partial and inherited locks, gradient fills,
/// the seven adjustment-layer kinds, layer masks (linked, unlinked, disabled, baked), non-uniform scale, skew and quads,
/// newer contents and retained fields, ref numbers out of positional order, bundles inside groups. Ids are fixed.
enum W3Documents {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static let asset = MediaAsset(id: id(1), kind: .image, relativePath: "media/base.heic", pixelSize: PSSize(width: 4000, height: 3000))
    static let logo = MediaAsset(id: id(2), kind: .image, relativePath: "media/logo.png", pixelSize: PSSize(width: 800, height: 400))
    static let cup = MediaAsset(id: id(3), kind: .image, relativePath: "media/cup.png", pixelSize: PSSize(width: 1200, height: 1600))

    static let stack = MaskStack(components: [MaskComponent(id: id(80), .radial(RadialGradientSpec(center: PSPoint(x: 0.4, y: 0.5), radiusX: 0.3, radiusY: 0.2)))],
                                 feather: 0.1)

    /// A base photo document with fixed ids and dates.
    static func base(_ n: Int, title: String) -> PhotoDocument {
        var document = PhotoDocument(title: title, baseImage: asset)
        document.id = id(n * 100)
        document.layers[0].id = id(n * 100 + 1)
        document.selectedLayerID = id(n * 100 + 1)
        document.createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        document.modifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
        return document
    }

    static func image(_ n: Int, _ name: String, _ asset: MediaAsset = cup, transform: LayerTransform = LayerTransform(scale: 0.5)) -> Layer {
        Layer(id: id(n), name: name, content: .image(asset), transform: transform)
    }

    static func text(_ n: Int, _ words: String, center: PSPoint = PSPoint(x: 0.5, y: 0.3)) -> Layer {
        Layer(id: id(n), name: words, content: .text(TextElement(id: id(n + 5000), text: words, center: center)))
    }

    static func finish(_ document: PhotoDocument) -> PhotoDocument {
        DocumentCodec.migrated(document)
    }

    /// 1. An isolated group (multiply) with two children, one masked.
    static var groupsIsolated: PhotoDocument {
        var d = base(1, title: "isolated")
        var masked = image(103, "Tasse")
        masked.maskStack = stack
        d.layers += [image(102, "Logo", logo), masked,
                     Layer(id: id(104), name: "Groupe 1", content: .group(LayerFolder(passThrough: false)), opacity: 0.8, blendMode: .multiply)]
        d.layers[1].parentID = id(104)
        d.layers[2].parentID = id(104)
        return finish(d)
    }

    /// 2. A pass-through group, collapsed and hidden, with an adjustment layer inside.
    static var groupsPassThrough: PhotoDocument {
        var d = base(2, title: "pass-through")
        d.layers += [image(202, "Tasse"),
                     Layer(id: id(203), name: "Courbes", content: .adjustment(.neutral), recipeKind: .curves),
                     Layer(id: id(204), name: "Groupe 1", content: .group(LayerFolder(passThrough: true, isCollapsed: true)), opacity: 0.5, isVisible: false)]
        d.layers[1].parentID = id(204)
        d.layers[2].parentID = id(204)
        d.layers[2].edits.append(.toneCurve(.sCurve(strength: 0.5)))
        return finish(d)
    }

    /// 3. Clipping: two layers clipped onto an image, one clipped onto a group, one over an adjustment (invalid base).
    static var clipping: PhotoDocument {
        var d = base(3, title: "clipping")
        d.layers += [image(302, "Tasse"),
                     Layer(id: id(303), name: "Ombre", content: .fill(.black), opacity: 0.5, blendMode: .multiply, isClipped: true),
                     text(304, "Soldes"),
                     image(305, "Logo", logo),
                     Layer(id: id(306), name: "Groupe 1", content: .group(LayerFolder(passThrough: false))),
                     Layer(id: id(307), name: "Teinte", content: .fill(.red), isClipped: true),
                     Layer(id: id(308), name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.3])), recipeKind: .light),
                     Layer(id: id(309), name: "Voile", content: .fill(.white), opacity: 0.3, isClipped: true)]
        d.layers[3].isClipped = true
        d.layers[4].parentID = id(306)
        return finish(d)
    }

    /// 4. Fill opacity, partial locks, a locked group locking its child.
    static var fillAndLocks: PhotoDocument {
        var d = base(4, title: "fill")
        d.layers += [Layer(id: id(402), name: "Logo", content: .image(logo), transform: LayerTransform(scale: 0.6), opacity: 0.9, fillOpacity: 0.5),
                     Layer(id: id(403), name: "Titre", content: .text(TextElement(id: id(5403), text: "Titre")), lockOptions: [.position]),
                     Layer(id: id(404), name: "Forme", content: .shape(ShapeElement(kind: .rectangle)), lockOptions: [.pixels, .transparency]),
                     image(405, "Tasse"),
                     Layer(id: id(406), name: "Groupe 1", content: .group(LayerFolder()), isLocked: true)]
        d.layers[4].parentID = id(406)
        return finish(d)
    }

    /// 5. Gradient fills and the seven adjustment-layer kinds.
    static var gradientsAndAdjustments: PhotoDocument {
        var d = base(5, title: "gradients")
        d.layers.append(Layer(id: id(502), name: "Dégradé", content: .gradientFill(GradientFill(style: .radial, stops: [
            GradientStop(location: 0, color: .black), GradientStop(location: 0.4, color: PSColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 0.6)),
            GradientStop(location: 1, color: .clear)], angle: 30, scale: 80, center: PSPoint(x: 0.4, y: 0.6), reverse: true))))
        d.layers.append(Layer(id: id(503), name: "Dégradé 2", content: .gradientFill(.blackToTransparent), blendMode: .softLight))
        for (offset, kind) in AdjustmentLayerKind.allCases.enumerated() {
            var layer = Layer(id: id(510 + offset), name: kind.frenchName, content: .adjustment(kind == .light ? Adjustments([.contrast: 0.2]) : .neutral),
                              recipeKind: kind)
            switch kind {
            case .curves: layer.edits.append(.toneCurve(.sCurve(strength: 0.4)))
            case .levels: layer.edits.append(.levels(Levels(rgb: Levels.Channel(inBlack: 0.05, inWhite: 0.95, gamma: 1.1))))
            case .hsl: layer.edits.append(.colorMixer(ColorMixer()))
            case .colorGrade: layer.edits.append(.colorGrade(ColorGrade()))
            case .lut, .look, .light: break
            }
            d.layers.append(layer)
        }
        return finish(d)
    }

    /// 6. Layer masks: linked, unlinked, disabled, baked, on a group, a legacy mask.
    static var layerMasks: PhotoDocument {
        var d = base(6, title: "masks")
        var linked = image(602, "Tasse")
        linked.maskStack = stack
        var unlinked = image(603, "Logo", logo)
        unlinked.maskStack = stack
        unlinked.isMaskLinked = false
        var disabled = text(604, "Titre")
        disabled.maskStack = stack
        disabled.isMaskEnabled = false
        var baked = image(605, "Tasse 2")
        baked.maskStack = stack
        baked.bakedMask = MaskReference(id: id(690), relativePath: "masks/layer-\(id(605).uuidString)-\(stack.contentKey).png", source: .region("layer"))
        var legacy = Layer(id: id(606), name: "Voile", content: .fill(.black), opacity: 0.4,
                           mask: MaskReference(id: id(691), source: .subject, boundingBox: PSRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)))
        legacy.isMaskEnabled = true
        var group = Layer(id: id(607), name: "Groupe 1", content: .group(LayerFolder(passThrough: false)))
        group.maskStack = stack
        d.layers += [linked, unlinked, disabled, baked, legacy, group]
        return finish(d)
    }

    /// 7. Transforms: non-uniform scale, skew, flips, a quad on an image and on a text layer.
    static var transforms: PhotoDocument {
        var d = base(7, title: "transforms")
        d.layers += [
            image(702, "Large", logo, transform: LayerTransform(center: PSPoint(x: 0.3, y: 0.4), scale: 0.8, rotation: 20, scaleX: 1.5, scaleY: 0.75)),
            image(703, "Incliné", cup, transform: LayerTransform(center: PSPoint(x: 0.6, y: 0.5), scale: 0.4, isFlippedHorizontally: true, skewX: 20, skewY: -10)),
            image(704, "Perspective", logo, transform: LayerTransform(quad: [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.5, y: 0.15),
                                                                             PSPoint(x: 0.45, y: 0.5), PSPoint(x: 0.12, y: 0.4)])),
        ]
        var text = text(705, "Déformé")
        text.transform = LayerTransform(quad: [PSPoint(x: 0.6, y: 0.6), PSPoint(x: 0.9, y: 0.6), PSPoint(x: 0.9, y: 0.7), PSPoint(x: 0.6, y: 0.7)])
        d.layers.append(text)
        return finish(d)
    }

    /// 8. A newer build's content (in a group) and retained fields on the document, a layer and a transform.
    static var unsupportedAndRetained: PhotoDocument {
        var d = base(8, title: "newer")
        var styled = image(802, "Tasse")
        styled.retainedFields = ["zStyles": #"{"dropShadow":{"opacity":0.5}}"#]
        styled.transform.retainedFields = ["zWarp": "[1,2,3]"]
        d.layers += [styled,
                     Layer(id: id(803), name: "Objet", content: .unsupported(#"{"smartObject":{"_0":{"source":"media/x.psb"}}}"#)),
                     Layer(id: id(804), name: "Groupe 1", content: .group(LayerFolder()))]
        d.layers[2].parentID = id(804)
        d.retainedFields = ["zGuides": "[0.25,0.75]"]
        return finish(d)
    }

    /// 9. Ref numbers that are no longer positional (a deleted layer, a reorder) and a table bundle inside a group.
    static var refsAndBundles: PhotoDocument {
        var d = base(9, title: "refs")
        var first = image(902, "Tasse")
        first.refNumber = 3
        var second = image(903, "Logo", logo)
        second.refNumber = 1
        d.layers += [first, second]
        let bundle = id(990)
        for cell in 0..<6 {
            var layer = text(910 + cell, "\(cell)")
            layer.group = LayerGroup(id: bundle, kind: .tableCells, row: cell / 2 + 1, column: cell % 2 + 1)
            layer.parentID = id(920)
            d.layers.append(layer)
        }
        d.layers.append(Layer(id: id(920), name: "Tableau", content: .group(LayerFolder(passThrough: false))))
        return finish(d)
    }

    /// 10. Everything at once on one document.
    static var everything: PhotoDocument {
        var d = base(10, title: "everything")
        var masked = image(1002, "Tasse", transform: LayerTransform(center: PSPoint(x: 0.4, y: 0.5), scale: 0.7, rotation: -15, scaleX: 1.2, skewX: 8))
        masked.maskStack = stack
        masked.isMaskLinked = false
        masked.fillOpacity = 0.6
        masked.blendMode = .overlay
        masked.parentID = id(1006)
        var clipped = Layer(id: id(1003), name: "Couleur", content: .gradientFill(.twoColor(.red, .blue)), opacity: 0.5, isClipped: true)
        clipped.parentID = id(1006)
        var adjustment = Layer(id: id(1004), name: "Niveaux", content: .adjustment(.neutral), recipeKind: .levels)
        adjustment.parentID = id(1006)
        adjustment.edits.append(.levels(Levels(rgb: Levels.Channel(inBlack: 0.1))))
        d.layers += [masked, clipped, adjustment, text(1005, "Soldes"),
                     Layer(id: id(1006), name: "Groupe 1", content: .group(LayerFolder(passThrough: false)), opacity: 0.9, blendMode: .multiply,
                           lockOptions: [.position]),
                     Layer(id: id(1007), name: "Objet", content: .unsupported(#"{"vector":{"_0":{"path":"M0 0"}}}"#))]
        d.retainedFields = ["zComps": "[]"]
        return finish(d)
    }

    static var all: [(name: String, document: PhotoDocument)] {
        [("groupsIsolated", groupsIsolated), ("groupsPassThrough", groupsPassThrough), ("clipping", clipping), ("fillAndLocks", fillAndLocks),
         ("gradientsAndAdjustments", gradientsAndAdjustments), ("layerMasks", layerMasks), ("transforms", transforms),
         ("unsupportedAndRetained", unsupportedAndRetained), ("refsAndBundles", refsAndBundles), ("everything", everything)]
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The document as a file holds it (sorted keys, whole-second dates): what a reload sees.
    static func reloaded(_ document: PhotoDocument) throws -> PhotoDocument {
        try decoder().decode(PhotoDocument.self, from: try encoder().encode(document))
    }
}
