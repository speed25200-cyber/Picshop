#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// UX 2.0 (ux-spec §4.5, §3.5.2): every tool panel has the same header. Row A is « Annuler » · the tool's name ·
// white « OK » (the grabber drawn in its top 8 points); row B holds the target pill or the tool's one mode switch,
// then « ? » and « Réinitialiser »; then the content; the strip sits under the panel (EditorShell's `panel` slot).
// Panels never close by swiping. It replaces W1's InspectorPanel and the W0 ToolPanel card once each editor moves
// to EditorShell; existing panels' content is hosted inside it unchanged. U1 owns this file.

/// The panel's three heights (§4.5).
enum PanelHeight: Int, CaseIterable, Comparable, Sendable {
    /// Rows A and B and the primary control: 188 points, or less when the content is smaller.
    case compact
    /// Every control of the tool, up to 40 % of the screen.
    case medium
    /// To the top bar less 24 points: list tools only (Calques, the zones, Actions).
    case full

    init(_ height: ToolLayout.Height) {
        switch height {
        case .compact: self = .compact
        case .medium: self = .medium
        case .full: self = .full
        }
    }

    static func < (lhs: PanelHeight, rhs: PanelHeight) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The whole panel's height cap (rows A and B included) on a screen `screen` points tall; `full` is the room
    /// from the top bar less 24 points to the strip.
    func cap(screen: CGFloat, full: CGFloat) -> CGFloat {
        switch self {
        case .compact: return PSMetrics.panelCompact
        case .medium: return max(PSMetrics.panelCompact, screen * PSMetrics.panelMediumShare)
        case .full: return max(PSMetrics.panelCompact, full)
        }
    }

    /// Where a drag on row A settles: the nearest allowed height to where the throw would carry it (a quarter of a
    /// second of momentum). A fling down never closes the panel: it stops at compact.
    static func settle(from start: PanelHeight, translation: CGFloat, velocity: CGFloat, allowsFull: Bool,
                       heights: (PanelHeight) -> CGFloat) -> PanelHeight {
        let projected = heights(start) - (translation + velocity * 0.25)
        let allowed = allCases.filter { allowsFull || $0 != .full }
        return allowed.min { abs(heights($0) - projected) < abs(heights($1) - projected) } ?? start
    }
}

/// Row A (§4.5): « Annuler » (text, leading) · the tool or sub-mode name · « OK » (white capsule, trailing), both at
/// least 44 × 44. The grabber is drawn in the top 8 points; its hit area is the centre 120 × 44 (a tap cycles the
/// heights). With a run verb (« Générer les sous-titres »), « OK » is plain text until the verb has run (AC-04).
struct PanelHeader: View {
    enum Primary: Equatable, Sendable {
        /// « OK » is the panel's white primary.
        case ok
        /// The panel's run verb is the primary: « OK » is drawn as plain text until it has run.
        case runVerbPending
    }

    let title: String
    var primary: Primary
    let onCancel: () -> Void
    let onDone: () -> Void
    var onGrabberTap: (() -> Void)?

    init(title: String, primary: Primary = .ok, onCancel: @escaping () -> Void, onDone: @escaping () -> Void,
         onGrabberTap: (() -> Void)? = nil) {
        self.title = title
        self.primary = primary
        self.onCancel = onCancel
        self.onDone = onDone
        self.onGrabberTap = onGrabberTap
    }

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.psStrokeStrong)
                .frame(width: 36, height: 5)
                .padding(.top, 3)
                .accessibilityHidden(true)
            HStack(spacing: PSSpacing.small) {
                cancelButton
                Spacer(minLength: 0)
                doneButton
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, PSMetrics.panelGrabberHit.width / 2 - PSSpacing.small)
                .frame(maxHeight: .infinity)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: PSMetrics.panelGrabberHit.width, height: PSMetrics.panelGrabberHit.height)
                .contentShape(Rectangle())
                .onTapGesture { onGrabberTap?() }
                .accessibilityHidden(true)
        }
        .frame(height: PSMetrics.panelRowA)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var cancelButton: some View {
        Button {
            Haptics.tap()
            onCancel()
        } label: {
            Text(L("Cancel"))
                .font(.body)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .frame(minWidth: PSMetrics.hitMinimum, minHeight: PSMetrics.hitMinimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.95))
        .uxProbe(id: "panel.cancel", role: .cancel)
    }

    @ViewBuilder
    private var doneButton: some View {
        switch primary {
        case .ok:
            PSPanelPrimaryButton(L("OK"), height: PSMetrics.chipVisual, action: onDone)
                .frame(minWidth: PSMetrics.hitMinimum, minHeight: PSMetrics.hitMinimum)
                .contentShape(Rectangle())
                .uxProbe(id: "panel.ok", role: .primary)
        case .runVerbPending:
            Button {
                Haptics.tap()
                onDone()
            } label: {
                Text(L("OK"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.psTextPrimary)
                    .frame(minWidth: PSMetrics.hitMinimum, minHeight: PSMetrics.hitMinimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PSPressStyle(scale: 0.95))
            .uxProbe(id: "panel.ok", role: .confirm)
        }
    }
}

/// A trailing action of row B: « Réinitialiser » (dimmed when the tool has no edit on its target), « Options »,
/// « Désélectionner », « Sélectionner ».
struct PanelRowAction {
    var id: String
    var title: String
    var isEnabled: Bool
    var action: () -> Void

    init(id: String, title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    /// « Réinitialiser »: resets this tool's edits on the current target.
    static func reset(isEnabled: Bool, action: @escaping () -> Void) -> PanelRowAction {
        PanelRowAction(id: "panel.reset", title: L("Reset"), isEnabled: isEnabled, action: action)
    }
}

/// Row B (§4.5): leading, the TargetPill or the tool's single mode switch (≤ 3 segments) or a creation tool's
/// properties; trailing, « ? » (the tool's help page and tips) and the row's action. 44 points; it wraps to two rows
/// at accessibility text sizes.
struct PanelRowB<Leading: View>: View {
    let leading: Leading
    var onHelp: (() -> Void)?
    var trailing: PanelRowAction?

    @Environment(\.dynamicTypeSize) private var typeSize

    init(onHelp: (() -> Void)? = nil, trailing: PanelRowAction? = nil, @ViewBuilder leading: () -> Leading) {
        self.leading = leading()
        self.onHelp = onHelp
        self.trailing = trailing
    }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: PSSpacing.xSmall))
            : AnyLayout(HStackLayout(spacing: PSSpacing.small))
        layout {
            leading
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: PSSpacing.xSmall) {
                if let onHelp {
                    Button {
                        Haptics.tap()
                        onHelp()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(PSFont.glyph(.bar))
                            .foregroundStyle(Color.psTextSecondary)
                            .frame(width: PSMetrics.hitMinimum, height: PSMetrics.hitMinimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.92))
                    .accessibilityLabel(L("Help"))
                    .uxProbe(id: "panel.help")
                }
                if let trailing {
                    Button {
                        Haptics.tap()
                        trailing.action()
                    } label: {
                        Text(trailing.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(trailing.isEnabled ? Color.psTextPrimary : Color.psTextDisabled)
                            .lineLimit(1)
                            .padding(.horizontal, PSSpacing.small)
                            .frame(minHeight: PSMetrics.hitMinimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.95))
                    .disabled(!trailing.isEnabled)
                    .uxProbe(id: trailing.id)
                }
            }
        }
        .frame(minHeight: PSMetrics.panelRowB)
    }
}

extension PanelRowB where Leading == EmptyView {
    init(onHelp: (() -> Void)? = nil, trailing: PanelRowAction? = nil) {
        self.init(onHelp: onHelp, trailing: trailing, leading: { EmptyView() })
    }
}

/// InspectorPanel v2: one regular-glass card at the bottom of EditorShell (the picture stays live above it), with
/// PanelHeader, row B and the content, scrolling beyond the height's cap. Three heights: a drag on row A snaps by
/// velocity, a tap on the grabber cycles them; nothing closes it but « Annuler » and « OK ». « Annuler » asks
/// « Abandonner les modifications de … ? » when the session changed something (§3.5.2). VoiceOver: Escape is
/// « Annuler »; custom actions grow and shrink the panel.
struct InspectorPanelV2<RowB: View, Content: View>: View {
    let title: String
    let session: any PanelSession
    @Binding var height: PanelHeight
    var allowsFull: Bool
    var primary: PanelHeader.Primary
    let rowB: RowB
    let content: Content

    @State private var dragOffset: CGFloat = 0
    @State private var contentHeight: CGFloat?
    @State private var confirmsCancel = false
    @Environment(\.studioScreenHeight) private var screenHeight
    @Environment(\.studioInspectorFullHeight) private var fullHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, session: any PanelSession, height: Binding<PanelHeight>, allowsFull: Bool = false,
         primary: PanelHeader.Primary = .ok, @ViewBuilder rowB: () -> RowB, @ViewBuilder content: () -> Content) {
        self.title = title
        self.session = session
        _height = height
        self.allowsFull = allowsFull
        self.primary = primary
        self.rowB = rowB()
        self.content = content()
    }

    private func cap(_ height: PanelHeight) -> CGFloat {
        height.cap(screen: screenHeight, full: fullHeight)
    }

    var body: some View {
        let room = max(PSMetrics.hitMinimum, cap(height) - PSMetrics.panelRowA - PSMetrics.panelRowB)
        let contentFrame = height == .full ? room : min(contentHeight ?? room, room)
        VStack(spacing: 0) {
            PanelHeader(title: title, primary: primary, onCancel: cancel, onDone: done, onGrabberTap: cycle)
                .gesture(resize)
            rowB
                .frame(minHeight: PSMetrics.panelRowB)
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled((contentHeight ?? .infinity) <= contentFrame)
            .frame(height: contentFrame)
        }
        .padding(.horizontal, PSSpacing.panel)
        .padding(.bottom, PSSpacing.small)
        .frame(maxWidth: .infinity)
        .psCard(cornerRadius: PSRadius.floating)
        .padding(.horizontal, PSSpacing.small)
        .frame(maxWidth: 620)
        .offset(y: max(-40, dragOffset * (dragOffset < 0 ? 0.3 : 0.6)))
        .animation(reduceMotion ? PSSpring.fade : PSSpring.standard, value: height)
        .confirmationDialog(String(format: L("Discard the changes to %@?"), title), isPresented: $confirmsCancel, titleVisibility: .visible) {
            Button(L("Discard Changes"), role: .destructive) { session.abandonPanel() }
            Button(L("Keep Editing"), role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(.escape) { cancel() }
        .accessibilityAction(named: Text(L("Expand the panel"))) { step(by: 1) }
        .accessibilityAction(named: Text(L("Shrink the panel"))) { step(by: -1) }
    }

    private func cancel() {
        if session.panelHasChanges {
            Haptics.warning()
            confirmsCancel = true
        } else {
            session.abandonPanel()
        }
    }

    /// « OK » (its button plays the confirm haptic).
    private func done() {
        session.commitPanel()
    }

    /// The grabber's tap: compact → medium → full (list tools) → compact.
    private func cycle() {
        let allowed = PanelHeight.allCases.filter { allowsFull || $0 != .full }
        guard let index = allowed.firstIndex(of: height) else { return }
        let next = allowed[(index + 1) % allowed.count]
        Haptics.tick()
        withAnimation(reduceMotion ? PSSpring.fade : PSSpring.standard) { height = next }
    }

    private func step(by steps: Int) {
        let allowed = PanelHeight.allCases.filter { allowsFull || $0 != .full }
        guard let index = allowed.firstIndex(of: height) else { return }
        let next = allowed[max(0, min(allowed.count - 1, index + steps))]
        guard next != height else { return }
        Haptics.tick()
        withAnimation(reduceMotion ? PSSpring.fade : PSSpring.standard) { height = next }
    }

    /// Drag row A: follows the finger, then snaps by velocity; never closes.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let vertical = abs(value.translation.height) > abs(value.translation.width)
                let target = vertical
                    ? PanelHeight.settle(from: height, translation: value.translation.height, velocity: value.velocity.height,
                                         allowsFull: allowsFull, heights: { cap($0) })
                    : height
                let release = PSSpring.release(velocity: -value.velocity.height, distance: max(1, abs(dragOffset)))
                withAnimation(reduceMotion ? PSSpring.fade : release) { dragOffset = 0 }
                if target != height {
                    Haptics.tick()
                    withAnimation(reduceMotion ? PSSpring.fade : PSSpring.standard) { height = target }
                }
            }
    }
}

extension InspectorPanelV2 where RowB == EmptyView {
    init(title: String, session: any PanelSession, height: Binding<PanelHeight>, allowsFull: Bool = false,
         primary: PanelHeader.Primary = .ok, @ViewBuilder content: () -> Content) {
        self.init(title: title, session: session, height: height, allowsFull: allowsFull, primary: primary,
                  rowB: { EmptyView() }, content: content)
    }
}
#endif
