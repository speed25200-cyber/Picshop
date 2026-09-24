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
public struct TranscriptAccumulator: Sendable {
    public private(set) var snapshot = TranscriptSnapshot()
    private var turnStart: Double = 0

    public init() {}

    public mutating func beginTurn(at time: Double) {
        // Phase 0 stub: no filtering by time yet.
        turnStart = time
        snapshot = TranscriptSnapshot()
    }

    public mutating func apply(_ segment: TranscriptSegment) -> TranscriptSnapshot {
        // Phase 0 stub.
        if segment.isFinal {
            snapshot.finalized = TranscriptSnapshot(finalized: snapshot.finalized, volatile: segment.text).text
            snapshot.volatile = ""
        } else {
            snapshot.volatile = segment.text
        }
        return snapshot
    }
}
