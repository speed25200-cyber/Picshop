import Foundation

// D18: inspector rows generated from the catalog's ParamSpec (L1 builds them, L4 labels the params, L3 draws them).
// Every row writes through `OperationCall(op, args: fixedArgs + [param: value], source: .ui)`.

/// One choice of a segmented control or a menu.
public struct InspectorOption: Hashable, Sendable {
    public var value: String
    public var label: Bilingual

    public init(value: String, label: Bilingual) {
        self.value = value
        self.label = label
    }
}

public struct InspectorRowModel: Hashable, Sendable, Identifiable {
    public enum Control: Hashable, Sendable {
        case slider(range: ClosedRange<Double>, step: Double, neutral: Double, unit: OpUnit)
        case stepper(range: ClosedRange<Int>)
        case segmented([InspectorOption])
        case menu([InspectorOption])
        case toggle
        case color
        /// "curves", "colorWheels", "crop", "histogram", "gradientStops", "transformQuad".
        case custom(String)
    }

    /// "<op>.<param>" or "<op>.<param>=<fixed value>".
    public var id: String
    public var op: OpID
    public var param: String
    public var fixedArgs: [String: OpValue]
    public var label: Bilingual
    public var group: Bilingual?
    public var control: Control

    public init(id: String, op: OpID, param: String, fixedArgs: [String: OpValue] = [:], label: Bilingual, group: Bilingual? = nil,
                control: Control) {
        self.id = id
        self.op = op
        self.param = param
        self.fixedArgs = fixedArgs
        self.label = label
        self.group = group
        self.control = control
    }
}

public enum InspectorModel {
    /// Param keys ("<op>.<param>" first, then the bare key) and kind names that map to a bespoke control (D18).
    public static let overrides: [String: String] = [
        "points": "curves",
        "colorGrade.color": "colorWheels",
        "colorGrade.hue": "colorWheels",
        "box": "crop",
        "histogram": "histogram",
        "stops": "gradientStops",
        "corners": "transformQuad",
        "quad": "transformQuad",
    ]

    /// Operations that create or restructure layers: they never get rows (a slider tick must never add a layer, D18).
    public static let creationOps: Set<String> = [
        "addFillLayer", "addAdjustmentLayer", "addImageLayer", "layerVia", "mergeLayers", "groupLayers", "duplicateLayer", "deleteLayer",
        "recipe", "exportPhoto",
    ]

    /// AdjustPanel's order (Photos'): light, colour, detail, effects. The « Lumière » rows follow it.
    public static let adjustOrder: [AdjustmentParameter] = [
        .exposure, .brightness, .highlights, .shadows, .contrast, .whites, .blacks,
        .saturation, .vibrance, .temperature, .tint, .skinTone, .hue,
        .sharpness, .clarity, .noiseReduction, .vignette, .grain, .fade,
    ]

    /// D18: the rows of an edit operation, in its params' order.
    /// - number → slider (its range; the step from the unit; neutral 0 when the range spans it, 1 for a multiplier,
    ///   0.5 for a fraction, else its lower end); integer → stepper; an enumeration → segmented (≤ 4 values) or a menu; boolean →
    ///   toggle; colour → well; a key or kind in `overrides` → its bespoke control (one per control id); text, refs,
    ///   points, boxes and lists give none. A param with `inspector: false` gives none.
    /// - `expanding` names an enumeration param: one row per value for every other row-giving param, with the value
    ///   fixed in `fixedArgs` (and `amountMode` absolute when the op has it). For AdjustmentParameter the rows follow
    ///   `adjustOrder` and leave out the vignette (a frame effect), grouped Lumière / Couleur / Détail / Effets.
    /// - Labels: `ParamSpec.label`, else an enum value's name, else the key.
    public static func rows(for spec: OperationSpec, expanding: String? = nil, excluding: Set<String> = []) -> [InspectorRowModel] {
        guard !creationOps.contains(spec.id.raw) else { return [] }
        if let expanding, let expanded = spec.params.first(where: { $0.key == expanding }), case .enumeration(let values) = expanded.kind {
            return expandedRows(spec, expanded: expanded, values: values, excluding: excluding)
        }
        var rows: [InspectorRowModel] = []
        var customs: Set<String> = []
        for param in spec.params where !excluding.contains(param.key) {
            if let custom = override(for: param, in: spec) {
                guard customs.insert(custom).inserted else { continue }
                rows.append(InspectorRowModel(id: "\(spec.id.raw).\(param.key)", op: spec.id, param: param.key, label: label(of: param), control: .custom(custom)))
                continue
            }
            guard param.inspector, let control = control(for: param) else { continue }
            rows.append(InspectorRowModel(id: "\(spec.id.raw).\(param.key)", op: spec.id, param: param.key, label: label(of: param), control: control))
        }
        return rows
    }

    /// "+0,35", "50 %", "−12°", "×1,5" (French decimal comma when `language` is .fr): signed units and signed ranges
    /// carry their sign (− is U+2212), percents a spaced %, degrees °, multipliers ×, seconds s; an enumeration value
    /// its option's label; a boolean oui / non.
    public static func format(_ value: OpValue, row: InspectorRowModel, language: OpLanguage) -> String {
        switch value {
        case .number(let number):
            switch row.control {
            case .slider(let range, _, _, let unit):
                let signed = unit == .signedPercent || range.lowerBound < 0
                switch unit {
                case .percent, .signedPercent: return decimal(number, decimals: 0, signed: signed, language: language) + " %"
                case .degrees: return decimal(number, decimals: 1, signed: range.lowerBound < 0 && number < 0, language: language) + "°"
                case .multiplier: return "×" + decimal(number, decimals: 2, signed: false, language: language)
                case .seconds: return decimal(number, decimals: 2, signed: false, language: language) + " s"
                case .fraction, .level255, .count, .none: return decimal(number, decimals: 2, signed: signed, language: language)
                }
            case .stepper:
                return decimal(number, decimals: 0, signed: false, language: language)
            case .segmented, .menu, .toggle, .color, .custom:
                return decimal(number, decimals: 2, signed: false, language: language)
            }
        case .string(let text):
            switch row.control {
            case .segmented(let options), .menu(let options):
                return options.first { $0.value == text }?.label(language) ?? text
            default:
                return text
            }
        case .bool(let flag):
            return flag ? (language == .fr ? "oui" : "on") : (language == .fr ? "non" : "off")
        case .point(let point):
            return "\(decimal(point.x, decimals: 0, signed: false, language: language)), \(decimal(point.y, decimals: 0, signed: false, language: language))"
        case .box(let box):
            return "\(decimal(box.width, decimals: 0, signed: false, language: language)) × \(decimal(box.height, decimals: 0, signed: false, language: language))"
        case .list(let values):
            return "\(values.count)"
        }
    }

    /// Where the value sits on the row's track (0…1) and where neutral sits. Sliders only; (0, 0) otherwise.
    public static func fraction(_ value: Double, row: InspectorRowModel) -> (fraction: Double, neutral: Double) {
        guard case .slider(let range, _, let neutral, _) = row.control, range.upperBound > range.lowerBound else { return (0, 0) }
        let span = range.upperBound - range.lowerBound
        let position = value.isFinite ? ((value - range.lowerBound) / span).clamped(to: 0...1) : 0
        return (position, ((neutral - range.lowerBound) / span).clamped(to: 0...1))
    }

    // MARK: Internals

    static func expandedRows(_ spec: OperationSpec, expanded: ParamSpec, values: [String], excluding: Set<String>) -> [InspectorRowModel] {
        let isAdjustment = values.allSatisfy { AdjustmentParameter(rawValue: $0) != nil }
        let ordered: [String] = isAdjustment
            ? adjustOrder.map(\.rawValue).filter { values.contains($0) && $0 != AdjustmentParameter.vignette.rawValue }
            : values
        var fixed: [String: OpValue] = [:]
        if let mode = spec.params.first(where: { $0.key == "amountMode" }), case .enumeration(let modes) = mode.kind, modes.contains("absolute") {
            fixed["amountMode"] = .string("absolute")
        }
        let others = spec.params.filter { $0.key != expanded.key && $0.key != "amountMode" && !excluding.contains($0.key) && $0.inspector }
        var rows: [InspectorRowModel] = []
        for value in ordered {
            for param in others {
                guard let control = control(for: param) else { continue }
                var args = fixed
                args[expanded.key] = .string(value)
                let valueLabel = optionLabel(value)
                rows.append(InspectorRowModel(id: "\(spec.id.raw).\(param.key)=\(value)", op: spec.id, param: param.key, fixedArgs: args,
                                              label: others.count == 1 ? valueLabel : Bilingual(en: "\(valueLabel.en) \(label(of: param).en)",
                                                                                               fr: "\(valueLabel.fr) \(label(of: param).fr)"),
                                              group: isAdjustment ? AdjustmentParameter(rawValue: value).map(adjustmentGroup) : nil, control: control))
            }
        }
        return rows
    }

    /// The bespoke control a param maps to: "<op>.<param>", then the key, then its kind's name.
    static func override(for param: ParamSpec, in spec: OperationSpec) -> String? {
        if let custom = overrides["\(spec.id.raw).\(param.key)"] { return custom }
        if let custom = overrides[param.key] { return custom }
        return overrides[kindName(param.kind)]
    }

    static func kindName(_ kind: ParamKind) -> String {
        switch kind {
        case .enumeration: return "enumeration"
        case .number: return "number"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .color: return "color"
        case .point: return "point"
        case .box: return "box"
        case .text: return "text"
        case .ref: return "ref"
        case .list: return "list"
        }
    }

    static func control(for param: ParamSpec) -> InspectorRowModel.Control? {
        switch param.kind {
        case .number(let range, let unit):
            return .slider(range: range, step: step(for: unit, range: range), neutral: neutral(for: unit, range: range), unit: unit)
        case .integer(let range):
            return .stepper(range: range)
        case .enumeration(let values):
            let options = values.map { InspectorOption(value: $0, label: optionLabel($0)) }
            return values.count <= 4 ? .segmented(options) : .menu(options)
        case .boolean:
            return .toggle
        case .color:
            return .color
        case .point, .box, .text, .ref, .list:
            return nil
        }
    }

    static func step(for unit: OpUnit, range: ClosedRange<Double>) -> Double {
        switch unit {
        case .percent, .signedPercent, .degrees, .level255, .count: return 1
        case .fraction: return 0.01
        case .seconds: return 0.1
        case .multiplier: return 0.05
        case .none:
            let span = range.upperBound - range.lowerBound
            return span > 0 ? span / 100 : 1
        }
    }

    /// D18: 0 for a signed range, 1 for a multiplier, the middle (0.5) for a 0…1 fraction, else the lower end.
    static func neutral(for unit: OpUnit, range: ClosedRange<Double>) -> Double {
        if range.contains(0), range.lowerBound < 0 { return 0 }
        if unit == .multiplier, range.contains(1) { return 1 }
        if unit == .fraction, range.contains(0.5) { return 0.5 }
        return range.lowerBound
    }

    static func label(of param: ParamSpec) -> Bilingual {
        param.label ?? optionLabel(param.key)
    }

    /// An enum value's name in both languages, from the enums the catalog generates its values from.
    static func optionLabel(_ value: String) -> Bilingual {
        if let parameter = AdjustmentParameter(rawValue: value) { return Bilingual(en: parameter.englishName, fr: parameter.frenchName) }
        if let mode = BlendMode(rawValue: value) { return Bilingual(en: mode.displayName, fr: mode.frenchName) }
        if let kind = AdjustmentLayerKind(rawValue: value) { return Bilingual(en: kind.englishName, fr: kind.frenchName) }
        switch value {
        case "linear": return Bilingual(en: "Linear", fr: "Linéaire")
        case "radial": return Bilingual(en: "Radial", fr: "Radial")
        case "reflected": return Bilingual(en: "Reflected", fr: "Reflété")
        case "none": return Bilingual(en: "None", fr: "Aucun")
        case "position": return Bilingual(en: "Position", fr: "Position")
        case "pixels": return Bilingual(en: "Pixels", fr: "Pixels")
        case "transparency": return Bilingual(en: "Transparency", fr: "Transparence")
        case "all": return Bilingual(en: "All", fr: "Tout")
        default: return Bilingual(en: value, fr: value)
        }
    }

    static func adjustmentGroup(_ parameter: AdjustmentParameter) -> Bilingual {
        if AdjustmentParameter.lightGroup.contains(parameter) { return Bilingual(en: "Light", fr: "Lumière") }
        if AdjustmentParameter.colorGroup.contains(parameter) { return Bilingual(en: "Color", fr: "Couleur") }
        if AdjustmentParameter.detailGroup.contains(parameter) { return Bilingual(en: "Detail", fr: "Détail") }
        return Bilingual(en: "Effects", fr: "Effets")
    }

    /// A number with at most `decimals` decimals, trailing zeros dropped, a comma in French, − (U+2212) for negatives
    /// and + for positives when `signed`.
    static func decimal(_ value: Double, decimals: Int, signed: Bool, language: OpLanguage) -> String {
        guard value.isFinite else { return "–" }
        var text = StableHash.token(abs(value), decimals: decimals)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if language == .fr { text = text.replacingOccurrences(of: ".", with: ",") }
        let isZero = text == "0"
        if value < 0, !isZero { return "\u{2212}" + text }
        if signed, value > 0, !isZero { return "+" + text }
        return text
    }
}
