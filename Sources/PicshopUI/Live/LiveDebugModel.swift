#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopIntent

/// What Settings › Live › Diagnostic Live shows. Updated only while liveDebug is
/// on, except the ring of recent decisions and the model's generation stats (one
/// update per answer), which are always kept.
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
    /// The last 50 generations' first-token times (ms) and speeds (tok/s), oldest first.
    public private(set) var firstTokenHistoryMs: [Int] = []
    public private(set) var tokensPerSecondHistory: [Double] = []
    public private(set) var voiceDescription = ""

    /// Mirrors AppSettings.liveDebug; set by LiveSession.
    @ObservationIgnored var isCollecting = false

    init() {}

    /// The on-device test the user runs from Diagnostic Live; results come back through Exporter le journal Live.
    public static var deviceChecklist: [String] {
        [
            L("Run Test the voice above: all six steps, answering Yes or No. On any ✗, export the log."),
            L("Loudspeaker, tap the orb: “Looking at your photo…” within 1 s, then a sentence and three ideas."),
            L("With a TV on in the room: “Listening…” never stays stuck more than 4 s, and no reply cancels itself."),
            L("Tap the orb during a reply: it stops at once."),
            L("A phone call in the middle of a reply."),
            L("Airplane mode: Live answers the same."),
            L("Headphones: run the test again, so duplex is allowed, then talk over a reply."),
            L("A 10-minute session with a large photo: note the thermal state and the answer speed."),
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
        lastStats = stats
        firstTokenHistoryMs.append(stats.firstTokenMs)
        if firstTokenHistoryMs.count > 50 { firstTokenHistoryMs.removeFirst(firstTokenHistoryMs.count - 50) }
        if stats.tokensPerSecond.isFinite, stats.tokensPerSecond > 0 {
            tokensPerSecondHistory.append(stats.tokensPerSecond)
            if tokensPerSecondHistory.count > 50 { tokensPerSecondHistory.removeFirst(tokensPerSecondHistory.count - 50) }
        }
    }

    /// Time to first token, p50 and p90 over the recent answers, in ms.
    public var firstTokenPercentilesMs: (p50: Int, p90: Int)? {
        guard !firstTokenHistoryMs.isEmpty else { return nil }
        let sorted = firstTokenHistoryMs.sorted()
        return (Self.percentile(sorted, 0.5), Self.percentile(sorted, 0.9))
    }

    /// Median decoding speed over the recent answers.
    public var medianTokensPerSecond: Double? {
        guard !tokensPerSecondHistory.isEmpty else { return nil }
        let sorted = tokensPerSecondHistory.sorted()
        return sorted[sorted.count / 2]
    }

    private static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    func setVoicePath(_ path: String) {
        guard isCollecting, voicePath != path else { return }
        voicePath = path
    }

    func setVoice(_ description: String) {
        guard isCollecting, voiceDescription != description else { return }
        voiceDescription = description
    }

    /// nominal, fair, serious or critical.
    public static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter
    }()
}
#endif
