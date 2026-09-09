#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopVideo
import PicshopImaging
import CoreImage

struct VideoToolPanel: View {
    @Bindable var session: VideoEditorSession
    let tool: VideoEditorSession.Tool

    var body: some View {
        switch tool {
        case .cut: CutPanel(session: session)
        case .speed: SpeedPanel(session: session)
        case .audio: AudioPanel(session: session)
        case .looks: VideoLooksPanel(session: session)
        case .adjust: VideoAdjustPanel(session: session)
        case .text: VideoTextPanel(session: session)
        case .transitions: TransitionsPanel(session: session)
        case .frame: FramePanel(session: session)
        }
    }
}

private extension VideoEditorSession {
    func perform(_ intent: EditIntent) { Task { await run(intent) } }
}

struct CutPanel: View {
    @Bindable var session: VideoEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PanelChip(title: L("Split here"), symbol: "scissors", tint: PSTheme.accent) { session.splitAtPlayhead() }
                    PanelChip(title: L("Delete clip"), symbol: "trash") { session.deleteSelectedClip() }
                    PanelChip(title: L("Duplicate"), symbol: "plus.square.on.square") { session.perform(EditIntent(action: .duplicateClip)) }
                    PanelChip(title: L("Freeze frame"), symbol: "pause.rectangle") { session.perform(EditIntent(action: .freezeFrame, amount: .absolute(2), time: session.player.currentTime)) }
                    PanelChip(title: L("Extract frame"), symbol: "photo") { session.perform(EditIntent(action: .extractFrame, time: session.player.currentTime)) }
                    PanelChip(title: L("Stabilize"), symbol: "video.badge.waveform") { session.perform(EditIntent(action: .stabilize)) }
                    PanelChip(title: L("Reverse"), symbol: "arrow.uturn.backward.circle") { session.perform(EditIntent(action: .reverse)) }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.mic").foregroundStyle(PSTheme.voice)
                Text(L("Drag the handles of the selected clip to trim, or say “coupe les 3 premières secondes”, “efface le passant”."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SpeedPanel: View {
    @Bindable var session: VideoEditorSession
    private let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 4]

    private var currentSpeed: Double { session.selectedClip?.speed ?? 1 }

    private func label(_ speed: Double) -> String {
        "×" + (speed == speed.rounded() ? String(Int(speed)) : String(speed))
    }

    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSTheme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(speeds, id: \.self) { speed in
                            PanelChip(title: label(speed), isActive: currentSpeed == speed) {
                                Haptics.tick()
                                session.perform(EditIntent(action: .setSpeed, amount: .absolute(speed)))
                            }
                        }
                    }
                }
                Image(systemName: "hare.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSTheme.textTertiary)
            }
            if let clip = session.selectedClip {
                HStack(spacing: 6) {
                    Image(systemName: currentSpeed < 1 ? "slowmo" : (currentSpeed > 1 ? "timelapse" : "speedometer"))
                        .foregroundStyle(currentSpeed == 1 ? PSTheme.textTertiary : PSTheme.accent)
                        .contentTransition(.symbolEffect(.replace))
                    Text(seconds(clip.sourceRange.duration)).foregroundStyle(PSTheme.textTertiary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(PSTheme.textTertiary)
                    Text(seconds(clip.timelineDuration)).foregroundStyle(PSTheme.textPrimary).contentTransition(.numericText())
                    Spacer()
                    Text(L("Slow motion keeps every frame; time-lapse drops them. Audio follows the speed."))
                        .foregroundStyle(PSTheme.textTertiary).lineLimit(2).multilineTextAlignment(.trailing)
                }
                .font(PSFont.caption(11))
                .animation(PSMotion.quick, value: currentSpeed)
            } else {
                Text(L("Tap a clip on the timeline to change its speed.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        }
    }
}

struct AudioPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var volume: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PanelChip(title: session.selectedClip?.isMuted == true ? L("Unmute") : L("Mute"), symbol: session.selectedClip?.isMuted == true ? "speaker.slash" : "speaker.wave.2") {
                    session.perform(EditIntent(action: session.selectedClip?.isMuted == true ? .unmute : .mute))
                }
                PanelChip(title: L("Add sound track"), symbol: "plus.circle", tint: PSTheme.accent) { session.addSoundTrack() }
                Spacer()
            }
            ParameterSlider(title: L("Clip volume"), value: $volume, range: 0...2, bipolar: false) { editing in
                if editing { session.beginSliderInteraction(L("Volume")) } else { session.endSliderInteraction() }
            }
            .onChange(of: volume) { _, value in session.updateSelectedClip(L("Volume")) { $0.volume = value; if value > 0 { $0.isMuted = false } } }
            .onAppear { volume = session.selectedClip?.volume ?? 1 }
            if session.timeline.audioTracks.isEmpty {
                Text(L("Add music, a voice-over or a sound effect: each one gets its own lane. Say “ajoute un son à 10 secondes”."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                // The mixer: one strip per track, like the lanes on the timeline.
                VStack(spacing: 8) {
                    ForEach(Array(session.timeline.audioTracks.enumerated()), id: \.element.id) { index, track in
                        SoundTrackRow(session: session, track: track, index: index)
                    }
                }
            }
        }
    }
}

/// One sound track in the mixer: name and position, volume, mute, remove.
struct SoundTrackRow: View {
    @Bindable var session: VideoEditorSession
    let track: AudioTrack
    let index: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(PSFont.mono(11)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(PSTheme.accentGradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name).font(PSFont.headline(13)).lineLimit(1).foregroundStyle(track.isMuted ? PSTheme.textTertiary : PSTheme.textPrimary)
                    Text(String(format: L("from %@ · %@"), psTimecode(track.timelineStart, frameRate: session.timeline.frameRate), psTimecode(track.sourceRange.duration, frameRate: session.timeline.frameRate)))
                        .font(PSFont.caption(10)).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                IconChip(title: track.isMuted ? L("Unmute") : L("Mute"), symbol: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2", isActive: track.isMuted) { session.toggleTrackMute(track.id) }
                IconChip(title: L("Playhead"), symbol: "arrow.right.to.line") { session.moveTrack(track.id, to: session.player.currentTime) }
                IconChip(title: L("Remove"), symbol: "trash") { session.removeTrack(track.id) }
            }
            ParameterSlider(title: L("Volume"), value: Binding(get: { track.volume }, set: { session.setTrackVolume(track.id, $0) }), range: 0...1, bipolar: false)
                .opacity(track.isMuted ? 0.5 : 1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .animation(PSMotion.quick, value: track.isMuted)
    }
}

struct VideoLooksPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var thumbnails: [FilterPreset: UIImage] = [:]

    private var currentLook: FilterPreset { session.selectedClip?.look ?? .original }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.gallery) { preset in
                        let active = currentLook == preset
                        Button {
                            Haptics.tick()
                            session.perform(EditIntent(action: .applyLook, look: preset))
                        } label: {
                            VStack(spacing: 6) {
                                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                                ZStack {
                                    if let image = thumbnails[preset] {
                                        Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                                    } else {
                                        PSTheme.surfaceElevated
                                        ProgressView().tint(PSTheme.textTertiary).controlSize(.mini)
                                    }
                                }
                                .frame(width: 68, height: 68)
                                .clipShape(shape)
                                .overlay(shape.strokeBorder(Color.white.opacity(active ? 0 : 0.08), lineWidth: 1))
                                .overlay {
                                    if active {
                                        shape.strokeBorder(PSTheme.accentGradient, lineWidth: 2.5)
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white, PSTheme.accent)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                            .padding(4)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .scaleEffect(active ? 1.04 : 1)
                                Text(localizedLookName(preset)).font(PSFont.caption(10.5)).fontWeight(active ? .semibold : .medium)
                                    .foregroundStyle(active ? PSTheme.textPrimary : PSTheme.textSecondary).lineLimit(1)
                            }
                            .frame(width: 72)
                            .animation(PSMotion.quick, value: active)
                        }
                        .buttonStyle(PSPressStyle())
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack {
                PanelChip(title: L("Apply to all clips"), symbol: "square.stack", isEnabled: session.timeline.clips.count > 1) {
                    session.perform(EditIntent(action: .applyLook, look: currentLook, scope: .all))
                }
                Spacer()
                Text(L("Looks preview on the selected clip's frame.")).font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
            }
        }
        .task(id: session.selectedClip?.id ?? session.timeline.clips.first?.id) { await renderThumbnails() }
    }

    /// One frame of the selected clip through every look, cached on the
    /// session per clip so reopening the panel costs nothing.
    private func renderThumbnails() async {
        guard let clip = session.selectedClip ?? session.timeline.clips.first else { return }
        if let cached = session.lookThumbnails, cached.clipID == clip.id {
            thumbnails = cached.images
            return
        }
        let side = Int(session.app.performance.thumbnailSide)
        guard let frame = await session.thumbnailer.thumbnails(for: clip, count: 1, height: side).first else { return }
        let base = CIImage(cgImage: frame)
        var rendered: [FilterPreset: UIImage] = [:]
        for preset in FilterPreset.gallery {
            let adjusted = AdjustmentPipeline.apply(preset.recipe, toneCurve: preset.toneCurve, to: base, scale: 0.05)
            if let cg = ImageSupport.cgImage(from: adjusted) {
                rendered[preset] = UIImage(cgImage: cg)
                thumbnails[preset] = rendered[preset]
            }
            await Task.yield()
        }
        session.lookThumbnails = (clip.id, rendered)
    }
}

private func localizedLookName(_ preset: FilterPreset) -> String {
    Locale.current.language.languageCode?.identifier == "fr" ? preset.frenchName : preset.englishName
}

struct VideoAdjustPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var value: Double = 0
    private let parameters: [AdjustmentParameter] = AdjustmentParameter.lightGroup + AdjustmentParameter.colorGroup + [.sharpness, .vignette, .grain]

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(parameters) { parameter in
                        let active = session.selectedParameter == parameter
                        Button {
                            Haptics.tick()
                            session.selectedParameter = parameter
                            value = session.selectedClip?.adjustments[parameter] ?? 0
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: parameter.symbolName).font(.system(size: 16, weight: .semibold))
                                Text(Locale.current.language.languageCode?.identifier == "fr" ? parameter.frenchName : parameter.englishName).font(PSFont.caption(10)).lineLimit(1)
                            }
                            .foregroundStyle(active ? Color.black : PSTheme.textPrimary)
                            .frame(width: 68, height: 52)
                            .background(active ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            DialSlider(value: $value, range: session.selectedParameter.range, neutral: 0, label: Locale.current.language.languageCode?.identifier == "fr" ? session.selectedParameter.frenchName : session.selectedParameter.englishName) { editing in
                if editing { session.beginSliderInteraction(session.selectedParameter.englishName) } else { session.endSliderInteraction() }
            }
            .onChange(of: value) { _, newValue in session.setAdjustment(session.selectedParameter, value: newValue) }
            .onAppear { value = session.selectedClip?.adjustments[session.selectedParameter] ?? 0 }
            HStack {
                PanelChip(title: L("Auto"), symbol: "wand.and.stars", tint: PSTheme.accent) { session.perform(EditIntent(action: .autoEnhance)) }
                Spacer()
                PanelChip(title: L("Blur background"), symbol: "person.crop.circle") { session.perform(EditIntent(action: .blurBackground)) }
            }
        }
    }
}

struct VideoTextPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L("Type or say “ajoute le texte …”"), text: $draft)
                    .textFieldStyle(.plain).font(PSFont.body(15)).foregroundStyle(PSTheme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10).psField(Capsule())
                    .submitLabel(.done).onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                    .buttonStyle(.plain).foregroundStyle(.white).psAccentFill(Circle())
            }
            if let overlay = session.timeline.overlays.last(where: { $0.textElement != nil }), let element = overlay.textElement {
                HStack(spacing: 8) {
                    ForEach([TextElement.Placement.top, .center, .bottom], id: \.self) { placement in
                        PanelChip(title: placement == .top ? L("Top") : (placement == .center ? L("Middle") : L("Bottom")), isActive: element.center == placement.center) {
                            session.perform(EditIntent(action: .editText, placement: placement))
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { session.perform(EditIntent(action: .removeText)) } label: { Image(systemName: "trash").frame(width: 38, height: 38) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.danger).psGlass(interactive: true, shape: AnyShape(Circle()))
                }
                ParameterSlider(title: L("Duration"), value: Binding(get: { overlay.span.duration }, set: { duration in
                    session.update(L("Text Duration")) { timeline in
                        if let index = timeline.overlays.firstIndex(where: { $0.id == overlay.id }) { timeline.overlays[index].span = TimeSpan(start: overlay.span.start, duration: duration) }
                    }
                }), range: 0.5...min(30, max(1, session.timeline.duration)), bipolar: false)
            }
        }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.perform(EditIntent(action: .addText, text: text, placement: .bottom))
        draft = ""
    }
}

struct TransitionsPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var duration: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TransitionKind.allCases.filter { $0 != .none }) { kind in
                        PanelChip(title: LD(kind.displayName), symbol: transitionSymbol(kind), isActive: session.selectedClip?.transitionOut?.kind == kind) {
                            Haptics.tick()
                            session.perform(EditIntent(action: .addTransition, time: duration, transition: kind))
                        }
                    }
                }
            }
            ParameterSlider(title: L("Duration"), value: $duration, range: 0.2...2, bipolar: false)
            HStack {
                PanelChip(title: L("Apply to all cuts"), symbol: "square.stack.3d.down.right") {
                    session.perform(EditIntent(action: .addTransition, time: duration, transition: session.selectedClip?.transitionOut?.kind ?? .crossDissolve, scope: .all))
                }
                PanelChip(title: L("Remove"), symbol: "xmark") { session.perform(EditIntent(action: .removeTransition)) }
            }
            if session.timeline.clips.count < 2 {
                Label(L("Split the video first to add a transition between two clips."), systemImage: "scissors")
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        }
    }

    private func transitionSymbol(_ kind: TransitionKind) -> String {
        switch kind {
        case .none: return "xmark"
        case .crossDissolve: return "circle.lefthalf.filled"
        case .fadeToBlack: return "moon.fill"
        case .fadeToWhite: return "sun.max.fill"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .wipeLeft: return "rectangle.lefthalf.inset.filled"
        case .zoom: return "plus.magnifyingglass"
        case .blur: return "drop.fill"
        }
    }
}

struct FramePanel: View {
    @Bindable var session: VideoEditorSession
    private let presets: [AspectPreset] = [.original, .ratio9x16, .square, .ratio4x5, .ratio16x9, .ratio4x3, .ratio21x9]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        PanelChip(title: preset.displayName, isActive: session.timeline.aspect == preset) {
                            session.perform(EditIntent(action: .setAspect, aspect: preset))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                PanelChip(title: L("Rotate"), symbol: "rotate.right") { session.perform(EditIntent(action: .rotate, degrees: 90)) }
                PanelChip(title: L("Flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.perform(EditIntent(action: .flip, flipAxis: .horizontal)) }
            }
        }
    }
}
#endif
