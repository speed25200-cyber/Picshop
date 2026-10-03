import Foundation
import PicshopCore

/// A time limit on an awaited start: the speech model's install, the audio
/// engine, the audio session, a self-test probe. Nothing Live awaits may hang it.
///
/// A thin wrapper over Core's `Deadline` (the same continuation race the router's
/// hard LLM timeout uses): the caller gets its answer when the time is up even if
/// the work ignores cancellation. The work is cancelled, not awaited; whatever it
/// does afterwards must be harmless (every start it wraps checks that its owner
/// still wants it).
public enum LiveDeadline {
    public struct Expired: Error, Sendable, Equatable, CustomStringConvertible {
        public let seconds: Double

        public init(seconds: Double) {
            self.seconds = seconds
        }

        public var description: String { "no answer within \(seconds) s" }
    }

    /// Runs `work` and returns its result, or throws `Expired` after `seconds`.
    /// Cancelling the caller cancels the work and throws `CancellationError`.
    public static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await Deadline.run(seconds, work)
        } catch let expired as Deadline.Expired {
            throw Expired(seconds: expired.seconds)
        }
    }

    /// Waits for `task` at most `seconds`; false when the time ran out (the task keeps running).
    @discardableResult
    public static func wait(_ task: Task<Void, Never>, seconds: Double) async -> Bool {
        await Deadline.wait(task, seconds: seconds)
    }
}
