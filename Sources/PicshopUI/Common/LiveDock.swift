#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopIntent

/// The Ask field: a glass capsule that grows to four lines. Submitting hands
/// over the trimmed text and clears the field.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var isEnabled: Bool
    let onSubmit: (String) -> Void

    init(text: Binding<String>, placeholder: String, isEnabled: Bool = true, onSubmit: @escaping (String) -> Void) {
        _text = text
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...4)
            .font(.body)
            .foregroundStyle(PSTheme.textPrimary)
            .submitLabel(.send)
            .onSubmit(submit)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: PSMetrics.composerHeight, alignment: .leading)
            .psGlassField()
            .disabled(!isEnabled)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
    }
}

/// The editors' bottom dock: idea chips (or choices), then Outils, the Ask
/// field and the orb at rest; the Live console while a conversation runs.
///
/// The body reads only `live.state`, `isLive`, `isMuted`, `choices != nil`
/// and `ideas`: captions, activity and levels are read by leaves.
///
/// Phase 0: the resting row, a plain console and the chip rows. The morph,
/// the keyboard mode, the caption zone and the reply capsule follow.
struct LiveDock: View {
    let live: LiveSession
    let onTools: () -> Void
    var candidateThumbnail: ((Int) async -> UIImage?)?

    @State private var draft = ""

    init(live: LiveSession, onTools: @escaping () -> Void, candidateThumbnail: ((Int) async -> UIImage?)? = nil) {
        self.live = live
        self.onTools = onTools
        self.candidateThumbnail = candidateThumbnail
    }

    var body: some View {
        VStack(spacing: 10) {
            if live.choices != nil {
                LiveChoicesLeaf(live: live, thumbnail: candidateThumbnail)
            } else {
                IdeaChipsRow(items: ideaItems, isEnabled: live.state != .acting,
                             onChoose: { id in if let idea = findIdea(id) { live.choose(idea) } },
                             onDismiss: { id in if let idea = findIdea(id) { live.dismiss(idea) } })
            }
            PSGlassContainer(spacing: 12) {
                if live.isLive {
                    console
                } else {
                    restingRow
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .animation(PSMotion.morph, value: live.isLive)
    }

    private var restingRow: some View {
        HStack(spacing: 8) {
            PSCircleButton(systemImage: "slider.horizontal.3", size: PSMetrics.dockButton, accessibilityLabel: L("Tools"), action: onTools)
            ComposerField(text: $draft, placeholder: L("Ask PicShop…"), isEnabled: live.state != .acting) { text in
                live.send(text: text)
            }
            if draft.isEmpty {
                LiveOrbButton(size: PSMetrics.orbComposer, state: live.state, meter: live.meter, isMuted: live.isMuted,
                              onTap: { live.orbTapped() },
                              onHoldStart: { live.beginDictation() },
                              onHoldEnd: { live.endDictation() })
            } else {
                PSCircleButton(systemImage: "arrow.up", size: PSMetrics.dockButton, kind: .prominent, accessibilityLabel: L("Send")) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    live.send(text: text)
                }
            }
        }
        .frame(minHeight: PSMetrics.composerHeight)
    }

    private var console: some View {
        HStack(spacing: 0) {
            PSCircleButton(systemImage: "slider.horizontal.3", size: PSMetrics.dockButton, accessibilityLabel: L("Tools"), action: onTools)
            Spacer(minLength: 8)
            PSCircleButton(systemImage: live.isMuted ? "mic.slash.fill" : "mic.fill", size: PSMetrics.dockButton,
                           kind: live.isMuted ? .prominent : .glass,
                           accessibilityLabel: live.isMuted ? L("Unmute microphone") : L("Mute microphone")) {
                live.setMuted(!live.isMuted)
            }
            Spacer(minLength: 8)
            LiveOrbButton(size: PSMetrics.orbConsole, state: live.state, meter: live.meter, isMuted: live.isMuted,
                          onTap: { live.orbTapped() })
            Spacer(minLength: 8)
            PSCircleButton(systemImage: "keyboard", size: PSMetrics.dockButton, accessibilityLabel: L("Keyboard")) {}
            Spacer(minLength: 8)
            PSCircleButton(systemImage: "xmark", size: PSMetrics.dockButton, kind: .danger, accessibilityLabel: L("End Live")) {
                live.end()
            }
        }
        .frame(height: PSMetrics.consoleHeight)
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

/// Reads the pending choice in a leaf, so the dock only depends on whether
/// there is one.
private struct LiveChoicesLeaf: View {
    let live: LiveSession
    var thumbnail: ((Int) async -> UIImage?)?

    var body: some View {
        if let request = live.choices {
            ChoiceChipsRow(request: request, thumbnail: thumbnail) { choice in
                live.choose(choice)
            }
        }
    }
}

#if DEBUG
private struct LiveDockPreview: View {
    let scenario: LiveSession.PreviewScenario
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
        .onAppear { if live == nil { live = LiveSession.preview(scenario) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("LiveDock resting") {
    LiveDockPreview(scenario: .resting)
}

#Preview("LiveDock cycle") {
    LiveDockPreview(scenario: .cycle)
}

#Preview("LiveDock choices") {
    LiveDockPreview(scenario: .choices)
}
#endif
#endif
