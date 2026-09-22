#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// The Magic tab of the video editor: the automatic tools a pro editor
/// would spend an afternoon on — captions, jump cuts, cuts on the beat,
/// vertical reframing that follows the subject, clean dialogue, matched
/// colour — each one tap, plus a prompt that takes any request.
struct VideoMagicPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var prompt = ""
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let intent: EditIntent
    }

    private var actions: [Action] {
        var reframe = EditIntent(action: .smartReframe)
        reframe.aspect = .ratio9x16
        var square = EditIntent(action: .smartReframe)
        square.aspect = .square
        return [
            Action(id: "captions", title: L("Captions"), symbol: "captions.bubble", intent: EditIntent(action: .autoCaptions)),
            Action(id: "silences", title: L("Jump cuts"), symbol: "scissors", intent: EditIntent(action: .removeSilences)),
            Action(id: "beat", title: L("On the beat"), symbol: "metronome", intent: EditIntent(action: .syncToBeat)),
            Action(id: "vertical", title: L("Vertical"), symbol: "rectangle.portrait", intent: reframe),
            Action(id: "square", title: L("Square"), symbol: "square", intent: square),
            Action(id: "voice", title: L("Clean voice"), symbol: "waveform.badge.mic", intent: EditIntent(action: .enhanceVoice, scope: .all)),
            Action(id: "kenburns", title: L("Camera move"), symbol: "arrow.up.left.and.arrow.down.right", intent: EditIntent(action: .kenBurns, scope: .all)),
            Action(id: "match", title: L("Match colour"), symbol: "circle.lefthalf.striped.horizontal", intent: EditIntent(action: .matchColor, scope: .all)),
            Action(id: "stabilize", title: L("Stabilize"), symbol: "camera.metering.center.weighted", intent: EditIntent(action: .stabilize)),
            Action(id: "enhance", title: L("Enhance"), symbol: "wand.and.stars", intent: EditIntent(action: .autoEnhance)),
            Action(id: "portrait", title: L("Portrait blur"), symbol: "camera.aperture", intent: EditIntent(action: .blurBackground)),
            Action(id: "slowmo", title: L("Slow motion"), symbol: "tortoise", intent: EditIntent(action: .setSpeed, amount: .absolute(0.5))),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptField
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        Haptics.magic()
                        let intent = action.intent
                        Task { await session.run(intent) }
                    } label: {
                        VStack(spacing: 6) {
                            MagicGlyph(size: 18, symbol: action.symbol).frame(height: 22)
                            Text(action.title).font(PSFont.label(10)).foregroundStyle(PSTheme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PSPressStyle(scale: 0.94))
                    .disabled(session.isProcessing)
                    .accessibilityLabel(action.title)
                }
            }
            if let captions = session.timeline.captions, !captions.isEmpty {
                captionStyles(captions)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(PSMotion.standard, value: session.timeline.captions?.style)
    }

    /// Once captions exist: their look, their place, and a way to remove them.
    private func captionStyles(_ captions: CaptionTrack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Caption style")).font(PSFont.label(11)).textCase(.uppercase).tracking(0.6).foregroundStyle(PSTheme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptionStyle.allCases) { style in
                        PanelChip(title: psPrefersFrench ? style.frenchName : style.displayName, isActive: captions.style == style) {
                            session.update("Caption Style") { timeline in timeline.captions?.restyle(style) }
                        }
                    }
                    PanelChip(title: captions.verticalPosition > 0.5 ? L("Move up") : L("Move down"), symbol: captions.verticalPosition > 0.5 ? "arrow.up" : "arrow.down") {
                        session.update("Caption Position") { timeline in
                            let current = timeline.captions?.verticalPosition ?? 0.72
                            timeline.captions?.verticalPosition = current > 0.5 ? 0.2 : 0.72
                        }
                    }
                    PanelChip(title: L("Remove"), symbol: "trash") {
                        Task { await session.run(EditIntent(action: .removeCaptions)) }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var promptField: some View {
        HStack(spacing: 10) {
            MagicGlyph(size: 15)
            TextField(L("Describe an edit…"), text: $prompt)
                .font(PSFont.body(15))
                .foregroundStyle(PSTheme.textPrimary)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(run)
            if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: run) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(L("Apply"))
            }
        }
        .padding(.leading, 14).padding(.trailing, 7)
        .frame(height: 46)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(PSTheme.intelligenceAngular, lineWidth: focused ? 1.5 : 0.8).opacity(focused ? 1 : 0.55))
        .animation(PSMotion.quick, value: prompt.isEmpty)
        .animation(PSMotion.quick, value: focused)
    }

    private func run() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        focused = false
        Haptics.magic()
        Task { await session.handleTranscript(text) }
    }
}

/// Colour for the selected clip: the mixer and the wheels.
struct VideoColorPanel: View {
    @Bindable var session: VideoEditorSession

    var body: some View {
        ColorControls(mixer: session.selectedClip?.colorMixer ?? .neutral,
                      grade: session.selectedClip?.colorGrade ?? .neutral,
                      onMixer: { mixer in session.updateSelectedClip("Colour Mixer") { $0.colorMixer = mixer.isNeutral ? nil : mixer } },
                      onGrade: { grade in session.updateSelectedClip("Colour Grading") { $0.colorGrade = grade.isNeutral ? nil : grade } },
                      onBegin: { session.beginSliderInteraction($0) },
                      onEnd: { session.endSliderInteraction() })
    }
}
#endif
