#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation
import PicshopCore
import PicshopSpeech
import PicshopImaging
import PicshopVideo

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
public final class AppSettings {
    private let defaults = UserDefaults.standard

    public var voiceMode: VoiceController.Mode { didSet { defaults.set(voiceMode.rawValue, forKey: "voiceMode") } }
    /// "auto", "fr" or "en".
    public var voiceLanguage: String { didSet { defaults.set(voiceLanguage, forKey: "voiceLanguage") } }
    public var speaksReplies: Bool { didSet { defaults.set(speaksReplies, forKey: "speaksReplies"); VoiceFeedback.shared.isEnabled = speaksReplies } }
    public var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "haptics"); Haptics.isEnabled = hapticsEnabled } }
    public var photoExportFormat: ExportOptions.Format { didSet { defaults.set(photoExportFormat.rawValue, forKey: "photoFormat") } }
    public var videoExportQuality: VideoExportOptions.Quality { didSet { defaults.set(videoExportQuality.rawValue, forKey: "videoQuality") } }
    public var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarded") } }
    /// Large models (Generative Fill, Pro Brain) download by themselves over Wi‑Fi.
    public var autoInstallsModels: Bool { didSet { defaults.set(autoInstallsModels, forKey: "autoInstallsModels") } }
    public var showsVoiceTranscript: Bool { didSet { defaults.set(showsVoiceTranscript, forKey: "showsTranscript") } }

    public init() {
        voiceMode = VoiceController.Mode(rawValue: defaults.string(forKey: "voiceMode") ?? "") ?? .tapToTalk
        voiceLanguage = defaults.string(forKey: "voiceLanguage") ?? "auto"
        speaksReplies = (defaults.object(forKey: "speaksReplies") as? Bool) ?? false
        hapticsEnabled = (defaults.object(forKey: "haptics") as? Bool) ?? true
        photoExportFormat = ExportOptions.Format(rawValue: defaults.string(forKey: "photoFormat") ?? "") ?? .heic
        videoExportQuality = VideoExportOptions.Quality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .high
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
        autoInstallsModels = (defaults.object(forKey: "autoInstallsModels") as? Bool) ?? true
        showsVoiceTranscript = (defaults.object(forKey: "showsTranscript") as? Bool) ?? true
        VoiceFeedback.shared.isEnabled = speaksReplies
        Haptics.isEnabled = hapticsEnabled
    }

    /// Models the user removed on purpose are not re-downloaded automatically.
    public func setAutoInstallSkipped(_ skipped: Bool, for modelID: String) {
        defaults.set(skipped, forKey: "skipAutoInstall.\(modelID)")
    }

    public func isAutoInstallSkipped(_ modelID: String) -> Bool {
        defaults.bool(forKey: "skipAutoInstall.\(modelID)")
    }

    /// Locale used for speech recognition.
    public var voiceLocale: Locale {
        switch voiceLanguage {
        case "fr": return Locale(identifier: "fr-FR")
        case "en": return Locale(identifier: "en-US")
        default:
            let current = Locale.current
            if current.language.languageCode?.identifier == "fr" { return Locale(identifier: "fr-FR") }
            return current.language.languageCode?.identifier == "en" ? current : Locale(identifier: "en-US")
        }
    }

    /// Two-letter hint for the intent parser, nil for auto-detect.
    public var languageHint: String? {
        voiceLanguage == "auto" ? nil : voiceLanguage
    }
}
#endif
