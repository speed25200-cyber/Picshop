#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit) && canImport(PhotosUI)
import SwiftUI
import PhotosUI
import PicshopCore
import PicshopImaging
import PicshopVideo

extension VideoEditorSession {
    /// Media overlays (pictures and videos), in stacking order.
    var mediaOverlays: [TimelineOverlay] { timeline.overlays.filter(\.isMedia) }

    var selectedOverlay: TimelineOverlay? {
        guard let id = selectedOverlayID else { return nil }
        return timeline.overlays.first { $0.id == id && $0.isMedia }
    }

    /// Copies a picked video or photo into the project and lays it over the
    /// main video at the playhead, as a picture-in-picture in the top corner.
    func addOverlay(from item: PhotosPickerItem) async {
        let store = app.store
        let projectID = projectID
        do {
            try store.createPackage(for: projectID)
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let asset: MediaAsset
            if isVideo {
                guard let file = try await item.loadTransferable(type: ImportedMovie.self) else { return }
                let relative = "\(Project.mediaDirectory)/overlay-\(UUID().uuidString).\(file.url.pathExtension.isEmpty ? "mov" : file.url.pathExtension)"
                let destination = store.url(for: relative, in: projectID)
                try FileManager.default.moveItem(at: file.url, to: destination)
                let metadata = try await VideoThumbnailer.metadata(for: destination)
                asset = MediaAsset(kind: .video, relativePath: relative, pixelSize: metadata.size, duration: metadata.duration, origin: .photoLibrary(localIdentifier: ""), frameRate: metadata.frameRate)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let relative = "\(Project.mediaDirectory)/overlay-\(UUID().uuidString).jpg"
                let destination = store.url(for: relative, in: projectID)
                try data.write(to: destination, options: .atomic)
                asset = MediaAsset(kind: .image, relativePath: relative, pixelSize: ImageSupport.pixelSize(at: destination) ?? PSSize(width: 1080, height: 1080), origin: .photoLibrary(localIdentifier: ""))
            }
            let start = min(player.currentTime, max(0, timeline.duration - 0.5))
            let available = max(0.5, timeline.duration - start)
            let length = asset.kind == .video ? min(asset.duration, available) : min(4, available)
            let placement = LayerTransform(center: PSPoint(x: 0.72, y: 0.26), scale: 0.4)
            let content: TimelineOverlay.Content = asset.kind == .video
                ? .video(asset, transform: placement, sourceStart: 0)
                : .image(asset, transform: placement)
            let overlay = TimelineOverlay(content: content, span: TimeSpan(start: start, duration: length), fadeIn: 0.2, fadeOut: 0.2)
            update(asset.kind == .video ? "Add Video Overlay" : "Add Picture Overlay") { $0.addOverlay(overlay) }
            selectedOverlayID = overlay.id
            Haptics.success()
        } catch {
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    /// Edits one overlay; the composition rebuilds once, on commit.
    func updateOverlay(_ id: UUID, _ label: String, _ body: (inout TimelineOverlay) -> Void) {
        update(label) { timeline in
            guard let index = timeline.overlays.firstIndex(where: { $0.id == id }) else { return }
            body(&timeline.overlays[index])
            timeline.touch()
        }
    }

    func removeOverlay(_ id: UUID) {
        update("Remove Overlay") { $0.removeOverlay(id: id) }
        if selectedOverlayID == id { selectedOverlayID = mediaOverlays.last?.id }
    }
}

/// Picture-in-picture, B-roll and green screen: add a video or a photo over
/// the main one, then size it, place it (drag on the preview), key out its
/// background, set its opacity and sound.
struct VideoOverlayPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var pickedItem: PhotosPickerItem?
    @State private var scale: Double = 0.4
    @State private var opacity: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickedItem, matching: .any(of: [.videos, .images])) {
                        Label(L("Add video or photo"), systemImage: "plus")
                            .font(PSFont.headline(13)).foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(Color.white))
                    }
                    ForEach(Array(session.mediaOverlays.enumerated()), id: \.element.id) { index, overlay in
                        PanelChip(title: String(format: L("Layer %d"), index + 1), symbol: overlay.mediaAsset?.kind == .video ? "film" : "photo",
                                  isActive: session.selectedOverlayID == overlay.id) {
                            session.selectedOverlayID = overlay.id
                            session.player.scrub(to: overlay.span.start + 0.05)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            if let overlay = session.selectedOverlay {
                controls(for: overlay)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text(L("Lay a second video or a photo over yours: picture in picture, B-roll, green screen."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        }
        .animation(PSMotion.standard, value: session.selectedOverlayID)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                await session.addOverlay(from: item)
                pickedItem = nil
            }
        }
        .onAppear {
            if session.selectedOverlay == nil { session.selectedOverlayID = session.mediaOverlays.last?.id }
            syncState()
        }
        .onChange(of: session.selectedOverlayID) { _, _ in syncState() }
    }

    private func syncState() {
        scale = session.selectedOverlay?.transform?.scale ?? 0.4
        opacity = session.selectedOverlay?.opacity ?? 1
    }

    @ViewBuilder
    private func controls(for overlay: TimelineOverlay) -> some View {
        DialSlider(value: $scale, range: 0.1...1, neutral: 0.4, label: L("Size"), format: { "\(Int(($0 * 100).rounded()))%" }, onEditingChanged: { editing in
            if !editing { session.updateOverlay(overlay.id, "Overlay Size") { $0.transform?.scale = scale } }
        })
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Placement.allCases) { placement in
                    PanelChip(title: placement.title, symbol: placement.symbol) {
                        session.updateOverlay(overlay.id, "Overlay Position") { item in
                            item.transform?.center = placement.center
                            if placement == .full { item.transform?.scale = 1 }
                        }
                        if placement == .full { scale = 1 }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PanelChip(title: L("Green screen"), symbol: "person.crop.rectangle.badge.plus", isActive: overlay.chromaKey?.hue == ChromaKey.green.hue) {
                    session.updateOverlay(overlay.id, "Green Screen") { $0.chromaKey = $0.chromaKey?.hue == ChromaKey.green.hue ? nil : .green }
                }
                PanelChip(title: L("Blue screen"), symbol: "person.crop.rectangle", isActive: overlay.chromaKey?.hue == ChromaKey.blue.hue) {
                    session.updateOverlay(overlay.id, "Blue Screen") { $0.chromaKey = $0.chromaKey?.hue == ChromaKey.blue.hue ? nil : .blue }
                }
                if overlay.mediaAsset?.kind == .video {
                    PanelChip(title: overlay.volume ?? 0 > 0 ? L("Sound on") : L("Sound off"), symbol: overlay.volume ?? 0 > 0 ? "speaker.wave.2.fill" : "speaker.slash", isActive: overlay.volume ?? 0 > 0) {
                        session.updateOverlay(overlay.id, "Overlay Sound") { $0.volume = ($0.volume ?? 0) > 0 ? nil : 1 }
                    }
                }
                FollowSubjectChip(session: session, overlay: overlay)
                KeyframeChip(session: session, overlay: overlay)
                PanelChip(title: L("Remove"), symbol: "trash") { session.removeOverlay(overlay.id) }
            }
            .padding(.horizontal, 2)
        }
        DialSlider(value: $opacity, range: 0...1, neutral: 1, label: L("Opacity"), format: { "\(Int(($0 * 100).rounded()))%" }, onEditingChanged: { editing in
            if !editing { session.updateOverlay(overlay.id, "Overlay Opacity") { $0.opacity = opacity >= 0.999 ? nil : opacity } }
        })
        Text(L("Drag on the picture to move it, pinch to resize."))
            .font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
    }

    enum Placement: String, CaseIterable, Identifiable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing, center, full
        var id: String { rawValue }
        var center: PSPoint {
            switch self {
            case .topLeading: return PSPoint(x: 0.28, y: 0.26)
            case .topTrailing: return PSPoint(x: 0.72, y: 0.26)
            case .bottomLeading: return PSPoint(x: 0.28, y: 0.74)
            case .bottomTrailing: return PSPoint(x: 0.72, y: 0.74)
            case .center, .full: return PSPoint(x: 0.5, y: 0.5)
            }
        }
        var title: String {
            switch self {
            case .topLeading: return L("Top left")
            case .topTrailing: return L("Top right")
            case .bottomLeading: return L("Bottom left")
            case .bottomTrailing: return L("Bottom right")
            case .center: return L("Centre")
            case .full: return L("Full frame")
            }
        }
        var symbol: String {
            switch self {
            case .topLeading: return "arrow.up.left"
            case .topTrailing: return "arrow.up.right"
            case .bottomLeading: return "arrow.down.left"
            case .bottomTrailing: return "arrow.down.right"
            case .center: return "circle.circle"
            case .full: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }
}

/// On the preview while arranging an overlay: its outline follows the finger
/// (drag to move, pinch to resize) and the composition updates on release.
struct OverlayArrangeLayer: View {
    @Bindable var session: VideoEditorSession
    /// The video's frame inside the preview.
    let frame: CGRect
    @State private var dragOffset: CGSize = .zero
    @State private var pinch: CGFloat = 1

    var body: some View {
        if let overlay = session.selectedOverlay, let transform = overlay.transform, let asset = overlay.mediaAsset {
            let aspect = asset.pixelSize.isEmpty ? 16.0 / 9.0 : asset.pixelSize.aspectRatio
            let width = frame.width * CGFloat(transform.scale) * pinch
            let height = width / CGFloat(max(0.1, aspect))
            let center = CGPoint(x: frame.minX + CGFloat(transform.center.x) * frame.width + dragOffset.width,
                                 y: frame.minY + CGFloat(transform.center.y) * frame.height + dragOffset.height)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PSTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PSTheme.accent.opacity(0.08)))
                .frame(width: width, height: height)
                .position(center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            let next = PSPoint(x: (transform.center.x + Double(value.translation.width / max(1, frame.width))).clamped(to: 0...1),
                                               y: (transform.center.y + Double(value.translation.height / max(1, frame.height))).clamped(to: 0...1))
                            dragOffset = .zero
                            Haptics.tick()
                            session.updateOverlay(overlay.id, "Move Overlay") { $0.transform?.center = next }
                        }
                        .simultaneously(with: MagnifyGesture()
                            .onChanged { pinch = $0.magnification }
                            .onEnded { value in
                                let next = (transform.scale * Double(value.magnification)).clamped(to: 0.1...1.2)
                                pinch = 1
                                session.updateOverlay(overlay.id, "Overlay Size") { $0.transform?.scale = next }
                            })
                )
                .animation(PSMotion.interactive, value: dragOffset)
        }
    }
}
/// Attaches an overlay to whatever moves under it (a face, a person, a
/// ball), or lets go of it. Tracking runs from the playhead both ways.
struct FollowSubjectChip: View {
    @Bindable var session: VideoEditorSession
    let overlay: TimelineOverlay

    var body: some View {
        let isFollowing = overlay.tracking != nil
        PanelChip(title: isFollowing ? L("Following") : L("Follow subject"), symbol: "scope", tint: PSTheme.voice, isActive: isFollowing, isEnabled: !session.isProcessing) {
            var intent = EditIntent(action: .trackSubject)
            intent.text = overlay.id.uuidString
            if isFollowing { intent.amount = .absolute(0) }
            Task { await session.run(intent) }
        }
        .accessibilityHint(L("The layer moves with the subject under it"))
    }
}
/// Records where the overlay is now as a keyframe at the playhead; place it
/// elsewhere later in time, tap again, and it moves between the two.
struct KeyframeChip: View {
    @Bindable var session: VideoEditorSession
    let overlay: TimelineOverlay

    var body: some View {
        let count = overlay.keyframes?.count ?? 0
        Menu {
            Button { record() } label: { Label(L("Keyframe at the playhead"), systemImage: "diamond") }
            if count > 0 {
                Button(role: .destructive) {
                    session.update(L("Clear Keyframes")) { timeline in
                        if let index = timeline.overlays.firstIndex(where: { $0.id == overlay.id }) { timeline.overlays[index].keyframes = nil }
                    }
                } label: { Label(L("Clear keyframes"), systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: count > 0 ? "diamond.fill" : "diamond").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(count > 0 ? PSTheme.accent : PSTheme.textPrimary)
                Text(count > 0 ? String(format: L("%d keyframes"), count) : L("Keyframe")).lineLimit(1)
            }
            .font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(PSTheme.textPrimary)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        } primaryAction: {
            record()
        }
        .accessibilityHint(L("Place the layer, move the playhead, place it again: it travels between the two."))
    }

    private func record() {
        Haptics.tick()
        let time = session.player.currentTime
        session.update(L("Keyframe")) { timeline in
            if let index = timeline.overlays.firstIndex(where: { $0.id == overlay.id }) { timeline.overlays[index].setKeyframe(at: time) }
        }
    }
}
#endif
