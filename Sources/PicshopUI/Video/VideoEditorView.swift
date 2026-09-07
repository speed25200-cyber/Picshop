#if canImport(SwiftUI) && canImport(AVKit)
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import PicshopCore
import PicshopIntent
import PicshopVideo

/// The video editing screen: player, timeline, tools and the voice orb.
public struct VideoEditorView: View {
    @State var session: VideoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app

    public init(session: VideoEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        ZStack {
            PSTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                PlayerPreview(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                transportBar
                TimelineView(session: session)
                    .frame(height: 118)
                bottomArea
            }
            if session.isProcessing {
                ProgressHUD(title: session.processingTitle, progress: session.processingProgress)
            }
            if let progress = session.exportProgress {
                ProgressHUD(title: L("Exporting…"), progress: progress)
            }
        }
        .overlay(alignment: .top) {
            if let toast = session.toast {
                ToastView(text: toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", tint: toast.isError ? PSTheme.danger : PSTheme.success)
                    .padding(.top, 64)
                    .id(toast.id)
            }
        }
        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { VideoExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .video) }
        .fileImporter(isPresented: $session.showsMusicPicker, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            if case .success(let url) = result { Task { await session.addMusic(from: url) } }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton("chevron.left", label: L("Close")) { session.teardown(); dismiss() }
            Spacer()
            PSGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassIconButton("arrow.uturn.backward", label: L("Undo")) { session.undo() }.disabled(!session.history.canUndo).opacity(session.history.canUndo ? 1 : 0.4)
                    GlassIconButton("arrow.uturn.forward", label: L("Redo")) { session.redo() }.disabled(!session.history.canRedo).opacity(session.history.canRedo ? 1 : 0.4)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                GlassIconButton("questionmark", label: L("Help")) { session.showsHelp = true }
                GlassIconButton("square.and.arrow.up", label: L("Export"), tint: PSTheme.accent, isActive: true) { session.showsExport = true }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    private var transportBar: some View {
        HStack(spacing: 14) {
            Text(timecode(session.player.currentTime)).font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).frame(width: 64, alignment: .leading)
            Spacer()
            GlassIconButton("backward.frame", label: L("Previous frame"), size: 36) { Task { await session.player.step(frames: -1, frameRate: session.timeline.frameRate) } }
            GlassIconButton(session.player.isPlaying ? "pause.fill" : "play.fill", label: session.player.isPlaying ? L("Pause") : L("Play"), size: 46) { session.player.togglePlayback() }
            GlassIconButton("forward.frame", label: L("Next frame"), size: 36) { Task { await session.player.step(frames: 1, frameRate: session.timeline.frameRate) } }
            Spacer()
            Text(timecode(session.timeline.duration)).font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    private var bottomArea: some View {
        VStack(spacing: 10) {
            if let app {
                CommandFeedbackView(voice: app.voice, transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                                    showsTranscript: app.settings.showsVoiceTranscript,
                                    onChoose: { session.choose(candidateIndex: $0) }, onChooseAll: { session.chooseAllCandidates() }, onCancel: { session.cancelClarification() })
                    .padding(.horizontal, 16)
            }
            if let tool = session.activeTool {
                VideoToolPanel(session: session, tool: tool).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            dock
        }
        .padding(.bottom, 6)
        .animation(.spring(duration: 0.35), value: session.activeTool)
    }

    private var dock: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(VideoEditorSession.Tool.allCases) { tool in
                        let isActive = session.activeTool == tool
                        Button {
                            Haptics.tap()
                            withAnimation(.spring(duration: 0.3)) { session.activeTool = isActive ? nil : tool }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tool.symbol).font(.system(size: 18, weight: .semibold))
                                Text(tool.title).font(PSFont.caption(10))
                            }
                            .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
                            .frame(width: 60, height: 54)
                            .background(isActive ? PSTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tool.title)
                        if tool == .audio { Spacer(minLength: 80) }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 30, style: .continuous)))
            .padding(.horizontal, 16)
            if let app {
                VoiceOrb(voice: app.voice, isBusy: session.isProcessing).offset(y: -22)
            }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let frames = Int((total - floor(total)) * max(1, session.timeline.frameRate))
        return String(format: "%02d:%02d.%02d", minutes, secs, frames)
    }
}

/// AVPlayer surface with tap-to-choose overlays.
struct PlayerPreview: View {
    @Bindable var session: VideoEditorSession

    private func videoFrame(in container: CGSize) -> CGRect {
        let aspect = CGFloat(max(0.1, session.timeline.renderSize.aspectRatio))
        let available = CGSize(width: container.width - 24, height: container.height - 12)
        var size = CGSize(width: available.width, height: available.width / aspect)
        if size.height > available.height { size = CGSize(width: available.height * aspect, height: available.height) }
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = videoFrame(in: proxy.size)
            let candidates = session.candidateOverlays
            ZStack {
                PlayerLayerView(player: session.player.player)
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .position(x: frame.midX, y: frame.midY)
                    .onTapGesture { location in
                        let point = PSPoint(x: Double((location.x - frame.minX) / frame.width), y: Double((location.y - frame.minY) / frame.height))
                        if point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 { session.tapPreview(at: point) }
                    }
                Canvas { context, _ in
                    for (index, candidate) in candidates.enumerated() {
                        let rect = CGRect(x: frame.minX + candidate.boundingBox.minX * frame.width, y: frame.minY + candidate.boundingBox.minY * frame.height,
                                          width: candidate.boundingBox.width * frame.width, height: candidate.boundingBox.height * frame.height)
                        let path = Path(roundedRect: rect, cornerRadius: 10)
                        context.stroke(path, with: .color(PSTheme.accent), lineWidth: 2.5)
                        context.fill(path, with: .color(PSTheme.accent.opacity(0.12)))
                        let badge = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 26, height: 26)
                        context.fill(Path(ellipseIn: badge), with: .color(PSTheme.accent))
                        context.draw(Text("\(index + 1)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.black), at: CGPoint(x: badge.midX, y: badge.midY))
                    }
                }
                .allowsHitTesting(false)
                if let clip = session.selectedClip, let label = clip.processedLabel {
                    GlassChip(label, systemImage: "sparkles").position(x: frame.minX + 60, y: frame.minY + 22)
                }
            }
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: View, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

struct VideoExportSheet: View {
    @Bindable var session: VideoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var quality: VideoExportOptions.Quality = .high
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Quality")) {
                    Picker(L("Quality"), selection: $quality) {
                        ForEach(VideoExportOptions.Quality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Text("\(Int(session.timeline.renderSize.width)) × \(Int(session.timeline.renderSize.height)) · \(String(format: "%.1f", session.timeline.duration)) s")
                        .font(PSFont.caption()).foregroundStyle(PSTheme.textSecondary)
                }
                Section { Toggle(L("Save to Photos"), isOn: $saveToPhotos) }
                Section {
                    Button { Task { await session.export(options: VideoExportOptions(quality: quality, saveToPhotos: saveToPhotos)) } } label: {
                        Label(L("Export"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle()).listRowBackground(Color.clear)
                    if let url = session.exportedURL {
                        ShareLink(item: url) { Label(L("Share last export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle()).listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(L("Export"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            .onAppear { quality = app?.settings.videoExportQuality ?? .high }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
#endif
