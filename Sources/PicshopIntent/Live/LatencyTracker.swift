import Foundation
import PicshopCore

/// Per-turn timing marks, from the end of the user's speech to the first audible word.
public struct LatencyTracker: Sendable {
    public enum Mark: String, Sendable, CaseIterable { case speechEnd, committed, requestSent, firstByte, firstText, firstChunk, firstAudio, toolStart, toolEnd }

    public init() {}

    public mutating func mark(_ mark: Mark, at: Double, turn: Int) {
        // Phase 0 stub.
    }

    public mutating func record(usage: ClaudeUsage, bodyBytes: Int, turn: Int) {
        // Phase 0 stub.
    }

    /// ms from speechEnd.
    public func report(turn: Int) -> [String: Double] {
        // Phase 0 stub.
        [:]
    }

    public func percentiles(_ mark: Mark) -> (p50: Double, p90: Double)? {
        // Phase 0 stub.
        nil
    }
}
