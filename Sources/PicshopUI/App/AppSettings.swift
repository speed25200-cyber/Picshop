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
    /// Settings › Performance: follow the thermal state, favour quality, or favour a cool phone.
    public var performancePreference: PerformanceGovernor.Preference { didSet { defaults.set(performancePreference.rawValue, forKey: "performancePreference") } }

    // MARK: Picshop Live

    /// Version of the Claude consent text the person accepted.
    public static let liveConsentCurrent = 1
    /// 0 never asked, negative declined, `liveConsentCurrent` accepted.
    public var liveConsentVersion: Int { didSet { defaults.set(liveConsentVersion, forKey: "liveConsentVersion") } }
    public var hasLiveConsent: Bool { liveConsentVersion == Self.liveConsentCurrent }
    public var liveUseClaude: Bool { didSet { defaults.set(liveUseClaude, forKey: "liveUseClaude") } }
    /// Effective only with consent.
    public var liveSendsImages: Bool { didSet { defaults.set(liveSendsImages, forKey: "liveSendsImages") } }
    public var liveAutoStart: Bool { didSet { defaults.set(liveAutoStart, forKey: "liveAutoStart") } }
    /// Off: on the loudspeaker only stop words, a tap, typing or a chip interrupt (safe mode).
    public var liveBargeIn: Bool { didSet { defaults.set(liveBargeIn, forKey: "liveBargeIn") } }
    public var liveSpeaks: Bool { didSet { defaults.set(liveSpeaks, forKey: "liveSpeaks") } }
    public var liveCaptions: Bool { didSet { defaults.set(liveCaptions, forKey: "liveCaptions") } }
    /// Voice identifiers; nil lets `VoiceSelector.best` choose.
    public var liveVoiceFR: String? { didSet { defaults.set(liveVoiceFR, forKey: "liveVoiceFR") } }
    public var liveVoiceEN: String? { didSet { defaults.set(liveVoiceEN, forKey: "liveVoiceEN") } }
    /// Speech rate multiplier, kept within `liveRateRange`.
    public var liveRate: Double {
        didSet {
            let clamped = Self.clampedLiveRate(liveRate)
            if clamped != liveRate { liveRate = clamped }
            defaults.set(clamped, forKey: "liveRate")
        }
    }
    public var liveFastLane: Bool { didSet { defaults.set(liveFastLane, forKey: "liveFastLane") } }
    public var liveHDBluetooth: Bool { didSet { defaults.set(liveHDBluetooth, forKey: "liveHDBluetooth") } }
    public var liveDebug: Bool { didSet { defaults.set(liveDebug, forKey: "liveDebug") } }
    /// Debug A/B: speak with `AVSpeechSynthesizer.speak` instead of the audio engine.
    public var liveSpeakerUsesSystem: Bool { didSet { defaults.set(liveSpeakerUsesSystem, forKey: "liveSpeakerUsesSystem") } }

    public static let liveRateRange: ClosedRange<Double> = 0.85...1.25

    static func clampedLiveRate(_ rate: Double) -> Double {
        rate.isFinite ? min(max(rate, liveRateRange.lowerBound), liveRateRange.upperBound) : 1
    }

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
        performancePreference = PerformanceGovernor.Preference(rawValue: defaults.string(forKey: "performancePreference") ?? "") ?? .automatic
        liveConsentVersion = defaults.integer(forKey: "liveConsentVersion")
        liveUseClaude = (defaults.object(forKey: "liveUseClaude") as? Bool) ?? true
        liveSendsImages = (defaults.object(forKey: "liveSendsImages") as? Bool) ?? true
        liveAutoStart = defaults.bool(forKey: "liveAutoStart")
        liveBargeIn = defaults.bool(forKey: "liveBargeIn")
        liveSpeaks = (defaults.object(forKey: "liveSpeaks") as? Bool) ?? true
        liveCaptions = (defaults.object(forKey: "liveCaptions") as? Bool) ?? true
        liveVoiceFR = defaults.string(forKey: "liveVoiceFR")
        liveVoiceEN = defaults.string(forKey: "liveVoiceEN")
        liveRate = Self.clampedLiveRate((defaults.object(forKey: "liveRate") as? Double) ?? 1)
        liveFastLane = (defaults.object(forKey: "liveFastLane") as? Bool) ?? true
        liveHDBluetooth = defaults.bool(forKey: "liveHDBluetooth")
        liveDebug = defaults.bool(forKey: "liveDebug")
        liveSpeakerUsesSystem = defaults.bool(forKey: "liveSpeakerUsesSystem")
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
