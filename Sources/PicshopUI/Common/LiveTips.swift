#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
#if canImport(TipKit)
import TipKit
#endif

/// Picshop Live's one tip: on the first editor visit, a popover on the orb.
enum LiveTips {
    /// Configures TipKit once per launch; later calls, and a datastore
    /// configured elsewhere, are ignored.
    @MainActor static func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        #if canImport(TipKit)
        try? Tips.configure([.displayFrequency(.immediate)])
        #endif
    }

    /// The orb was used: the tip has done its job.
    @MainActor static func orbUsed() {
        #if canImport(TipKit)
        guard isConfigured else { return }
        OrbTip().invalidate(reason: .actionPerformed)
        #endif
    }

    @MainActor private static var isConfigured = false
}

#if canImport(TipKit)
/// 'Touche l'orbe pour discuter en direct. Maintiens-la pour dicter.'
struct OrbTip: Tip {
    var title: Text { Text(L("Talk with PicShop")) }
    var message: Text? { Text(L("Tap the orb to talk live. Hold it to dictate.")) }
    var image: Image? { Image(systemName: "waveform") }
}
#endif

/// Anchors OrbTip's popover on the resting orb.
struct OrbTipAnchor: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(TipKit)
        content.popoverTip(OrbTip(), arrowEdge: .bottom)
        #else
        content
        #endif
    }
}
#endif
