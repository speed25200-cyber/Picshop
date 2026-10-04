#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import Foundation
import CoreGraphics
import PicshopCore

#if DEBUG
/// DEBUG launch scenarios (W2): `-PicshopScenario <name>` makes the app import a procedural photo, open the editor
/// and call `applyDebugScenario(_:)`; CI then takes the simulator screenshots. Parametric masks only, so the
/// simulator needs no model.
extension PhotoEditorSession {
    /// masks3, maskHandles, selectOutline, colorRange, selectAndMask, graphiteOn; W3: layers10, groupsClip,
    /// freeTransform, layersInspector, layerMaskPaint, exportPro.
    public func applyDebugScenario(_ name: String) async {
        // The editor configures itself as it opens: wait for its services and first frame (10 s at most).
        guard await waitUntil(seconds: 10, { [weak self] in self?.services != nil && self?.hasRenderedPreview == true }) else { return }
        switch name {
        case "masks3":
            // Linear (a darker sky), radial (a brighter centre) and luminance (lifted shadows) masks, with dials.
            var linear = scenarioMask(.top)
            linear.adjustments[.exposure] = -0.4
            linear.adjustments[.saturation] = 0.2
            var radial = scenarioMask(.center)
            radial.adjustments[.exposure] = 0.3
            radial.adjustments[.temperature] = 0.15
            var shadows = scenarioMask(.shadows)
            shadows.adjustments[.shadows] = 0.4
            var document = self.document
            for adjustment in [linear, radial, shadows] { document.setLocalAdjustment(adjustment, label: Self.masksLabel) }
            commit(document, label: Self.masksLabel)
            activeTool = .masks
            maskState.selectedID = radial.id
            maskState.editing = nil
        case "maskHandles":
            // One radial mask selected, its handles on the canvas.
            var radial = scenarioMask(.center)
            radial.adjustments[.exposure] = 0.35
            guard let component = radial.stack.components.first else { return }
            var document = self.document
            document.setLocalAdjustment(radial, label: Self.masksLabel)
            commit(document, label: Self.masksLabel)
            activeTool = .masks
            maskState.selectedID = radial.id
            maskState.editing = .handles(component.id)
        case "selectOutline":
            // A selection (the centre ellipse, parametric) with Sélection open: the ants and the 20 % tint.
            activeTool = .select
            select(region: .center)
            _ = await waitUntil(seconds: 10, { [weak self] in self?.document.selection != nil })
        case "colorRange":
            // The Color Range sheet open on a new selection, the blues preset picked.
            openSelect(mode: .colorRange)
            openColorRange(for: .selection)
            updateColorRange { $0.preset = .blues }
        case "selectAndMask":
            // A selection, then Select & Mask open with a softer, smoother edge.
            activeTool = .select
            select(region: .center)
            guard await waitUntil(seconds: 10, { [weak self] in self?.document.selection != nil }) else { return }
            openSelectAndMask()
            updateRefine { $0.refinement = SelectionRefinement(radius: 0.4, smooth: 0.3, feather: 0.2) }
        case "graphiteOn":
            // The graphite surround (D18) behind Masques.
            FeatureFlags.set(.graphiteSurround, true)
            activeTool = .masks
            applySurround()
            requestPreview()
        case "layers10", "groupsClip", "freeTransform", "layersInspector", "layerMaskPaint", "exportPro":
            await applyLayerScenario(name)
        default:
            return
        }
    }

    // MARK: - W3 layer fixtures (§7.13)

    /// The ids of the fixture's layers.
    private struct LayerFixture {
        var photo: UUID
        var gradient: UUID
        var curves: UUID
        var group: UUID
        var frame: UUID
        var clipped: UUID
        var title: UUID
        var ellipse: UUID
    }

    /// layers10: the column over ten layers (a group, a clip, adjustments, a gradient); groupsClip: the inspector on the
    /// clipping group; freeTransform: transform mode on a skewed copy of the photo with guides, after a synthetic
    /// 120-frame drag whose body counts are logged (`layers.bodyCount`, L5's ios-build step checks them); layersInspector:
    /// the inspector at full height; layerMaskPaint: the brush on a layer mask; exportPro: the sheet on PSD 16 bits.
    private func applyLayerScenario(_ name: String) async {
        guard let fixture = buildLayerFixture() else { return }
        layerState.showsColumn = true
        switch name {
        case "layers10":
            activeTool = nil
        case "groupsClip":
            activeTool = .layers
            selectLayer(fixture.clipped)
            layerState.inspectorDetentRequest = .medium
        case "freeTransform":
            beginTransformMode(fixture.photo)
            layerState.inspectorDetentRequest = .medium
            // Let the inspector and the column settle before counting.
            try? await Task.sleep(for: .milliseconds(600))
            await syntheticTransformDrag(frames: 120)
            // The screenshot: guides showing on the centre lines, the readout visible.
            layerState.guides = [SnapGuide(axis: .vertical, line: SnapLine(value: 0.5, source: .canvasCenter), span: 0...1),
                                 SnapGuide(axis: .horizontal, line: SnapLine(value: 0.5, source: .canvasCenter), span: 0...1)]
            layerState.transform.isVisible = true
        case "layersInspector":
            activeTool = .layers
            selectLayer(fixture.group)
            layerState.inspectorDetentRequest = .full
        case "layerMaskPaint":
            activeTool = .layers
            addLayerMask(.revealAll, to: fixture.photo)
            beginLayerMaskPaint(fixture.photo)
            setLayerMaskHides(true)
            // One stroke across the copy, as a finger would paint it.
            beginLayerMaskStroke(at: PSPoint(x: 0.56, y: 0.30))
            for step in 1...24 {
                continueLayerMaskStroke(to: PSPoint(x: 0.56 + Double(step) * 0.007, y: 0.30 + Double(step) * 0.004))
                try? await Task.sleep(for: .milliseconds(8))
            }
            endLayerMaskStroke()
        case "exportPro":
            presentExport(preset: ExportPreset(format: .psd, bitDepth: 16, layered: true))
        default:
            break
        }
    }

    /// Ten layers, procedural only (a copy of the photo, a gradient, solid and shape layers, text, adjustments, a group
    /// with a clip), made in one step.
    private func buildLayerFixture() -> LayerFixture? {
        guard let baseID = document.baseLayerID else { return nil }
        var document = self.document
        func add(_ layer: Layer, _ placement: LayerPlacementSpec = .top) -> UUID? {
            let (outcome, id) = document.applyStructureEdit(.add(layer, placement: placement))
            guard case .applied = outcome else { return nil }
            return id ?? layer.id
        }
        // A copy of the photo, smaller, turned and skewed (i2).
        let (copied, copyID) = document.applyStructureEdit(.duplicate(baseID))
        guard case .applied = copied, let photo = copyID else { return nil }
        document.applyLayerEdit(.rename("Photo 2"), to: photo)
        document.applyLayerEdit(.transform(LayerTransform(center: PSPoint(x: 0.66, y: 0.36), scale: 0.42, rotation: -8, skewX: 12)), to: photo)
        let warm = GradientFill.twoColor(PSColor(red: 1, green: 0.55, blue: 0.1), PSColor(red: 1, green: 0.55, blue: 0.1, alpha: 0), angle: 90)
        guard let gradient = add(Layer(name: "Dégradé 1", content: .gradientFill(warm), opacity: 0.7, blendMode: .softLight)) else { return nil }
        var curveEdits = EditStack()
        curveEdits.setTone(.toneCurve(ToneCurve(rgb: [ToneCurve.Point(0, 0), ToneCurve.Point(0.25, 0.2), ToneCurve.Point(0.5, 0.5),
                                                     ToneCurve.Point(0.75, 0.82), ToneCurve.Point(1, 1)])))
        guard let curves = add(Layer(name: "Courbes 1", content: .adjustment(.neutral), edits: curveEdits, recipeKind: .curves)) else { return nil }
        let frameShape = ShapeElement(kind: .roundedRectangle, fill: PSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.85),
                                      relativeSize: PSSize(width: 0.62, height: 0.18))
        guard let frame = add(Layer(name: "Cadre", content: .shape(frameShape), transform: LayerTransform(center: PSPoint(x: 0.5, y: 0.8)))) else { return nil }
        guard let clipped = add(Layer(name: "Couleur unie 1", content: .fill(PSColor(red: 0.2, green: 0.45, blue: 1)), opacity: 0.6,
                                      blendMode: .overlay, isClipped: true)) else { return nil }
        let text = TextElement(text: "Picshop", relativeSize: 0.07, color: .white, center: PSPoint(x: 0.5, y: 0.8))
        guard let title = add(Layer(name: "Titre", content: .text(text))) else { return nil }
        let (grouped, groupID) = document.applyStructureEdit(.group([frame, clipped, title], name: "Groupe 1"))
        guard case .applied = grouped, let group = groupID else { return nil }
        let ellipseShape = ShapeElement(kind: .ellipse, fill: PSColor(red: 1, green: 0.85, blue: 0.2), relativeSize: PSSize(width: 0.16, height: 0.16))
        guard let ellipse = add(Layer(name: "Ellipse", content: .shape(ellipseShape), transform: LayerTransform(center: PSPoint(x: 0.2, y: 0.22)),
                                      opacity: 0.8, blendMode: .screen)) else { return nil }
        var light = Adjustments.neutral
        light[.exposure] = 0.15
        light[.contrast] = 0.1
        _ = add(Layer(name: "Lumière 1", content: .adjustment(light), recipeKind: .light))
        document.selectedLayerID = photo
        commit(document, label: "Layers")
        return LayerFixture(photo: photo, gradient: gradient, curves: curves, group: group, frame: frame, clipped: clipped, title: title, ellipse: ellipse)
    }

    /// A 120-frame move of the transformed layer at 120 Hz (§7.2's re-render budget), then the body evaluations of
    /// the column and the inspector it caused, logged for L5's ios-build step.
    private func syntheticTransformDrag(frames: Int) async {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 520)
        LayersColumn.resetBodyCount()
        LayersInspector.resetBodyCount()
        guard beginTransformDrag(.inside, frame: frame) else { return }
        for index in 1...frames {
            let t = Double(index) / Double(frames)
            transformDrag(translation: PSPoint(x: -0.16 * t, y: 0.1 * sin(t * .pi)), location: PSPoint(x: 0.66 - 0.16 * t, y: 0.36), anchorAtCenter: false)
            try? await Task.sleep(for: .milliseconds(8))
        }
        endTransformDrag()
        try? await Task.sleep(for: .milliseconds(300))
        PSLog.info("layers.bodyCount column=\(LayersColumn.bodyCount) inspector=\(LayersInspector.bodyCount) frames=\(frames)", category: .ui)
    }

    /// A parametric mask of `region` (no model), dials neutral.
    private func scenarioMask(_ region: MaskRegion) -> LocalAdjustment {
        let component = MaskStack.defaultComponent(for: region, aspect: maskAspect)
        return LocalAdjustment(region: region, stack: component.map { MaskStack.single($0) } ?? MaskStack())
    }

    /// Polls `condition` every 100 ms until it holds (true) or the time runs out (false).
    private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
#endif
#endif
