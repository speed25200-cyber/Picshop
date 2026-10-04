import Foundation
import PicshopCore

/// One turn's first token (D23): the `live.firstToken` event's fields.
public struct FirstTokenSample: Sendable, Equatable, Codable {
    public var milliseconds: Int
    /// "warm", "restored", "prefix", "cold", "picture".
    public var path: String
    public var prefilled: Int
    public var cached: Int
    public var picture: Bool

    public init(milliseconds: Int, path: String, prefilled: Int, cached: Int, picture: Bool) {
        self.milliseconds = milliseconds
        self.path = path
        self.prefilled = prefilled
        self.cached = cached
        self.picture = picture
    }

    /// The sample of a generation's stats: its KV path, or for W2's engine (which reports none) "picture", "warm"
    /// when it reused cached tokens, else "cold"; what it prefilled and what it reused. Nil without a first token.
    public init?(stats: LiveGenerationStats, picture: Bool) {
        guard stats.firstTokenMs > 0 else { return nil }
        let path = stats.kvPath ?? (picture ? "picture" : (stats.cachedTokens > 0 ? "warm" : "cold"))
        self.init(milliseconds: stats.firstTokenMs, path: path, prefilled: stats.promptTokens, cached: stats.cachedTokens,
                  picture: picture || path == "picture")
    }

    /// `path=<…> prefilled=N cached=M`: the `live.firstToken` and `llm.prefill` signpost metadata.
    public var signpostMetadata: String {
        "path=\(path) prefilled=\(prefilled) cached=\(cached)"
    }
}

/// The D23 goals the « Latence » section paints green or red. Reported, not kill criteria (§10 item 6).
public enum FirstTokenTargets {
    /// Warm first token without new cards, p50.
    public static let warmP50Ms = 700
    /// Warm first token with new cards, p50 (the suffix is up to `warmSuffixBudgetWithCards`).
    public static let warmWithCardsP50Ms = 1_000
    /// Every warm turn, p95.
    public static let warmP95Ms = 1_200
    /// A picture turn, p50.
    public static let pictureP50Ms = 1_200
    /// The first turn after a relaunch with the persisted prefix.
    public static let coldMs = 1_200
    /// A barge-in's checkpoint restore.
    public static let restoreMs = 50
    /// Compactions per 10 turns.
    public static let compactionsPer10Turns = 1.0
}

/// p50/p95 per path, the measured prefill and decode rates, barge-in restores and compactions per 10 turns, for
/// LiveDebugView's « Latence » section (D23). Pure; L5 owns it. Bounded: the most recent `capacity` samples.
public struct FirstTokenStats: Sendable, Equatable {
    /// The paths a sample can take, in the order the debug view lists them.
    public static let paths = ["warm", "restored", "prefix", "cold", "picture"]
    public static let capacity = 200

    private var samples: [FirstTokenSample] = []
    private var decodeRates: [Double] = []
    private var restores: [Int] = []
    public private(set) var turns = 0
    public private(set) var compactions = 0

    public init() {}

    public mutating func add(_ sample: FirstTokenSample) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public mutating func noteTurn(compacted: Bool) {
        turns += 1
        if compacted { compactions += 1 }
    }

    /// A generation's decode speed in tokens a second (ignored unless finite and positive).
    public mutating func noteDecodeRate(_ tokensPerSecond: Double) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        decodeRates.append(tokensPerSecond)
        if decodeRates.count > Self.capacity { decodeRates.removeFirst(decodeRates.count - Self.capacity) }
    }

    /// A barge-in that restored the turn checkpoint, and how long the restore took.
    public mutating func noteRestore(milliseconds: Int) {
        restores.append(max(0, milliseconds))
        if restores.count > Self.capacity { restores.removeFirst(restores.count - Self.capacity) }
    }

    /// The nearest-rank percentile (p in 0…100) of the samples on `path` (nil: every path); nil without samples.
    public func percentile(_ p: Double, path: String?) -> Int? {
        let values = samples.filter { path == nil || $0.path == path }.map(\.milliseconds).sorted()
        return Self.nearestRank(p, values)
    }

    public var compactionsPer10Turns: Double {
        turns == 0 ? 0 : Double(compactions) * 10 / Double(turns)
    }

    /// Samples on `path` (nil: every path).
    public func count(path: String?) -> Int {
        samples.filter { path == nil || $0.path == path }.count
    }

    /// The median prefill rate in tokens a second over the samples on `path` that prefilled something: prefilled
    /// tokens over the first-token time (which also holds one sampling step, so it slightly understates the rate).
    public func prefillTokensPerSecond(path: String?) -> Double? {
        let rates = samples
            .filter { (path == nil || $0.path == path) && $0.prefilled > 0 && $0.milliseconds > 0 }
            .map { Double($0.prefilled) * 1_000 / Double($0.milliseconds) }
            .sorted()
        guard !rates.isEmpty else { return nil }
        return rates[(rates.count - 1) / 2]
    }

    /// The median decode rate, nil without one.
    public var decodeTokensPerSecond: Double? {
        guard !decodeRates.isEmpty else { return nil }
        let sorted = decodeRates.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    public var restoreCount: Int { restores.count }

    /// The nearest-rank percentile of the restore times.
    public func restorePercentile(_ p: Double) -> Int? {
        Self.nearestRank(p, restores.sorted())
    }

    /// Whether a measured value meets its goal: nil (grey) without a measure.
    public static func meets(_ value: Int?, goal: Int) -> Bool? {
        value.map { $0 <= goal }
    }

    private static func nearestRank(_ p: Double, _ sorted: [Int]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p.clamped(to: 0...100) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
