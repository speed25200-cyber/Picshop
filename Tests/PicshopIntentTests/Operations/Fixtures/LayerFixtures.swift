import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3: the layered poster the S lane and the layer tests run on (D19 refs in brackets, bottom → top):
/// the photo [i0] with its LUT, two masks (a1 sky, a2 bottom) and the subject selected; « SOLDES » [l1], the subtitle
/// [l2], a rectangle [s1]; « Tasse » [i1], a placed photo with a layer mask and a local adjustment [a3]; « Logo » [i2];
/// a white fill at 50 % [j1]; a black-to-clear gradient [j2]; Courbes [j3], Lumière [j4], Niveaux [j5],
/// Teinte/Saturation [j6], Étalonnage [j7], LUT [j8] and Look [j9] adjustment layers; a group « Groupe 1 » [g1]
/// holding a circle [s2] and a caption [l3]. The title is selected.
extension OperationFixtures {
    static let cupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID()
    static let logoID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2") ?? UUID()
    static let solidID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3") ?? UUID()
    static let gradientID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4") ?? UUID()
    static let curvesID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5") ?? UUID()
    static let lightID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C6") ?? UUID()
    static let levelsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C7") ?? UUID()
    static let hslID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C8") ?? UUID()
    static let gradeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C9") ?? UUID()
    static let lutLayerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CA") ?? UUID()
    static let lookID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CB") ?? UUID()
    static let circleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC") ?? UUID()
    static let captionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CD") ?? UUID()
    static let cupMaskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1") ?? UUID()

    static func photoWithLayers() -> PhotoDocument {
        var document = photoWithMasks()
        let selection = document.selection
        var cup = Layer(id: cupID, name: "Tasse", content: .image(MediaAsset(kind: .image, relativePath: "media/cup.png", pixelSize: PSSize(width: 800, height: 600))))
        cup.transform = LayerTransform(center: PSPoint(x: 0.3, y: 0.6), scale: 0.5)
        cup.maskStack = MaskStack.single(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4, feather: 0.2))))
        document.addLayer(cup, select: false)
        let rim = MaskSimulation.raster(.object, label: "cup", key: "fixture-cup", coverage: 0.4, document: document)
        document.setLocalAdjustment(LocalAdjustment(id: cupMaskID, region: .object, label: "cup", stack: MaskStack.single(MaskComponent(.raster(rim))),
                                                    adjustments: Adjustments([.exposure: 0.1])), label: "Mask: Cup", on: cupID)
        var logo = Layer(id: logoID, name: "Logo", content: .image(MediaAsset(kind: .image, relativePath: "media/logo.png", pixelSize: PSSize(width: 400, height: 400))))
        logo.transform = LayerTransform(center: PSPoint(x: 0.8, y: 0.15), scale: 0.3)
        document.addLayer(logo, select: false)
        document.addLayer(Layer(id: solidID, name: "Couleur unie", content: .fill(.white), opacity: 0.5), select: false)
        document.addLayer(Layer(id: gradientID, name: "Dégradé", content: .gradientFill(.blackToTransparent)), select: false)
        let kinds: [(UUID, AdjustmentLayerKind)] = [(curvesID, .curves), (lightID, .light), (levelsID, .levels), (hslID, .hsl), (gradeID, .colorGrade),
                                                    (lutLayerID, .lut), (lookID, .look)]
        for (id, kind) in kinds {
            var layer = Layer(id: id, name: kind.frenchName, content: .adjustment(.neutral), recipeKind: kind)
            if kind == .lut { layer.edits.append(.lut(LUTReference(relativePath: "media/lut-teal.cube", title: "Teal", intensity: 1))) }
            document.addLayer(layer, select: false)
        }
        document.addLayer(Layer(id: circleID, name: "Cercle", content: .shape(ShapeElement(kind: .ellipse))), select: false)
        var caption = TextElement(text: "Nouveau", relativeSize: 0.04, center: PSPoint(x: 0.2, y: 0.85))
        caption.maxRelativeWidth = 0.5
        document.addLayer(Layer(id: captionID, name: "Nouveau", content: .text(caption)), select: false)
        document.applyStructureEdit(.group([circleID, captionID], name: "Groupe 1"))
        document.selectedLayerID = titleID
        document.setSelection(selection)
        return document
    }

    /// The layered poster's context: its scene map with the text layers as the scene numbers them.
    static func layersContext(_ document: PhotoDocument) -> IntentContext {
        photoContext(document)
    }
}
