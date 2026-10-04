#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// An editor's own content for the canvas's fixed zones (ux-spec §3.4 « Canvas zones »), laid over the canvas
/// between the top bar and the bottom chrome by EditorShell:
/// - A (top left, 12-point inset): view badges (zoom %, HDR, the histogram card, video scopes);
/// - B2 (right edge, under « ◐ Avant »): photo's « ▤ Calques n » pill, Sélection's zones column. Hidden while a
///   panel is open.
/// The shell draws zone B (« ◐ Avant ») and zone C (the feedback slot and the docked context bar) itself. Empty
/// space here is not hit-testable: the canvas keeps every touch between the controls.
struct CanvasZones<Badges: View, Pills: View>: View {
    let badges: Badges
    let pills: Pills

    @Environment(\.editorPanelOpen) private var isPanelOpen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder badges: () -> Badges, @ViewBuilder pills: () -> Pills) {
        self.badges = badges()
        self.pills = pills()
    }

    var body: some View {
        ZStack {
            badges
                .padding(PSMetrics.canvasInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            pills
                .padding(.top, Self.pillsTop)
                .padding(.trailing, PSMetrics.canvasInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(isPanelOpen ? 0 : 1)
                .allowsHitTesting(!isPanelOpen)
                .animation(reduceMotion ? PSSpring.fade : PSSpring.quick, value: isPanelOpen)
        }
    }

    /// Zone B2 starts under zone B's 44-point « Avant » and an 8-point gap.
    static var pillsTop: CGFloat { PSMetrics.canvasInset + PSMetrics.barButton + PSSpacing.small }
}

extension CanvasZones where Pills == EmptyView {
    init(@ViewBuilder badges: () -> Badges) {
        self.init(badges: badges, pills: { EmptyView() })
    }
}

extension CanvasZones where Badges == EmptyView {
    init(@ViewBuilder pills: () -> Pills) {
        self.init(badges: { EmptyView() }, pills: pills)
    }
}
#endif
