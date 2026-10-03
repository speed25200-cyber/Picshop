import Foundation

/// A hard time limit on awaited work: a language model's plan, a speech model's
/// install, an audio start. The caller gets its answer when the time is up even
/// if the work ignores cancellation: the work is cancelled, not awaited.
///
/// A task group cannot do this: leaving `withTaskGroup` awaits every child, so
/// an engine that never checks for cancellation holds the caller as long as it
/// runs. Here the first answer resumes a continuation and nothing else is
/// awaited. Whatever the work does after losing must be harmless (it is told to
/// stop, and its late result is dropped).
public enum Deadline {
    /// The time ran out before the work answered.
    public struct Expired: Error, Sendable, Equatable, CustomStringConvertible {
        public let seconds: Double

        public init(seconds: Double) {
            self.seconds = seconds
        }

        public var description: String { "no answer within \(seconds) s" }
    }

    /// The work's value, or nil when it answered nil, threw, or did not answer within `limit`.
    /// On time even when the work ignores cancellation. Cancelling the caller answers nil at once.
    public static func race<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        do {
            return try await run(seconds(limit)) { await work() }
        } catch {
            return nil
        }
    }

    /// Runs `work` and returns its result, or throws `Expired` after `seconds`.
    /// Cancelling the caller cancels the work and throws `CancellationError`.
    public static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard gate.install(continuation) else { return }
                let worker = Task {
                    do {
                        let value = try await work()
                        gate.resume(.success(value))
                    } catch {
                        gate.resume(.failure(error))
                    }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    gate.resume(.failure(Expired(seconds: seconds)))
                }
                gate.attach(worker: worker, timer: timer)
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }

    /// Waits for `task` at most `seconds`; false when the time ran out (the task keeps running).
    @discardableResult
    public static func wait(_ task: Task<Void, Never>, seconds: Double) async -> Bool {
        do {
            try await run(seconds) { await task.value }
            return true
        } catch {
            return false
        }
    }

    /// A Duration in seconds, attoseconds included.
    public static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The first answer wins: the work's result, the deadline or a cancellation.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        /// An answer that came before the continuation was installed (a caller already cancelled).
        private var early: Result<T, Error>?
        private var answered = false
        private var worker: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        /// False when the answer is already known: the continuation was resumed with it.
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            let result = early
            if result == nil { self.continuation = continuation }
            lock.unlock()
            guard let result else { return true }
            continuation.resume(with: result)
            return false
        }

        func attach(worker: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            self.worker = worker
            self.timer = timer
            let done = answered
            lock.unlock()
            if done {
                worker.cancel()
                timer.cancel()
            }
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            guard !answered else {
                lock.unlock()
                return
            }
            answered = true
            let pending = continuation
            continuation = nil
            if pending == nil { early = result }
            let work = worker
            let clock = timer
            lock.unlock()
            pending?.resume(with: result)
            clock?.cancel()
            // The deadline or a cancellation won: the work is told to stop.
            if case .failure = result { work?.cancel() }
        }
    }
}
