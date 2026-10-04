#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// UX 2.0 tokens (ux-spec §4.20). The W1 values they replace stay in PSTokens.swift until the old shell is removed
// (UX-A phase 4), so the previous UI, still reachable when `ux2` is off, keeps its look. U1 owns this file.

public extension PSMetrics {
    /// The labelled tool bar (categories and context bars): 56 points.
    static let toolBar: CGFloat = 56
    /// A bar item's narrowest width (its label plus 4 points when wider); its hit area is 44 × 56.
    static let toolBarItemMinWidth: CGFloat = 48
    /// The bar's side insets.
    static let toolBarInset: CGFloat = 8
    /// A tool strip, in place of the bar while a panel is open: 52 points.
    static let toolStrip: CGFloat = 52
    /// Magie's action tiles: up to 96 points wide, the label on two lines.
    static let toolTileMaxWidth: CGFloat = 96
    /// The Ask row under the bar.
    static let askRow: CGFloat = 52
    /// Panel row A (« Annuler » · name · « OK », the grabber drawn in its top 8 points).
    static let panelRowA: CGFloat = 44
    /// Panel row B (target or mode, « ? », « Réinitialiser »).
    static let panelRowB: CGFloat = 44
    /// The panel's primary control at compact height.
    static let panelPrimary: CGFloat = 96
    /// Compact panel: rows A and B and the primary control, plus 4 points of air.
    static let panelCompact: CGFloat = 188
    /// Medium panel: at most this share of the screen (was 0.46).
    static let panelMediumShare: CGFloat = 0.40
    /// The grabber's hit area, centred in row A (Annuler and OK excluded).
    static let panelGrabberHit = CGSize(width: 120, height: 44)
    /// Carousel rings: centre to centre.
    static let carouselRingSpacing: CGFloat = 64
    /// A carousel ring's diameter.
    static let carouselRing: CGFloat = 44
    /// Small items (§4.22): below this on screen along an axis, the edge handles on that axis hide.
    static let smallItemThreshold: CGFloat = 88
    /// A small item's corner handle sits this far outside its bounds.
    static let smallItemHandleOffset: CGFloat = 12
    /// A small item's rotate knob sits this far outside its bounds.
    static let smallItemKnobOffset: CGFloat = 32
    /// Each handle's exclusive hit area (AC-03 exception 2).
    static let exclusiveHandleHit: CGFloat = 32
    /// Courbes and Niveaux overlay: the canvas width less twice this.
    static let toneGraphOverlayInset: CGFloat = 16
    /// The smallest hit area of anything interactive (AC-03).
    static let hitMinimum: CGFloat = 44
    /// Chips: 36 visual, 44 hit.
    static let chipVisual: CGFloat = 36
    /// Colour swatches: 28 visual, 44 hit.
    static let swatch: CGFloat = 28
    /// The context bar's capsule.
    static let contextBar: CGFloat = 44
    /// The feedback slot's height range and width.
    static let feedbackSlotMin: CGFloat = 44
    static let feedbackSlotMax: CGFloat = 88
    static let feedbackSlotMaxWidth: CGFloat = 360
    /// The canvas zones' inset (A, B, C).
    static let canvasInset: CGFloat = 12
    /// PSSlider: the track's thickness and the thumb's diameter.
    static let sliderTrack: CGFloat = 4
    static let sliderThumb: CGFloat = 24
}

public extension View {
    /// Extends the hit area of a control drawn `visible` points wide (a 28-point swatch, a 36-point chip) to 44 × 44
    /// without changing its size or layout (§4.20 `hitMinimum`).
    func psHitArea(visible: CGFloat) -> some View {
        contentShape(Rectangle().inset(by: -max(0, (PSMetrics.hitMinimum - visible) / 2)))
    }
}

/// A glossary label in the interface's language (UX 2.0 labels come from UXGlossary through term ids).
public extension UXGlossary {
    static func label(_ termID: String) -> String {
        text(termID, french: psPrefersFrench)
    }
}
#endif
