import Foundation
#if canImport(os)
import os
#endif

/// Thin logging facade so every module logs consistently on Apple platforms and Linux.
public enum PSLog {
    public enum Category: String, Sendable {
        case core, intent, imaging, video, speech, ui, models
    }

    #if canImport(os)
    private static let loggers: [Category: Logger] = {
        var map: [Category: Logger] = [:]
        for category in [Category.core, .intent, .imaging, .video, .speech, .ui, .models] {
            map[category] = Logger(subsystem: "com.picshop.app", category: category.rawValue)
        }
        return map
    }()
    #endif

    public static func debug(_ message: @autoclosure () -> String, category: Category = .core) {
        #if DEBUG
        #if canImport(os)
        loggers[category]?.debug("\(message(), privacy: .public)")
        #else
        print("[\(category.rawValue)] \(message())")
        #endif
        #endif
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .core) {
        #if canImport(os)
        loggers[category]?.info("\(message(), privacy: .public)")
        #else
        print("[\(category.rawValue)] \(message())")
        #endif
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .core) {
        #if canImport(os)
        loggers[category]?.error("\(message(), privacy: .public)")
        #else
        print("[\(category.rawValue)] ERROR \(message())")
        #endif
    }
}

/// Wall-clock timing helper for performance logging.
public struct PSTimer: Sendable {
    private let start = Date()
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var elapsedMilliseconds: Double { Date().timeIntervalSince(start) * 1000 }

    public func log(category: PSLog.Category = .core) {
        PSLog.debug("\(label) took \(Int(elapsedMilliseconds)) ms", category: category)
    }
}
