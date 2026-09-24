#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// What Home's dock can start.
struct HomeDockActions {
    var pick: (PHPickerFilter) -> Void
    var importPDF: () -> Void
    var magicMovie: () -> Void
    /// Picks media, then the editor opens running the shortcut.
    var magic: (MagicShortcut) -> Void
    var open: (UUID) -> Void
}

/// Home's bottom bar, from the studio's own pieces: '+' to start something,
/// three ideas, the Ask field and the orb. The orb dictates one request (tap,
/// or hold to talk); typed or spoken, `HomeCommands` reads it on the device.
/// Home has no Live conversation: nothing leaves the phone from here.
struct HomeDock: View {
    let app: AppEnvironment
    /// The kind of media edited last, which orders the ideas.
    let lastKind: ProjectSummary.Kind?
    let projects: () -> [ProjectSummary]
    let actions: HomeDockActions

    @State private var draft = ""
    @State private var reply: HomeReply?
    @State private var meter = LiveMeter()

    private static let replySeconds: Double = 4
    private static let problemSeconds: Double = 7

    var body: some View {
        let voice = app.voice
        VStack(spacing: 10) {
            IdeaChipsRow(items: chips) { id in choose(id) }
            PSGlassContainer(spacing: 12) {
                HStack(spacing: 8) {
                    plusMenu
                    ComposerField(text: $draft, placeholder: L("Ask PicShop…")) { text in run(text) }
                    if draft.isEmpty {
                        LiveOrbButton(size: PSMetrics.orbComposer, state: voice.isListening ? .dictating : .off, meter: meter,
                                      onTap: tapOrb, onHoldStart: holdStart, onHoldEnd: holdEnd)
                    } else {
                        PSCircleButton(systemImage: "arrow.up", size: PSMetrics.dockButton, kind: .prominent, accessibilityLabel: L("Send")) {
                            let text = draft
                            draft = ""
                            run(text)
                        }
                    }
                }
                .frame(minHeight: PSMetrics.composerHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        // The reply floats above the dock and takes no layout space.
        .overlay(alignment: .top) {
            HomeReplyLayer(voice: voice, reply: reply)
                .padding(.horizontal, 16)
                .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 12 }
        }
        .background { HomeMeterFeed(voice: voice, meter: meter) }
        .animation(PSMotion.quick, value: draft.isEmpty)
        .task(id: reply?.id) {
            guard let current = reply else { return }
            try? await Task.sleep(for: .seconds(current.isProblem ? Self.problemSeconds : Self.replySeconds))
            if reply?.id == current.id { reply = nil }
        }
        .onChange(of: voice.state) { _, state in
            if case .unavailable(let message) = state { show(message, isProblem: true) }
        }
        .onAppear(perform: claimVoice)
        .onDisappear {
            if app.voice.isListening { app.voice.cancel() }
        }
        // Magic Tap (two-finger double tap) dictates, as on the editors.
        .accessibilityAction(.magicTap) { tapOrb() }
    }

    // MARK: Pieces

    private var plusMenu: some View {
        Menu {
            Button { actions.pick(.images) } label: { Label(L("Photo"), systemImage: "photo") }
            Button { actions.pick(.videos) } label: { Label(L("Video"), systemImage: "video") }
            Button { actions.importPDF() } label: { Label(L("PDF"), systemImage: "doc.richtext") }
            Divider()
            Button { actions.magicMovie() } label: { Label(L("Magic Movie"), systemImage: "film.stack") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PSTheme.textPrimary)
                .frame(width: PSMetrics.dockButton, height: PSMetrics.dockButton)
                .modifier(HomeCircleSurface())
                .contentShape(Circle())
        }
        .accessibilityLabel(L("New"))
    }

    /// Three ways to start, led by the kind of media edited last.
    private var chips: [IdeaChipModel] {
        let captions = IdeaChipModel(id: "captions", title: L("Caption a video"), symbol: "captions.bubble")
        let clean = IdeaChipModel(id: "clean", title: L("Clean up a photo"), symbol: "eraser")
        let movie = IdeaChipModel(id: "movie", title: L("Create a magic movie"), symbol: "film.stack")
        switch lastKind {
        case .video?: return [captions, movie, clean]
        default: return [clean, captions, movie]
        }
    }

    private func choose(_ id: String) {
        switch id {
        case "captions": actions.magic(.captions)
        case "clean": actions.magic(.eraseObjects)
        case "movie": actions.magicMovie()
        default: break
        }
    }

    // MARK: Voice

    /// Home owns the dictation handler while it is on screen (an editor's
    /// Live session takes it when one opens).
    private func claimVoice() {
        app.voice.onFinalTranscript = { text in run(text) }
    }

    private func tapOrb() {
        let voice = app.voice
        if voice.isListening {
            voice.stop()
        } else {
            listen(.tapToTalk)
        }
    }

    private func holdStart() {
        if app.voice.isListening { app.voice.cancel() }
        listen(.pushToTalk)
    }

    private func holdEnd() {
        app.voice.stop()
    }

    private func listen(_ mode: VoiceController.Mode) {
        claimVoice()
        reply = nil
        app.voice.mode = mode
        app.voice.start()
    }

    // MARK: Commands

    private func run(_ text: String) {
        guard let command = HomeCommands.interpret(text, projects: projects()) else { return }
        switch command {
        case .magic(let shortcut):
            Haptics.tap()
            actions.magic(shortcut)
        case .magicMovie:
            Haptics.magic()
            actions.magicMovie()
        case .pick(let kind):
            switch kind {
            case .photo: actions.pick(.images)
            case .video: actions.pick(.videos)
            case .pdf: actions.importPDF()
            }
        case .open(let id):
            actions.open(id)
        case .reply(let line, let isProblem):
            show(line, isProblem: isProblem)
        }
    }

    private func show(_ text: String, isProblem: Bool) {
        if isProblem { Haptics.warning() }
        reply = HomeReply(text: text, isProblem: isProblem)
    }
}

/// A line Home says back.
struct HomeReply: Equatable {
    let id = UUID()
    let text: String
    let isProblem: Bool
}

/// Above the dock: the words being heard while dictating, else the last reply.
/// A leaf, so the running transcript redraws only this.
private struct HomeReplyLayer: View {
    let voice: VoiceController
    let reply: HomeReply?

    var body: some View {
        ZStack {
            if voice.isListening {
                capsule(voice.partialTranscript.isEmpty ? L("Listening…") : voice.partialTranscript,
                        color: voice.partialTranscript.isEmpty ? PSTheme.captionVolatile : PSTheme.captionPrimary)
                    .transition(.opacity)
            } else if let reply {
                capsule(reply.text, color: reply.isProblem ? PSTheme.warning : PSTheme.captionPrimary)
                    .id(reply.id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(PSMotion.standard, value: voice.isListening)
        .animation(PSMotion.standard, value: reply?.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func capsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, PSSpacing.large)
            .padding(.vertical, 10)
            .psGlass()
            .frame(maxWidth: .infinity)
    }
}

/// Moves the microphone level into the orb's meter. Only this leaf and the
/// orb redraw at audio rate.
private struct HomeMeterFeed: View {
    let voice: VoiceController
    let meter: LiveMeter

    var body: some View {
        Color.clear
            .onChange(of: voice.level) { _, level in
                meter.input = voice.isListening ? min(1, max(0, level)) : 0
            }
            .onChange(of: voice.isListening) { _, listening in
                if !listening { meter.input = 0 }
            }
            .accessibilityHidden(true)
    }
}
#endif
