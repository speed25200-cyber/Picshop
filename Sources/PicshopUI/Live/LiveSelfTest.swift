#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopSpeech

/// Diagnostic Live › Tester le vocal: six checks, each with ✓/✗ and a reason —
/// permissions, the speech model, the voice, the ear, the duplex engine
/// (headphones only) and the brain. The last run's summary is kept by LiveServices.
///
/// Phase 0: the frozen surface. Permissions and the brain (LocalBrainHub.probe())
/// are checked; the audio steps arrive in phase 1 and are skipped until then.
@MainActor
@Observable
public final class LiveSelfTest {
    enum Status: Equatable {
        case pending, running, passed(String), failed(String), skipped(String)

        var isPassed: Bool {
            if case .passed = self { return true }
            return false
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
    @ObservationIgnored private var heard: CheckedContinuation<Bool, Never>?

    init() {
        steps = Self.initialSteps()
    }

    func answerHeard(_ yes: Bool) {
        asksHeard = false
        heard?.resume(returning: yes)
        heard = nil
    }

    /// Refused while Live or push-to-talk owns the audio. Each step takes 12 s at most.
    func run(app: AppEnvironment) async {
        guard !isRunning, AudioSessionArbiter.shared.owner == .none, !app.voice.isListening else { return }
        isRunning = true
        defer { isRunning = false }
        steps = Self.initialSteps()
        update("perm", VoiceController.permissionsGranted ? .passed("OK") : .failed(L("Microphone or speech recognition not allowed")))
        for id in ["model", "voice", "ear", "duplex"] {
            update(id, .skipped(L("Not in this build yet")))
        }
        update("brain", .running)
        let probe = await LocalBrainHub.shared.probe()
        update("brain", probe.passed ? .passed(probe.summary) : .failed("\(probe.summary) · Apple Intelligence: \(probe.appleIntelligence)"))
        LiveServices.shared.recordSelfTest(summary: summary())
    }

    /// "2/6 ✓ · 24 sept."
    private func summary() -> String {
        let passed = steps.filter(\.status.isPassed).count
        return "\(passed)/\(steps.count) ✓ · \(Date().formatted(.dateTime.day().month(.abbreviated)))"
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
