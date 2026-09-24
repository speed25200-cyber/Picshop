#if canImport(UIKit)
import Foundation
import UIKit
import PicshopCore
import PicshopImaging
import PicshopIntent
#if canImport(MetricKit)
import MetricKit
#endif

/// Makes a crash, a hang or a memory kill report itself on the next launch.
///
/// - MetricKit crash and hang diagnostics are written as JSON to
///   Application Support/Diagnostics.
/// - An unclean-exit marker is set while the app is in the foreground and
///   cleared when it goes to the background: still there at launch, the last
///   session ended without warning (a memory kill leaves no crash log).
/// - A persisted ring of the last breadcrumbs (commands, heavy steps, free
///   memory) says what the app was doing at the time.
public final class Diagnostics: NSObject, @unchecked Sendable {
    public static let shared = Diagnostics()

    /// A previous session that ended badly.
    public struct Report: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// MetricKit delivered a crash diagnostic.
            case crash
            /// The app was in the foreground and never reached the background: a memory kill, a watchdog or a crash.
            case uncleanExit
        }

        public let id: UUID
        public let kind: Kind
        /// When the ended session was last known alive.
        public let date: Date
        /// One technical line (termination reason, signal…), in English for the report.
        public let summary: String
        /// Oldest first.
        public let breadcrumbs: [String]
        /// MetricKit JSON files that belong with it.
        public let files: [URL]
    }

    public static let breadcrumbLimit = 50

    /// Application Support/Diagnostics.
    public let directory: URL
    private var archiveDirectory: URL { directory.appendingPathComponent("Archive", isDirectory: true) }
    private var markerURL: URL { directory.appendingPathComponent("session.marker") }
    private var breadcrumbsURL: URL { directory.appendingPathComponent("breadcrumbs.log") }

    private let lock = NSLock()
    private let writer = DispatchQueue(label: "picshop.diagnostics", qos: .utility)
    private var crumbs: [String] = []
    private var previousCrumbs: [String] = []
    private var pending: Report?
    private var started = false
    private var commandsRedacted = false
    private var observers: [NSObjectProtocol] = []
    private var reportHandler: (@MainActor @Sendable (Report?) -> Void)?

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = support.appendingPathComponent("Diagnostics", isDirectory: true)
        super.init()
    }

    // MARK: - Lifecycle

    /// Call once at launch, before anything heavy runs.
    @MainActor
    public func start() {
        let alreadyStarted = lock.withLock { () -> Bool in
            defer { started = true }
            return started
        }
        guard !alreadyStarted else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        // What the last session left behind.
        let leftover = (try? String(contentsOf: breadcrumbsURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let markerDate = (try? fm.attributesOfItem(atPath: markerURL.path)[.modificationDate]) as? Date
        let files = unreportedFiles()
        let crashFiles = files.filter { $0.lastPathComponent.hasPrefix("crash-") }
        var report: Report?
        if markerDate != nil || !crashFiles.isEmpty {
            report = Report(id: UUID(), kind: crashFiles.isEmpty ? .uncleanExit : .crash, date: markerDate ?? Date(),
                            summary: crashFiles.isEmpty ? "The last session ended while in the foreground (no crash log: likely a memory kill or a watchdog)." : "MetricKit crash diagnostic.",
                            breadcrumbs: leftover, files: files)
        }
        lock.withLock {
            previousCrumbs = leftover
            pending = report
            crumbs = []
        }
        if let report { PSLog.error("previous session ended badly: \(report.kind.rawValue), \(report.breadcrumbs.last ?? "no breadcrumbs")", category: .ui) }

        // A launch into the background (a download finishing) is not a foreground session.
        if UIApplication.shared.applicationState != .background { setMarker() }
        note("launch \(BuildInfo.stamp)")
        ImagingBreadcrumbs.setHandler { [weak self] message in self?.note(message) }

        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("background")
            self?.clearMarker()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setMarker()
            self?.note("foreground")
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clearMarker()
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.note("memory warning")
        })
    }

    private func setMarker() {
        try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: markerURL, options: .atomic)
    }

    private func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: - Breadcrumbs

    /// True while Picshop Live runs: commands are noted by length only, never their words.
    public var redactsCommands: Bool {
        get { lock.withLock { commandsRedacted } }
        set { lock.withLock { commandsRedacted = newValue } }
    }

    /// Records what the app is doing, with the free memory, in the persisted ring.
    /// Anything shaped like an Anthropic key is redacted first.
    public func note(_ message: String) {
        let time = Self.timeFormatter.string(from: Date())
        let line = "\(time) \(APIKeyFormat.redact(message)) [\(MemoryBudget.availableDescription) free]"
        let text: String = lock.withLock {
            crumbs.append(line)
            if crumbs.count > Self.breadcrumbLimit { crumbs.removeFirst(crumbs.count - Self.breadcrumbLimit) }
            return crumbs.joined(separator: "\n")
        }
        let url = breadcrumbsURL
        writer.async {
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    /// The command about to run (spoken or tapped). During Live only its length.
    public func noteCommand(_ text: String) {
        if redactsCommands {
            note("command (\(text.count) characters)")
        } else {
            note("command “\(text.prefix(120))”")
        }
    }

    public var breadcrumbs: [String] { lock.withLock { crumbs } }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Reports

    /// The previous session's report, until dismissed.
    public var pendingReport: Report? { lock.withLock { pending } }

    /// Called on the main actor whenever `pendingReport` changes (a MetricKit
    /// payload can arrive a while after launch).
    public func setReportHandler(_ handler: (@MainActor @Sendable (Report?) -> Void)?) {
        lock.withLock { reportHandler = handler }
    }

    /// The report was seen or shared: its files move to the archive and it is not offered again.
    public func dismissPendingReport() {
        let files = lock.withLock { () -> [URL] in
            defer { pending = nil }
            return pending?.files ?? []
        }
        archive(files)
        publish(nil)
    }

    /// Writes a plain-text report to share (Mail, Files, AirDrop): the report, the
    /// breadcrumbs of both sessions and every MetricKit JSON inline.
    public func writeShareableReport(_ requested: Report? = nil) throws -> URL {
        let (report, current, previous) = lock.withLock { (requested ?? pending, crumbs, previousCrumbs) }
        var text = "Picshop diagnostics\n"
        text += "Build: \(BuildInfo.stamp)\n"
        text += "Device: \(Self.deviceModel) · \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "Written: \(ISO8601DateFormatter().string(from: Date()))\n"
        text += "Free memory now: \(MemoryBudget.availableDescription)\n\n"
        if let report {
            text += "== Previous session (\(report.kind.rawValue)) ==\n"
            text += "Last alive: \(ISO8601DateFormatter().string(from: report.date))\n"
            text += report.summary + "\n\n"
            text += "-- Breadcrumbs --\n" + report.breadcrumbs.joined(separator: "\n") + "\n\n"
        } else if !previous.isEmpty {
            text += "-- Previous session breadcrumbs --\n" + previous.joined(separator: "\n") + "\n\n"
        }
        text += "-- This session --\n" + current.joined(separator: "\n") + "\n"
        let files = report?.files ?? unreportedFiles()
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            text += "\n== \(file.lastPathComponent) ==\n" + String(decoding: data, as: UTF8.self) + "\n"
        }
        let stamp = Self.fileStamp(Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Picshop-diagnostics-\(stamp).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func publish(_ report: Report?) {
        let handler = lock.withLock { reportHandler }
        guard let handler else { return }
        Task { @MainActor in handler(report) }
    }

    /// MetricKit files not yet shown in a report.
    private func unreportedFiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func archive(_ files: [URL]) {
        let fm = FileManager.default
        for file in files where fm.fileExists(atPath: file.path) {
            let destination = archiveDirectory.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: file, to: destination)
        }
        // Keep the archive small: the 20 newest.
        let archived = ((try? fm.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in archived.dropFirst(20) { try? fm.removeItem(at: old) }
    }

    fileprivate func store(_ data: Data, kind: String, date: Date) -> URL? {
        let url = directory.appendingPathComponent("\(kind)-\(Self.fileStamp(date))-\(UUID().uuidString.prefix(4)).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            PSLog.error("could not write diagnostic: \(error)", category: .ui)
            return nil
        }
    }

    /// A crash diagnostic arrived: attach it to the pending report, or start one.
    fileprivate func received(crashFiles: [URL], summary: String, date: Date) {
        guard !crashFiles.isEmpty else { return }
        let report: Report = lock.withLock {
            let merged: Report
            if let current = pending {
                merged = Report(id: current.id, kind: .crash, date: current.date, summary: summary, breadcrumbs: current.breadcrumbs, files: current.files + crashFiles)
            } else {
                merged = Report(id: UUID(), kind: .crash, date: date, summary: summary, breadcrumbs: previousCrumbs, files: crashFiles)
            }
            pending = merged
            return merged
        }
        publish(report)
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// "iPhone17,1".
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

#if canImport(MetricKit)
extension Diagnostics: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashFiles: [URL] = []
        var summary = "MetricKit crash diagnostic."
        var date = Date()
        for payload in payloads {
            date = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                if let url = store(crash.jsonRepresentation(), kind: "crash", date: payload.timeStampEnd) { crashFiles.append(url) }
                var parts: [String] = []
                if let reason = crash.terminationReason { parts.append(reason) }
                if let signal = crash.signal { parts.append("signal \(signal)") }
                if let exception = crash.exceptionType { parts.append("exception \(exception)") }
                if !parts.isEmpty { summary = "Crash: " + parts.joined(separator: " · ") }
            }
            for hang in payload.hangDiagnostics ?? [] {
                _ = store(hang.jsonRepresentation(), kind: "hang", date: payload.timeStampEnd)
            }
        }
        note("MetricKit: \(crashFiles.count) crash diagnostic(s)")
        received(crashFiles: crashFiles, summary: summary, date: date)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily metrics: kept only when the system ended the app in the foreground (memory limit, bad access…).
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics?.foregroundExitData else { continue }
            let abnormal = exits.cumulativeMemoryResourceLimitExitCount + exits.cumulativeAbnormalExitCount + exits.cumulativeBadAccessExitCount
            guard abnormal > 0 else { continue }
            _ = store(payload.jsonRepresentation(), kind: "exits", date: payload.timeStampEnd)
            note("MetricKit: \(exits.cumulativeMemoryResourceLimitExitCount) memory-limit exit(s) in the foreground")
        }
    }
}
#endif
#endif
