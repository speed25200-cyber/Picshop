import Foundation
import PicshopCore

/// Puts a validated plan in a sensible order before it runs (deterministic, pure Swift):
/// - the user's order is kept when they said it ("puis", "ensuite", "then", "after");
///   otherwise the steps sort stably by catalog phase (refs, geometry, cleanup, tone, colour,
///   effects, composition, text, output);
/// - steps that use a scene ref, a point or a box run before a geometry change, which would move
///   what they name; when the user's order puts them after one, a note says so (the executor
///   re-reads the scene and carries the ids over);
/// - two steps on the same setting merge (relative amounts add, an absolute one wins; two calls of
///   one operation on the same band, range, channel or layer keep the later arguments);
/// - of two steps that undo each other's background (cut out, then blur), the later one stays.
public enum PlanLinter {
    /// Words that mean the user gave an order.
    static let sequencingWords: [String] = [
        "puis", "ensuite", "apres", "d abord", "en premier", "enfin", "pour finir", "et apres", "avant de",
        "then", "after", "afterwards", "first", "finally", "before", "and then", "next",
    ]

    public static func lint(_ steps: [EditIntent], utterance: String, catalog: OperationCatalog = .shared) -> (steps: [EditIntent], notes: [String]) {
        guard steps.count > 1 else { return (steps, []) }
        var notes: [String] = []
        var result = merged(steps, notes: &notes)
        result = backgrounds(result, notes: &notes)
        let geometry = result.contains { changesGeometry($0, catalog: catalog) }
        if saysOrder(utterance) {
            if geometry, let first = result.firstIndex(where: { changesGeometry($0, catalog: catalog) }),
               result.indices.contains(where: { $0 > first && usesPlace(result[$0]) }) {
                notes.append("kept the user's order: a step after the geometry change names a place read before it")
            }
            return (result, notes)
        }
        let ranked = result.enumerated().map { offset, intent -> (offset: Int, phase: OpPhase, intent: EditIntent) in
            let phase: OpPhase = geometry && usesPlace(intent) && !changesGeometry(intent, catalog: catalog) ? .refDependent : phase(of: intent, catalog: catalog)
            return (offset, phase, intent)
        }
        let sorted = ranked.sorted { $0.phase != $1.phase ? $0.phase < $1.phase : $0.offset < $1.offset }
        if sorted.map(\.offset) != Array(result.indices) { notes.append("sorted by phase") }
        return (sorted.map(\.intent), notes)
    }

    // MARK: Order

    static func saysOrder(_ utterance: String) -> Bool {
        let folded = " " + utterance.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        return sequencingWords.contains { folded.contains(" \($0) ") }
    }

    static func spec(of intent: EditIntent, catalog: OperationCatalog) -> OperationSpec? {
        if intent.action == .operation, let call = intent.operation { return catalog.spec(call.id) }
        return catalog.spec(lowering: intent.action)
    }

    /// The step's catalog phase; steps the catalog does not describe keep the middle (effects).
    static func phase(of intent: EditIntent, catalog: OperationCatalog) -> OpPhase {
        spec(of: intent, catalog: catalog)?.phase ?? fallbackPhase(intent.action)
    }

    static func fallbackPhase(_ action: IntentAction) -> OpPhase {
        switch action {
        case .crop, .setAspect, .rotate, .straighten, .flip, .resetOrientation, .autoCrop, .expandCanvas, .upscale: return .geometry
        case .removeObject, .cleanUp, .eraseRegion, .blurObject, .moveObject: return .cleanup
        case .adjust, .selectiveAdjust, .autoEnhance, .relight, .denoise, .sharpen: return .tone
        case .applyLook, .recolor, .matchColor: return .color
        case .addText, .editText, .removeText, .moveText, .textBehind, .fillCells, .clearCells, .highlightCells: return .text
        case .export, .share: return .output
        default: return .effects
        }
    }

    static func changesGeometry(_ intent: EditIntent, catalog: OperationCatalog) -> Bool {
        if let spec = spec(of: intent, catalog: catalog), spec.requires.geometryChange { return true }
        switch intent.action {
        case .crop, .setAspect, .rotate, .straighten, .flip, .resetOrientation, .autoCrop, .expandCanvas: return true
        default: return false
        }
    }

    /// Whether the step names a place on the current picture: a scene ref, a point, a box.
    static func usesPlace(_ intent: EditIntent) -> Bool {
        if intent.ref != nil || intent.region != nil || intent.target?.point != nil { return true }
        guard let call = intent.operation else { return false }
        return call.args.values.contains { value in
            switch value {
            case .point, .box: return true
            case .string(let text): return HybridIntentRouter.isRefLike(text)
            default: return false
            }
        }
    }

    // MARK: Merging

    /// Two steps on one setting become one.
    static func merged(_ steps: [EditIntent], notes: inout [String]) -> [EditIntent] {
        var result: [EditIntent] = []
        for step in steps {
            if let index = result.lastIndex(where: { sameSetting($0, step) }) {
                result[index] = combine(result[index], step)
                notes.append("merged two \(step.operation?.id.raw ?? step.action.rawValue) steps")
            } else {
                result.append(step)
            }
        }
        return result
    }

    static func sameSetting(_ a: EditIntent, _ b: EditIntent) -> Bool {
        if a.action == .adjust, b.action == .adjust, let p = a.parameter, p == b.parameter, a.amount != nil, b.amount != nil { return true }
        guard a.action == .operation, b.action == .operation, let x = a.operation, let y = b.operation, x.id == y.id else { return false }
        // Same band, range, channel and layer (absent counts as the same).
        for key in ["band", "range", "channel", "ref"] where x.args[key] != y.args[key] { return false }
        // A curve's shape and a layer's order are not settings that add up.
        return !["curves", "layerOrder"].contains(x.id.raw)
    }

    static func combine(_ a: EditIntent, _ b: EditIntent) -> EditIntent {
        var result = b
        if a.action == .adjust, let first = a.amount, let second = b.amount {
            // Relative amounts add; an absolute one wins (the later one when both are).
            if second.mode == .absolute {
                result.amount = second
            } else if first.mode == .absolute {
                result.amount = .absolute(first.value + second.value)
            } else {
                result.amount = .relative(first.value + second.value)
            }
            return result
        }
        if var call = a.operation, let later = b.operation {
            for (key, value) in later.args { call.args[key] = value }
            call.source = later.source
            result.operation = call
        }
        return result
    }

    /// Cut out, then blur the background (or the other way round): the later one is what was meant.
    static func backgrounds(_ steps: [EditIntent], notes: inout [String]) -> [EditIntent] {
        let exclusive: Set<IntentAction> = [.removeBackground, .blurBackground, .replaceBackground]
        let indices = steps.indices.filter { exclusive.contains(steps[$0].action) }
        guard indices.count > 1, let last = indices.last else { return steps }
        let dropped = Set(indices.dropLast())
        notes.append("kept \(steps[last].action.rawValue), the later of \(indices.count) background steps")
        return steps.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}
