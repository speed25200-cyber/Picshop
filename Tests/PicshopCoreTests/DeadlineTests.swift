import XCTest
@testable import PicshopCore

/// Work that never checks for cancellation: a task group would wait for it.
private func stubborn(_ seconds: Double) async -> Int? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: 7) }
    }
}

final class DeadlineTests: XCTestCase {
    func testRaceAnswersOnTimeWhenTheWorkIgnoresCancellation() async {
        let start = Date()
        let value = await Deadline.race(.milliseconds(100)) { await stubborn(2) }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1 + 0.05)
    }

    func testRaceReturnsTheWorksValueWhenItIsInTime() async {
        let value = await Deadline.race(.seconds(2)) { await stubborn(0.01) }
        XCTAssertEqual(value, 7)
    }

    func testRunThrowsExpiredAndPassesErrorsThrough() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(0.05) { await stubborn(2) }
            XCTFail("expected Expired")
        } catch {
            XCTAssertEqual(error as? Deadline.Expired, Deadline.Expired(seconds: 0.05))
        }
        do {
            _ = try await Deadline.run(1) { () async throws -> Int in throw Boom() }
            XCTFail("expected the work's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testCancellingTheCallerAnswersAtOnce() async {
        let task = Task { await Deadline.race(.seconds(5)) { await stubborn(2) } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testDurationSeconds() {
        XCTAssertEqual(Deadline.seconds(.milliseconds(1500)), 1.5, accuracy: 1e-9)
    }
}
