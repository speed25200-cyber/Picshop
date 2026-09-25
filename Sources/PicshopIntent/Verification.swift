import Foundation
import PicshopCore

// Act-then-verify. After a step applies, the host builds the checks with `EditVerifier.request`,
// the imaging layer runs them on the rendered result (`PhotoAIServices.verify`), and Live hands the
// report's `summary` to the model, which gets at most one repair round when it failed. The grammar
// lane gets the same checks. Everything here is pure and runs on Linux.

/// One thing the rendered result should show after an edit.
public struct VerificationCheck: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        /// `text` reads inside `region`.
        case textPresent
        /// `text` (nil: any text) no longer reads inside `region`.
        case textAbsent
        /// Nothing labelled `label` is detected over `region` any more.
        case objectAbsent
    }

    public var kind: Kind
    /// Normalised canvas space, top-left origin.
    public var region: PSRect
    public var text: String?
    /// objectAbsent: canonical English label ("person", "sign").
    public var label: String?
    /// Short name for the summary: "r6c3" (a cell), "t3" (a block), "text", "dog".
    public var tag: String
    /// The Picshop layer expected to carry `text`, when there is one (the structural check reads it).
    public var layerID: UUID?

    public init(kind: Kind, region: PSRect, text: String? = nil, label: String? = nil, tag: String, layerID: UUID? = nil) {
        self.kind = kind
        self.region = region
        self.text = text
        self.label = label
        self.tag = tag
        self.layerID = layerID
    }
}

/// The checks for one applied step.
public struct VerificationRequest: Hashable, Codable, Sendable {
    public var intentID: UUID
    public var action: IntentAction
    public var checks: [VerificationCheck]

    public init(intentID: UUID, action: IntentAction, checks: [VerificationCheck]) {
        self.intentID = intentID
        self.action = action
        self.checks = checks
    }
}

/// What the checks found.
public struct VerificationReport: Hashable, Codable, Sendable {
    public enum Outcome: String, Hashable, Codable, Sendable { case passed, failed, unverified }
    /// pixels: OCR and the detector on the render; structural: the document alone (layers).
    public enum Method: String, Hashable, Codable, Sendable { case pixels, structural }

    public struct Item: Hashable, Codable, Sendable {
        public var check: VerificationCheck
        public var outcome: Outcome
        /// What was read or detected there ("7", "dog"), for the repair round.
        public var observed: String?

        public init(check: VerificationCheck, outcome: Outcome, observed: String? = nil) {
            self.check = check
            self.outcome = outcome
            self.observed = observed
        }
    }

    public var intentID: UUID
    public var action: IntentAction
    public var items: [Item]
    public var method: Method

    public init(intentID: UUID, action: IntentAction, items: [Item], method: Method) {
        self.intentID = intentID
        self.action = action
        self.items = items
        self.method = method
    }

    /// Every check unverified: what a back end that cannot read pixels answers.
    public static func unverified(_ request: VerificationRequest, method: Method = .structural) -> VerificationReport {
        VerificationReport(intentID: request.intentID, action: request.action,
                           items: request.checks.map { Item(check: $0, outcome: .unverified) }, method: method)
    }

    public var total: Int { items.count }
    public var passed: Int { items.filter { $0.outcome == .passed }.count }
    public var failed: Int { items.filter { $0.outcome == .failed }.count }
    public var unverifiedCount: Int { items.filter { $0.outcome == .unverified }.count }

    /// failed when any check failed; passed when at least one passed and none failed; else unverified.
    public var status: Outcome {
        if failed > 0 { return .failed }
        return passed > 0 ? .passed : .unverified
    }

    public var failures: [Item] { items.filter { $0.outcome == .failed } }

    /// English, at most 200 characters, for the model only (never spoken):
    /// "verified 45/45" · "verify failed 3/45: r2c1 reads '7'; r5c4 missing; t3 still there" · "not verified".
    public var summary: String {
        switch status {
        case .passed:
            return "verified \(passed)/\(total)"
        case .unverified:
            return "not verified"
        case .failed:
            var text = "verify failed \(failed)/\(total):"
            var shown = 0
            for item in failures {
                let part = " " + Self.describe(item) + ";"
                guard text.count + part.count <= 190, shown < 6 else { break }
                text += part
                shown += 1
            }
            if shown < failed { text += " +\(failed - shown) more" }
            if text.hasSuffix(";") { text.removeLast() }
            return String(text.prefix(200))
        }
    }

    static func describe(_ item: Item) -> String {
        let observed = item.observed.map { String($0.prefix(16)) }
        switch item.check.kind {
        case .textPresent:
            if let observed, !observed.isEmpty { return "\(item.check.tag) reads '\(observed)'" }
            return "\(item.check.tag) missing"
        case .textAbsent:
            return "\(item.check.tag) still there"
        case .objectAbsent:
            return "\(item.check.tag) still visible"
        }
    }
}

/// Plans and runs the document-level part of act-then-verify.
public enum EditVerifier {
    /// Steps worth a look at the result. Adjustments and looks always "work"; there is nothing to check.
    public static let verifiedActions: Set<IntentAction> = [
        .fillCells, .clearCells, .addText, .editText, .removeText, .moveText, .eraseRegion, .removeObject,
    ]

    /// The checks for one applied step: what `after` should show that `before` did not. `scene` is the
    /// map the step was planned on (the ids it used). Nil when the step did not apply or has nothing
    /// to check.
    public static func request(for intent: EditIntent, before: PhotoDocument, after: PhotoDocument, result: ExecutionResult,
                               scene: SceneMap?) -> VerificationRequest? {
        guard result.outcome.isSuccess, verifiedActions.contains(intent.action) else { return nil }
        let canvas = after.canvasSize
        let beforeLayers = Dictionary(before.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var checks: [VerificationCheck] = []
        var writtenBoxes: [PSRect] = []

        // Text layers the step made or changed must read where they are.
        for layer in after.layers where layer.isVisible {
            guard let element = layer.textElement, !element.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let old = beforeLayers[layer.id], old.textElement == element { continue }
            let box = element.estimatedBox(canvasSize: canvas)
            writtenBoxes.append(box)
            let region = box.insetBy(dx: -box.width * 0.15 - 0.004, dy: -box.height * 0.25 - 0.004).clampedToUnit()
            var tag = "text"
            if let group = layer.group, let row = group.row, let column = group.column { tag = "r\(row)c\(column)" }
            else if intent.ref?.isText == true, let ref = intent.ref { tag = ref.id }
            checks.append(VerificationCheck(kind: .textPresent, region: region, text: element.text, tag: tag, layerID: layer.id))
        }

        // Text the step removed or moved away must be gone from where it was.
        let afterIDs = Set(after.layers.map(\.id))
        for layer in before.layers where !afterIDs.contains(layer.id) {
            guard let element = layer.textElement, layer.isVisible, !element.text.isEmpty else { continue }
            var tag = "text"
            if let group = layer.group, let row = group.row, let column = group.column { tag = "r\(row)c\(column)" }
            checks.append(VerificationCheck(kind: .textAbsent, region: element.estimatedBox(canvasSize: before.canvasSize).clampedToUnit(),
                                            text: element.text, tag: tag, layerID: layer.id))
        }
        if let ref = intent.ref, ref.isText, let block = scene?.block(ref), !block.isLayer,
           intent.action == .editText || intent.action == .removeText || intent.action == .moveText || intent.action == .eraseRegion {
            let written = SceneMap.folded(intent.text ?? "")
            // The old words should be gone, unless the new text still contains them ("Total" -> "Total 2025"),
            // the step only restyled them (same words, new colour, size, weight or alignment, where they were)
            // or a short move put the text back over its old place.
            let keptWords = intent.action == .editText && (intent.text == nil || written.isEmpty || written.contains(SceneMap.folded(block.text)))
            let movedOntoItself = intent.action == .moveText && writtenBoxes.contains { $0.iou(block.box) > 0.1 }
            if !keptWords, !movedOntoItself {
                checks.append(VerificationCheck(kind: .textAbsent, region: block.box, text: block.text, tag: ref.id))
            }
        }

        // Pixels the step erased.
        let newOperations = Array((after.baseLayer?.edits.operations ?? []).dropFirst(before.baseLayer?.edits.operations.count ?? 0))
        for operation in newOperations {
            guard case .removeObject(let mask) = operation.kind else { continue }
            switch intent.action {
            case .removeObject:
                let label = intent.target?.label ?? "object"
                if ["text", "data", "number", "numbers", "word", "words", "watermark"].contains(label) {
                    checks.append(VerificationCheck(kind: .textAbsent, region: mask.boundingBox, tag: label))
                } else {
                    checks.append(VerificationCheck(kind: .objectAbsent, region: mask.boundingBox, label: label, tag: label))
                }
            case .eraseRegion:
                if case .object(let n)? = intent.ref, let object = scene?.object(id: "o\(n)") {
                    checks.append(VerificationCheck(kind: .objectAbsent, region: object.box, label: object.label, tag: "o\(n)"))
                } else if intent.ref == nil, let scene, scene.texts.contains(where: { !$0.isLayer && $0.box.intersection(mask.boundingBox).area > 0 }) {
                    checks.append(VerificationCheck(kind: .textAbsent, region: mask.boundingBox, tag: "area"))
                }
            default:
                continue
            }
        }
        // Printed values a table step erased: each cleared cell (and the one cell a fill wrote over) must no
        // longer read its old value; the cell geometry is known, so the check is per cell.
        if let grid = scene?.table, let spec = intent.table, intent.action == .clearCells || (intent.action == .fillCells && spec.namesOneCell),
           let cells = try? TableSelection.scope(for: spec, in: grid) {
            let newValue: String? = {
                if case .constant(let text)? = spec.value { return SceneMap.folded(text) }
                return nil
            }()
            for cell in cells where (cell.state == .printed || cell.state == .placeholder) && !cell.text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let address = grid.dataAddress(of: cell) else { continue }
                // A fill that writes the old value again ("80" -> "80%") keeps it on purpose.
                if intent.action == .fillCells, let newValue, newValue.contains(SceneMap.folded(cell.text)) { continue }
                checks.append(VerificationCheck(kind: .textAbsent, region: cell.contentRect, text: cell.text, tag: "r\(address.row)c\(address.column)"))
            }
        }
        guard !checks.isEmpty else { return nil }
        return VerificationRequest(intentID: intent.id, action: intent.action, checks: checks)
    }

    /// The document-only check (no pixels): a textPresent passes when a visible text layer with that
    /// text sits in the region, a textAbsent fails when one still does; everything about printed
    /// pixels or objects stays unverified. The default of `PhotoAIServices.verify`, and what Linux tests use.
    public static func structural(_ request: VerificationRequest, in document: PhotoDocument) -> VerificationReport {
        let canvas = document.canvasSize
        let visible = document.layers.filter { $0.isVisible && $0.textElement != nil }
        func layersIn(_ region: PSRect) -> [(Layer, TextElement)] {
            let grown = region.insetBy(dx: -region.width * 0.1, dy: -region.height * 0.1)
            return visible.compactMap { layer in
                guard let element = layer.textElement, grown.contains(element.estimatedBox(canvasSize: canvas).center) else { return nil }
                return (layer, element)
            }
        }
        let items = request.checks.map { check -> VerificationReport.Item in
            switch check.kind {
            case .textPresent:
                let wanted = SceneMap.folded(check.text ?? "")
                if let id = check.layerID {
                    guard let layer = document.layer(id: id), layer.isVisible, let element = layer.textElement else {
                        return .init(check: check, outcome: .failed)
                    }
                    let inside = check.region.insetBy(dx: -check.region.width * 0.1, dy: -check.region.height * 0.1)
                        .contains(element.estimatedBox(canvasSize: canvas).center)
                    let reads = wanted.isEmpty || SceneMap.folded(element.text).contains(wanted)
                    return .init(check: check, outcome: inside && reads ? .passed : .failed, observed: element.text)
                }
                let found = layersIn(check.region)
                if found.contains(where: { wanted.isEmpty || SceneMap.folded($0.1.text).contains(wanted) }) {
                    return .init(check: check, outcome: .passed, observed: check.text)
                }
                // No layer reads it; printed pixels might, which only the pixel check can tell.
                return .init(check: check, outcome: found.isEmpty ? .unverified : .failed, observed: found.first?.1.text)
            case .textAbsent:
                if let id = check.layerID {
                    // A layer's text is gone when the layer is.
                    guard let layer = document.layer(id: id), layer.isVisible else { return .init(check: check, outcome: .passed) }
                    return .init(check: check, outcome: .failed, observed: layer.textElement?.text)
                }
                let unwanted = check.text.map { SceneMap.folded($0) }
                let still = layersIn(check.region).first { pair in
                    guard let unwanted, !unwanted.isEmpty else { return true }
                    return SceneMap.folded(pair.1.text).contains(unwanted)
                }
                return still.map { .init(check: check, outcome: .failed, observed: $0.1.text) } ?? .init(check: check, outcome: .unverified)
            case .objectAbsent:
                return .init(check: check, outcome: .unverified)
            }
        }
        return VerificationReport(intentID: request.intentID, action: request.action, items: items, method: .structural)
    }
}
