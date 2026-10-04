import Foundation
import PicshopCore

/// What a photo operation handler may read besides the document.
public struct OperationRunContext: Sendable {
    public var intent: IntentContext
    public var language: NormalizedUtterance.Language
    public var services: any PhotoAIServices
    /// The candidates the person picked after a mask or selection call asked which one (chooseCandidate): the
    /// call runs again on them instead of asking again.
    public var chosen: [ObjectCandidate]?

    public init(intent: IntentContext, language: NormalizedUtterance.Language, services: any PhotoAIServices, chosen: [ObjectCandidate]? = nil) {
        self.intent = intent
        self.language = language
        self.services = services
        self.chosen = chosen
    }

    var french: Bool { language == .french }
}

public typealias PhotoOperationHandler = @Sendable (OperationCall, PhotoDocument, OperationRunContext) async -> (PhotoDocument, ExecutionResult)

/// The photo executor of catalog operations (IntentAction.operation): one handler per operation id.
/// Every handler edits through EditStack (setTone, setColor: one undo step, idempotent like the
/// panels) or the layer's own fields, and answers like the other executors: an applied label
/// for the history, or an honest reason it could not.
public enum PhotoOperationHandlers {
    public static let table: [OpID: PhotoOperationHandler] = [
        "curves": { call, document, context in curves(call, document, context) },
        "levels": { call, document, context in await levels(call, document, context) },
        "autoTone": { call, document, context in await autoTone(call, document, context) },
        "hsl": { call, document, context in hsl(call, document, context) },
        "colorGrade": { call, document, context in colorGrade(call, document, context) },
        "lutIntensity": { call, document, context in lut(call, document, context, remove: false) },
        "removeLUT": { call, document, context in lut(call, document, context, remove: true) },
        "perspective": { call, document, context in perspective(call, document, context) },
        "lensFocus": { call, document, context in await lensFocus(call, document, context) },
        "layerOpacity": { call, document, context in layerProperty(call, document, context) },
        "layerBlend": { call, document, context in layerProperty(call, document, context) },
        "layerVisibility": { call, document, context in layerProperty(call, document, context) },
        "layerOrder": { call, document, context in layerOrder(call, document, context) },
        // W2: masks and selections (PhotoOperationHandlers+Masks, +Selection).
        "maskAdjust": { call, document, context in await maskAdjust(call, document, context) },
        "maskEdit": { call, document, context in await maskEdit(call, document, context) },
        "maskDelete": { call, document, context in maskDelete(call, document, context) },
        "select": { call, document, context in await select(call, document, context) },
        "selectionModify": { call, document, context in await selectionModify(call, document, context) },
        "selectionApply": { call, document, context in await selectionApply(call, document, context) },
    ]

    public static func run(_ call: OperationCall, on document: PhotoDocument, context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        // A gesture-only control the grammar heard (W2): its tool opens on it.
        if let control = call.args["openTool"]?.string { return openTool(control, document, context) }
        if let handler = table[call.id] { return await handler(call, document, context) }
        let title = OperationCatalog.shared.spec(call.id)?.title.en ?? call.id.raw
        // In French the English operation name never goes inside « ».
        let message = context.language == .french ? "Ça, je ne peux pas le faire sur une photo." : PicshopError.unsupportedOperation(title).message(french: false)
        return (document, ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.unsupported.effect]))
    }

    /// The history label of a call: the catalog's English title (like the other edits' labels).
    static func label(_ call: OperationCall) -> String {
        OperationCatalog.shared.spec(call.id)?.title.en ?? call.id.raw
    }

    static func unavailable(_ message: String, _ document: PhotoDocument, reason: ExecutionReason = .unsupported) -> (PhotoDocument, ExecutionResult) {
        (document, ExecutionResult(outcome: .failed(message: message), effects: [reason.effect]))
    }

    // MARK: Tone

    /// curves: a preset shape at a strength, or the given points, on one channel; the other channels kept.
    static func curves(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let layerID = document.activeImageLayerID, let edits = document.layer(id: layerID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        let channel = call.args["channel"]?.string.flatMap(ToneCurve.Channel.init(rawValue:)) ?? .rgb
        let strength = ((call.args["amount"]?.double ?? 50) / 100).clamped(to: 0...1)
        let points: [ToneCurve.Point]
        if let given = call.args["points"].flatMap(pointList), given.count >= 2 {
            points = given
        } else if let preset = call.args["preset"]?.string, let shaped = presetPoints(preset, strength: strength) {
            points = shaped
        } else {
            return unavailable(context.french ? "Quelle courbe ? Un préréglage (courbe en S, mate…) ou des points." : "Which curve? A preset (S curve, matte…) or points.", document)
        }
        var curve = userToneCurve(edits)
        curve.setPoints(points, for: channel)
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setTone(.toneCurve(curve)) }
        return (updated, .applied(label(call)))
    }

    /// The curve the person set (the last `.toneCurve`), never the look's built-in curve.
    static func userToneCurve(_ edits: EditStack) -> ToneCurve {
        for operation in edits.operations.reversed() {
            if case .toneCurve(let curve) = operation.kind { return curve }
        }
        return .identity
    }

    /// The control points of a preset (0…1), at a strength 0…1. `invert` is always full.
    static func presetPoints(_ preset: String, strength s: Double) -> [ToneCurve.Point]? {
        typealias P = ToneCurve.Point
        switch preset {
        case "sCurve": return [P(0, 0), P(0.25, 0.25 - 0.12 * s), P(0.5, 0.5), P(0.75, 0.75 + 0.12 * s), P(1, 1)]
        case "strongS": return [P(0, 0), P(0.25, 0.25 - 0.22 * s), P(0.5, 0.5), P(0.75, 0.75 + 0.22 * s), P(1, 1)]
        case "matte":
            let lift = 0.2 * s
            return [P(0, lift), P(0.25, 0.25 + lift * 0.6), P(0.5, 0.5 + lift * 0.3), P(0.75, 0.75), P(1, 1)]
        case "fade":
            let lift = 0.18 * s
            return [P(0, lift), P(0.5, 0.5 + lift * 0.2), P(1, 1 - lift * 0.6)]
        case "invert": return [P(0, 1), P(1, 0)]
        case "brighten": return [P(0, 0), P(0.5, 0.5 + 0.2 * s), P(1, 1)]
        case "darken": return [P(0, 0), P(0.5, 0.5 - 0.2 * s), P(1, 1)]
        case "linear": return ToneCurve.linear
        default: return nil
        }
    }

    /// Points in the model's 0…1000 space → curve points 0…1, sorted, one per input, endpoints added, at most 16.
    static func pointList(_ value: OpValue) -> [ToneCurve.Point]? {
        guard case .list(let items) = value else { return nil }
        var points: [ToneCurve.Point] = []
        for item in items {
            switch item {
            case .point(let point): points.append(ToneCurve.Point(point.x / 1000, point.y / 1000))
            case .list(let pair) where pair.count == 2:
                guard let x = pair[0].double, let y = pair[1].double else { return nil }
                points.append(ToneCurve.Point(x / 1000, y / 1000))
            default: return nil
            }
        }
        var byInput: [Double: Double] = [:]
        for point in points { byInput[point.input.clamped(to: 0...1)] = point.output.clamped(to: 0...1) }
        if byInput[0] == nil { byInput[0] = 0 }
        if byInput[1] == nil { byInput[1] = 1 }
        let sorted = byInput.keys.sorted().map { ToneCurve.Point($0, byInput[$0] ?? $0) }
        guard sorted.count <= ToneCurve.maxPoints else { return nil }
        return sorted
    }

    /// levels: the given handles (0…255, gamma) merged into the channel; `auto` takes autoTone's path.
    static func levels(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if call.args["auto"]?.bool == true { return await autoTone(OperationCall("autoTone", args: ["amount": .number(100)], source: call.source), document, context, label: label(call)) }
        guard let layerID = document.activeImageLayerID, let edits = document.layer(id: layerID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        let channel = call.args["channel"]?.string.flatMap(ToneCurve.Channel.init(rawValue:)) ?? .rgb
        var levels = edits.resolvedLevels
        var handles = levels[channel]
        if let value = call.args["black"]?.double { handles.inBlack = (value / 255).clamped(to: 0...1) }
        if let value = call.args["white"]?.double { handles.inWhite = (value / 255).clamped(to: 0...1) }
        if let value = call.args["gamma"]?.double { handles.gamma = value.clamped(to: 0.1...9.99) }
        if let value = call.args["outBlack"]?.double { handles.outBlack = (value / 255).clamped(to: 0...1) }
        if let value = call.args["outWhite"]?.double { handles.outWhite = (value / 255).clamped(to: 0...1) }
        guard handles.inWhite - handles.inBlack >= 2.0 / 255 else {
            return unavailable(context.french ? "Le point blanc doit rester au-dessus du point noir." : "The white point must stay above the black point.", document)
        }
        guard handles != levels[channel] else {
            return (document, ExecutionResult(outcome: .info(message: context.french ? "Les niveaux sont déjà réglés ainsi." : "The levels are already set that way.")))
        }
        levels[channel] = handles
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setTone(.levels(levels)) }
        return (updated, .applied(label(call)))
    }

    /// autoTone: levels from the rendered histogram (0.1 % clipped), blended toward identity by amount.
    static func autoTone(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext, label override: String? = nil) async -> (PhotoDocument, ExecutionResult) {
        guard let layerID = document.activeImageLayerID else { return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document) }
        guard let histogram = await context.services.histogram(of: document) else {
            return unavailable(context.french ? "Je ne peux pas lire l'histogramme de la photo pour l'instant. Essaie l'outil Niveaux."
                                              : "I can't read the photo's histogram right now. Try the Levels tool.", document)
        }
        let strength = ((call.args["amount"]?.double ?? 100) / 100).clamped(to: 0...1)
        let automatic = blend(.identity, Levels.auto(from: histogram, clip: 0.001), strength)
        guard !automatic.isIdentity else {
            return (document, ExecutionResult(outcome: .info(message: context.french ? "La photo utilise déjà toute la plage de tons." : "The photo already uses the whole tonal range.")))
        }
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setTone(.levels(automatic)) }
        return (updated, .applied(override ?? label(call)))
    }

    static func blend(_ a: Levels, _ b: Levels, _ t: Double) -> Levels {
        func mix(_ x: Levels.Channel, _ y: Levels.Channel) -> Levels.Channel {
            Levels.Channel(inBlack: x.inBlack + (y.inBlack - x.inBlack) * t, inWhite: x.inWhite + (y.inWhite - x.inWhite) * t,
                           gamma: x.gamma + (y.gamma - x.gamma) * t, outBlack: x.outBlack + (y.outBlack - x.outBlack) * t,
                           outWhite: x.outWhite + (y.outWhite - x.outWhite) * t)
        }
        return Levels(rgb: mix(a.rgb, b.rgb), red: mix(a.red, b.red), green: mix(a.green, b.green), blue: mix(a.blue, b.blue))
    }

    // MARK: Colour

    /// hsl: one band's hue, saturation and luminance (−100…100), added (relative) or set (absolute).
    static func hsl(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let layerID = document.activeImageLayerID, let edits = document.layer(id: layerID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        guard let name = call.args["band"]?.string,
              let band = ColorMixer.Band.allCases.first(where: { $0.englishName.lowercased() == name.lowercased() }) ?? ColorMixer.Band.matching(name) else {
            return unavailable(context.french ? "Quelle couleur ? Rouges, oranges, jaunes, verts, cyans, bleus, violets ou magentas." : "Which colour band?", document)
        }
        let absolute = call.args["amountMode"]?.string == "absolute"
        var mixer = lastMixer(edits)
        var changed = false
        for (key, channel) in [("hue", ColorMixer.Channel.hue), ("saturation", .saturation), ("luminance", .luminance)] {
            guard let value = call.args[key]?.double else { continue }
            let delta = (value / 100).clamped(to: -1...1)
            mixer[band, channel] = absolute ? delta : mixer[band, channel] + delta
            changed = true
        }
        guard changed else { return unavailable(context.french ? "Teinte, saturation ou luminance ?" : "Hue, saturation or luminance?", document) }
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setColor(.colorMixer(mixer)) }
        return (updated, .applied(label(call)))
    }

    static func lastMixer(_ edits: EditStack) -> ColorMixer {
        for operation in edits.operations.reversed() {
            if case .colorMixer(let mixer) = operation.kind { return mixer }
        }
        return .neutral
    }

    static func lastGrade(_ edits: EditStack) -> ColorGrade {
        for operation in edits.operations.reversed() {
            if case .colorGrade(let grade) = operation.kind { return grade }
        }
        return .neutral
    }

    /// colorGrade: one range's wheel (a colour name or a hue), its strength, its luminance, and the balance.
    static func colorGrade(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let layerID = document.activeImageLayerID, let edits = document.layer(id: layerID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        guard let range = call.args["range"]?.string.flatMap(ColorGrade.Range.init(rawValue:)) else {
            return unavailable(context.french ? "Les ombres, les tons moyens ou les hautes lumières ?" : "Shadows, midtones or highlights?", document)
        }
        var grade = lastGrade(edits)
        var wheel = grade[range]
        var hue = wheel.hue
        if let degrees = call.args["hue"]?.double {
            hue = degrees
        } else if let name = call.args["color"]?.string {
            guard let color = PSColor.named(name) ?? PSColor(hex: name) else {
                return unavailable(context.french ? "Je ne connais pas cette couleur." : "I don't know that colour.", document)
            }
            hue = ColorEngine.hsl(fromRGB: (color.red, color.green, color.blue)).0
        }
        let amount = call.args["amount"]?.double.map { ($0 / 100).clamped(to: 0...1) } ?? (wheel.amount > 0 ? wheel.amount : 0.3)
        let luminance = call.args["luminance"]?.double.map { ($0 / 100).clamped(to: -1...1) } ?? wheel.luminance
        wheel = ColorWheel(hue: hue, amount: amount, luminance: luminance)
        grade[range] = wheel
        if let balance = call.args["balance"]?.double { grade.balance = (balance / 100).clamped(to: -1...1) }
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setColor(.colorGrade(grade)) }
        return (updated, .applied(label(call)))
    }

    /// lutIntensity / removeLUT: the imported LUT's strength (0 takes it off). Needs an imported LUT.
    static func lut(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext, remove: Bool) -> (PhotoDocument, ExecutionResult) {
        guard let layerID = document.activeImageLayerID, let edits = document.layer(id: layerID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        guard let reference = lastLUT(edits) else {
            return unavailable(context.french ? "Il n'y a pas de LUT sur la photo : importe-en un dans Couleur › LUT." : "There is no LUT on the photo: import one in Color › LUT.", document)
        }
        let intensity = remove ? 0 : ((call.args["amount"]?.double ?? 100) / 100).clamped(to: 0...1)
        guard abs(intensity - reference.intensity) > 0.001 else {
            let message = remove ? (context.french ? "Le LUT est déjà retiré." : "The LUT is already off.")
                : (context.french ? "Le LUT est déjà à cette intensité." : "The LUT is already at that intensity.")
            return (document, ExecutionResult(outcome: .info(message: message)))
        }
        var updated = document
        updated.update(layerID: layerID) { $0.edits.setColor(.lut(LUTReference(relativePath: reference.relativePath, title: reference.title, intensity: intensity))) }
        return (updated, .applied(label(call)))
    }

    /// The last LUT put on the layer, at any intensity (one taken off can come back).
    static func lastLUT(_ edits: EditStack) -> LUTReference? {
        for operation in edits.operations.reversed() {
            if case .lut(let reference) = operation.kind { return reference }
        }
        return nil
    }

    // MARK: Geometry and optics

    /// perspective: keystone correction, −100…100 per axis → the crop panel's −1…1. A correction right
    /// after another replaces it (one undo step, as the sliders do).
    static func perspective(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let baseID = document.baseLayerID, let edits = document.layer(id: baseID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        let horizontal = call.args["horizontal"]?.double.map { ($0 / 100).clamped(to: -1...1) }
        let vertical = call.args["vertical"]?.double.map { ($0 / 100).clamped(to: -1...1) }
        guard horizontal != nil || vertical != nil else {
            return unavailable(context.french ? "Horizontale ou verticale ?" : "Horizontal or vertical?", document)
        }
        var updated = document
        if let last = edits.operations.last, case .perspective(let h, let v) = last.kind {
            updated.update(layerID: baseID) { layer in
                layer.edits.operations[layer.edits.operations.count - 1] = EditOperation(id: last.id, kind: .perspective(horizontal: horizontal ?? h, vertical: vertical ?? v), createdAt: last.createdAt)
            }
            // The in-place replacement bypasses `apply`: masks and the selection follow the new geometry here (D3).
            updated.reconcileMasks(previousBaseEdits: edits)
        } else {
            updated.apply(.perspective(horizontal: horizontal ?? 0, vertical: vertical ?? 0), to: baseID)
        }
        return (updated, .applied(label(call)))
    }

    /// lensFocus: sharp at a point (0…1000) or on a scene object's centre, lens blur elsewhere. The depth
    /// map sets near and far when the source has one; the subject outline otherwise (as a focus tap).
    static func lensFocus(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard let baseID = document.baseLayerID, let edits = document.layer(id: baseID)?.edits else {
            return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document)
        }
        var focus: PSPoint?
        if let point = call.args["point"].flatMap(normalizedPoint) {
            focus = point
        } else if let raw = call.args["ref"]?.string, let ref = SceneRef(raw) {
            var scene = context.intent.scene
            if scene?.box(ref) == nil { scene = (try? await context.services.sceneMap(in: document)) ?? nil }
            guard let box = scene?.box(ref) else {
                return unavailable(context.french ? "Je ne trouve pas \(raw) sur la photo." : "\(raw) is not on the picture.", document, reason: .unknownRef)
            }
            focus = box.center
        }
        guard let focus else {
            return unavailable(context.french ? "Où faire la mise au point ? Touche la photo ou nomme le sujet." : "Where should the focus be? Tap the photo or name the subject.", document, reason: .needsSelection)
        }
        let previous = edits.operations.reversed().compactMap { operation -> (PSPoint, Double, MaskReference?)? in
            if case .lensBlur(let point, let aperture, let mask) = operation.kind { return (point, aperture, mask) }
            return nil
        }.first
        let aperture = ((call.args["aperture"]?.double ?? (previous.map { $0.1 * 100 } ?? 60)) / 100).clamped(to: 0...1)
        var mask = previous?.2
        if previous == nil || edits.hasGeometry, mask == nil {
            mask = try? await context.services.subjectMask(in: document)
        }
        var updated = document
        updated.update(layerID: baseID) { $0.edits.setColor(.lensBlur(focus: focus, aperture: aperture, mask: mask)) }
        return (updated, .applied(label(call)))
    }

    /// [x, y] in 0…1000 → 0…1.
    static func normalizedPoint(_ value: OpValue) -> PSPoint? {
        switch value {
        case .point(let point): return PSPoint(x: (point.x / 1000).clamped(to: 0...1), y: (point.y / 1000).clamped(to: 0...1))
        case .list(let pair) where pair.count == 2:
            guard let x = pair[0].double, let y = pair[1].double else { return nil }
            return PSPoint(x: (x / 1000).clamped(to: 0...1), y: (y / 1000).clamped(to: 0...1))
        default: return nil
        }
    }

    // MARK: Layers

    /// The layer a call names: "l2" (a text layer, as the scene lines number them), "s1" (a shape),
    /// "i1" (an image layer above the photo); no ref, the selected layer, or the only one there is.
    static func layer(for call: OperationCall, in document: PhotoDocument, context: OperationRunContext) -> Layer? {
        layer(ref: call.args["ref"]?.string, in: document, scene: context.intent.scene)
    }

    static func layer(ref: String?, in document: PhotoDocument, scene: SceneMap?) -> Layer? {
        guard let raw = ref?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            if let selected = document.selectedLayer, selected.id != document.baseLayerID { return selected }
            let others = document.layers.filter { $0.id != document.baseLayerID }
            return others.count == 1 ? others[0] : nil
        }
        guard let kind = raw.first, let number = Int(raw.dropFirst()), number >= 1 else { return nil }
        switch kind {
        case "l":
            if let id = scene?.block(.layer(number))?.layerID, let layer = document.layer(id: id) { return layer }
            let free = document.layers.filter { $0.group == nil && $0.textElement != nil }
            let shown = free.filter(\.isVisible)
            if number <= shown.count { return shown[number - 1] }
            return number <= free.count ? free[number - 1] : nil
        case "s":
            let shapes = document.layers.filter(\.isShape)
            return number <= shapes.count ? shapes[number - 1] : nil
        case "i":
            let images = document.layers.filter { $0.isImage && $0.id != document.baseLayerID }
            return number <= images.count ? images[number - 1] : nil
        default:
            return nil
        }
    }

    static func noLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let raw = call.args["ref"]?.string {
            return unavailable(context.french ? "Il n'y a pas de calque \(raw)." : "There is no layer \(raw).", document, reason: .unknownRef)
        }
        if document.layers.count <= 1 {
            return unavailable(context.french ? "La photo n'a pas d'autre calque : ajoute un texte, une forme ou une image d'abord."
                                              : "The photo has no other layer: add a text, a shape or a picture first.", document, reason: .nothingToDo)
        }
        // The base photo is not a layer these settings change: say which one.
        return unavailable(context.french ? "Quel calque ? Le fond ne change pas : sélectionne un calque ou nomme-le (l1, s1…)."
                                          : "Which layer? The base photo doesn't change: select a layer or name it (l1, s1…).", document, reason: .needsSelection)
    }

    /// layerOpacity, layerBlend, layerVisibility: one field of the layer.
    static func layerProperty(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let layer = layer(for: call, in: document, context: context), layer.id != document.baseLayerID else { return noLayer(call, document, context) }
        var updated = document
        switch call.id.raw {
        case "layerOpacity":
            guard let value = call.args["opacity"]?.double else { return unavailable(context.french ? "Quelle opacité ?" : "What opacity?", document) }
            updated.update(layerID: layer.id) { $0.opacity = (value / 100).clamped(to: 0...1) }
        case "layerBlend":
            guard let mode = call.args["mode"]?.string.flatMap(BlendMode.init(rawValue:)) else {
                return unavailable(context.french ? "Quel mode de fusion ?" : "Which blend mode?", document)
            }
            updated.update(layerID: layer.id) { $0.blendMode = mode }
        case "layerVisibility":
            guard let visible = call.args["visible"]?.bool else { return unavailable(context.french ? "Afficher ou masquer ?" : "Show or hide?", document) }
            updated.update(layerID: layer.id) { $0.isVisible = visible }
        default:
            return run(call, on: document, context: context, fallback: true)
        }
        guard updated.layers != document.layers else {
            return (document, ExecutionResult(outcome: .info(message: context.french ? "Le calque est déjà ainsi." : "The layer is already like that.")))
        }
        return (updated, .applied(label(call)))
    }

    /// layerOrder: front, back (just above the photo), forward, backward.
    static func layerOrder(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard let layer = layer(for: call, in: document, context: context), layer.id != document.baseLayerID,
              let index = document.index(of: layer.id) else { return noLayer(call, document, context) }
        let floor = (document.baseLayerID.flatMap { document.index(of: $0) } ?? -1) + 1
        let last = document.layers.count - 1
        let target: Int
        switch call.args["position"]?.string {
        case "front": target = last
        case "back": target = floor
        case "forward": target = min(last, index + 1)
        case "backward": target = max(floor, index - 1)
        default: return unavailable(context.french ? "Devant ou derrière ?" : "Forward or back?", document)
        }
        guard target != index else {
            let message = target == last ? (context.french ? "Le calque est déjà au premier plan." : "The layer is already in front.")
                : (context.french ? "Le calque est déjà tout derrière." : "The layer is already at the back.")
            return (document, ExecutionResult(outcome: .info(message: message)))
        }
        var updated = document
        updated.moveLayer(id: layer.id, to: target)
        return (updated, .applied(label(call)))
    }

    /// An id the table does not hold, reached from a handler that serves several ids.
    private static func run(_ call: OperationCall, on document: PhotoDocument, context: OperationRunContext, fallback: Bool) -> (PhotoDocument, ExecutionResult) {
        let message = context.french ? "Ça, je ne peux pas le faire sur une photo." : PicshopError.unsupportedOperation(label(call)).message(french: false)
        return (document, ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.unsupported.effect]))
    }
}
