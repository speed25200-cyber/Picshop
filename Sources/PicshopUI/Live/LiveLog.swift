#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import PicshopIntent

/// The Live event log behind 'Exporter le journal Live': lengths, ids, statuses
/// and timings only. Entries are sanitized on the way in and again on export, so
/// no transcript can reach the file.
@MainActor
final class LiveLog {
    static let limit = 800
    private(set) var entries: [LiveLogEntry] = []

    func append(_ entry: LiveLogEntry) {
        entries.append(Self.sanitized(entry))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Field names that could carry words the user said or the model wrote.
    nonisolated static let forbiddenFields: Set<String> = [
        "text", "transcript", "utterance", "prompt", "reply", "message", "caption", "content", "said", "spoken", "key", "apikey", "api_key", "x-api-key",
    ]

    nonisolated static func sanitized(_ entry: LiveLogEntry) -> LiveLogEntry {
        var fields: [String: String] = [:]
        for (name, value) in entry.fields where !forbiddenFields.contains(name.lowercased()) {
            fields[name] = String(value.prefix(80))
        }
        return LiveLogEntry(time: entry.time, event: String(entry.event.prefix(48)), fields: fields)
    }

    /// Pretty JSON: a header, then the entries oldest first.
    nonisolated static func exportData(_ entries: [LiveLogEntry], header: [String: String]) -> Data {
        let origin = entries.first?.time ?? 0
        let items: [[String: Any]] = entries.map { raw in
            let entry = sanitized(raw)
            return ["t": ((entry.time - origin) * 1000).rounded() / 1000, "event": entry.event, "fields": entry.fields]
        }
        let object: [String: Any] = ["picshop_live_log": 1, "header": header, "entries": items]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
#endif
