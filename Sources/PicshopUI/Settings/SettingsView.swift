#if canImport(SwiftUI)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopVideo
import PicshopSpeech

/// Preferences: AI brain, models, voice, feedback, export.
public struct SettingsView: View {
    @Environment(\.picshop) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var modelStates: [String: ModelManager.State] = [:]
    @State private var observerToken: UUID?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                if let app {
                    brainSection(app)
                    modelsSection(app)
                    voiceSection(app)
                    exportSection(app)
                    aboutSection
                }
            }
            .navigationTitle(L("Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(PSTheme.accent)
        .task { await observeModels() }
        .onDisappear {
            if let token = observerToken, let models = app?.models { Task { await models.removeObserver(token) } }
        }
    }

    @ViewBuilder
    private func brainSection(_ app: AppEnvironment) -> some View {
        Section {
            ForEach(IntentEngineKind.allCases) { kind in
                let available = app.availableEngines.contains(kind)
                Button {
                    guard available else { return }
                    Haptics.tick()
                    app.settings.preferredEngine = kind
                    app.applyVoiceSettings()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName).font(PSFont.headline(15)).foregroundStyle(available ? PSTheme.textPrimary : PSTheme.textSecondary)
                            Text(description(for: kind, app: app)).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                        }
                        Spacer()
                        if app.settings.preferredEngine == kind, available {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.accent)
                        }
                    }
                }
                .disabled(!available)
            }
        } header: {
            Text(L("AI brain"))
        } footer: {
            Text(L("Every brain runs entirely on your iPhone. The instant grammar always runs first; the language model is consulted only for ambiguous or complex requests."))
        }
    }

    private func description(for kind: IntentEngineKind, app: AppEnvironment) -> String {
        switch kind {
        case .rules: return L("Deterministic grammar, instant, offline. Always on.")
        case .appleIntelligence:
            return app.availableEngines.contains(.appleIntelligence) ? L("Apple's on-device foundation model with guided generation.") : (app.appleIntelligenceReason ?? L("Requires Apple Intelligence."))
        case .proLocal:
            return app.availableEngines.contains(.proLocal) ? L("Qwen3 4B through MLX — best for long multi-step commands.") : L("Download the Pro Brain model below to enable.")
        }
    }

    @ViewBuilder
    private func modelsSection(_ app: AppEnvironment) -> some View {
        Section {
            ForEach(ModelCatalog.all) { model in
                let state = modelStates[model.id] ?? .notInstalled
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName).font(PSFont.headline(15))
                        Text(model.summary).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                        Text("\(model.sizeMB) MB").font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                    }
                    Spacer()
                    modelControl(model, state: state, app: app)
                }
            }
            HStack {
                Text(L("Model server"))
                TextField("https://…", text: Binding(get: { app.settings.modelBaseURL }, set: { app.settings.modelBaseURL = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(PSFont.mono(12)).multilineTextAlignment(.trailing)
            }
        } header: {
            Text(L("On-device models"))
        } footer: {
            Text(L("Neural models improve object removal and upscaling. Without them, PicShop uses its built-in PatchMatch engine — see docs/MODELS.md to host the archives."))
        }
    }

    @ViewBuilder
    private func modelControl(_ model: ModelDescriptor, state: ModelManager.State, app: AppEnvironment) -> some View {
        switch state {
        case .installed:
            Menu {
                Button(role: .destructive) { Task { try? await app.models.delete(model.id); await app.refreshEngines() } } label: { Label(L("Delete"), systemImage: "trash") }
            } label: {
                Label(L("Installed"), systemImage: "checkmark.circle.fill").font(PSFont.caption(13)).foregroundStyle(PSTheme.success)
            }
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: progress).frame(width: 80)
                Button(L("Cancel")) { Task { await app.models.cancelInstall(model.id) } }.font(PSFont.caption(12))
            }
        case .compiling:
            ProgressView()
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button(L("Retry")) { install(model, app: app) }.font(PSFont.caption(13))
                Text(message).font(PSFont.caption(10)).foregroundStyle(PSTheme.danger).lineLimit(2).frame(maxWidth: 160, alignment: .trailing)
            }
        case .notInstalled:
            Button(L("Get")) { install(model, app: app) }
                .font(PSFont.caption(13)).buttonStyle(.borderedProminent).tint(PSTheme.accent)
        }
    }

    private func install(_ model: ModelDescriptor, app: AppEnvironment) {
        Haptics.tap()
        if model.kind == .generative, app.generativeEngineProvider == nil {
            app.library.errorMessage = L("This build was compiled without the Stable Diffusion runtime.")
            return
        }
        if model.kind == .languageModel {
            Task { await ProBrainInstaller.shared?.install(model, app: app) }
        } else {
            Task { await app.models.install(model) }
        }
    }

    private func observeModels() async {
        guard let app else { return }
        for model in ModelCatalog.all {
            modelStates[model.id] = await app.models.state(of: model.id)
        }
        observerToken = await app.models.observe { id, state in
            Task { @MainActor in
                modelStates[id] = state
                if case .installed = state { await app.refreshEngines() }
            }
        }
    }

    @ViewBuilder
    private func voiceSection(_ app: AppEnvironment) -> some View {
        Section(L("Voice")) {
            Picker(L("Activation"), selection: Binding(get: { app.settings.voiceMode }, set: { app.settings.voiceMode = $0; app.applyVoiceSettings() })) {
                Text(L("Tap to talk")).tag(VoiceController.Mode.tapToTalk)
                Text(L("Hold to talk")).tag(VoiceController.Mode.pushToTalk)
                Text(L("Hands-free")).tag(VoiceController.Mode.handsFree)
            }
            Picker(L("Language"), selection: Binding(get: { app.settings.voiceLanguage }, set: { app.settings.voiceLanguage = $0; app.applyVoiceSettings() })) {
                Text(L("Automatic")).tag("auto")
                Text("Français").tag("fr")
                Text("English").tag("en")
            }
            Toggle(L("Speak replies"), isOn: Binding(get: { app.settings.speaksReplies }, set: { app.settings.speaksReplies = $0 }))
            Toggle(L("Show transcript"), isOn: Binding(get: { app.settings.showsVoiceTranscript }, set: { app.settings.showsVoiceTranscript = $0 }))
            Toggle(L("Haptics"), isOn: Binding(get: { app.settings.hapticsEnabled }, set: { app.settings.hapticsEnabled = $0 }))
        }
    }

    @ViewBuilder
    private func exportSection(_ app: AppEnvironment) -> some View {
        Section(L("Export defaults")) {
            Picker(L("Photo format"), selection: Binding(get: { app.settings.photoExportFormat }, set: { app.settings.photoExportFormat = $0 })) {
                ForEach(ExportOptions.Format.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(L("Video quality"), selection: Binding(get: { app.settings.videoExportQuality }, set: { app.settings.videoExportQuality = $0 })) {
                ForEach(VideoExportOptions.Quality.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(L("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            Text(L("Photos, videos and voice never leave your device. PicShop has no servers, no accounts and no tracking."))
                .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
        } header: {
            Text(L("Privacy"))
        }
    }
}

/// Bridge so the settings screen can trigger language-model downloads that
/// live in the app target (MLX). Registered by the app at launch.
@MainActor
public final class ProBrainInstaller {
    public static var shared: ProBrainInstaller?
    private let handler: (ModelDescriptor, AppEnvironment) async -> Void

    public init(handler: @escaping (ModelDescriptor, AppEnvironment) async -> Void) {
        self.handler = handler
    }

    public func install(_ model: ModelDescriptor, app: AppEnvironment) async {
        await handler(model, app)
    }
}
#endif
