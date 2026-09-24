#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Which end of the clip a framing edit applies to.
enum MotionKeyframeEnd: String, CaseIterable, Identifiable {
    case start, end
    var id: String { rawValue }
    var title: String { self == .start ? L("Start") : L("End") }
    var symbol: String { self == .start ? "backward.end" : "forward.end" }
}

extension VideoEditorSession {
    /// The selected clip's motion as two editable keyframes (start and end).
    func editableMotion(for clip: VideoClip) -> ClipMotion {
        if let motion = clip.motion, motion.keyframes.count >= 2, motion.kind != .smartReframe {
            return motion
        }
        let centred: (focus: PSPoint, zoom: Double) = (PSPoint(x: 0.5, y: 0.5), 1)
        let start = clip.motion?.sample(at: 0) ?? centred
        let end = clip.motion?.sample(at: clip.timelineDuration) ?? centred
        return ClipMotion(kind: .manual, keyframes: [
            MotionKeyframe(time: 0, focus: start.focus, zoom: start.zoom),
            MotionKeyframe(time: clip.timelineDuration, focus: end.focus, zoom: end.zoom),
        ])
    }

    /// Changes the framing of one end of the selected clip.
    func setFraming(_ end: MotionKeyframeEnd, _ label: String, _ body: (inout MotionKeyframe) -> Void) {
        guard let clip = selectedClip else { return }
        var motion = editableMotion(for: clip)
        let index = end == .start ? 0 : motion.keyframes.count - 1
        body(&motion.keyframes[index])
        motion.keyframes[index] = MotionKeyframe(time: motion.keyframes[index].time, focus: motion.keyframes[index].focus, zoom: motion.keyframes[index].zoom, easing: .easeInOut)
        let finished = ClipMotion(kind: .manual, keyframes: motion.keyframes)
        updateSelectedClip(label) { $0.motion = finished }
    }

    /// Shows the frame being framed.
    func seekToKeyframe(_ end: MotionKeyframeEnd) {
        guard let clip = selectedClip, let span = timeline.span(of: clip.id) else { return }
        let target = end == .start ? span.start + 0.02 : max(span.start, span.end - 0.04)
        let player = self.player
        Task { await player.seek(to: target) }
    }
}

/// Pan & Zoom, like Vegas' Pan/Crop: frame the start and the end of the clip
/// (drag on the picture to move, pinch to zoom) and the camera travels
/// between them; or pick a ready-made move.
struct MotionPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var end: MotionKeyframeEnd? = .start
    @State private var zoom: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let clip = session.selectedClip {
                ModeSegments(modes: MotionKeyframeEnd.allCases, selection: $end, title: { $0.title }, symbol: { $0.symbol })
                DialSlider(value: $zoom, range: 1...3, neutral: 1, label: L("Zoom"), units: 100, format: { String(format: "%.2f×", $0) }, onEditingChanged: { editing in
                    if editing { session.beginSliderInteraction("Zoom") } else { session.endSliderInteraction() }
                })
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PanelChip(title: L("Push in"), symbol: "plus.magnifyingglass") { preset(clip, from: (PSPoint(x: 0.5, y: 0.5), 1), to: (PSPoint(x: 0.5, y: 0.47), 1.25)) }
                        PanelChip(title: L("Pull out"), symbol: "minus.magnifyingglass") { preset(clip, from: (PSPoint(x: 0.5, y: 0.47), 1.25), to: (PSPoint(x: 0.5, y: 0.5), 1)) }
                        PanelChip(title: L("Pan left"), symbol: "arrow.left") { preset(clip, from: (PSPoint(x: 0.62, y: 0.5), 1.2), to: (PSPoint(x: 0.38, y: 0.5), 1.2)) }
                        PanelChip(title: L("Pan right"), symbol: "arrow.right") { preset(clip, from: (PSPoint(x: 0.38, y: 0.5), 1.2), to: (PSPoint(x: 0.62, y: 0.5), 1.2)) }
                        PanelChip(title: L("Follow subject"), symbol: "person.crop.rectangle", tint: PSTheme.voice) {
                            var intent = EditIntent(action: .smartReframe)
                            intent.aspect = session.timeline.aspect == .original ? .ratio9x16 : session.timeline.aspect
                            Task { await session.run(intent) }
                        }
                        PanelChip(title: L("None"), symbol: "xmark", isEnabled: clip.motion != nil) {
                            session.updateSelectedClip("Remove Camera Move") { $0.motion = nil }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                Text(L("Drag on the picture to frame, pinch to zoom. The camera moves from the start framing to the end one."))
                    .font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
            } else {
                Text(L("Select a clip on the timeline.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        }
        .onAppear { sync() }
        .onChange(of: end) { _, value in
            sync()
            if let value { session.seekToKeyframe(value) }
        }
        .onChange(of: session.selectedClipID) { _, _ in sync() }
        .onChange(of: zoom) { _, value in
            guard let end, let clip = session.selectedClip else { return }
            let current = session.editableMotion(for: clip).keyframes[end == .start ? 0 : 1].zoom
            if abs(current - value) > 0.001 { session.setFraming(end, "Zoom") { $0.zoom = value } }
        }
    }

    private func sync() {
        guard let clip = session.selectedClip, let end else { return }
        let motion = session.editableMotion(for: clip)
        zoom = motion.keyframes[end == .start ? 0 : motion.keyframes.count - 1].zoom
    }

    private func preset(_ clip: VideoClip, from: (PSPoint, Double), to: (PSPoint, Double)) {
        let motion = ClipMotion(kind: .manual, keyframes: [
            MotionKeyframe(time: 0, focus: from.0, zoom: from.1),
            MotionKeyframe(time: clip.timelineDuration, focus: to.0, zoom: to.1),
        ])
        session.updateSelectedClip("Camera Move") { $0.motion = motion }
        sync()
        Haptics.confirm()
    }
}

/// On the preview while framing: dragging moves the camera's target, a pinch
/// zooms; a frame shows the move while the finger is down, the composition
/// updates on release.
struct MotionFramingLayer: View {
    @Bindable var session: VideoEditorSession
    let frame: CGRect
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1

    var body: some View {
        if let clip = session.selectedClip {
            Rectangle()
                .fill(Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PSTheme.accent.opacity(drag == .zero && pinch == 1 ? 0.5 : 1), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .scaleEffect(1 / max(0.3, pinch))
                        .offset(drag)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            drag = .zero
                            let target = currentEnd(clip)
                            let motion = session.editableMotion(for: clip)
                            let key = motion.keyframes[target == .start ? 0 : motion.keyframes.count - 1]
                            // Moving the picture right moves the camera left, scaled by how far it is zoomed in.
                            let dx = -Double(value.translation.width / max(1, frame.width)) / key.zoom
                            let dy = -Double(value.translation.height / max(1, frame.height)) / key.zoom
                            session.setFraming(target, "Pan") { $0.focus = PSPoint(x: ($0.focus.x + dx).clamped(to: 0...1), y: ($0.focus.y + dy).clamped(to: 0...1)) }
                            Haptics.tick()
                        }
                        .simultaneously(with: MagnifyGesture()
                            .onChanged { pinch = $0.magnification }
                            .onEnded { value in
                                pinch = 1
                                let target = currentEnd(clip)
                                session.setFraming(target, "Zoom") { $0.zoom = ($0.zoom * Double(value.magnification)).clamped(to: 1...3) }
                            })
                )
                .animation(PSMotion.interactive, value: drag)
        }
    }

    /// The end being edited follows the playhead: the first half of the clip frames the start.
    private func currentEnd(_ clip: VideoClip) -> MotionKeyframeEnd {
        guard let span = session.timeline.span(of: clip.id) else { return .start }
        return session.player.currentTime < span.start + span.duration / 2 ? .start : .end
    }
}
#endif
