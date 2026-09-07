import Foundation

/// Every action the voice/LLM layer can request. This is the vocabulary shared
/// by the rule-based parser, the on-device LLM schema and the command executor.
public enum IntentAction: String, Codable, Sendable, CaseIterable {
    // Shared photo & video
    case removeObject
    case removeBackground
    case replaceBackground
    case blurBackground
    case adjust
    case selectiveAdjust
    case applyLook
    case autoEnhance
    case crop
    case setAspect
    case rotate
    case straighten
    case flip
    case addText
    case editText
    case removeText
    case upscale
    case denoise
    case sharpen
    case relight
    case generativeFill
    case recolor
    case undo
    case redo
    case revert
    case compare
    case zoom
    case export
    case share
    case selectLayer
    case duplicateLayer
    case deleteLayer
    // Video only
    case trim
    case split
    case deleteClip
    case deleteRange
    case setSpeed
    case reverse
    case mute
    case unmute
    case setVolume
    case addTransition
    case removeTransition
    case addMusic
    case removeMusic
    case extractFrame
    case seek
    case play
    case pause
    case duplicateClip
    case moveClip
    case stabilize
    case freezeFrame
    // PDF only
    case deletePage
    case rotatePage
    case movePage
    case duplicatePage
    case insertBlankPage
    case goToPage
    case highlightText
    case underlineText
    case redactText
    case findText
    case addSignature
    case extractPage
    case addPageNumbers
    case mergeDocument
    // Meta / dialogue
    case chooseCandidate
    case confirm
    case cancel
    case help
    case unknown

    public var isVideoOnly: Bool {
        switch self {
        case .trim, .split, .deleteClip, .deleteRange, .setSpeed, .reverse, .mute, .unmute, .setVolume,
             .addTransition, .removeTransition, .addMusic, .removeMusic, .extractFrame, .seek, .play, .pause,
             .duplicateClip, .moveClip, .stabilize, .freezeFrame:
            return true
        default:
            return false
        }
    }

    public var isPhotoOnly: Bool {
        switch self {
        case .selectLayer, .duplicateLayer, .deleteLayer, .upscale, .relight, .generativeFill, .recolor: return true
        default: return false
        }
    }

    public var isPDFOnly: Bool {
        switch self {
        case .deletePage, .rotatePage, .movePage, .duplicatePage, .insertBlankPage, .goToPage, .highlightText, .underlineText, .redactText, .findText,
             .addSignature, .extractPage, .addPageNumbers, .mergeDocument:
            return true
        default:
            return false
        }
    }

    public var isMeta: Bool {
        switch self {
        case .chooseCandidate, .confirm, .cancel, .help, .unknown, .undo, .redo, .compare, .zoom, .play, .pause, .seek: return true
        default: return false
        }
    }
}

/// Where in the frame the user pointed with words ("the one on the left").
public enum SpatialHint: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom, center, foreground, background, largest, smallest, leftmost, rightmost, nearest, farthest

    public var aliases: [String] {
        switch self {
        case .left: return ["left", "on the left", "gauche", "a gauche", "de gauche", "sur la gauche"]
        case .right: return ["right", "on the right", "droite", "a droite", "de droite", "sur la droite"]
        case .top: return ["top", "at the top", "upper", "above", "haut", "en haut", "du haut", "au-dessus", "au dessus"]
        case .bottom: return ["bottom", "at the bottom", "lower", "below", "bas", "en bas", "du bas", "en dessous", "au-dessous"]
        case .center: return ["center", "centre", "middle", "in the middle", "au centre", "au milieu", "du milieu", "central"]
        case .foreground: return ["foreground", "in front", "front", "premier plan", "au premier plan", "devant"]
        case .background: return ["in the background", "behind", "arriere-plan", "arriere plan", "au fond", "derriere", "dans le fond"]
        case .largest: return ["largest", "biggest", "big", "large", "le plus grand", "la plus grande", "le gros", "la grosse", "grand", "grande", "gros", "grosse"]
        case .smallest: return ["smallest", "tiny", "small", "little", "le plus petit", "la plus petite", "petit", "petite"]
        case .leftmost: return ["leftmost", "far left", "tout a gauche", "completement a gauche"]
        case .rightmost: return ["rightmost", "far right", "tout a droite", "completement a droite"]
        case .nearest: return ["closest", "nearest", "le plus proche", "la plus proche"]
        case .farthest: return ["farthest", "furthest", "le plus loin", "la plus loin", "au loin"]
        }
    }
}

/// A natural-language reference to something in the image or frame.
public struct ObjectTarget: Hashable, Codable, Sendable {
    /// Canonical English noun ("dog", "person", "car"), singular, lower case.
    public var label: String
    /// The words the user actually said, for UI echo.
    public var originalPhrase: String
    public var spatialHint: SpatialHint?
    /// "the second person" → 2
    public var ordinal: Int?
    /// "all the people" → true
    public var matchesAll: Bool
    /// Extra descriptive words (colour, clothing…) that help ranking.
    public var attributes: [String]
    /// Normalised tap location if the user pointed at the object.
    public var point: PSPoint?

    public init(label: String, originalPhrase: String? = nil, spatialHint: SpatialHint? = nil, ordinal: Int? = nil,
                matchesAll: Bool = false, attributes: [String] = [], point: PSPoint? = nil) {
        self.label = label
        self.originalPhrase = originalPhrase ?? label
        self.spatialHint = spatialHint
        self.ordinal = ordinal
        self.matchesAll = matchesAll
        self.attributes = attributes
        self.point = point
    }
}

/// How much to change something.
public struct AmountSpec: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// `value` is the final normalised value.
        case absolute
        /// `value` is added to the current normalised value.
        case relative
        /// `value` is a multiplier (speed, zoom).
        case multiplier
    }

    public var mode: Mode
    public var value: Double

    public init(mode: Mode, value: Double) {
        self.mode = mode
        self.value = value
    }

    public static func absolute(_ value: Double) -> AmountSpec { AmountSpec(mode: .absolute, value: value) }
    public static func relative(_ value: Double) -> AmountSpec { AmountSpec(mode: .relative, value: value) }
    public static func multiplier(_ value: Double) -> AmountSpec { AmountSpec(mode: .multiplier, value: value) }

    public static let slightlyMore = AmountSpec.relative(0.12)
    public static let more = AmountSpec.relative(0.2)
    public static let muchMore = AmountSpec.relative(0.4)
    public static let slightlyLess = AmountSpec.relative(-0.12)
    public static let less = AmountSpec.relative(-0.2)
    public static let muchLess = AmountSpec.relative(-0.4)
    public static let maximum = AmountSpec.absolute(1)
    public static let reset = AmountSpec.absolute(0)

    /// Resolves against the current value of a parameter.
    public func resolve(current: Double, range: ClosedRange<Double>) -> Double {
        switch mode {
        case .absolute: return value.clamped(to: range)
        case .relative: return (current + value).clamped(to: range)
        case .multiplier: return (current * value).clamped(to: range)
        }
    }
}

public enum BackgroundSpec: Hashable, Codable, Sendable {
    case transparent
    case color(PSColor)
    case blur(Double)
    case white
    case black
    case gradient(PSColor, PSColor)
}

/// Which items a video command applies to.
public enum TargetScope: String, Codable, Sendable {
    case current
    case all
    case selection
    case range
}

/// One executable request. Optional fields are populated according to `action`.
public struct EditIntent: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var action: IntentAction
    public var target: ObjectTarget?
    public var parameter: AdjustmentParameter?
    public var amount: AmountSpec?
    public var look: FilterPreset?
    public var aspect: AspectPreset?
    public var degrees: Double?
    public var flipAxis: FlipAxis?
    public var text: String?
    public var placement: TextElement.Placement?
    public var color: PSColor?
    public var background: BackgroundSpec?
    public var timeRange: TimeSpan?
    public var time: Double?
    public var clipIndex: Int?
    public var transition: TransitionKind?
    public var index: Int?
    public var scope: TargetScope
    public var confidence: Double

    public init(id: UUID = UUID(), action: IntentAction, target: ObjectTarget? = nil, parameter: AdjustmentParameter? = nil,
                amount: AmountSpec? = nil, look: FilterPreset? = nil, aspect: AspectPreset? = nil, degrees: Double? = nil,
                flipAxis: FlipAxis? = nil, text: String? = nil, placement: TextElement.Placement? = nil, color: PSColor? = nil,
                background: BackgroundSpec? = nil, timeRange: TimeSpan? = nil, time: Double? = nil, clipIndex: Int? = nil,
                transition: TransitionKind? = nil, index: Int? = nil, scope: TargetScope = .current, confidence: Double = 1) {
        self.id = id
        self.action = action
        self.target = target
        self.parameter = parameter
        self.amount = amount
        self.look = look
        self.aspect = aspect
        self.degrees = degrees
        self.flipAxis = flipAxis
        self.text = text
        self.placement = placement
        self.color = color
        self.background = background
        self.timeRange = timeRange
        self.time = time
        self.clipIndex = clipIndex
        self.transition = transition
        self.index = index
        self.scope = scope
        self.confidence = confidence
    }

    /// Short human description shown in the command feedback chip.
    public var summary: String {
        switch action {
        case .removeObject: return "Remove \(target?.originalPhrase ?? "object")"
        case .removeBackground: return "Remove background"
        case .replaceBackground: return "Replace background"
        case .blurBackground: return "Blur background"
        case .adjust:
            let name = parameter?.englishName ?? "Adjust"
            guard let amount else { return name }
            switch amount.mode {
            case .absolute: return "\(name) → \(Int((amount.value * 100).rounded()))"
            case .relative: return "\(name) \(amount.value >= 0 ? "+" : "")\(Int((amount.value * 100).rounded()))"
            case .multiplier: return "\(name) ×\(amount.value)"
            }
        case .selectiveAdjust: return "Adjust \(target?.originalPhrase ?? "selection")"
        case .applyLook: return "Look: \(look?.englishName ?? "")"
        case .autoEnhance: return "Auto enhance"
        case .crop, .setAspect: return "Crop \(aspect?.displayName ?? "")"
        case .rotate: return "Rotate \(Int(degrees ?? 90))°"
        case .straighten: return "Straighten"
        case .flip: return flipAxis == .vertical ? "Flip vertical" : "Flip horizontal"
        case .addText: return "Add text “\(text ?? "")”"
        case .editText: return "Edit text"
        case .removeText: return "Remove text"
        case .upscale: return "Upscale"
        case .denoise: return "Reduce noise"
        case .sharpen: return "Sharpen"
        case .relight: return "Relight"
        case .generativeFill: return "Generate “\(text ?? "")”"
        case .recolor: return "Recolor \(target?.originalPhrase ?? "")"
        case .deletePage: return "Delete page"
        case .rotatePage: return "Rotate page"
        case .movePage: return "Move page"
        case .duplicatePage: return "Duplicate page"
        case .insertBlankPage: return "Insert page"
        case .goToPage: return "Go to page \(index ?? 1)"
        case .highlightText: return "Highlight “\(text ?? "")”"
        case .underlineText: return "Underline “\(text ?? "")”"
        case .redactText: return "Redact “\(text ?? "")”"
        case .findText: return "Find “\(text ?? "")”"
        case .addSignature: return "Add signature"
        case .extractPage: return "Extract page"
        case .addPageNumbers: return "Page numbers"
        case .mergeDocument: return "Merge PDF"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .revert: return "Revert to original"
        case .compare: return "Compare"
        case .zoom: return "Zoom"
        case .export: return "Export"
        case .share: return "Share"
        case .selectLayer: return "Select layer"
        case .duplicateLayer: return "Duplicate layer"
        case .deleteLayer: return "Delete layer"
        case .trim: return "Trim"
        case .split: return "Split clip"
        case .deleteClip: return "Delete clip"
        case .deleteRange: return "Delete range"
        case .setSpeed: return "Speed ×\(amount?.value ?? 1)"
        case .reverse: return "Reverse"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .setVolume: return "Volume"
        case .addTransition: return "Transition: \(transition?.displayName ?? "")"
        case .removeTransition: return "Remove transition"
        case .addMusic: return "Add music"
        case .removeMusic: return "Remove music"
        case .extractFrame: return "Extract frame"
        case .seek: return "Go to \(time ?? 0)s"
        case .play: return "Play"
        case .pause: return "Pause"
        case .duplicateClip: return "Duplicate clip"
        case .moveClip: return "Move clip"
        case .stabilize: return "Stabilize"
        case .freezeFrame: return "Freeze frame"
        case .chooseCandidate: return "Choose"
        case .confirm: return "Confirm"
        case .cancel: return "Cancel"
        case .help: return "Help"
        case .unknown: return "Not understood"
        }
    }
}

public enum IntentEngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Deterministic grammar, instant, always available.
    case rules
    /// Apple on-device foundation model (Apple Intelligence).
    case appleIntelligence
    /// Optional larger on-device model through MLX (Pro Brain).
    case proLocal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rules: return "Instant"
        case .appleIntelligence: return "Apple Intelligence"
        case .proLocal: return "Pro Brain"
        }
    }
}

/// What the language layer produced for one utterance.
public struct EditPlan: Hashable, Codable, Sendable {
    public var utterance: String
    public var intents: [EditIntent]
    public var confidence: Double
    /// BCP-47 language of the utterance, if detected.
    public var language: String?
    /// A short spoken/visual reply ("Done, removed the dog.").
    public var reply: String?
    /// Question to ask when the request is ambiguous.
    public var clarification: String?
    public var engine: IntentEngineKind

    public init(utterance: String, intents: [EditIntent], confidence: Double = 1, language: String? = nil, reply: String? = nil,
                clarification: String? = nil, engine: IntentEngineKind = .rules) {
        self.utterance = utterance
        self.intents = intents
        self.confidence = confidence
        self.language = language
        self.reply = reply
        self.clarification = clarification
        self.engine = engine
    }

    public var isEmpty: Bool { intents.isEmpty || intents.allSatisfy { $0.action == .unknown } }
    public var needsClarification: Bool { clarification != nil }

    public static func unknown(_ utterance: String, engine: IntentEngineKind = .rules) -> EditPlan {
        EditPlan(utterance: utterance, intents: [EditIntent(action: .unknown, confidence: 0)], confidence: 0, engine: engine)
    }
}

/// A detected object the executor may ask the user to pick from.
public struct ObjectCandidate: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var boundingBox: PSRect
    public var confidence: Double
    /// Index of the instance in the segmentation result, if any.
    public var instanceIndex: Int?
    public var maskPath: String?

    public init(id: UUID = UUID(), label: String, boundingBox: PSRect, confidence: Double, instanceIndex: Int? = nil, maskPath: String? = nil) {
        self.id = id
        self.label = label
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.instanceIndex = instanceIndex
        self.maskPath = maskPath
    }

    public var spokenDescription: String {
        let horizontal: String
        switch boundingBox.midX {
        case ..<0.34: horizontal = "left"
        case 0.66...: horizontal = "right"
        default: horizontal = "center"
        }
        return "\(label) (\(horizontal))"
    }
}

/// Raised by the executor when it needs the user to disambiguate.
public struct ClarificationRequest: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var question: String
    public var candidates: [ObjectCandidate]
    public var pendingIntent: EditIntent

    public init(id: UUID = UUID(), question: String, candidates: [ObjectCandidate], pendingIntent: EditIntent) {
        self.id = id
        self.question = question
        self.candidates = candidates
        self.pendingIntent = pendingIntent
    }
}

/// Outcome of executing one intent.
public enum CommandOutcome: Hashable, Sendable {
    case applied(label: String)
    case info(message: String)
    case needsClarification(ClarificationRequest)
    case failed(message: String)
    case ignored

    public var isSuccess: Bool {
        if case .applied = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .applied(let label): return label
        case .info(let message): return message
        case .needsClarification(let request): return request.question
        case .failed(let message): return message
        case .ignored: return nil
        }
    }
}
