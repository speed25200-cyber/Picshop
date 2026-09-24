#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Diagnostic Live › Tester le vocal: six checks, each with ✓/✗ and a reason —
/// permissions, the speech model, the voice, the ear, the duplex engine
/// (headphones only) and the brain. The run writes `liveDuplexAllowed` from the
/// duplex step, keeps its summary in LiveServices and says it out loud.
///
/// The probes themselves are in LiveSelfTest+Probes.swift. Every step has its own
/// time limit (12 s for the audio steps, plus the time the person takes to answer
/// Oui / Non; 20 s for the brain, which may load its weights first).
@MainActor
@Observable
public final class LiveSelfTest {
    enum Status: Equatable {
        case pending, running, passed(String), failed(String), skipped(String)

        var isPassed: Bool {
            if case .passed = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }

        /// The reason shown under the step.
        var reason: String? {
            switch self {
            case .pending, .running: return nil
            case .passed(let text), .failed(let text), .skipped(let text): return text.isEmpty ? nil : text
            }
        }

        /// For the log: never the reason, which may quote what the person said.
        var token: String {
            switch self {
            case .pending: return "pending"
            case .running: return "running"
            case .passed: return "passed"
            case .failed: return "failed"
            case .skipped: return "skipped"
            }
        }
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var status: Status
    }

    /// perm, model, voice, ear, duplex, brain.
    private(set) var steps: [Step]
    private(set) var isRunning = false
    /// The voice step waits for Oui / Non.
    private(set) var asksHeard = false
    /// What the person should do now ("Say “bonjour Picshop”"), shown under the steps.
    private(set) var instruction: String?
    /// Why the last tap did not start a test (Live or dictation holds the audio).
    private(set) var refusal: String?
    @ObservationIgnored private var heard: CheckedContinuation<Bool?, Never>?

    init() {
        steps = Self.initialSteps()
    }

    func answerHeard(_ yes: Bool) {
        guard let pending = heard else { return }
        heard = nil
        asksHeard = false
        pending.resume(returning: yes)
    }

    /// Refused while Live or push-to-talk owns the audio.
    func run(app: AppEnvironment) async {
        guard !isRunning else { return }
        guard AudioSessionArbiter.shared.owner == .none, !app.voice.isListening else {
            refusal = L("Stop Live or dictation first, then test again.")
            return
        }
        refusal = nil
        isRunning = true
        defer {
            isRunning = false
            asksHeard = false
            instruction = nil
        }
        steps = Self.initialSteps()
        let settings = app.settings
        let language: NormalizedUtterance.Language = settings.voiceLocale.language.languageCode?.identifier == "fr" ? .french : .english
        let lines = SelfTestLines(language: language)
        let voice = SelfTestVoice(settings: settings, language: language)
        LiveServices.shared.record(LiveLogEntry(time: ProcessInfo.processInfo.systemUptime, event: "selftest.step", fields: ["id": "start", "status": "running"]))

        await perform("perm") { await SelfTestProbes.permissions() }
        await perform("model") { await SelfTestProbes.speechModel(locale: settings.voiceLocale) }

        // The voice and the ear run on the simple path's session, exactly as in Live.
        if let problem = await SelfTestProbes.acquireSimpleSession() {
            update("voice", .failed(problem))
            update("ear", .failed(problem))
        } else {
            await perform("voice") { await self.voiceStep(voice: voice, lines: lines) }
            await perform("ear") { await self.earStep(app: app, voice: voice, lines: lines) }
            AudioSessionArbiter.shared.release(.liveSimple)
        }
        await perform("duplex") { await SelfTestProbes.duplex(settings: settings, lines: lines) }
        await perform("brain") { await SelfTestProbes.brain() }

        // Duplex is allowed only after it passed here; a skipped step keeps the last verdict.
        var duplexVerdict: Bool?
        if let duplex = steps.first(where: { $0.id == "duplex" })?.status {
            if duplex.isPassed { duplexVerdict = true } else if duplex.isFailed { duplexVerdict = false }
        }
        if let duplexVerdict, settings.liveDuplexAllowed != duplexVerdict { settings.liveDuplexAllowed = duplexVerdict }

        let counted = steps.filter { !$0.status.isSkipped }
        let passed = counted.filter(\.status.isPassed).count
        let summary = "\(passed)/\(counted.count) ✓ · \(Date().formatted(.dateTime.day().month(.abbreviated)))"
        LiveServices.shared.recordSelfTest(summary: summary, duplexPassed: duplexVerdict)
        LiveServices.shared.record(LiveLogEntry(time: ProcessInfo.processInfo.systemUptime, event: "selftest.step", fields: [
            "id": "summary", "passed": String(passed), "counted": String(counted.count),
        ]))
        SpokenFallback.say(lines.summary(passed: passed, counted: counted.count), language: language)
    }

    // MARK: Steps

    private func perform(_ id: String, _ probe: () async -> Status) async {
        update(id, .running)
        let started = ProcessInfo.processInfo.systemUptime
        let status = await probe()
        update(id, status)
        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        LiveServices.shared.record(LiveLogEntry(time: ProcessInfo.processInfo.systemUptime, event: "selftest.step", fields: [
            "id": id, "status": status.token, "ms": String(ms),
        ]))
    }

    /// speak() must start within 2.5 s and finish; then the person says whether they heard it.
    private func voiceStep(voice: SelfTestVoice, lines: SelfTestLines) async -> Status {
        let probe = SpeakProbe()
        let result = await probe.say(lines.voiceCheck, voice: voice, finishWithin: 8)
        guard let startMs = result.startMs else { return .failed(L("speak() did not start within 2.5 s: the system voice is stuck.")) }
        guard result.finished else { return .failed(L("The voice started but never finished.")) }
        instruction = L("Did you hear the voice?")
        asksHeard = true
        let answer = await waitForAnswer(seconds: 15)
        asksHeard = false
        instruction = nil
        switch answer {
        case .some(true): return .passed("\(startMs) ms · \(voice.name)")
        case .some(false): return .failed(L("Not heard: check the volume, the silent switch and where the sound goes (AirPlay, Bluetooth)."))
        case .none: return .failed(L("No answer."))
        }
    }

    /// "Dis : bonjour Picshop", then one utterance on VoiceController, as the simple path hears.
    private func earStep(app: AppEnvironment, voice: SelfTestVoice, lines: SelfTestLines) async -> Status {
        instruction = L("Say “bonjour Picshop” after the prompt.")
        defer { instruction = nil }
        let probe = SpeakProbe()
        _ = await probe.say(lines.earPrompt, voice: voice, finishWithin: 6)
        // The echo tail, as in Live.
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard let text = await EarProbe.listenOnce(voice: app.voice, locale: app.settings.voiceLocale, timeout: 8), !text.isEmpty else {
            return .failed(L("Nothing recognized: speak closer, or check the microphone."))
        }
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let expected = ["bonjour", "hello", "picshop", "pic shop"].contains { folded.contains($0) }
        return expected ? .passed("« \(text) »") : .failed("« \(text) » · " + L("not the expected words"))
    }

    /// Oui (true), Non (false), or no answer in time (nil).
    private func waitForAnswer(seconds: Double) async -> Bool? {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let pending = self.heard else { return }
            self.heard = nil
            self.asksHeard = false
            pending.resume(returning: nil)
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            heard = continuation
        }
        timeout.cancel()
        return answer
    }

    private func update(_ id: String, _ status: Status) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].status != status else { return }
        steps[index].status = status
    }

    private static func initialSteps() -> [Step] {
        [
            Step(id: "perm", title: L("Permissions"), status: .pending),
            Step(id: "model", title: L("Speech model"), status: .pending),
            Step(id: "voice", title: L("Voice"), status: .pending),
            Step(id: "ear", title: L("Listening"), status: .pending),
            Step(id: "duplex", title: L("Echo-cancelled audio (headphones)"), status: .pending),
            Step(id: "brain", title: L("On-device brain"), status: .pending),
        ]
    }
}
#endif
