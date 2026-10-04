import XCTest
@testable import PicshopCore

/// What the Layers column, the Layers inspector and the transform handles say (W3 §7.12): the row labels in both
/// languages, the handles' names, values and VoiceOver steps, the HUD's figures.
final class LayerAccessibilityTests: XCTestCase {
    private let base = MediaAsset(kind: .image, relativePath: "media/base.jpg", pixelSize: PSSize(width: 4000, height: 3000))

    /// A photo with a mug layer (80 %, multiply, clipped onto a fill, masked, locked) and the given extra layers.
    private func document(selectMug: Bool = true) -> (PhotoDocument, Layer) {
        var document = PhotoDocument(title: "Test", baseImage: base)
        let fill = Layer(name: "Fond bleu", content: .fill(.blue))
        document.layers.append(fill)
        let mug = Layer(name: "Tasse", content: .image(MediaAsset(kind: .image, relativePath: "media/mug.png", pixelSize: PSSize(width: 800, height: 600))),
                        opacity: 0.8, blendMode: .multiply, isLocked: true, maskStack: MaskStack(), isClipped: true)
        document.layers.append(mug)
        document.selectedLayerID = selectMug ? mug.id : nil
        return (document, mug)
    }

    // MARK: Rows

    func testTheContractLabelInFrenchAndEnglish() {
        let (document, mug) = document()
        XCTAssertEqual(LayerAccessibility.label(for: mug, in: document, isSelected: true, language: .fr),
                       "Tasse, calque d'image, 80 %, produit, écrêté, masque, verrouillé, sélectionné")
        XCTAssertEqual(LayerAccessibility.label(for: mug, in: document, isSelected: true, language: .en),
                       "Tasse, image layer, 80%, multiply, clipped, mask, locked, selected")
    }

    func testDefaultsSayNothingButTheNameAndKind() {
        let (document, _) = document()
        let fill = document.layers[1]
        XCTAssertEqual(LayerAccessibility.label(for: fill, in: document, isSelected: false, language: .fr), "Fond bleu, calque de remplissage")
        let photo = document.layers[0]
        XCTAssertEqual(LayerAccessibility.label(for: photo, in: document, isSelected: false, language: .fr), "Photo de fond")
        XCTAssertEqual(LayerAccessibility.label(for: photo, in: document, isSelected: true, language: .en), "Background photo, selected")
    }

    func testHiddenFillPartialLockAndDisabledMask() {
        var (document, mug) = document()
        document.update(layerID: mug.id) { layer in
            layer.isLocked = false
            layer.lockOptions = [.position]
            layer.isVisible = false
            layer.fillOpacity = 0.5
            layer.isMaskEnabled = false
            layer.opacity = 1
            layer.blendMode = .normal
            layer.isClipped = false
        }
        mug = document.layer(id: mug.id)!
        XCTAssertEqual(LayerAccessibility.label(for: mug, in: document, isSelected: false, language: .fr),
                       "Tasse, calque d'image, fond 50 %, masque désactivé, position verrouillée, masqué")
        XCTAssertEqual(LayerAccessibility.label(for: mug, in: document, isSelected: false, language: .en),
                       "Tasse, image layer, fill 50%, mask off, position locked, hidden")
    }

    func testAGroupCountsItsChildrenAndPassesItsLockDown() {
        var (document, mug) = document()
        let group = Layer(name: "Groupe 1", content: .group(LayerFolder()), isLocked: true)
        document.update(layerID: mug.id) { layer in
            layer.parentID = group.id
            layer.isLocked = false
            layer.isClipped = false
        }
        document.layers.append(group)
        document.normalizeLayerTree()
        XCTAssertEqual(LayerAccessibility.label(for: group, in: document, isSelected: false, language: .fr), "Groupe 1, groupe, 1 calque, verrouillé")
        // The child inherits the group's lock (D7).
        mug = document.layer(id: mug.id)!
        XCTAssertTrue(LayerAccessibility.label(for: mug, in: document, isSelected: false, language: .en).hasSuffix("locked"))
    }

    func testAdjustmentGradientAndBundleKinds() {
        var document = PhotoDocument(title: "Test", baseImage: base)
        let curves = Layer(name: "Courbes 1", content: .adjustment(.neutral), recipeKind: .curves)
        let gradient = Layer(name: "", content: .gradientFill(.blackToTransparent))
        document.layers += [curves, gradient]
        XCTAssertEqual(LayerAccessibility.kindName(curves, language: .fr), "calque de réglage Courbes")
        XCTAssertEqual(LayerAccessibility.kindName(curves, language: .en), "Curves adjustment layer")
        XCTAssertEqual(LayerAccessibility.displayName(gradient, language: .fr), "Calque de dégradé")
        let bundleID = UUID()
        var cells: [Layer] = []
        for index in 0..<3 {
            var cell = Layer(name: "r1 c\(index + 1)", content: .text(TextElement(text: "\(index)")))
            cell.group = LayerGroup(id: bundleID, kind: .tableCells, row: 1, column: index + 1)
            cells.append(cell)
        }
        document.layers += cells
        XCTAssertEqual(LayerAccessibility.label(for: cells[2], in: document, isSelected: false, language: .fr), "Tableau · 3 cases, tableau")
        XCTAssertEqual(LayerAccessibility.label(for: cells[2], in: document, isSelected: false, language: .en), "Table · 3 cells, table")
    }

    func testColumnActions() {
        XCTAssertEqual(LayerAccessibility.visibilityAction(isVisible: true, language: .fr), "Masquer")
        XCTAssertEqual(LayerAccessibility.visibilityAction(isVisible: false, language: .fr), "Afficher")
        XCTAssertEqual(LayerAccessibility.visibilityAction(isVisible: true, language: .en), "Hide")
        XCTAssertEqual(LayerAccessibility.moveUpAction(language: .fr), "Monter")
        XCTAssertEqual(LayerAccessibility.moveDownAction(language: .fr), "Descendre")
        XCTAssertEqual(LayerAccessibility.moveDownAction(language: .en), "Move down")
    }

    // MARK: Handles

    func testHandleNamesAndValues() {
        let figures = LayerTransformFigures(widthPercent: 120, heightPercent: 80, rotation: 15, x: 412, y: 96)
        XCTAssertEqual(LayerAccessibility.handleName(.edge(1), language: .fr), "Bord droit")
        XCTAssertEqual(LayerAccessibility.handleValue(.edge(1), figures: figures, language: .fr), "Largeur 120 %")
        XCTAssertEqual(LayerAccessibility.handleValue(.edge(0), figures: figures, language: .fr), "Hauteur 80 %")
        XCTAssertEqual(LayerAccessibility.handleValue(.edge(3), figures: figures, language: .en), "Width 120%")
        XCTAssertEqual(LayerAccessibility.handleValue(.corner(2), figures: figures, language: .fr), "Échelle 100 %")
        XCTAssertEqual(LayerAccessibility.handleValue(.rotate, figures: figures, language: .fr), "Rotation 15°")
        XCTAssertEqual(LayerAccessibility.handleValue(.inside, figures: figures, language: .fr), "X 412 · Y 96 px")
        XCTAssertEqual(LayerAccessibility.handleName(.corner(0), language: .en), "Top left corner")
        XCTAssertTrue(LayerAccessibility.isAdjustable(.rotate))
        XCTAssertFalse(LayerAccessibility.isAdjustable(.inside))
    }

    func testHandlesStepFivePercentAndFiveDegrees() throws {
        let start = LayerTransform(center: PSPoint(x: 0.4, y: 0.6), scale: 1.2, rotation: 10, scaleX: 1, scaleY: 0.5)
        // A right edge: width 120 % → 125 %, height unchanged.
        let wider = try XCTUnwrap(LayerAccessibility.adjusted(.edge(1), transform: start, increment: true))
        XCTAssertEqual(100 * wider.scale * wider.scaleX, 125, accuracy: 1e-9)
        XCTAssertEqual(100 * wider.scale * wider.scaleY, 60, accuracy: 1e-9)
        // A top edge: height 60 % → 55 %.
        let shorter = try XCTUnwrap(LayerAccessibility.adjusted(.edge(0), transform: start, increment: false))
        XCTAssertEqual(100 * shorter.scale * shorter.scaleY, 55, accuracy: 1e-9)
        XCTAssertEqual(100 * shorter.scale * shorter.scaleX, 120, accuracy: 1e-9)
        // A corner: scale 120 % → 125 %.
        let bigger = try XCTUnwrap(LayerAccessibility.adjusted(.corner(2), transform: start, increment: true))
        XCTAssertEqual(bigger.scale, 1.25, accuracy: 1e-9)
        XCTAssertEqual(bigger.center, start.center)
        // The knob: 10° → 5°.
        let turned = try XCTUnwrap(LayerAccessibility.adjusted(.rotate, transform: start, increment: false))
        XCTAssertEqual(turned.rotation, 5, accuracy: 1e-9)
        // Nothing for the inside, nor below 1 %.
        XCTAssertNil(LayerAccessibility.adjusted(.inside, transform: start, increment: true))
        XCTAssertNil(LayerAccessibility.adjusted(.corner(0), transform: LayerTransform(scale: 0.04), increment: false))
        // A flipped width keeps its flip.
        let flipped = try XCTUnwrap(LayerAccessibility.adjusted(.edge(3), transform: LayerTransform(scale: 1, scaleX: -1), increment: true))
        XCTAssertEqual(flipped.scaleX, -1.05, accuracy: 1e-9)
    }

    func testAQuadScalesAboutItsCentroid() throws {
        let quad = [PSPoint(x: 0.2, y: 0.2), PSPoint(x: 0.6, y: 0.2), PSPoint(x: 0.6, y: 0.6), PSPoint(x: 0.2, y: 0.6)]
        let start = LayerTransform(quad: quad)
        let wider = try XCTUnwrap(LayerAccessibility.adjusted(.edge(1), transform: start, increment: true)?.quad)
        XCTAssertEqual(wider[0].x, 0.4 - 0.2 * 1.05, accuracy: 1e-12)
        XCTAssertEqual(wider[1].x, 0.4 + 0.2 * 1.05, accuracy: 1e-12)
        XCTAssertEqual(wider[0].y, 0.2, accuracy: 1e-12)
    }

    // MARK: Figures (HUD and transform rows)

    func testFiguresFromAnAffineTransform() {
        var layer = Layer(name: "Logo", content: .image(MediaAsset(kind: .image, relativePath: "media/logo.png", pixelSize: PSSize(width: 400, height: 200))))
        layer.transform = LayerTransform(center: PSPoint(x: 0.25, y: 0.5), scale: 1.2, rotation: -30, scaleX: 1, scaleY: 0.5, skewX: 12)
        let figures = LayerTransformFigures.of(layer, contentSize: PSSize(width: 400, height: 200), canvasSize: PSSize(width: 4000, height: 3000), isBase: false)
        XCTAssertEqual(figures.widthPercent, 120, accuracy: 1e-9)
        XCTAssertEqual(figures.heightPercent, 60, accuracy: 1e-9)
        XCTAssertEqual(figures.rotation, -30, accuracy: 1e-9)
        // A parallelogram is centred on its transform's centre.
        XCTAssertEqual(figures.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(figures.y, 1500, accuracy: 1e-6)
        XCTAssertEqual(figures.sizeLine(language: .fr), "L 120 % · H 60 % · \u{2212}30° · Incl. 12°")
        XCTAssertEqual(figures.sizeLine(language: .en), "W 120% · H 60% · \u{2212}30° · Skew 12°")
        XCTAssertEqual(figures.positionLine(language: .fr), "X 1000 · Y 1500 px")
    }

    func testFiguresFromCorners() {
        var layer = Layer(name: "Affiche", content: .image(MediaAsset(kind: .image, relativePath: "media/poster.png", pixelSize: PSSize(width: 1000, height: 1000))))
        // The fitted size of a 1000 px square on a 2000 × 1000 canvas is 1000 px; this quad is 500 px wide, 250 px tall.
        layer.transform = LayerTransform(quad: [PSPoint(x: 0.25, y: 0.25), PSPoint(x: 0.5, y: 0.25), PSPoint(x: 0.5, y: 0.5), PSPoint(x: 0.25, y: 0.5)])
        let figures = LayerTransformFigures.of(layer, contentSize: PSSize(width: 1000, height: 1000), canvasSize: PSSize(width: 2000, height: 1000), isBase: false)
        XCTAssertEqual(figures.widthPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(figures.heightPercent, 25, accuracy: 1e-9)
        XCTAssertEqual(figures.rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(figures.x, 750, accuracy: 1e-9)
        XCTAssertEqual(figures.y, 375, accuracy: 1e-9)
    }

    func testTheBaseIsNeverTransformed() {
        let document = PhotoDocument(title: "Test", baseImage: base)
        let figures = LayerTransformFigures.of(document.layers[0], contentSize: base.pixelSize, canvasSize: document.canvasSize, isBase: true)
        XCTAssertEqual(figures, LayerTransformFigures(x: 2000, y: 1500))
    }

    func testNumbers() {
        XCTAssertEqual(LayerAccessibility.percent(79.6, language: .fr), "80 %")
        XCTAssertEqual(LayerAccessibility.percent(79.6, language: .en), "80%")
        XCTAssertEqual(LayerAccessibility.degrees(-7.5, language: .fr), "\u{2212}7,5°")
        XCTAssertEqual(LayerAccessibility.degrees(-7.5, language: .en), "\u{2212}7.5°")
        XCTAssertEqual(LayerAccessibility.degrees(15.02, language: .fr), "15°")
        XCTAssertEqual(LayerTransformFigures.normalizedDegrees(370), 10, accuracy: 1e-12)
        XCTAssertEqual(LayerTransformFigures.normalizedDegrees(-190), 170, accuracy: 1e-12)
        XCTAssertEqual(LayerTransformFigures.normalizedDegrees(-180), 180, accuracy: 1e-12)
    }
}
