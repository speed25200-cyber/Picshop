#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopVideo

/// Scrubbable filmstrip timeline with clip selection and trim handles.
struct TimelineView: View {
    @Bindable var session: VideoEditorSession
    @State private var pixelsPerSecond: CGFloat = 60
    @State private var steadyScale: CGFloat = 60
    @State private var trimDrag: TrimDrag?
    @State private var position = ScrollPosition(edge: .leading)

    enum Edge { case leading, trailing }

    struct TrimDrag {
        var clipID: UUID
        var edge: Edge
        var originalRange: TimeSpan
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let contentWidth = CGFloat(session.timeline.duration) * pixelsPerSecond
            Group {
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ruler(contentWidth: contentWidth, leading: width / 2)
                        HStack(spacing: 3) {
                            ForEach(Array(session.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                                ClipView(session: session, clip: clip, index: index, pixelsPerSecond: pixelsPerSecond, trimDrag: $trimDrag)
                            }
                        }
                        .padding(.horizontal, width / 2)
                        .offset(y: TimelineView.rulerHeight)
                        overlaysLane(width: width)
                    }
                    .frame(width: contentWidth + width, alignment: .leading)
                    .background(GeometryReader { inner in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: -inner.frame(in: .named("timeline")).minX)
                    })
                }
                .coordinateSpace(name: "timeline")
                .scrollPosition($position)
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    guard !session.player.isPlaying, trimDrag == nil else { return }
                    let time = Double(offset / pixelsPerSecond)
                    if abs(time - session.player.currentTime) > 0.02 { session.player.scrub(to: time) }
                }
            }
            .overlay(alignment: .top) {
                // Playhead: a capped needle, like the one in Final Cut, so the
                // current frame reads at a glance even over busy thumbnails.
                VStack(spacing: 0) {
                    Capsule().fill(PSTheme.accent).frame(width: 10, height: 5)
                    Rectangle().fill(PSTheme.accent).frame(width: 2)
                }
                .frame(maxHeight: .infinity)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .shadow(color: PSTheme.accent.opacity(0.55), radius: 5)
                .allowsHitTesting(false)
            }
            .gesture(MagnifyGesture().onChanged { value in
                pixelsPerSecond = min(400, max(12, steadyScale * value.magnification))
            }.onEnded { _ in steadyScale = pixelsPerSecond })
            .overlay {
                // Following the playhead must not re-evaluate the filmstrip on
                // every tick, so the observation lives in a leaf view.
                PlayheadFollower(player: session.player, pixelsPerSecond: pixelsPerSecond, position: $position)
            }
        }
        .psCard(cornerRadius: 18, shadow: false)
    }

    static let rulerHeight: CGFloat = 16

    /// Time ruler: labelled ticks whose spacing follows the zoom, so a
    /// second stays legible whether the strip is pinched in or out.
    private func ruler(contentWidth: CGFloat, leading: CGFloat) -> some View {
        let major: Double = pixelsPerSecond >= 200 ? 1 : (pixelsPerSecond >= 80 ? 2 : (pixelsPerSecond >= 40 ? 5 : (pixelsPerSecond >= 16 ? 10 : 30)))
        let minor = major / 5
        let duration = max(0, session.timeline.duration)
        return Canvas(rendersAsynchronously: true) { context, size in
            let baseline = size.height - 1
            var index = 0
            while true {
                let t = Double(index) * minor
                guard t <= duration + 0.001 else { break }
                defer { index += 1 }
                let x = leading + CGFloat(t) * pixelsPerSecond
                let isMajor = index % 5 == 0
                let height: CGFloat = isMajor ? 6 : 3
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: baseline))
                tick.addLine(to: CGPoint(x: x, y: baseline - height))
                context.stroke(tick, with: .color(Color.white.opacity(isMajor ? 0.5 : 0.22)), lineWidth: 1)
                if isMajor {
                    let total = Int(t.rounded())
                    let label = String(format: "%d:%02d", total / 60, total % 60)
                    context.draw(Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.white.opacity(0.55)),
                                 at: CGPoint(x: x + 3, y: 5), anchor: .leading)
                }
            }
        }
        .frame(width: contentWidth + leading * 2, height: TimelineView.rulerHeight)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func overlaysLane(width: CGFloat) -> some View {
        ForEach(session.timeline.overlays) { overlay in
            let x = width / 2 + CGFloat(overlay.span.start) * pixelsPerSecond
            HStack(spacing: 4) {
                Image(systemName: "textformat").font(.system(size: 9, weight: .bold))
                Text(overlay.textElement?.text ?? L("Overlay")).font(PSFont.caption(10)).lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 6).frame(height: 18)
            .frame(width: max(30, CGFloat(overlay.span.duration) * pixelsPerSecond), alignment: .leading)
            .background(PSTheme.warning, in: Capsule())
            .offset(x: x, y: 96 + TimelineView.rulerHeight)
        }
        ForEach(session.timeline.audioTracks) { track in
            let x = width / 2 + CGFloat(track.timelineStart) * pixelsPerSecond
            HStack(spacing: 4) {
                Image(systemName: "music.note").font(.system(size: 9, weight: .bold))
                Text(track.name).font(PSFont.caption(10)).lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 6).frame(height: 18)
            .frame(width: max(30, CGFloat(min(track.sourceRange.duration, session.timeline.duration - track.timelineStart)) * pixelsPerSecond), alignment: .leading)
            .background(PSTheme.success, in: Capsule())
            .offset(x: x, y: 96 + TimelineView.rulerHeight)
        }
    }
}

/// Scrolls the timeline to keep up with the playhead. A leaf view, so the
/// player's ticks invalidate nothing but itself.
private struct PlayheadFollower: View {
    let player: TimelinePlayer
    let pixelsPerSecond: CGFloat
    @Binding var position: ScrollPosition

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: player.currentTime) { _, time in
                guard player.isPlaying else { return }
                position.scrollTo(x: CGFloat(time) * pixelsPerSecond)
            }
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ClipView: View {
    @Bindable var session: VideoEditorSession
    let clip: VideoClip
    let index: Int
    let pixelsPerSecond: CGFloat
    @Binding var trimDrag: TimelineView.TrimDrag?
    @State private var thumbnails: [UIImage] = []

    private var isSelected: Bool { session.selectedClip?.id == clip.id }
    private var width: CGFloat { max(24, CGFloat(clip.timelineDuration) * pixelsPerSecond) }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 60, height: 84).clipped()
                }
            }
            .frame(width: width, height: 84, alignment: .leading)
            .clipped()
            .background(PSTheme.surfaceElevated)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if clip.speed != 1 { GlassChipMini(text: "×\(formatted(clip.speed))") }
                    if clip.isMuted { GlassChipMini(text: "", symbol: "speaker.slash.fill") }
                    if clip.look != .original { GlassChipMini(text: clip.look.englishName) }
                    if clip.transitionOut != nil { GlassChipMini(text: "", symbol: "square.stack.3d.down.right") }
                }
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if width > 72 { GlassChipMini(text: formattedDuration).padding(4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? PSTheme.accent : PSTheme.hairline, lineWidth: isSelected ? 2.5 : 1))
            .shadow(color: PSTheme.accent.opacity(isSelected ? 0.45 : 0), radius: 8)
            .opacity(session.selectedClip == nil || isSelected ? 1 : 0.7)
            .animation(PSMotion.quick, value: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tick()
                session.selectedClipID = clip.id
                if let span = session.timeline.span(of: clip.id) { session.player.scrub(to: span.start + 0.01) }
            }
            if isSelected {
                trimHandle(edge: .leading).frame(width: 16, height: 84)
                trimHandle(edge: .trailing).frame(width: 16, height: 84).offset(x: width - 16)
            }
        }
        .frame(width: width, height: 84)
        .task(id: "\(clip.renderAsset.relativePath)-\(clip.sourceRange.start)-\(clip.sourceRange.duration)-\(Int(width))") {
            let count = max(1, Int(width / 60) + 1)
            let images = await session.thumbnailer.thumbnails(for: clip, count: count)
            thumbnails = images.map { UIImage(cgImage: $0) }
        }
    }

    private func trimHandle(edge: TimelineView.Edge) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(PSTheme.accentGradient)
            .overlay(Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if trimDrag == nil {
                            trimDrag = TimelineView.TrimDrag(clipID: clip.id, edge: edge, originalRange: clip.sourceRange)
                            session.beginSliderInteraction(L("Trim"))
                            Haptics.soft()
                        }
                        guard let original = trimDrag?.originalRange else { return }
                        let delta = Double(value.translation.width / pixelsPerSecond) * clip.speed
                        let range: TimeSpan = edge == .leading
                            ? TimeSpan(start: min(original.end - 0.1, max(0, original.start + delta)), end: original.end)
                            : TimeSpan(start: original.start, end: max(original.start + 0.1, min(clip.asset.duration > 0 ? clip.asset.duration : .infinity, original.end + delta)))
                        session.setClipSourceRange(clip.id, range)
                    }
                    .onEnded { _ in
                        trimDrag = nil
                        session.endSliderInteraction()
                        Haptics.confirm()
                    }
            )
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    private var formattedDuration: String {
        let seconds = clip.timelineDuration
        return seconds < 10 ? String(format: "%.1fs", seconds) : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct GlassChipMini: View {
    var text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            if !text.isEmpty { Text(text) }
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(Color.black.opacity(0.55), in: Capsule())
    }
}
#endif
