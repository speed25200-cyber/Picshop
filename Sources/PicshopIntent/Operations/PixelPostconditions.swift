import Foundation
import PicshopCore

/// Pixel postconditions (W2, D14, §8.7): after a mask or selection step, two 256 px proxies (before, after) and
/// the region's mask are measured in CIE Lab (`PixelStats`), and the step is checked on what it should have done
/// to the pixels, not only to the document. Pure: the plan comes from the call and the two documents, the
/// verdict from the measured regions. The executor runs the probes (`PhotoAIServices.pixelProbes`) inside its 2 s
/// deadline; a timeout or an unmeasured region is unverifiable, never failed.
///
/// The probes are chosen from the parameters the call actually sent, never from the spec alone. A step that
/// appended an expensive kind (erase, cut out, generate) is not rendered here: unverifiable. Thresholds are
/// conservative (Lab units on 256 px proxies; "inside" is mask-weighted, "outside" is where m < 0.05).
public enum PixelPostconditions {
    // MARK: Thresholds

    public static let lightness = 0.8, lightnessContrast = 0.5, contrast = 0.4, chroma = 0.8, warmth = 0.5, tint = 0.5
    public static let leakFloor = 0.6, leakShare = 0.25
    public static let minimumAmount = 5.0
    public static let coverageRange = 0.002...0.98
    public static let coverageStep = 0.002
    public static let invertedTolerance = 0.02
    public static let fillDistance = 5.0, recolorDistance = 3.0, blurDrop = -0.3
    public static let colorAlreadyThere = 8.0, uniformForBlur = 2.0
    /// The share of the mask's box that must lie in the target box grown by 10 %.
    public static let boxShare = 0.5

    /// What a parameter's change is measured on.
    enum Metric: Equatable {
        case lightness, contrast, chroma, warmth, tint

        static func of(_ parameter: AdjustmentParameter) -> Metric? {
            switch parameter {
            case .exposure, .brightness, .shadows, .highlights, .whites, .blacks: return .lightness
            case .contrast, .clarity: return .contrast
            case .saturation, .vibrance: return .chroma
            case .temperature: return .warmth
            case .tint: return .tint
            case .hue, .sharpness, .noiseReduction, .grain, .fade, .skinTone, .vignette: return nil
            }
        }
    }

    // MARK: Plan

    /// Which document the "before" render is.
    public enum Baseline: Hashable, Sendable {
        case before
        /// `after` without that local adjustment: what « caché » must look like.
        case withoutAdjustment(UUID)
    }

    /// One probe and how its numbers are read.
    public struct Check: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// The parameter moved the inside of its mask that way (+1, −1); `amount` in percent of the dial's range.
            case parameter(AdjustmentParameter, direction: Int, amount: Double)
            /// The adjustment shows (ΔE > 1 against the render without it) or is hidden (ΔE ≤ 0.5).
            case visible(Bool)
            /// 0.2 %–98 % of the picture; with a target box, ≥ 50 % of the mask's box lies in it (grown by 10 %).
            case coverageInRange(mask: PSRect?, target: PSRect?)
            /// The mean m moved that way by ≥ 0.002; `quiet`: no move is unverifiable rather than failed (the edit may
            /// not change the coverage by construction), with `note` said when it passes unchanged.
            case coverage(Expectation, quiet: Bool, note: String?)
            case inverted
            case softness
            case peak
            /// selectionApply's `use` (fill, recolour, blur), with the colour asked for.
            case use(String, color: PSColor?)
        }

        public var request: PixelProbeRequest
        public var kind: Kind
        public var baseline: Baseline

        public init(_ request: PixelProbeRequest, _ kind: Kind, baseline: Baseline = .before) {
            self.request = request
            self.kind = kind
            self.baseline = baseline
        }
    }

    public struct Plan: Hashable, Sendable {
        public var checks: [Check]
        /// Why some of what the call did cannot be checked on pixels.
        public var unverifiable: [String]

        public init(checks: [Check] = [], unverifiable: [String] = []) {
            self.checks = checks
            self.unverifiable = unverifiable
        }

        public var isEmpty: Bool { checks.isEmpty && unverifiable.isEmpty }
        /// The requests of the checks against `before`, in order.
        public var requests: [PixelProbeRequest] { checks.filter { $0.baseline == .before }.map(\.request) }
        /// The baselines other than `before`.
        public var otherBaselines: [Baseline] {
            var seen: [Baseline] = []
            for check in checks where check.baseline != .before && !seen.contains(check.baseline) { seen.append(check.baseline) }
            return seen
        }
    }

    /// The probe requests a call needs (§8.7), from the parameters it sent and the two documents.
    public static func requests(for call: OperationCall, spec: OperationSpec, before: PhotoDocument, after: PhotoDocument) -> [PixelProbeRequest] {
        guard spec.verify.contains(where: { if case .pixels = $0 { return true } else { return false } }) else { return [] }
        return plan(for: call, before: before, after: after).checks.map(\.request)
    }

    /// The checks of a catalog call on a photo.
    public static func plan(for call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        if let reason = expensiveStep(before: before, after: after) { return Plan(unverifiable: [reason]) }
        switch call.id.raw {
        case "maskAdjust": return maskAdjustPlan(call, before: before, after: after)
        case "maskEdit": return maskEditPlan(call, before: before, after: after)
        case "select": return selectPlan(call, before: before, after: after)
        case "selectionModify": return selectionModifyPlan(call, before: before, after: after)
        case "selectionApply": return selectionApplyPlan(call, before: before, after: after)
        default: return Plan()
        }
    }

    /// selectiveAdjust lowered onto a local adjustment: its parameter inside that mask.
    public static func plan(forSelective intent: EditIntent, before: PhotoDocument, after: PhotoDocument) -> Plan {
        guard let parameter = intent.parameter, let changed = changedAdjustment(before: before, after: after) else { return Plan() }
        return Plan(checks: [], unverifiable: []).adding(parameterCheck(parameter, adjustment: changed.after, previous: changed.before))
    }

    /// "expensive step not rendered yet" when the call appended an erase, a cut-out, a generation…
    static func expensiveStep(before: PhotoDocument, after: PhotoDocument) -> String? {
        let old = Set(before.layers.flatMap { $0.edits.operations.map(\.id) })
        let added = after.layers.flatMap(\.edits.operations).filter { !old.contains($0.id) }
        return added.contains { $0.kind.isExpensive } ? "expensive step not rendered yet" : nil
    }

    /// The local adjustment a step created or changed (the only one), before (nil when new) and after.
    static func changedAdjustment(before: PhotoDocument, after: PhotoDocument) -> (before: LocalAdjustment?, after: LocalAdjustment)? {
        let old = Dictionary(before.localAdjustments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changed = after.localAdjustments.filter { old[$0.id] != $0 }
        guard changed.count == 1, let adjustment = changed.first else { return nil }
        return (old[adjustment.id], adjustment)
    }

    /// The parameter check of an adjustment whose dial moved, or why it cannot be one. `requested` is the relative
    /// amount the call asked for (±100): its direction is what the pixels must show, so a dial moved the wrong way,
    /// or not at all, fails instead of passing on its own movement.
    static func parameterCheck(_ parameter: AdjustmentParameter, adjustment: LocalAdjustment, previous: LocalAdjustment?,
                               requested: Double? = nil) -> Either {
        let request = PixelProbeRequest(.maskedParameter, region: .localAdjustment(adjustment.id))
        guard Metric.of(parameter) != nil else { return .unverifiable("\(parameter.rawValue) is not measured on pixels") }
        guard adjustment.isVisible else { return .unverifiable("the adjustment is hidden") }
        let old = previous?.adjustments[parameter] ?? 0
        let delta = adjustment.adjustments[parameter] - old
        let amount = abs(delta) / max(1e-9, parameter.range.upperBound) * 100 * (previous == nil ? adjustment.amount : 1)
        if let requested, abs(requested) >= minimumAmount {
            return .check(Check(request, .parameter(parameter, direction: requested > 0 ? 1 : -1, amount: max(amount, abs(requested) * adjustment.amount))))
        }
        guard amount >= minimumAmount else { return .unverifiable("amount under \(Int(minimumAmount))") }
        return .check(Check(request, .parameter(parameter, direction: delta > 0 ? 1 : -1, amount: amount)))
    }

    enum Either {
        case check(Check)
        case unverifiable(String)
    }

    // MARK: Per operation

    static func maskAdjustPlan(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        guard let changed = changedAdjustment(before: before, after: after) else { return Plan() }
        var plan = Plan()
        let region = PixelProbeRequest.Region.localAdjustment(changed.after.id)
        if changed.before == nil {
            let target = (call.args["box"]).flatMap(MaskAreaArgs.normalizedBox)
            let maskBox = changed.after.stack.rasterRefs.first.map { raster in raster.boundingBox }
            plan.checks.append(Check(PixelProbeRequest(.maskCoverageInRange, region: region), .coverageInRange(mask: target == nil ? nil : maskBox, target: target)))
        }
        if let name = call.args["parameter"]?.string, let parameter = AdjustmentParameter(rawValue: name) {
            // A relative amount says which way the pixels must go (the default mode); an absolute one is checked
            // by the dial's own movement.
            let relative = (call.args["amountMode"]?.string ?? "relative") == "relative"
            let requested = relative ? call.args["amount"]?.double : nil
            plan = plan.adding(parameterCheck(parameter, adjustment: changed.after, previous: changed.before, requested: requested))
        }
        if call.args["curve"] != nil { plan.unverifiable.append("a curve is not measured on pixels") }
        if call.args["band"] != nil { plan.unverifiable.append("the HSL subset is not measured on pixels") }
        if call.args["localColor"] != nil { plan.unverifiable.append("a local colour is not measured on pixels") }
        return plan
    }

    static func maskEditPlan(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        let args = call.args
        var plan = Plan()
        guard let changed = changedAdjustment(before: before, after: after), let previous = changed.before else {
            if args["duplicate"] != nil || args["name"] != nil || args["refresh"] != nil || args["show"] != nil { return plan }
            return plan
        }
        let adjustment = changed.after
        let region = PixelProbeRequest.Region.localAdjustment(adjustment.id)
        func coverage(_ expectation: Expectation, quiet: Bool = false, note: String? = nil) {
            plan.checks.append(Check(PixelProbeRequest(.maskCoverage, region: region), .coverage(expectation, quiet: quiet, note: note)))
        }
        if let mode = args["combine"]?.string {
            switch mode {
            case "add": coverage(.increased, quiet: true)
            case "subtract", "intersect": coverage(.decreased, quiet: true)
            default: break
            }
        }
        if let expand = args["expand"]?.double, expand != 0 { coverage(expand > 0 ? .increased : .decreased) }
        if args["invert"] != nil, adjustment.stack.isInverted != previous.stack.isInverted {
            plan.checks.append(Check(PixelProbeRequest(.maskInverted, region: region), .inverted))
        }
        if adjustment.stack.feather > previous.stack.feather {
            plan.checks.append(Check(PixelProbeRequest(.maskSoftness, region: region), .softness))
        }
        if adjustment.stack.density < previous.stack.density {
            plan.checks.append(Check(PixelProbeRequest(.maskPeak, region: region), .peak))
        }
        if args["amount"] != nil, adjustment.amount != previous.amount {
            // The effect inside moves with the strength, the way its main dial goes.
            if let dial = MaskAccessibility.dialOrder.first(where: { Metric.of($0) != nil && abs(adjustment.adjustments[$0]) > 0.0005 }) {
                let value = adjustment.adjustments[dial]
                let deltaAmount = adjustment.amount - previous.amount
                let amount = abs(deltaAmount * value) / max(1e-9, dial.range.upperBound) * 100
                if amount >= minimumAmount, adjustment.isVisible {
                    let direction = (deltaAmount > 0) == (value > 0) ? 1 : -1
                    plan.checks.append(Check(PixelProbeRequest(.maskedParameter, region: region), .parameter(dial, direction: direction, amount: amount)))
                } else {
                    plan.unverifiable.append(adjustment.isVisible ? "amount under \(Int(minimumAmount))" : "the adjustment is hidden")
                }
            } else {
                plan.unverifiable.append("no measured dial on this mask")
            }
        }
        if let visible = args["visible"]?.bool, visible != previous.isVisible {
            plan.checks.append(Check(PixelProbeRequest(.maskedParameter, region: region), .visible(visible), baseline: .withoutAdjustment(adjustment.id)))
        }
        let shapeKeys = ["start", "end", "center", "radius", "rotation", "roundness"]
        let partKeys = ["component", "componentMode", "componentInvert", "componentDelete", "low", "high", "smoothness", "fuzziness"]
        if args["combine"] == nil, (shapeKeys + partKeys).contains(where: { args[$0] != nil }), adjustment.stack != previous.stack {
            coverage(.changed, quiet: true)
        }
        return plan
    }

    static func selectPlan(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        guard let selection = after.selection, selection != before.selection else { return Plan() }
        let request = { (probe: PixelProbe) in PixelProbeRequest(probe, region: .selection) }
        let mode = call.args["mode"]?.string ?? "new"
        if before.selection == nil || mode == "new" {
            if call.args["what"]?.string == "all" { return Plan(unverifiable: ["the whole picture"]) }
            let target = call.args["box"].flatMap(MaskAreaArgs.normalizedBox)
            return Plan(checks: [Check(request(.selectionCoverageInRange), .coverageInRange(mask: target == nil ? nil : selection.mask.boundingBox, target: target))])
        }
        switch mode {
        case "add": return Plan(checks: [Check(request(.selectionCoverage), .coverage(.increased, quiet: true, note: Note.alreadySelected))])
        case "subtract": return Plan(checks: [Check(request(.selectionCoverage), .coverage(.decreased, quiet: true, note: Note.nothingToRemove))])
        default: return Plan(checks: [Check(request(.selectionCoverage), .coverage(.decreased, quiet: true, note: nil))])
        }
    }

    static func selectionModifyPlan(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        guard after.selection != nil, after.selection != before.selection else { return Plan() }
        var plan = Plan()
        let request = PixelProbeRequest(.selectionCoverage, region: .selection)
        if call.args["grow"] != nil { plan.checks.append(Check(request, .coverage(.increased, quiet: false, note: nil))) }
        if call.args["shrink"] != nil { plan.checks.append(Check(request, .coverage(.decreased, quiet: false, note: nil))) }
        return plan
    }

    static func selectionApplyPlan(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Plan {
        guard let use = call.args["use"]?.string else { return Plan() }
        switch use {
        case "erase", "cutout": return Plan(unverifiable: ["expensive step not rendered yet"])
        case "generate": return Plan(unverifiable: ["generative"])
        case "adjust", "mask":
            guard let changed = changedAdjustment(before: before, after: after) else { return Plan() }
            var plan = Plan(checks: [Check(PixelProbeRequest(.maskCoverageInRange, region: .localAdjustment(changed.after.id)), .coverageInRange(mask: nil, target: nil))])
            if use == "adjust", let parameter = changed.after.adjustments.activeParameters.first {
                plan = plan.adding(parameterCheck(parameter, adjustment: changed.after, previous: nil))
            }
            return plan
        case "fill", "recolor":
            let color = call.args["color"]?.string.flatMap { PSColor.named($0) ?? PSColor(hex: $0) }
            if use == "fill", after.layers.count <= before.layers.count {
                return Plan(checks: [], unverifiable: []).adding(.unverifiable("no fill layer"))
            }
            return Plan(checks: [Check(PixelProbeRequest(.selectionUse, region: .selection), .use(use, color: color))])
        case "blur":
            return Plan(checks: [Check(PixelProbeRequest(.selectionUse, region: .selection), .use(use, color: nil))])
        default:
            return Plan()
        }
    }

    /// What a check that passes unchanged says (« déjà dans la sélection »), by key.
    public enum Note {
        public static let alreadySelected = "alreadySelected"
        public static let nothingToRemove = "nothingToRemove"

        public static func text(_ key: String, french: Bool) -> String {
            switch key {
            case alreadySelected: return french ? "C'était déjà dans la sélection." : "That was already in the selection."
            case nothingToRemove: return french ? "Il n'y avait rien à retirer de la sélection." : "There was nothing to remove from the selection."
            default: return key
            }
        }
    }

    // MARK: Verdict

    /// The checks' verdicts from the measured regions, in the structural report's form. `results` (nil: the
    /// probes timed out) are in the order of the plan's checks against `before`; `others` are the results of the
    /// checks against another baseline, by baseline.
    public static func evaluate(_ plan: Plan, results: [PixelProbeResult]?, others: [Baseline: [PixelProbeResult]] = [:]) -> Verdict {
        var verdict = Verdict()
        verdict.report.unverifiable += plan.unverifiable.count
        verdict.reasons += plan.unverifiable
        var cursor: [Baseline: Int] = [:]
        for check in plan.checks {
            let list = check.baseline == .before ? results : others[check.baseline]
            let index = cursor[check.baseline, default: 0]
            cursor[check.baseline] = index + 1
            guard let list, index < list.count, list[index].request == check.request else {
                verdict.unverified("not measured")
                continue
            }
            judge(check, list[index], into: &verdict)
        }
        return verdict
    }

    /// The pixel verdict: the report Live reads, why some checks could not be made, and what to say when a check
    /// passed with a note (« déjà dans la sélection »).
    public struct Verdict: Equatable, Sendable {
        public var report = OperationPostconditions.Report()
        public var reasons: [String] = []
        public var notes: [String] = []

        public init() {}

        mutating func pass() { report.passed += 1 }

        mutating func unverified(_ reason: String) {
            report.unverifiable += 1
            reasons.append(reason)
        }

        mutating func fail(_ probe: PixelProbe, expected: String, observed: String) {
            let failure = OperationPostconditions.Report.Failure(probe: probe.rawValue, expected: expected, observed: observed)
            report.failures.append(failure)
            report.failed.append(failure.line)
        }
    }

    static func judge(_ check: Check, _ result: PixelProbeResult, into verdict: inout Verdict) {
        let probe = check.request.probe
        switch check.kind {
        case .coverageInRange(let mask, let target):
            guard let after = result.after else { return verdict.unverified("not measured") }
            guard coverageRange.contains(after.coverage) else {
                return verdict.fail(probe, expected: "coverage 0.2–98 %", observed: percent(after.coverage))
            }
            if let mask, let target {
                let grown = target.insetBy(dx: -target.width * 0.05, dy: -target.height * 0.05)
                let share = mask.area > 0 ? mask.intersection(grown).area / mask.area : 0
                guard share >= boxShare else { return verdict.fail(probe, expected: "the mask in the target box", observed: "\(percent(share)) inside") }
            }
            verdict.pass()
        case .coverage(let expectation, let quiet, let note):
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            let delta = after.coverage - before.coverage
            let moved: Bool
            switch expectation {
            case .increased: moved = delta >= coverageStep
            case .decreased: moved = delta <= -coverageStep
            default: moved = abs(delta) >= coverageStep
            }
            if moved { return verdict.pass() }
            if abs(delta) < coverageStep, quiet {
                if let note {
                    verdict.notes.append(note)
                    return verdict.pass()
                }
                return verdict.unverified("coverage did not move")
            }
            if (expectation == .increased && before.coverage > coverageRange.upperBound) || (expectation == .decreased && before.coverage < coverageRange.lowerBound) {
                return verdict.unverified("the mask was already \(expectation == .increased ? "full" : "empty")")
            }
            verdict.fail(probe, expected: "coverage \(expectationText(expectation))", observed: "\(percent(before.coverage)) → \(percent(after.coverage))")
        case .inverted:
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            let gap = abs(after.coverage - (1 - before.coverage))
            if gap <= invertedTolerance { return verdict.pass() }
            verdict.fail(probe, expected: "coverage \(percent(1 - before.coverage))", observed: percent(after.coverage))
        case .softness:
            // The share of pixels at m < 0.05 shrinks when the edge spreads (PixelStats has the outside weights).
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            guard before.outside.weight > 0 else { return verdict.unverified("the mask covers the whole picture") }
            if after.outside.weight < before.outside.weight - 0.5 { return verdict.pass() }
            verdict.fail(probe, expected: "a softer edge", observed: "no softer edge")
        case .peak:
            // Density scales m: the mean falls with the maximum.
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            if after.coverage < before.coverage - 1e-4 { return verdict.pass() }
            verdict.fail(probe, expected: "a weaker mask", observed: "\(percent(before.coverage)) → \(percent(after.coverage))")
        case .visible(let shown):
            guard let without = result.before, let with = result.after else { return verdict.unverified("not measured") }
            let distance = deltaE(without.inside, with.inside)
            if shown {
                if distance > 1 { return verdict.pass() }
                if without.inside.weight == 0 { return verdict.unverified("an empty mask") }
                verdict.fail(probe, expected: "the adjustment shows", observed: "ΔE \(format(distance))")
            } else {
                if distance <= 0.5 { return verdict.pass() }
                verdict.fail(probe, expected: "the adjustment hidden", observed: "ΔE \(format(distance))")
            }
        case .parameter(let parameter, let direction, _):
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            guard before.inside.weight > 0, after.inside.weight > 0 else { return verdict.unverified("an empty mask") }
            judgeParameter(parameter, direction: direction, before: before, after: after, probe: probe, into: &verdict)
        case .use(let use, let color):
            guard let before = result.before, let after = result.after else { return verdict.unverified("not measured") }
            switch use {
            case "fill", "recolor":
                if let color {
                    let asked = MaskMath.lab(color)
                    let already = ((before.inside.meanL - asked.l) * (before.inside.meanL - asked.l) + (before.inside.meanA - asked.a) * (before.inside.meanA - asked.a)
                        + (before.inside.meanB - asked.b) * (before.inside.meanB - asked.b)).squareRoot()
                    if already < colorAlreadyThere { return verdict.unverified("the area already has that colour") }
                }
                let distance = deltaE(before.inside, after.inside)
                let needed = use == "fill" ? fillDistance : recolorDistance
                if distance >= needed { return verdict.pass() }
                verdict.fail(probe, expected: "ΔE inside ≥ \(format(needed))", observed: "ΔE \(format(distance))")
            case "blur":
                if before.inside.stdL < uniformForBlur { return verdict.unverified("a uniform area cannot get smoother") }
                let drop = after.inside.stdL - before.inside.stdL
                if drop <= blurDrop { return verdict.pass() }
                verdict.fail(probe, expected: "Δstd L* inside ≤ \(format(blurDrop))", observed: format(drop))
            default:
                verdict.unverified("not measured")
            }
        }
    }

    static func judgeParameter(_ parameter: AdjustmentParameter, direction: Int, before: PixelStats.Regions, after: PixelStats.Regions,
                               probe: PixelProbe, into verdict: inout Verdict) {
        let sign = Double(direction)
        let inL = after.inside.meanL - before.inside.meanL
        let hasOutside = before.outside.weight > 0 && after.outside.weight > 0
        let outL = hasOutside ? after.outside.meanL - before.outside.meanL : 0
        // The leak check holds for every measured parameter.
        if hasOutside, abs(outL) > max(leakFloor, leakShare * abs(inL)) {
            return verdict.fail(probe, expected: "no change outside the mask", observed: "leaks outside the mask (ΔL* out \(format(outL)))")
        }
        guard let metric = Metric.of(parameter) else { return verdict.unverified("\(parameter.rawValue) is not measured on pixels") }
        switch metric {
        case .lightness:
            guard sign * inL >= lightness else {
                return verdict.fail(probe, expected: "ΔL* inside \(direction > 0 ? "≥ +" : "≤ −")\(format(lightness))", observed: format(inL))
            }
            guard !hasOutside || sign * (inL - outL) >= lightnessContrast else {
                return verdict.fail(probe, expected: "inside moves more than outside", observed: "ΔL* in \(format(inL)), out \(format(outL))")
            }
        case .contrast:
            let delta = after.inside.stdL - before.inside.stdL
            guard sign * delta >= contrast else {
                return verdict.fail(probe, expected: "Δstd L* inside \(direction > 0 ? "≥ +" : "≤ −")\(format(contrast))", observed: format(delta))
            }
        case .chroma:
            let delta = after.inside.meanChroma - before.inside.meanChroma
            guard sign * delta >= chroma else {
                return verdict.fail(probe, expected: "ΔC* inside \(direction > 0 ? "≥ +" : "≤ −")\(format(chroma))", observed: format(delta))
            }
        case .warmth:
            let delta = after.inside.meanB - before.inside.meanB
            guard sign * delta >= warmth else {
                return verdict.fail(probe, expected: "Δb* inside \(direction > 0 ? "≥ +" : "≤ −")\(format(warmth))", observed: format(delta))
            }
        case .tint:
            let delta = after.inside.meanA - before.inside.meanA
            guard sign * delta >= tint else {
                return verdict.fail(probe, expected: "Δa* inside \(direction > 0 ? "≥ +" : "≤ −")\(format(tint))", observed: format(delta))
            }
        }
        verdict.pass()
    }

    static func deltaE(_ a: PixelStats, _ b: PixelStats) -> Double {
        let dl = a.meanL - b.meanL, da = a.meanA - b.meanA, db = a.meanB - b.meanB
        return (dl * dl + da * da + db * db).squareRoot()
    }

    static func percent(_ value: Double) -> String {
        let percent = value * 100
        return percent < 10 ? String(format: "%.1f %%", percent) : "\(Int(percent.rounded())) %"
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    static func expectationText(_ expectation: Expectation) -> String {
        switch expectation {
        case .increased: return "up"
        case .decreased: return "down"
        default: return "changed"
        }
    }
}

extension PixelPostconditions.Plan {
    func adding(_ either: PixelPostconditions.Either) -> PixelPostconditions.Plan {
        var plan = self
        switch either {
        case .check(let check): plan.checks.append(check)
        case .unverifiable(let reason): plan.unverifiable.append(reason)
        }
        return plan
    }
}

extension OperationPostconditions.Report {
    /// The structural report with the pixel verdict added; the pixel conditions the structural pass counted as
    /// unverifiable (`pixelConditions`) are replaced by the verdict.
    public func merged(with pixels: OperationPostconditions.Report, replacing pixelConditions: Int) -> OperationPostconditions.Report {
        var report = self
        report.unverifiable = max(0, report.unverifiable - pixelConditions) + pixels.unverifiable
        report.passed += pixels.passed
        report.failed += pixels.failed
        report.failures += pixels.failures
        return report
    }
}
