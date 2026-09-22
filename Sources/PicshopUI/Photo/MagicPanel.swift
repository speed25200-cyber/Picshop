#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore
import PicshopIntent

/// The Magic tab of the photo editor: say or type what you want, or pick
/// one of the things PicShop can already see to do. Everything here goes
/// through the same planner as the voice, so a typed "make the sky more
/// dramatic" and a spoken one behave the same.
struct MagicPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var prompt = ""
    @FocusState private var focused: Bool
    @State private var showsReferencePicker = false
    @State private var referenceItem: PhotosPickerItem?

    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let run: @MainActor (PhotoEditorSession) -> Void
    }

    private var suggestions: [Suggestion] {
        let fr = psPrefersFrench
        func say(_ french: String, _ english: String) -> @MainActor (PhotoEditorSession) -> Void {
            { session in Task { await session.handleTranscript(fr ? french : english) } }
        }
        return [
            Suggestion(id: "enhance", title: L("Enhance"), symbol: "wand.and.stars") { $0.perform(EditIntent(action: .autoEnhance)) },
            Suggestion(id: "behind", title: L("Text behind"), symbol: "person.and.background.dotted") { session in Task { await session.textBehindSubject() } },
            Suggestion(id: "match", title: L("Match colours"), symbol: "eyedropper.halffull") { _ in showsReferencePicker = true },
            Suggestion(id: "people", title: L("Erase people"), symbol: "person.2.slash") { $0.eraseAll(label: "person", phrase: L("people")) },
            Suggestion(id: "cutout", title: L("Cut out"), symbol: "person.crop.rectangle") { $0.perform(EditIntent(action: .removeBackground)) },
            Suggestion(id: "portrait", title: L("Portrait blur"), symbol: "camera.aperture", run: say("floute l'arrière-plan", "blur the background")),
            Suggestion(id: "relight", title: L("Relight"), symbol: "lightbulb.max") { $0.perform(EditIntent(action: .relight)) },
            Suggestion(id: "sky", title: L("Sunset sky"), symbol: "sun.horizon", run: say("remplace le ciel par un coucher de soleil", "replace the sky with a sunset")),
            Suggestion(id: "upscale", title: L("Upscale"), symbol: "arrow.up.left.and.arrow.down.right") { $0.perform(EditIntent(action: .upscale, amount: .absolute(2))) },
            Suggestion(id: "denoise", title: L("Denoise"), symbol: "circle.dotted.circle") { $0.perform(EditIntent(action: .denoise)) },
            Suggestion(id: "mono", title: L("Black & white"), symbol: "circle.lefthalf.filled", run: say("noir et blanc", "black and white")),
            Suggestion(id: "expand", title: L("Expand"), symbol: "arrow.up.left.and.arrow.down.right") { $0.expandCanvas() },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptField
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        Haptics.magic()
                        suggestion.run(session)
                    } label: {
                        VStack(spacing: 6) {
                            MagicGlyph(size: 18, symbol: suggestion.symbol)
                                .frame(height: 22)
                            Text(suggestion.title).font(PSFont.label(10)).foregroundStyle(PSTheme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PSPressStyle(scale: 0.94))
                    .disabled(session.isProcessing)
                    .accessibilityLabel(suggestion.title)
                }
            }
            if !session.sceneObjects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("In this photo")).font(PSFont.label(11)).textCase(.uppercase).tracking(0.6).foregroundStyle(PSTheme.textTertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(session.sceneObjects) { candidate in
                                SceneObjectChip(candidate: candidate, thumbnail: { await session.candidateThumbnail($0) }) {
                                    session.erase(candidate)
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(PSMotion.standard, value: session.sceneObjects.map(\.id))
        .task(id: session.lookThumbnailKey) { await session.loadSceneObjects() }
        .photosPicker(isPresented: $showsReferencePicker, selection: $referenceItem, matching: .images)
        .onChange(of: referenceItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let data { await session.matchColors(to: data) }
                referenceItem = nil
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
#endif
