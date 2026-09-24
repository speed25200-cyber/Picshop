import Foundation
import PicshopCore

/// Loudness of one 20 ms slice of microphone audio.
public struct AudioFrameFeatures: Sendable, Equatable {
    public var rmsDB: Float
    public var time: Double

    public init(rmsDB: Float, time: Double) {
        self.rmsDB = rmsDB
        self.time = time
    }
}

/// One result from the speech recognizer, with times in seconds from the stream start.
public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var isFinal: Bool

    public init(text: String, start: Double, end: Double, isFinal: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}

/// What the user has said so far in the current turn.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var finalized: String
    public var volatile: String

    public init(finalized: String = "", volatile: String = "") {
        self.finalized = finalized
        self.volatile = volatile
    }

    public var text: String {
        [finalized, volatile].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

/// Finalized and volatile recognizer segments, per user turn.
///
/// Keeps the segments that end after the turn start; a final segment replaces
/// the volatile text it covers. Recent segments are remembered, so a turn that
/// begins in the past (0.3 s before a barge-in) still gets its first words.
public struct TranscriptAccumulator: Sendable {
    public private(set) var snapshot = TranscriptSnapshot()
    private var turnStart: Double = -.infinity
    private var finals: [TranscriptSegment] = []
    private var volatile: TranscriptSegment?
    /// Segments older than this before the newest one are forgotten.
    private static let memory: Double = 30

    public init() {}

    public mutating func beginTurn(at time: Double) {
        turnStart = time
        rebuild()
    }

    public mutating func apply(_ segment: TranscriptSegment) -> TranscriptSnapshot {
        if segment.isFinal {
            finals.removeAll { $0.start < segment.end && $0.end > segment.start }
            finals.append(segment)
            finals.sort { $0.start < $1.start }
            if let current = volatile, current.start < segment.end { volatile = nil }
            let horizon = segment.end - Self.memory
            finals.removeAll { $0.end < horizon }
        } else {
            volatile = segment
        }
        rebuild()
        return snapshot
    }

    private mutating func rebuild() {
        let kept = finals.filter { $0.end > turnStart }
        let finalized = kept.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        var tail = ""
        if let volatile, volatile.end > turnStart { tail = volatile.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        snapshot = TranscriptSnapshot(finalized: finalized, volatile: tail)
    }
}
