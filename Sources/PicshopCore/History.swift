import Foundation

/// Value-semantic undo/redo stack storing whole snapshots.
///
/// Snapshots are cheap because documents are small value types that reference
/// media by path; pixels are never copied. Transactions coalesce rapid changes
/// (slider drags, brush strokes) into one undo step.
public struct EditHistory<State: Hashable & Sendable>: Sendable {
    public struct Entry: Sendable {
        public var state: State
        public var label: String
        public var timestamp: Date
    }

    public private(set) var present: State
    public private(set) var past: [Entry] = []
    public private(set) var future: [Entry] = []
    public var limit: Int
    private var transactionOrigin: Entry?

    public init(initial: State, limit: Int = 200) {
        present = initial
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoLabel: String? { past.last?.label }
    public var redoLabel: String? { future.last?.label }
    public var isInTransaction: Bool { transactionOrigin != nil }
    public var count: Int { past.count }

    /// Records `newState` as an undoable step.
    public mutating func commit(_ newState: State, label: String) {
        guard newState != present else { return }
        if transactionOrigin != nil {
            present = newState
            return
        }
        past.append(Entry(state: present, label: label, timestamp: Date()))
        if past.count > limit { past.removeFirst(past.count - limit) }
        present = newState
        future.removeAll()
    }

    /// Starts a coalescing transaction (e.g. slider drag). Changes committed
    /// before `endTransaction` collapse into one undo step.
    public mutating func beginTransaction(label: String) {
        guard transactionOrigin == nil else { return }
        transactionOrigin = Entry(state: present, label: label, timestamp: Date())
    }

    public mutating func endTransaction() {
        guard let origin = transactionOrigin else { return }
        transactionOrigin = nil
        guard origin.state != present else { return }
        past.append(origin)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    public mutating func cancelTransaction() {
        guard let origin = transactionOrigin else { return }
        transactionOrigin = nil
        present = origin.state
    }

    @discardableResult
    public mutating func undo() -> String? {
        endTransaction()
        guard let entry = past.popLast() else { return nil }
        future.append(Entry(state: present, label: entry.label, timestamp: Date()))
        present = entry.state
        return entry.label
    }

    @discardableResult
    public mutating func redo() -> String? {
        guard let entry = future.popLast() else { return nil }
        past.append(Entry(state: present, label: entry.label, timestamp: Date()))
        present = entry.state
        return entry.label
    }

    /// Replaces the present state without creating an undo step (view-only state such as the current page).
    public mutating func replacePresent(_ state: State) {
        present = state
    }

    /// Replaces the present state without recording history (used for loads).
    public mutating func reset(to state: State) {
        past.removeAll()
        future.removeAll()
        transactionOrigin = nil
        present = state
    }

    /// Reverts to the very first state while keeping it undoable.
    public mutating func revertToOriginal() {
        guard let first = past.first else { return }
        commit(first.state, label: "Revert to Original")
    }
}
