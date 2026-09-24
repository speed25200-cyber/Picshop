#if canImport(SwiftUI) && canImport(AVKit) && canImport(UIKit)
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import PicshopCore
import PicshopIntent
import PicshopVideo

/// The video editing screen in the studio shell: the player edge to edge
/// between the top bar and the filmstrip, Live at the bottom, every manual
/// tool behind Outils.
///
/// The body reads only coarse mirrors (canUndo, canRedo, undoLabels, the open
/// tool, whether work runs); the playhead, the frames and Live's levels are
/// read by leaves.
public struct VideoEditorView: View {
    @State var session: VideoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app

    public init(session: VideoEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        StudioChrome(bar: bar, actions: actions, live: session.live,
                     catalog: { VideoToolCatalog.make(session: session) },
                     isToolOpen: session.activeTool != nil) {
            VideoCanvas(session: session)
        } panel: {
            if let tool = session.activeTool {
                VideoToolCard(session: session, tool: tool)
            }
        }
        // Progress and toasts live in their own view, so a progress tick never
        // re-evaluates the player and the dock.
        .overlay { EditorStatusOverlay(session: session) }
        .task { await open() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { VideoExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) {
            HelpSheet(mode: .video) { text in session.live.send(text: text) }
        }
        .fileImporter(isPresented: $session.showsMusicPicker, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            if case .success(let url) = result { Task { await session.addMusic(from: url) } }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private var bar: StudioBar {
        StudioBar(canUndo: session.canUndo, canRedo: session.canRedo, undoLabels: session.undoLabels, isBusy: session.isProcessing)
    }

    private var actions: StudioActions {
        let session = session
        let dismiss = dismiss
        // A step undone under a running job would only make it drop its result.
        return StudioActions(close: { dismiss() },
                             undo: { guard !session.isProcessing else { return }; session.undo() },
                             redo: { guard !session.isProcessing else { return }; session.redo() },
                             undoSteps: { steps in guard !session.isProcessing else { return }; session.undo(steps: steps) },
                             revert: { guard !session.isProcessing else { return }; session.revert() },
                             export: {
                                 session.player.pause()
                                 session.showsExport = true
                             })
    }

    /// Configures the session, then starts Live on its own when Settings asks for it.
    private func open() async {
        await session.configure()
        guard app?.settings.liveAutoStart == true else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        session.live.start()
    }
}

/// Minutes, seconds and frames, the way an editor reads a timeline.
func psTimecode(_ seconds: Double, frameRate: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = Int(total) % 60
    let frames = Int((total - floor(total)) * max(1, frameRate))
    return String(format: "%02d:%02d.%02d", minutes, secs, frames)
}

/// Minutes and seconds ('mm:ss'), for the timecode pill.
func psClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded(.down))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: - Canvas

/// The canvas under the studio's bars: the player fitted between the top bar
/// and the filmstrip, the filmstrip just above the dock (hidden while the full
/// timeline is open in its panel).
struct VideoCanvas: View {
    let session: VideoEditorSession
    @Environment(\.studioEdges) private var studioEdges
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let showsFilmstrip = session.activeTool != .cut
        GeometryReader { proxy in
            let chrome = studioEdges.insets(over: proxy.frame(in: .global))
            VStack(spacing: 0) {
                Color.clear.frame(height: chrome.top + 8)
                PlayerStage(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsFilmstrip {
                    FilmstripScrubber(session: session)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
                Color.clear.frame(height: chrome.bottom + (showsFilmstrip ? 16 : 8))
            }
            .animation(reduceMotion ? nil : PSMotion.standard, value: chrome)
        }
    }
}

/// The player, edge to edge: tap to play or pause, double-tap a side to skip
/// five seconds, the timecode in a pill at the bottom left. The candidate boxes
/// of a pending choice are drawn over the frame and can be tapped.
struct PlayerStage: View {
    @Bindable var session: VideoEditorSession
    /// The glyph that flashes in the centre after a tap (play.fill or pause.fill).
    @State private var flash: String?
    @State private var flashID = 0
    /// -5 or +5 after a double tap on a side.
    @State private var skip: Int?
    @State private var skipID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fitted edge to edge: no side inset, the height left by the bars.
    private func videoFrame(in container: CGSize) -> CGRect {
        let aspect = CGFloat(max(0.1, session.timeline.renderSize.aspectRatio))
        var size = CGSize(width: container.width, height: container.width / aspect)
        if size.height > container.height { size = CGSize(width: container.height * aspect, height: container.height) }
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = videoFrame(in: proxy.size)
            // Rounded only when the frame stands clear of the screen's sides.
            let radius: CGFloat = frame.width < proxy.size.width - 1 ? 14 : 0
            let candidates = session.candidateOverlays
            ZStack {
                // The shadow on a sibling shape: the video layer itself is never drawn offscreen.
                if radius > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                PlayerLayerView(player: session.player.player, cornerRadius: radius)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityElement()
                    .accessibilityLabel(L("Video"))
                    .accessibilityAddTraits(.startsMediaSession)
                    .accessibilityAction { togglePlayback() }
                if !candidates.isEmpty {
                    CandidateBoxes(candidates: candidates, frame: frame)
                }
                if session.activeTool == .overlay {
                    OverlayArrangeLayer(session: session, frame: frame)
                }
                if session.activeTool == .motion {
                    MotionFramingLayer(session: session, frame: frame)
                }
                // The explicitly selected clip only: resolving the clip under the
                // playhead here would re-evaluate the stage on every tick.
                if let id = session.selectedClipID, let clip = session.timeline.clips.first(where: { $0.id == id }), let label = clip.processedLabel {
                    GlassChip(label, systemImage: "sparkles").position(x: frame.minX + 60, y: frame.minY + 22)
                }
                TimecodePill(player: session.player)
                    .padding(8)
                    .frame(width: frame.width, height: frame.height, alignment: .bottomLeading)
                    .position(x: frame.midX, y: frame.midY)
                if let flash {
                    Image(systemName: flash)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .psGlass(shape: AnyShape(Circle()))
                        .position(x: frame.midX, y: frame.midY)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                        .id(flashID)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let skip {
                    SkipBadge(seconds: skip)
                        .position(x: skip < 0 ? frame.minX + frame.width / 6 : frame.maxX - frame.width / 6, y: frame.midY)
                        .transition(.opacity)
                        .id(skipID)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { location in doubleTap(at: location, frame: frame) }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in tap(at: location, frame: frame) }
        }
    }

    private func normalized(_ location: CGPoint, in frame: CGRect) -> PSPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let point = PSPoint(x: Double((location.x - frame.minX) / frame.width), y: Double((location.y - frame.minY) / frame.height))
        return point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1 ? point : nil
    }

    private func tap(at location: CGPoint, frame: CGRect) {
        // A pending choice: a tap on a numbered box chooses it.
        if session.pendingClarification != nil, let point = normalized(location, in: frame) {
            session.tapPreview(at: point)
            return
        }
        togglePlayback()
    }

    private func doubleTap(at location: CGPoint, frame: CGRect) {
        let third = frame.width / 3
        guard frame.width > 0, location.x < frame.minX + third || location.x > frame.maxX - third else {
            togglePlayback()
            return
        }
        let delta = location.x < frame.minX + third ? -5 : 5
        Haptics.tick()
        let player = session.player
        let target = (player.currentTime + Double(delta)).clamped(to: 0...max(0, player.duration))
        Task { await player.seek(to: target) }
        skipID += 1
        let id = skipID
        withAnimation(PSMotion.quick) { skip = delta }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard skipID == id else { return }
            withAnimation(PSMotion.quick) { skip = nil }
        }
    }

    private func togglePlayback() {
        let player = session.player
        let willPlay = !player.isPlaying
        player.togglePlayback()
        Haptics.tap()
        flashID += 1
        let id = flashID
        withAnimation(PSMotion.quick) { flash = willPlay ? "play.fill" : "pause.fill" }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard flashID == id else { return }
            withAnimation(PSMotion.quick) { flash = nil }
        }
        UIAccessibility.post(notification: .announcement, argument: willPlay ? L("Play") : L("Pause"))
    }
}

/// The numbered boxes of a pending choice, over the frame.
private struct CandidateBoxes: View {
    let candidates: [ObjectCandidate]
    let frame: CGRect

    var body: some View {
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
        .accessibilityHidden(true)
    }
}

/// 'gobackward.5' or 'goforward.5' after a double tap on a side.
private struct SkipBadge: View {
    let seconds: Int

    var body: some View {
        Image(systemName: seconds < 0 ? "gobackward.5" : "goforward.5")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .psGlass(shape: AnyShape(Circle()), variant: .clear)
    }
}

/// 'mm:ss / mm:ss' at the player's bottom left. A leaf of its own: the playhead
/// moves many times a second and must re-evaluate nothing else.
struct TimecodePill: View {
    let player: TimelinePlayer

    var body: some View {
        Text(verbatim: "\(psClock(player.currentTime)) / \(psClock(player.duration))")
            .font(PSFont.timecode(12))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .psGlass(variant: .clear)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityLabel(L("Timecode"))
            .accessibilityValue(Text(verbatim: "\(psClock(player.currentTime)) / \(psClock(player.duration))"))
    }
}

/// AVPlayer surface. The corners are cut by the layer itself (a SwiftUI clip
/// would draw the moving video offscreen every frame).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var cornerRadius: CGFloat = 0

    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = cornerRadius
        view.layer.masksToBounds = cornerRadius > 0
        return view
    }

    func updateUIView(_ view: View, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if view.layer.cornerRadius != cornerRadius {
            view.layer.cornerRadius = cornerRadius
            view.layer.masksToBounds = cornerRadius > 0
        }
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
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.selection)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.75))
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
#endif
