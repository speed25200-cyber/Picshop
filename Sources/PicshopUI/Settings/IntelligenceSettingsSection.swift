#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Settings › Intelligence: the local brain (the model this iPhone runs, its
/// tier, its download, its storage and its speed), Apple Intelligence, and
/// whether Live gets ready when an editor opens. Live's chain: local brain,
/// then Apple Intelligence, then commands, all on the iPhone.
///
/// The section's body reads only settings; the rows that follow the local
/// brain's status (download progress changes often) are leaves.
struct IntelligenceSettingsSection: View {
    let app: AppEnvironment

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            LocalBrainRows(app: app)
            AppleIntelligenceRow(app: app)
            SettingsRow(systemName: "bolt.horizontal.circle", tint: PSTheme.textPrimary) {
                Toggle(isOn: $settings.livePreparesOnOpen) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Prepare Live when an editor opens"))
                        Text(L("Loads the local brain as the editor opens, so the first answer doesn't wait."))
                            .font(PSFont.footnote())
                            .foregroundStyle(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text(L("Intelligence"))
        } footer: {
            Text(L("Local brain → Apple Intelligence → commands, all on the iPhone."))
        }
    }
}

// MARK: - Local brain

/// The local brain's rows: the model card, what can be done with it, the
/// quality, the storage it takes and the speed test. A leaf that reads
/// `LocalBrainHub.status`, so download progress redraws only these rows.
private struct LocalBrainRows: View {
    let app: AppEnvironment
    private let hub = LocalBrainHub.shared

    var body: some View {
        let status = hub.status
        LocalBrainCard(status: status)
        LocalBrainActionsRow(app: app, status: status)
        if LocalBrainText.offersQuality(status) {
            LocalBrainQualityRow(app: app, status: status)
        }
        if status.bytesOnDisk > 0 {
            LabeledContent {
                Text(LocalBrainText.size(status.bytesOnDisk))
                    .font(PSFont.mono(13))
                    .foregroundStyle(PSTheme.textSecondary)
            } label: {
                HStack(spacing: 12) {
                    SettingsRowIcon(systemName: "internaldrive", tint: PSTheme.textPrimary)
                    Text(L("Storage used"))
                }
            }
        }
        if LocalBrainText.isOnDisk(status.phase) {
            LocalBrainSpeedRow(status: status)
        }
    }
}

/// Name, tier, status and why this model; the progress while it downloads.
private struct LocalBrainCard: View {
    let status: LocalBrainStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsRowIcon(systemName: "brain", tint: LocalBrainText.isReady(status.phase) ? PSTheme.success : PSTheme.textPrimary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.model?.displayName ?? L("Local brain"))
                        .font(PSFont.headline(15))
                        .foregroundStyle(PSTheme.textPrimary)
                    if let tier = LocalBrainText.tierName(status.decision.tier) {
                        Text(tier)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PSTheme.textSecondary)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().strokeBorder(PSTheme.textQuaternary, lineWidth: 1))
                    }
                }
                Text(LocalBrainText.phase(status.phase))
                    .font(PSFont.caption(12).monospacedDigit())
                    .foregroundStyle(LocalBrainText.phaseTint(status.phase))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                if case .downloading(let progress) = status.phase {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(PSTheme.textPrimary)
                        .padding(.vertical, 2)
                }
                if status.decision.reason != .recommended {
                    Text(LocalBrainText.reason(status.decision.reason))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.model != nil, status.downloadBytes > 0, !LocalBrainText.isOnDisk(status.phase) {
                    Text(String(format: L("Download size: %@"), LocalBrainText.size(status.downloadBytes)))
                        .font(PSFont.caption(12))
                        .foregroundStyle(PSTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Télécharger (Wi‑Fi), Autoriser le cellulaire, Annuler, Supprimer: what the
/// status allows. Cellular and Supprimer each ask first.
private struct LocalBrainActionsRow: View {
    let app: AppEnvironment
    let status: LocalBrainStatus
    private let hub = LocalBrainHub.shared
    @State private var confirmsCellular = false
    @State private var confirmsDelete = false
    @State private var isDeleting = false

    var body: some View {
        if status.model != nil, hasActions {
            HStack(spacing: 8) {
                switch status.phase {
                case .notInstalled, .failed:
                    button(status.phase == .notInstalled ? L("Download (Wi‑Fi)") : L("Try again (Wi‑Fi)"), systemImage: "wifi", prominent: true) {
                        hub.download(allowCellular: false)
                    }
                    button(L("Allow cellular"), systemImage: "antenna.radiowaves.left.and.right") { confirmsCellular = true }
                case .waitingForWiFi:
                    button(L("Allow cellular"), systemImage: "antenna.radiowaves.left.and.right", prominent: true) { confirmsCellular = true }
                    button(L("Cancel"), systemImage: "xmark") { cancel() }
                case .downloading, .verifying:
                    button(L("Cancel"), systemImage: "xmark") { cancel() }
                case .installed, .loading, .ready:
                    button(isDeleting ? L("Deleting…") : L("Delete"), systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(isDeleting)
                case .unsupported, .notInThisBuild:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .localBrainCellularConfirmation(isPresented: $confirmsCellular, status: status) {
                app.settings.localModelAllowsCellular = true
                hub.download(allowCellular: true)
            }
            .confirmationDialog(L("Delete the local brain?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(String(format: L("Delete %@"), LocalBrainText.size(status.bytesOnDisk)), role: .destructive) { delete() }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("Live then answers with Apple Intelligence or the commands. You can download it again here."))
            }
        }
    }

    private var hasActions: Bool {
        switch status.phase {
        case .unsupported, .notInThisBuild: return false
        default: return true
        }
    }

    private func cancel() {
        Haptics.tap()
        hub.cancelDownload()
        app.settings.localModelAllowsCellular = false
    }

    private func delete() {
        Haptics.confirm()
        isDeleting = true
        Task {
            await hub.delete()
            app.settings.localModelAllowsCellular = false
            // Deleted on purpose: the editors don't offer it again for a week (Settings still does).
            LocalBrainPillLook.snoozeOffer()
            isDeleting = false
        }
    }

    /// Separate buttons in one Form row: each with an explicit style, so a tap
    /// runs only its own action.
    @ViewBuilder
    private func button(_ title: String, systemImage: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        let label = Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        if prominent {
            Button(role: role, action: action) { label.foregroundStyle(PSTheme.onPrimary) }
                .buttonStyle(.glassProminent)
                .tint(PSTheme.primary)
                .controlSize(.small)
        } else {
            Button(role: role, action: action) { label.foregroundStyle(role == .destructive ? PSTheme.danger : PSTheme.textPrimary) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

/// Qualité: Auto (what this iPhone's tier says), Max (4B) or Rapide (2B),
/// within the memory limits. A choice that needs the other model says so.
private struct LocalBrainQualityRow: View {
    let app: AppEnvironment
    let status: LocalBrainStatus
    private let hub = LocalBrainHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SettingsRowIcon(systemName: "dial.medium", tint: PSTheme.textPrimary)
                Text(L("Quality"))
            }
            Picker(L("Quality"), selection: Binding(get: { app.settings.localModelQuality }, set: { quality in
                guard quality != app.settings.localModelQuality else { return }
                Haptics.tick()
                Task { await hub.setQuality(quality) }
            })) {
                ForEach(LocalModelQuality.allCases, id: \.self) { quality in
                    Text(LocalBrainText.qualityName(quality)).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // One model at a time: no switching while one downloads or loads.
            .disabled(isBusy)
            Text(explanation)
                .font(PSFont.footnote())
                .foregroundStyle(PSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var isBusy: Bool {
        switch status.phase {
        case .waitingForWiFi, .downloading, .verifying, .loading: return true
        default: return false
        }
    }

    private var explanation: String {
        if isBusy { return L("Quality can change once the download or the loading is over.") }
        // The chosen quality needs a model that isn't here yet: it replaces the one on the iPhone.
        if let model = status.model, status.bytesOnDisk > 0, !LocalBrainText.isOnDisk(status.phase) {
            return String(format: L("%@ (%@) replaces the model on the iPhone once downloaded."), model.displayName, LocalBrainText.size(status.downloadBytes))
        }
        switch app.settings.localModelQuality {
        case .auto: return L("Auto picks Max or Fast from this iPhone's chip, memory and temperature.")
        case .max: return L("Max: Qwen3.5 4B, the most natural answers. Falls back to Fast when memory runs short.")
        case .fast: return L("Fast: Qwen3.5 2B, quicker and lighter on memory and battery.")
        }
    }
}

/// Tester la vitesse: tokens per second and the time to the first answer.
private struct LocalBrainSpeedRow: View {
    let status: LocalBrainStatus
    private let hub = LocalBrainHub.shared
    @State private var isTesting = false
    @State private var failed = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(systemName: "speedometer", tint: PSTheme.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Speed test"))
                Text(summary)
                    .font(PSFont.caption(12).monospacedDigit())
                    .foregroundStyle(failed ? PSTheme.warning : PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isTesting {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Test")) { test() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        if isTesting { return L("Loading the model and timing an answer…") }
        if failed { return L("The test couldn't run: the model didn't load. Close other apps, then try again.") }
        guard let speed = status.speed else { return L("Not measured yet") }
        return String(format: L("%d tok/s · first answer in %d ms"), Int(speed.tokensPerSecond.rounded()), speed.firstTokenMs)
    }

    private func test() {
        Haptics.tap()
        failed = false
        isTesting = true
        Task {
            let speed = await hub.runSpeedTest()
            isTesting = false
            failed = speed == nil
            if speed != nil { Haptics.success() } else { Haptics.warning() }
        }
    }
}

// MARK: - Apple Intelligence

/// Apple's on-device model, the second brain in Live's chain.
private struct AppleIntelligenceRow: View {
    let app: AppEnvironment

    var body: some View {
        let ready = app.availableEngines.contains(.appleIntelligence)
        HStack(spacing: 12) {
            SettingsRowIcon(systemName: "apple.intelligence", tint: ready ? PSTheme.success : PSTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Apple Intelligence").foregroundStyle(PSTheme.textPrimary)
                Text(ready ? L("Apple Intelligence is ready") : (app.appleIntelligenceReason.map(LD) ?? L("The built-in grammar answers simple commands.")))
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Words

/// The words for the local brain's status, tier and quality, shared by
/// Settings, the brain pill, the offer sheet and onboarding. LocalBrainHub
/// reports enums; the text lives only here.
enum LocalBrainText {
    /// The weights are on the iPhone (loaded or not).
    static func isReady(_ phase: LocalBrainStatus.Phase) -> Bool {
        isOnDisk(phase)
    }

    static func isOnDisk(_ phase: LocalBrainStatus.Phase) -> Bool {
        switch phase {
        case .installed, .loading, .ready: return true
        default: return false
        }
    }

    /// Not here yet, and the iPhone could get it: the pill and the sheet offer it.
    static func isOffered(_ phase: LocalBrainStatus.Phase) -> Bool {
        switch phase {
        case .notInstalled, .waitingForWiFi, .downloading, .verifying, .failed: return true
        default: return false
        }
    }

    /// The Qualité picker makes sense only on an iPhone with a tier.
    static func offersQuality(_ status: LocalBrainStatus) -> Bool {
        guard status.model != nil else { return false }
        switch status.phase {
        case .unsupported, .notInThisBuild: return false
        default: return true
        }
    }

    static func phase(_ phase: LocalBrainStatus.Phase) -> String {
        switch phase {
        case .notInThisBuild: return L("Not in this build")
        case .unsupported: return L("Not available on this iPhone")
        case .notInstalled: return L("Not downloaded")
        case .waitingForWiFi: return L("Waiting for Wi‑Fi")
        case .downloading(let progress): return String(format: L("Downloading · %@"), percent(progress))
        case .verifying: return L("Verifying…")
        case .installed: return L("Downloaded · loads when Live needs it")
        case .loading: return L("Loading the brain…")
        case .ready: return L("Ready · on the iPhone")
        case .failed(let message): return String(format: L("Failed: %@"), message)
        }
    }

    static func phaseTint(_ phase: LocalBrainStatus.Phase) -> Color {
        switch phase {
        case .ready: return PSTheme.success
        case .failed: return PSTheme.warning
        default: return PSTheme.textSecondary
        }
    }

    static func reason(_ reason: LocalTierReason) -> String {
        switch reason {
        case .recommended: return L("Recommended for this iPhone")
        case .olderChip: return L("The lighter model suits this chip.")
        case .notEnoughMemory: return L("This iPhone doesn't have enough memory for the local brain; Live uses Apple Intelligence or the commands.")
        case .lowPowerMode: return L("The lighter model, while Low Power Mode is on.")
        case .hot: return L("The lighter model, while the iPhone is hot.")
        case .userChoseFast: return L("You chose Fast.")
        case .userChoseMax: return L("You chose Max.")
        case .memoryKillLastTime: return L("The lighter model: last time, the iPhone ran out of memory.")
        case .slowMeasured: return L("The lighter model: the speed test was slow.")
        case .simulator: return L("The local brain doesn't run in the Simulator.")
        case .notInThisBuild: return L("This build has no local brain; Live uses Apple Intelligence or the commands.")
        }
    }

    static func tierName(_ tier: LocalModelTier) -> String? {
        switch tier {
        case .max: return L("Max")
        case .fast: return L("Fast")
        case .unsupported: return nil
        }
    }

    static func qualityName(_ quality: LocalModelQuality) -> String {
        switch quality {
        case .auto: return L("Auto")
        case .max: return L("Max")
        case .fast: return L("Fast")
        }
    }

    /// "42 %" / "42%".
    static func percent(_ progress: Double) -> String {
        min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }

    /// "3,06 Go" / "3.06 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
