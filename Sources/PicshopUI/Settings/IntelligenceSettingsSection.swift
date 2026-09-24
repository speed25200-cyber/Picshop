#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Settings › Intelligence: the local brain (the model this iPhone runs, where
/// it stands), Apple Intelligence, and whether Live gets ready when an editor
/// opens. Live's chain: local brain, then Apple Intelligence, then commands.
///
/// Phase 0 shell: the model card only reports the status. Download, quality,
/// storage and the speed test arrive with the local brain.
struct IntelligenceSettingsSection: View {
    let app: AppEnvironment

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            LocalBrainCard()
            AppleIntelligenceRow(app: app)
            SettingsRow(systemName: "bolt.horizontal.circle", tint: PSTheme.textPrimary) {
                Toggle(L("Prepare Live when an editor opens"), isOn: $settings.livePreparesOnOpen)
            }
        } header: {
            Text(L("Intelligence"))
        } footer: {
            Text(L("Local brain → Apple Intelligence → commands, all on the iPhone."))
        }
    }
}

/// The local model and where it stands. A leaf: only this row redraws while
/// the status changes (download progress).
private struct LocalBrainCard: View {
    private let hub = LocalBrainHub.shared

    var body: some View {
        let status = hub.status
        HStack(alignment: .top, spacing: 12) {
            SettingsRowIcon(systemName: "brain", tint: LocalBrainText.isReady(status.phase) ? PSTheme.success : PSTheme.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.model?.displayName ?? L("Local brain"))
                    .font(PSFont.headline(15))
                    .foregroundStyle(PSTheme.textPrimary)
                Text(LocalBrainText.phase(status.phase))
                    .font(PSFont.caption(12))
                    .foregroundStyle(PSTheme.textSecondary)
                if status.decision.reason != .recommended {
                    Text(LocalBrainText.reason(status.decision.reason))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

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

/// The words for the local brain's status and tier, shared by Settings and the
/// Live dock. LocalBrainHub reports enums; the text lives only here.
enum LocalBrainText {
    static func isReady(_ phase: LocalBrainStatus.Phase) -> Bool {
        switch phase {
        case .installed, .loading, .ready: return true
        default: return false
        }
    }

    static func phase(_ phase: LocalBrainStatus.Phase) -> String {
        switch phase {
        case .notInThisBuild: return L("Not in this build")
        case .unsupported: return L("Not available on this iPhone")
        case .notInstalled: return L("Not downloaded")
        case .waitingForWiFi: return L("Waiting for Wi‑Fi")
        case .downloading(let progress):
            return String(format: L("Downloading · %@"), min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0))))
        case .verifying: return L("Verifying…")
        case .installed: return L("Downloaded")
        case .loading: return L("Loading the brain…")
        case .ready: return L("Ready")
        case .failed(let message): return String(format: L("Failed: %@"), message)
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

    /// "3,06 Go" / "3.06 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
