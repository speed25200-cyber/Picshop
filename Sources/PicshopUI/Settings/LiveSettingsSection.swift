#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Settings › PicShop Live: which brain answers, how Live starts, talking over
/// it with headphones, and Diagnostic Live with the voice self-test. The voice
/// itself (which one, its speed, captions) is the Voice section below.
/// Everything runs on the iPhone.
struct LiveSettingsSection: View {
    let app: AppEnvironment

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            LiveEngineRow(app: app)
            SettingsRow(systemName: "play.circle", tint: PSTheme.textPrimary) {
                Toggle(L("Start Live when an editor opens"), isOn: $settings.liveAutoStart)
            }
            SettingsRow(systemName: "bolt.fill", tint: PSTheme.textPrimary) {
                Toggle(isOn: $settings.liveFastLane) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Instant answers for simple commands"))
                        Text(L("“Plus chaud”, “annule”: done at once by the built-in grammar, without waiting for the brain."))
                            .font(PSFont.footnote())
                            .foregroundStyle(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LiveDuplexRow(settings: app.settings)
        } header: {
            Text(verbatim: "PicShop Live")
        } footer: {
            Text(L("On the loudspeaker, interrupt PicShop with a tap on the orb, by typing, or by saying “stop”. Everything stays on the iPhone."))
        }

        Section {
            NavigationLink {
                LiveDebugView()
            } label: {
                LiveDiagnosticLabel()
            }
            SettingsRow(systemName: "stethoscope", tint: PSTheme.textPrimary) {
                Toggle(L("Record Live measurements"), isOn: $settings.liveDebug)
            }
        } footer: {
            Text(L("The voice test checks the microphone, the speech model, the voice, the ear, headphones and the brain, and says what failed. Measurements record latency, echo and end-of-turn decisions while Live runs; the log holds no transcript."))
        }
    }
}

/// The first brain in Live's chain that can answer: the local model once it is
/// on the iPhone, then Apple Intelligence, then the built-in commands. A leaf,
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
                Text(detail).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        let status = hub.status
        if LocalBrainText.isOnDisk(status.phase), let model = status.model {
            return String(format: L("Local assistant · %@"), model.displayName)
        }
        if app.availableEngines.contains(.appleIntelligence) { return "Apple Intelligence" }
        return L("Built-in commands")
    }

    private var detail: String {
        let status = hub.status
        if LocalBrainText.isOnDisk(status.phase) || app.availableEngines.contains(.appleIntelligence) {
            return L("Answers on the iPhone, even in airplane mode.")
        }
        switch status.phase {
        case .unsupported, .notInThisBuild:
            // Honest: without the local brain and Apple Intelligence, Live understands commands only.
            return L("Understands editing commands, on the iPhone. Turn on Apple Intelligence for a real conversation.")
        default:
            return L("Understands editing commands until the local brain is downloaded (Settings › Intelligence).")
        }
    }
}

/// Conversation duplex (écouteurs): with headphones, talk over PicShop to
/// interrupt it (the echo-cancelling path). Only after the voice test's
/// headphones step has passed; the person may turn it off at any time.
private struct LiveDuplexRow: View {
    let settings: AppSettings
    private let services = LiveServices.shared

    var body: some View {
        let passed = services.selfTestDuplexPassed
        let allowed = settings.liveDuplexAllowed
        SettingsRow(systemName: "headphones", tint: PSTheme.textPrimary) {
            Toggle(isOn: Binding(get: { settings.liveDuplexAllowed }, set: { settings.liveDuplexAllowed = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Duplex conversation (headphones)"))
                    Text(passed || allowed
                         ? L("With headphones, talk over PicShop to interrupt it.")
                         : L("Run the voice test in Diagnostic Live with headphones on: this turns on once it passes."))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Turning it off is always possible; on, only once the test passed.
            .disabled(!(passed || allowed))
        }
    }
}

/// Diagnostic Live, with the last voice test's result. A leaf: the summary
/// changes when a test finishes.
private struct LiveDiagnosticLabel: View {
    private let services = LiveServices.shared

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(systemName: "waveform.path.ecg", tint: PSTheme.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Diagnostic Live"))
                if let summary = services.selfTestSummary {
                    Text(String(format: L("Last voice test: %@"), summary))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                } else {
                    Text(L("Test the voice, the ear and the brain"))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
