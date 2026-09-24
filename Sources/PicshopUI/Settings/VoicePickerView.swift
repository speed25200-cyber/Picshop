#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopIntent
import PicshopSpeech

/// Where to download a better system voice. One pair of strings, so the path
/// can be corrected in one place once checked against iOS 26's Settings.
enum VoiceDownloadHint {
    static var title: String { L("A more natural voice") }
    static var path: String { L("Download a Premium voice: Settings › Accessibility › Spoken Content › Voices › French.") }

    /// The path for one language's voices: French, else English.
    static func path(forLanguage language: String) -> String {
        language.lowercased().hasPrefix("fr") ? path : L("Download a Premium voice: Settings › Accessibility › Spoken Content › Voices › English.")
    }
}

/// Settings › Voix: Live's voice for French and for English, best first,
/// each with a sample to hear. Apps cannot download voices, so a language
/// without a Premium voice shows where iOS keeps them.
struct VoicePickerView: View {
    @Environment(\.picshop) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var voices: [VoiceCandidate] = []
    /// The voice whose sample is playing.
    @State private var playing: String?

    struct LanguageGroup: Identifiable {
        let language: String
        let title: String
        var id: String { language }
    }

    private let groups = [LanguageGroup(language: "fr-FR", title: "Français"), LanguageGroup(language: "en-US", title: "English")]

    var body: some View {
        List {
            if let app {
                ForEach(groups) { group in
                    section(group, settings: app.settings)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackground().ignoresSafeArea())
        .navigationTitle(L("Voices"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refresh()
            for await _ in SystemVoices.voicesDidChange() { refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onDisappear {
            SystemVoices.stopSample()
            playing = nil
        }
        .task(id: playing) {
            // The sample lasts a few seconds; the button returns to Play after it.
            guard let current = playing else { return }
            try? await Task.sleep(for: .seconds(4.5))
            if playing == current { playing = nil }
        }
        .preferredColorScheme(.dark)
    }

    private func refresh() {
        let all = SystemVoices.all()
        if all != voices { voices = all }
    }

    @ViewBuilder
    private func section(_ group: LanguageGroup, settings: AppSettings) -> some View {
        let sorted = VoiceSelector.sorted(voices, language: group.language)
        let chosen = identifier(for: group.language, in: settings)
        let effective = VoiceSelector.best(for: group.language, among: voices, preferredIdentifier: chosen)
        Section {
            if !sorted.contains(where: { $0.quality == .premium }) {
                hint(language: group.language)
            }
            automaticRow(group.language, best: VoiceSelector.best(for: group.language, among: voices), isSelected: chosen == nil, settings: settings)
            ForEach(sorted) { voice in
                row(voice, isSelected: chosen != nil && effective?.identifier == voice.identifier, settings: settings)
            }
            if sorted.isEmpty {
                Text(L("No voice installed for this language."))
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
            }
        } header: {
            Text(verbatim: group.title)
        }
    }

    // MARK: Rows

    private func automaticRow(_ language: String, best: VoiceCandidate?, isSelected: Bool, settings: AppSettings) -> some View {
        Button {
            Haptics.tick()
            setIdentifier(nil, for: language, in: settings)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Automatic")).foregroundStyle(PSTheme.textPrimary)
                    Text(best.map { String(format: L("The best installed voice: %@"), $0.name) } ?? L("The best installed voice"))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                }
                Spacer(minLength: 0)
                checkmark(isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func row(_ voice: VoiceCandidate, isSelected: Bool, settings: AppSettings) -> some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tick()
                setIdentifier(voice.identifier, for: voice.language, in: settings)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).font(.body).foregroundStyle(PSTheme.textPrimary)
                        Text(region(of: voice)).font(.footnote).foregroundStyle(PSTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    VoiceQualityBadge(quality: voice.quality)
                    checkmark(isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            playButton(voice, rate: settings.liveRate)
        }
    }

    private func playButton(_ voice: VoiceCandidate, rate: Double) -> some View {
        let isPlaying = playing == voice.identifier
        return Button {
            if isPlaying {
                SystemVoices.stopSample()
                playing = nil
            } else {
                SystemVoices.playSample(language: voice.language, voiceIdentifier: voice.identifier, rate: rate)
                playing = voice.identifier
            }
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PSTheme.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(PSTheme.fill))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isPlaying ? L("Stop") : String(format: L("Listen to %@"), voice.name))
    }

    private func checkmark(_ isSelected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PSTheme.textPrimary)
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// No Premium voice for this language: where iOS keeps them.
    private func hint(language: String) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Label(VoiceDownloadHint.title, systemImage: "waveform.badge.plus")
                .font(PSFont.headline(15))
                .foregroundStyle(PSTheme.textPrimary)
            Text(VoiceDownloadHint.path(forLanguage: language))
                .font(PSFont.footnote())
                .foregroundStyle(PSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(PSSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .psCard(cornerRadius: PSRadius.card, shadow: false)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
    }

    // MARK: Settings

    private func identifier(for language: String, in settings: AppSettings) -> String? {
        let id = language.lowercased().hasPrefix("fr") ? settings.liveVoiceFR : settings.liveVoiceEN
        // A chosen voice that was deleted falls back to Automatic.
        guard let id, voices.contains(where: { $0.identifier == id }) else { return nil }
        return id
    }

    private func setIdentifier(_ identifier: String?, for language: String, in settings: AppSettings) {
        if language.lowercased().hasPrefix("fr") {
            settings.liveVoiceFR = identifier
        } else {
            settings.liveVoiceEN = identifier
        }
    }

    private func region(of voice: VoiceCandidate) -> String {
        let parts = voice.language.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard parts.count >= 2, let name = Locale.current.localizedString(forRegionCode: String(parts[parts.count - 1])) else { return voice.language }
        return name
    }
}

/// Premium in the spectrum, Enhanced in white, Standard in grey.
struct VoiceQualityBadge: View {
    let quality: VoiceCandidate.Quality

    var body: some View {
        let title: String
        switch quality {
        case .premium: title = L("Premium")
        case .enhanced: title = L("Enhanced")
        case .standard: title = L("Standard")
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .modifier(VoiceQualityStyle(quality: quality))
            .accessibilityLabel(title)
    }
}

private struct VoiceQualityStyle: ViewModifier {
    let quality: VoiceCandidate.Quality

    @ViewBuilder
    func body(content: Content) -> some View {
        switch quality {
        case .premium:
            content
                .foregroundStyle(PSTheme.voiceGradient)
                .background(Capsule().strokeBorder(PSTheme.voiceGradient, lineWidth: 1))
        case .enhanced:
            content
                .foregroundStyle(PSTheme.onPrimary)
                .background(Capsule().fill(PSTheme.primary))
        case .standard:
            content
                .foregroundStyle(PSTheme.textTertiary)
                .background(Capsule().strokeBorder(PSTheme.textQuaternary, lineWidth: 1))
        }
    }
}
#endif
