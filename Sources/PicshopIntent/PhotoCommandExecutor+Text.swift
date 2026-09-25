import Foundation
import PicshopCore

// Composable photo primitives, so a request nobody foresaw can still be carried out step by step:
// text placed at a point or in a box in a chosen or matched style, a detected text block rewritten or
// moved in its own style, a region erased. Every step is validated before anything changes, and each
// one is one document mutation (one commit, one undo): an erase and the text that replaces it go together.

extension PhotoCommandExecutor {
    // MARK: addText in a box, at a scene area, or in a style

    /// addText with a box (`region`), a scene id (`ref`: a free area to write in, or a text block to
    /// write under) or a style (`textStyle`): laid out in the box, in the asked or matched typography.
    func placeText(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let fr = language == .french
        guard let text = intent.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (document, ExecutionResult(outcome: .info(message: fr ? "Quel texte ?" : "What should it say?")))
        }
        let scene = await currentScene(in: document, context: context)
        var box: PSRect? = intent.region
        var alignedWith: SceneMap.TextBlock?
        if let ref = intent.ref {
            switch ref {
            case .area:
                guard let area = scene?.freeArea(id: ref.id) else { return (document, unknownRef()) }
                box = area.box
            case .text, .layer:
                // "sous le titre": a line under that block, on its left edge and in its style unless said otherwise.
                guard let block = scene?.block(ref) ?? layerBlock(ref, in: document) else { return (document, unknownRef()) }
                alignedWith = block
                let height = block.box.height / Double(max(1, block.lineCount))
                var line = PSRect(x: block.box.minX, y: min(1 - height, block.box.maxY + 0.25 * height), width: max(block.box.width, 0.2), height: height)
                // A line already under it (a subtitle): the new one goes under that, never over it.
                for _ in 0..<6 {
                    guard let blocker = scene?.texts.first(where: { $0.id != block.id && $0.box.intersection(line).area > line.area * 0.05 }) else { break }
                    line.origin.y = min(1 - height, blocker.box.maxY + 0.25 * height)
                }
                box = line
            case .object:
                // Beside an object makes no sense without a side: under it.
                guard let object = scene?.object(id: ref.id) else { return (document, unknownRef()) }
                box = PSRect(x: object.box.minX, y: min(0.94, object.box.maxY + 0.01), width: object.box.width, height: 0.06)
            }
        }
        if let region = box, region.width < 0.01 || region.height < 0.006 { return (document, badRegion()) }

        let point = intent.target?.point.map { PSPoint(x: $0.x.clamped(to: 0...1), y: $0.y.clamped(to: 0...1)) }
        let anchor = box?.center ?? point ?? (intent.placement ?? .bottom).center
        // The style: what it matches (a block, or the text nearest the new one), else the block it goes under.
        var matched: TableGrid.Style?
        switch intent.textStyle?.match {
        case .ref(let ref)?:
            guard let block = scene?.block(ref) ?? layerBlock(ref, in: document) else { return (document, unknownRef()) }
            matched = block.style ?? Self.estimatedStyle(of: block)
        case .nearby?:
            matched = scene?.style(near: box ?? PSRect(x: anchor.x - 0.05, y: anchor.y - 0.02, width: 0.1, height: 0.04))
        case nil:
            matched = alignedWith.flatMap { $0.style ?? Self.estimatedStyle(of: $0) }
        }
        var element = TextElement(text: text)
        var base = matched ?? TableGrid.Style(relativeSize: element.relativeSize, color: element.color, weight: .bold, design: .rounded, alignment: .center)
        if matched == nil, let box {
            // A box with no style to copy: text as tall as the box allows.
            let lines = Double(max(1, text.split(separator: "\n").count))
            base.relativeSize = min(0.12, 0.7 * box.height / lines)
            base.color = Self.readableColor(on: scene?.freeAreas.first { $0.box.iou(box) > 0.3 }?.background ?? scene?.background)
            base.weight = .semibold
            base.design = .sans
        }
        if let alignedWith, intent.textStyle?.alignment == nil { base.alignment = alignedWith.style?.alignment ?? .leading }
        let style = (intent.textStyle ?? TextStyleSpec()).applied(to: base)
        element.fontName = Self.textFontName(style)
        element.relativeSize = style.relativeSize
        element.color = intent.color ?? style.color
        element.alignment = style.alignment
        element.style = matched != nil || box != nil ? .plain : element.style
        if matched != nil || box != nil { element.lineSpacing = 1.0 }
        if let amount = intent.amount, amount.mode == .absolute { element.relativeSize = amount.value.clamped(to: TextStyleSpec.relativeSizeRange) }
        if let box {
            // Fit the box, keep the size asked for when it fits.
            let lines = Double(max(1, text.split(separator: "\n").count))
            let widest = text.split(separator: "\n").map(String.init).max { $0.count < $1.count } ?? text
            element.relativeSize = Self.fittedSize(widest, element.relativeSize, width: box.width, height: box.height / lines, canvas: document.canvasSize)
            element.maxRelativeWidth = box.width
            if element.alignment != .center { element.frameWidth = box.width }
            element.center = box.center
        } else {
            element.center = anchor
            // At a placement (no box, no point shown), the styled line moves off the text and table already there,
            // as the plain addText does.
            if point == nil, let scene {
                let size = element.estimatedBox(canvasSize: document.canvasSize).size
                if let clear = RuleBasedIntentEngine.clearBox(for: intent.placement ?? .bottom, in: scene, size: size, anchor: anchor) {
                    element.center = clear.center
                }
            }
        }
        let layer = Layer(name: String(text.prefix(40)), content: .text(element), transform: LayerTransform(center: element.center))
        document.addLayer(layer)
        return (document, .applied("Add Text", effects: [.selectLayer(layer.id)]))
    }

    // MARK: Text blocks

    /// editText on a scene block: a layer is edited in place; printed text is erased with a tight mask
    /// and rewritten as a layer in its measured style, in one commit.
    func editTextBlock(_ ref: SceneRef, intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let scene = await currentScene(in: document, context: context)
        guard let block = scene?.block(ref) ?? layerBlock(ref, in: document) else { return (document, unknownRef()) }
        let matched = await matchedStyle(intent, scene: scene, document: document)
        if let layerID = block.layerID {
            guard document.layer(id: layerID)?.textElement != nil else { return (document, unknownRef()) }
            document.update(layerID: layerID) { layer in
                guard var element = layer.textElement else { return }
                if let text = intent.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { element.text = text; layer.name = String(text.prefix(40)) }
                if let destination = destination(of: intent, from: element.center) { element.center = destination }
                if let matched { Self.apply(matched, to: &element) }
                Self.restyle(&element, with: intent)
                layer.textElement = element
                layer.transform.center = element.center
            }
            return (document, .applied("Edit Text"))
        }
        // Printed: the same words (or new ones) in the block's own style, where they were.
        let text = intent.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? block.text
        var element = rewritten(block, text: text, canvas: document.canvasSize)
        if let matched { Self.apply(matched, to: &element) }
        Self.restyle(&element, with: intent)
        if let destination = destination(of: intent, from: element.center) { element.center = destination }
        rememberTableIfTouched(block.box, context: context, in: &document, grid: scene?.table)
        do { try await eraseBlock(block, in: &document) } catch { return (input, failure(error)) }
        let layer = Layer(name: String(text.prefix(40)), content: .text(element), transform: LayerTransform(center: element.center))
        document.addLayer(layer)
        return (document, .applied("Edit Text", effects: [.selectLayer(layer.id)]))
    }

    /// removeText (or removeObject) on a scene block: a layer is deleted; printed text is erased with a tight mask.
    func removeTextBlock(_ ref: SceneRef, intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let scene = await currentScene(in: document, context: context)
        guard let block = scene?.block(ref) ?? layerBlock(ref, in: document) else { return (document, unknownRef()) }
        if let layerID = block.layerID {
            guard document.removeLayer(id: layerID) != nil else { return (document, unknownRef()) }
            return (document, .applied("Remove Text"))
        }
        rememberTableIfTouched(block.box, context: context, in: &document, grid: scene?.table)
        do { try await eraseBlock(block, in: &document) } catch { return (input, failure(error)) }
        return (document, .applied("Remove Text"))
    }

    /// Erases `region` (or the box of `ref`) and fills it from its surroundings.
    func eraseRegion(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        let document = input
        let fr = language == .french
        let scene = await currentScene(in: document, context: context)
        if let ref = intent.ref {
            switch ref {
            case .text, .layer:
                return await removeTextBlock(ref, intent: intent, on: document, context: context)
            case .object:
                var removal = intent
                removal.action = .removeObject
                return await actOnSceneObject(removal, on: document, context: context, label: "Erase Area")
            case .area:
                guard let area = scene?.freeArea(id: ref.id) else { return (document, unknownRef()) }
                return await erase(area.box, in: document, context: context, scene: scene)
            }
        }
        guard let region = intent.region else {
            let message = fr ? "Entoure la zone à effacer, ou dis-moi laquelle." : "Circle the area to erase, or tell me which one."
            return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("selectRegion"), ExecutionReason.needsSelection.effect]))
        }
        return await erase(region, in: document, context: context, scene: scene)
    }

    /// Moves a text block: a layer moves; printed text is erased and rewritten at the destination in its own style.
    func moveText(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let fr = language == .french
        let scene = await currentScene(in: document, context: context)
        let block: SceneMap.TextBlock
        if let ref = intent.ref {
            guard let found = scene?.block(ref) ?? layerBlock(ref, in: document) else { return (document, unknownRef()) }
            block = found
        } else if let layer = document.selectedLayer?.isText == true ? document.selectedLayer : document.textLayers.last(where: { $0.group == nil }),
                  let element = layer.textElement {
            block = SceneMap.TextBlock(id: "l0", text: element.text, box: element.estimatedBox(canvasSize: document.canvasSize), source: .layer(layer.id))
        } else {
            return (document, ExecutionResult(outcome: .failed(message: fr ? "Il n'y a pas de texte à déplacer." : "There's no text to move."), effects: [ExecutionReason.noText.effect]))
        }
        guard let target = destination(of: intent, from: block.box.center) else {
            let message = fr ? "Où veux-tu le mettre ?" : "Where should it go?"
            return (document, ExecutionResult(outcome: .info(message: message), effects: [ExecutionReason.needsSelection.effect]))
        }
        if let layerID = block.layerID {
            guard document.layer(id: layerID) != nil else { return (document, unknownRef()) }
            document.update(layerID: layerID) { layer in
                guard var element = layer.textElement else { return }
                element.center = target
                if let region = intent.region { element.maxRelativeWidth = max(element.maxRelativeWidth, region.width) }
                Self.restyle(&element, with: intent)
                layer.textElement = element
                layer.transform.center = target
            }
            return (document, .applied("Move Text"))
        }
        var element = rewritten(block, text: block.text, canvas: document.canvasSize)
        element.center = target
        Self.restyle(&element, with: intent)
        rememberTableIfTouched(block.box, context: context, in: &document, grid: scene?.table)
        do { try await eraseBlock(block, in: &document) } catch { return (input, failure(error)) }
        let layer = Layer(name: String(block.text.prefix(40)), content: .text(element), transform: LayerTransform(center: target))
        document.addLayer(layer)
        return (document, .applied("Move Text", effects: [.selectLayer(layer.id)]))
    }

    // MARK: Objects by id

    /// removeObject, blurObject or moveObject on a scene object ("o2"), with no phrase to look for.
    func actOnSceneObject(_ intent: EditIntent, on document: PhotoDocument, context: IntentContext, label: String? = nil) async -> (PhotoDocument, ExecutionResult) {
        guard case .object? = intent.ref, let ref = intent.ref else { return (document, unknownRef()) }
        let scene = await currentScene(in: document, context: context)
        guard let object = scene?.object(id: ref.id) else { return (document, unknownRef()) }
        var resolved = intent
        let phrase = language == .french ? (ObjectVocabulary.frenchName(forLabel: object.label).map { "le \($0)" } ?? "cet objet") : "the \(object.label)"
        resolved.target = ObjectTarget(label: object.label, originalPhrase: phrase)
        let candidate = ObjectCandidate(label: object.label, boundingBox: object.box, confidence: object.confidence)
        var (edited, result) = await apply(pendingIntent: resolved, candidates: [candidate], document: document)
        if let label, result.outcome.isSuccess {
            result.outcome = .applied(label: label)
            result.label = label
        }
        if result.outcome.isSuccess, intent.action == .removeObject, context.table != nil || scene?.table != nil,
           let grid = scene?.table, grid.bounds.intersection(object.box).area > 0 {
            var remembered = document
            rememberTable(grid, in: &remembered)
            edited.tableMemory = remembered.tableMemory
        }
        return (edited, result)
    }

    // MARK: Table clarification

    /// "la première" or "Opus 5.5" after "Quelle colonne : Opus 5.5 ou Opus 5 ?": the pending table step
    /// with the chosen name in place of the ambiguous one.
    func chooseTableCandidate(_ intent: EditIntent, pending: ClarificationRequest, on document: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var chosen: ObjectCandidate?
        if let index = intent.index, index >= 1, index <= pending.candidates.count { chosen = pending.candidates[index - 1] }
        else if let target = intent.target {
            let said = SceneMap.folded(target.originalPhrase)
            chosen = pending.candidates.first { SceneMap.folded($0.label) == said } ?? pending.candidates.first { said.contains(SceneMap.folded($0.label)) }
        }
        guard let choice = chosen, var spec = pending.pendingIntent.table, let grid = await currentTable(in: document) else {
            return (document, ExecutionResult(outcome: .ignored))
        }
        func replaced(_ refs: [TableEditSpec.Ref], axis: TableGrid.Axis) -> [TableEditSpec.Ref] {
            refs.map { ref in
                let names = grid.names(axis).map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
                if case .ambiguous = grid.match(ref, on: axis), names.contains(choice.label) { return .name(choice.label) }
                return ref
            }
        }
        spec.columns = replaced(spec.columns, axis: .column)
        spec.rows = replaced(spec.rows, axis: .row)
        var resumed = pending.pendingIntent
        resumed.table = spec
        return await execute(resumed, on: document, context: context)
    }

    // MARK: Scene

    /// The scene the step's ids refer to: the context's map when it is of this state (its ids kept), else
    /// a fresh one (ids carried over from the context's), overlaid with the text layers.
    func currentScene(in document: PhotoDocument, context: IntentContext) async -> SceneMap? {
        if let scene = context.scene, scene.stateKey == document.baseStateKey { return scene.overlaying(document.layers) }
        guard let fresh = (try? await services.sceneMap(in: document)) ?? nil else { return context.scene?.overlaying(document.layers) }
        let carried = context.scene.map { fresh.overlaying(document.layers).carryingIDs(from: $0) } ?? fresh.overlaying(document.layers)
        return carried
    }

    /// "l2" with no scene map: the second free-standing text layer, in document order.
    func layerBlock(_ ref: SceneRef, in document: PhotoDocument) -> SceneMap.TextBlock? {
        guard case .layer(let number) = ref else { return nil }
        let free = document.layers.filter { $0.group == nil && $0.isVisible && $0.textElement != nil }
        guard number >= 1, number <= free.count, let element = free[number - 1].textElement else { return nil }
        let style = TableGrid.Style(relativeSize: element.relativeSize, color: element.color, weight: SceneMap.weight(ofFontNamed: element.fontName),
                                    design: SceneMap.design(ofFontNamed: element.fontName), alignment: element.alignment)
        return SceneMap.TextBlock(id: ref.id, text: element.text, box: element.estimatedBox(canvasSize: document.canvasSize), style: style,
                                  source: .layer(free[number - 1].id))
    }

    /// The style a step asks to copy (`textStyle.match`), if any.
    func matchedStyle(_ intent: EditIntent, scene: SceneMap?, document: PhotoDocument) async -> TableGrid.Style? {
        switch intent.textStyle?.match {
        case .ref(let ref)?:
            guard let block = scene?.block(ref) ?? layerBlock(ref, in: document) else { return nil }
            return block.style ?? Self.estimatedStyle(of: block)
        case .nearby?:
            if case .text? = intent.ref, let block = intent.ref.flatMap({ scene?.block($0) }) {
                return scene?.texts.filter { $0.id != block.id && $0.style != nil }
                    .min { $0.box.center.distance(to: block.box.center) < $1.box.center.distance(to: block.box.center) }?.style
            }
            return intent.region.flatMap { scene?.style(near: $0) }
        case nil:
            return nil
        }
    }

    /// Where a move or an edit sends text: a point, the centre of a box, an anchor, or a direction and distance.
    func destination(of intent: EditIntent, from start: PSPoint) -> PSPoint? {
        if let point = intent.target?.point { return PSPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1)) }
        if let region = intent.region { return region.center }
        if let placement = intent.placement { return placement.center }
        if let degrees = intent.degrees {
            let distance = (intent.amount?.value ?? 0.1).clamped(to: 0.01...0.9)
            let angle = degrees * .pi / 180
            return PSPoint(x: (start.x + cos(angle) * distance).clamped(to: 0.02...0.98), y: (start.y - sin(angle) * distance).clamped(to: 0.02...0.98))
        }
        return nil
    }

    /// A printed block as a text layer that reads the same: its measured style (or one estimated from its
    /// box), plain, laid out over its box.
    func rewritten(_ block: SceneMap.TextBlock, text: String, canvas: PSSize) -> TextElement {
        let style = block.style ?? Self.estimatedStyle(of: block)
        var element = TextElement(text: text, fontName: Self.textFontName(style), relativeSize: style.relativeSize, color: style.color,
                                  alignment: style.alignment, style: .plain, center: block.box.center, letterSpacing: 0, lineSpacing: 1.0,
                                  maxRelativeWidth: min(0.95, max(block.box.width * 1.4, 0.2)))
        if style.alignment != .center {
            // Keep the edge it was aligned on, however long the new words are.
            let lines = text.split(separator: "\n").map(String.init)
            let widest = lines.map { Self.estimatedWidth($0, relativeSize: style.relativeSize, canvas: canvas) }.max() ?? 0
            let frame = min(0.95, max(block.box.width, widest * 1.05))
            element.frameWidth = frame
            element.maxRelativeWidth = frame
            let x = style.alignment == .leading ? block.box.minX + frame / 2 : block.box.maxX - frame / 2
            element.center = PSPoint(x: x.clamped(to: frame / 2...max(frame / 2, 1 - frame / 2)), y: block.box.midY)
        }
        return element
    }

    /// Typography read off a block's box when nothing was measured: size from the line height, dark or
    /// light by nothing better than a guess (dark), regular, left-aligned text.
    static func estimatedStyle(of block: SceneMap.TextBlock) -> TableGrid.Style {
        let lineHeight = block.box.height / Double(max(1, block.lineCount))
        return TableGrid.Style(relativeSize: (lineHeight * 0.8).clamped(to: TextStyleSpec.relativeSizeRange), color: PSColor(hex: "#1C1C1E") ?? .black,
                               weight: .regular, design: .sans, alignment: block.lineCount > 1 ? .leading : .center)
    }

    /// The D5 font name for text that is not a table value: plain SF Pro for sans.
    static func textFontName(_ style: TableGrid.Style) -> String {
        guard style.design == .sans else { return style.fontName }
        return "SFPro-" + (style.fontName.split(separator: "-").last.map(String.init) ?? "Regular")
    }

    /// A matched typography laid over an element (size, colour, weight, design, alignment).
    static func apply(_ style: TableGrid.Style, to element: inout TextElement) {
        element.relativeSize = style.relativeSize
        element.color = style.color
        element.fontName = textFontName(style)
        element.alignment = style.alignment
        element.style = .plain
    }

    /// Dark text on a light background, white on a dark one.
    static func readableColor(on background: PSColor?) -> PSColor {
        guard let background else { return .white }
        return background.luminance > 0.55 ? (PSColor(hex: "#1C1C1E") ?? .black) : .white
    }

    // MARK: Erasing

    /// Erases a printed block with a tight mask over its words (the block's box when OCR gave no words).
    func eraseBlock(_ block: SceneMap.TextBlock, in document: inout PhotoDocument) async throws {
        let canvas = document.canvasSize
        let boxes = (block.wordBoxes.isEmpty ? [block.box] : block.wordBoxes).map { box -> PSRect in
            let pixels = max(1.5, 0.15 * box.height * max(1, canvas.height))
            return box.insetBy(dx: -pixels / max(1, canvas.width), dy: -pixels / max(1, canvas.height)).clampedToUnit()
        }
        let candidates = boxes.map { ObjectCandidate(label: "text", boundingBox: $0, confidence: 1) }
        let target = ObjectTarget(label: "text", originalPhrase: "« \(block.text) »", matchesAll: true)
        let mask = try await services.mask(for: candidates, target: target, in: document)
        document.apply(.removeObject(mask))
    }

    /// Erases a region (a box the model or the person gave), refused when it is a sliver or most of the picture.
    func erase(_ region: PSRect, in input: PhotoDocument, context: IntentContext, scene: SceneMap?) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let box = region.clampedToUnit()
        guard box.width >= 0.005, box.height >= 0.005, box.area <= 0.5 else { return (document, badRegion()) }
        rememberTableIfTouched(box, context: context, in: &document, grid: scene?.table)
        let target = ObjectTarget(label: "object", originalPhrase: language == .french ? "cette zone" : "this area")
        do {
            let mask = try await services.mask(for: [ObjectCandidate(label: "object", boundingBox: box, confidence: 1)], target: target, in: document)
            document.apply(.removeObject(mask))
        } catch {
            return (input, failure(error))
        }
        return (document, .applied("Erase Area"))
    }

    /// D7 for any erase: when it touches the table's printed values, the table is remembered first.
    func rememberTableIfTouched(_ box: PSRect, context: IntentContext, in document: inout PhotoDocument, grid: TableGrid?) {
        guard let table = grid ?? context.table, table.bounds.intersection(box).area > 0 else { return }
        rememberTable(table, in: &document)
    }

    // MARK: Failures

    /// An id that is not on the picture (any more): unknown_ref.
    func unknownRef() -> ExecutionResult {
        let message = language == .french ? "Je ne vois pas ce que tu désignes sur l'image — tu peux me le montrer ?" : "I can't find that on the picture — can you point to it?"
        return ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.unknownRef.effect])
    }

    /// A box that is a sliver, or most of the picture: bad_region.
    func badRegion() -> ExecutionResult {
        let message = language == .french ? "Cette zone est trop petite ou trop grande pour ça." : "That area is too small or too large for this."
        return ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.badRegion.effect])
    }

    func unsupportedPrimitive() -> ExecutionResult {
        let message = language == .french ? "Je ne sais pas encore faire ça." : "I can't do that yet."
        return ExecutionResult(outcome: .info(message: message), effects: [ExecutionReason.unsupported.effect])
    }
}

fileprivate extension String {
    /// nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
