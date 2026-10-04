import Foundation

// The small DSL the catalog entries are written in (Catalog+*.swift). One builder
// call per spec and per param, never one giant literal: a big catalog literal
// runs into the type checker's time limit.
//
// Enumerations are generated from the Core enums' allCases, never retyped.

// MARK: - Literals

extension OpValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Specs

/// English then French.
func t(_ en: String, _ fr: String) -> Bilingual {
    Bilingual(en: en, fr: fr)
}

/// One spec: identity, where it lives and how it runs, then the rest set in `configure`.
func op(_ id: OpID, _ lowering: OpLowering, in domains: Set<OpDomain>, _ category: OpCategory, _ phase: OpPhase,
        title: Bilingual, summary: Bilingual, _ configure: (inout OperationSpec) -> Void) -> OperationSpec {
    var spec = OperationSpec(id: id, domains: domains, category: category, phase: phase, title: title, summary: summary, lowering: lowering)
    configure(&spec)
    return spec
}

/// An existing action: its id is the IntentAction's raw value.
func legacy(_ action: IntentAction, in domains: Set<OpDomain>, _ category: OpCategory, _ phase: OpPhase,
            title: Bilingual, summary: Bilingual, _ configure: (inout OperationSpec) -> Void) -> OperationSpec {
    op(OpID(action.rawValue), .intent(action), in: domains, category, phase, title: title, summary: summary, configure)
}

/// Requirements, set in one expression.
func needs(subject: Bool = false, selection: Bool = false, table: Bool = false, captions: Bool = false, generativeEngine: Bool = false,
           importedLUT: Bool = false, nonBaseLayer: Bool = false, localMask: Bool = false, layerMask: Bool = false, layerAboveBase: Bool = false,
           referenceAsset: AssetKind? = nil, cost: OpCost = .instant, geometryChange: Bool = false, destructive: Bool = false) -> OpRequirements {
    var requirements = OpRequirements()
    requirements.localMask = localMask
    requirements.layerMask = layerMask
    requirements.layerAboveBase = layerAboveBase
    requirements.subject = subject
    requirements.selection = selection
    requirements.table = table
    requirements.captions = captions
    requirements.generativeEngine = generativeEngine
    requirements.importedLUT = importedLUT
    requirements.nonBaseLayer = nonBaseLayer
    requirements.referenceAsset = referenceAsset
    requirements.cost = cost
    requirements.geometryChange = geometryChange
    requirements.destructive = destructive
    return requirements
}

// MARK: - Examples

func fr(_ say: String, _ args: [String: OpValue] = [:]) -> OpExample {
    OpExample(say, .fr, args)
}

func en(_ say: String, _ args: [String: OpValue] = [:]) -> OpExample {
    OpExample(say, .en, args)
}

/// Another way to say it (colloquial, an anglicism, a speech-recognition slip).
func para(_ say: String, _ language: OpLanguage, _ args: [String: OpValue] = [:]) -> OpExample {
    OpExample(say, language, args, role: .paraphrase)
}

/// A near miss: it must go to `expected` (nil: no operation, refuse honestly).
func near(_ say: String, _ language: OpLanguage, expected: OpID?) -> OpExample {
    OpExample(say, language, role: .negative(expected: expected))
}

// MARK: - Params

extension ParamSpec {
    /// The same param, off the one-line card.
    var offCard: ParamSpec {
        var copy = self
        copy.onCard = false
        return copy
    }

    func required() -> ParamSpec {
        var copy = self
        copy.presence = .required
        return copy
    }

    func inGroup(_ group: String) -> ParamSpec {
        var copy = self
        copy.presence = .oneOf(group: group)
        return copy
    }

    func defaulting(_ value: OpValue) -> ParamSpec {
        var copy = self
        copy.presence = .optional(value)
        return copy
    }

    func aliases(_ values: [String: String]) -> ParamSpec {
        var copy = self
        copy.valueAliases.merge(values) { first, _ in first }
        return copy
    }

    func keys(_ aliases: String...) -> ParamSpec {
        var copy = self
        copy.keyAliases += aliases
        return copy
    }

    /// W3 (D18): the inspector row's label, English then French.
    func labelled(_ en: String, _ fr: String) -> ParamSpec {
        var copy = self
        copy.label = Bilingual(en: en, fr: fr)
        return copy
    }

    /// W3 (D18): kept out of the generated inspector rows (refs, points, boxes, lists, text, internal flags).
    var noInspector: ParamSpec {
        var copy = self
        copy.inspector = false
        return copy
    }
}

/// Every case of a String-backed Core enum, in declaration order.
func values<E: CaseIterable & RawRepresentable>(_ type: E.Type) -> [String] where E.RawValue == String {
    E.allCases.map(\.rawValue)
}

func enumParam<E: CaseIterable & RawRepresentable>(_ key: String, _ type: E.Type, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec
    where E.RawValue == String {
    ParamSpec(key, .enumeration(values(type)), presence, doc: doc)
}

func enumParam(_ key: String, _ values: [String], _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .enumeration(values), presence, doc: doc)
}

func number(_ key: String, _ range: ClosedRange<Double>, _ unit: OpUnit, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .number(range, unit), presence, doc: doc)
}

/// 0…100 (or the range given), in percent.
func percent(_ key: String, _ range: ClosedRange<Double> = 0...100, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    number(key, range, .percent, presence, doc: doc)
}

/// −100…100: less to more.
func signedPercent(_ key: String, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    number(key, -100...100, .signedPercent, presence, doc: doc)
}

func integer(_ key: String, _ range: ClosedRange<Int>, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .integer(range), presence, doc: doc)
}

func boolean(_ key: String, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .boolean, presence, doc: doc)
}

func text(_ key: String, max: Int, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .text(maxLength: max), presence, doc: doc)
}

func ref(_ key: String = "ref", _ kinds: Set<RefKind>, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
    ParamSpec(key, .ref(kinds), presence, doc: doc)
}

/// The fields of an apply_edits step for the existing actions, exactly as ToolInputValidator
/// and IntentNormalizer read them (keys, enums, ranges, the AmountUnit table). A catalog test
/// keeps them in parity with the validator.
enum Step {
    static func target(_ presence: Presence = .optional(nil), doc: String = "English noun: dog, person, sky") -> ParamSpec {
        PicshopCore.text("target", max: 40, presence, doc: doc).keys("object", "subject")
    }

    static var spatialHint: ParamSpec { enumParam("spatialHint", SpatialHint.self, doc: "where it is in the frame").offCard }
    static var ordinal: ParamSpec { integer("ordinal", 1...20, doc: "the second one → 2").offCard }
    static var all: ParamSpec { boolean("all", doc: "every matching one").offCard }
    /// [x, y] in 0…1000, top-left origin, in the last image seen.
    static var point: ParamSpec { ParamSpec("point", .point, doc: "[x,y] where it is, 0-1000") }
    static var attributes: ParamSpec { ParamSpec("attributes", .list(.text(maxLength: 24), max: 3), doc: "colour or clothing that tells it apart").offCard }

    static func parameter(_ presence: Presence = .required) -> ParamSpec {
        enumParam("parameter", AdjustmentParameter.self, presence, doc: "the setting").keys("param", "setting")
    }

    static var amountMode: ParamSpec {
        enumParam("amountMode", ["relative", "absolute", "multiplier"], doc: "relative more/less, absolute set to").offCard
    }

    /// The step's amount in its AmountUnit's terms.
    static func amount(_ range: ClosedRange<Double>, _ unit: OpUnit, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
        number("amount", range, unit, presence, doc: doc).keys("value", "strength", "intensity")
    }

    static func look(_ presence: Presence = .required) -> ParamSpec {
        enumParam("look", FilterPreset.self, presence, doc: "the look").keys("preset", "filter")
    }

    static func aspect(_ presence: Presence = .optional(nil)) -> ParamSpec {
        enumParam("aspect", AspectPreset.self, presence, doc: "the frame shape").keys("ratio", "format")
    }

    static func degrees(_ range: ClosedRange<Double> = -360...360, doc: String) -> ParamSpec {
        number("degrees", range, .degrees, doc: doc).keys("angle")
    }

    static var flipAxis: ParamSpec { enumParam("flipAxis", FlipAxis.self, doc: "mirror axis").keys("axis") }

    static func text(_ presence: Presence = .optional(nil), max: Int = 200, doc: String) -> ParamSpec {
        PicshopCore.text("text", max: max, presence, doc: doc)
    }

    /// `text` holding one of a fixed set of words (a caption style, a language code).
    static func textChoice(_ values: [String], _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
        enumParam("text", values, presence, doc: doc)
    }

    static var placement: ParamSpec { enumParam("placement", TextElement.Placement.self, doc: "where on the frame").keys("position") }
    static func color(_ presence: Presence = .optional(nil), doc: String = "colour name or #RRGGBB") -> ParamSpec {
        ParamSpec("color", .color, presence, doc: doc).keys("colour", "couleur")
    }

    static var background: ParamSpec { PicshopCore.text("background", max: 40, doc: "colour, transparent or blur") }
    static func choiceIndex(_ range: ClosedRange<Int> = 1...99, doc: String) -> ParamSpec {
        integer("choiceIndex", range, doc: doc)
    }

    // Video
    static func startSeconds(_ presence: Presence = .optional(nil)) -> ParamSpec {
        number("startSeconds", 0...36_000, .seconds, presence, doc: "range start").keys("start", "from")
    }

    static func endSeconds(_ presence: Presence = .optional(nil)) -> ParamSpec {
        number("endSeconds", 0...36_000, .seconds, presence, doc: "range end").keys("end", "to")
    }

    static func seconds(_ presence: Presence = .optional(nil), doc: String = "a time") -> ParamSpec {
        number("seconds", 0...36_000, .seconds, presence, doc: doc).keys("time", "at")
    }

    static func clipNumber(_ presence: Presence = .optional(nil), doc: String = "clip 1.., -1 last") -> ParamSpec {
        integer("clipNumber", -1...999, presence, doc: doc).keys("clip")
    }

    static func transition(_ presence: Presence = .required) -> ParamSpec {
        enumParam("transition", TransitionKind.self, presence, doc: "the transition").keys("kind", "type")
    }

    static func speed(_ presence: Presence = .required) -> ParamSpec {
        number("speed", 0.1...8, .multiplier, presence, doc: "0.5 slow motion, 2 fast").keys("factor", "rate")
    }

    static func scope(_ values: [String] = ["current", "all", "selection"], doc: String = "current clip, all clips") -> ParamSpec {
        enumParam("scope", values, doc: doc)
    }

    // Photo: tables and text primitives
    static var cells: ParamSpec { enumParam("cells", ["empty", "all"], doc: "empty cells (default) or all") }
    static var row: ParamSpec { PicshopCore.text("row", max: 40, doc: "row name or number, several with |") }
    static var column: ParamSpec { PicshopCore.text("column", max: 40, doc: "column name or number") }
    static var values: ParamSpec { enumParam("values", ["random", "sequence", "plausible", "list"], doc: "generated values") }
    static var min: ParamSpec { number("min", -1_000_000_000...1_000_000_000, .none, doc: "smallest value").offCard }
    static var max: ParamSpec { number("max", -1_000_000_000...1_000_000_000, .none, doc: "largest value").offCard }
    static var decimals: ParamSpec { integer("decimals", 0...3, doc: "decimal places").offCard }

    /// A scene-map id: t3 printed text, l2 text layer, o1 object, f1 free area.
    static func ref(_ kinds: Set<RefKind>, _ presence: Presence = .optional(nil), doc: String) -> ParamSpec {
        PicshopCore.ref("ref", kinds, presence, doc: doc)
    }

    /// [x1, y1, x2, y2] in 0…1000, top-left origin.
    static func box(doc: String) -> ParamSpec { ParamSpec("box", .box, doc: doc) }
    static var size: ParamSpec { PicshopCore.text("size", max: 12, doc: "small|medium|large|title, x1.5") }
    static var weight: ParamSpec { enumParam("weight", TableGrid.FontWeight.self, doc: "font weight") }
    static var align: ParamSpec { enumParam("align", ["left", "center", "right"], doc: "alignment").offCard }
    static var font: ParamSpec { enumParam("font", TableGrid.FontDesign.self, doc: "font design") }
    static var match: ParamSpec { PicshopCore.text("match", max: 8, doc: "copy the style of: nearby or t3").offCard }

    // PDF: pages are read from clipNumber (the planner's contract)
    static func page(_ presence: Presence = .optional(nil), doc: String = "page 1.., -1 last") -> ParamSpec {
        integer("clipNumber", -1...9_999, presence, doc: doc).keys("page", "pageNumber")
    }

    static func replacement(_ presence: Presence = .required) -> ParamSpec {
        PicshopCore.text("replacement", max: 200, presence, doc: "the new words, \"\" erases").keys("with", "newText")
    }
}
