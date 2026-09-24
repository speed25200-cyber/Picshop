#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation

/// What Settings › Live › Diagnostic Live shows. Updated only while liveDebug is
/// on, except the ring of recent decisions, which is always kept.
@MainActor
@Observable
public final class LiveDebugModel {
    public struct Cache: Equatable, Sendable {
        public var read: Int
        public var write: Int

        public init(read: Int, write: Int) {
            self.read = read
            self.write = write
        }
    }

    public private(set) var brain = ""
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
    public private(set) var lastCache: Cache?
    public private(set) var lastStopReason: String?
    public private(set) var lastRequestBytes: Int?
    public private(set) var voiceDescription = ""

    /// Backs `injectedFault`. Stored outside `#if` so observation tracks it.
    private var fault: String?

    #if DEBUG
    /// 401, 402, 429, 529, timeout, refusal, offline, or nil. Read by FaultInjectingTransport.
    public var injectedFault: String? {
        get { fault }
        set { fault = newValue }
    }
    #endif

    init() {}
}
#endif
