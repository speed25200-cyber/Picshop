import Foundation

/// How a title comes on screen. Each is a complete, tasteful move — the
/// timing and the curves are chosen, so nobody has to keyframe a title.
public enum TextAnimation: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Springs up from smaller, overshooting a touch.
    case pop
    /// Rises into place as it fades in.
    case rise
    /// Revealed left to right behind a soft edge.
    case wipe
    /// Comes into focus from a blur.
    case focus
    /// Grows very slowly for as long as it is on screen.
    case drift

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pop: return "Pop"
        case .rise: return "Rise"
        case .wipe: return "Wipe"
        case .focus: return "Focus"
        case .drift: return "Drift"
        }
    }

    public var frenchName: String {
        switch self {
        case .pop: return "Pop"
        case .rise: return "Montée"
        case .wipe: return "Balayage"
        case .focus: return "Mise au point"
        case .drift: return "Dérive"
        }
    }

    /// How long the entrance lasts.
    public var entrance: Double {
        switch self {
        case .pop: return 0.5
        case .rise: return 0.6
        case .wipe: return 0.7
        case .focus: return 0.6
        case .drift: return 0
        }
    }

    /// What the renderer applies to the title at one instant.
    public struct State: Equatable, Sendable {
        /// Scale around the title's centre.
        public var scale: Double = 1
        /// Horizontal shift as a fraction of the frame width (positive = right).
        public var offsetX: Double = 0
        /// Vertical shift as a fraction of the frame height (positive = lower).
        public var offsetY: Double = 0
        /// 0 sharp … 1 fully blurred.
        public var blur: Double = 0
        /// How much of the title is revealed, left to right (1 = all).
        public var reveal: Double = 1
        /// Multiplies the overlay's own opacity.
        public var opacity: Double = 1

        public init() {}
        public static let rest = State()
    }

    public func state(at time: Double, span: TimeSpan) -> State {
        var state = State()
        let elapsed = time - span.start
        if self == .drift {
            let t = (elapsed / max(0.1, span.duration)).clamped(to: 0...1)
            state.scale = 1 + 0.07 * t
            return state
        }
        let p = (elapsed / entrance).clamped(to: 0...1)
        guard p < 1 else { return state }
        switch self {
        case .pop:
            state.scale = 0.6 + 0.4 * Self.easeOutBack(p)
            state.opacity = min(1, p * 2.5)
        case .rise:
            state.offsetY = 0.045 * (1 - Self.easeOutCubic(p))
            state.opacity = Self.easeOutCubic(p)
        case .wipe:
            state.reveal = Self.easeInOut(p)
        case .focus:
            state.blur = 1 - Self.easeOutCubic(p)
            state.scale = 1.06 - 0.06 * Self.easeOutCubic(p)
            state.opacity = min(1, p * 1.6)
        case .drift:
            break
        }
        return state
    }

    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    /// Overshoots to about 1.1 and settles, like a spring.
    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    public static func matching(_ text: String) -> TextAnimation? {
        let query = text.normalizedForMatching
        let aliases: [(TextAnimation, [String])] = [
            (.pop, ["pop", "rebond", "bounce", "spring", "ressort"]),
            (.rise, ["rise", "monte", "montee", "slide up", "glisse", "from below", "par le bas"]),
            (.wipe, ["wipe", "balayage", "reveal", "revele", "devoile", "typewriter", "machine a ecrire"]),
            (.focus, ["focus", "mise au point", "flou", "blur", "net"]),
            (.drift, ["drift", "derive", "lent", "slow zoom", "zoom lent", "ken burns"]),
        ]
        for (animation, words) in aliases where words.contains(where: { query.contains($0) }) { return animation }
        return nil
    }
}
