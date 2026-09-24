#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import Speech
import PicshopCore
import PicshopIntent
import PicshopSpeech

// The self-test's probes. Each returns a status with a reason the person can act on,
// and cleans up whatever it started (session, engine, VoiceController's settings).

/// What the self-test says out loud: in the reply language, never through L() (spoken
/// lines follow the conversation's language, as LiveLines does).
struct SelfTestLines {
    let language: NormalizedUtterance.Language

    var french: Bool { language == .french }
    /// The speaker's language code.
    var code: String { french ? "fr" : "en" }
    var voiceCheck: String { french ? "Test de la voix. Tu m'entends ?" : "Voice test. Can you hear me?" }
    var earPrompt: String { french ? "Dis : bonjour Picshop." : "Say: hello Picshop." }
    var duplexCheck: String { french ? "Test du son avec les écouteurs." : "Testing the sound on your headphones." }

    func summary(passed: Int, counted: Int) -> String {
        if french {
            let base = "Test terminé : \(passed) étape\(passed > 1 ? "s" : "") sur \(counted) réussie\(passed > 1 ? "s" : "")."
            return passed == counted ? base : base + " Les croix expliquent ce qui ne va pas."
        }
        let base = "Test finished: \(passed) of \(counted) steps passed."
        return passed == counted ? base : base + " The crosses explain what went wrong."
    }
}

/// The voice Live would speak with: the chosen or best installed voice, at the Live rate.
struct SelfTestVoice {
    let code: String
    let identifier: String?
    let name: String
    let rate: Float

    @MainActor
    init(settings: AppSettings, language: NormalizedUtterance.Language) {
        code = language == .french ? "fr-FR" : "en-US"
        let preferred = language == .french ? settings.liveVoiceFR : settings.liveVoiceEN
        let best = SystemVoices.best(for: code, preferredIdentifier: preferred)
        identifier = best?.identifier
        name = best?.name ?? "system"
        let multiplier = Float(min(max(settings.liveRate.isFinite ? settings.liveRate : 1, 0.85), 1.25))
        rate = min(max(AVSpeechUtteranceDefaultSpeechRate * multiplier, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }
}

@MainActor
enum SelfTestProbes {
    // MARK: 1. Permissions

    static func permissions() async -> LiveSelfTest.Status {
        if VoiceController.permissionsGranted { return .passed(L("Microphone and speech recognition allowed")) }
        // Prompts only what was never asked; a refusal is answered at once.
        if await VoiceController.requestPermissions() { return .passed(L("Microphone and speech recognition allowed")) }
        if AVAudioApplication.shared.recordPermission != .granted {
            return .failed(L("The microphone is not allowed: Settings › Picshop › Microphone."))
        }
        return .failed(L("Speech recognition is not allowed: Settings › Picshop › Speech Recognition."))
    }

    // MARK: 2. Speech model

    /// The locale SpeechAnalyzer resolves to, and whether its model is installed (asked for
    /// now if not, 12 s at most; the download goes on after that).
    static func speechModel(locale: Locale) async -> LiveSelfTest.Status {
        guard #available(iOS 26.0, *) else { return legacyRecognizer(locale: locale) }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return legacyRecognizer(locale: locale) }
        let id = resolved.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == id }) { return .passed("\(id) · SpeechAnalyzer") }
        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            if let request {
                let install = Task { try await request.downloadAndInstall() }
                try await LiveDeadline.run(12) { try await install.value }
            }
            return .passed("\(id) · SpeechAnalyzer · " + L("installed now"))
        } catch {
            return .failed("\(id) · " + L("The speech model is still downloading: test again in a minute."))
        }
    }

    /// A language SpeechAnalyzer does not know: SFSpeechRecognizer on the iPhone is the ear.
    private static func legacyRecognizer(locale: Locale) -> LiveSelfTest.Status {
        let id = locale.identifier(.bcp47)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return .failed("\(id) · " + L("No speech recognition for this language on this iPhone."))
        }
        return recognizer.supportsOnDeviceRecognition
            ? .passed("\(id) · SFSpeechRecognizer")
            : .failed("\(id) · " + L("Speech recognition for this language is not on the iPhone."))
    }

    // MARK: 3–4. The simple path's session

    /// Nil when the session is Live's simple one; otherwise the reason it is not.
    static func acquireSimpleSession() async -> String? {
        let arbiter = AudioSessionArbiter.shared
        do {
            try await LiveDeadline.run(6) { try await arbiter.acquire(.liveSimple) }
            return nil
        } catch {
            arbiter.release(.liveSimple)
            return L("The audio session did not start.")
        }
    }

    // MARK: 5. Duplex

    /// Headphones only: the echo-cancelling engine starts, microphone frames come, echo
    /// cancellation is on, the configuration settles, and a line plays through the engine
    /// at a real level (and is not reported played without being heard).
    static func duplex(settings: AppSettings, lines: SelfTestLines) async -> LiveSelfTest.Status {
        let route = LiveAudioEngine.currentRoute()
        guard route == .headphones || route == .bluetooth else { return .skipped(L("Connect headphones to test it.")) }
        let arbiter = AudioSessionArbiter.shared
        let hdBluetooth = settings.liveHDBluetooth
        do {
            try await LiveDeadline.run(6) { try await arbiter.acquire(.live, hdBluetooth: hdBluetooth) }
        } catch {
            arbiter.release(.live)
            return .failed(L("The audio session did not start."))
        }
        defer { arbiter.release(.live) }
        let engine = LiveAudioEngine()
        let events = DuplexProbeEvents()
        engine.onEvent = { event in
            switch event {
            case .rebuilt: events.rebuilds += 1
            case .failed(let reason): events.failure = reason
            case .interrupted, .routeChanged, .mediaServicesReset: break
            }
        }
        do {
            try await LiveDeadline.run(6) { try await engine.start() }
        } catch {
            engine.stop()
            return .failed(L("The echo-cancelling engine did not start.") + " (\(LiveSession.errorToken(error)))")
        }
        defer { engine.stop() }
        engine.setMicrophoneOpen(true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let quiet = engine.drainFeatures()

        // One line through the engine, as duplex Live speaks.
        let speaker = LiveSpeaker(engine: engine)
        speaker.rateMultiplier = settings.liveRate
        speaker.preferredVoices = ["fr": settings.liveVoiceFR, "en": settings.liveVoiceEN].compactMapValues { $0 }
        speaker.onSignal = { _, signal in
            switch signal {
            case .chunkStarted: events.voiceStarted = true
            case .drained: events.voiceDrained = true
            case .chunkQueued, .chunkFinished: break
            }
        }
        speaker.onFallback = { reason in events.voiceFallback = reason }
        let begun = ProcessInfo.processInfo.systemUptime
        speaker.enqueue(lines.duplexCheck, language: lines.code, turn: 1)
        var peakOutput: Float = -100
        var duringVoice: [AudioFrameFeatures] = []
        while ProcessInfo.processInfo.systemUptime - begun < 8, !events.voiceDrained {
            try? await Task.sleep(nanoseconds: 50_000_000)
            peakOutput = max(peakOutput, engine.outputLevelDB)
            duringVoice += engine.drainFeatures()
        }
        speaker.stop(fadeMs: 0)
        let frames = quiet.count + duringVoice.count

        if frames == 0 { return .failed(L("No sound from the microphone.")) }
        if !engine.echoCancellationActive { return .failed(L("Echo cancellation is not available on this route.")) }
        if events.failure != nil { return .failed(L("The audio engine failed.")) }
        if let fallback = events.voiceFallback { return .failed(L("The engine voice did not play:") + " \(fallback.prefix(60))") }
        if !events.voiceStarted || !events.voiceDrained { return .failed(L("The voice did not finish playing.")) }
        if events.rebuilds > 1 { return .failed(L("The audio configuration keeps changing.")) }
        if peakOutput < -50 { return .failed(L("The voice is too quiet on this route.")) }
        let quietLevel = quiet.map(\.rmsDB).sorted().dropFirst(quiet.count / 2).first ?? -100
        let echoLevel = duringVoice.map(\.rmsDB).max() ?? -100
        return .passed("\(frames) frames · AEC · \(Int(peakOutput)) dBFS · echo \(Int(echoLevel - quietLevel)) dB")
    }

    // MARK: 6. Brain

    /// The local model's own probe (it may load first: 20 s at most), and Apple Intelligence.
    static func brain() async -> LiveSelfTest.Status {
        let hub = LocalBrainHub.shared
        let probe: LocalBrainProbe
        do {
            probe = try await LiveDeadline.run(20) { await hub.probe() }
        } catch {
            return .failed(L("The local brain did not answer within 20 s."))
        }
        let apple = appleIntelligenceText(probe.appleIntelligence)
        if probe.passed { return .passed("\(probe.summary) · \(apple)") }
        // No local model, but Apple Intelligence answers: Live has a brain.
        if probe.appleIntelligence == "available" { return .passed("\(apple) · \(probe.summary)") }
        return .failed("\(probe.summary) · \(apple) · " + L("Live answers with voice commands only."))
    }

    static func appleIntelligenceText(_ availability: String) -> String {
        switch availability {
        case "available": return L("Apple Intelligence on")
        case "deviceNotEligible": return L("Apple Intelligence: not on this iPhone")
        case "appleIntelligenceNotEnabled": return L("Apple Intelligence is off in Settings")
        case "modelNotReady": return L("Apple Intelligence is still getting ready")
        default: return L("Apple Intelligence unavailable")
        }
    }
}

/// What the duplex probe's engine and speaker reported.
@MainActor
final class DuplexProbeEvents {
    var rebuilds = 0
    var failure: String?
    var voiceStarted = false
    var voiceDrained = false
    var voiceFallback: String?
}

/// speak() with its own synthesizer: when it started (2.5 s at most) and whether it finished.
@MainActor
final class SpeakProbe: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var startedAt: Double?
    private var finished = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String, voice: SelfTestVoice, finishWithin: Double) async -> (startMs: Int?, finished: Bool) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice.identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: voice.code)
        utterance.rate = voice.rate
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        let begun = ProcessInfo.processInfo.systemUptime
        synthesizer.speak(utterance)
        while startedAt == nil, ProcessInfo.processInfo.systemUptime - begun < SystemSpeechStart.limit {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let startedAt else {
            synthesizer.stopSpeaking(at: .immediate)
            return (nil, false)
        }
        while !finished, ProcessInfo.processInfo.systemUptime - startedAt < finishWithin {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !finished { synthesizer.stopSpeaking(at: .immediate) }
        return (Int((startedAt - begun) * 1000), finished)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self, self.startedAt == nil else { return }
            self.startedAt = now
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished = true }
    }
}

/// The limit the voice step holds speak() to, the same as Live's system voice.
enum SystemSpeechStart {
    static let limit = 2.5
}

/// One utterance on VoiceController, the ear of Live's simple path, with its settings
/// saved and put back.
@MainActor
enum EarProbe {
    private final class Heard {
        var final: String?
        var partial = ""
    }

    /// The final transcript (or the last partial), nil when nothing was recognized.
    static func listenOnce(voice: VoiceController, locale: Locale, timeout: Double) async -> String? {
        guard voice.canStart else { return nil }
        let mode = voice.mode
        let savedLocale = voice.locale
        let silence = voice.silenceTimeout
        let maximum = voice.maximumDuration
        let textSilence = voice.textSilenceTimeout
        let onFinal = voice.onFinalTranscript
        let onPartial = voice.onPartialTranscript
        defer {
            voice.mode = mode
            voice.locale = savedLocale
            voice.silenceTimeout = silence
            voice.maximumDuration = maximum
            voice.textSilenceTimeout = textSilence
            voice.onFinalTranscript = onFinal
            voice.onPartialTranscript = onPartial
        }
        let heard = Heard()
        voice.mode = .tapToTalk
        voice.locale = locale
        voice.silenceTimeout = SimpleLiveVoice.silenceTimeout
        voice.maximumDuration = timeout
        voice.textSilenceTimeout = SimpleLiveVoice.textSilenceTimeout
        voice.onFinalTranscript = { text in heard.final = text }
        voice.onPartialTranscript = { text in heard.partial = text }
        voice.start()
        let begun = ProcessInfo.processInfo.systemUptime
        var sawListening = false
        listening: while ProcessInfo.processInfo.systemUptime - begun < timeout + 3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if heard.final != nil { break }
            switch voice.state {
            case .listening:
                sawListening = true
            case .preparing, .finishing:
                break
            case .idle:
                if sawListening || ProcessInfo.processInfo.systemUptime - begun > 4 { break listening }
            case .unavailable:
                break listening
            }
        }
        if voice.isListening { voice.cancel() }
        if let final = heard.final, !final.isEmpty { return final }
        return heard.partial.isEmpty ? nil : heard.partial
    }
}
#endif
