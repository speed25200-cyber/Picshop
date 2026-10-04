#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Curves, Levels, Auto and the layer controls, on the session's drag hooks: a
/// drag between beginInteraction and endInteraction is one undo step; a single
/// change outside a drag commits at once. History labels are English keys the
/// panels also show (Curves, Levels, Opacity, Blend), so the History menu reads
/// them in French too.
///
/// W3 (D9): Lumière, Courbes, Niveaux and Couleur edit `document.toneTarget(for:)`, the selected adjustment layer of
/// the panel's family, else the active image layer, the rule the generated rows and the voice handlers use too. Each
/// panel's header shows it as a chip (« Sur : Courbes 1 (j1) », « Photo de fond »); tapping it lists the eligible
/// layers.
extension PhotoEditorSession {
    // MARK: The tone target (D9)

    /// Where a tone or colour op of the panels lands now.
    func toneTargetID(for op: OpID) -> UUID? {
        document.toneTarget(for: op)
    }

    /// The interactive snapshot's scope for a drag on that target (D13): an adjustment layer's recipe, or an image
    /// layer's develop.
    func toneScope(for op: OpID) -> InteractionScope? {
        guard let id = toneTargetID(for: op), let layer = document.layer(id: id) else { return nil }
        return layer.isAdjustment ? .adjustmentLayer(id) : .layerDevelop(id)
    }

    /// A content lock refuses tone and colour edits on that layer (D7): said once, with a light haptic.
    func toneTargetAllows(_ layerID: UUID) -> Bool {
        layerAllows(.content, on: layerID)
    }

    /// The layers a panel's target chip lists, top first: every image layer, and the adjustment layers of the op's
    /// family (an adjustment layer of another kind never takes these dials).
    func toneTargetChoices(for op: OpID) -> [UUID] {
        let kinds = PhotoDocument.toneTargetKinds(for: op)
        return document.layers.reversed().compactMap { layer -> UUID? in
            if layer.isImage { return layer.id }
            if layer.isAdjustment, kinds.contains(layer.recipeKind ?? .light) { return layer.id }
            return nil
        }
    }

    /// Whether the chip shows: there is more than one layer the panel could edit.
    func showsToneTargetChip(for op: OpID) -> Bool {
        FeatureFlags.isOn(.proLayers) && toneTargetChoices(for: op).count > 1
    }

    /// « Sur : Courbes 1 (j1) », « Sur : Photo de fond ».
    func toneTargetLabel(for op: OpID) -> String {
        guard let id = toneTargetID(for: op) else { return "" }
        return String(format: L("On: %@"), layerChoiceName(id))
    }

    /// A layer as the chip and its list name it: « Courbes 1 (j1) », « Photo de fond ».
    func layerChoiceName(_ id: UUID) -> String {
        guard let layer = document.layer(id: id) else { return "" }
        let name = LayerAccessibility.displayName(layer, isBase: id == document.baseLayerID, language: layerLanguage)
        guard let ref = Self.layerRef(layer, in: document) else { return name }
        return "\(name) (\(ref))"
    }

    /// A layer picked from the chip's list: it becomes the selection, so the panel edits it (D9).
    func chooseToneTarget(_ id: UUID) {
        guard document.selectedLayerID != id, document.layer(id: id) != nil else { return }
        Haptics.tick()
        selectLayer(id)
    }

    // MARK: Tone

    /// The tone target's own curve (identity when none): what the Curves panel edits.
    var userToneCurve: ToneCurve {
        toneTargetID(for: "curves").flatMap { document.layer(id: $0)?.edits.resolvedUserToneCurve } ?? .identity
    }

    /// The tone target's Levels (identity when none).
    var levels: Levels {
        toneTargetID(for: "levels").flatMap { document.layer(id: $0)?.edits.resolvedLevels } ?? .identity
    }

    /// The Curves panel's drag: one step, on the target's snapshot.
    func beginCurvesInteraction() {
        beginInteraction(label: "Curves", scope: toneScope(for: "curves"))
    }

    /// The Levels panel's drag: one step, on the target's snapshot.
    func beginLevelsInteraction() {
        beginInteraction(label: "Levels", scope: toneScope(for: "levels"))
    }

    func setToneCurve(_ curve: ToneCurve) {
        guard let layerID = toneTargetID(for: "curves"), toneTargetAllows(layerID) else { return }
        interactiveEdit(label: "Curves") { document in
            document.update(layerID: layerID) { $0.edits.setTone(.toneCurve(curve)) }
        }
    }

    func setLevels(_ levels: Levels) {
        guard let layerID = toneTargetID(for: "levels"), toneTargetAllows(layerID) else { return }
        interactiveEdit(label: "Levels") { document in
            document.update(layerID: layerID) { $0.edits.setTone(.levels(levels)) }
        }
    }

    /// Adaptive auto levels from the active layer's own histogram (before its Levels and curves),
    /// one undo step, on the Levels target (a selected « Niveaux » layer, else the active image layer).
    /// Tone only: the colour channels are left alone.
    func autoTone() {
        guard let renderer, let layerID = toneTargetID(for: "levels"), toneTargetAllows(layerID) else { return }
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
            guard self.toneTargetID(for: "levels") == layerID else { return }
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

    /// W1's opacity dial (LayerBlendControls, the flag-off inspector): through `applyLayerEdit` (W3), so a lock
    /// refuses it the way it refuses the voice.
    func setLayerOpacity(_ value: Double, layerID: UUID) {
        setLayerOpacityValue(value, layerID: layerID)
    }

    func setLayerBlend(_ mode: PicshopCore.BlendMode, layerID: UUID) {
        guard let layer = document.layer(id: layerID), layer.blendMode != mode else { return }
        setBlend(mode, layerID: layerID)
    }

    /// The blend modes the menu offers: all 27 with pro tone on, else the 12 before W1.
    static var offeredBlendModes: [PicshopCore.BlendMode] {
        FeatureFlags.isOn(.proTone) ? PicshopCore.BlendMode.allCases : Array(PicshopCore.BlendMode.allCases.prefix(12))
    }
}
#endif
