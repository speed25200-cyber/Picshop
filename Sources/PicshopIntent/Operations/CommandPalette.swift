import Foundation
import PicshopCore

/// One suggestion of the command palette (W2, D16): a tool to open, or an operation ready to run.
public struct PaletteMatch: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        /// A PhotoEditorSession.Tool raw value, or a video or PDF panel id.
        case tool(String)
        case operation(OperationCall)
    }

    public var id: String
    public var title: String
    /// An SF Symbol name.
    public var symbol: String?
    public var target: Target
    public var score: Double

    public init(id: String, title: String, symbol: String? = nil, target: Target, score: Double) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.target = target
        self.score = score
    }
}

/// The Ask field's suggestions: tools and ready-to-run operations matching a few typed words. Suggestions
/// only: Return always sends the sentence to Live or the planner.
public enum CommandPalette {
    public static let maxWords = 4
    public static let maxCharacters = 32
    public static let threshold = 0.55

    /// ≤4 words, ≤32 chars, not a question.
    public static func shouldSuggest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCharacters else { return false }
        guard trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" }).count <= maxWords else { return false }
        return !OperationIndex.isQuestion(trimmed)
    }

    /// The best `limit` entries scoring at least 0.55, best first (tools before operations on a tie).
    public static func matches(_ text: String, domain: OpDomain, language: OpLanguage, limit: Int = 3) -> [PaletteMatch] {
        guard shouldSuggest(text), limit > 0 else { return [] }
        let query = Folded(text)
        guard !query.text.isEmpty else { return [] }
        var scored: [(match: PaletteMatch, order: Int)] = []
        for (order, entry) in entries(domain: domain, language: language).enumerated() {
            let best = entry.names.map { Self.score(query, Folded($0)) }.max() ?? 0
            guard best >= threshold else { continue }
            scored.append((PaletteMatch(id: entry.id, title: entry.title, symbol: entry.symbol, target: entry.target, score: (best * 1_000).rounded() / 1_000),
                           order))
        }
        scored.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.order < $1.order }
        var seen: Set<String> = []
        return scored.map(\.match).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    // MARK: Scoring

    /// Folded text (lower case, no accents, no elision) and its content tokens.
    struct Folded {
        let text: String
        let tokens: [String]

        init(_ raw: String) {
            let all = TextFolding.tokens(raw)
            text = all.joined(separator: " ")
            let content = all.filter { !TextFolding.stopwords.contains($0) }
            tokens = content.isEmpty ? all : content
        }
    }

    /// (3 × prefix + Jaccard + trigram) / 5, in 0…1.
    static func score(_ query: Folded, _ name: Folded) -> Double {
        guard !query.tokens.isEmpty, !name.tokens.isEmpty else { return 0 }
        return (3 * prefix(query, name) + jaccard(Set(query.tokens), Set(name.tokens)) + jaccard(trigrams(query.text), trigrams(name.text))) / 5
    }

    /// 1 when the name starts with the words typed; else the share of typed words that start a word of the name
    /// (« inverse la sél » → « Inverser la sélection »).
    static func prefix(_ query: Folded, _ name: Folded) -> Double {
        if name.text.hasPrefix(query.text) { return 1 }
        let hits = query.tokens.filter { typed in name.tokens.contains { $0.hasPrefix(typed) } }.count
        return Double(hits) / Double(query.tokens.count)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    static func trigrams(_ text: String) -> Set<String> {
        let padded = Array(" " + text + " ")
        guard padded.count >= 3 else { return [String(padded)] }
        return Set((0...(padded.count - 3)).map { String(padded[$0..<($0 + 3)]) })
    }

    // MARK: Entries

    struct Entry {
        var id: String
        var title: String
        var symbol: String?
        var target: PaletteMatch.Target
        /// Every name the entry answers to: its titles, synonyms and its catalog operations' titles.
        var names: [String]
    }

    /// A tool's titles, symbol and synonyms.
    struct ToolInfo {
        var fr: String
        var en: String
        var symbol: String
        var synonyms: [String]
    }

    /// The photo editor's tools (PhotoEditorSession.Tool raw values), in the tool rail's order.
    public static let photoTools = ["magic", "focus", "adjust", "looks", "color", "erase", "precise", "cutout", "crop", "text", "shapes", "layers",
                                    "curves", "levels", "masks", "select"]

    static let tools: [String: ToolInfo] = [
        "magic": ToolInfo(fr: "Magie", en: "Magic", symbol: "wand.and.stars", synonyms: ["auto", "amélioration auto", "auto enhance", "ia", "ai"]),
        "focus": ToolInfo(fr: "Mise au point", en: "Focus", symbol: "camera.aperture", synonyms: ["flou", "portrait", "bokeh", "blur", "depth"]),
        "adjust": ToolInfo(fr: "Réglages", en: "Adjust", symbol: "slider.horizontal.3",
                           synonyms: ["lumière", "exposition", "contraste", "saturation", "light", "exposure", "contrast"]),
        "looks": ToolInfo(fr: "Filtres", en: "Filters", symbol: "camera.filters", synonyms: ["look", "looks", "lut", "preset", "filtre"]),
        "color": ToolInfo(fr: "Couleur", en: "Colour", symbol: "paintpalette",
                          synonyms: ["couleurs", "teinte", "hsl", "étalonnage", "color", "hue", "grading", "colour grade"]),
        "erase": ToolInfo(fr: "Effacer", en: "Erase", symbol: "eraser", synonyms: ["gomme", "nettoyer", "enlever", "clean up", "remove"]),
        "precise": ToolInfo(fr: "Précis", en: "Precise", symbol: "pencil.tip", synonyms: ["retouche", "retouche précise", "retouch"]),
        "cutout": ToolInfo(fr: "Détourage", en: "Cutout", symbol: "person.crop.rectangle", synonyms: ["détourer", "fond", "background", "cut out"]),
        "crop": ToolInfo(fr: "Recadrer", en: "Crop", symbol: "crop", synonyms: ["rogner", "format", "rotation", "redresser", "rotate", "straighten"]),
        "text": ToolInfo(fr: "Texte", en: "Text", symbol: "textformat", synonyms: ["titre", "écrire", "title", "write"]),
        "shapes": ToolInfo(fr: "Formes", en: "Shapes", symbol: "square.on.circle", synonyms: ["forme", "rectangle", "cercle", "shape", "circle"]),
        "layers": ToolInfo(fr: "Calques", en: "Layers", symbol: "square.3.layers.3d", synonyms: ["calque", "opacité", "layer", "opacity", "blend"]),
        "curves": ToolInfo(fr: "Courbes", en: "Curves", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                           synonyms: ["courbe", "courbe en s", "curve", "s curve", "tone curve"]),
        "levels": ToolInfo(fr: "Niveaux", en: "Levels", symbol: "chart.bar", synonyms: ["niveau", "point noir", "point blanc", "black point", "white point"]),
        "masks": ToolInfo(fr: "Masques", en: "Masks", symbol: "circle.lefthalf.filled",
                          synonyms: ["masque", "dégradé", "filtre radial", "réglage local", "mask", "gradient", "radial filter", "local adjustment"]),
        "select": ToolInfo(fr: "Sélection", en: "Selection", symbol: "lasso",
                           synonyms: ["sélectionner", "lasso", "baguette magique", "sélection rapide", "select", "magic wand", "quick selection"]),
        // Video and PDF panels (catalog uiTool ids).
        "audio": ToolInfo(fr: "Audio", en: "Audio", symbol: "waveform", synonyms: ["son", "musique", "volume", "sound", "music"]),
        "cut": ToolInfo(fr: "Montage", en: "Edit", symbol: "scissors", synonyms: ["couper", "découper", "clip", "cut", "trim", "split"]),
        "speed": ToolInfo(fr: "Vitesse", en: "Speed", symbol: "gauge.with.dots.needle.67percent", synonyms: ["ralenti", "accéléré", "slow motion"]),
        "transitions": ToolInfo(fr: "Transitions", en: "Transitions", symbol: "rectangle.2.swap", synonyms: ["transition", "fondu", "fade"]),
        "transcript": ToolInfo(fr: "Transcription", en: "Transcript", symbol: "text.bubble", synonyms: ["sous-titres", "captions", "subtitles"]),
        "motion": ToolInfo(fr: "Mouvement", en: "Motion", symbol: "move.3d", synonyms: ["zoom", "suivi", "tracking", "ken burns"]),
        "overlay": ToolInfo(fr: "Incrustation", en: "Overlay", symbol: "rectangle.inset.filled", synonyms: ["incruster", "pip", "picture in picture"]),
        "frame": ToolInfo(fr: "Cadre", en: "Frame", symbol: "rectangle.dashed", synonyms: ["image fixe", "freeze", "capture"]),
        "pages": ToolInfo(fr: "Pages", en: "Pages", symbol: "doc.on.doc", synonyms: ["page", "organiser", "organize"]),
        "highlight": ToolInfo(fr: "Surligner", en: "Highlight", symbol: "highlighter", synonyms: ["surligneur", "souligner", "underline"]),
        "redact": ToolInfo(fr: "Caviarder", en: "Redact", symbol: "rectangle.fill", synonyms: ["masquer le texte", "noircir", "black out"]),
        "signature": ToolInfo(fr: "Signature", en: "Signature", symbol: "signature", synonyms: ["signer", "sign"]),
        "image": ToolInfo(fr: "Image", en: "Image", symbol: "photo", synonyms: ["photo", "insérer une image", "insert image"]),
    ]

    /// Operations a few words can run as they are (their required fields given here), beyond the operations
    /// that have no parameter at all.
    static let readyOperations: [(id: OpID, args: [String: OpValue], fr: String, en: String, symbol: String)] = [
        ("select", ["what": "subject"], "Sélectionner le sujet", "Select subject", "person.crop.circle"),
        ("select", ["what": "sky"], "Sélectionner le ciel", "Select sky", "cloud.sun"),
        ("select", ["what": "background"], "Sélectionner l'arrière-plan", "Select background", "photo"),
        ("select", ["what": "all"], "Tout sélectionner", "Select all", "rectangle.dashed"),
        ("selectionModify", ["invert": true], "Inverser la sélection", "Invert selection", "arrow.left.arrow.right"),
        ("selectionModify", ["deselect": true], "Désélectionner", "Deselect", "xmark.circle"),
        ("selectionModify", ["refine": true], "Affiner les bords", "Refine edges", "scribble"),
        ("maskAdjust", ["where": "sky", "parameter": "exposure", "amount": -10], "Assombrir le ciel", "Darken sky", "cloud"),
        ("maskAdjust", ["where": "subject", "parameter": "exposure", "amount": 15], "Éclaircir le sujet", "Brighten subject", "person.fill"),
        ("autoTone", [:], "Tonalité auto", "Auto tone", "wand.and.rays"),
        ("autoEnhance", [:], "Amélioration auto", "Auto enhance", "wand.and.stars"),
    ]

    static func entries(domain: OpDomain, language: OpLanguage) -> [Entry] {
        let catalog = OperationCatalog.shared
        let disabled = OperationGate.disabled()
        let french = language == .fr
        let specs = catalog.specs(in: domain).filter { !disabled.contains($0.id) }
        var toolIDs: [String] = domain == .photo ? photoTools : []
        for spec in specs { if let tool = spec.uiTool, !toolIDs.contains(tool) { toolIDs.append(tool) } }
        if disabled.contains("maskAdjust") { toolIDs.removeAll { $0 == "masks" } }
        if disabled.contains("select") { toolIDs.removeAll { $0 == "select" } }
        var entries: [Entry] = []
        for id in toolIDs {
            guard let info = tools[id] else { continue }
            let operations = specs.filter { $0.uiTool == id }.flatMap { [$0.title.fr, $0.title.en] }
            entries.append(Entry(id: "tool.\(id)", title: french ? info.fr : info.en, symbol: info.symbol, target: .tool(id),
                                 names: [info.fr, info.en] + info.synonyms + operations))
        }
        for ready in readyOperations where specs.contains(where: { $0.id == ready.id }) {
            let call = OperationCall(ready.id, args: ready.args, source: .ui)
            let key = ready.args.keys.sorted().map { "\($0)=\(ready.args[$0].map(describe) ?? "")" }.joined(separator: ",")
            entries.append(Entry(id: "op.\(ready.id.raw).\(key)", title: french ? ready.fr : ready.en, symbol: ready.symbol, target: .operation(call),
                                 names: [ready.fr, ready.en]))
        }
        for spec in specs where spec.params.isEmpty && !spec.requires.destructive && !readyOperations.contains(where: { $0.id == spec.id }) {
            entries.append(Entry(id: "op.\(spec.id.raw)", title: french ? spec.title.fr : spec.title.en, symbol: nil,
                                 target: .operation(OperationCall(spec.id, args: [:], source: .ui)), names: [spec.title.fr, spec.title.en]))
        }
        return entries
    }

    static func describe(_ value: OpValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: return "\(value)"
        }
    }
}
