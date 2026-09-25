import Foundation

/// What the picture holds, for the model and the executors: text blocks, detected objects and people,
/// the table, and the free areas where something can be written. Canvas space, normalised, top-left
/// origin (D1), the same space as `TextElement.center`.
///
/// The imaging layer builds it once per base state (`PhotoDocument.baseStateKey`), off the main actor,
/// from one text pass shared with the table and erase queries. OCR only reads the base picture, so
/// Picshop's own text layers are laid over it at use time (`overlaying(_:)`).
///
/// Ids are short so a small model can copy them: `t<n>` printed text blocks in reading order,
/// `l<n>` Picshop text layers, `o<n>` objects, `f<n>` free areas. `carryingIDs(from:)` keeps an id on
/// the same thing from one version to the next.
public struct SceneMap: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        case photo, screenshot, document, table
    }

    /// Size classes the model reads instead of numbers ("t3 … body dark").
    public enum SizeClass: String, Hashable, Codable, Sendable, CaseIterable {
        case tiny, small, body, large, title

        /// From a font size as a fraction of the canvas height.
        public init(relativeSize: Double) {
            switch relativeSize {
            case ..<0.012: self = .tiny
            case ..<0.022: self = .small
            case ..<0.04: self = .body
            case ..<0.08: self = .large
            default: self = .title
            }
        }

        /// The font size a new text of this class gets (fraction of the canvas height).
        public var relativeSize: Double {
            switch self {
            case .tiny: return 0.01
            case .small: return 0.017
            case .body: return 0.028
            case .large: return 0.055
            case .title: return 0.09
            }
        }
    }

    public struct TextBlock: Hashable, Codable, Sendable, Identifiable {
        public enum Source: Hashable, Codable, Sendable {
            /// Pixels of the picture, read by OCR.
            case printed
            /// A Picshop text layer.
            case layer(UUID)
        }

        public enum Role: String, Hashable, Codable, Sendable, CaseIterable {
            case title, heading, body, caption, tableHeader, tableLabel, tableCell
        }

        /// "t3" (printed) or "l2" (layer).
        public var id: String
        public var text: String
        /// Normalised, top-left origin.
        public var box: PSRect
        public var lineCount: Int
        /// Printed words, for a tight erase that spares rules and backgrounds; [] for a layer.
        public var wordBoxes: [PSRect]
        /// Measured typography (size, colour, weight, design, alignment); nil when it could not be read.
        public var style: TableGrid.Style?
        public var role: Role
        public var source: Source
        public var confidence: Double

        public init(id: String, text: String, box: PSRect, lineCount: Int = 1, wordBoxes: [PSRect] = [], style: TableGrid.Style? = nil,
                    role: Role = .body, source: Source = .printed, confidence: Double = 1) {
            self.id = id
            self.text = text
            self.box = box
            self.lineCount = lineCount
            self.wordBoxes = wordBoxes
            self.style = style
            self.role = role
            self.source = source
            self.confidence = confidence
        }

        public var isLayer: Bool {
            if case .layer = source { return true }
            return false
        }

        public var layerID: UUID? {
            if case .layer(let id) = source { return id }
            return nil
        }

        /// From the measured size, else from the box height per line.
        public var sizeClass: SizeClass {
            SizeClass(relativeSize: style?.relativeSize ?? (box.height / Double(max(1, lineCount))) * 0.75)
        }

        /// "dark", "light", or a colour name ("red", "blue"…) when the text is clearly coloured; nil unmeasured.
        public var colorClass: String? { style.map { SceneMap.colorClass(of: $0.color) } }
    }

    public struct Object: Hashable, Codable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Codable, Sendable, CaseIterable { case person, face, animal, object }

        /// "o1".
        public var id: String
        /// Canonical English label ("person", "dog"); for the model only, never spoken in French.
        public var label: String
        public var box: PSRect
        public var confidence: Double
        public var kind: Kind

        public init(id: String, label: String, box: PSRect, confidence: Double, kind: Kind = .object) {
            self.id = id
            self.label = label
            self.box = box
            self.confidence = confidence
            self.kind = kind
        }
    }

    /// A flat stretch with no text and no object, where new text reads well.
    public struct FreeArea: Hashable, Codable, Sendable, Identifiable {
        /// "f1".
        public var id: String
        public var box: PSRect
        /// Mean colour behind it, to choose a readable text colour.
        public var background: PSColor?
        /// Flat colour (a text box can go there without a backdrop).
        public var isUniform: Bool

        public init(id: String, box: PSRect, background: PSColor? = nil, isUniform: Bool = true) {
            self.id = id
            self.box = box
            self.background = background
            self.isUniform = isUniform
        }
    }

    /// `PhotoDocument.baseStateKey` of the analysed state.
    public var stateKey: String
    public var canvasSize: PSSize
    public var kind: Kind
    /// Reading order: top to bottom, then left to right.
    public var texts: [TextBlock]
    public var objects: [Object]
    /// The main table (D2), as `tableGrid(in:remembered:)` returns it.
    public var table: TableGrid?
    public var freeAreas: [FreeArea]
    /// Dominant colour of the picture.
    public var background: PSColor?

    public init(stateKey: String, canvasSize: PSSize, kind: Kind = .photo, texts: [TextBlock] = [], objects: [Object] = [],
                table: TableGrid? = nil, freeAreas: [FreeArea] = [], background: PSColor? = nil) {
        self.stateKey = stateKey
        self.canvasSize = canvasSize
        self.kind = kind
        self.texts = texts
        self.objects = objects
        self.table = table
        self.freeAreas = freeAreas
        self.background = background
    }

    public var isEmpty: Bool { texts.isEmpty && objects.isEmpty && table == nil }

    // MARK: Lookup

    public func text(id: String) -> TextBlock? {
        let key = id.lowercased()
        return texts.first { $0.id == key }
    }

    public func object(id: String) -> Object? {
        let key = id.lowercased()
        return objects.first { $0.id == key }
    }

    public func freeArea(id: String) -> FreeArea? {
        let key = id.lowercased()
        return freeAreas.first { $0.id == key }
    }

    /// The text block a reference names (`t` or `l`), nil when it is not in this map.
    public func block(_ ref: SceneRef) -> TextBlock? {
        switch ref {
        case .text, .layer: return text(id: ref.id)
        case .object, .area: return nil
        }
    }

    /// The box a reference names, whatever its kind.
    public func box(_ ref: SceneRef) -> PSRect? {
        switch ref {
        case .text, .layer: return block(ref)?.box
        case .object: return object(id: ref.id)?.box
        case .area: return freeArea(id: ref.id)?.box
        }
    }

    /// "le titre": the block marked title, else the largest text in the top third.
    public var title: TextBlock? {
        if let marked = texts.first(where: { $0.role == .title }) { return marked }
        return texts.filter { $0.box.midY < 0.34 }.max { ($0.style?.relativeSize ?? $0.box.height) < ($1.style?.relativeSize ?? $1.box.height) }
    }

    /// Blocks whose text contains the phrase (case, accents and punctuation folded), best match first.
    public func texts(matching phrase: String) -> [TextBlock] {
        let wanted = Self.folded(phrase)
        guard !wanted.isEmpty else { return [] }
        let exact = texts.filter { Self.folded($0.text) == wanted }
        let containing = texts.filter { Self.folded($0.text) != wanted && Self.folded($0.text).contains(wanted) }
        return exact + containing
    }

    /// The text block closest to a point (centre distance; a block containing it wins).
    public func nearestText(to point: PSPoint) -> TextBlock? {
        if let inside = texts.first(where: { $0.box.contains(point) }) { return inside }
        return texts.min { $0.box.center.distance(to: point) < $1.box.center.distance(to: point) }
    }

    /// Typography of the nearest measured printed text: "in the same style as the text around it".
    public func style(near box: PSRect) -> TableGrid.Style? {
        texts.filter { $0.style != nil }
            .min { $0.box.center.distance(to: box.center) < $1.box.center.distance(to: box.center) }?
            .style
    }

    // MARK: Layers and versions

    /// Picshop text layers (ungrouped, visible) added as `l<n>` blocks, in document order; table-cell
    /// layers stay in the table. A layer's box is estimated from its font size and text length. A layer
    /// this map already shows keeps its id, so overlaying an overlaid map again changes no id; new
    /// layers are numbered after the highest `l` id.
    public func overlaying(_ layers: [Layer]) -> SceneMap {
        var map = self
        var known: [UUID: String] = [:]
        for block in texts { if let id = block.layerID, known[id] == nil { known[id] = block.id } }
        map.texts.removeAll { $0.isLayer }
        var next = known.values.compactMap { Self.number(of: $0, prefix: "l") }.max() ?? 0
        for layer in layers where layer.group == nil && layer.isVisible {
            guard let element = layer.textElement, !element.text.isEmpty else { continue }
            let id: String
            if let existing = known[layer.id] {
                id = existing
            } else {
                next += 1
                id = "l\(next)"
            }
            let lines = max(1, element.text.split(separator: "\n", omittingEmptySubsequences: false).count)
            let box = element.estimatedBox(canvasSize: canvasSize)
            let style = TableGrid.Style(relativeSize: element.relativeSize, color: element.color, weight: Self.weight(ofFontNamed: element.fontName),
                                        design: Self.design(ofFontNamed: element.fontName), alignment: element.alignment)
            map.texts.append(TextBlock(id: id, text: element.text, box: box, lineCount: lines, style: style, role: .body,
                                       source: .layer(layer.id)))
        }
        return map
    }

    /// The same map with the ids of `previous` kept on the blocks and objects that are still there, so
    /// "t3" keeps meaning the same thing across versions:
    /// - a layer block keeps the id of the same layer;
    /// - a printed block keeps the id of the block with the same text over about the same place
    ///   (IoU ≥ 0.3), or of a block right where it was (IoU ≥ 0.6) when OCR read it a little differently;
    /// - an object keeps the id of one with the same label (IoU ≥ 0.4), a free area one it overlaps (IoU ≥ 0.4).
    /// Everything else is numbered after the highest id of its kind in either map, in reading order.
    public func carryingIDs(from previous: SceneMap) -> SceneMap {
        var map = self

        // Text blocks.
        var textIDs = [String?](repeating: nil, count: texts.count)
        var used = Set<String>()
        for (index, block) in texts.enumerated() {
            guard let layerID = block.layerID, let old = previous.texts.first(where: { $0.layerID == layerID }), !used.contains(old.id) else { continue }
            textIDs[index] = old.id
            used.insert(old.id)
        }
        var pairs: [(new: Int, old: String, score: Double)] = []
        for (index, block) in texts.enumerated() where !block.isLayer {
            let folded = Self.folded(block.text)
            for old in previous.texts where !old.isLayer {
                let overlap = block.box.iou(old.box)
                if folded == Self.folded(old.text), overlap >= 0.3 { pairs.append((index, old.id, 1 + overlap)) }
                else if overlap >= 0.6 { pairs.append((index, old.id, overlap)) }
            }
        }
        for pair in pairs.sorted(by: { $0.score > $1.score }) where textIDs[pair.new] == nil && !used.contains(pair.old) {
            textIDs[pair.new] = pair.old
            used.insert(pair.old)
        }
        var nextText = (previous.texts.map(\.id) + textIDs.compactMap { $0 }).compactMap { Self.number(of: $0, prefix: "t") }.max() ?? 0
        var nextLayer = (previous.texts.map(\.id) + textIDs.compactMap { $0 }).compactMap { Self.number(of: $0, prefix: "l") }.max() ?? 0
        for index in texts.indices {
            if let id = textIDs[index] {
                map.texts[index].id = id
            } else if texts[index].isLayer {
                nextLayer += 1
                map.texts[index].id = "l\(nextLayer)"
            } else {
                nextText += 1
                map.texts[index].id = "t\(nextText)"
            }
        }

        // Objects.
        var objectIDs = [String?](repeating: nil, count: objects.count)
        var usedObjects = Set<String>()
        var objectPairs: [(new: Int, old: String, score: Double)] = []
        for (index, object) in objects.enumerated() {
            for old in previous.objects where old.label == object.label {
                let overlap = object.box.iou(old.box)
                if overlap >= 0.4 { objectPairs.append((index, old.id, overlap)) }
            }
        }
        for pair in objectPairs.sorted(by: { $0.score > $1.score }) where objectIDs[pair.new] == nil && !usedObjects.contains(pair.old) {
            objectIDs[pair.new] = pair.old
            usedObjects.insert(pair.old)
        }
        var nextObject = (previous.objects.map(\.id) + objectIDs.compactMap { $0 }).compactMap { Self.number(of: $0, prefix: "o") }.max() ?? 0
        for index in objects.indices {
            if let id = objectIDs[index] { map.objects[index].id = id } else { nextObject += 1; map.objects[index].id = "o\(nextObject)" }
        }

        // Free areas.
        var areaIDs = [String?](repeating: nil, count: freeAreas.count)
        var usedAreas = Set<String>()
        for (index, area) in freeAreas.enumerated() {
            if let old = previous.freeAreas.filter({ !usedAreas.contains($0.id) && $0.box.iou(area.box) >= 0.4 }).max(by: { $0.box.iou(area.box) < $1.box.iou(area.box) }) {
                areaIDs[index] = old.id
                usedAreas.insert(old.id)
            }
        }
        var nextArea = (previous.freeAreas.map(\.id) + areaIDs.compactMap { $0 }).compactMap { Self.number(of: $0, prefix: "f") }.max() ?? 0
        for index in freeAreas.indices {
            if let id = areaIDs[index] { map.freeAreas[index].id = id } else { nextArea += 1; map.freeAreas[index].id = "f\(nextArea)" }
        }
        return map
    }

    /// 3 for "t3" with prefix "t"; nil for another kind.
    static func number(of id: String, prefix: Character) -> Int? {
        guard id.first == prefix else { return nil }
        return Int(id.dropFirst())
    }

    // MARK: Helpers

    /// Lower case, no accents, punctuation as spaces, single spaces.
    public static func folded(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let spaced = String(lowered.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// "dark", "light", or a colour name for a clearly coloured text.
    public static func colorClass(of color: PSColor) -> String {
        let maxC = max(color.red, color.green, color.blue), minC = min(color.red, color.green, color.blue)
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        if saturation < 0.25 || maxC < 0.2 {
            if color.luminance < 0.35 { return "dark" }
            if color.luminance > 0.75 { return "light" }
            return "gray"
        }
        let named: [(String, PSColor)] = [("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("blue", .blue),
                                          ("purple", .purple), ("pink", .pink), ("teal", .teal), ("brown", .brown)]
        func distance(_ a: PSColor, _ b: PSColor) -> Double {
            let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
            return dr * dr + dg * dg + db * db
        }
        return named.min { distance($0.1, color) < distance($1.1, color) }?.0 ?? "dark"
    }

    /// The weight a font name carries in the D5 grammar ("SFProDigits-Semibold" -> semibold).
    public static func weight(ofFontNamed name: String) -> TableGrid.FontWeight {
        let face = name.split(separator: "-").last.map { $0.lowercased() } ?? ""
        if face.contains("semibold") { return .semibold }
        if face.contains("bold") || face.contains("black") || face.contains("heavy") { return .bold }
        if face.contains("medium") { return .medium }
        return .regular
    }

    /// The design a font name carries in the D5 grammar ("SFMono-Regular" -> mono).
    public static func design(ofFontNamed name: String) -> TableGrid.FontDesign {
        let family = name.split(separator: "-").first.map { $0.lowercased() } ?? ""
        if family.contains("mono") { return .mono }
        if family.contains("serif") || family.contains("newyork") { return .serif }
        if family.contains("rounded") { return .rounded }
        return .sans
    }
}
