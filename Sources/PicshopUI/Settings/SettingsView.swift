#if canImport(SwiftUI) && canImport(UIKit)
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
            .scrollContentBackground(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .navigationTitle(L("Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(PSTheme.accent)
    }

    /// The brain is chosen automatically; this row only shows which one is answering.
    @ViewBuilder
    private func brainSection(_ app: AppEnvironment) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: app.activeEngine == .rules ? "bolt.fill" : "brain.head.profile")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PSTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(PSTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.activeEngine.displayName).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                    Text(description(for: app.activeEngine, app: app)).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.success)
            }
        } header: {
            Text(L("AI brain"))
        } footer: {
            Text(L("PicShop always uses the most capable brain available on this iPhone. The instant grammar answers first; the language model steps in for complex or ambiguous requests. Everything runs on device."))
        }
    }

    private func description(for kind: IntentEngineKind, app: AppEnvironment) -> String {
        switch kind {
        case .rules: return app.appleIntelligenceReason ?? L("Deterministic grammar, instant, offline. Always on.")
        case .appleIntelligence: return L("Apple's on-device foundation model with guided generation.")
        case .proLocal: return L("Qwen3 4B through MLX — best for long multi-step commands.")
        }
    }

    @ViewBuilder
    private func modelsSection(_ app: AppEnvironment) -> some View {
        Section {
            ForEach(ModelCatalog.all) { model in
                let state = app.modelStates[model.id] ?? .notInstalled
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localizedName(model)).font(PSFont.headline(15))
                        Text(localizedSummary(model)).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                        Text(ModelManager.isBundled(model.id) ? L("Included in the app") : "\(model.sizeMB) MB").font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                    }
                    Spacer()
                    if ModelManager.isBundled(model.id) {
                        Label(L("Ready"), systemImage: "checkmark.seal.fill").font(PSFont.caption(13)).foregroundStyle(PSTheme.success)
                    } else {
                        modelControl(model, state: state, app: app)
                    }
                }
            }
            Toggle(L("Download large models automatically"), isOn: Binding(get: { app.settings.autoInstallsModels }, set: { value in
                app.settings.autoInstallsModels = value
                if value { Task { await app.autoInstallModels() } }
            }))
        } header: {
            Text(L("On-device models"))
        } footer: {
            Text(L("The eraser and the upscaler ship with the app. Generative Fill and the Pro Brain are large: they download by themselves over Wi‑Fi the first time, and everything runs on your iPhone."))
        }
    }

    private func localizedName(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("Neural eraser")
        case "realesrgan-x4": return L("Super resolution ×4")
        case "sd-generative-fill": return L("Generative Fill")
        case "qwen3-4b-4bit": return L("Pro Brain")
        default: return model.displayName
        }
    }

    private func localizedSummary(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("LaMa network for clean object removal on complex backgrounds.")
        case "realesrgan-x4": return L("Real-ESRGAN upscaler for sharp enlargements.")
        case "sd-generative-fill": return L("Stable Diffusion: “replace the sky with a sunset”, “add a hat”.")
        case "qwen3-4b-4bit": return L("Qwen3 4B language model for long, multi-step voice commands.")
        default: return model.summary
        }
    }

    @ViewBuilder
    private func modelControl(_ model: ModelDescriptor, state: ModelManager.State, app: AppEnvironment) -> some View {
        switch state {
        case .installed:
            Menu {
                Button(role: .destructive) { Task { await app.delete(model) } } label: { Label(L("Delete"), systemImage: "trash") }
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
        guard app.install(model) else {
            app.library.errorMessage = model.kind == .generative
                ? L("This build was compiled without the Stable Diffusion runtime.")
                : L("This build was compiled without the MLX runtime.")
            return
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
