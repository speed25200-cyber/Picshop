#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopCore

/// Named styles: the tonal recipe of a photo (adjustments, look, tone curve,
/// detail) saved by voice and replayable on any other photo. The style of the
/// last edited photo is always kept as "last".
@MainActor
@Observable
public final class StyleLibrary {
    public struct Style: Codable, Hashable, Identifiable, Sendable {
        public var name: String
        public var operations: [EditOperation.Kind]
        public var savedAt: Date
        public var id: String { name.lowercased() }
    }

    public static let lastName = "last"
    private let defaults = UserDefaults.standard
    private let key = "picshop.styles"
    public private(set) var styles: [Style] = []

    public init() {
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([Style].self, from: data) {
            styles = decoded
        }
    }

    /// The operations of a stack that make up its "style" (no geometry, no masks, no generated pixels).
    public static func recipe(from stack: EditStack) -> [EditOperation.Kind] {
        stack.operations.map(\.kind).filter { kind in
            switch kind {
            case .adjust, .adjustments, .toneCurve, .look, .autoEnhance, .denoise, .sharpen, .relight: return true
            default: return false
            }
        }
    }

    public func style(named name: String) -> Style? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        return styles.first { $0.id == wanted } ?? styles.first { $0.id.contains(wanted) || wanted.contains($0.id) }
    }

    /// Saves (or replaces) a style. Returns false when the stack has no tonal edits.
    @discardableResult
    public func save(_ operations: [EditOperation.Kind], as name: String) -> Bool {
        guard !operations.isEmpty else { return false }
        let clean = name.trimmingCharacters(in: .whitespaces)
        styles.removeAll { $0.id == clean.lowercased() }
        styles.append(Style(name: clean, operations: operations, savedAt: Date()))
        persist()
        return true
    }

    /// Remembers the style of the photo just edited, for "the same look as the last photo".
    public func rememberLast(_ operations: [EditOperation.Kind]) {
        guard !operations.isEmpty else { return }
        save(operations, as: StyleLibrary.lastName)
    }

    public func delete(named name: String) {
        styles.removeAll { $0.id == name.lowercased() }
        persist()
    }

    /// Styles the user named (the automatic "last" one excluded).
    public var named: [Style] { styles.filter { $0.id != StyleLibrary.lastName }.sorted { $0.savedAt > $1.savedAt } }

    private func persist() {
        if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: key) }
    }
}
#endif
