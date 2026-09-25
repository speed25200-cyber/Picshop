import Foundation
import PicshopCore

/// Turns a local model's tool arguments into the strict JSON ToolInputValidator expects.
///
/// A 2–4B model knows what it wants but writes it loosely. The XML-function
/// dialect sends every parameter as text, and small models add their own habits.
/// The coercer repairs the form, never the meaning:
/// - arrays and objects sent as strings are parsed (trailing commas, smart or
///   single quotes and Python literals repaired); a single step or idea is
///   wrapped into its list;
/// - numbers sent as strings ("15", "+15", "15 %", "0,5") become numbers,
///   booleans ("true", "True", "oui", 1) become booleans, per field;
/// - a point in Qwen-VL's 0–1000 grid (or as `[x, y]`, "x,y", or a box) becomes
///   `{"x", "y"}` in 0–1;
/// - enum values that differ only by case or separators ("Temperature",
///   "apply_look", "16:9") become the exact value; anything else is left for
///   the validator to refuse;
/// - nulls are dropped; tool names are normalised (`applyEdits`, `redo`).
/// Unknown fields stay: the validator names them, and the model corrects itself.
public enum ToolArgumentCoercer {
    /// Model arguments (arrays or numbers sent as strings, points in 0...1000, nulls) → the strict JSON ToolInputValidator expects.
    public static func rawToolUse(id: String, name: String, arguments: JSONValue) -> RawToolUse {
        var (tool, object) = normalizedCall(name: name, arguments: arguments)
        switch LiveToolName(rawValue: tool) {
        case .applyEdits?:
            object = applyEdits(object)
        case .undo?:
            object = undo(object)
        case .compareBeforeAfter?:
            object = compare(object)
        case .proposeIdeas?:
            object = proposeIdeas(object)
        case nil:
            break
        }
        return RawToolUse(id: id, name: tool, rawInput: JSONValue.object(object).serialized())
    }

    // MARK: Tools

    /// The tool's canonical name, and its arguments as an object.
    static func normalizedCall(name: String, arguments original: JSONValue) -> (String, [String: JSONValue]) {
        let key = foldedKey(name)
        var arguments = original
        if case .string(let text) = original, let parsed = lenientJSON(text) { arguments = parsed }
        var object = argumentsObject(arguments)
        switch key {
        case "applyedits", "applyedit", "edit", "edits":
            if object["steps"] == nil, case .array = arguments { object = ["steps": arguments] }
            return (LiveToolName.applyEdits.rawValue, object)
        case "undo":
            return (LiveToolName.undo.rawValue, object)
        case "redo":
            if object["direction"] == nil { object["direction"] = "redo" }
            return (LiveToolName.undo.rawValue, object)
        case "comparebeforeafter", "compare", "comparebefore", "showbefore", "beforeafter":
            return (LiveToolName.compareBeforeAfter.rawValue, object)
        case "proposeideas", "proposeidea", "ideas", "suggestideas":
            if object["ideas"] == nil, case .array = arguments { object = ["ideas": arguments] }
            return (LiveToolName.proposeIdeas.rawValue, object)
        default:
            return (name.trimmingCharacters(in: .whitespacesAndNewlines), object)
        }
    }

    private static func argumentsObject(_ arguments: JSONValue) -> [String: JSONValue] {
        switch arguments {
        case .object(let object):
            return dropNulls(object)
        case .string(let text):
            if let parsed = lenientJSON(text), case .object(let object) = parsed { return dropNulls(object) }
            return [:]
        default:
            return [:]
        }
    }

    static func applyEdits(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if object["steps"] == nil, object["action"] != nil {
            // One step written as the arguments themselves.
            object = ["steps": .array([.object(input)])]
        }
        if let steps = object["steps"] { object["steps"] = stepList(steps) }
        return object
    }

    static func undo(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if let count = object["count"] { object["count"] = integer(count) ?? number(count) ?? count }
        if let direction = object["direction"]?.string {
            let folded = foldedKey(direction)
            object["direction"] = .string(["redo", "refaire", "retablir"].contains(folded) ? "redo" : ["undo", "annuler", "back"].contains(folded) ? "undo" : direction)
        }
        if let flag = object["to_original"] { object["to_original"] = boolean(flag) ?? flag }
        return object
    }

    static func compare(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if let seconds = object["seconds"] { object["seconds"] = number(seconds) ?? seconds }
        return object
    }

    static func proposeIdeas(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if object["ideas"] == nil, object["title"] != nil { object = ["ideas": .array([.object(input)])] }
        guard let ideas = object["ideas"] else { return object }
        object["ideas"] = list(ideas).map { items in
            .array(items.map { item -> JSONValue in
                guard case .object(var idea) = item else { return item }
                idea = dropNulls(idea)
                for key in ["title", "why", "symbol"] {
                    if let value = idea[key], let text = scalarText(value) { idea[key] = .string(text) }
                }
                if let steps = idea["steps"] { idea["steps"] = stepList(steps) }
                return .object(idea)
            })
        } ?? ideas
        return object
    }

    // MARK: Steps

    static let numberFields = ["amount", "degrees", "startSeconds", "endSeconds", "seconds", "speed", "min", "max"]
    static let integerFields = ["ordinal", "choiceIndex", "clipNumber", "decimals"]
    static let booleanFields = ["all"]
    /// A number written for one of these becomes its text: "text": 1 → "1", "row": 3 → "3", "size": 24 → "24".
    static let textFields = ["target", "text", "color", "background", "row", "column", "ref", "size", "match"]
    /// Steps whose box is a region of their own (erase it, write in it), not a way to point at an object.
    static let boxActions: Set<String> = [IntentAction.eraseRegion.rawValue, IntentAction.addText.rawValue, IntentAction.moveText.rawValue]

    private static func stepList(_ value: JSONValue) -> JSONValue {
        guard let items = list(value) else { return value }
        return .array(items.map { item in
            guard case .object(let step) = item else { return item }
            return .object(coerceStep(step))
        })
    }

    /// One apply_edits step: types, enums, point, aliases.
    static func coerceStep(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var step = dropNulls(input)
        if let action = step["action"]?.string {
            // The exact name first ("FillCells", "fill_cells"), then the names small models use ("fill_table").
            let exact = canonical(action, among: IntentAction.allCases.map(\.rawValue), field: "action")
            step["action"] = .string(IntentAction(rawValue: exact) != nil ? exact : actionAliases[foldedKey(action)]?.rawValue ?? action)
        }
        let action = step["action"]?.string.flatMap(IntentAction.init(rawValue:))
        if let action, IntentNormalizer.tableActions.contains(action) { step = tableStep(step) }
        // Unambiguous aliases small models use.
        for (alias, field) in [("value", "amount"), ("param", "parameter"), ("preset", "look"), ("filter", "look"), ("fontSize", "size"),
                               ("font_size", "size"), ("textSize", "size"), ("text_size", "size"), ("alignment", "align"), ("fontWeight", "weight")]
            where step[field] == nil {
            if let value = step.removeValue(forKey: alias) { step[field] = value }
        }
        // "size": 1.5 or "2" for « une fois et demie / deux fois plus gros »: a factor, never thousandths of the height.
        if let size = step["size"], let factor = sizeFactor(size) { step["size"] = .string("x" + shortNumber(factor)) }
        // "bottom right", "en bas à droite", "top-left": the corner as the enum spells it.
        if let placement = step["placement"]?.string, let corner = placementSynonyms[foldedKey(placement)] { step["placement"] = .string(corner) }
        for field in numberFields { if let value = step[field] { step[field] = number(value) ?? value } }
        // A number that is not whole stays a number, so the validator says "must be an integer".
        for field in integerFields { if let value = step[field] { step[field] = integer(value) ?? number(value) ?? value } }
        for field in booleanFields { if let value = step[field] { step[field] = boolean(value) ?? value } }
        for field in textFields { if let value = step[field], let text = scalarText(value) { step[field] = .string(text) } }
        for (field, values) in enumFields {
            if let text = step[field]?.string { step[field] = .string(canonical(text, among: values, field: field)) }
        }
        if let attributes = step["attributes"] {
            switch attributes {
            case .string(let text):
                let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                step["attributes"] = .array(parts.map { .string($0) })
            case .array(let items):
                step["attributes"] = .array(items.map { scalarText($0).map { .string($0) } ?? $0 })
            default:
                break
            }
        }
        let keepsBox = step["action"]?.string.map { boxActions.contains($0) } ?? false
        if keepsBox, let raw = ["box", "bbox_2d", "bbox"].lazy.compactMap({ step[$0] }).first {
            // The region itself: [x1, y1, x2, y2] in 0–1.
            step["box"] = box(raw) ?? raw
            for key in ["bbox_2d", "bbox"] { step[key] = nil }
        }
        if let point = step["point"] {
            step["point"] = self.point(point) ?? point
        } else if !keepsBox, let box = ["bbox_2d", "bbox", "box"].lazy.compactMap({ step[$0] }).first, let center = boxCenter(box) {
            step["point"] = center
        }
        if step["point"] != nil, !keepsBox { for key in ["bbox_2d", "bbox", "box"] { step[key] = nil } }
        return step
    }

    /// A size written as a bare number between 0.25 and 4 (1.5, "2", "1,5"): a factor. A number with an "x", a
    /// word or a fraction below 0.25 (a size as part of the height) is left as it is.
    static func sizeFactor(_ value: JSONValue) -> Double? {
        if let text = value.string, text.lowercased().contains("x") || text.contains("×") { return nil }
        guard let factor = number(value)?.double, factor.isFinite, (0.25...4).contains(factor) else { return nil }
        return factor
    }

    /// 1.5 -> "1.5", 2 -> "2".
    static func shortNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// Placements small models (and people) write another way, folded, to the enum's values.
    static let placementSynonyms: [String: String] = {
        var map: [String: String] = [:]
        let table: [(String, [String])] = [
            ("topLeading", ["topleft", "lefttop", "upperleft", "topleftcorner", "hautgauche", "enhautagauche", "enhautgauche", "hautagauche", "coinhautgauche"]),
            ("topTrailing", ["topright", "righttop", "upperright", "toprightcorner", "hautdroite", "enhautadroite", "enhautdroite", "hautadroite", "coinhautdroite"]),
            ("bottomLeading", ["bottomleft", "leftbottom", "lowerleft", "bottomleftcorner", "basgauche", "enbasagauche", "enbasgauche", "basagauche", "coinbasgauche"]),
            ("bottomTrailing", ["bottomright", "rightbottom", "lowerright", "bottomrightcorner", "basdroite", "enbasadroite", "enbasdroite", "basadroite", "coinbasdroite"]),
            ("top", ["haut", "enhaut", "upper", "attop", "atthetop"]),
            ("bottom", ["bas", "enbas", "lower", "atbottom", "atthebottom"]),
            ("center", ["centre", "middle", "milieu", "aucentre", "aumilieu", "centered", "centred"]),
        ]
        for (value, keys) in table { for key in keys { map[key] = value } }
        return map
    }()

    /// Action names small models use for the table and text steps (the validator wants the exact names).
    static let actionAliases: [String: IntentAction] = [
        "fill": .fillCells, "filltable": .fillCells, "fillgrid": .fillCells, "fillcell": .fillCells, "setcell": .fillCells, "setcells": .fillCells,
        "populate": .fillCells, "populatetable": .fillCells, "writecells": .fillCells, "writecell": .fillCells, "fillin": .fillCells,
        "clearcell": .clearCells, "clearcolumn": .clearCells, "clearrow": .clearCells, "emptycells": .clearCells, "cleartable": .clearCells,
        "highlightcolumn": .highlightCells, "highlightrow": .highlightCells, "highlightcell": .highlightCells,
        "shadecolumn": .highlightCells, "shaderow": .highlightCells,
        "erasearea": .eraseRegion, "erasebox": .eraseRegion, "clearregion": .eraseRegion, "cleararea": .eraseRegion,
        "movelabel": .moveText, "movetitle": .moveText,
        "writetext": .addText, "placetext": .addText, "inserttext": .addText,
        "changetext": .editText, "rewritetext": .editText, "replacetextblock": .editText, "restyletext": .editText,
        "erasetext": .removeText, "deletetext": .removeText,
    ]

    /// cells / values synonyms, and the table step's own aliases: `value` is the text written in the cells
    /// (or "random"), `scope` is `cells`, a list of rows or columns is joined with "|", `range` is min and max.
    static func tableStep(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var step = input
        if step["text"] == nil, let value = step.removeValue(forKey: "value") {
            if let text = value.string, let values = valuesSynonyms[foldedKey(text)] { step["values"] = .string(values) }
            else if let text = scalarText(value) { step["text"] = .string(text) }
        }
        if step["cells"] == nil, let scope = step.removeValue(forKey: "scope") { step["cells"] = scope }
        if let cells = step["cells"]?.string, let canonical = cellsSynonyms[foldedKey(cells)] { step["cells"] = .string(canonical) }
        if let values = step["values"]?.string, let canonical = valuesSynonyms[foldedKey(values)] { step["values"] = .string(canonical) }
        for field in ["row", "column", "rows", "columns"] {
            guard case .array(let items)? = step[field] else { continue }
            step[field] = .string(items.compactMap(scalarText).joined(separator: "|"))
        }
        for (plural, singular) in [("rows", "row"), ("columns", "column")] where step[singular] == nil {
            if let value = step.removeValue(forKey: plural) { step[singular] = value }
        }
        // The forms the table lines print, as the model copies them: "Novel problem…" (a cut name), "r6", "c3",
        // "row 6", "colonne 3", and one "r6c3" in row or column (the cells: line's notation).
        for field in ["row", "column"] {
            guard let text = step[field].flatMap(scalarText) else { continue }
            if let cell = cellAddress(text) {
                if step["row"].flatMap(scalarText).map({ cellAddress($0) != nil || $0 == text }) ?? true { step["row"] = .string(String(cell.row)) }
                if step["column"].flatMap(scalarText).map({ cellAddress($0) != nil || $0 == text }) ?? true { step["column"] = .string(String(cell.column)) }
                continue
            }
            step[field] = .string(tableRef(text, axis: field))
        }
        if let range = step.removeValue(forKey: "range"), step["min"] == nil, step["max"] == nil {
            var bounds: [Double] = []
            switch range {
            case .array(let items): bounds = items.compactMap { number($0)?.double }
            case .string(let text): bounds = text.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "," || $0 == " " }).compactMap { number(.string(String($0)))?.double }
            default: break
            }
            if bounds.count == 2 { step["min"] = .number(bounds[0]); step["max"] = .number(bounds[1]) } else { step["range"] = range }
        }
        return step
    }

    /// "r6c3", "R6 C3", "l6c3": a cell by its 1-based data row and column.
    static func cellAddress(_ text: String) -> (row: Int, column: Int)? {
        let key = text.lowercased().filter { !$0.isWhitespace }
        guard let first = key.first, first == "r" || first == "l", let c = key.firstIndex(of: "c"),
              let row = Int(key[key.index(after: key.startIndex)..<c]), let column = Int(key[key.index(after: c)...]), row >= 1, column >= 1 else { return nil }
        return (row, column)
    }

    /// One row or column name as printed: the ellipsis of a cut name dropped; "r6", "row 6", "ligne 6" -> "6"
    /// (rows), "c3", "col 3", "colonne 3" -> "3" (columns). Several joined with "|" each get the same.
    static func tableRef(_ text: String, axis: String) -> String {
        text.split(separator: "|", omittingEmptySubsequences: false).map { part -> String in
            var name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasSuffix("…") || name.hasSuffix(".") { name.removeLast() }
            name = name.trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            let prefixes = axis == "row" ? ["row ", "ligne ", "rangée ", "rangee ", "r"] : ["column ", "colonne ", "col ", "col. ", "c"]
            for prefix in prefixes where key.hasPrefix(prefix) {
                let rest = key.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if let number = Int(rest), number >= 1 || number == -1 { return String(number) }
            }
            return name
        }.joined(separator: "|")
    }

    static let cellsSynonyms: [String: String] = [
        "empty": "empty", "blank": "empty", "remaining": "empty", "rest": "empty", "others": "empty", "other": "empty", "missing": "empty",
        "emptyonly": "empty", "vides": "empty", "vide": "empty", "autres": "empty", "reste": "empty",
        "all": "all", "every": "all", "everything": "all", "allcells": "all", "toutes": "all", "tout": "all", "tous": "all",
    ]

    static let valuesSynonyms: [String: String] = [
        "random": "random", "randomnumbers": "random", "randomnumber": "random", "randomvalues": "random", "aleatoire": "random", "aleatoires": "random",
        "hasard": "random", "auhasard": "random", "chiffresaleatoires": "random", "nombresaleatoires": "random",
        "sequence": "sequence", "sequential": "sequence", "count": "sequence", "numbering": "sequence", "increasing": "sequence",
        "plausible": "plausible", "realistic": "plausible", "credible": "plausible", "realiste": "plausible", "realistes": "plausible",
        "list": "list",
    ]

    static let enumFields: [(String, [String])] = [
        ("action", IntentAction.allCases.map(\.rawValue)),
        ("parameter", AdjustmentParameter.allCases.map(\.rawValue)),
        ("look", FilterPreset.allCases.map(\.rawValue)),
        ("aspect", AspectPreset.allCases.map(\.rawValue)),
        ("spatialHint", SpatialHint.allCases.map(\.rawValue)),
        ("flipAxis", FlipAxis.allCases.map(\.rawValue)),
        ("placement", TextElement.Placement.allCases.map(\.rawValue)),
        ("transition", TransitionKind.allCases.map(\.rawValue)),
        ("amountMode", ["relative", "absolute", "multiplier"]),
        ("scope", ["current", "all", "selection"]),
        ("cells", LiveToolSchema.cellsValues),
        ("values", LiveToolSchema.valuesValues),
        ("weight", TableGrid.FontWeight.allCases.map(\.rawValue)),
        ("align", LiveToolSchema.alignValues),
        ("font", TableGrid.FontDesign.allCases.map(\.rawValue)),
    ]

    /// The exact enum value that `text` spells with another case or separators.
    static func canonical(_ text: String, among values: [String], field: String) -> String {
        if values.contains(text) { return text }
        var key = foldedKey(text)
        if field == "aspect" {
            // "16:9", "16/9", "16 x 9" → ratio16x9; "carré" → square.
            let digits = text.split(whereSeparator: { !$0.isNumber })
            if digits.count == 2 { key = "ratio\(digits[0])x\(digits[1])" }
            if ["carre", "square", "11", "ratio1x1"].contains(key) { key = "square" }
        }
        return values.first { foldedKey($0) == key } ?? text
    }

    // MARK: Points

    /// `{"x": 512, "y": 300}`, `[512, 300]` or "512, 300": 0–1000 (Qwen-VL) or already 0–1.
    static func point(_ value: JSONValue) -> JSONValue? {
        var pair: (Double, Double)?
        switch value {
        case .object(let object):
            if let x = object["x"].flatMap(number)?.double, let y = object["y"].flatMap(number)?.double { pair = (x, y) }
        case .array(let items) where items.count == 2:
            if let x = number(items[0])?.double, let y = number(items[1])?.double { pair = (x, y) }
        case .string(let text):
            if let parsed = lenientJSON(text), parsed != value { return point(parsed) }
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { number(.string(String($0)))?.double }
            if parts.count == 2 { pair = (parts[0], parts[1]) }
        default:
            break
        }
        guard let (x, y) = pair else { return nil }
        let scale = max(x, y) > 1 ? 1_000.0 : 1
        func unit(_ value: Double) -> Double {
            let scaled = value / scale
            // Within the grid (a hair outside is rounding): clamped; far outside stays for the validator.
            return (-0.01...1.01).contains(scaled) ? min(max(scaled, 0), 1) : scaled
        }
        return ["x": .number(round4(unit(x))), "y": .number(round4(unit(y)))]
    }

    /// A region as the validator reads it, `[x1, y1, x2, y2]` in 0–1, from `[x1, y1, x2, y2]` (0–1000,
    /// Qwen-VL's grid, or 0–1), "x1, y1, x2, y2", `{"x1","y1","x2","y2"}` or `{"x","y","width","height"}`.
    /// Nil when it is not a box (the validator names the field).
    static func box(_ value: JSONValue) -> JSONValue? {
        var corners: [Double]?
        switch value {
        case .array(let items) where items.count == 4:
            let numbers = items.compactMap { number($0)?.double }
            if numbers.count == 4 { corners = numbers }
        case .object(let object):
            func read(_ keys: [String]) -> Double? { keys.lazy.compactMap { object[$0].flatMap(number)?.double }.first }
            if let x1 = read(["x1", "left"]), let y1 = read(["y1", "top"]), let x2 = read(["x2", "right"]), let y2 = read(["y2", "bottom"]) {
                corners = [x1, y1, x2, y2]
            } else if let x = read(["x"]), let y = read(["y"]), let width = read(["width", "w"]), let height = read(["height", "h"]) {
                corners = [x, y, x + width, y + height]
            }
        case .string(let text):
            if let parsed = lenientJSON(text), parsed != value { return box(parsed) }
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { number(.string(String($0)))?.double }
            if parts.count == 4 { corners = parts }
        default:
            break
        }
        guard let corners else { return nil }
        let scale = corners.contains { $0 > 1 } ? 1_000.0 : 1
        let unit = corners.map { corner -> Double in
            let scaled = corner / scale
            return (-0.01...1.01).contains(scaled) ? min(max(scaled, 0), 1) : scaled
        }
        return .array(unit.map { .number(round4($0)) })
    }

    /// A box `[x1, y1, x2, y2]` (0–1000 or 0–1): its centre.
    static func boxCenter(_ value: JSONValue) -> JSONValue? {
        var box = value
        if case .string(let text) = value, let parsed = lenientJSON(text) { box = parsed }
        guard let items = box.array, items.count == 4 else { return nil }
        let numbers = items.compactMap { number($0)?.double }
        guard numbers.count == 4 else { return nil }
        return point(.array([.number((numbers[0] + numbers[2]) / 2), .number((numbers[1] + numbers[3]) / 2)]))
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    // MARK: Scalars

    /// A number, or a string that is one ("15", "+15", "15 %", "0,5", "-20°").
    static func number(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .number:
            return value
        case .string(let text):
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in ["%", "°", "s", "x", "×"] where cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            if cleaned.hasPrefix("+") { cleaned.removeFirst() }
            if cleaned.contains(","), !cleaned.contains(".") { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
            guard !cleaned.isEmpty, let parsed = Double(cleaned), parsed.isFinite else { return nil }
            return .number(parsed)
        case .bool(let flag):
            return .number(flag ? 1 : 0)
        default:
            return nil
        }
    }

    /// A whole number (2, 2.0, "2").
    static func integer(_ value: JSONValue) -> JSONValue? {
        guard let parsed = number(value)?.double, let whole = Int(exactly: parsed.rounded()), abs(parsed - parsed.rounded()) < 1e-9 else { return nil }
        return .number(Double(whole))
    }

    static func boolean(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .bool:
            return value
        case .number(let number):
            if number == 1 { return .bool(true) }
            if number == 0 { return .bool(false) }
            return nil
        case .string(let text):
            switch foldedKey(text) {
            case "true", "yes", "oui", "vrai", "1": return .bool(true)
            case "false", "no", "non", "faux", "0": return .bool(false)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A number written where text is expected ("2024" for addText) becomes its text.
    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number: return value.serialized()
        default: return nil
        }
    }

    private static func list(_ value: JSONValue) -> [JSONValue]? {
        switch value {
        case .array(let items):
            return items
        case .object:
            return [value]
        case .string(let text):
            guard let parsed = lenientJSON(text) else { return nil }
            if case .string = parsed { return nil }
            return list(parsed)
        default:
            return nil
        }
    }

    private static func dropNulls(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.filter { $0.value != .null }
    }

    /// Lowercased, without accents, spaces, dashes or underscores.
    static func foldedKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Lenient JSON

    /// Strict JSON, else the same text with smart quotes, trailing commas, Python
    /// literals and single quotes repaired. Nil when it is still not JSON.
    static func lenientJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let strict = try? JSONValue.parse(trimmed) { return strict }
        guard trimmed.first == "[" || trimmed.first == "{" else { return nil }
        var repaired = LLMResponseParser.repair(trimmed)
        if let parsed = try? JSONValue.parse(repaired) { return parsed }
        if !repaired.contains("\"") {
            repaired = repaired.replacingOccurrences(of: "'", with: "\"")
            if let parsed = try? JSONValue.parse(repaired) { return parsed }
        }
        return nil
    }
}
