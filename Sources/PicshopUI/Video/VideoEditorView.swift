#if canImport(SwiftUI) && canImport(AVKit) && canImport(UIKit)
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
        EditorChrome {
            VStack(spacing: 0) {
                PlayerPreview(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                transportBar
                TimelineView(session: session)
                    .frame(height: 118 + TimelineView.rulerHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        } top: {
            EditorTopBar(
                title: L("Video"),
                subtitle: "\(Int(session.timeline.renderSize.width)) × \(Int(session.timeline.renderSize.height)) · \(timecode(session.timeline.duration))",
                canUndo: session.history.canUndo, canRedo: session.history.canRedo,
                onClose: { session.teardown(); dismiss() },
                onUndo: { session.undo() }, onRedo: { session.redo() },
                onHelp: { session.showsHelp = true }, onExport: { session.showsExport = true })
        } bottom: {
            bottomArea
        }
        .overlay {
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
                    .padding(.top, 60)
                    .id(toast.id)
            }
        }
        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { VideoExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .video) { text in Task { await session.handleTranscript(text) } } }
        .fileImporter(isPresented: $session.showsMusicPicker, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            if case .success(let url) = result { Task { await session.addMusic(from: url) } }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    @State private var scrubStart: Double?

    /// Transport row. Dragging horizontally anywhere on the row scrubs the
    /// playhead (a second per 120 pt, with frame-fine control at slow speed).
    private var transportBar: some View {
        HStack(spacing: 14) {
            Text(timecode(session.player.currentTime)).font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).frame(width: 64, alignment: .leading)
                .contentTransition(.numericText())
            Spacer()
            GlassIconButton("backward.frame", label: L("Previous frame"), size: 34) { Task { await session.player.step(frames: -1, frameRate: session.timeline.frameRate) } }
            GlassIconButton(session.player.isPlaying ? "pause.fill" : "play.fill", label: session.player.isPlaying ? L("Pause") : L("Play"), tint: PSTheme.accent, isActive: true, size: 44) { session.player.togglePlayback() }
            GlassIconButton("forward.frame", label: L("Next frame"), size: 34) { Task { await session.player.step(frames: 1, frameRate: session.timeline.frameRate) } }
            Spacer()
            Text(timecode(session.timeline.duration)).font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if scrubStart == nil {
                        scrubStart = session.player.currentTime
                        Haptics.soft()
                    }
                    guard let start = scrubStart else { return }
                    let target = (start + Double(value.translation.width) / 120).clamped(to: 0...max(0, session.timeline.duration))
                    Task { await session.player.seek(to: target) }
                }
                .onEnded { _ in
                    scrubStart = nil
                    Haptics.tick()
                }
        )
    }

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let tool = session.activeTool {
                let group = VideoEditorSession.Tool.groups.first { $0.contains(tool) }
                let grouped = (group?.tools.count ?? 1) > 1
                ToolPanelContainer(title: grouped ? group?.title ?? tool.title : tool.title, symbol: grouped ? group?.symbol ?? tool.symbol : tool.symbol,
                                   onClose: { session.activeTool = nil },
                                   modes: grouped ? AnyView(ModeSegments(modes: group?.tools ?? [], selection: $session.activeTool, title: { $0.title }, symbol: { $0.symbol })) : nil) {
                    VideoToolPanel(session: session, tool: tool)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            if let app {
                VoiceStrip(voice: app.voice, isBusy: session.isProcessing, busyTitle: session.processingTitle,
                           transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                           showsHint: session.activeTool == nil,
                           onChoose: { session.choose(candidateIndex: $0) }, onChooseAll: { session.chooseAllCandidates() }, onCancel: { session.cancelClarification() })
            }
            HStack(spacing: 8) {
                GroupedToolDock(groups: VideoEditorSession.Tool.groups, selection: $session.activeTool)
                if let app { MicButton(voice: app.voice, isBusy: session.isProcessing) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .psDockBackground()
        .animation(PSMotion.standard, value: session.activeTool)
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
    @State private var poster: UIImage?
    @Namespace private var qualityIndicator

    private var isExporting: Bool { session.exportProgress != nil }

    /// Output frame for a quality, so the choice is concrete.
    private func outputSize(for quality: VideoExportOptions.Quality) -> (width: Int, height: Int) {
        let size = session.timeline.renderSize
        let longest = max(size.width, size.height)
        let cap: Double
        switch quality {
        case .high: cap = longest
        case .medium: cap = 1920
        case .low: cap = 1280
        }
        let scale = min(1, cap / max(1, longest))
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Rough file size from typical HEVC/H.264 bitrates.
    private func estimatedMegabytes(for quality: VideoExportOptions.Quality) -> Double {
        let megabitsPerSecond: Double
        switch quality {
        case .high: megabitsPerSecond = max(8, Double(outputSize(for: .high).width * outputSize(for: .high).height) / 1_000_000 * 5)
        case .medium: megabitsPerSecond = 10
        case .low: megabitsPerSecond = 5
        }
        return megabitsPerSecond * max(0, session.timeline.duration) / 8
    }

    private func subtitle(for quality: VideoExportOptions.Quality) -> String {
        switch quality {
        case .high: return L("Original")
        case .medium: return L("Balanced")
        case .low: return L("Small")
        }
    }

    private func title(for quality: VideoExportOptions.Quality) -> String {
        switch quality {
        case .high: return "HEVC"
        case .medium: return "1080p"
        case .low: return "720p"
        }
    }

    private var durationText: String {
        let total = max(0, session.timeline.duration)
        return String(format: "%d:%02d", Int(total) / 60, Int(total) % 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PSSpacing.large) {
                    preview
                    qualityPicker
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Output")).font(PSFont.headline(15))
                                let size = outputSize(for: quality)
                                Text("\(size.width) × \(size.height) · \(durationText) · ~\(String(format: "%.0f", estimatedMegabytes(for: quality))) MB")
                                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).contentTransition(.numericText())
                            }
                            Spacer()
                            Image(systemName: "film.stack").font(.system(size: 18, weight: .medium)).foregroundStyle(PSTheme.textTertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        Divider().overlay(PSTheme.hairline).padding(.leading, 16)
                        Toggle(isOn: $saveToPhotos) {
                            Text(L("Save to Photos")).font(PSFont.headline(15))
                        }
                        .tint(PSTheme.accent)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .psCard(cornerRadius: 18, shadow: false)
                    if let url = session.exportedURL, !isExporting {
                        ShareLink(item: url) { Label(L("Share last export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle())
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .animation(PSMotion.standard, value: quality)
                .animation(PSMotion.standard, value: session.exportedURL)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(isExporting) } }
            .onAppear { quality = app?.settings.videoExportQuality ?? .high }
            .interactiveDismissDisabled(isExporting)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Primary action, or the export progress in its place — the sheet stays
    /// put while the movie is written, so the percentage is where the eye is.
    @ViewBuilder private var footer: some View {
        Group {
            if let progress = session.exportProgress {
                VStack(spacing: 10) {
                    HStack {
                        Text(L("Exporting…")).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                        Spacer()
                        Text("\(Int(progress * 100)) %").font(PSFont.mono(13)).foregroundStyle(PSTheme.textSecondary).contentTransition(.numericText())
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(PSTheme.accentGradient)
                                .frame(width: max(8, geo.size.width * CGFloat(min(1, progress))))
                        }
                    }
                    .frame(height: 6)
                    .animation(PSMotion.numeric, value: progress)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .psCard(cornerRadius: 18, shadow: false)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                Button {
                    Haptics.confirm()
                    Task { await session.export(options: VideoExportOptions(quality: quality, saveToPhotos: saveToPhotos)) }
                } label: {
                    Label(saveToPhotos ? L("Save to Photos") : L("Export"), systemImage: saveToPhotos ? "photo.badge.arrow.down" : "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .animation(PSMotion.standard, value: isExporting)
    }

    /// Poster frame with the running time, so the sheet reads as the movie.
    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    PSTheme.surfaceElevated
                        .overlay(Image(systemName: "film").font(.system(size: 32, weight: .light)).foregroundStyle(PSTheme.textTertiary))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipped()
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                Text(durationText).font(PSFont.mono(12))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(12)
        }
        .task {
            guard poster == nil, let cg = await session.thumbnailer.poster(for: session.timeline) else { return }
            poster = UIImage(cgImage: cg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }

    private var qualityPicker: some View {
        HStack(spacing: 4) {
            ForEach(VideoExportOptions.Quality.allCases) { item in
                let isActive = quality == item
                Button {
                    Haptics.tick()
                    withAnimation(PSMotion.standard) { quality = item }
                } label: {
                    VStack(spacing: 2) {
                        Text(title(for: item)).font(PSFont.headline(14))
                        Text(subtitle(for: item)).font(PSFont.caption(10)).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.accentGradient)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.accentHighlight))
                                .matchedGeometryEffect(id: "quality", in: qualityIndicator)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .disabled(isExporting)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

extension VideoEditorSession.Tool {
    /// Dock entries, grouped by purpose. Sub-modes appear as segments in the panel.
    static var groups: [ToolGroup<VideoEditorSession.Tool>] {
        [
            ToolGroup(id: "cut", title: L("Cut"), symbol: "scissors", tools: [.cut, .speed, .frame]),
            ToolGroup(id: "color", title: L("Color"), symbol: "camera.filters", tools: [.adjust, .looks]),
            ToolGroup(id: "audio", title: L("Audio"), symbol: "speaker.wave.2", tools: [.audio]),
            ToolGroup(id: "text", title: L("Text"), symbol: "textformat", tools: [.text]),
            ToolGroup(id: "transitions", title: L("Transitions"), symbol: "square.stack.3d.down.right", tools: [.transitions]),
        ]
    }
}
#endif
