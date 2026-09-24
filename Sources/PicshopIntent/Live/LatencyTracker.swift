import Foundation
import PicshopCore

/// Per-turn timing marks, from the end of the user's speech to the first audible word.
/// Keeps the last 50 turns; percentiles are nearest-rank over the turns that have the mark.
public struct LatencyTracker: Sendable {
    public enum Mark: String, Sendable, CaseIterable { case speechEnd, committed, requestSent, firstByte, firstText, firstChunk, firstAudio, toolStart, toolEnd }

    private struct Turn: Sendable {
        var marks: [Mark: Double] = [:]
        var usage: ClaudeUsage?
        var bodyBytes: Int?
    }

    private var turns: [Int: Turn] = [:]
    private var order: [Int] = []
    static let capacity = 50

    public init() {}

    /// The first time a mark is reached in a turn counts.
    public mutating func mark(_ mark: Mark, at: Double, turn: Int) {
        touch(turn)
        if turns[turn]?.marks[mark] == nil { turns[turn]?.marks[mark] = at }
    }

    public mutating func record(usage: ClaudeUsage, bodyBytes: Int, turn: Int) {
        touch(turn)
        turns[turn]?.usage = usage
        turns[turn]?.bodyBytes = bodyBytes
    }

    /// ms from speechEnd (from committed when speechEnd is missing: typed turns).
    public func report(turn: Int) -> [String: Double] {
        guard let marks = turns[turn]?.marks else { return [:] }
        let originMark: Mark = marks[.speechEnd] != nil ? .speechEnd : .committed
        guard let origin = marks[originMark] else { return [:] }
        var result: [String: Double] = [:]
        for (mark, time) in marks where mark != originMark {
            result[mark.rawValue] = ((time - origin) * 1000).rounded()
        }
        return result
    }

    public func usage(turn: Int) -> ClaudeUsage? { turns[turn]?.usage }

    public func percentiles(_ mark: Mark) -> (p50: Double, p90: Double)? {
        let values = order.compactMap { report(turn: $0)[mark.rawValue] }.sorted()
        guard !values.isEmpty else { return nil }
        func rank(_ p: Double) -> Double {
            let index = Int((p * Double(values.count)).rounded(.up)) - 1
            return values[min(max(index, 0), values.count - 1)]
        }
        return (rank(0.5), rank(0.9))
    }

    private mutating func touch(_ turn: Int) {
        guard turns[turn] == nil else { return }
        turns[turn] = Turn()
        order.append(turn)
        if order.count > Self.capacity {
            turns[order.removeFirst()] = nil
        }
    }
}
