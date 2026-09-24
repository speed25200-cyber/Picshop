#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// One open tool, inline at the bottom of the studio: a glass card with the
/// mini orb (so Live keeps going), the tool's title, its own action and Done,
/// then the tool's controls. A swipe down on the header, or the accessibility
/// escape, closes it.
///
/// Controls inside use `PSTheme.fill` / `psChipFill`: never glass on glass.
///
/// Phase 0: the card, the header and the swipe. The 46 % height cap with
/// scrolling follows.
struct ToolPanel<Accessory: View, Content: View>: View {
    let title: String
    let live: LiveSession?
    let onDone: () -> Void
    let accessory: Accessory
    let content: Content

    @State private var dragOffset: CGFloat = 0

    init(title: String, live: LiveSession?, onDone: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.live = live
        self.onDone = onDone
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .psCard(cornerRadius: PSRadius.toolPanel)
        .padding(.horizontal, 10)
        .offset(y: dragOffset * 0.5)
        .opacity(1 - Double(min(dragOffset, 120)) / 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(.escape) { onDone() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let live {
                ToolPanelOrb(live: live)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(PSTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
            PSCircleButton(systemImage: "checkmark", size: 36, kind: .prominent, accessibilityLabel: L("Done")) {
                Haptics.confirm()
                onDone()
            }
        }
        .frame(minHeight: 44)
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

/// The mini orb in a panel header: a leaf, so Live's state changes never
/// re-evaluate the panel's content.
private struct ToolPanelOrb: View {
    let live: LiveSession

    var body: some View {
        LiveOrbButton(size: PSMetrics.orbMini, state: live.state, meter: live.meter, isMuted: live.isMuted,
                      onTap: { live.orbTapped() })
    }
}

#if DEBUG
private struct ToolPanelPreview: View {
    @State private var live: LiveSession?

    var body: some View {
        VStack {
            Spacer()
            ToolPanel(title: "Recadrer", live: live, onDone: {}) {
                PSCapsuleButton("Annuler", height: 36, kind: .glass) {}
            } content: {
                Text(verbatim: "Contenu du panneau").foregroundStyle(PSTheme.textSecondary).frame(height: 120)
            }
            ToolPanel(title: "Réglages", live: nil, onDone: {}) {
                Text(verbatim: "Sans Live").foregroundStyle(PSTheme.textSecondary).frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .onAppear { if live == nil { live = LiveSession.preview(.listening) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("ToolPanel") {
    ToolPanelPreview()
}
#endif
#endif
