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
        let tiles: [Suggestion] = [
            Suggestion(id: "enhance", title: L("Enhance"), symbol: "wand.and.stars") { $0.perform(EditIntent(action: .autoEnhance)) },
            Suggestion(id: "cleanup", title: L("Clean up"), symbol: "person.2.slash") { $0.perform(EditIntent(action: .cleanUp)) },
            Suggestion(id: "expand", title: L("Expand"), symbol: "arrow.up.left.and.arrow.down.right") { $0.expandCanvas() },
            Suggestion(id: "behind", title: L("Text behind"), symbol: "person.and.background.dotted") { session in Task { await session.textBehindSubject() } },
            Suggestion(id: "retouch", title: L("Retouch"), symbol: "face.smiling", run: say("lisse la peau et éclaircis les yeux et blanchis les dents", "smooth the skin and brighten the eyes and whiten the teeth")),
            Suggestion(id: "portrait", title: L("Portrait blur"), symbol: "camera.aperture", run: say("floute l'arrière-plan", "blur the background")),
            Suggestion(id: "sky", title: L("Sunset sky"), symbol: "sun.horizon", run: say("remplace le ciel par un coucher de soleil", "replace the sky with a sunset")),
            Suggestion(id: "match", title: L("Match colours"), symbol: "eyedropper.halffull") { $0.showsColorReferencePicker = true },
            Suggestion(id: "relight", title: L("Relight"), symbol: "lightbulb.max") { $0.perform(EditIntent(action: .relight)) },
            Suggestion(id: "cutout", title: L("Cut out"), symbol: "person.crop.rectangle") { $0.perform(EditIntent(action: .removeBackground)) },
            Suggestion(id: "upscale", title: L("Upscale"), symbol: "arrow.up.left.and.arrow.down.right") { $0.perform(EditIntent(action: .upscale, amount: .absolute(2))) },
            Suggestion(id: "mono", title: L("Black & white"), symbol: "circle.lefthalf.filled", run: say("noir et blanc", "black and white")),
        ]
        // The picture decides the order: a portrait leads with the retouch, a crowd with Clean up.
        let order = MagicSuggestions.ranked(for: session.sceneDescription)
        return tiles.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            promptField
            // One scrolling row, so the panel stays short and the photo stays big.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            Haptics.magic()
                            suggestion.run(session)
                        } label: {
                            VStack(spacing: 6) {
                                MagicGlyph(size: 20, symbol: suggestion.symbol)
                                    .frame(height: 24)
                                Text(suggestion.title).font(.caption2.weight(.medium)).foregroundStyle(PSTheme.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .frame(width: 72, height: 64)
                            .background(PanelChipStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PSPressStyle(scale: 0.95))
                        .disabled(session.isProcessing)
                        .accessibilityLabel(suggestion.title)
                    }
                }
                .padding(.horizontal, 2)
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            if !session.sceneObjects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.sceneObjects) { candidate in
                            SceneObjectChip(candidate: candidate, thumbnail: { await session.candidateThumbnail($0) }) {
                                session.erase(candidate)
                            }
                            .contextMenu {
                                Button { session.erase(candidate) } label: { Label(L("Erase"), systemImage: "eraser") }
                                Divider()
                                Button { session.move(candidate, degrees: 180) } label: { Label(L("Move left"), systemImage: "arrow.left") }
                                Button { session.move(candidate, degrees: 0) } label: { Label(L("Move right"), systemImage: "arrow.right") }
                                Button { session.move(candidate, degrees: 90) } label: { Label(L("Move up"), systemImage: "arrow.up") }
                                Button { session.move(candidate, degrees: -90) } label: { Label(L("Move down"), systemImage: "arrow.down") }
                                Button { session.move(candidate, degrees: nil) } label: { Label(L("Centre it"), systemImage: "scope") }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .accessibilityHint(L("Tap to erase · hold to move"))
                .transition(.opacity)
            }
        }
        .animation(PSMotion.standard, value: session.sceneObjects.map(\.id))
        .animation(PSMotion.standard, value: session.sceneDescription)
        .task(id: session.lookThumbnailKey) { await session.loadSceneObjects() }
        .photosPicker(isPresented: $session.showsColorReferencePicker, selection: $referenceItem, matching: .images)
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
                .font(.body)
                .foregroundStyle(PSTheme.textPrimary)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(run)
            if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: run) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .transition(.opacity)
                .accessibilityLabel(L("Apply"))
            }
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: 44)
        .background(Capsule().fill(PanelChipStyle.fill))
        // The spectrum rim only while the AI is being spoken to.
        .overlay(Capsule().strokeBorder(PSTheme.intelligenceAngular, lineWidth: 1).opacity(focused ? 0.9 : 0))
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
