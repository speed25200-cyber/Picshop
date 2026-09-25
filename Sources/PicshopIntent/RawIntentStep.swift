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
    /// Table steps: "empty" (the default: only empty cells) or "all".
    public var cells: String?
    /// Table steps: a row label or number ("3", "-1", "last"); several joined with "|".
    public var row: String?
    /// Table steps: a column header or number; several joined with "|".
    public var column: String?
    /// Table steps: "random" | "sequence" | "plausible" | "list" (text = the constant, or the list joined with "|").
    public var values: String?
    public var min: Double?
    public var max: Double?
    public var decimals: Int?
    /// Photo primitives: a scene-map id, "t3" (printed text), "l2" (text layer), "o1" (object), "f1" (free area).
    public var ref: String?
    /// Photo primitives: a box (0...1, top-left origin) to erase, or to lay text out in.
    public var box: PSRect?
    /// Text size: small | medium | large | title | bigger | smaller | match, "x1.5", or a font size as a
    /// fraction of the picture height (a number above 1 is read in thousandths).
    public var size: String?
    /// regular | medium | semibold | bold.
    public var weight: String?
    /// left | center | right.
    public var align: String?
    /// sans | serif | mono | rounded.
    public var font: String?
    /// Copy the style of: "nearby" (the text next to it) or a scene-map id ("t3").
    public var match: String?

    public init(action: String, target: String? = nil, spatialHint: String? = nil, ordinal: Int? = nil, all: Bool? = nil, parameter: String? = nil,
                amountMode: String? = nil, amount: Double? = nil, look: String? = nil, aspect: String? = nil, degrees: Double? = nil, flipAxis: String? = nil,
                text: String? = nil, placement: String? = nil, color: String? = nil, background: String? = nil, startSeconds: Double? = nil,
                endSeconds: Double? = nil, seconds: Double? = nil, clipNumber: Int? = nil, transition: String? = nil, speed: Double? = nil,
                choiceIndex: Int? = nil, scope: String? = nil, replacement: String? = nil, point: PSPoint? = nil, attributes: [String]? = nil,
                cells: String? = nil, row: String? = nil, column: String? = nil, values: String? = nil, min: Double? = nil, max: Double? = nil,
                decimals: Int? = nil, ref: String? = nil, box: PSRect? = nil, size: String? = nil, weight: String? = nil, align: String? = nil,
                font: String? = nil, match: String? = nil) {
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
        self.cells = cells
        self.row = row
        self.column = column
        self.values = values
        self.min = min
        self.max = max
        self.decimals = decimals
        self.ref = ref
        self.box = box
        self.size = size
        self.weight = weight
        self.align = align
        self.font = font
        self.match = match
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
        guard var action = action(named: step.action) else { return nil }
        // On a photo, "replace this text" is an edit of the text block, never the PDF action.
        let replacesPhotoText = action == .replaceText && context.mode == .photo
        if replacesPhotoText { action = .editText }
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
        if replacesPhotoText, let replacement = intent.replacement {
            // text = the words that are there, replacement = the new ones: the edit writes the new ones.
            intent.text = replacement
            intent.replacement = nil
        }
        // Strict: a primitive field that is there but unreadable drops the step rather than guessing.
        guard applyPrimitiveFields(step, to: &intent) else { return nil }
        if tableActions.contains(action) { applyTableFields(step, to: &intent) }

        // Sanity rules: actions that need a payload.
        switch action {
        case .removeObject where intent.target == nil: return nil
        case .adjust where intent.parameter == nil: return nil
        case .applyLook where intent.look == nil: intent.confidence = 0.5
        case .addText where intent.text == nil: intent.confidence = 0.5
        case .fillCells where intent.table?.value == nil && intent.table?.style == nil: intent.confidence = 0.5
        // Nothing named to erase: kept, so the executor asks for a box or a tap (needs_selection).
        case .eraseRegion where intent.region == nil && intent.ref == nil: intent.confidence = 0.5
        case .editText, .removeText, .moveText:
            // They act on text: an object or an area is not a text block.
            if let ref = intent.ref, !ref.isText { return nil }
            if action == .moveText, intent.target?.point == nil, intent.region == nil, intent.placement == nil, intent.degrees == nil { intent.confidence = 0.5 }
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
            "fill": .fillCells, "fillcells": .fillCells, "filltable": .fillCells, "fillgrid": .fillCells, "setcell": .fillCells, "setcells": .fillCells,
            "populate": .fillCells, "fillcell": .fillCells, "writecells": .fillCells,
            "clearcells": .clearCells, "clearcolumn": .clearCells, "clearrow": .clearCells, "emptycells": .clearCells, "clearcell": .clearCells,
            "highlightcolumn": .highlightCells, "highlightrow": .highlightCells, "shadecolumn": .highlightCells, "shaderow": .highlightCells,
            "highlightcell": .highlightCells, "highlightcells": .highlightCells,
            "eraseregion": .eraseRegion, "erasearea": .eraseRegion, "erasebox": .eraseRegion, "clearregion": .eraseRegion, "cleararea": .eraseRegion,
            "removeregion": .eraseRegion, "removearea": .eraseRegion,
            "movetext": .moveText, "movetitle": .moveText, "movelabel": .moveText, "movecaption": .moveText,
            "write": .addText, "writetext": .addText, "placetext": .addText, "inserttext": .addText,
            "changetext": .editText, "rewrite": .editText, "retype": .editText, "replacetextblock": .editText, "restyletext": .editText,
            "erasetext": .removeText, "deletetext": .removeText,
        ]
        return aliases[lowered]
    }
}

// MARK: - Table and primitive fields

extension IntentNormalizer {
    /// The actions whose steps carry cells / row / column / values.
    public static let tableActions: Set<IntentAction> = [.fillCells, .clearCells, .highlightCells]

    /// cells, row, column, values, min, max, decimals, text and color into `EditIntent.table`.
    static func applyTableFields(_ step: RawIntentStep, to intent: inout EditIntent) {
        var spec = TableEditSpec()
        spec.rows = tableRefs(step.row)
        spec.columns = tableRefs(step.column)
        switch step.cells?.normalizedForMatching {
        case "all", "every", "toutes", "tout": spec.onlyEmpty = false
        default: spec.onlyEmpty = true
        }
        let text = step.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step.values?.normalizedForMatching {
        case "random", "aleatoire", "hasard":
            spec.value = .random(min: step.min, max: step.max, decimals: step.decimals.map { Swift.max(0, Swift.min($0, 3)) })
        case "sequence", "numbers", "numero", "count":
            spec.value = .sequence(start: step.min ?? 1, step: 1)
        case "plausible", "realistic", "credible":
            spec.value = .plausible
        case "list":
            let items = (text ?? "").split(whereSeparator: { $0 == "|" || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !items.isEmpty { spec.value = .list(items) }
        default:
            if let text, !text.isEmpty { spec.value = .constant(String(text.prefix(24))) }
        }
        if let color = intent.color { spec.style = CellStyleOverride(color: color) }
        if let weight = step.weight.flatMap(fontWeight(named:)) {
            spec.style = CellStyleOverride(color: spec.style?.color, weight: weight, scale: spec.style?.scale)
        }
        if case .scale(let factor)? = step.size.flatMap(textSize(named:)) {
            spec.style = CellStyleOverride(color: spec.style?.color, weight: spec.style?.weight, scale: factor.clamped(to: 0.5...2))
        }
        intent.table = spec
    }

    /// "3" -> .index(3); "-1", "last", "dernière" -> .index(-1); else the name. Several joined with "|".
    static func tableRefs(_ field: String?) -> [TableEditSpec.Ref] {
        guard let field else { return [] }
        return field.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { part in
            let key = part.normalizedForMatching
            if let number = Int(key), number >= 1 || number == -1 { return .index(number) }
            if ["last", "derniere", "dernier", "la derniere", "le dernier", "the last one"].contains(key) { return .index(-1) }
            return .name(part)
        }
    }

    /// ref, box, size, weight, align, font and match into `ref`, `region` and `textStyle`. False when a
    /// field is present but unreadable (an id that is not one, a box outside the picture): the step is
    /// dropped, never run on a guess.
    static func applyPrimitiveFields(_ step: RawIntentStep, to intent: inout EditIntent) -> Bool {
        if let raw = step.ref?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let ref = SceneRef(raw) else { return false }
            intent.ref = ref
        }
        if let box = step.box {
            guard let region = region(from: box) else { return false }
            intent.region = region
        }
        var style = TextStyleSpec()
        if let size = step.size, !size.trimmingCharacters(in: .whitespaces).isEmpty {
            if ["match", "same", "meme", "pareil", "nearby"].contains(size.normalizedForMatching) { style.match = .nearby }
            else {
                guard let parsed = textSize(named: size) else { return false }
                style.size = parsed
            }
        }
        if let weight = step.weight {
            guard let parsed = fontWeight(named: weight) else { return false }
            style.weight = parsed
        }
        if let align = step.align {
            guard let parsed = alignment(named: align) else { return false }
            style.alignment = parsed
        }
        if let font = step.font {
            guard let parsed = fontDesign(named: font) else { return false }
            style.design = parsed
        }
        if let match = step.match?.trimmingCharacters(in: .whitespacesAndNewlines), !match.isEmpty {
            if let ref = SceneRef(match) { style.match = .ref(ref) }
            else if ["nearby", "auto", "same", "yes", "true", "around", "local"].contains(match.normalizedForMatching) { style.match = .nearby }
            else { return false }
        }
        if !style.isEmpty { intent.textStyle = style }
        return true
    }

    /// A model box (0...1, or 0...1000 when any side is above 1) as a normalised rect with a real area.
    static func region(from box: PSRect) -> PSRect? {
        let values = [box.minX, box.minY, box.width, box.height]
        guard values.allSatisfy({ $0.isFinite }), box.width > 0, box.height > 0 else { return nil }
        let scale = values.contains(where: { $0 > 1.0001 }) ? 1000.0 : 1.0
        let rect = PSRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale).clampedToUnit()
        guard rect.width >= 0.002, rect.height >= 0.002 else { return nil }
        return rect
    }

    static func textSize(named name: String) -> TextStyleSpec.Size? {
        let key = name.normalizedForMatching
        switch key {
        case "tiny", "minuscule": return .preset(.tiny)
        case "small", "petit", "petite": return .preset(.small)
        case "medium", "normal", "body", "moyen", "moyenne": return .preset(.body)
        case "large", "big", "grand", "grande", "gros", "grosse": return .preset(.large)
        case "title", "huge", "titre", "enorme": return .preset(.title)
        case "bigger", "larger", "plus gros", "plus grand", "plus grande": return .scale(1.35)
        case "smaller", "plus petit", "plus petite": return .scale(0.75)
        default: break
        }
        var number = key
        var isScale = false
        if number.hasPrefix("x") || number.hasPrefix("×") { number.removeFirst(); isScale = true }
        if number.hasSuffix("x") { number.removeLast(); isScale = true }
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return nil }
        if isScale { return .scale(value.clamped(to: TextStyleSpec.scaleRange)) }
        let fraction = value > 1 ? value / 1000 : value
        return .relative(fraction.clamped(to: TextStyleSpec.relativeSizeRange))
    }

    static func fontWeight(named name: String) -> TableGrid.FontWeight? {
        switch name.normalizedForMatching {
        case "regular", "normal", "light", "thin", "book", "plain", "400": return .regular
        case "medium", "500": return .medium
        case "semibold", "semi bold", "demibold", "600": return .semibold
        case "bold", "heavy", "black", "gras", "700", "800", "900": return .bold
        default: return nil
        }
    }

    static func alignment(named name: String) -> TextElement.Alignment? {
        switch name.normalizedForMatching {
        case "left", "leading", "gauche", "start": return .leading
        case "center", "centre", "middle", "centered", "milieu": return .center
        case "right", "trailing", "droite", "end": return .trailing
        default: return nil
        }
    }

    static func fontDesign(named name: String) -> TableGrid.FontDesign? {
        switch name.normalizedForMatching {
        case "sans", "sans serif", "default", "system", "sf", "sf pro": return .sans
        case "serif", "new york", "times": return .serif
        case "mono", "monospace", "monospaced", "code": return .mono
        case "rounded", "round", "arrondi": return .rounded
        default: return nil
        }
    }
}

extension RawIntentStep {
    /// The inverse of `IntentNormalizer.normalize`, in the model's own vocabulary: what the action memory
    /// ("last: fillCells text=1 cells=empty") and the ideas show the model.
    public init(intent: EditIntent) {
        self.init(action: intent.action.rawValue)
        if let target = intent.target {
            if !(target.label == "object" && target.point != nil) { self.target = target.label }
            spatialHint = target.spatialHint?.rawValue
            ordinal = target.ordinal
            all = target.matchesAll ? true : nil
            point = target.point
            attributes = target.attributes.isEmpty ? nil : target.attributes
        }
        parameter = intent.parameter?.rawValue
        if let amount = intent.amount {
            amountMode = amount.mode.rawValue
            if let unit = AmountUnit.for(intent.action) {
                switch unit {
                case .percent: self.amount = amount.mode == .multiplier ? amount.value : amount.value * 100
                case .fraction, .seconds, .multiplier: self.amount = amount.value
                }
            } else {
                self.amount = amount.value
            }
        }
        look = intent.look?.rawValue
        aspect = intent.aspect?.rawValue
        degrees = intent.degrees
        flipAxis = intent.flipAxis?.rawValue
        text = intent.text
        placement = intent.placement?.rawValue
        color = intent.color?.hexString
        switch intent.background {
        case .transparent?: background = "transparent"
        case .blur?: background = "blur"
        case .white?: background = "white"
        case .black?: background = "black"
        case .color(let color)?: background = color.hexString
        case .gradient(let color, _)?: background = color.hexString
        case nil: break
        }
        startSeconds = intent.timeRange?.start
        endSeconds = intent.timeRange?.end
        seconds = intent.time
        clipNumber = intent.clipIndex
        transition = intent.transition?.rawValue
        choiceIndex = intent.index
        scope = intent.scope == .current ? nil : intent.scope.rawValue
        replacement = intent.replacement
        if let table = intent.table {
            cells = table.onlyEmpty ? "empty" : "all"
            row = Self.joined(table.rows)
            column = Self.joined(table.columns)
            switch table.value {
            case .constant(let value)?: text = value
            case .random(let low, let high, let places)?: values = "random"; min = low; max = high; decimals = places
            case .sequence(let start, _)?: values = "sequence"; min = start
            case .list(let items)?: values = "list"; text = items.joined(separator: "|")
            case .plausible?: values = "plausible"
            case nil: break
            }
            if let tint = table.style?.color { color = tint.hexString }
            weight = table.style?.weight?.rawValue
            if let scale = table.style?.scale { size = "x" + Self.number(scale) }
        }
        ref = intent.ref?.id
        box = intent.region
        if let style = intent.textStyle {
            switch style.size {
            case .relative(let value)?: size = String(Int((value * 1000).rounded()))
            case .scale(let factor)?: size = "x" + Self.number(factor)
            case .preset(let sizeClass)?: size = sizeClass == .body ? "medium" : sizeClass.rawValue
            case nil: break
            }
            weight = style.weight?.rawValue ?? weight
            align = style.alignment.map { $0 == .leading ? "left" : $0 == .trailing ? "right" : "center" }
            font = style.design?.rawValue
            switch style.match {
            case .nearby?: match = "nearby"
            case .ref(let ref)?: match = ref.id
            case nil: break
            }
        }
    }

    /// "1.35", "2": no trailing zeros, no locale.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func joined(_ refs: [TableEditSpec.Ref]) -> String? {
        guard !refs.isEmpty else { return nil }
        return refs.map { ref -> String in
            switch ref {
            case .index(let index): return String(index)
            case .name(let name): return name
            }
        }.joined(separator: "|")
    }
}
