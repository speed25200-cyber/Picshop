import Foundation

/// What the feedback slot shows (ux-spec §4.7), in ascending priority: a job outranks an error, which outranks a
/// clarification, Live captions, a receipt, a reply, a notice and, last, an undo receipt.
public enum FeedbackKind: Int, CaseIterable, Comparable, Codable, Sendable {
    /// « Annulé : Lumière · (↷) »: 1,5 s, the next receipt replaces it.
    case undoReceipt = 0
    /// « Remplir avec l'IA nécessite 1,9 Go. »: until dismissed or acted on.
    case notice
    /// The assistant's words: 8 s; a tap opens the Conversation.
    case reply
    /// « ✦ Lumière auto · Exposition +0,3 »: 6 s (12 s with VoiceOver), or until the next edit.
    case receipt
    /// Live's words while it runs.
    case liveCaptions
    /// « Quel chien ? » with chips: until answered or the person starts something else.
    case clarification
    /// « Je ne sais pas encore… Le plus proche : »: until dismissed.
    case refusal
    /// Until dismissed, or until the person starts something else (then it moves to the Conversation).
    case error
    /// « Effacement… 42 % » with Annuler: until done.
    case job

    public static func < (lhs: FeedbackKind, rhs: FeedbackKind) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Seconds on screen; nil: until dismissed, answered or done.
    public func duration(voiceOver: Bool) -> Double? {
        switch self {
        case .undoReceipt: return 1.5
        case .receipt: return voiceOver ? 12 : 6
        case .reply: return 8
        case .notice, .liveCaptions, .clarification, .refusal, .error, .job: return nil
        }
    }

    /// Stale errors, refusals and clarifications never block (AC-11): they leave the slot for the Conversation as
    /// soon as the person starts anything new.
    public var yieldsToNewAction: Bool {
        switch self {
        case .clarification, .refusal, .error: return true
        case .undoReceipt, .notice, .reply, .receipt, .liveCaptions, .job: return false
        }
    }

    /// Transient items that are dropped rather than kept for the Conversation when something replaces them.
    public var isTransient: Bool { self == .undoReceipt }
}

/// The slot's one-at-a-time rule (§4.7): the highest-priority item shows, up to three wait, the rest go to the
/// Conversation. Pure, so the order is tested on Linux; the UI's Announcer holds the payloads by id.
public struct FeedbackQueue<ID: Hashable & Sendable>: Sendable {
    public struct Entry: Sendable, Hashable {
        public var id: ID
        public var kind: FeedbackKind

        public init(id: ID, kind: FeedbackKind) {
            self.id = id
            self.kind = kind
        }
    }

    /// At most this many items wait behind the one showing.
    public static var capacity: Int { 3 }

    /// What the slot shows now.
    public private(set) var current: Entry?
    /// What waits, highest priority first, oldest first within a priority.
    public private(set) var waiting: [Entry] = []

    public init() {}

    /// Every entry, showing first.
    public var all: [Entry] { (current.map { [$0] } ?? []) + waiting }

    public func contains(_ id: ID) -> Bool { current?.id == id || waiting.contains { $0.id == id } }

    /// Posts an item. Returns the items pushed out for the Conversation (the queue was full). Posting an id that is
    /// already queued keeps its place (a job's progress update).
    @discardableResult
    public mutating func post(_ id: ID, kind: FeedbackKind) -> [Entry] {
        guard !contains(id) else { return [] }
        let entry = Entry(id: id, kind: kind)
        if kind == .undoReceipt || kind == .receipt {
            // The next receipt replaces an undo receipt; only the latest undo receipt matters.
            waiting.removeAll { $0.kind == .undoReceipt }
            if current?.kind == .undoReceipt { current = nil }
        }
        guard let shown = current else {
            current = entry
            return []
        }
        if kind > shown.kind {
            current = entry
            if !shown.kind.isTransient { enqueue(shown) }
        } else {
            enqueue(entry)
        }
        return trim()
    }

    /// Removes an item (dismissed, timed out, answered, job done) and shows the next. False when it was not queued.
    @discardableResult
    public mutating func dismiss(_ id: ID) -> Bool {
        if current?.id == id {
            current = nil
            promote()
            return true
        }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        waiting.remove(at: index)
        return true
    }

    /// The person started an action or a job: errors, refusals and clarifications, showing or waiting, leave for the
    /// Conversation (returned, oldest first) and the next item shows.
    @discardableResult
    public mutating func userStartedAction() -> [Entry] {
        var moved: [Entry] = []
        if let shown = current, shown.kind.yieldsToNewAction {
            moved.append(shown)
            current = nil
        }
        moved += waiting.filter(\.kind.yieldsToNewAction)
        waiting.removeAll(where: \.kind.yieldsToNewAction)
        if current == nil { promote() }
        return moved
    }

    /// Empties the slot (the editor closes).
    public mutating func removeAll() {
        current = nil
        waiting = []
    }

    private mutating func enqueue(_ entry: Entry) {
        let index = waiting.firstIndex { $0.kind < entry.kind } ?? waiting.endIndex
        waiting.insert(entry, at: index)
    }

    private mutating func promote() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
    }

    /// Drops the lowest-priority waiting items beyond capacity (newest first among equals).
    private mutating func trim() -> [Entry] {
        var dropped: [Entry] = []
        while waiting.count > Self.capacity {
            dropped.append(waiting.removeLast())
        }
        return dropped.filter { !$0.kind.isTransient }
    }
}
