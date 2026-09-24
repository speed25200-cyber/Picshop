#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopVideo

/// The video at a glance, under the player: a 48-point strip of frames that
/// slides under a fixed centre playhead. Drag to scrub (the player chases the
/// finger), pinch to zoom, tap to open the full timeline (Montage › Timeline &
/// coupe). Under the strip, 3-point hints show where the captions, the
/// overlays and the sound tracks sit. With several clips, the selected one
/// (the one the clip tools edit) is outlined.
///
/// Only the offset follows the playhead: the frames are laid out once per
/// zoom and never re-evaluated by playback.
struct FilmstripScrubber: View {
    let session: VideoEditorSession
    /// Points per second, set when the strip first lays out so the whole video fits.
    @State private var pixelsPerSecond: CGFloat?
    /// Where a drag started, in timeline seconds.
    @State private var dragStart: Double?
    @State private var wasPlaying = false
    @GestureState private var pinch: CGFloat = 1

    static let stripHeight: CGFloat = 48
    static let laneHeight: CGFloat = 3
    static let laneSpacing: CGFloat = 1.5

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let timeline = session.timeline
        let lanes = FilmstripLanes(timeline: timeline)
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = pixelsPerSecond ?? Self.fitting(duration: timeline.duration, width: width)
            ZStack(alignment: .topLeading) {
                FilmstripContent(session: session, timeline: timeline, lanes: lanes, pixelsPerSecond: scale)
                    .modifier(PlayheadOffset(player: session.player, pixelsPerSecond: scale, centerX: width / 2))
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            // Pinching stretches what is there about the playhead; the new zoom lays out on release.
            .scaleEffect(x: pinch, y: 1, anchor: .center)
            .clipped()
            .overlay { Playhead(height: proxy.size.height) }
            .contentShape(Rectangle())
            .gesture(scrub(pixelsPerSecond: scale))
            .simultaneousGesture(zoom(pixelsPerSecond: scale, width: width))
            .onTapGesture {
                Haptics.tap()
                session.activeTool = .cut
            }
            .onChange(of: timeline.duration) { _, _ in pixelsPerSecond = nil }
        }
        .frame(height: Self.stripHeight + lanes.height)
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
        .overlay { ScrubberAccessibility(session: session) }
    }

    /// The whole video across the strip, within a sensible range.
    static func fitting(duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 40 }
        return min(200, max(4, width / CGFloat(duration)))
    }

    private func scrub(pixelsPerSecond: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let player = session.player
                if dragStart == nil {
                    dragStart = player.currentTime
                    wasPlaying = player.isPlaying
                    if wasPlaying { player.pause() }
                    Haptics.soft()
                }
                guard let start = dragStart else { return }
                player.scrub(to: start - Double(value.translation.width / max(1, pixelsPerSecond)))
            }
            .onEnded { _ in
                dragStart = nil
                session.player.endScrub()
                if wasPlaying { session.player.play() }
                Haptics.tick()
            }
    }

    private func zoom(pixelsPerSecond: CGFloat, width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                let minimum = min(Self.fitting(duration: session.timeline.duration, width: width), 24)
                self.pixelsPerSecond = min(400, max(minimum, pixelsPerSecond * value.magnification))
            }
    }
}

/// VoiceOver's scrubber: an adjustable element whose value is the playhead. A
/// leaf, so its value never re-evaluates the strip.
private struct ScrubberAccessibility: View {
    let session: VideoEditorSession

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(L("Timeline"))
            .accessibilityHint(L("Swipe up or down to move by a second. Double-tap to open the timeline."))
            .accessibilityValue(Text(verbatim: psClock(session.player.currentTime)))
            .accessibilityAdjustableAction { direction in
                let player = session.player
                let step: Double = direction == .increment ? 1 : -1
                Task { await player.seek(to: player.currentTime + step) }
            }
            .accessibilityAction { session.activeTool = .cut }
    }
}

/// Slides the strip so the playhead's time sits under the centre line. A leaf
/// modifier: the playhead re-evaluates this, not the frames.
private struct PlayheadOffset: ViewModifier {
    let player: TimelinePlayer
    let pixelsPerSecond: CGFloat
    let centerX: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: centerX - CGFloat(player.currentTime) * pixelsPerSecond)
    }
}

/// Which lanes the video has, and their spans.
struct FilmstripLanes: Equatable {
    var captions: [TimeSpan] = []
    var overlays: [TimeSpan] = []
    var audio: [TimeSpan] = []

    init(timeline: VideoTimeline) {
        if let track = timeline.captions, !track.isEmpty { captions = track.cues.map(\.span) }
        overlays = timeline.overlays.map(\.span)
        audio = timeline.audioTracks.map { track in
            TimeSpan(start: track.timelineStart, duration: max(0, min(track.sourceRange.duration, timeline.duration - track.timelineStart)))
        }
    }

    /// Present lanes, top to bottom, with their shade and symbol.
    var rows: [(spans: [TimeSpan], opacity: Double, symbol: String)] {
        var rows: [(spans: [TimeSpan], opacity: Double, symbol: String)] = []
        if !captions.isEmpty { rows.append((captions, 0.55, "captions.bubble")) }
        if !overlays.isEmpty { rows.append((overlays, 0.35, "rectangle.on.rectangle")) }
        if !audio.isEmpty { rows.append((audio, 0.25, "music.note")) }
        return rows
    }

    var height: CGFloat {
        let count = CGFloat(rows.count)
        return count == 0 ? 0 : 6 + count * FilmstripScrubber.laneHeight + (count - 1) * FilmstripScrubber.laneSpacing
    }
}

/// The frames of every clip end to end, and the lane hints under them, at a zoom.
private struct FilmstripContent: View {
    let session: VideoEditorSession
    let timeline: VideoTimeline
    let lanes: FilmstripLanes
    let pixelsPerSecond: CGFloat

    var body: some View {
        let width = max(1, CGFloat(timeline.duration) * pixelsPerSecond)
        // With several clips, the one the clip tools edit (Réglages, Looks, Vitesse…) is outlined.
        let selected = timeline.clips.count > 1 ? session.selectedClipID : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(timeline.clips, id: \.id) { clip in
                    FilmstripClip(thumbnailer: session.thumbnailer, clip: clip, aspect: timeline.renderSize.aspectRatio,
                                  width: max(2, CGFloat(clip.timelineDuration) * pixelsPerSecond))
                        .overlay {
                            if clip.id == selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(PSTheme.accent, lineWidth: 2)
                            }
                        }
                }
            }
            .frame(width: width, height: FilmstripScrubber.stripHeight, alignment: .leading)
            .background(PSTheme.fill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !lanes.rows.isEmpty {
                VStack(alignment: .leading, spacing: FilmstripScrubber.laneSpacing) {
                    ForEach(Array(lanes.rows.enumerated()), id: \.offset) { _, row in
                        ZStack(alignment: .leading) {
                            ForEach(Array(row.spans.enumerated()), id: \.offset) { _, span in
                                Capsule()
                                    .fill(Color.white.opacity(row.opacity))
                                    .frame(width: max(3, CGFloat(span.duration) * pixelsPerSecond), height: FilmstripScrubber.laneHeight)
                                    .offset(x: CGFloat(span.start) * pixelsPerSecond)
                            }
                        }
                        .frame(width: width, height: FilmstripScrubber.laneHeight, alignment: .leading)
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// One clip's frames, tiled at the strip's height. Frame counts come in
/// powers of two, so a pinch rarely asks for new ones.
private struct FilmstripClip: View {
    let thumbnailer: VideoThumbnailer
    let clip: VideoClip
    let aspect: Double
    let width: CGFloat
    @State private var frames: [UIImage] = []

    private var count: Int {
        let tile = FilmstripScrubber.stripHeight * CGFloat(max(0.3, min(aspect, 3)))
        let needed = max(1, Int((width / tile).rounded(.up)))
        var bucket = 1
        while bucket < needed, bucket < 32 { bucket *= 2 }
        return bucket
    }

    var body: some View {
        let count = self.count
        HStack(spacing: 0) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width / CGFloat(max(1, frames.count)), height: FilmstripScrubber.stripHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: FilmstripScrubber.stripHeight, alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            // The cut between two clips.
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 1)
        }
        .task(id: "\(clip.renderAsset.relativePath)|\(clip.sourceRange.start)|\(clip.sourceRange.duration)|\(count)") {
            let images = await thumbnailer.thumbnails(for: clip, count: count, height: 96)
            guard !Task.isCancelled else { return }
            frames = images.map { UIImage(cgImage: $0) }
        }
    }
}

/// The fixed centre line: 2 points wide, an 8-point knob on top.
private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: -2) {
            Circle().fill(Color.white).frame(width: 8, height: 8)
            Capsule().fill(Color.white).frame(width: 2)
        }
        .frame(height: height + 8)
        .offset(y: -4)
        .shadow(color: .black.opacity(0.35), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
