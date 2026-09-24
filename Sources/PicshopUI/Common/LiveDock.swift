#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopIntent

/// The Ask field: a glass capsule that grows to four lines. Submitting hands
/// over the trimmed text and clears the field; the Send key submits (a return
/// never becomes a new line).
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var isEnabled: Bool
    let onSubmit: (String) -> Void
    private var focus: FocusState<Bool>.Binding?
    private var height: CGFloat = PSMetrics.composerHeight

    init(text: Binding<String>, placeholder: String, isEnabled: Bool = true, onSubmit: @escaping (String) -> Void) {
        _text = text
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    /// Binds the field's keyboard focus.
    func focusBinding(_ focus: FocusState<Bool>.Binding) -> ComposerField {
        var copy = self
        copy.focus = focus
        return copy
    }

    /// The resting height: 52, or 48 on compact screens.
    func composerHeight(_ height: CGFloat) -> ComposerField {
        var copy = self
        copy.height = height
        return copy
    }

    var body: some View {
        field
            .lineLimit(1...4)
            .font(.body)
            .foregroundStyle(PSTheme.textPrimary)
            .tint(PSTheme.textPrimary)
            .submitLabel(.send)
            .onSubmit(submit)
            .onChange(of: text) { _, new in
                // With a vertical axis the Send key types a return: treat it as Send.
                guard new.hasSuffix("\n") else { return }
                text = String(new.dropLast())
                submit()
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Capsule())
            .psGlassField()
            .disabled(!isEnabled)
            .accessibilityLabel(placeholder)
    }

    @ViewBuilder
    private var field: some View {
        let input = TextField(text: $text, prompt: Text(placeholder).foregroundStyle(PSTheme.textTertiary), axis: .vertical) {
            Text(placeholder)
        }
        if let focus {
            input.focused(focus)
        } else {
            input
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
    }
}

/// The editors' bottom dock. At rest: the idea chips (or choices), then Outils,
/// the Ask field and the orb. While Live runs it morphs into the console
/// (Outils, mute, orb, keyboard, End) and reserves the caption zone above the
/// chips. The resting reply capsule floats 8 points above the chips and takes
/// no layout space.
///
/// The body reads only `live.state`, `isLive`, `isMuted`, `choices != nil`
/// and `ideas`: captions, replies, activity and levels are read by leaves.
struct LiveDock: View {
    let live: LiveSession
    let onTools: () -> Void
    var candidateThumbnail: ((Int) async -> UIImage?)?

    @Namespace private var glass
    @State private var keyboardOpen = false
    @Environment(\.studioCompact) private var isCompact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(live: LiveSession, onTools: @escaping () -> Void, candidateThumbnail: ((Int) async -> UIImage?)? = nil) {
        self.live = live
        self.onTools = onTools
        self.candidateThumbnail = candidateThumbnail
    }

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let isLive = live.isLive
        VStack(spacing: 0) {
            if isLive {
                LiveCaptions(live: live)
                    .padding(.horizontal, 8)
                    .padding(.bottom, PSSpacing.captionGap)
                    .transition(.opacity)
            }
            if showsChipRow {
                chips(flat: isLive)
                    .frame(minHeight: PSMetrics.ideaChip)
                Color.clear.frame(height: isLive ? PSSpacing.consoleGap : PSSpacing.dockGap)
            }
            PSGlassContainer(spacing: 12) {
                if isLive {
                    VStack(spacing: PSSpacing.dockGap) {
                        if keyboardOpen {
                            ConsoleKeyboardField(live: live, isOpen: $keyboardOpen, glass: glass)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        console
                    }
                } else {
                    ComposerRow(live: live, glass: glass, height: isCompact ? PSMetrics.composerHeightCompact : PSMetrics.composerHeight,
                                onTools: onTools)
                }
            }
        }
        .padding(.horizontal, PSSpacing.editorSide)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if !isLive {
                LiveReplyCapsule(live: live)
                    .padding(.horizontal, PSSpacing.editorSide)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : PSMotion.morph, value: isLive)
        .animation(PSMotion.standard, value: keyboardOpen)
        .onChange(of: isLive) { _, running in if !running { keyboardOpen = false } }
    }

    /// No empty band: PDF has no ideas (its choices still show), and every idea may be dismissed.
    private var showsChipRow: Bool {
        if live.choices != nil { return true }
        if !live.canGoLive, case .loading = live.ideas { return false }
        if case .ready(let list) = live.ideas, list.isEmpty { return false }
        return true
    }

    @ViewBuilder
    private func chips(flat: Bool) -> some View {
        if live.choices != nil {
            LiveChoicesLeaf(live: live, thumbnail: candidateThumbnail, flat: flat)
                .transition(.opacity)
        } else {
            IdeaChipsRow(items: ideaItems, isEnabled: live.state != .acting,
                         onChoose: { id in if let idea = findIdea(id) { live.choose(idea) } },
                         onDismiss: { id in if let idea = findIdea(id) { live.dismiss(idea) } })
                .flat(flat)
                .transition(.opacity)
        }
    }

    private var console: some View {
        let isMuted = live.isMuted
        let orbSize = isCompact ? PSMetrics.orbConsoleCompact : PSMetrics.orbConsole
        return HStack(spacing: 0) {
            ToolsButton(glass: glass, action: onTools)
            Spacer(minLength: 8)
            PSCircleButton(systemImage: isMuted ? "mic.slash.fill" : "mic.fill", size: PSMetrics.dockButton,
                           kind: isMuted ? .prominent : .glass,
                           accessibilityLabel: isMuted ? L("Unmute microphone") : L("Mute microphone")) {
                live.setMuted(!isMuted)
            }
            .glassEffectID("mute", in: glass)
            Spacer(minLength: 8)
            DockOrb(live: live, size: orbSize, allowsHold: false)
            Spacer(minLength: 8)
            PSCircleButton(systemImage: keyboardOpen ? "keyboard.chevron.compact.down" : "keyboard", size: PSMetrics.dockButton,
                           accessibilityLabel: L("Keyboard")) {
                keyboardOpen.toggle()
            }
            .glassEffectID("keyboard", in: glass)
            Spacer(minLength: 8)
            PSCircleButton(systemImage: "xmark", size: PSMetrics.dockButton, kind: .danger, accessibilityLabel: L("End Live")) {
                live.end()
            }
            .glassEffectID("end", in: glass)
        }
        .frame(maxWidth: 360)
        .frame(height: isCompact ? PSMetrics.orbConsoleCompact : PSMetrics.consoleHeight)
    }

    private var ideaItems: [IdeaChipModel]? {
        switch live.ideas {
        case .loading: return nil
        case .ready(let ideas): return ideas.map { IdeaChipModel($0) }
        }
    }

    private func findIdea(_ id: String) -> LiveIdea? {
        guard case .ready(let ideas) = live.ideas else { return nil }
        return ideas.first { $0.id == id }
    }
}

/// Outils: the 52-point glass circle the sheet grows out of.
private struct ToolsButton: View {
    let glass: Namespace.ID
    let action: () -> Void
    @Environment(\.studioToolsNamespace) private var toolsNamespace

    var body: some View {
        PSCircleButton(systemImage: "slider.horizontal.3", size: PSMetrics.dockButton, accessibilityLabel: L("Tools"), action: action)
            .glassEffectID("left", in: glass)
            .modifier(ToolsTransitionSource(namespace: toolsNamespace))
    }
}

/// The source of the Outils sheet's zoom transition, when StudioChrome provides one.
private struct ToolsTransitionSource: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: StudioChromeIDs.toolsTransition, in: namespace)
        } else {
            content
        }
    }
}

/// The resting row: Outils, the Ask field, and the orb, which cross-fades to
/// Send while the field has text. Owns the draft, so typing re-evaluates only this row.
private struct ComposerRow: View {
    let live: LiveSession
    let glass: Namespace.ID
    let height: CGFloat
    let onTools: () -> Void

    @State private var draft = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            ToolsButton(glass: glass, action: onTools)
            ComposerField(text: $draft, placeholder: typeSize.isAccessibilitySize ? L("Ask…") : L("Ask PicShop…"),
                          isEnabled: live.state != .acting) { text in
                live.send(text: text)
            }
            .composerHeight(height)
            .glassEffectID("field", in: glass)
            ZStack {
                if draft.isEmpty {
                    DockOrb(live: live, size: PSMetrics.orbComposer, allowsHold: true)
                        .modifier(OrbTipAnchor())
                        .transition(.opacity)
                } else {
                    PSCircleButton(systemImage: "arrow.up", size: PSMetrics.dockButton, kind: .prominent, accessibilityLabel: L("Send")) {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        draft = ""
                        live.send(text: text)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: PSMetrics.dockButton, height: PSMetrics.dockButton)
            .animation(.easeInOut(duration: 0.2), value: draft.isEmpty)
        }
        .frame(minHeight: height)
    }
}

/// The console's keyboard mode: the Ask field above the console; Live keeps running.
private struct ConsoleKeyboardField: View {
    let live: LiveSession
    @Binding var isOpen: Bool
    let glass: Namespace.ID

    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            ComposerField(text: $draft, placeholder: typeSize.isAccessibilitySize ? L("Ask…") : L("Ask PicShop…")) { text in
                live.send(text: text)
            }
            .focusBinding($focused)
            .glassEffectID("field", in: glass)
            if !draft.isEmpty {
                PSCircleButton(systemImage: "arrow.up", size: PSMetrics.dockButton, kind: .prominent, accessibilityLabel: L("Send")) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    live.send(text: text)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: draft.isEmpty)
        .task { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { isOpen = false }
        }
    }
}

/// The orb in the dock: a leaf, so levels, the activity and its progress
/// never re-evaluate the dock.
private struct DockOrb: View {
    let live: LiveSession
    let size: CGFloat
    /// Push-to-talk (resting only: a hold during Live does nothing).
    let allowsHold: Bool

    var body: some View {
        let state = live.state
        let activity = state == .acting ? live.activity : nil
        LiveOrbButton(size: size, state: state, meter: live.meter, isMuted: live.isMuted,
                      onTap: {
                          LiveTips.orbUsed()
                          live.orbTapped()
                      },
                      onHoldStart: allowsHold ? {
                          LiveTips.orbUsed()
                          live.beginDictation()
                      } : nil,
                      onHoldEnd: allowsHold ? { live.endDictation() } : nil)
            .actingProgress(activity?.progress)
            .liveAccessibility(activity: activity?.title, actions: live.isLive ? orbActions : nil)
    }

    private var orbActions: LiveOrbActions {
        let live = live
        return LiveOrbActions(setMuted: { live.setMuted($0) },
                              interrupt: {
                                  switch live.state {
                                  case .thinking, .speaking, .acting: live.orbTapped()
                                  default: break
                                  }
                              },
                              end: { live.end() })
    }
}

/// Reads the pending choice in a leaf, so the dock only depends on whether
/// there is one.
private struct LiveChoicesLeaf: View {
    let live: LiveSession
    var thumbnail: ((Int) async -> UIImage?)?
    var flat: Bool

    var body: some View {
        if let request = live.choices {
            ChoiceChipsRow(request: request, thumbnail: thumbnail) { choice in
                live.choose(choice)
            }
            .onCancel { live.dismissChoice() }
            .flat(flat)
        }
    }
}

/// One line floating over the picture: the reply to a command outside Live
/// (4 s, 7 s for errors), a notice, the words being dictated, the job running.
/// With a tool panel open during Live, it also carries the assistant's line.
/// Takes no layout space; the owner places it.
struct LiveReplyCapsule: View {
    enum Placement { case resting, overPanel }

    let live: LiveSession
    var placement: Placement = .resting

    private struct Message: Equatable {
        var id: String
        var text: String
        var symbol: String?
        var isProblem = false
        var truncatesHead = false
        var shimmers = false
        var action: LiveNotice.Action = .none
        var offersUndo = false
    }

    var body: some View {
        let message = currentMessage
        ZStack {
            if let message {
                capsule(message)
                    .id(message.id)
                    .transition(AnyTransition.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(PSMotion.appear, value: message?.id)
    }

    private var currentMessage: Message? {
        let state = live.state
        if placement == .overPanel, live.isLive {
            switch state {
            case .acting:
                if let activity = live.activity { return Message(id: "activity", text: activity.title, symbol: nil, shimmers: true) }
            case .speaking:
                let text = live.transcript.assistant
                if !text.isEmpty { return Message(id: "assistant-\(live.transcript.turnID)", text: text, symbol: nil) }
            case .hearing:
                let text = live.transcript.user.text
                if !text.isEmpty { return Message(id: "user-\(live.transcript.turnID)", text: text, symbol: "waveform", truncatesHead: true) }
            default:
                break
            }
        }
        if state == .dictating {
            let text = live.transcript.user.text
            return Message(id: "dictation", text: text.isEmpty ? L("Listening…") : text, symbol: "waveform", truncatesHead: true)
        }
        if let notice = live.notice {
            return Message(id: "notice-\(notice.id)", text: notice.text, symbol: notice.isProblem ? "exclamationmark.triangle.fill" : "info.circle",
                           isProblem: notice.isProblem, action: notice.action)
        }
        if !live.isLive, state == .acting, let activity = live.activity {
            return Message(id: "activity", text: activity.title, symbol: nil, shimmers: true)
        }
        if let reply = live.reply {
            return Message(id: "reply-\(reply.id)", text: reply.text,
                           symbol: reply.isProblem || reply.isError ? "exclamationmark.triangle.fill" : nil,
                           isProblem: reply.isProblem || reply.isError, offersUndo: live.undoOffer != nil)
        }
        return nil
    }

    private func capsule(_ message: Message) -> some View {
        HStack(spacing: 8) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(message.isProblem ? PSTheme.warning : PSTheme.textSecondary)
            }
            if message.shimmers {
                ShimmerText(message.text, font: .subheadline).lineLimit(1)
            } else {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(PSTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(message.truncatesHead ? .head : .tail)
            }
            if let title = actionTitle(message.action) {
                Button {
                    Haptics.tap()
                    live.performNoticeAction()
                } label: {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PSTheme.onPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(PSTheme.primary))
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.95))
            } else if message.offersUndo {
                Button {
                    Haptics.tap()
                    live.undoLastAction()
                } label: {
                    Label(L("Undo"), systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .psChipFill(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.95))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, message.action != .none || message.offersUndo ? 4 : 14)
        .frame(minHeight: 36)
        .psGlass()
        .accessibilityElement(children: .combine)
    }

    private func actionTitle(_ action: LiveNotice.Action) -> String? {
        switch action {
        case .none: return nil
        case .allowMicrophone: return L("Allow the microphone")
        case .openSettings: return L("Open Settings")
        }
    }
}

#if DEBUG
private struct LiveDockPreview: View {
    let scenario: LiveSession.PreviewScenario
    var compact = false
    @State private var live: LiveSession?

    var body: some View {
        VStack {
            Spacer()
            if let live {
                LiveDock(live: live, onTools: {})
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .environment(\.studioCompact, compact)
        .onAppear { if live == nil { live = LiveSession.preview(scenario) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("LiveDock resting") {
    LiveDockPreview(scenario: .resting)
}

#Preview("LiveDock console") {
    LiveDockPreview(scenario: .speaking)
}

#Preview("LiveDock cycle") {
    LiveDockPreview(scenario: .cycle)
}

#Preview("LiveDock choices") {
    LiveDockPreview(scenario: .choices)
}

#Preview("LiveDock notice") {
    LiveDockPreview(scenario: .problem)
}

#Preview("LiveDock compact") {
    LiveDockPreview(scenario: .acting, compact: true)
}
#endif
#endif
