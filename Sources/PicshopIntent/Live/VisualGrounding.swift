import Foundation
import PicshopCore

/// A vision-language model that finds what a phrase names in a picture (W2, D13): the fallback when Vision's
/// candidates miss « la tasse bleue ». One short generation per call; no networking, ever.
public protocol VisualGrounder: Sendable {
    /// The box (normalised, top-left) of what `phrase` names in the picture, nil when absent: one short generation.
    func box(for phrase: String, imageJPEG: Data, language: NormalizedUtterance.Language) async -> PSRect?
}

/// The grounder the app installed (M5: when a vision-capable local model is ready; nil on release). Nil in
/// tests and on hosts without one, and then `groundBox` answers nil.
public enum VisualGrounding {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var grounder: (any VisualGrounder)?
    }

    private static let box = Box()

    public static var current: (any VisualGrounder)? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.grounder
    }

    public static func install(_ grounder: (any VisualGrounder)?) {
        box.lock.lock()
        box.grounder = grounder
        box.lock.unlock()
    }
}
