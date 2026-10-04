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
    /// MetricKit's days, read from the device when the screen opens.
    @State private var measuredDays: [PerformanceDay] = []
    /// Bumped when a flag changes, so its row redraws (flags live in UserDefaults).
    @State private var flagsRevision = 0

    var body: some View {
        Form {
            if let app {
                modelsSection(app)
                performanceSection(app)
                measuredSection
                experimentalSection
                diagnosticsSection(app)
                buildSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackground().ignoresSafeArea())
        .navigationTitle(L("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
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
            SettingsRow(systemName: "antenna.radiowaves.left.and.right", tint: PSTheme.voice) {
                Toggle(L("Mask models over cellular"), isOn: Binding(get: { app.settings.maskModelsAllowCellular }, set: { value in
                    Haptics.tick()
                    app.settings.maskModelsAllowCellular = value
                }))
            }
        } header: {
            Text(L("On-device models"))
        } footer: {
            Text(verbatim: L("The eraser and the upscaler ship with the app. Generative Fill is large: it downloads by itself over Wi‑Fi the first time, and everything runs on your iPhone. The local brain is in Settings › Intelligence.")
                 + " " + L("The object selection and depth models download only when you ask, over Wi‑Fi unless cellular is allowed above; each file is checked before it is used."))
        }
    }

    private func localizedName(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("Neural eraser")
        case "realesrgan-x4": return L("Super resolution ×4")
        case "sd-generative-fill": return L("Generative Fill")
        case MaskModelCatalog.samTiny.id: return L("AI object selection (SAM 2.1)")
        case MaskModelCatalog.depthSmall.id: return L("AI depth (Depth Anything V2)")
        default: return model.displayName
        }
    }

    private func localizedSummary(_ model: ModelDescriptor) -> String {
        switch model.id {
        case "lama-inpainting": return L("LaMa network for clean object removal on complex backgrounds.")
        case "realesrgan-x4": return L("Real-ESRGAN upscaler for sharp enlargements.")
        case "sd-generative-fill": return L("Stable Diffusion: “replace the sky with a sunset”, “add a hat”.")
        case MaskModelCatalog.samTiny.id: return L("Segment Anything 2.1: a tap, a box or a brush stroke selects an object.")
        case MaskModelCatalog.depthSmall.id: return L("Depth Anything V2: near and far for depth-range masks.")
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

    /// What iOS measured in daily use (MetricKit), kept on the iPhone: launch, hangs,
    /// scroll hitches, peak memory. The newest day first.
    private var measuredSection: some View {
        Section {
            if measuredDays.isEmpty {
                Text(L("iOS reports these once a day, after a day of use.")).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
            } else {
                ForEach(measuredDays.reversed(), id: \.date) { day in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date, format: .dateTime.day().month().year()).font(PSFont.headline(14))
                        Text(verbatim: Self.summary(of: day)).font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }
        } header: {
            Text(L("Measured performance"))
        } footer: {
            Text(L("Launch time (median and 90th percentile), hangs, scroll hitches in milliseconds per second, and peak memory. These numbers never leave your iPhone."))
        }
        .task { measuredDays = await Task.detached(priority: .utility) { Diagnostics.shared.performanceLog().days }.value }
    }

    /// 'launch 310/520 ms · 2 hangs (p90 340 ms) · hitches 3.1 ms/s · 1 840 MB'.
    static func summary(of day: PerformanceDay) -> String {
        var parts: [String] = []
        if let p50 = day.launchP50, let p90 = day.launchP90 { parts.append("launch \(Int(p50.rounded()))/\(Int(p90.rounded())) ms") }
        if let count = day.hangCount {
            parts.append(count == 0 ? "0 hangs" : "\(count) hangs" + (day.hangP90.map { " (p90 \(Int($0.rounded())) ms)" } ?? ""))
        }
        if let ratio = day.hitchRatio { parts.append(String(format: "hitches %.1f ms/s", ratio)) }
        if let peak = day.peakMemoryMB { parts.append("\(Int(peak.rounded())) MB") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Réglages › Avancé › Expérimental: the W1 and W2 kill switches. Each new part of the app can
    /// be turned off here if it misbehaves; Default follows the build.
    private var experimentalSection: some View {
        Section {
            ForEach(FeatureFlag.allCases, id: \.self) { flag in
                let _ = flagsRevision
                Toggle(isOn: Binding(get: { FeatureFlags.isOn(flag) }, set: { value in
                    Haptics.tick()
                    FeatureFlags.set(flag, value == FeatureFlags.defaultValue(flag) ? nil : value)
                    flagsRevision += 1
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(of: flag)).font(PSFont.headline(15))
                        Text(L("Takes effect in the next editor you open.")).font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
                    }
                }
            }
        } header: {
            Text(L("Experimental"))
        }
    }

    static func title(of flag: FeatureFlag) -> String {
        switch flag {
        case .catalogOps: return L("New voice operations")
        case .retrievalCards: return L("Shorter Live prompt")
        case .displayLinkCanvas: return L("120 Hz canvas")
        case .proTone: return L("Curves, Levels and blend modes")
        case .studioWorkspace: return L("Studio workspace")
        case .psBackdrop: return L("New Home and backdrop")
        case .masks: return L("Masks")
        case .aiSelection: return L("AI selection")
        case .samModel: return L("Object selection model")
        case .depthModel: return L("Depth model")
        case .pixelPostconditions: return L("Pixel checks")
        case .fmDynamicSchema: return L("Apple Intelligence schema")
        case .commandPalette: return L("Command palette")
        case .metalOrb: return L("Metal orb")
        case .graphiteSurround: return L("Graphite surround")
        case .modelBroker: return L("Model broker")
        case .proLayers: return L("Pro layers")
        case .freeTransform: return L("Free transform")
        case .layersColumn: return L("Layers column")
        case .paramInspector: return L("Generated inspector rows")
        case .contentHashCache: return L("Content-hash cache")
        case .interactiveSnapshot: return L("Interactive snapshot")
        case .tiledRendering: return L("Tiled rendering")
        case .proExport: return L("Pro export formats")
        case .psdExport: return L("Layered PSD")
        case .layerOps: return L("LLM layer operations")
        case .outlineFill: return L("Outline then fill")
        case .recipes: return L("Recipes")
        case .kvEngine: return L("KV engine")
        case .persistedPrefix: return L("Persisted prefix")
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
