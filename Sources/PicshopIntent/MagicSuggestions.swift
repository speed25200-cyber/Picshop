import Foundation

/// Which magic tools suit this picture, most useful first — what a retoucher
/// would reach for after one look: a portrait gets the retouch and the soft
/// background, a crowded street the Clean Up, a flat sky a new one.
public enum MagicSuggestions {
    /// Ids used by the photo Magic grid.
    public static let all = ["enhance", "cleanup", "expand", "behind", "retouch", "portrait", "sky", "match", "relight", "cutout", "upscale", "mono"]

    public static func ranked(for scene: SceneDescription?, people: Int? = nil) -> [String] {
        guard let scene else { return all }
        var score: [String: Double] = [:]
        for (index, id) in all.enumerated() { score[id] = Double(all.count - index) * 0.1 }   // the default order breaks ties
        let persons = people ?? scene.people
        let labels = Set(scene.labels)
        func boost(_ id: String, _ amount: Double) { score[id, default: 0] += amount }

        if scene.faces == 1 || persons == 1 {
            boost("retouch", 3); boost("portrait", 2.6); boost("behind", 2.2); boost("relight", 1.5)
        }
        if persons >= 3 { boost("cleanup", 3.2) } else if persons == 2 { boost("cleanup", 1.2); boost("portrait", 1) }
        let outdoor = ["sky", "outdoor", "beach", "mountain", "landscape", "sea", "ocean", "field", "desert", "sunset", "sunrise", "cityscape", "architecture", "skyline", "snow"]
        if !labels.isDisjoint(with: outdoor) { boost("sky", 2.4); boost("expand", 1.6) }
        let product = ["food", "dish", "drink", "product", "shoe", "bag", "watch", "furniture", "car", "vehicle", "bottle", "cup", "jewelry", "clothing"]
        if !labels.isDisjoint(with: product), persons == 0 { boost("cutout", 3); boost("enhance", 1) }
        if !scene.animals.isEmpty { boost("portrait", 1.4); boost("cutout", 1.2) }
        if scene.brightness < 0.3 || scene.brightness > 0.8 { boost("enhance", 2.5); boost("relight", 1) }
        if scene.colourfulness < 0.15 { boost("match", 1.4); boost("mono", 1.2) }
        return all.sorted { (score[$0] ?? 0) > (score[$1] ?? 0) }
    }
}
