#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// What a probed element is to the UX checks (ux-spec §6.4): `check-ux.py` counts one `primary` per screen state
/// (AC-04), compares the `back`, `undo`, `redo` and `primary` frames across editors (AC-05), and so on.
enum UXProbeRole: String, CaseIterable, Sendable {
    case primary, cancel, confirm, back, undo, redo, compare, tool, canvas, slot, contextBar, control
}

extension View {
    /// Tags an element for the UX probe and the XCUITest task paths (`step()`): its probe id becomes its
    /// accessibility identifier ("bar.adjust", "strip.adjust.light", "panel.ok"). The shared components tag
    /// themselves; lanes tag their own controls. Phase 0 sets the identifier; U1 adds the DEBUG geometry record
    /// (`Documents/ux-<scenario>.json`) behind this same call.
    func uxProbe(id: String, role: UXProbeRole = .control) -> some View {
        accessibilityIdentifier(id)
    }
}
#endif
