#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopIntent

/// What Settings › Live › Diagnostic Live shows. Updated only while liveDebug is
/// on, except the ring of recent decisions, which is always kept.
@MainActor
@Observable
public final class LiveDebugModel {
    public private(set) var brain = ""
    /// simple or duplex: the voice path in use.
    public private(set) var voicePath = ""
    public private(set) var echoCancellation = false
    public private(set) var outputRoute = ""
    public private(set) var echoRisk = ""
    public private(set) var bargeInMode = ""
    public private(set) var noiseFloorDB: Double = 0
    /// dB above the noise floor, 10 Hz, the last 3 s.
    public private(set) var levelHistory: [Double] = []
    /// End-of-turn and barge-in decisions with their reasons, newest first, at most 30.
    public private(set) var decisions: [String] = []
    public private(set) var lastLatencyMs: [String: Double] = [:]
    /// Mark -> [p50, p90].
    public private(set) var percentilesMs: [String: [Double]] = [:]
    /// The last generation of a brain that reports stats (the local model).
    public private(set) var lastStats: LiveGenerationStats?
    public private(set) var voiceDescription = ""

    /// Mirrors AppSettings.liveDebug; set by LiveSession.
    @ObservationIgnored var isCollecting = false

    init() {}

    /// The on-device test the user runs from Diagnostic Live; results come back through Exporter le journal Live.
    public static var deviceChecklist: [String] {
        [
            L("Loudspeaker at full volume in a quiet room: talk over the assistant in safe mode. It must not interrupt itself. Say “stop”: it stops within 0.3 s."),
            L("Turn on Let me interrupt and repeat step 1, noting false interruptions in the decisions list."),
            L("AirPods: full barge-in by default. Check the voice quality."),
            L("Café noise: the end of your turn is detected in under 2 s."),
            L("A phone call in the middle of a reply."),
            L("Airplane mode: Live answers the same."),
            L("A 20-minute session: note the thermal state and the answer speed."),
            L("VoiceOver on: turn-taking."),
        ]
    }

    // MARK: Updates (LiveSession)

    func noteDecision(_ decision: String) {
        let time = Self.clock.string(from: Date())
        decisions.insert("\(time) \(decision)", at: 0)
        if decisions.count > 30 { decisions.removeLast(decisions.count - 30) }
    }

    func setAudio(brain: String, echoCancellation: Bool, outputRoute: String, echoRisk: String, bargeInMode: String) {
        guard isCollecting else { return }
        if self.brain != brain { self.brain = brain }
        if self.echoCancellation != echoCancellation { self.echoCancellation = echoCancellation }
        if self.outputRoute != outputRoute { self.outputRoute = outputRoute }
        if self.echoRisk != echoRisk { self.echoRisk = echoRisk }
        if self.bargeInMode != bargeInMode { self.bargeInMode = bargeInMode }
    }

    /// 10 Hz: the level above the floor, and the floor.
    func pushLevel(aboveFloorDB: Double, floorDB: Double) {
        guard isCollecting else { return }
        levelHistory.append((aboveFloorDB * 10).rounded() / 10)
        if levelHistory.count > 30 { levelHistory.removeFirst(levelHistory.count - 30) }
        let floor = (floorDB * 10).rounded() / 10
        if noiseFloorDB != floor { noiseFloorDB = floor }
    }

    func setLatency(last: [String: Double], percentiles: [String: [Double]]) {
        guard isCollecting else { return }
        if lastLatencyMs != last { lastLatencyMs = last }
        if percentilesMs != percentiles { percentilesMs = percentiles }
    }

    func setStats(_ stats: LiveGenerationStats) {
        guard isCollecting, lastStats != stats else { return }
        lastStats = stats
    }

    func setVoicePath(_ path: String) {
        guard isCollecting, voicePath != path else { return }
        voicePath = path
    }

    func setVoice(_ description: String) {
        guard isCollecting, voiceDescription != description else { return }
        voiceDescription = description
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter
    }()
}
#endif
