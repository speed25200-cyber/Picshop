import Foundation
import PicshopCore

/// D19: the `layers:` state line with stored refs that never renumber (i image, j adjustment and fill, s shape,
/// l text, g group and table bundle), and the single resolver handlers and lines use.
///
/// - A layer's ref is its prefix and its stored `Layer.refNumber` (assigned at creation, never renumbered; a layer
///   without one, from an older build's document, gets the number `PhotoDocument.assignMissingRefNumbers` would give,
///   on a copy). The base photo answers to `i0` and is printed « Photo base ».
/// - Text layers keep the W1/W2 rule: the scene map's `l` id when the map shows the layer (`SceneMap.carryingIDs`
///   keeps them across versions), else the stored number (the next free one when a scene id already has it).
/// - A table bundle (every layer sharing one `LayerGroup.id`) is one `g` entry; its ref names the whole bundle.
/// - The line runs top → bottom; groups bracket their children; flags appear when not default. Over the budget,
///   collapsed groups' children are elided first, then the lowest layers (`… +4`).
public enum LiveLayerLines {
    /// The line's character budget: collapsed groups' children are elided first, then the lowest layers.
    public static let budget = 280
    /// A layer name's longest form on the line.
    static let nameLimit = 24

    // MARK: Refs

    /// Every layer's ref, by layer id (a bundle's members share theirs; a newer build's content has none).
    public static func refs(in document: PhotoDocument, scene: SceneMap?) -> [UUID: String] {
        let numbered = numbered(document)
        let baseID = numbered.baseLayerID
        var sceneIDs: [UUID: String] = [:]
        for block in scene?.texts ?? [] {
            if let layerID = block.layerID, sceneIDs[layerID] == nil { sceneIDs[layerID] = block.id }
        }
        var used = Set(sceneIDs.values)
        var highestText = used.compactMap { Int($0.dropFirst()) }.max() ?? 0
        for layer in numbered.layers where layer.refPrefix == "l" && sceneIDs[layer.id] == nil {
            highestText = max(highestText, layer.refNumber ?? 0)
        }
        var result: [UUID: String] = [:]
        for layer in numbered.layers {
            if layer.id == baseID {
                result[layer.id] = "i0"
                continue
            }
            guard let prefix = layer.refPrefix, let number = layer.refNumber else { continue }
            guard prefix == "l" else {
                result[layer.id] = "\(prefix)\(number)"
                continue
            }
            if let id = sceneIDs[layer.id] {
                result[layer.id] = id
                continue
            }
            var candidate = "l\(number)"
            if used.contains(candidate) {
                highestText += 1
                candidate = "l\(highestText)"
            }
            used.insert(candidate)
            result[layer.id] = candidate
        }
        return result
    }

    /// The ref the line prints for a layer ("i2", "g1", "l3"); nil for a layer this build cannot name.
    public static func ref(of layerID: UUID, in document: PhotoDocument, scene: SceneMap?) -> String? {
        refs(in: document, scene: scene)[layerID]
    }

    /// The layer a ref names (a bundle ref names its topmost member); nil when no layer has it.
    public static func layer(ref: String, in document: PhotoDocument, scene: SceneMap?) -> Layer? {
        guard let ids = layerIDs(ref: ref, in: document, scene: scene), let top = ids.last else { return nil }
        return document.layer(id: top)
    }

    /// Every layer a ref names, bottom → top: one layer, or a table bundle's members; nil when no layer has it.
    public static func layerIDs(ref raw: String, in document: PhotoDocument, scene: SceneMap?) -> [UUID]? {
        guard let wanted = normalized(raw) else { return nil }
        let refs = refs(in: document, scene: scene)
        let ids = document.layers.map(\.id).filter { refs[$0] == wanted }
        if !ids.isEmpty { return ids }
        // A text layer's scene id the map shows but the numbering missed (a hidden one shown again meanwhile).
        if wanted.hasPrefix("l"), let number = Int(wanted.dropFirst()), let id = scene?.block(.layer(number))?.layerID, document.layer(id: id) != nil {
            return [id]
        }
        return nil
    }

    /// "i3", "I3", "#i3", " i 3 " → "i3"; nil for anything else.
    static func normalized(_ raw: String) -> String? {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("#") { key.removeFirst() }
        key = key.replacingOccurrences(of: " ", with: "")
        guard let letter = key.first, "ijslg".contains(letter), let number = Int(key.dropFirst()), number >= 0, number <= 999 else { return nil }
        return "\(letter)\(number)"
    }

    /// The kind of layer a ref letter names.
    static func refKind(of ref: String) -> RefKind? {
        switch ref.first {
        case "i": return .imageLayer
        case "j": return .adjustmentLayer
        case "s": return .shape
        case "l": return .textLayer
        case "g": return .layerGroup
        default: return nil
        }
    }

    /// The refs that exist, in line order (top → bottom), at most about 120 characters: what an unknown ref answer
    /// lists (« i1, i2, j1, g1 »). `kinds` keeps the ones a param accepts.
    public static func existingRefs(in document: PhotoDocument, scene: SceneMap?, kinds: Set<RefKind>? = nil) -> String {
        let refs = refs(in: document, scene: scene)
        var seen: Set<String> = []
        var list = ""
        for layer in document.layers.reversed() {
            guard let ref = refs[layer.id], seen.insert(ref).inserted else { continue }
            if let kinds, let kind = refKind(of: ref), !kinds.contains(kind) { continue }
            let next = list.isEmpty ? ref : ", " + ref
            guard list.count + next.count <= 120 else { return list + ", …" }
            list += next
        }
        return list
    }

    /// The document with every layer numbered (a copy only when some layer has no stored number).
    static func numbered(_ document: PhotoDocument) -> PhotoDocument {
        guard document.layers.contains(where: { $0.refNumber == nil && $0.refPrefix != nil }) else { return document }
        var copy = document
        copy.assignMissingRefNumbers()
        return copy
    }

    // MARK: The line

    /// One top-level row of the line: a layer, a group with its children, or a table bundle.
    struct Entry {
        var text: String
        var children: [String] = []
        var isGroup = false
        var isCollapsed = false
        var childCount = 0

        func rendered(elidingChildren: Bool, language: OpLanguage) -> String {
            guard isGroup else { return text }
            if elidingChildren, childCount > 0 {
                return text + " [\(childCount) \(language == .fr ? (childCount > 1 ? "calques" : "calque") : (childCount > 1 ? "layers" : "layer"))]"
            }
            return text + " [" + children.joined(separator: " | ") + "]"
        }
    }

    /// D19: `layers: l1 "SOLDES" text | g1 Groupe 1 [i2 Tasse 80% multiply clip mask | j1 Courbes] | i1 Logo sel | Photo base`,
    /// at most `budget` characters; nil with only the photo.
    public static func line(for document: PhotoDocument, scene: SceneMap?, language: OpLanguage) -> String? {
        guard document.layers.count > 1 else { return nil }
        let refs = refs(in: document, scene: scene)
        let entries = topLevelEntries(document, refs: refs, language: language)
        guard !entries.isEmpty else { return nil }
        let prefix = "layers: "
        func render(_ kept: [Entry], eliding: (Entry) -> Bool, dropped: Int) -> String {
            var parts = kept.map { $0.rendered(elidingChildren: eliding($0), language: language) }
            if dropped > 0 { parts.append("… +\(dropped)") }
            return prefix + parts.joined(separator: " | ")
        }
        // 1. Everything; 2. collapsed groups' children elided; 3. every group's children elided; 4. the lowest rows dropped.
        var text = render(entries, eliding: { _ in false }, dropped: 0)
        if text.count <= budget { return text }
        text = render(entries, eliding: { $0.isCollapsed }, dropped: 0)
        if text.count <= budget { return text }
        var kept = entries
        var dropped = 0
        text = render(kept, eliding: { $0.isGroup }, dropped: dropped)
        while text.count > budget, kept.count > 1 {
            let last = kept.removeLast()
            dropped += last.isGroup ? last.childCount + 1 : 1
            text = render(kept, eliding: { $0.isGroup }, dropped: dropped)
        }
        return text.count <= budget ? text : String(text.prefix(budget - 1)) + "…"
    }

    /// The rows top → bottom: each top-level layer, each group with its children (top → bottom), each table bundle once
    /// at its topmost member's place.
    static func topLevelEntries(_ document: PhotoDocument, refs: [UUID: String], language: OpLanguage) -> [Entry] {
        let groupIDs = Set(document.layers.filter(\.isGroup).map(\.id))
        let bundles = Dictionary(document.bundles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isChild(_ layer: Layer) -> Bool { layer.parentID.map(groupIDs.contains) ?? false }
        /// The rows of a list of sibling layers (bottom → top), bundles folded at their topmost member.
        func rows(_ layers: [Layer]) -> [(layer: Layer, bundleCount: Int?)] {
            var result: [(layer: Layer, bundleCount: Int?)] = []
            for (index, layer) in layers.enumerated() {
                if let group = layer.group, let bundle = bundles[group.id] {
                    // Only the topmost member of the bundle among these siblings stands for it.
                    let laterMember = layers[(index + 1)...].contains { $0.group?.id == group.id }
                    if laterMember { continue }
                    result.append((layer, bundle.memberIDs.count))
                } else {
                    result.append((layer, nil))
                }
            }
            return result
        }
        var entries: [Entry] = []
        for row in rows(document.layers.filter { !isChild($0) }) {
            let layer = row.layer
            var entry = Entry(text: describe(layer, ref: refs[layer.id], bundleCount: row.bundleCount, document: document, language: language))
            if layer.isGroup {
                let children = rows(document.layers.filter { $0.parentID == layer.id && $0.id != layer.id })
                entry.isGroup = true
                entry.isCollapsed = layer.folder?.isCollapsed ?? false
                entry.childCount = children.reduce(0) { $0 + ($1.bundleCount ?? 1) }
                entry.children = children.reversed().map { describe($0.layer, ref: refs[$0.layer.id], bundleCount: $0.bundleCount, document: document, language: language) }
            }
            entries.append(entry)
        }
        return entries.reversed()
    }

    /// One layer as the line prints it: its ref, its name (a text layer's quoted words), then its flags.
    static func describe(_ layer: Layer, ref: String?, bundleCount: Int?, document: PhotoDocument, language: OpLanguage) -> String {
        let fr = language == .fr
        var words: [String] = []
        if layer.id == document.baseLayerID {
            words.append(fr ? "Photo base" : "Base photo")
        } else if let count = bundleCount, let group = layer.group {
            let kind = group.kind == .tableCells ? (fr ? "Tableau" : "Table") : (fr ? "Surlignage" : "Highlight")
            words.append([ref, "\(kind) \(count) \(fr ? (count > 1 ? "cases" : "case") : (count > 1 ? "cells" : "cell"))"].compactMap { $0 }.joined(separator: " "))
        } else if let element = layer.textElement {
            let said = clean(element.text)
            let quoted = said.count > 20 ? String(said.prefix(19)) + "…" : said
            words.append([ref, "\"\(quoted)\"", "text"].compactMap { $0 }.joined(separator: " "))
        } else {
            let name = clean(layer.name.isEmpty ? defaultName(layer, fr: fr) : layer.name)
            words.append([ref, name.count > nameLimit ? String(name.prefix(nameLimit - 1)) + "…" : name].compactMap { $0 }.joined(separator: " "))
        }
        words += flags(layer, document: document)
        return words.joined(separator: " ")
    }

    /// The flags that are not default: opacity %, fill %, blend mode, clip, mask (off), hidden, locks, sel.
    static func flags(_ layer: Layer, document: PhotoDocument) -> [String] {
        var flags: [String] = []
        if layer.opacity < 0.995 { flags.append("\(Int((layer.opacity * 100).rounded()))%") }
        if layer.fillOpacity < 0.995, !layer.isGroup { flags.append("fill \(Int((layer.fillOpacity * 100).rounded()))%") }
        if layer.blendMode != .normal { flags.append(layer.blendMode.rawValue) }
        if layer.isClipped, !layer.isGroup { flags.append("clip") }
        if layer.mask != nil || (layer.maskStack.map { !$0.isEmpty } ?? false) { flags.append(layer.isMaskEnabled ? "mask" : "mask off") }
        if !layer.isVisible { flags.append("hidden") }
        let lock = layer.ownLock
        if lock.isSuperset(of: .all) {
            flags.append("locked")
        } else {
            if lock.contains(.position) { flags.append("lock pos") }
            if lock.contains(.pixels) { flags.append("lock px") }
            if lock.contains(.transparency) { flags.append("lock alpha") }
        }
        if let selected = document.selectedLayerID, selected == layer.id, layer.id != document.baseLayerID || document.layers.count > 1 {
            flags.append("sel")
        }
        return flags
    }

    /// A layer without a name: its kind, as the panels name it.
    static func defaultName(_ layer: Layer, fr: Bool) -> String {
        switch layer.content {
        case .image: return fr ? "Image" : "Image"
        case .text: return fr ? "Texte" : "Text"
        case .shape: return fr ? "Forme" : "Shape"
        case .adjustment: return layer.recipeKind.map { fr ? $0.frenchName : $0.englishName } ?? (fr ? "Réglage" : "Adjustment")
        case .fill: return fr ? "Remplissage" : "Fill"
        case .gradientFill: return fr ? "Dégradé" : "Gradient"
        case .group: return fr ? "Groupe" : "Group"
        case .unsupported: return fr ? "Calque" : "Layer"
        }
    }

    /// Names never break the line's syntax: no bar, bracket, quote or line break.
    static func clean(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "<", with: "‹")
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
