#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopVideo
import PicshopSpeech

/// Preferences, calm and short: the on-device intelligence, PicShop Live, the
/// voice, general choices, then Advanced and what stays private.
public struct SettingsView: View {
    @Environment(\.picshop) private var app
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                if let app {
                    SettingsHeader()
                    IntelligenceSettingsSection(app: app)
                    LiveSettingsSection(app: app)
                    voiceSection(app)
                    generalSection(app)
                    Section {
                        NavigationLink {
                            AdvancedSettingsView()
                        } label: {
                            SettingsRow(systemName: "gearshape.2.fill", tint: PSTheme.textPrimary) {
                                Text(L("Advanced"))
                            }
                        }
                    } footer: {
                        Text(L("On-device models, performance, diagnostics and the build."))
                    }
                    privacySection
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .navigationTitle(L("Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Voice

    @ViewBuilder
    private func voiceSection(_ app: AppEnvironment) -> some View {
        @Bindable var settings = app.settings
        Section {
            NavigationLink {
                VoicePickerView()
            } label: {
                VoiceSummaryRow(settings: app.settings)
            }
            SettingsRow(systemName: "speaker.wave.2.fill", tint: PSTheme.voice) {
                Toggle(L("Spoken replies"), isOn: $settings.liveSpeaks)
            }
            SettingsRow(systemName: "hand.raised.fill", tint: PSTheme.textPrimary) {
                Toggle(isOn: $settings.liveBargeIn) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Let me interrupt"))
                        Text(L("Always on with headphones. On the loudspeaker, turn it on if PicShop doesn't cut itself off while it speaks."))
                            .font(PSFont.footnote())
                            .foregroundStyle(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsRow(systemName: "captions.bubble.fill", tint: PSTheme.textPrimary) {
                Toggle(L("Captions"), isOn: $settings.liveCaptions)
            }
            VoiceRateSlider(settings: app.settings)
            SettingsRow(systemName: "globe", tint: PSTheme.success) {
                Picker(L("Language"), selection: Binding(get: { app.settings.voiceLanguage }, set: { app.settings.voiceLanguage = $0; app.applyVoiceSettings() })) {
                    Text(L("Automatic")).tag("auto")
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "English").tag("en")
                }
            }
            SettingsRow(systemName: "airpods", tint: PSTheme.textPrimary) {
                Toggle(isOn: $settings.liveHDBluetooth) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("HD voice in AirPods"))
                        Text(L("The AirPods play the voice in high quality; PicShop then listens through the iPhone's own microphone."))
                            .font(PSFont.footnote())
                            .foregroundStyle(PSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsRow(systemName: "text.bubble.fill", tint: PSTheme.textPrimary) {
                Toggle(L("Read out replies to dictated commands"), isOn: $settings.speaksReplies)
            }
        } header: {
            Text(L("Voice"))
        }
    }

    // MARK: General

    @ViewBuilder
    private func generalSection(_ app: AppEnvironment) -> some View {
        Section(L("General")) {
            SettingsRow(systemName: "hand.tap.fill", tint: PSTheme.textPrimary) {
                Toggle(L("Haptics"), isOn: Binding(get: { app.settings.hapticsEnabled }, set: { app.settings.hapticsEnabled = $0 }))
            }
            SettingsRow(systemName: "photo.fill", tint: PSTheme.textPrimary) {
                Picker(L("Photo format"), selection: Binding(get: { app.settings.photoExportFormat }, set: { app.settings.photoExportFormat = $0 })) {
                    ForEach(ExportOptions.Format.allCases) { Text($0.displayName).tag($0) }
                }
            }
            SettingsRow(systemName: "film.fill", tint: PSTheme.textPrimary) {
                Picker(L("Video quality"), selection: Binding(get: { app.settings.videoExportQuality }, set: { app.settings.videoExportQuality = $0 })) {
                    ForEach(VideoExportOptions.Quality.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                SettingsRowIcon(systemName: "hand.raised.fill", tint: PSTheme.success)
                Text(L("Everything stays on the iPhone. Live listens, understands, looks at the picture and answers on the device — nothing is sent. PicShop has no server, no account and no tracking."))
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(L("Privacy"))
        }
    }
}

/// App identity at the top, like the Apple ID card in Settings: the tile,
/// the version, and where Live answers from: always the iPhone.
private struct SettingsHeader: View {
    var body: some View {
        Section {
            HStack(spacing: 14) {
                let shape = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background { HeroMesh().clipShape(shape) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "PicShop").font(.title2.weight(.bold)).foregroundStyle(PSTheme.textPrimary)
                    HStack(spacing: 6) {
                        Text(L("Version")).foregroundStyle(PSTheme.textTertiary)
                        Text(verbatim: "\(BuildInfo.version) (\(BuildInfo.buildNumber))")
                    }
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    Label(L("Live: on the iPhone"), systemImage: "iphone")
                        .font(PSFont.caption(12))
                        .foregroundStyle(PSTheme.success)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }
}

/// The voice row: Live's voice for each language, with its quality.
private struct VoiceSummaryRow: View {
    let settings: AppSettings
    @State private var french: VoiceCandidate?
    @State private var english: VoiceCandidate?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(systemName: "person.wave.2.fill", tint: PSTheme.voice)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Voices")).foregroundStyle(PSTheme.textPrimary)
                line("FR", french)
                line("EN", english)
            }
        }
        .task(id: "\(settings.liveVoiceFR ?? "")|\(settings.liveVoiceEN ?? "")") { refresh() }
        .task {
            for await _ in SystemVoices.voicesDidChange() { refresh() }
        }
    }

    private func refresh() {
        french = SystemVoices.best(for: "fr-FR", preferredIdentifier: settings.liveVoiceFR)
        english = SystemVoices.best(for: "en-US", preferredIdentifier: settings.liveVoiceEN)
    }

    private func line(_ code: String, _ voice: VoiceCandidate?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: code).font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
            Text(voice?.name ?? L("None installed")).font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
            if let voice { VoiceQualityBadge(quality: voice.quality) }
        }
    }
}

/// Live's speaking rate, 0.85 to 1.25; releasing the slider plays a sample.
private struct VoiceRateSlider: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Speed"))
                Spacer()
                Text(settings.liveRate, format: .number.precision(.fractionLength(2)))
                    .font(PSFont.mono(13))
                    .foregroundStyle(PSTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { settings.liveRate }, set: { settings.liveRate = $0 }), in: AppSettings.liveRateRange, step: 0.05) {
                Text(L("Speed"))
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill").foregroundStyle(PSTheme.textSecondary).accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "hare.fill").foregroundStyle(PSTheme.textSecondary).accessibilityHidden(true)
            } onEditingChanged: { editing in
                guard !editing else { return }
                let french = settings.voiceLocale.language.languageCode?.identifier == "fr"
                SystemVoices.playSample(language: french ? "fr-FR" : "en-US",
                                        voiceIdentifier: french ? settings.liveVoiceFR : settings.liveVoiceEN,
                                        rate: settings.liveRate)
            }
        }
        .padding(.vertical, 2)
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
                        Image(systemName: option.symbol).font(.system(size: 15, weight: .medium)).symbolRenderingMode(.hierarchical)
                        Text(option.title).font(PSFont.caption(11)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.selection)
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
    }
}

/// Squircle in front of a settings row. Neutral, so colour keeps its
/// meaning: `tint` shows only for success, warning and the voice; any
/// other tint draws white.
struct SettingsRowIcon: View {
    let systemName: String
    let tint: Color

    private var glyphColor: Color {
        [PSTheme.success, PSTheme.warning, PSTheme.voice].contains(tint) ? tint : PSTheme.textPrimary
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(glyphColor)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: PSRadius.tiny + 1, style: .continuous).fill(PSTheme.fill))
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
#endif
