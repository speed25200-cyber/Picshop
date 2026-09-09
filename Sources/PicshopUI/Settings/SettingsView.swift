#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopVideo
import PicshopSpeech

/// Preferences: AI brain, models, performance, voice, feedback, export.
public struct SettingsView: View {
    @Environment(\.picshop) private var app
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                if let app {
                    identityHeader
                    brainSection(app)
                    modelsSection(app)
                    performanceSection(app)
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

    /// App identity at the top, like the Apple ID card in Settings: the icon
    /// tile, the version and the one promise that matters (nothing leaves).
    private var identityHeader: some View {
        Section {
            HStack(spacing: 14) {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 24, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background { HeroMesh().clipShape(shape).overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))) }
                    .overlay(shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: PSTheme.voice.opacity(0.4), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PicShop").font(PSFont.display(22)).foregroundStyle(PSTheme.textPrimary).tracking(-0.4)
                    HStack(spacing: 6) {
                        Text(L("Version")).foregroundStyle(PSTheme.textTertiary)
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                        Text("·").foregroundStyle(PSTheme.textTertiary)
                        Label(L("On-device, private"), systemImage: "lock.shield.fill").foregroundStyle(PSTheme.success)
                    }
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    /// The brain is chosen automatically; this row only shows which one is answering.
    @ViewBuilder
    private func brainSection(_ app: AppEnvironment) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: app.activeEngine == .rules ? "bolt.fill" : "brain.head.profile")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
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
            SettingsRow(systemName: "arrow.down.circle.fill", tint: PSTheme.accent) {
                Toggle(L("Download large models automatically"), isOn: Binding(get: { app.settings.autoInstallsModels }, set: { value in
                    app.settings.autoInstallsModels = value
                    if value { Task { await app.autoInstallModels() } }
                }))
            }
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

    /// Thermal / battery budget: what the phone is doing right now and how PicShop should react.
    @ViewBuilder
    private func performanceSection(_ app: AppEnvironment) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: app.performance.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(app.performance.statusTint)
                    .frame(width: 36, height: 36)
                    .background(app.performance.statusTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.performance.statusTitle).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                    Text(tierDescription(app.performance.tier)).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    TierDots(tier: app.performance.tier, tint: app.performance.statusTint)
                    Text("\(Int(app.performance.previewLongestSide)) px").font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary).contentTransition(.numericText())
                }
            }
            .animation(PSMotion.quick, value: app.performance.tier)
            SegmentedChoice(selection: Binding(get: { app.settings.performancePreference }, set: { value in
                Haptics.tick()
                app.settings.performancePreference = value
                app.applyPerformanceSettings()
            }), options: [
                .init(value: PerformanceGovernor.Preference.automatic, title: L("Automatic"), symbol: "wand.and.sparkles"),
                .init(value: .quality, title: L("Best quality"), symbol: "sparkles.rectangle.stack"),
                .init(value: .efficiency, title: L("Cool & battery"), symbol: "leaf.fill"),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text(L("Performance"))
        } footer: {
            Text(L("Automatic follows the iPhone's temperature: previews shrink and glow effects pause before the frame rate drops, and heavy AI work waits until the phone cools down. Exports are always full quality."))
        }
    }

    private func tierDescription(_ tier: PerformanceGovernor.Tier) -> String {
        switch tier {
        case .full: return L("Full quality previews at the display's refresh rate.")
        case .balanced: return L("Slightly lighter previews; effects unchanged.")
        case .conserve: return L("Lighter previews and no glow, to cool down.")
        case .critical: return L("Minimal rendering until the iPhone cools down.")
        }
    }

    @ViewBuilder
    private func voiceSection(_ app: AppEnvironment) -> some View {
        Section(L("Voice")) {
            SettingsRow(systemName: "mic.fill", tint: PSTheme.voice) {
                Picker(L("Activation"), selection: Binding(get: { app.settings.voiceMode }, set: { app.settings.voiceMode = $0; app.applyVoiceSettings() })) {
                    Text(L("Tap to talk")).tag(VoiceController.Mode.tapToTalk)
                    Text(L("Hold to talk")).tag(VoiceController.Mode.pushToTalk)
                    Text(L("Hands-free")).tag(VoiceController.Mode.handsFree)
                }
            }
            SettingsRow(systemName: "globe", tint: PSTheme.success) {
                Picker(L("Language"), selection: Binding(get: { app.settings.voiceLanguage }, set: { app.settings.voiceLanguage = $0; app.applyVoiceSettings() })) {
                    Text(L("Automatic")).tag("auto")
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                }
            }
            SettingsRow(systemName: "speaker.wave.2.fill", tint: PSTheme.voice) {
                Toggle(L("Speak replies"), isOn: Binding(get: { app.settings.speaksReplies }, set: { app.settings.speaksReplies = $0 }))
            }
            SettingsRow(systemName: "hand.tap.fill", tint: PSTheme.danger) {
                Toggle(L("Haptics"), isOn: Binding(get: { app.settings.hapticsEnabled }, set: { app.settings.hapticsEnabled = $0 }))
            }
        }
    }

    @ViewBuilder
    private func exportSection(_ app: AppEnvironment) -> some View {
        Section(L("Export defaults")) {
            SettingsRow(systemName: "photo.fill", tint: PSTheme.accent) {
                Picker(L("Photo format"), selection: Binding(get: { app.settings.photoExportFormat }, set: { app.settings.photoExportFormat = $0 })) {
                    ForEach(ExportOptions.Format.allCases) { Text($0.displayName).tag($0) }
                }
            }
            SettingsRow(systemName: "film.fill", tint: PSTheme.voice) {
                Picker(L("Video quality"), selection: Binding(get: { app.settings.videoExportQuality }, set: { app.settings.videoExportQuality = $0 })) {
                    ForEach(VideoExportOptions.Quality.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsRowIcon(systemName: "hand.raised.fill", tint: PSTheme.success)
                Text(L("Photos, videos and voice never leave your device. PicShop has no servers, no accounts and no tracking."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        } header: {
            Text(L("Privacy"))
        }
    }
}

/// Four dots that read the performance tier at a glance: all lit is full
/// quality, one lit is the critical tier.
struct TierDots: View {
    let tier: PerformanceGovernor.Tier
    let tint: Color

    private var lit: Int {
        switch tier {
        case .full: return 4
        case .balanced: return 3
        case .conserve: return 2
        case .critical: return 1
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(index < lit ? tint : PSTheme.hairline).frame(width: 10, height: 4)
            }
        }
        .animation(PSMotion.quick, value: lit)
        .accessibilityHidden(true)
    }
}

/// Illustrated segments for a short list of choices, the same control the
/// export sheets use, so settings feel like the rest of the app.
struct SegmentedChoice<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let symbol: String
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let isActive = selection == option.value
                Button {
                    withAnimation(PSMotion.standard) { selection = option.value }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol).font(.system(size: 15, weight: .semibold)).symbolRenderingMode(.hierarchical)
                        Text(option.title).font(PSFont.caption(11)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.accentGradient)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.accentHighlight))
                                .matchedGeometryEffect(id: "segment", in: indicator)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// Coloured squircle in front of a settings row, like the system Settings app.
struct SettingsRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
    }
}

/// A picker or toggle with the settings icon leading it.
struct SettingsRow<Content: View>: View {
    let systemName: String
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(systemName: systemName, tint: tint)
            content()
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
