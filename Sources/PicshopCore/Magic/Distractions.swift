import Foundation

/// What spoils a photo without being its point: the passers-by, the
/// photobomber at the edge, the small figures behind the people it is of.
/// Apple Photos calls the fix Clean Up; this is the choice of what to clean.
public enum DistractionFinder {
    /// People who are not the subject. The subject is the largest person and
    /// anyone as prominent standing with them; the rest — much smaller, apart
    /// from them, or cut by the frame's edge — are distractions. A photo
    /// without a clear subject (a street, a landscape) loses only its smallest figures.
    public static func distractions(among people: [ObjectCandidate]) -> [ObjectCandidate] {
        guard let main = people.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return [] }
        let mainArea = main.boundingBox.area
        let hasSubject = mainArea > 0.04
        return people.filter { person in
            guard person.id != main.id else { return false }
            let area = person.boundingBox.area
            if !hasSubject { return area < 0.01 }
            // Standing with the subject, about as big: part of the picture.
            let together = person.boundingBox.insetBy(dx: -0.05, dy: -0.05).intersection(main.boundingBox).area > 0
            if area > mainArea * 0.45 { return false }
            if together, area > mainArea * 0.2 { return false }
            let box = person.boundingBox
            let cutByEdge = box.minX < 0.01 || box.maxX > 0.99
            return area < mainArea * 0.3 || (cutByEdge && area < mainArea * 0.6)
        }
    }
}
