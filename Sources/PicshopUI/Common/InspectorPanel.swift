#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation

/// The inspector's three heights.
enum InspectorDetent: CaseIterable, Comparable {
    /// 148 points: the dial or the tool's main control, the most picture.
    case compact
    /// The tool's controls at their own height, up to 46 % of the screen
    /// (the W0 ToolPanel's height, so every panel opens as it always has).
    case medium
    /// The screen less the top bar and 24 points.
    case full

    /// The panel's height cap at this detent.
    func height(screen: CGFloat, full: CGFloat) -> CGFloat {
        switch self {
        case .compact: return PSMetrics.inspectorCompact
        case .medium: return max(PSMetrics.inspectorCompact, screen * PSMetrics.inspectorMediumShare)
        case .full: return max(PSMetrics.inspectorCompact, full)
        }
    }

    /// Where a drag that ends at `translation` (points, down is positive) moving at
    /// `velocity` (points per second) settles: the nearest height to where the
    /// throw would carry it. Nil when it is thrown down past compact (close).
    static func settle(from start: InspectorDetent, translation: CGFloat, velocity: CGFloat,
                       heights: (InspectorDetent) -> CGFloat) -> InspectorDetent? {
        // A quarter of a second of momentum, as the system sheets do.
        let projected = heights(start) - (translation + velocity * 0.25)
        if projected < heights(.compact) - 72 { return nil }
        return allCases.min { abs(heights($0) - projected) < abs(heights($1) - projected) } ?? start
    }
}

/// The detent the open panel sits at, shared by StudioChrome (it hides the
/// rail at full height) and the panel. Kept across tools; full falls back to
/// medium when the panel closes.
@MainActor
@Observable
final class StudioInspectorState {
    var detent: InspectorDetent = .medium
}

private struct StudioInspectorKey: EnvironmentKey {
    static let defaultValue: StudioInspectorState? = nil
}

private struct StudioInspectorFullHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 640
}

private struct StudioScreenHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 844
}

extension EnvironmentValues {
    /// Set by StudioChrome in the W1 workspace: ToolPanel then hosts an InspectorPanel.
    var studioInspector: StudioInspectorState? {
        get { self[StudioInspectorKey.self] }
        set { self[StudioInspectorKey.self] = newValue }
    }

    /// The inspector's full height: the screen less the top bar, 24 points and the bottom margin.
    var studioInspectorFullHeight: CGFloat {
        get { self[StudioInspectorFullHeightKey.self] }
        set { self[StudioInspectorFullHeightKey.self] = newValue }
    }

    /// The window's height (the keyboard does not change it).
    var studioScreenHeight: CGFloat {
        get { self[StudioScreenHeightKey.self] }
        set { self[StudioScreenHeightKey.self] = newValue }
    }
}

/// The W1 inspector: one regular-glass card at the bottom of the studio, not a
/// system sheet, so the picture stays live above it. A grabber and a header
/// (an optional leading view, the title, the tool's accessory, Done), then the
/// controls, scrolling beyond the detent's height. Sections inside pin their
/// headers.
///
/// Three heights; a drag on the header snaps to the nearest by velocity, a
/// throw down from compact closes it (Done). Controls inside are flat (no
/// glass on glass), the Done button white.
struct InspectorPanel<Accessory: View, Content: View>: View {
    let title: String
    @Binding var detent: InspectorDetent
    let onDone: () -> Void
    let accessory: Accessory
    let content: Content
    /// Drawn before the title (ToolPanel puts Live's mini orb there).
    private var leadingView: AnyView?

    @State private var dragOffset: CGFloat = 0
    @State private var contentHeight: CGFloat?
    @Environment(\.studioScreenHeight) private var screenHeight
    @Environment(\.studioInspectorFullHeight) private var fullHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, detent: Binding<InspectorDetent>, onDone: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        _detent = detent
        self.onDone = onDone
        self.accessory = accessory()
        self.content = content()
    }

    /// A view before the title.
    func leading<V: View>(_ view: V) -> InspectorPanel {
        var copy = self
        copy.leadingView = AnyView(view)
        return copy
    }

    /// Grabber, header, gap and padding: what the controls do not get.
    private static var chrome: CGFloat { 6 + 5 + 6 + PSMetrics.barButton + 10 + 14 }

    private func cap(_ detent: InspectorDetent) -> CGFloat {
        detent.height(screen: screenHeight, full: fullHeight)
    }

    var body: some View {
        let room = max(44, cap(detent) - Self.chrome)
        // Compact and medium fit their controls up to the cap; full is the full height.
        let height = detent == .full ? room : min(contentHeight ?? room, room)
        VStack(spacing: 0) {
            grabber
            header
                .padding(.bottom, 10)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .center, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    content
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled((contentHeight ?? .infinity) <= height)
            .frame(height: height)
        }
        .padding(.horizontal, PSSpacing.panel)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .psCard(cornerRadius: PSRadius.floating)
        .padding(.horizontal, 10)
        .frame(maxWidth: 620)
        .offset(y: max(-40, dragOffset * (dragOffset < 0 ? 0.3 : 0.6)))
        .animation(reduceMotion ? PSSpring.fade : PSSpring.standard, value: detent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(.escape) { onDone() }
        .accessibilityAction(named: Text(L("Taller panel"))) { step(by: 1) }
        .accessibilityAction(named: Text(L("Shorter panel"))) { step(by: -1) }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.psStrokeStrong)
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(resize)
            .onTapGesture(count: 2) { step(by: detent == .full ? -2 : 1) }
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let leadingView { leadingView }
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: PSSpacing.small)
            accessory
            PSPanelPrimaryButton(systemImage: "checkmark", size: PSMetrics.barButton, accessibilityLabel: L("Done"), action: onDone)
        }
        .frame(minHeight: PSMetrics.barButton)
        .contentShape(Rectangle())
        .gesture(resize)
    }

    /// Drag the grabber or the header: follows the finger, then snaps by velocity.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let vertical = abs(value.translation.height) > abs(value.translation.width)
                let target = vertical
                    ? InspectorDetent.settle(from: detent, translation: value.translation.height, velocity: value.velocity.height,
                                             heights: { cap($0) })
                    : detent
                let release = PSSpring.release(velocity: -value.velocity.height, distance: max(1, abs(dragOffset)))
                withAnimation(reduceMotion ? PSSpring.fade : release) { dragOffset = 0 }
                guard let target else {
                    Haptics.tap()
                    onDone()
                    return
                }
                if target != detent {
                    Haptics.tick()
                    withAnimation(reduceMotion ? PSSpring.fade : PSSpring.standard) { detent = target }
                }
            }
    }

    private func step(by steps: Int) {
        let all = InspectorDetent.allCases
        guard let index = all.firstIndex(of: detent) else { return }
        let next = all[max(0, min(all.count - 1, index + steps))]
        guard next != detent else { return }
        Haptics.tick()
        withAnimation(reduceMotion ? PSSpring.fade : PSSpring.standard) { detent = next }
    }
}

extension InspectorPanel where Accessory == EmptyView {
    init(title: String, detent: Binding<InspectorDetent>, onDone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, detent: detent, onDone: onDone, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Rows

/// A sticky group header (Lumière, Couleur, Détail…): put it in a Section's
/// header inside an InspectorPanel and it pins while the rows scroll.
struct InspectorGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(PSFontRole.groupHeader)
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(Color.psTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Color.psElevated.opacity(0.92))
            .accessibilityAddTraits(.isHeader)
    }
}

/// An inspector row: the label, the value in monospaced digits (yellow when off
/// neutral), and a 2-point track filled from neutral, in yellow. 52 points tall.
/// W1 ships the row; from W3 the rows are generated from the catalog's ParamSpec.
struct InspectorRow: View {
    let label: String
    /// The formatted value ("+0,35").
    let value: String
    /// Where the value sits, 0…1, and where neutral sits (0.5 for a bipolar value).
    var fraction: Double
    var neutral: Double = 0.5

    private var isOffNeutral: Bool { abs(fraction - neutral) > 0.0005 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(PSFontRole.inspectorLabel)
                    .foregroundStyle(Color.psTextSecondary)
                Spacer(minLength: PSSpacing.small)
                Text(value)
                    .font(PSFontRole.inspectorValue)
                    .foregroundStyle(isOffNeutral ? Color.psValueAccent : Color.psTextPrimary)
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let from = min(fraction, neutral) * width
                let to = max(fraction, neutral) * width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.psFillControl)
                    Capsule().fill(Color.psValueAccent)
                        .frame(width: max(0, to - from))
                        .offset(x: from)
                        .opacity(isOffNeutral ? 1 : 0)
                }
            }
            .frame(height: 2)
        }
        .frame(minHeight: PSMetrics.inspectorRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
#endif
