#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Settings › Avancé: the on-device models, the performance budget, the
/// diagnostics report and the build this is. The local brain's language model
/// lives in Settings › Intelligence, not here.
struct AdvancedSettingsView: View {
    @Environment(\.picshop) private var app
    /// The diagnostics text file, written when the screen opens.
    @State private var reportURL: URL?

    var body: some View {
        Form {
            if let app {
                modelsSection(app)
                performanceSection(app)
                diagnosticsSection(app)
                buildSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackground().ignoresSafeArea())
        .navigationTitle(L("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    // MARK: Models

    @ViewBuilder
    private func modelsSection(_ app: AppEnvironment) -> some View {
        Section {
            ForEach(ModelCatalog.all.filter { $0.kind != .languageModel }) { model in
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
            SettingsRow(systemName: "arrow.down.circle.fill", tint: PSTheme.voice) {
                Toggle(L("Download large models automatically"), isOn: Binding(get: { app.settings.autoInstallsModels }, set: { value in
                    app.settings.autoInstallsModels = value
                    if value { Task { await app.autoInstallModels() } }
                }))
            }
        } header: {
            Text(L("On-device models"))
        } footer: {
            Text(L("The eraser and the upscaler ship with the app. Generative Fill is large: it downloads by itself over Wi‑Fi the first time, and everything runs on your iPhone. The local brain is in Settings › Intelligence."))
        }
    }

    private func localizedName(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("Neural eraser")
        case "realesrgan-x4": return L("Super resolution ×4")
        case "sd-generative-fill": return L("Generative Fill")
        default: return model.displayName
        }
    }

    private func localizedSummary(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("LaMa network for clean object removal on complex backgrounds.")
        case "realesrgan-x4": return L("Real-ESRGAN upscaler for sharp enlargements.")
        case "sd-generative-fill": return L("Stable Diffusion: “replace the sky with a sunset”, “add a hat”.")
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
                .font(.subheadline.weight(.semibold)).buttonStyle(.glass).controlSize(.small)
        }
    }

    private func install(_ model: ModelDescriptor, app: AppEnvironment) {
        Haptics.tap()
        guard app.install(model) else {
            app.library.errorMessage = L("This build was compiled without the Stable Diffusion runtime.")
            return
        }
    }

    // MARK: Performance

    /// Thermal / battery budget: what the phone is doing right now and how PicShop should react.
    @ViewBuilder
    private func performanceSection(_ app: AppEnvironment) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: app.performance.statusSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(app.performance.statusTint)
                    .frame(width: 36, height: 36)
                    .background(PSTheme.fill, in: RoundedRectangle(cornerRadius: PSRadius.thumb, style: .continuous))
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

    // MARK: Diagnostics

    /// A session that ended badly offers its report; the current breadcrumbs
    /// can always be shared when asking for help.
    @ViewBuilder
    private func diagnosticsSection(_ app: AppEnvironment) -> some View {
        Section {
            if let report = app.pendingCrashReport {
                HStack(spacing: 12) {
                    SettingsRowIcon(systemName: "exclamationmark.triangle.fill", tint: PSTheme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.kind == .crash ? L("PicShop quit unexpectedly") : L("PicShop was closed unexpectedly"))
                            .font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                        Text(report.date, format: .relative(presentation: .named))
                            .font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }
            if let reportURL {
                ShareLink(item: reportURL, subject: Text(verbatim: "PicShop diagnostics")) {
                    Label(app.pendingCrashReport == nil ? L("Share diagnostics") : L("Share the report"), systemImage: "square.and.arrow.up")
                }
            }
            if app.pendingCrashReport != nil {
                Button(L("Dismiss")) {
                    Haptics.tap()
                    app.dismissCrashReport()
                }
                .foregroundStyle(PSTheme.textSecondary)
            }
        } header: {
            Text(L("Diagnostics"))
        } footer: {
            Text(L("The report says what PicShop was doing, including your last commands, with the device model and free memory. No photos, videos or recordings. It leaves your iPhone only if you share it."))
        }
        .task(id: app.pendingCrashReport?.id) {
            reportURL = app.writeCrashReport()
        }
    }

    // MARK: Build

    private var buildSection: some View {
        Section {
            LabeledContent(L("Version")) {
                Text(verbatim: "\(BuildInfo.version) (\(BuildInfo.buildNumber))")
            }
            LabeledContent(L("Build")) {
                HStack(spacing: 6) {
                    Text(verbatim: BuildInfo.commit).font(PSFont.mono(12))
                    if !BuildInfo.branch.isEmpty { Text(verbatim: BuildInfo.branch).lineLimit(1).truncationMode(.middle) }
                    if !BuildInfo.date.isEmpty { Text(verbatim: BuildInfo.date) }
                }
                .font(PSFont.caption(12))
                .foregroundStyle(PSTheme.textTertiary)
            }
            .textSelection(.enabled)
        }
    }
}
#endif
