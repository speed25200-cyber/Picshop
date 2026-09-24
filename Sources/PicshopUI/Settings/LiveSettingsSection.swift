#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Settings › PicShop Live: which brain answers, the Claude key, what Claude
/// may see, the on-device fallback, usage and the diagnostics.
struct LiveSettingsSection: View {
    let app: AppEnvironment
    private let services = LiveServices.shared

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            engineRow
            ClaudeKeyField(store: services.keyStore)
        } header: {
            Text(verbatim: "PicShop Live")
        } footer: {
            Text(ProBrainInstaller.shared != nil ? L("Claude → Apple Intelligence → Pro Brain → built-in grammar") : L("Claude → Apple Intelligence → built-in grammar"))
        }

        Section {
            SettingsRow(systemName: "sparkles", tint: PSTheme.voice) {
                Toggle(L("Use Claude"), isOn: $settings.liveUseClaude)
            }
            SettingsRow(systemName: "photo.badge.arrow.down", tint: PSTheme.textPrimary) {
                Toggle(L("Show the picture to Claude"), isOn: $settings.liveSendsImages)
            }
            .disabled(!settings.liveUseClaude)
        } footer: {
            Text(L("In Live mode with Claude, once you agree, the text of the conversation and, when this is on, a reduced copy (1024 px) of the picture on screen are sent to Anthropic with your own key — never the audio. Outside Live mode, nothing is sent."))
        }

        Section {
            SettingsRow(systemName: "play.circle", tint: PSTheme.textPrimary) {
                Toggle(L("Start Live when an editor opens"), isOn: $settings.liveAutoStart)
            }
            SettingsRow(systemName: "bolt.fill", tint: PSTheme.textPrimary) {
                Toggle(L("Instant answers for simple commands"), isOn: $settings.liveFastLane)
            }
            fallbackRow
        }

        usageSection

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
            Text(L("Measures latency, echo and end-of-turn decisions while Live runs. The log holds no transcript and no key."))
        }
    }

    // MARK: Engine

    /// Claude when the key, the switch and the consent are all there.
    private var usesClaude: Bool {
        services.keyStore.hasKey && app.settings.liveUseClaude && app.settings.hasLiveConsent
    }

    private var engineRow: some View {
        HStack(spacing: 12) {
            LiveOrb(size: 28, state: .off, meter: nil)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(engineName).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                Text(engineDetail).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var engineName: String {
        if usesClaude { return "Claude" }
        if app.availableEngines.contains(.appleIntelligence) { return "Apple Intelligence" }
        if app.availableEngines.contains(.proLocal) { return L("Pro Brain") }
        return L("Built-in grammar")
    }

    private var engineDetail: String {
        let settings = app.settings
        if usesClaude { return L("Claude Opus 5 with your key, while Live runs.") }
        if !services.keyStore.hasKey { return L("Add a Claude key for the most natural conversation.") }
        if !settings.liveUseClaude { return L("Claude is off: Live stays on the iPhone.") }
        if settings.liveConsentVersion < 0 { return L("You chose to stay on the iPhone. Turn Use Claude off and on to be asked again.") }
        return L("Claude asks for your consent the first time Live starts.")
    }

    /// What answers without a key or a network.
    private var fallbackRow: some View {
        let ready = app.availableEngines.contains(.appleIntelligence)
        return HStack(spacing: 12) {
            SettingsRowIcon(systemName: "iphone", tint: ready ? PSTheme.success : PSTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Without a key or a network")).foregroundStyle(PSTheme.textPrimary)
                Text(ready ? L("Apple Intelligence is ready") : (app.appleIntelligenceReason.map(LD) ?? L("The built-in grammar answers simple commands.")))
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Usage

    @ViewBuilder
    private var usageSection: some View {
        let usage = services.usage
        if usage.requests > 0 || services.keyStore.hasKey {
            Section {
                LabeledContent(L("Requests")) {
                    Text(verbatim: "\(usage.sessionRequests.formatted()) · \(usage.requests.formatted())")
                }
                LabeledContent(L("Tokens sent")) { Text(usage.inputTokens, format: .number) }
                LabeledContent(L("Tokens received")) { Text(usage.outputTokens, format: .number) }
                LabeledContent(L("Read from cache")) { Text(usage.cacheReadTokens, format: .number) }
                LabeledContent(L("Estimated cost, this session")) { Text(usage.sessionEstimatedUSD, format: .currency(code: "USD")) }
                LabeledContent(L("Estimated cost, in total")) { Text(usage.estimatedUSD, format: .currency(code: "USD")) }
                Button(L("Reset"), role: .destructive) {
                    Haptics.confirm()
                    services.resetUsage()
                }
                .disabled(usage == LiveUsageTotals())
            } header: {
                Text(L("Claude usage"))
            } footer: {
                Text(L("Requests: this session · in total. The cost is an estimate from public prices; your Anthropic console has the real bill."))
            }
            .monospacedDigit()
        }
    }
}
#endif
