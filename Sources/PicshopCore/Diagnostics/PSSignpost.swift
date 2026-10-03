import Foundation
#if canImport(os)
import os
#endif

/// Instruments intervals and events (Points of Interest) around the hot paths:
/// editor.open, photo.render, color.cube, llm.load… OSSignposter on Apple
/// platforms, a no-op on Linux. Details are only built while Instruments records.
public enum PSSignpost {
    public struct Interval: @unchecked Sendable {
        #if canImport(os)
        let name: StaticString
        let state: OSSignpostIntervalState?
        #endif
    }

    #if canImport(os)
    nonisolated(unsafe) private static let signposter = OSSignposter(subsystem: "com.picshopio.picshop", category: .pointsOfInterest)
    #endif

    public static func begin(_ name: StaticString, _ detail: @autoclosure () -> String = String()) -> Interval {
        #if canImport(os)
        guard signposter.isEnabled else { return Interval(name: name, state: nil) }
        let text = detail()
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(text, privacy: .public)")
        return Interval(name: name, state: state)
        #else
        return Interval()
        #endif
    }

    public static func end(_ interval: Interval) {
        #if canImport(os)
        guard let state = interval.state else { return }
        signposter.endInterval(interval.name, state)
        #endif
    }

    public static func event(_ name: StaticString, _ detail: @autoclosure () -> String = String()) {
        #if canImport(os)
        guard signposter.isEnabled else { return }
        let text = detail()
        signposter.emitEvent(name, id: signposter.makeSignpostID(), "\(text, privacy: .public)")
        #endif
    }

    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try body()
    }
}
