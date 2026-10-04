import Foundation
import PicshopCore

/// Structural postconditions: what the catalog says must be true after a step, read from the
/// document before and after it (state diffs, microseconds, Linux-testable). Pixel probes come in
/// W2; until then they, and every `.unverifiable` entry, count as unverifiable.
///
/// Live reads the report as the step's check ('verified n/m' / 'verify failed n/m: …'), so a step
/// that applied but did not do what it said gets the single repair round.
public enum OperationPostconditions {
    public struct Report: Sendable, Equatable {
        /// One failed check: the probe, what the step asked for, what the document shows.
        public struct Failure: Sendable, Equatable {
            public var probe: String
            public var expected: String
            public var observed: String

            public init(probe: String, expected: String, observed: String) {
                self.probe = probe
                self.expected = expected
                self.observed = observed
            }

            /// "layerOpacity is 80, expected 50".
            public var line: String { "\(probe) is \(observed), expected \(expected)" }
        }

        public var passed: Int
        public var failed: [String]
        public var unverifiable: Int
        /// The failures, structured (additive to the W1 contract).
        public var failures: [Failure]

        public init(passed: Int = 0, failed: [String] = [], unverifiable: Int = 0, failures: [Failure] = []) {
            self.passed = passed
            self.failed = failed
            self.unverifiable = unverifiable
            self.failures = failures
        }

        /// Nothing could be checked structurally.
        public var isEmpty: Bool { passed == 0 && failed.isEmpty }
        public var total: Int { passed + failed.count }
        public var status: VerificationReport.Outcome { !failed.isEmpty ? .failed : (passed > 0 ? .passed : .unverified) }
    }

    // MARK: Entry points

    /// A catalog operation on a photo.
    public static func check(_ call: OperationCall, before: PhotoDocument, after: PhotoDocument) -> Report {
        guard let spec = OperationCatalog.shared.spec(call.id) else { return Report(unverifiable: 1) }
        let target = layerTarget(call.args, before: before, after: after)
        return evaluate(spec.verify, args: call.args, before: before, after: after) { probe, document in
            photoValue(probe, args: call.args, document: document, layerID: target)
        }
    }

    /// Any photo step: a catalog operation, or an action the catalog describes (its spec's postconditions).
    public static func check(_ intent: EditIntent, before: PhotoDocument, after: PhotoDocument) -> Report {
        if intent.action == .operation, let call = intent.operation { return check(call, before: before, after: after) }
        guard let spec = OperationCatalog.shared.spec(lowering: intent.action) else { return Report(unverifiable: 1) }
        let args = arguments(of: intent)
        let target = layerTarget(args, before: before, after: after)
        return evaluate(spec.verify, args: args, before: before, after: after) { probe, document in
            photoValue(probe, args: args, document: document, layerID: target)
        }
    }

    /// A video step the catalog describes.
    public static func check(_ intent: EditIntent, before: VideoTimeline, after: VideoTimeline) -> Report {
        guard let spec = spec(for: intent) else { return Report(unverifiable: 1) }
        let args = intent.operation?.args ?? arguments(of: intent)
        return evaluate(spec.verify, args: args, before: before, after: after) { probe, timeline in videoValue(probe, args: args, timeline: timeline) }
    }

    /// A PDF step the catalog describes.
    public static func check(_ intent: EditIntent, before: PDFDocumentModel, after: PDFDocumentModel) -> Report {
        guard let spec = spec(for: intent) else { return Report(unverifiable: 1) }
        let args = intent.operation?.args ?? arguments(of: intent)
        return evaluate(spec.verify, args: args, before: before, after: after) { probe, document in pdfValue(probe, document: document) }
    }

    static func spec(for intent: EditIntent) -> OperationSpec? {
        if intent.action == .operation, let call = intent.operation { return OperationCatalog.shared.spec(call.id) }
        return OperationCatalog.shared.spec(lowering: intent.action)
    }

    /// A legacy step's arguments in the model's vocabulary (what equalsParam reads).
    static func arguments(of intent: EditIntent) -> [String: OpValue] {
        let step = RawIntentStep(intent: intent)
        var args: [String: OpValue] = [:]
        if let parameter = step.parameter { args["parameter"] = .string(parameter) }
        if let amount = step.amount { args["amount"] = .number(amount) }
        if let aspect = step.aspect { args["aspect"] = .string(aspect) }
        if let degrees = step.degrees { args["degrees"] = .number(degrees) }
        if let text = step.text { args["text"] = .string(text) }
        return args
    }

    // MARK: Evaluation

    /// What a probe reads: a number, an exact text, an opaque state compared for change only, or a count with
    /// the state it counts (the local adjustments: their number goes up or down, their content changes).
    enum ProbeValue: Equatable {
        case number(Double), text(String), state(String), counted(Double, String)

        var number: Double? {
            switch self {
            case .number(let value), .counted(let value, _): return value
            default: return nil
            }
        }

        var shown: String {
            switch self {
            case .number(let value): return OperationPostconditions.format(value)
            case .text(let text): return text
            case .state: return "unchanged"
            case .counted(let value, _): return OperationPostconditions.format(value)
            }
        }
    }

    static func evaluate<Document>(_ conditions: [Postcondition], args: [String: OpValue], before: Document, after: Document,
                                   read: (StateProbe, Document) -> ProbeValue?) -> Report {
        var report = Report()
        for condition in conditions {
            guard case .structural(let probe, let expectation) = condition else {
                report.unverifiable += 1
                continue
            }
            let old = read(probe, before), new = read(probe, after)
            guard let new else {
                report.unverifiable += 1
                continue
            }
            let name = probeName(probe)
            func fail(_ expected: String, _ observed: String) {
                let failure = Report.Failure(probe: name, expected: expected, observed: observed)
                report.failures.append(failure)
                report.failed.append(failure.line)
            }
            switch expectation {
            case .changed:
                guard let old else { report.unverifiable += 1; continue }
                if old != new { report.passed += 1 } else { fail("changed", new.shown) }
            case .unchanged:
                guard let old else { report.unverifiable += 1; continue }
                if old == new { report.passed += 1 } else { fail("unchanged", new.shown) }
            case .increased, .decreased:
                guard let a = old?.number, let b = new.number else { report.unverifiable += 1; continue }
                let up = expectation == .increased
                if up ? b > a + 1e-9 : b < a - 1e-9 { report.passed += 1 } else { fail(up ? "> \(format(a))" : "< \(format(a))", format(b)) }
            case .delta(let delta):
                guard let a = old?.number, let b = new.number else { report.unverifiable += 1; continue }
                if abs((b - a) - delta) < 1e-6 { report.passed += 1 } else { fail(format(a + delta), format(b)) }
            case .equalsParam(let key):
                guard let expected = expectedValue(probe, key: key, args: args) else { report.unverifiable += 1; continue }
                if matches(new, expected, probe: probe) { report.passed += 1 } else { fail(expected.shown, new.shown) }
            }
        }
        return report
    }

    /// The value a param asks for, in the probe's terms (an aspect name becomes its ratio).
    static func expectedValue(_ probe: StateProbe, key: String, args: [String: OpValue]) -> ProbeValue? {
        guard let value = args[key] else { return nil }
        if probe == .canvasAspect {
            guard let name = value.string, let ratio = AspectPreset(rawValue: name)?.value else { return nil }
            return .number(ratio)
        }
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .text(text)
        case .bool(let flag): return .text(flag ? "true" : "false")
        default: return nil
        }
    }

    static func matches(_ observed: ProbeValue, _ expected: ProbeValue, probe: StateProbe) -> Bool {
        switch (observed, expected) {
        case (.number(let a), .number(let b)):
            let tolerance = probe == .canvasAspect ? 0.02 : 0.5
            return abs(a - b) <= tolerance
        case (.text(let a), .text(let b)):
            return a.lowercased() == b.lowercased()
        default:
            return false
        }
    }

    static func probeName(_ probe: StateProbe) -> String {
        switch probe {
        case .adjustment(let key): return key
        case .toneCurve: return "toneCurve"
        case .levels: return "levels"
        case .colorMixer: return "colorMixer"
        case .colorGrade: return "colorGrade"
        case .lutIntensity: return "lutIntensity"
        case .perspective: return "perspective"
        case .lensBlur: return "lensBlur"
        case .layerOpacity: return "layerOpacity"
        case .layerBlend: return "layerBlend"
        case .layerVisibility: return "layerVisibility"
        case .layerOrder: return "layerOrder"
        case .layerCount: return "layerCount"
        case .textLayerCount: return "textLayerCount"
        case .canvasAspect: return "canvasAspect"
        case .rotation: return "rotation"
        case .clipCount: return "clipCount"
        case .timelineDuration: return "timelineDuration"
        case .captions: return "captions"
        case .overlayCount: return "overlayCount"
        case .audioTrackCount: return "audioTrackCount"
        case .pageCount: return "pageCount"
        case .markupCount: return "markupCount"
        case .localAdjustments: return "localAdjustments"
        case .selection: return "selection"
        case .selectionCoverage: return "selectionCoverage"
        }
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Photo probes

    /// The layer the layer probes read: the one whose properties changed, else the one the ref names
    /// (or the selected one), as the handler resolves it.
    static func layerTarget(_ args: [String: OpValue], before: PhotoDocument, after: PhotoDocument) -> UUID? {
        let changed = after.layers.filter { layer in
            guard let old = before.layer(id: layer.id) else { return false }
            return old.opacity != layer.opacity || old.blendMode != layer.blendMode || old.isVisible != layer.isVisible
                || before.index(of: layer.id) != after.index(of: layer.id)
        }
        if changed.count == 1 { return changed[0].id }
        return PhotoOperationHandlers.layer(ref: args["ref"]?.string, in: after, scene: nil)?.id
    }

    static func photoValue(_ probe: StateProbe, args: [String: OpValue], document: PhotoDocument, layerID: UUID?) -> ProbeValue? {
        let active = document.activeImageLayerID.flatMap { document.layer(id: $0) }
        let base = document.baseLayer
        let layer = layerID.flatMap { document.layer(id: $0) }
        switch probe {
        case .adjustment(let key):
            let name = args[key]?.string ?? key
            guard let parameter = AdjustmentParameter(rawValue: name), let active else { return nil }
            return .number(active.edits.resolvedAdjustments[parameter])
        case .toneCurve:
            return active.map { .state(String(describing: PhotoOperationHandlers.userToneCurve($0.edits))) }
        case .levels:
            return active.map { .state(String(describing: $0.edits.resolvedLevels)) }
        case .colorMixer:
            return active.map { .state(String(describing: PhotoOperationHandlers.lastMixer($0.edits))) }
        case .colorGrade:
            return active.map { .state(String(describing: PhotoOperationHandlers.lastGrade($0.edits))) }
        case .lutIntensity:
            return active.map { .number((PhotoOperationHandlers.lastLUT($0.edits)?.intensity ?? 0) * 100) }
        case .perspective:
            guard let base else { return nil }
            let last = base.edits.operations.last { if case .perspective = $0.kind { return true } else { return false } }
            return .state(last.map { String(describing: $0.kind) } ?? "none")
        case .lensBlur:
            guard let base else { return nil }
            guard let lens = base.edits.resolvedLensBlur else { return .state("none") }
            return .state("\(lens.focus.x),\(lens.focus.y),\(lens.aperture)")
        case .layerOpacity:
            return layer.map { .number($0.opacity * 100) }
        case .layerBlend:
            return layer.map { .text($0.blendMode.rawValue) }
        case .layerVisibility:
            return layer.map { .text($0.isVisible ? "true" : "false") }
        case .layerOrder:
            return layerID.flatMap { document.index(of: $0) }.map { .number(Double($0)) }
        case .layerCount:
            return .number(Double(document.layers.count))
        case .textLayerCount:
            return .number(Double(document.layers.filter { $0.textElement != nil }.count))
        case .canvasAspect:
            return .number(document.canvasSize.aspectRatio)
        case .rotation:
            return base.map { .number($0.edits.resolvedRotation) }
        case .clipCount, .timelineDuration, .captions, .overlayCount, .audioTrackCount, .pageCount, .markupCount:
            return nil
        case .localAdjustments:
            let masks = document.localAdjustments
            return .counted(Double(masks.count), String(describing: masks))
        case .selection:
            return .counted(document.selection == nil ? 0 : 1, document.selection.map { String(describing: $0) } ?? "none")
        case .selectionCoverage:
            return .number((document.selection?.coverage ?? 0) * 100)
        }
    }

    // MARK: Video and PDF probes

    static func videoValue(_ probe: StateProbe, args: [String: OpValue], timeline: VideoTimeline) -> ProbeValue? {
        switch probe {
        case .clipCount: return .number(Double(timeline.clips.count))
        case .timelineDuration: return .number(timeline.duration)
        case .captions: return .state(String(describing: timeline.captions))
        case .overlayCount: return .number(Double(timeline.overlays.count))
        case .audioTrackCount: return .number(Double(timeline.audioTracks.count))
        case .canvasAspect:
            if let ratio = timeline.aspect.value { return .number(ratio) }
            return timeline.renderSize.height > 0 ? .number(timeline.renderSize.aspectRatio) : nil
        case .adjustment(let key):
            let name = args[key]?.string ?? key
            guard let parameter = AdjustmentParameter(rawValue: name), !timeline.clips.isEmpty else { return nil }
            return .number(timeline.clips.map { $0.adjustments[parameter] }.reduce(0, +) / Double(timeline.clips.count))
        default:
            return nil
        }
    }

    static func pdfValue(_ probe: StateProbe, document: PDFDocumentModel) -> ProbeValue? {
        switch probe {
        case .pageCount: return .number(Double(document.pageCount))
        case .markupCount: return .number(Double(document.allMarkups.count))
        default: return nil
        }
    }

    // MARK: Live

    /// The effect a photo `.operation` result carries its report in, for Live's verify step.
    static let effectPrefix = "postconditions:"
    private static let separator: Character = "\u{1F}"

    public static func effect(_ report: Report) -> EditorEffect {
        var fields = ["\(report.passed)", "\(report.unverifiable)"]
        fields += report.failures.map { "\($0.probe)\u{1E}\($0.expected)\u{1E}\($0.observed)" }
        return .message(effectPrefix + fields.joined(separator: String(separator)))
    }

    /// The report a result's effects carry, if any.
    public static func report(in effects: [EditorEffect]) -> Report? {
        for effect in effects {
            guard case .message(let message) = effect, message.hasPrefix(effectPrefix) else { continue }
            let fields = message.dropFirst(effectPrefix.count).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let passed = Int(fields[0]), let unverifiable = Int(fields[1]) else { return nil }
            let failures = fields.dropFirst(2).compactMap { field -> Report.Failure? in
                let parts = field.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init)
                return parts.count == 3 ? Report.Failure(probe: parts[0], expected: parts[1], observed: parts[2]) : nil
            }
            return Report(passed: passed, failed: failures.map(\.line), unverifiable: unverifiable, failures: failures)
        }
        return nil
    }

    /// The report as a step's check ('verified n/m', 'verify failed n/m: probe=expected reads …'), nil when
    /// nothing was checked.
    public static func verification(_ report: Report, intent: EditIntent) -> VerificationReport? {
        guard !report.isEmpty else { return nil }
        var items: [VerificationReport.Item] = []
        let tag = intent.operation?.id.raw ?? intent.action.rawValue
        for _ in 0..<report.passed {
            items.append(.init(check: VerificationCheck(kind: .textPresent, region: .unit, tag: tag), outcome: .passed))
        }
        for failure in report.failures {
            // The check kind is borrowed: the summary reads "probe=expected reads 'observed'".
            let check = VerificationCheck(kind: .textPresent, region: .unit, text: failure.expected, tag: "\(failure.probe)=\(failure.expected)")
            items.append(.init(check: check, outcome: .failed, observed: failure.observed))
        }
        return VerificationReport(intentID: intent.id, action: intent.action, items: items, method: .structural)
    }
}
