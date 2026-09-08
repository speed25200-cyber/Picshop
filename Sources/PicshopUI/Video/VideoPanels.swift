#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopVideo

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(speeds, id: \.self) { speed in
                    PanelChip(title: "×\(speed == speed.rounded() ? String(Int(speed)) : String(speed))", isActive: session.selectedClip?.speed == speed) {
                        session.perform(EditIntent(action: .setSpeed, amount: .absolute(speed)))
                    }
                }
            }
            Text(L("Slow motion keeps every frame; time-lapse drops them. Audio follows the speed."))
                .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
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
                PanelChip(title: session.timeline.audioTracks.isEmpty ? L("Add music") : L("Replace music"), symbol: "music.note") { session.showsMusicPicker = true }
                if !session.timeline.audioTracks.isEmpty {
                    PanelChip(title: L("Remove music"), symbol: "music.note.list") { session.perform(EditIntent(action: .removeMusic)) }
                }
            }
            ParameterSlider(title: L("Clip volume"), value: $volume, range: 0...2, bipolar: false) { editing in
                if editing { session.beginSliderInteraction(L("Volume")) } else { session.endSliderInteraction() }
            }
            .onChange(of: volume) { _, value in session.updateSelectedClip(L("Volume")) { $0.volume = value; if value > 0 { $0.isMuted = false } } }
            .onAppear { volume = session.selectedClip?.volume ?? 1 }
            if let music = session.timeline.audioTracks.first {
                ParameterSlider(title: "\(L("Music")) · \(music.name)", value: Binding(get: { music.volume }, set: { value in session.update(L("Music Volume")) { $0.audioTracks[0].volume = value } }), range: 0...1, bipolar: false)
            }
        }
    }
}

struct VideoLooksPanel: View {
    @Bindable var session: VideoEditorSession

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterPreset.gallery) { preset in
                        PanelChip(title: Locale.current.language.languageCode?.identifier == "fr" ? preset.frenchName : preset.englishName, isActive: session.selectedClip?.look == preset) {
                            session.perform(EditIntent(action: .applyLook, look: preset))
                        }
                    }
                }
            }
            PanelChip(title: L("Apply to all clips"), symbol: "square.stack") {
                if let look = session.selectedClip?.look { session.perform(EditIntent(action: .applyLook, look: look, scope: .all)) }
            }
        }
    }
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
                    .padding(.horizontal, 14).padding(.vertical, 10).background(PSTheme.hairline, in: Capsule())
                    .submitLabel(.done).onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                    .buttonStyle(.plain).foregroundStyle(.black).psGlass(tint: PSTheme.accent, interactive: true, shape: AnyShape(Circle()))
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
                        PanelChip(title: kind.displayName, isActive: session.selectedClip?.transitionOut?.kind == kind) {
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
                Text(L("Split the video first to add a transition between two clips.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
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
