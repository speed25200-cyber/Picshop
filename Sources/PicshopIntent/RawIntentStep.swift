import Foundation
import PicshopCore

/// Loosely-typed step as produced by a language model (Foundation Models
/// guided generation or JSON from the MLX model). `IntentNormalizer` turns it
/// into a strongly-typed `EditIntent`, validating every field against the app
/// vocabulary so hallucinated values can never reach the executor.
public struct RawIntentStep: Codable, Sendable, Equatable {
    public var action: String
    public var target: String?
    public var spatialHint: String?
    public var ordinal: Int?
    public var all: Bool?
    public var parameter: String?
    public var amountMode: String?
    public var amount: Double?
    public var look: String?
    public var aspect: String?
    public var degrees: Double?
    public var flipAxis: String?
    public var text: String?
    public var placement: String?
    public var color: String?
    public var background: String?
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var seconds: Double?
    public var clipNumber: Int?
    public var transition: String?
    public var speed: Double?
    public var choiceIndex: Int?
    public var scope: String?

    public init(action: String, target: String? = nil, spatialHint: String? = nil, ordinal: Int? = nil, all: Bool? = nil, parameter: String? = nil,
                amountMode: String? = nil, amount: Double? = nil, look: String? = nil, aspect: String? = nil, degrees: Double? = nil, flipAxis: String? = nil,
                text: String? = nil, placement: String? = nil, color: String? = nil, background: String? = nil, startSeconds: Double? = nil,
                endSeconds: Double? = nil, seconds: Double? = nil, clipNumber: Int? = nil, transition: String? = nil, speed: Double? = nil,
                choiceIndex: Int? = nil, scope: String? = nil) {
        self.action = action
        self.target = target
        self.spatialHint = spatialHint
        self.ordinal = ordinal
        self.all = all
        self.parameter = parameter
        self.amountMode = amountMode
        self.amount = amount
        self.look = look
        self.aspect = aspect
        self.degrees = degrees
        self.flipAxis = flipAxis
        self.text = text
        self.placement = placement
        self.color = color
        self.background = background
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.seconds = seconds
        self.clipNumber = clipNumber
        self.transition = transition
        self.speed = speed
        self.choiceIndex = choiceIndex
        self.scope = scope
    }
}

/// The complete model response.
public struct RawPlan: Codable, Sendable, Equatable {
    public var steps: [RawIntentStep]
    public var reply: String?
    public var clarification: String?
    public var language: String?

    public init(steps: [RawIntentStep], reply: String? = nil, clarification: String? = nil, language: String? = nil) {
        self.steps = steps
        self.reply = reply
        self.clarification = clarification
        self.language = language
    }
}

/// Validates model output against the app vocabulary.
public enum IntentNormalizer {
    public static func plan(from raw: RawPlan, utterance: String, context: IntentContext, engine: IntentEngineKind) -> EditPlan {
        let intents = raw.steps.compactMap { normalize($0, context: context) }
        let language: NormalizedUtterance.Language = (raw.language ?? NormalizedUtterance(utterance).language.rawValue).hasPrefix("fr") ? .french : .english
        let reply = raw.reply?.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence: Double = intents.isEmpty ? 0 : (intents.allSatisfy { $0.action != .unknown } ? 0.85 : 0.4)
        return EditPlan(utterance: utterance, intents: intents.isEmpty ? [EditIntent(action: .unknown, confidence: 0)] : intents, confidence: confidence,
                        language: language.rawValue, reply: (reply?.isEmpty ?? true) ? Replies.combined(for: intents, language: language) : reply,
                        clarification: raw.clarification?.isEmpty == false ? raw.clarification : nil, engine: engine)
    }

    public static func normalize(_ step: RawIntentStep, context: IntentContext) -> EditIntent? {
        guard let action = action(named: step.action) else { return nil }
        var intent = EditIntent(action: action, confidence: 0.85)

        if let target = step.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            let engine = RuleBasedIntentEngine()
            var object = engine.makeTarget(from: target, context: context) ?? ObjectTarget(label: target.normalizedForMatching, originalPhrase: target)
            if let hint = step.spatialHint, let spatial = SpatialHint(rawValue: hint.normalizedForMatching) ?? SpatialHint.allCases.first(where: { $0.aliases.contains(hint.normalizedForMatching) }) {
                object.spatialHint = spatial
            }
            if let ordinal = step.ordinal, ordinal > 0 { object.ordinal = ordinal }
            if step.all == true { object.matchesAll = true }
            intent.target = object
        }
        if let parameter = step.parameter { intent.parameter = ParameterVocabulary.parameter(named: parameter) }
        if let amount = step.amount {
            let mode: AmountSpec.Mode
            switch step.amountMode?.lowercased() {
            case "absolute", "set", "to": mode = .absolute
            case "multiplier", "multiply", "times": mode = .multiplier
            default: mode = .relative
            }
            var value = amount
            if mode != .multiplier, abs(value) > 1 { value /= 100 }
            intent.amount = AmountSpec(mode: mode, value: mode == .multiplier ? value : value.clamped(to: -1...1))
        }
        if let look = step.look { intent.look = FilterPreset.matching(look) }
        if let aspect = step.aspect { intent.aspect = AspectPreset.matching(aspect) ?? AspectPreset(rawValue: aspect) }
        if let degrees = step.degrees { intent.degrees = degrees }
        if let axis = step.flipAxis?.lowercased() { intent.flipAxis = axis.hasPrefix("v") ? .vertical : .horizontal }
        if let text = step.text, !text.isEmpty { intent.text = text }
        if let placement = step.placement { intent.placement = TextElement.Placement(rawValue: placement) ?? RuleBasedIntentEngine.placementPhrases[placement.normalizedForMatching] }
        if let color = step.color { intent.color = PSColor.named(color) ?? PSColor(hex: color) }
        if let background = step.background?.lowercased() {
            if background == "transparent" || background == "none" { intent.background = .transparent }
            else if background.hasPrefix("blur") { intent.background = .blur(0.65) }
            else if let color = PSColor.named(background) ?? PSColor(hex: background) { intent.background = .color(color); intent.color = color }
        }
        if let start = step.startSeconds, let end = step.endSeconds, end > start { intent.timeRange = TimeSpan(start: start, end: end) }
        else if let start = step.startSeconds, step.endSeconds == nil, action == .deleteRange { intent.timeRange = TimeSpan(start: start, end: context.timelineDuration) }
        if let seconds = step.seconds { intent.time = seconds }
        if let clip = step.clipNumber, clip != 0 { intent.clipIndex = clip }
        if let transition = step.transition { intent.transition = TransitionKind.matching(transition) ?? TransitionKind(rawValue: transition) }
        if let speed = step.speed, speed > 0 { intent.amount = .absolute(speed) }
        if let choice = step.choiceIndex, choice > 0 { intent.index = choice }
        if let scope = step.scope, let resolved = TargetScope(rawValue: scope.lowercased()) { intent.scope = resolved }

        // Sanity rules: actions that need a payload.
        switch action {
        case .removeObject where intent.target == nil: return nil
        case .adjust where intent.parameter == nil: return nil
        case .applyLook where intent.look == nil: intent.confidence = 0.5
        case .addText where intent.text == nil: intent.confidence = 0.5
        case .setSpeed where intent.amount == nil: intent.amount = .absolute(2)
        case .rotate where intent.degrees == nil: intent.degrees = 90
        case .crop, .setAspect:
            if intent.aspect == nil, intent.target == nil { intent.aspect = .free }
        case .seek where intent.time == nil: return nil
        case .split where intent.time == nil: intent.time = context.playheadSeconds
        default: break
        }
        if action.isVideoOnly, context.mode != .video { return nil }
        if action.isPhotoOnly, context.mode != .photo { return nil }
        if action.isPDFOnly, context.mode != .pdf { return nil }
        if action.isPDFOnly, intent.index == nil, let page = intent.clipIndex { intent.index = page }
        return intent
    }

    public static func action(named name: String) -> IntentAction? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = IntentAction(rawValue: key) { return direct }
        let lowered = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        for action in IntentAction.allCases where action.rawValue.lowercased() == lowered {
            return action
        }
        let aliases: [String: IntentAction] = [
            "remove": .removeObject, "erase": .removeObject, "delete": .removeObject, "removeobject": .removeObject, "eraseobject": .removeObject,
            "inpaint": .removeObject, "heal": .removeObject, "cutout": .removeBackground, "removebg": .removeBackground, "backgroundremove": .removeBackground,
            "changebackground": .replaceBackground, "setbackground": .replaceBackground, "portrait": .blurBackground, "bokeh": .blurBackground,
            "adjustment": .adjust, "set": .adjust, "increase": .adjust, "decrease": .adjust, "filter": .applyLook, "look": .applyLook, "preset": .applyLook,
            "enhance": .autoEnhance, "auto": .autoEnhance, "autoenhance": .autoEnhance, "improve": .autoEnhance, "aspect": .setAspect, "aspectratio": .setAspect,
            "rotation": .rotate, "turn": .rotate, "mirror": .flip, "text": .addText, "caption": .addText, "title": .addText, "superresolution": .upscale,
            "resolution": .upscale, "noise": .denoise, "noisereduction": .denoise, "cut": .split, "splitclip": .split, "trimclip": .trim, "cutrange": .deleteRange,
            "removerange": .deleteRange, "removeclip": .deleteClip, "speed": .setSpeed, "slowmotion": .setSpeed, "volume": .setVolume, "transition": .addTransition,
            "music": .addMusic, "soundtrack": .addMusic, "screenshot": .extractFrame, "frame": .extractFrame, "goto": .seek, "jump": .seek, "choose": .chooseCandidate,
            "select": .chooseCandidate, "pick": .chooseCandidate, "yes": .confirm, "no": .cancel, "none": .unknown, "unknown": .unknown, "compare": .compare,
            "reset": .revert, "revertall": .revert, "save": .export, "download": .export,
        ]
        return aliases[lowered]
    }
}
