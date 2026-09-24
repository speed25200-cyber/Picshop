#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The caption zone above the chips while Live runs: what the user says, in
/// lighter text as it streams, then the chunk the assistant is speaking; the
/// running action with its progress, the inline Annuler, the notice line and
/// the one-time voice hint.
///
/// A leaf: it is the only view that reads `transcript`, `activity`,
/// `undoOffer` and `notice`, so a caption update never re-evaluates the dock.
/// Its height is fixed when Live starts (`captionReserve`, 3 lines of
/// `.title3`, 2 on compact screens) and never follows the text, so the picture
/// above never moves. With captions off in Settings it keeps one line for the
/// activity and notices.
struct LiveCaptions: View {
    let live: LiveSession

    @Environment(\.picshop) private var app
    @Environment(\.studioCompact) private var isCompact
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var reserve: CGFloat = 84
    @ScaledMetric(relativeTo: .title3) private var reserveCompact: CGFloat = 56
    @ScaledMetric(relativeTo: .subheadline) private var reserveOneLine: CGFloat = 30

    init(live: LiveSession) {
        self.live = live
    }

    /// The zone's height: what the dock reserves, and nothing more.
    static func height(captions: Bool, compact: Bool, reserve: CGFloat, reserveCompact: CGFloat, oneLine: CGFloat) -> CGFloat {
        guard captions else { return oneLine }
        return compact ? reserveCompact : reserve
    }

    private var showsText: Bool { app?.settings.liveCaptions ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            if live.showsVoiceHint, showsText {
                voiceHint
            } else {
                if showsText { conversation }
                statusRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height(captions: showsText, compact: isCompact, reserve: reserve, reserveCompact: reserveCompact, oneLine: reserveOneLine))
        .clipped()
    }

    // MARK: Conversation

    private var secondary: Color { contrast == .increased ? Color.white.opacity(0.80) : PSTheme.captionSecondary }
    private var volatile: Color { contrast == .increased ? Color.white.opacity(0.60) : PSTheme.captionVolatile }

    @ViewBuilder
    private var conversation: some View {
        let transcript = live.transcript
        let activity = live.state == .acting ? live.activity : nil
        let speaksNow = activity != nil || !transcript.assistant.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            if !transcript.user.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    userText(transcript)
                        .font(.body)
                        .lineLimit(speaksNow || typeSize.isAccessibilitySize ? 1 : 2)
                        .truncationMode(.head)
                    if transcript.userPaused, !transcript.userIsFinal {
                        BreathingEllipsis(color: secondary, animated: !reduceMotion)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: transcript.userIsFinal)
            }
            if let activity {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ShimmerText(activity.title, font: .title3.weight(.medium))
                        .lineLimit(1)
                    if let progress = activity.progress {
                        Text(verbatim: "\(Int((progress * 100).rounded())) %")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(secondary)
                            .contentTransition(.numericText())
                    }
                }
                .transition(.opacity)
            } else if !transcript.assistant.isEmpty {
                AssistantLines(text: transcript.assistant, isStreaming: live.state == .speaking)
                    .id(transcript.turnID)
                    // A new turn: the previous words rise 8 points and fade.
                    .transition(reduceMotion
                                ? AnyTransition.opacity
                                : AnyTransition.asymmetric(insertion: .opacity, removal: AnyTransition.offset(y: -8).combined(with: .opacity)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: transcript.turnID)
        .animation(.easeOut(duration: 0.2), value: activity == nil)
        // One element for VoiceOver: "You: … PicShop: …". Nothing is announced; it is read on focus.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(transcript, activity: activity))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func userText(_ transcript: LiveTranscript) -> Text {
        let stable = transcript.user.stable
        let pending = transcript.user.volatile
        let separator = stable.isEmpty || pending.isEmpty ? "" : " "
        return Text(verbatim: stable).foregroundStyle(secondary)
            + Text(verbatim: separator + pending).foregroundStyle(transcript.userIsFinal ? secondary : volatile)
    }

    private func accessibilityText(_ transcript: LiveTranscript, activity: LiveActivity?) -> String {
        var parts: [String] = []
        if !transcript.user.isEmpty { parts.append(String(format: L("You: %@"), transcript.user.text)) }
        if let activity {
            parts.append(String(format: L("PicShop: %@"), activity.title))
        } else if !transcript.assistant.isEmpty {
            parts.append(String(format: L("PicShop: %@"), transcript.assistant))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Status: the activity (captions off), the notice, Annuler

    @ViewBuilder
    private var statusRow: some View {
        let notice = live.notice
        let offer = live.undoOffer
        let activity = showsText ? nil : (live.state == .acting ? live.activity : nil)
        if notice != nil || offer != nil || activity != nil {
            HStack(alignment: .center, spacing: 8) {
                if let notice {
                    NoticeLine(notice: notice) { live.performNoticeAction() }
                } else if let activity {
                    ShimmerText(activity.title, font: .subheadline.weight(.medium)).lineLimit(1)
                    if let progress = activity.progress {
                        Text(verbatim: "\(Int((progress * 100).rounded())) %")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(secondary)
                    }
                }
                Spacer(minLength: 0)
                if let offer {
                    UndoOfferChip(label: offer.label) { live.undoLastAction() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(PSMotion.quick, value: offer?.id)
        }
    }

    // MARK: Voice hint

    private var voiceHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PSTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceDownloadHint.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PSTheme.textPrimary)
                Text(VoiceDownloadHint.path)
                    .font(.footnote)
                    .foregroundStyle(PSTheme.textSecondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                live.dismissVoiceHint()
            } label: {
                Text(L("Later"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PSTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .psChipFill(Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PSPressStyle(scale: 0.95))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PSTheme.fill))
        .transition(.opacity)
    }
}

/// The assistant's words: the chunk the voice is saying, the last lines kept in view.
private struct AssistantLines: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.title3.weight(.medium))
                .foregroundStyle(PSTheme.captionPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDisabled(isStreaming)
        .scrollBounceBehavior(.basedOnSize)
        .mask {
            // A short fade at the top, so a clipped line reads as older text.
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Color.black
            }
        }
    }
}

/// "…" breathing after the user's words while they pause mid-sentence: still listening.
private struct BreathingEllipsis: View {
    let color: Color
    let animated: Bool
    @State private var bright = false

    var body: some View {
        Text(verbatim: "…")
            .font(.body)
            .foregroundStyle(color)
            .opacity(animated ? (bright ? 0.8 : 0.3) : 0.6)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
            .accessibilityHidden(true)
    }
}

/// A problem or info line, with its one action (Autoriser le micro, Ouvrir Réglages).
private struct NoticeLine: View {
    let notice: LiveNotice
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(notice.isProblem ? PSTheme.warning : PSTheme.textSecondary)
            Text(notice.text)
                .font(.subheadline)
                .foregroundStyle(PSTheme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let title = actionTitle {
                Button {
                    Haptics.tap()
                    perform()
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PSTheme.onPrimary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(Capsule().fill(PSTheme.primary))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PSPressStyle(scale: 0.95))
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.action {
        case .allowMicrophone, .openSettings: return "mic.slash"
        case .none: return notice.isProblem ? "exclamationmark.triangle.fill" : "info.circle"
        }
    }

    private var actionTitle: String? {
        switch notice.action {
        case .none: return nil
        case .allowMicrophone: return L("Allow the microphone")
        case .openSettings: return L("Open Settings")
        }
    }
}

/// The inline Annuler after a Live, idea or choice edit: where the eyes already are.
struct UndoOfferChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(L("Undo"), systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PSTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .psChipFill(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.95))
        .accessibilityHint(label)
    }
}

#if DEBUG
private struct LiveCaptionsPreview: View {
    let scenario: LiveSession.PreviewScenario
    @State private var live: LiveSession?

    var body: some View {
        VStack {
            Spacer()
            if let live {
                LiveCaptions(live: live).padding(.horizontal, 16)
                    .background(Color.white.opacity(0.03))
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .onAppear { if live == nil { live = LiveSession.preview(scenario) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("LiveCaptions cycle") {
    LiveCaptionsPreview(scenario: .cycle)
}

#Preview("LiveCaptions speaking") {
    LiveCaptionsPreview(scenario: .speaking)
}

#Preview("LiveCaptions problem") {
    LiveCaptionsPreview(scenario: .problem)
}
#endif
#endif
