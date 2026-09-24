#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopIntent

/// App-wide Live services shared by every editor's `LiveSession` and by Settings:
/// the log, the Diagnostic Live model and the voice self-test. Live runs on the
/// iPhone: nothing here talks to a server.
@MainActor
@Observable
public final class LiveServices {
    public static let shared = LiveServices()

    /// Settings › Live › Diagnostic Live.
    public let debug: LiveDebugModel
    /// Diagnostic Live › Tester le vocal.
    public let selfTest: LiveSelfTest
    /// The last self-test, "5/6 ✓ · 24 sept.", persisted under liveSelfTest.v1.
    public private(set) var selfTestSummary: String? = nil
    /// The last self-test's duplex step passed (headphones): Settings › Live may offer duplex.
    public private(set) var selfTestDuplexPassed = false

    @ObservationIgnored let log = LiveLog()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let selfTestKey = "liveSelfTest.v1"
    private static let selfTestDuplexKey = "liveSelfTest.duplex.v1"

    private init() {
        debug = LiveDebugModel()
        selfTest = LiveSelfTest()
        selfTestSummary = defaults.string(forKey: Self.selfTestKey)
        selfTestDuplexPassed = defaults.bool(forKey: Self.selfTestDuplexKey)
    }

    /// Writes the Live log as redacted JSON (no transcript) to a temporary file to share.
    public func exportLog() async -> URL? {
        let entries = log.entries
        var header: [String: String] = [
            "exported": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "brain": debug.brain,
            "voice_path": debug.voicePath,
            "route": debug.outputRoute,
            "echo_risk": debug.echoRisk,
            "barge_in": debug.bargeInMode,
            "echo_cancellation": debug.echoCancellation ? "on" : "off",
            "voice": debug.voiceDescription,
            "self_test": selfTestSummary ?? "none",
            "self_test_duplex": selfTestDuplexPassed ? "passed" : "not_passed",
            "thermal": LiveDebugModel.thermalDescription(ProcessInfo.processInfo.thermalState),
        ]
        let hub = LocalBrainHub.shared.status
        header["local_model"] = hub.model?.displayName ?? "none"
        header["local_tier"] = hub.decision.tier.rawValue
        header["local_tier_reason"] = hub.decision.reason.rawValue
        if let ttft = debug.firstTokenPercentilesMs {
            header["first_token_p50_ms"] = String(ttft.p50)
            header["first_token_p90_ms"] = String(ttft.p90)
        }
        if let stats = debug.lastStats {
            header["model"] = stats.model
            header["first_token_ms"] = String(stats.firstTokenMs)
            header["tokens_per_s"] = String(format: "%.1f", stats.tokensPerSecond)
        }
        for (mark, values) in debug.percentilesMs where values.count == 2 {
            header["p50_\(mark)"] = String(Int(values[0]))
            header["p90_\(mark)"] = String(Int(values[1]))
        }
        for (index, decision) in debug.decisions.prefix(30).enumerated() {
            header[String(format: "decision_%02d", index)] = decision
        }
        return await Task.detached(priority: .utility) { () -> URL? in
            let data = LiveLog.exportData(entries, header: header)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Picshop-Live-log-\(formatter.string(from: Date())).json")
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    // MARK: Live sessions

    /// Where brains send their log entries, from any thread.
    nonisolated var logSink: @Sendable (LiveLogEntry) -> Void {
        { entry in Task { @MainActor in LiveServices.shared.record(entry) } }
    }

    func record(_ entry: LiveLogEntry) {
        log.append(entry)
    }

    /// The self-test finished: its summary for Settings › Live and the log header.
    /// `duplexPassed` is nil when the duplex step was skipped (no headphones): the last verdict stays.
    func recordSelfTest(summary: String, duplexPassed: Bool? = nil) {
        if selfTestSummary != summary { selfTestSummary = summary }
        defaults.set(summary, forKey: Self.selfTestKey)
        if let duplexPassed {
            if selfTestDuplexPassed != duplexPassed { selfTestDuplexPassed = duplexPassed }
            defaults.set(duplexPassed, forKey: Self.selfTestDuplexKey)
        }
    }

    /// The one-time better-voice card, once per install.
    var hasShownVoiceHint: Bool {
        get { defaults.bool(forKey: "liveVoiceHintShown") }
        set { defaults.set(newValue, forKey: "liveVoiceHintShown") }
    }
}
#endif
