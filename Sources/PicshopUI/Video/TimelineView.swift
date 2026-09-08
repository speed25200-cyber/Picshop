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
                        HStack(spacing: 2) {
                            ForEach(Array(session.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                                ClipView(session: session, clip: clip, index: index, pixelsPerSecond: pixelsPerSecond, trimDrag: $trimDrag)
                            }
                        }
                        .padding(.horizontal, width / 2)
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
                Rectangle().fill(PSTheme.accent).frame(width: 2).frame(maxHeight: .infinity)
                    .shadow(color: PSTheme.accent.opacity(0.6), radius: 4)
                    .allowsHitTesting(false)
            }
            .gesture(MagnifyGesture().onChanged { value in
                pixelsPerSecond = min(400, max(12, steadyScale * value.magnification))
            }.onEnded { _ in steadyScale = pixelsPerSecond })
            .onChange(of: session.player.currentTime) { _, time in
                guard session.player.isPlaying else { return }
                position.scrollTo(x: CGFloat(time) * pixelsPerSecond)
            }
        }
        .psCard(cornerRadius: 18, shadow: false)
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
            .offset(x: x, y: 96)
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
            .offset(x: x, y: 96)
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isSelected ? PSTheme.accent : PSTheme.hairline, lineWidth: isSelected ? 3 : 1))
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
