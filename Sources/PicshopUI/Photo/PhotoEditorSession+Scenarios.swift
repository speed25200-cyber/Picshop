#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import Foundation
import PicshopCore

#if DEBUG
/// DEBUG launch scenarios (W2): `-PicshopScenario <name>` makes the app import a procedural photo, open the editor
/// and call `applyDebugScenario(_:)`; CI then takes the simulator screenshots. Parametric masks only, so the
/// simulator needs no model.
extension PhotoEditorSession {
    /// masks3, maskHandles, selectOutline, colorRange, selectAndMask, graphiteOn.
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
        default:
            return
        }
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
