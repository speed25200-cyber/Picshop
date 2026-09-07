import Foundation
import PicshopCore

/// Applies the user's words ("the one on the left", "the second", "all") to a
/// ranked list of detected objects. Pure logic, unit-tested on every platform.
public enum CandidateSelector {
    public enum Selection: Equatable, Sendable {
        case single(ObjectCandidate)
        case multiple([ObjectCandidate])
        case ambiguous([ObjectCandidate])
        case none
    }

    /// Minimum confidence for a candidate to count as a match at all.
    public static let minimumConfidence = 0.18
    /// Score margin (top vs. runner-up) at which we stop asking the user.
    public static let decisiveMargin = 0.28
    /// Maximum options offered when asking the user.
    public static let maximumOptions = 4

    public static func select(from candidates: [ObjectCandidate], for target: ObjectTarget) -> Selection {
        var pool = candidates.filter { $0.confidence >= minimumConfidence }.sorted { $0.confidence > $1.confidence }
        guard !pool.isEmpty else { return .none }

        if let point = target.point {
            let containing = pool.filter { $0.boundingBox.contains(point) }
            if let best = containing.min(by: { $0.boundingBox.area < $1.boundingBox.area }) { return .single(best) }
            if let nearest = pool.min(by: { $0.boundingBox.center.distance(to: point) < $1.boundingBox.center.distance(to: point) }),
               nearest.boundingBox.center.distance(to: point) < 0.25 {
                return .single(nearest)
            }
        }

        if target.matchesAll {
            let strong = pool.filter { $0.confidence >= max(minimumConfidence, pool[0].confidence * 0.35) }
            return strong.count == 1 ? .single(strong[0]) : .multiple(strong)
        }

        if let hint = target.spatialHint {
            pool = applied(hint, to: pool)
            if pool.count == 1 { return .single(pool[0]) }
        }

        if let ordinal = target.ordinal {
            let ordered = pool.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
            let index = ordinal == -1 ? ordered.count - 1 : ordinal - 1
            if index >= 0, index < ordered.count { return .single(ordered[index]) }
        }

        if pool.count == 1 { return .single(pool[0]) }
        let top = pool[0]
        let second = pool[1]
        if top.confidence - second.confidence >= decisiveMargin, target.spatialHint == nil {
            return .single(top)
        }
        // Same label, similar confidence: ask.
        return .ambiguous(Array(pool.prefix(maximumOptions)))
    }

    /// Narrows candidates by a spatial hint. Returns the best-matching subset
    /// (ideally one element) while keeping the original ordering by confidence.
    public static func applied(_ hint: SpatialHint, to candidates: [ObjectCandidate]) -> [ObjectCandidate] {
        guard candidates.count > 1 else { return candidates }
        func pick(_ key: (ObjectCandidate) -> Double, ascending: Bool, relative: Bool = false) -> [ObjectCandidate] {
            let sorted = candidates.sorted { ascending ? key($0) < key($1) : key($0) > key($1) }
            guard let best = sorted.first else { return candidates }
            // Keep others that are within a small tolerance so genuine ties stay ambiguous.
            let close = sorted.filter { candidate in
                let difference = abs(key(candidate) - key(best))
                return relative ? difference <= abs(key(best)) * 0.12 : difference <= 0.06
            }
            return close
        }
        switch hint {
        case .left, .leftmost:
            return pick({ $0.boundingBox.midX }, ascending: true)
        case .right, .rightmost:
            return pick({ $0.boundingBox.midX }, ascending: false)
        case .top:
            return pick({ $0.boundingBox.midY }, ascending: true)
        case .bottom, .nearest:
            return pick({ $0.boundingBox.midY }, ascending: false)
        case .farthest:
            return pick({ $0.boundingBox.area }, ascending: true, relative: true)
        case .center:
            return pick({ $0.boundingBox.center.distance(to: PSPoint(x: 0.5, y: 0.5)) }, ascending: true)
        case .largest, .foreground:
            return pick({ $0.boundingBox.area }, ascending: false, relative: true)
        case .smallest, .background:
            return pick({ $0.boundingBox.area }, ascending: true, relative: true)
        }
    }

    /// Builds the question to ask the user, in their language.
    public static func question(for target: ObjectTarget, options: [ObjectCandidate], language: NormalizedUtterance.Language) -> String {
        let count = options.count
        let noun = target.originalPhrase
        switch language {
        case .french:
            return "J'ai trouvé \(count) \(count > 1 ? "correspondances" : "correspondance") pour « \(noun) ». Laquelle ? (par ex. « celle de gauche », « la deuxième », « toutes »)"
        case .english:
            return "I found \(count) \(count > 1 ? "matches" : "match") for “\(noun)”. Which one? (say “the left one”, “the second”, or “all”)"
        }
    }
}
