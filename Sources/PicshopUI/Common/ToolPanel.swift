#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// One open tool, inline at the bottom of the studio: a glass card with the
/// mini orb (so Live keeps going), the tool's title, its own action and Done,
/// then the tool's controls. A swipe down on the header, or the accessibility
/// escape, closes it. At most 46 % of the screen tall; the controls scroll
/// beyond that.
///
/// Controls inside use `PSTheme.fill` / `psChipFill`, and the white actions
/// are flat: never glass on glass.
struct ToolPanel<Accessory: View, Content: View>: View {
    let title: String
    let live: LiveSession?
    let onDone: () -> Void
    let accessory: Accessory
    let content: Content

    @State private var dragOffset: CGFloat = 0
    /// The controls' own height, measured: the scroll view is exactly that tall up to the cap.
    @State private var contentHeight: CGFloat?
    @Environment(\.studioPanelMaxHeight) private var maxHeight

    init(title: String, live: LiveSession?, onDone: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.live = live
        self.onDone = onDone
        self.accessory = accessory()
        self.content = content()
    }

    /// Room left for the controls: the cap less the header, the gap and the padding.
    private var contentCap: CGFloat { max(120, maxHeight - PSMetrics.barButton - 12 - 32) }

    var body: some View {
        VStack(spacing: 12) {
            header
            // One copy of the controls (two, as ViewThatFits keeps, would swap and lose their
            // state when the height crosses the cap). It scrolls only when it does not fit, so
            // dial and crop drags stay free of the scroll view otherwise.
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled((contentHeight ?? .infinity) <= contentCap)
            .frame(height: min(contentHeight ?? contentCap, contentCap))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .psCard(cornerRadius: PSRadius.toolPanel)
        .padding(.horizontal, 10)
        .frame(maxWidth: 620)
        .offset(y: dragOffset * 0.5)
        .opacity(1 - Double(min(dragOffset, 120)) / 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(.escape) { onDone() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let live {
                LiveMiniOrb(live: live)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(PSTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
            PSPanelPrimaryButton(systemImage: "checkmark", size: PSMetrics.barButton, accessibilityLabel: L("Done"), action: onDone)
        }
        .frame(minHeight: PSMetrics.barButton)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    let vertical = abs(value.translation.height) > abs(value.translation.width)
                    let shouldClose = vertical && (value.translation.height > 48 || value.predictedEndTranslation.height > 140)
                    withAnimation(PSMotion.standard) { dragOffset = 0 }
                    if shouldClose {
                        Haptics.tap()
                        onDone()
                    }
                }
        )
    }
}

extension ToolPanel where Accessory == EmptyView {
    init(title: String, live: LiveSession?, onDone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, live: live, onDone: onDone, accessory: { EmptyView() }, content: content)
    }
}

/// The 36-point orb in a panel header: a leaf, so Live's state changes never
/// re-evaluate the panel's content. A tap does what the orb does; outside
/// Live a hold dictates. With Differentiate Without Colour it also shows a
/// symbol for the phase.
struct LiveMiniOrb: View {
    let live: LiveSession
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        let state = live.state
        let isLive = live.isLive
        let activity = state == .acting ? live.activity : nil
        LiveOrbButton(size: PSMetrics.orbMini, state: state, meter: live.meter, isMuted: live.isMuted,
                      onTap: { live.orbTapped() },
                      onHoldStart: isLive ? nil : { live.beginDictation() },
                      onHoldEnd: isLive ? nil : { live.endDictation() })
            .actingProgress(activity?.progress)
            .liveAccessibility(activity: activity?.title, actions: nil)
            .overlay {
                if differentiate, let symbol = Self.phaseSymbol(state) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    static func phaseSymbol(_ state: LiveState) -> String? {
        switch state {
        case .hearing, .dictating: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2"
        case .acting: return "wand.and.stars"
        default: return nil
        }
    }
}

#if DEBUG
private struct ToolPanelPreview: View {
    @State private var live: LiveSession?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ToolPanel(title: "Recadrer", live: live, onDone: {}) {
                PSPanelPrimaryButton("OK") {}
            } content: {
                Text(verbatim: "Contenu du panneau").foregroundStyle(PSTheme.textSecondary).frame(height: 120)
            }
            ToolPanel(title: "Réglages", live: nil, onDone: {}) {
                VStack(spacing: 12) {
                    ForEach(0..<12, id: \.self) { index in
                        Text(verbatim: "Ligne \(index + 1)").foregroundStyle(PSTheme.textSecondary).frame(maxWidth: .infinity, minHeight: 32)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .environment(\.studioPanelMaxHeight, 360)
        .onAppear { if live == nil { live = LiveSession.preview(.acting) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("ToolPanel") {
    ToolPanelPreview()
}
#endif
#endif
