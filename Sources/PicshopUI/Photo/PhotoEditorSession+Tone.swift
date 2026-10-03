#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// Curves, Levels, Auto and the layer controls, on the session's drag hooks: a
/// drag between beginInteraction and endInteraction is one undo step; a single
/// change outside a drag commits at once. History labels are English keys the
/// panels also show (Curves, Levels, Opacity, Blend), so the History menu reads
/// them in French too.
extension PhotoEditorSession {
    // MARK: Tone

    /// The active image layer's own curve (identity when none): what the Curves panel edits.
    var userToneCurve: ToneCurve {
        document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedUserToneCurve } ?? .identity
    }

    /// The active image layer's Levels (identity when none).
    var levels: Levels {
        document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedLevels } ?? .identity
    }

    func setToneCurve(_ curve: ToneCurve) {
        guard let layerID = document.activeImageLayerID else { return }
        interactiveEdit(label: "Curves") { document in
            document.update(layerID: layerID) { $0.edits.setTone(.toneCurve(curve)) }
        }
    }

    func setLevels(_ levels: Levels) {
        guard let layerID = document.activeImageLayerID else { return }
        interactiveEdit(label: "Levels") { document in
            document.update(layerID: layerID) { $0.edits.setTone(.levels(levels)) }
        }
    }

    /// Adaptive auto levels from the active layer's own histogram (before its Levels and curves),
    /// one undo step. Tone only: the colour channels are left alone.
    func autoTone() {
        guard let renderer, let layerID = document.activeImageLayerID else { return }
        let document = self.document
        Task { [weak self] in
            guard let self else { return }
            guard let histogram = await self.tone.currentInputHistogram(document: document, renderer: renderer) else {
                self.showToast(L("The histogram is not ready yet. Try again in a moment."), isError: true)
                return
            }
            let automatic = Levels.auto(from: histogram)
            guard !automatic.isIdentity else {
                Haptics.tick()
                self.showToast(L("The photo already uses the whole tonal range."))
                return
            }
            // Something else changed meanwhile (an undo, a voice edit): act on the photo as it is now.
            guard self.document.activeImageLayerID == layerID else { return }
            var updated = self.document
            updated.update(layerID: layerID) { $0.edits.setTone(.levels(automatic)) }
            self.commit(updated, label: "Levels")
            Haptics.success()
        }
    }

    /// Every channel of the curve back to a straight line (one step), or nothing when it already is.
    func resetToneCurve() {
        guard !userToneCurve.isIdentity else { return }
        setToneCurve(.identity)
    }

    func resetLevels() {
        guard !levels.isIdentity else { return }
        setLevels(.identity)
    }

    // MARK: Layers

    func setLayerOpacity(_ value: Double, layerID: UUID) {
        let opacity = value.clamped(to: 0...1)
        guard document.layer(id: layerID) != nil else { return }
        interactiveEdit(label: "Opacity") { document in
            document.update(layerID: layerID) { $0.opacity = opacity }
        }
    }

    func setLayerBlend(_ mode: BlendMode, layerID: UUID) {
        guard let layer = document.layer(id: layerID), layer.blendMode != mode else { return }
        interactiveEdit(label: "Blend") { document in
            document.update(layerID: layerID) { $0.blendMode = mode }
        }
        Haptics.tick()
    }

    /// The blend modes the menu offers: all 27 with pro tone on, else the 12 before W1.
    static var offeredBlendModes: [BlendMode] {
        FeatureFlags.isOn(.proTone) ? BlendMode.allCases : Array(BlendMode.allCases.prefix(12))
    }
}
#endif
