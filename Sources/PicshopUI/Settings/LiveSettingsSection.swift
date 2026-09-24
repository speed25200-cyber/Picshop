#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Settings › PicShop Live: which brain answers, how Live starts, and the
/// diagnostics. Everything runs on the iPhone.
struct LiveSettingsSection: View {
    let app: AppEnvironment

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            LiveEngineRow(app: app)
        } header: {
            Text(verbatim: "PicShop Live")
        } footer: {
            Text(L("Everything stays on the iPhone."))
        }

        Section {
            SettingsRow(systemName: "play.circle", tint: PSTheme.textPrimary) {
                Toggle(L("Start Live when an editor opens"), isOn: $settings.liveAutoStart)
            }
            SettingsRow(systemName: "bolt.fill", tint: PSTheme.textPrimary) {
                Toggle(L("Instant answers for simple commands"), isOn: $settings.liveFastLane)
            }
        }

        Section {
            SettingsRow(systemName: "stethoscope", tint: PSTheme.textPrimary) {
                Toggle(L("Live diagnostics"), isOn: $settings.liveDebug)
            }
            if settings.liveDebug {
                NavigationLink {
                    LiveDebugView()
                } label: {
                    Label(L("Open Live diagnostics"), systemImage: "waveform.path.ecg")
                }
            }
        } footer: {
            Text(L("Measures latency, echo and end-of-turn decisions while Live runs. The log holds no transcript."))
        }
    }
}

/// The first brain in Live's chain that can answer: the local model once it is
/// on the iPhone, then Apple Intelligence, then the built-in grammar. A leaf,
/// because the local brain's status changes while it downloads.
private struct LiveEngineRow: View {
    let app: AppEnvironment
    private let hub = LocalBrainHub.shared

    var body: some View {
        HStack(spacing: 12) {
            LiveOrb(size: 28, state: .off, meter: nil)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                Text(L("Answers on the iPhone, even in airplane mode.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        let status = hub.status
        switch status.phase {
        case .installed, .loading, .ready:
            if let model = status.model { return model.displayName }
        default:
            break
        }
        if app.availableEngines.contains(.appleIntelligence) { return "Apple Intelligence" }
        return L("Built-in grammar")
    }
}
#endif
