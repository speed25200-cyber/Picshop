import XCTest
@testable import PicshopCore

/// The measurement API is callable everywhere (a no-op on Linux), and timers end
/// their interval when they log.
final class SignpostTests: XCTestCase {
    func testIntervalsEventsAndMeasureRun() {
        let interval = PSSignpost.begin("photo.render", "1280 px")
        PSSignpost.event("touchToPhoton", "generation 3")
        PSSignpost.end(interval)
        let value = PSSignpost.measure("color.cube") { 17 * 17 * 17 }
        XCTAssertEqual(value, 4913)
    }

    func testMeasureRethrows() {
        struct Failure: Error {}
        XCTAssertThrowsError(try PSSignpost.measure("video.compositionBuild") { () throws -> Int in throw Failure() })
    }

    func testTimerLogsOnce() {
        let timer = PSTimer("export")
        XCTAssertGreaterThanOrEqual(timer.elapsedMilliseconds, 0)
        timer.log()
        XCTAssertEqual(timer.label, "export")
    }
}

/// MetricKit's daily histograms read as percentiles, and the days kept on the device.
final class PerformanceLogTests: XCTestCase {
    func testPercentilesInterpolateInsideTheirBucket() {
        let buckets = [MetricHistogram.Bucket(start: 0, end: 100, count: 50),
                       MetricHistogram.Bucket(start: 100, end: 200, count: 40),
                       MetricHistogram.Bucket(start: 200, end: 400, count: 10)]
        XCTAssertEqual(MetricHistogram.percentile(0.5, of: buckets)!, 100, accuracy: 1e-9)
        XCTAssertEqual(MetricHistogram.percentile(0.9, of: buckets)!, 200, accuracy: 1e-9)
        XCTAssertEqual(MetricHistogram.percentile(0.95, of: buckets)!, 300, accuracy: 1e-9)
        XCTAssertEqual(MetricHistogram.percentile(0.25, of: buckets)!, 50, accuracy: 1e-9)
        XCTAssertNil(MetricHistogram.percentile(0.5, of: []))
        XCTAssertEqual(MetricHistogram.total(buckets), 100)
    }

    func testTheLogKeepsOneEntryPerDayAndAMonth() {
        var log = PerformanceLog()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for day in 0..<40 { log.add(PerformanceDay(date: start.addingTimeInterval(Double(day) * 86_400), launchP50: Double(day))) }
        XCTAssertEqual(log.days.count, PerformanceLog.limit)
        XCTAssertEqual(log.days.last?.launchP50, 39)
        log.add(PerformanceDay(date: start.addingTimeInterval(39 * 86_400 + 60), launchP50: 7))
        XCTAssertEqual(log.days.count, PerformanceLog.limit, "the same day again replaces it")
        XCTAssertEqual(log.days.last?.launchP50, 7)
    }
}
