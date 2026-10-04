import Foundation

// The Operation Catalog's vocabulary: what an operation is, which arguments it
// takes, how it is retrieved, checked and lowered to the executors. Pure data,
// shared by the catalog entries (Core) and retrieval, cards, validation and
// abstention (Intent). The W1 seam froze these signatures: only additive
// changes with default values from here on.

/// A catalog operation's identifier ("curves", "adjust"). Ids of operations that
/// lower to an IntentAction equal its raw value; new ids never collide with one.
public struct OpID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { raw }

    // Coded as the bare string.
    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// The editors an operation exists in.
public enum OpDomain: String, Codable, Sendable, CaseIterable { case photo, video, pdf }

/// The languages of titles, triggers and examples.
public enum OpLanguage: String, Codable, Sendable, CaseIterable { case fr, en }

public enum OpCategory: String, Codable, Sendable, CaseIterable {
    // Photo
    case light, color, detail, retouch, objects, background, geometry, text, layers, shapes, selection, generative, effects, table
    // Video
    case cut, speed, audio, captions, transitions, overlays, motion, clipColor, story
    // PDF and shared
    case pages, annotate, pdfText, sign, document, export, history
}

/// Where an operation sits in a plan: steps are ordered by phase (a crop before a grade before a title).
public enum OpPhase: Int, Codable, Sendable, Comparable {
    case refDependent, geometry, cleanup, tone, color, effects, composition, text, output

    public static func < (lhs: OpPhase, rhs: OpPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One text in English and French.
public struct Bilingual: Hashable, Codable, Sendable {
    public var en: String
    public var fr: String

    public init(en: String, fr: String) {
        self.en = en
        self.fr = fr
    }

    public func callAsFunction(_ language: OpLanguage) -> String {
        switch language {
        case .en: return en
        case .fr: return fr
        }
    }
}

/// How a number param is read and printed.
public enum OpUnit: String, Codable, Sendable { case percent, signedPercent, fraction, seconds, multiplier, degrees, level255, count, none }

/// The kinds of scene-map things a `ref` param may name.
public enum RefKind: String, Codable, Sendable, CaseIterable {
    case printedText, textLayer, object, freeArea, shape, imageLayer, adjustmentLayer, clip, soundTrack, overlay, caption, page, markup, textHit
    /// A local adjustment (W2): "a1" is `document.localAdjustments[0]`.
    case mask

    /// The letter a ref of this kind starts with ("t3", "l2", "o1").
    public var prefix: Character {
        switch self {
        case .printedText: return "t"
        case .textLayer: return "l"
        case .object: return "o"
        case .freeArea: return "f"
        case .shape: return "s"
        case .imageLayer: return "i"
        case .adjustmentLayer: return "j"
        case .clip: return "c"
        case .soundTrack: return "m"
        case .overlay: return "v"
        case .caption: return "k"
        case .page: return "p"
        case .markup: return "n"
        case .textHit: return "w"
        case .mask: return "a"
        }
    }
}

/// The type of one param.
public indirect enum ParamKind: Hashable, Sendable {
    case enumeration([String])
    case number(ClosedRange<Double>, OpUnit)
    case integer(ClosedRange<Int>)
    /// point and box are in 0…1000, top-left origin.
    case boolean, color, point, box
    case text(maxLength: Int)
    case ref(Set<RefKind>)
    case list(ParamKind, max: Int)
}

/// One argument value.
public enum OpValue: Hashable, Codable, Sendable {
    case number(Double), string(String), bool(Bool), point(PSPoint), box(PSRect), list([OpValue])

    public var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// Whether a param must be given: required, optional (with its default), or one of a group of which one must be given.
public enum Presence: Hashable, Sendable { case required, optional(OpValue?), oneOf(group: String) }

public struct ParamSpec: Hashable, Sendable {
    public var key: String
    public var kind: ParamKind
    public var presence: Presence
    /// At most 40 characters, printed on the card.
    public var doc: String
    /// Folded alias → exact value.
    public var valueAliases: [String: String]
    public var keyAliases: [String]
    /// False keeps the param off the one-line card (still validated and documented): the cards
    /// stay within their 160 characters by showing what a model needs to write the call.
    public var onCard: Bool

    public init(_ key: String, _ kind: ParamKind, _ presence: Presence = .optional(nil), doc: String,
                valueAliases: [String: String] = [:], keyAliases: [String] = [], onCard: Bool = true) {
        self.key = key
        self.kind = kind
        self.presence = presence
        self.doc = doc
        self.valueAliases = valueAliases
        self.keyAliases = keyAliases
        self.onCard = onCard
    }
}

public enum OpCost: String, Sendable { case instant, fast, heavy }

public enum AssetKind: String, Sendable { case image, video, audio, lut, signature }

/// What the document or the device must offer before the operation can run.
public struct OpRequirements: Hashable, Sendable {
    public var subject = false, selection = false, table = false, captions = false, generativeEngine = false
    public var importedLUT = false, nonBaseLayer = false
    /// A local adjustment must exist (W2: maskEdit, maskDelete).
    public var localMask = false
    public var referenceAsset: AssetKind? = nil
    public var cost: OpCost = .instant
    public var geometryChange = false, destructive = false

    public init() {}
}

/// A sentence that should (or should not) call the operation, with the arguments it means.
public struct OpExample: Hashable, Sendable {
    public enum Role: Hashable, Sendable { case positive, paraphrase, negative(expected: OpID?) }

    public var say: String
    public var language: OpLanguage
    public var args: [String: OpValue]
    public var role: Role

    public init(_ say: String, _ language: OpLanguage, _ args: [String: OpValue] = [:], role: Role = .positive) {
        self.say = say
        self.language = language
        self.args = args
        self.role = role
    }
}

/// A piece of editor state a postcondition reads before and after the step.
/// `adjustment(name)`: the adjustment named by the call's argument with that key ("parameter"),
/// else the AdjustmentParameter with that raw value ("noiseReduction").
public enum StateProbe: Hashable, Sendable {
    case adjustment(String), toneCurve, levels, colorMixer, colorGrade, lutIntensity, perspective, lensBlur
    case layerOpacity, layerBlend, layerVisibility, layerOrder, layerCount, textLayerCount, canvasAspect, rotation
    case clipCount, timelineDuration, captions, overlayCount, audioTrackCount, pageCount, markupCount
    /// W2, photo only. localAdjustments and selection: their count under increased/decreased, else a digest of
    /// their content; selectionCoverage: the number.
    case localAdjustments, selection, selectionCoverage
}

public enum Expectation: Hashable, Sendable { case increased, decreased, changed, unchanged, equalsParam(String), delta(Double) }

/// Pixel probe names used in Postcondition.pixels(rawValue, expectation) (W2, D14). Specs list a representative
/// `.pixels(...)`; PixelPostconditions.requests(for:spec:) picks the probes from the parameters the call actually sent.
public enum PixelProbe: String, Codable, Sendable, CaseIterable {
    /// The call's parameter, inside its mask vs outside (direction from parameter and amount sign).
    case maskedParameter
    /// Creation: the mask covers 0.2 %–98 % (and ≥50 % of it inside the target box when one is given).
    case maskCoverageInRange
    /// Edits: mean m moved in the Expectation's direction (expand, contract).
    case maskCoverage
    /// |after − (1 − before)| ≤ 0.02 on mean m.
    case maskInverted
    /// The fraction of pixels with 0.05 < m < 0.95 increased (feather).
    case maskSoftness
    /// The maximum of m decreased (density).
    case maskPeak
    case selectionCoverageInRange
    /// Mean coverage moved in the Expectation's direction.
    case selectionCoverage
    /// selectionApply, per `use`.
    case selectionUse
}

/// What must be true after the step ran.
public enum Postcondition: Hashable, Sendable { case structural(StateProbe, Expectation), pixels(String, Expectation), unverifiable(String) }

/// How much of the operation's vocabulary the rule-based grammar handles.
public enum GrammarOwnership: String, Sendable { case owned, keywordsOnly, none }

/// How the operation runs: as an existing IntentAction, or through a domain handler table (IntentAction.operation).
public enum OpLowering: Hashable, Sendable { case intent(IntentAction), handler }

/// One catalog entry.
public struct OperationSpec: Hashable, Sendable {
    public var id: OpID
    public var domains: Set<OpDomain>
    /// The domains whose stable prompt prefix always carries the card.
    public var coreIn: Set<OpDomain>
    public var category: OpCategory
    public var phase: OpPhase
    public var title: Bilingual
    public var summary: Bilingual
    public var params: [ParamSpec]
    public var requires: OpRequirements
    public var triggers: [OpLanguage: [String]]
    public var avoid: [OpLanguage: [String]]
    public var examples: [OpExample]
    public var verify: [Postcondition]
    public var grammar: GrammarOwnership
    public var fastLane: Bool
    /// PhotoEditorSession.Tool raw value; video and PDF panel ids.
    public var uiTool: String?
    public var lowering: OpLowering
    /// One-of groups whose members exclude each other (a preset or points, never both). In the
    /// other groups at least one member is given and several may be.
    public var exclusiveGroups: Set<String>

    public init(id: OpID, domains: Set<OpDomain>, coreIn: Set<OpDomain> = [], category: OpCategory, phase: OpPhase,
                title: Bilingual, summary: Bilingual, params: [ParamSpec] = [], requires: OpRequirements = OpRequirements(),
                triggers: [OpLanguage: [String]] = [:], avoid: [OpLanguage: [String]] = [:], examples: [OpExample] = [],
                verify: [Postcondition] = [], grammar: GrammarOwnership = .none, fastLane: Bool = false, uiTool: String? = nil,
                lowering: OpLowering, exclusiveGroups: Set<String> = []) {
        self.id = id
        self.domains = domains
        self.coreIn = coreIn
        self.category = category
        self.phase = phase
        self.title = title
        self.summary = summary
        self.params = params
        self.requires = requires
        self.triggers = triggers
        self.avoid = avoid
        self.examples = examples
        self.verify = verify
        self.grammar = grammar
        self.fastLane = fastLane
        self.uiTool = uiTool
        self.lowering = lowering
        self.exclusiveGroups = exclusiveGroups
    }
}

/// A request for one catalog operation with typed arguments: what EditIntent(.operation) carries.
public struct OperationCall: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case model, planner, grammar, ui, idea }

    public var id: OpID
    public var args: [String: OpValue]
    public var source: Source

    public init(_ id: OpID, args: [String: OpValue] = [:], source: Source = .model) {
        self.id = id
        self.args = args
        self.source = source
    }
}
