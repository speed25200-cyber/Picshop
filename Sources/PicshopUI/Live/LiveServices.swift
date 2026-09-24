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
/// the Claude key, the usage counters and the Diagnostic Live model.
@MainActor
@Observable
public final class LiveServices {
    public static let shared = LiveServices()

    public let keyStore: ClaudeKeyStore
    /// Settings › Live › Diagnostic Live.
    public let debug: LiveDebugModel
    /// Lifetime totals (UserDefaults liveUsage.*) and the current session's counters.
    public private(set) var usage = LiveUsageTotals()

    private init() {
        keyStore = ClaudeKeyStore()
        debug = LiveDebugModel()
    }

    public func resetUsage() {
        // Phase 0 stub: nothing is persisted yet.
        if usage != LiveUsageTotals() { usage = LiveUsageTotals() }
    }

    /// Writes the Live log as redacted JSON (no transcript, no key) to a temporary file to share.
    public func exportLog() async -> URL? {
        // Phase 0 stub.
        nil
    }
}
#endif
