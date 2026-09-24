import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Server-sent events from raw bytes, in whatever chunks the network delivers.
///
/// Lines end at LF, CRLF or a lone CR; only complete lines are decoded, so a
/// chunk boundary inside a multi-byte character or between CR and LF is safe.
/// A blank line dispatches the event; comments are ignored; several data lines
/// join with LF.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var afterCR = false
    private var sawFirstByte = false
    private var eventName: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var lastID: String?

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if !sawFirstByte {
                sawFirstByte = true
                line.reserveCapacity(256)
            }
            switch byte {
            case 0x0A:
                if afterCR {
                    afterCR = false
                    continue
                }
                endLine(into: &events)
            case 0x0D:
                afterCR = true
                endLine(into: &events)
            default:
                afterCR = false
                line.append(byte)
            }
        }
        return events
    }

    /// Flushes a last line and event that had no trailing blank line.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty { endLine(into: &events) }
        dispatch(into: &events)
        afterCR = false
        return events
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        var text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "id":
            if !value.contains("\u{0}") { lastID = String(value) }
        default: break   // retry and unknown fields
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            eventName = nil
            dataLines.removeAll()
            hasData = false
        }
        guard hasData else { return }
        events.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastID))
    }
}
