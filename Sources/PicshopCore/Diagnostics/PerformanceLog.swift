import Foundation

/// One day of MetricKit's field measurements, kept on the device (never sent)
/// for Réglages › Avancé › Performance: launch, hangs, scroll hitches, memory.
public struct PerformanceDay: Codable, Hashable, Sendable {
    /// End of the day the payload covers.
    public var date: Date
    /// Time to first draw, milliseconds.
    public var launchP50: Double?
    public var launchP90: Double?
    /// How many hangs, and the 90th percentile of their length (milliseconds).
    public var hangCount: Int?
    public var hangP90: Double?
    /// Scroll hitch time, milliseconds per second of scrolling.
    public var hitchRatio: Double?
    public var peakMemoryMB: Double?

    public init(date: Date, launchP50: Double? = nil, launchP90: Double? = nil, hangCount: Int? = nil, hangP90: Double? = nil,
                hitchRatio: Double? = nil, peakMemoryMB: Double? = nil) {
        self.date = date
        self.launchP50 = launchP50
        self.launchP90 = launchP90
        self.hangCount = hangCount
        self.hangP90 = hangP90
        self.hitchRatio = hitchRatio
        self.peakMemoryMB = peakMemoryMB
    }
}

/// MetricKit histograms come as buckets (a range and a count); percentiles are
/// read off them, interpolated inside the bucket where they fall.
public enum MetricHistogram {
    public struct Bucket: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var count: Int

        public init(start: Double, end: Double, count: Int) {
            self.start = start
            self.end = max(start, end)
            self.count = max(0, count)
        }
    }

    public static func total(_ buckets: [Bucket]) -> Int { buckets.reduce(0) { $0 + $1.count } }

    /// The value under which `fraction` (0…1) of the samples fall; nil without samples.
    public static func percentile(_ fraction: Double, of buckets: [Bucket]) -> Double? {
        let sorted = buckets.filter { $0.count > 0 }.sorted { $0.start < $1.start }
        let total = total(sorted)
        guard total > 0 else { return nil }
        let target = min(1, max(0, fraction)) * Double(total)
        var seen = 0.0
        for bucket in sorted {
            let next = seen + Double(bucket.count)
            if next >= target {
                let inside = bucket.count > 0 ? (target - seen) / Double(bucket.count) : 0
                return bucket.start + (bucket.end - bucket.start) * min(1, max(0, inside))
            }
            seen = next
        }
        return sorted.last?.end
    }
}

/// The days kept on the device: newest last, at most `limit`, one per date.
public struct PerformanceLog: Codable, Hashable, Sendable {
    public static let limit = 30
    public private(set) var days: [PerformanceDay] = []

    public init(days: [PerformanceDay] = []) {
        for day in days { add(day) }
    }

    public mutating func add(_ day: PerformanceDay) {
        days.removeAll { abs($0.date.timeIntervalSince(day.date)) < 3600 }
        days.append(day)
        days.sort { $0.date < $1.date }
        if days.count > Self.limit { days.removeFirst(days.count - Self.limit) }
    }
}
