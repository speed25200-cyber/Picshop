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
    /// For replaceText: the new words.
    public var replacement: String?
    /// Where the object is in the last image the model saw (0...1, top-left origin).
    public var point: PSPoint?
    /// Words that tell the object apart: a colour, clothing ("red", "blue shirt").
    public var attributes: [String]?

    public init(action: String, target: String? = nil, spatialHint: String? = nil, ordinal: Int? = nil, all: Bool? = nil, parameter: String? = nil,
                amountMode: String? = nil, amount: Double? = nil, look: String? = nil, aspect: String? = nil, degrees: Double? = nil, flipAxis: String? = nil,
                text: String? = nil, placement: String? = nil, color: String? = nil, background: String? = nil, startSeconds: Double? = nil,
                endSeconds: Double? = nil, seconds: Double? = nil, clipNumber: Int? = nil, transition: String? = nil, speed: Double? = nil,
                choiceIndex: Int? = nil, scope: String? = nil, replacement: String? = nil, point: PSPoint? = nil, attributes: [String]? = nil) {
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
        self.replacement = replacement
        self.point = point
        self.attributes = attributes
    }
}

/// What a step's `amount` counts, per action. Models say amounts the way the
/// prompt documents them (percent, seconds, a multiplier); the executors read
/// normalised values, so each unit converts differently.
public enum AmountUnit: Sendable, Equatable {
    /// -100...100 style: divided by 100.
    case percent(ClosedRange<Double>)
    /// Already a fraction; a value above 1 is read as a percentage.
    case fraction(ClosedRange<Double>)
    case seconds(ClosedRange<Double>)
    case multiplier(ClosedRange<Double>)

    /// The range the model may use, in the unit's own terms.
    public var range: ClosedRange<Double> {
        switch self {
        case .percent(let range), .fraction(let range), .seconds(let range), .multiplier(let range): return range
        }
    }

    /// The unit table; nil for actions whose amount keeps the historical reading.
    public static func `for`(_ action: IntentAction) -> AmountUnit? {
        switch action {
        case .adjust, .selectiveAdjust: return .percent(-100...100)
        case .applyLook, .blurBackground, .autoEnhance, .denoise, .sharpen: return .percent(0...100)
        case .setVolume: return .percent(0...200)
        case .moveObject: return .fraction(0.05...0.5)
        case .removeSilences: return .fraction(0.2...0.45)
        case .autoDuck: return .fraction(0...0.9)
        case .recolor, .splitScenes: return .fraction(0...1)
        case .fadeAudio: return .seconds(0...10)
        case .highlights: return .seconds(5...300)
        case .upscale: return .multiplier(2...4)
        case .punchIns: return .multiplier(1...1.5)
        case .speedRamp: return .multiplier(0.1...1)
        case .setSpeed: return .multiplier(0.1...8)
        default: return nil
        }
    }

    /// The range a validated amount must fall in. Relative percentages may go both ways.
    public func acceptedRange(mode: AmountSpec.Mode) -> ClosedRange<Double> {
        switch self {
        case .percent(let range):
            if mode == .multiplier { return 0...4 }
            return mode == .relative ? -range.upperBound...range.upperBound : range
        default:
            return range
        }
    }

    /// Converts a model amount into the executor's AmountSpec, clamped to the table.
    public func spec(_ amount: Double, mode: AmountSpec.Mode) -> AmountSpec {
        switch self {
        case .percent(let range):
            if mode == .multiplier { return .multiplier(amount.clamped(to: 0...4)) }
            let accepted = mode == .relative ? -range.upperBound...range.upperBound : range
            return AmountSpec(mode: mode, value: amount.clamped(to: accepted) / 100)
        case .fraction(let range):
            let value = abs(amount) > 1 ? amount / 100 : amount
            return .absolute(value.clamped(to: range))
        case .seconds(let range), .multiplier(let range):
            return .absolute(amount.clamped(to: range))
        }
    }

    /// Actions whose amount 0 means "take it off" even though 0 is outside their range.
    public static func removesAtZero(_ action: IntentAction) -> Bool {
        action == .punchIns
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
        // Exact names first: the fuzzy lookups lower-case camelCase names (noiseReduction) and mix up neighbours (slideRight).
        if let parameter = step.parameter { intent.parameter = AdjustmentParameter(rawValue: parameter) ?? ParameterVocabulary.parameter(named: parameter) }
        if let point = step.point {
            // A point alone still names something: whatever is there.
            if intent.target == nil { intent.target = ObjectTarget(label: "object", originalPhrase: "object") }
            intent.target?.point = PSPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1))
        }
        if let attributes = step.attributes?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }), !attributes.isEmpty, intent.target != nil {
            intent.target?.attributes = attributes
        }
        if let amount = step.amount, amount.isFinite {
            let mode: AmountSpec.Mode
            switch step.amountMode?.lowercased() {
            case "absolute", "set", "to": mode = .absolute
            case "multiplier", "multiply", "times": mode = .multiplier
            default: mode = .relative
            }
            if AmountUnit.removesAtZero(action), amount <= 0.01 {
                intent.amount = .absolute(0)
            } else if let unit = AmountUnit.for(action) {
                intent.amount = unit.spec(amount, mode: mode)
            } else {
                // Actions outside the unit table keep the historical reading.
                var value = amount
                if mode != .multiplier, abs(value) > 1 { value /= 100 }
                intent.amount = AmountSpec(mode: mode, value: mode == .multiplier ? value : value.clamped(to: -1...1))
            }
        }
        if let look = step.look { intent.look = FilterPreset(rawValue: look) ?? FilterPreset.matching(look) }
        if let aspect = step.aspect { intent.aspect = AspectPreset(rawValue: aspect) ?? AspectPreset.matching(aspect) }
        if let degrees = step.degrees { intent.degrees = degrees }
        if let axis = step.flipAxis?.lowercased() { intent.flipAxis = axis.hasPrefix("v") ? .vertical : .horizontal }
        if let text = step.text, !text.isEmpty { intent.text = text }
        if let replacement = step.replacement, !replacement.isEmpty { intent.replacement = replacement }
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
        if let transition = step.transition { intent.transition = TransitionKind(rawValue: transition) ?? TransitionKind.matching(transition) }
        if let speed = step.speed, speed > 0 { intent.amount = .absolute(speed.clamped(to: 0.1...8)) }
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
        case .highlights:
            // The recap's length is in seconds, never a percentage.
            let length = step.seconds ?? step.amount.map { abs($0) }
            intent.amount = length.flatMap { $0 >= 5 ? .absolute(min($0, 300)) : nil }
            intent.time = nil
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
            "rotation": .rotate, "turn": .rotate, "mirror": .flip, "upright": .resetOrientation, "rightwayup": .resetOrientation, "resetorientation": .resetOrientation, "unflip": .resetOrientation, "text": .addText, "caption": .addText, "title": .addText, "superresolution": .upscale,
            "resolution": .upscale, "noise": .denoise, "noisereduction": .denoise, "cut": .split, "splitclip": .split, "trimclip": .trim, "cutrange": .deleteRange,
            "removerange": .deleteRange, "removeclip": .deleteClip, "speed": .setSpeed, "slowmotion": .setSpeed, "volume": .setVolume, "transition": .addTransition,
            "music": .addMusic, "soundtrack": .addMusic, "screenshot": .extractFrame, "frame": .extractFrame, "goto": .seek, "jump": .seek, "choose": .chooseCandidate,
            "select": .chooseCandidate, "pick": .chooseCandidate, "yes": .confirm, "no": .cancel, "none": .unknown, "unknown": .unknown, "compare": .compare,
            "reset": .revert, "revertall": .revert, "save": .export, "download": .export,
            "translatecaptions": .translateCaptions, "translatesubtitles": .translateCaptions, "translate": .translateCaptions,
            "subtitles": .autoCaptions, "subtitle": .autoCaptions, "captions": .autoCaptions, "autocaption": .autoCaptions, "transcribe": .autoCaptions,
            "jumpcut": .removeSilences, "jumpcuts": .removeSilences, "removesilence": .removeSilences, "cutsilences": .removeSilences, "removepauses": .removeSilences,
            "animatetext": .animateText, "animatetitle": .animateText, "textanimation": .animateText, "titleanimation": .animateText,
            "punchins": .punchIns, "punchin": .punchIns, "zoomcuts": .punchIns, "zoomcut": .punchIns,
            "speedramp": .speedRamp, "ramp": .speedRamp, "slowmoramp": .speedRamp, "timeramp": .speedRamp,
            "highlights": .highlights, "highlightreel": .highlights, "recap": .highlights, "bestmoments": .highlights, "summary": .highlights, "summarize": .highlights,
            "splitscenes": .splitScenes, "scenedetect": .splitScenes, "scenedetection": .splitScenes, "detectscenes": .splitScenes, "shotdetection": .splitScenes,
            "track": .trackSubject, "tracksubject": .trackSubject, "follow": .trackSubject, "followsubject": .trackSubject, "motiontrack": .trackSubject, "pin": .trackSubject,
            "autoduck": .autoDuck, "ducking": .autoDuck, "duck": .autoDuck, "duckmusic": .autoDuck, "autoducking": .autoDuck,
            "removefillers": .removeFillers, "fillers": .removeFillers, "removefillerwords": .removeFillers, "removeums": .removeFillers, "cutfillers": .removeFillers, "removehesitations": .removeFillers,
            "cutwords": .cutWords, "removewords": .cutWords, "deletewords": .cutWords, "cutphrase": .cutWords, "cuttext": .cutWords, "textcut": .cutWords,
            "blurfaces": .blurFaces, "anonymize": .blurFaces, "anonymise": .blurFaces, "hidefaces": .blurFaces, "pixelatefaces": .blurFaces,
            "fitmusic": .fitMusic, "fitthemusic": .fitMusic, "musicfit": .fitMusic, "endmusic": .fitMusic,
            "beatsync": .syncToBeat, "cuttobeat": .syncToBeat, "synctomusic": .syncToBeat, "reframe": .smartReframe, "autoreframe": .smartReframe,
            "voiceisolation": .enhanceVoice, "isolatevoice": .enhanceVoice, "cleanaudio": .enhanceVoice, "denoiseaudio": .enhanceVoice,
            "blurobject": .blurObject, "blurregion": .blurObject, "pixelate": .blurObject,
            "autocrop": .autoCrop, "bestcrop": .autoCrop, "smartcrop": .autoCrop,
            "cleanup": .cleanUp, "removedistractions": .cleanUp, "removepassersby": .cleanUp, "removetourists": .cleanUp,
            "textbehind": .textBehind, "textbehindsubject": .textBehind, "deptheffect": .textBehind,
            "moveobject": .moveObject, "magicmove": .moveObject, "shiftobject": .moveObject, "reposition": .moveObject,
            "outpaint": .expandCanvas, "uncrop": .expandCanvas, "expand": .expandCanvas, "expandcanvas": .expandCanvas, "extend": .expandCanvas, "generativeexpand": .expandCanvas,
            "colormatch": .matchColor, "matchcolors": .matchColor, "matchcolours": .matchColor, "panzoom": .kenBurns,
        ]
        return aliases[lowered]
    }
}
