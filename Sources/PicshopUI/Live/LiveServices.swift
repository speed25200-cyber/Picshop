#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopIntent

/// Claude usage for Settings: lifetime totals and the current Live session.
public struct LiveUsageTotals: Equatable, Sendable {
    public var requests: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var outputTokens: Int
    /// An estimate (LiveCostEstimator), not a bill.
    public var estimatedUSD: Double
    public var sessionRequests: Int
    public var sessionEstimatedUSD: Double

    public init(requests: Int = 0, inputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, outputTokens: Int = 0,
                estimatedUSD: Double = 0, sessionRequests: Int = 0, sessionEstimatedUSD: Double = 0) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.estimatedUSD = estimatedUSD
        self.sessionRequests = sessionRequests
        self.sessionEstimatedUSD = sessionEstimatedUSD
    }
}

/// App-wide Live services shared by every editor's `LiveSession` and by Settings:
/// the Claude key, the usage counters, the network state, the log and the
/// Diagnostic Live model.
@MainActor
@Observable
public final class LiveServices {
    public static let shared = LiveServices()

    public let keyStore: ClaudeKeyStore
    /// Settings › Live › Diagnostic Live.
    public let debug: LiveDebugModel
    /// Lifetime totals (UserDefaults liveUsage.*) and the current session's counters.
    public private(set) var usage = LiveUsageTotals()

    @ObservationIgnored let reachability = LiveReachability()
    @ObservationIgnored let log = LiveLog()
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        keyStore = ClaudeKeyStore(transport: Self.makeTransport(onImageUpload: nil))
        debug = LiveDebugModel()
        usage = loadUsage()
    }

    public func resetUsage() {
        let cleared = LiveUsageTotals()
        if usage != cleared { usage = cleared }
        saveUsage(cleared)
    }

    /// Writes the Live log as redacted JSON (no transcript, no key) to a temporary file to share.
    public func exportLog() async -> URL? {
        let entries = log.entries
        var header: [String: String] = [
            "exported": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "brain": debug.brain,
            "route": debug.outputRoute,
            "echo_risk": debug.echoRisk,
            "barge_in": debug.bargeInMode,
            "echo_cancellation": debug.echoCancellation ? "on" : "off",
            "voice": debug.voiceDescription,
            "requests": String(usage.requests),
            "cache_read_tokens": String(usage.cacheReadTokens),
        ]
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

    /// A transport for one Live session. Debug builds route it through the fault injector.
    static func makeTransport(onImageUpload: (@Sendable (URLSessionClaudeTransport.UploadEvent) -> Void)?) -> any ClaudeTransport {
        let base = URLSessionClaudeTransport(onImageUpload: onImageUpload)
        #if DEBUG
        return FaultInjectingTransport(base: base)
        #else
        return base
        #endif
    }

    /// Where brains send their log entries, from any thread.
    nonisolated var logSink: @Sendable (LiveLogEntry) -> Void {
        { entry in Task { @MainActor in LiveServices.shared.record(entry) } }
    }

    func record(_ entry: LiveLogEntry) {
        log.append(entry)
        guard debug.isCollecting else { return }
        // ClaudeLiveBrain reports request sizes, cache use and stop reasons through the log.
        let fields = entry.fields
        let read = fields["cache_read"].flatMap(Int.init)
        let write = fields["cache_write"].flatMap(Int.init)
        let cache = (read != nil || write != nil) ? LiveDebugModel.Cache(read: read ?? 0, write: write ?? 0) : nil
        let bytes = entry.event == "request" ? fields["bytes"].flatMap(Int.init) : nil
        debug.setRequest(cache: cache, stopReason: fields["stop_reason"], bytes: bytes)
    }

    /// A new Live session: its counters start at zero.
    func beginSession() {
        var next = usage
        next.sessionRequests = 0
        next.sessionEstimatedUSD = 0
        if usage != next { usage = next }
    }

    /// One Claude response's usage, added to the session and the lifetime totals.
    func add(_ tokens: ClaudeUsage) {
        let cost = LiveCostEstimator.dollars(tokens)
        var next = usage
        next.requests += 1
        next.inputTokens += tokens.inputTokens
        next.cacheReadTokens += tokens.cacheReadInputTokens
        next.cacheWriteTokens += tokens.cacheCreationInputTokens
        next.outputTokens += tokens.outputTokens
        next.estimatedUSD += cost
        next.sessionRequests += 1
        next.sessionEstimatedUSD += cost
        usage = next
        saveUsage(next)
        debug.setRequest(cache: LiveDebugModel.Cache(read: tokens.cacheReadInputTokens, write: tokens.cacheCreationInputTokens), stopReason: nil, bytes: nil)
    }

    /// The one-time better-voice card, once per install.
    var hasShownVoiceHint: Bool {
        get { defaults.bool(forKey: "liveVoiceHintShown") }
        set { defaults.set(newValue, forKey: "liveVoiceHintShown") }
    }

    private func loadUsage() -> LiveUsageTotals {
        LiveUsageTotals(requests: defaults.integer(forKey: "liveUsage.requests"),
                        inputTokens: defaults.integer(forKey: "liveUsage.inputTokens"),
                        cacheReadTokens: defaults.integer(forKey: "liveUsage.cacheReadTokens"),
                        cacheWriteTokens: defaults.integer(forKey: "liveUsage.cacheWriteTokens"),
                        outputTokens: defaults.integer(forKey: "liveUsage.outputTokens"),
                        estimatedUSD: defaults.double(forKey: "liveUsage.estimatedUSD"))
    }

    private func saveUsage(_ totals: LiveUsageTotals) {
        defaults.set(totals.requests, forKey: "liveUsage.requests")
        defaults.set(totals.inputTokens, forKey: "liveUsage.inputTokens")
        defaults.set(totals.cacheReadTokens, forKey: "liveUsage.cacheReadTokens")
        defaults.set(totals.cacheWriteTokens, forKey: "liveUsage.cacheWriteTokens")
        defaults.set(totals.outputTokens, forKey: "liveUsage.outputTokens")
        defaults.set(totals.estimatedUSD, forKey: "liveUsage.estimatedUSD")
    }
}
#endif
