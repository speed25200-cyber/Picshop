#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import CoreImage
import Observation
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopSpeech

/// State and behaviour of the photo editor screen. Owns the undo history,
/// renders previews, and runs the voice pipeline:
/// transcript → `HybridIntentRouter` → `PhotoCommandExecutor` → history → render.
@MainActor
@Observable
public final class PhotoEditorSession {
    public enum Tool: String, CaseIterable, Identifiable {
        case adjust, looks, erase, precise, cutout, crop, text, shapes, layers
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .adjust: return L("Adjust")
            case .looks: return L("Looks")
            case .erase: return L("Erase")
            case .precise: return L("Precise")
            case .cutout: return L("Cutout")
            case .crop: return L("Crop")
            case .text: return L("Text")
            case .shapes: return L("Shapes")
            case .layers: return L("Layers")
            }
        }
        var symbol: String {
            switch self {
            case .adjust: return "slider.horizontal.3"
            case .looks: return "camera.filters"
            case .erase: return "eraser.line.dashed"
            case .precise: return "scope"
            case .cutout: return "person.crop.rectangle"
            case .crop: return "crop.rotate"
            case .text: return "textformat"
            case .shapes: return "square.on.circle"
            case .layers: return "square.3.layers.3d"
            }
        }
    }

    /// Sub-modes of the pixel-precise tool.
    public enum PreciseMode: String, CaseIterable, Identifiable {
        case wand, lasso, generate, pixelBrush, clone
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .wand: return L("Magic wand")
            case .lasso: return L("Lasso")
            case .generate: return L("Generate")
            case .pixelBrush: return L("Pixel brush")
            case .clone: return L("Clone")
            }
        }
        var symbol: String {
            switch self {
            case .wand: return "wand.and.rays"
            case .lasso: return "lasso"
            case .generate: return "sparkles"
            case .pixelBrush: return "paintbrush.pointed"
            case .clone: return "doc.on.doc"
            }
        }
    }

    public struct Toast: Equatable {
        var text: String
        var isError: Bool
        var id = UUID()
    }

    public let projectID: UUID
    public let app: AppEnvironment
    public private(set) var history: EditHistory<PhotoDocument>
    public var document: PhotoDocument { history.present }

    public private(set) var renderer: PhotoRenderer?
    private var services: VisionPhotoServices?
    private var executor: PhotoCommandExecutor?

    public private(set) var preview: CIImage?
    public private(set) var isRendering = false
    public var showsOriginal = false { didSet { requestPreview() } }
    public var activeTool: Tool? { didSet { toolDidChange(from: oldValue) } }
    // Crop tool state (normalised over the straightened preview).
    public var cropRect: PSRect?
    public var cropAspect: AspectPreset = .free
    public var straightenPreview: Double = 0 { didSet { if straightenPreview != oldValue { requestPreview(interactive: true) } } }
    /// Perspective correction previewed live in the crop tool (-1…1 each).
    public var perspectiveHorizontal: Double = 0 { didSet { if perspectiveHorizontal != oldValue { requestPreview(interactive: true) } } }
    public var perspectiveVertical: Double = 0 { didSet { if perspectiveVertical != oldValue { requestPreview(interactive: true) } } }
    /// Whether the crop tool has any pending geometry change.
    public var hasPendingGeometry: Bool { cropRect != .unit || straightenPreview != 0 || perspectiveHorizontal != 0 || perspectiveVertical != 0 }
    /// Brush circle shown at the canvas centre while the size dial is dragged.
    public var showsBrushPreview = false
    /// Text or shape layer being dragged / pinched on the canvas.
    public var manipulatedTextLayerID: UUID?
    /// Shape kind added by the next tap on the canvas, when the Shapes tool is open.
    public var shapeKindToAdd: ShapeElement.Kind = .rectangle
    public var selectedParameter: AdjustmentParameter = .exposure
    public var brushRadius: Double = 0.03
    public var brushStrokes: [BrushStroke] = []
    // Precise tool state.
    public var preciseMode: PreciseMode = .wand
    public var wandTolerance: Double = 0.25
    public var wandContiguous = true
    public var lassoPoints: [PSPoint] = []
    /// Current selection made with the wand or lasso, ready for erase/generate/recolor.
    public var selectionMask: MaskReference?
    public var selectionPreview: CIImage?
    public var paintColor: PSColor = .white
    public var pixelBrushRadius: Double = 0.004
    /// Clone source (normalised) and the offset between source and destination.
    public var cloneSource: PSPoint?
    public var cloneOffset: PSPoint?
    public var generativePrompt = ""
    public var hasGenerativeEngine = false
    public var lastTapPoint: PSPoint?
    public var isProcessing = false
    public var processingTitle = ""
    public var toast: Toast?
    public var transcript = ""
    public var lastPlan: EditPlan?
    public var pendingClarification: ClarificationRequest?
    public var candidateOverlays: [ObjectCandidate] = []
    public var showsExport = false
    public var exportedURL: URL?
    public var exportProgress: Double?
    public var showsHelp = false
    public var isVoiceReady = false

    private var renderTask: Task<Void, Never>?
    private var interactiveRendering = false
    private var toastTask: Task<Void, Never>?
    private var isConfigured = false

    public init(document: PhotoDocument, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: document)
    }

    // MARK: - Lifecycle

    public func configure() async {
        guard !isConfigured else { return }
        isConfigured = true
        let pipeline = await app.makeInpaintingPipeline()
        let upscaler = await app.makeUpscaler()
        let renderer = PhotoRenderer(store: app.store, projectID: projectID, inpainting: pipeline, upscaler: upscaler)
        self.renderer = renderer
        let services = VisionPhotoServices(renderer: renderer, store: app.store, projectID: projectID)
        self.services = services
        executor = PhotoCommandExecutor(services: services, language: language)
        hasGenerativeEngine = pipeline.hasGenerativeEngine
        app.voice.onFinalTranscript = { [weak self] text in
            Task { await self?.handleTranscript(text) }
        }
        isVoiceReady = true
        requestPreview()
    }

    public func teardown() {
        app.voice.cancel()
        app.voice.onFinalTranscript = nil
        renderTask?.cancel()
        save()
    }

    public func save() {
        let project = Project(id: projectID, content: .photo(document), createdAt: document.createdAt, modifiedAt: Date())
        app.library.save(project)
        if let renderer {
            let store = app.store
            let document = self.document
            Task.detached(priority: .utility) {
                await ThumbnailGenerator.writeThumbnail(for: document, renderer: renderer, store: store)
            }
        }
    }

    var language: NormalizedUtterance.Language {
        if let hint = app.settings.languageHint { return hint == "fr" ? .french : .english }
        return Locale.current.language.languageCode?.identifier == "fr" ? .french : .english
    }

    var intentContext: IntentContext {
        IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, hasSelection: document.selectedLayer?.isText == true,
                      selectedIndex: document.selectedLayerID.flatMap { document.index(of: $0) }, clipCount: 0, textLayerCount: document.textLayers.count,
                      pendingClarification: pendingClarification, lastTapPoint: lastTapPoint, canUndo: history.canUndo, canRedo: history.canRedo,
                      preferredLanguage: app.settings.languageHint)
    }

    // MARK: - Rendering

    public func requestPreview(interactive: Bool = false) {
        guard let renderer else { return }
        renderTask?.cancel()
        var document = self.document
        if straightenPreview != 0 { document.apply(.straighten(degrees: straightenPreview)) }
        if perspectiveHorizontal != 0 || perspectiveVertical != 0 { document.apply(.perspective(horizontal: perspectiveHorizontal, vertical: perspectiveVertical)) }
        let showsOriginal = self.showsOriginal
        let side: Double = interactive ? 1280 : 2048
        interactiveRendering = interactive
        renderTask = Task { [weak self] in
            self?.isRendering = true
            defer { self?.isRendering = false }
            do {
                let image = try await renderer.render(document, options: PhotoRenderer.Options(targetLongestSide: side, showOriginal: showsOriginal, allowExpensiveWork: true))
                guard !Task.isCancelled else { return }
                self?.preview = image
                if interactive {
                    // Follow up with a sharper frame once the interaction settles.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.requestPreview(interactive: false)
                }
            } catch {
                PSLog.error("preview failed: \(error)", category: .ui)
            }
        }
    }

    // MARK: - History

    private func commit(_ newDocument: PhotoDocument, label: String) {
        var updated = newDocument
        updated.touch()
        history.commit(updated, label: label)
        requestPreview()
    }

    public func undo() {
        guard history.canUndo else { return }
        let label = history.undo()
        Haptics.tick()
        showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo"))
        requestPreview()
    }

    public func redo() {
        guard history.canRedo else { return }
        let label = history.redo()
        Haptics.tick()
        showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo"))
        requestPreview()
    }

    public func revert() {
        history.revertToOriginal()
        Haptics.confirm()
        requestPreview()
    }

    // MARK: - Direct (touch) edits

    public func beginSliderInteraction(_ parameter: AdjustmentParameter) {
        history.beginTransaction(label: parameter.englishName)
    }

    public func endSliderInteraction() {
        history.endTransaction()
        requestPreview()
    }

    public func setAdjustment(_ parameter: AdjustmentParameter, value: Double) {
        var document = self.document
        guard let layerID = document.activeImageLayerID else { return }
        document.update(layerID: layerID) { $0.edits.setAdjustment(parameter, value: value) }
        history.commit(document, label: parameter.englishName)
        requestPreview(interactive: true)
    }

    public func adjustmentValue(_ parameter: AdjustmentParameter) -> Double {
        document.activeAdjustments[parameter]
    }

    public func apply(_ kind: EditOperation.Kind, label: String? = nil) {
        var document = self.document
        document.apply(kind, label: label)
        commit(document, label: label ?? kind.defaultLabel)
        Haptics.tick()
    }

    public func applyLook(_ preset: FilterPreset, intensity: Double = 1) {
        apply(.look(preset, intensity: intensity), label: preset.englishName)
    }

    public func setLookIntensity(_ intensity: Double) {
        guard let look = document.baseLayer?.edits.resolvedLook else { return }
        var document = self.document
        guard let layerID = document.activeImageLayerID else { return }
        document.update(layerID: layerID) { layer in
            if let last = layer.edits.operations.last, case .look = last.kind {
                layer.edits.operations[layer.edits.operations.count - 1] = EditOperation(id: last.id, kind: .look(look.preset, intensity: intensity), createdAt: last.createdAt, label: last.label)
            } else {
                layer.edits.append(.look(look.preset, intensity: intensity))
            }
        }
        history.commit(document, label: "Look Intensity")
        requestPreview(interactive: true)
    }

    // MARK: - Tool lifecycle

    private func toolDidChange(from previous: Tool?) {
        guard previous != activeTool else { return }
        if previous == .erase { commitBrushErase() }
        if previous == .precise { brushStrokes = []; lassoPoints = [] }
        if previous == .crop, activeTool != .crop { cancelCrop() }
        if activeTool == .crop { beginCrop() }
        manipulatedTextLayerID = nil
        if activeTool == .text, document.selectedLayer?.isText != true, let last = document.textLayers.last {
            selectLayer(last.id)
        }
        if activeTool == .shapes, document.selectedLayer?.isShape != true, let last = document.shapeLayers.last {
            selectLayer(last.id)
        }
    }

    // MARK: - Crop & straighten

    /// Aspect ratio (w/h) of what is currently on screen.
    public var previewAspectRatio: Double {
        if let preview, preview.extent.height > 0 { return Double(preview.extent.width / preview.extent.height) }
        return document.aspectRatio
    }

    public var isCropping: Bool { cropRect != nil }

    public func beginCrop() {
        cropAspect = .free
        cropRect = .unit
        straightenPreview = 0
        perspectiveHorizontal = 0
        perspectiveVertical = 0
    }

    public func cancelCrop() {
        cropRect = nil
        cropAspect = .free
        straightenPreview = 0
        perspectiveHorizontal = 0
        perspectiveVertical = 0
    }

    /// Largest centred rectangle with the preset's ratio, in normalised coordinates.
    public func setCropAspect(_ preset: AspectPreset) {
        cropAspect = preset
        guard preset != .free else { return }
        let image = previewAspectRatio
        let target = preset == .original ? (document.baseLayer?.imageAsset?.pixelSize.aspectRatio ?? image) : (preset.value ?? image)
        var width = 1.0, height = 1.0
        if target >= image { height = image / target } else { width = target / image }
        cropRect = PSRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        Haptics.tick()
    }

    /// Commits the straighten angle and the crop rectangle as edits.
    public func commitCrop() {
        guard let rect = cropRect else { return }
        var document = self.document
        var labels: [String] = []
        if abs(straightenPreview) > 0.01 {
            document.apply(.straighten(degrees: straightenPreview))
            labels.append(L("Straighten"))
        }
        if abs(perspectiveHorizontal) > 0.005 || abs(perspectiveVertical) > 0.005 {
            document.apply(.perspective(horizontal: perspectiveHorizontal, vertical: perspectiveVertical))
            labels.append(L("Perspective"))
        }
        let clamped = rect.clampedToUnit()
        if clamped.width < 0.999 || clamped.height < 0.999 || clamped.minX > 0.001 || clamped.minY > 0.001 {
            document.apply(.crop(clamped))
            labels.append(L("Crop"))
        }
        straightenPreview = 0
        perspectiveHorizontal = 0
        perspectiveVertical = 0
        cropRect = nil
        cropAspect = .free
        guard !labels.isEmpty else { requestPreview(); return }
        commit(document, label: labels.joined(separator: " · "))
        Haptics.success()
        activeTool = nil
    }

    /// Quarter-turn and flips apply immediately and reset the crop frame.
    public func rotateQuarterTurn() {
        apply(.rotate(degrees: 90), label: L("Rotate"))
        if isCropping { cropRect = .unit; cropAspect = .free }
    }

    public func flipHorizontally() {
        apply(.flip(.horizontal), label: L("Flip"))
    }

    public func autoLevel() {
        Task { await run(EditIntent(action: .straighten)) }
        if isCropping { cropRect = .unit }
    }

    // MARK: - Text manipulation on the canvas

    /// Normalised bounds of a text layer as rendered.
    public func textBounds(for layer: Layer) -> PSRect? {
        guard let element = layer.textElement else { return nil }
        let canvas = CGSize(width: document.canvasSize.width, height: document.canvasSize.height)
        guard canvas.width > 0, canvas.height > 0, let size = TextRasterizer.boundingSize(for: element, canvasSize: canvas) else { return nil }
        let width = Double(size.width / canvas.width), height = Double(size.height / canvas.height)
        return PSRect(x: element.center.x - width / 2, y: element.center.y - height / 2, width: width, height: height)
    }

    /// Topmost text layer under a point (with a small touch slop).
    public func textLayer(at point: PSPoint) -> Layer? {
        for layer in document.layers.reversed() where layer.isText && layer.isVisible {
            if let bounds = textBounds(for: layer), bounds.insetBy(dx: -0.02, dy: -0.02).contains(point) { return layer }
        }
        return nil
    }

    /// Normalised, unrotated bounds of a shape layer as rendered.
    public func shapeBounds(for layer: Layer) -> PSRect? {
        guard let shape = layer.shapeElement else { return nil }
        let width = shape.relativeSize.width * layer.transform.scale
        let height = shape.relativeSize.height * layer.transform.scale
        return PSRect(x: layer.transform.center.x - width / 2, y: layer.transform.center.y - height / 2, width: width, height: height)
    }

    /// Topmost shape layer under a point.
    public func shapeLayer(at point: PSPoint) -> Layer? {
        for layer in document.layers.reversed() where layer.isShape && layer.isVisible {
            if let bounds = shapeBounds(for: layer), bounds.insetBy(dx: -0.02, dy: -0.02).contains(point) { return layer }
        }
        return nil
    }

    /// Whether the active tool moves overlays (text or shapes) with canvas gestures.
    public var manipulatesOverlays: Bool { activeTool == .text || activeTool == .shapes }

    /// Text or shape layer under a point, depending on the active tool.
    public func overlayLayer(at point: PSPoint) -> Layer? {
        switch activeTool {
        case .text: return textLayer(at: point)
        case .shapes: return shapeLayer(at: point)
        default: return nil
        }
    }

    /// Bounds of an overlay layer (text or shape) for selection handles and hit testing.
    public func overlayBounds(for layer: Layer) -> PSRect? {
        layer.isText ? textBounds(for: layer) : shapeBounds(for: layer)
    }

    /// Centre, size and rotation of an overlay layer, in a tool-agnostic form.
    public func overlayGeometry(for layer: Layer) -> (center: PSPoint, size: Double, rotation: Double)? {
        if let element = layer.textElement { return (element.center, element.relativeSize, element.rotation) }
        if layer.isShape { return (layer.transform.center, layer.transform.scale, layer.transform.rotation) }
        return nil
    }

    /// Selected overlay of the active tool, if any.
    public var selectedOverlayLayerID: UUID? {
        guard let layer = document.selectedLayer else { return nil }
        switch activeTool {
        case .text: return layer.isText ? layer.id : nil
        case .shapes: return layer.isShape ? layer.id : nil
        default: return nil
        }
    }

    public func beginTextInteraction(_ layerID: UUID) {
        manipulatedTextLayerID = layerID
        if document.selectedLayerID != layerID { selectLayer(layerID) }
        history.beginTransaction(label: document.layers.first(where: { $0.id == layerID })?.isShape == true ? "Move Shape" : "Move Text")
    }

    /// Moves, scales (relative factor) or rotates the manipulated text or shape layer.
    public func updateManipulatedText(center: PSPoint? = nil, scale: Double? = nil, rotation: Double? = nil) {
        guard let id = manipulatedTextLayerID else { return }
        if document.layers.first(where: { $0.id == id })?.isShape == true {
            updateLayer(id) { layer in
                if let center { layer.transform.center = PSPoint(x: center.x.clamped(to: 0...1), y: center.y.clamped(to: 0...1)) }
                if let scale { layer.transform.scale = (layer.transform.scale * scale).clamped(to: 0.05...4) }
                if let rotation { layer.transform.rotation = rotation }
            }
            return
        }
        updateText(layerID: id) { element in
            if let center { element.center = PSPoint(x: center.x.clamped(to: 0...1), y: center.y.clamped(to: 0...1)) }
            if let scale { element.relativeSize = (element.relativeSize * scale).clamped(to: 0.015...0.4) }
            if let rotation { element.rotation = rotation }
        }
    }

    public func endTextInteraction() {
        history.endTransaction()
        manipulatedTextLayerID = nil
        requestPreview()
        Haptics.tick()
    }

    /// Erases every instance of a category (people, text, animals…).
    public func eraseAll(label: String, phrase: String) {
        Task { await run(EditIntent(action: .removeObject, target: ObjectTarget(label: label, originalPhrase: phrase, matchesAll: true), scope: .all)) }
    }

    public func crop(to aspect: AspectPreset) {
        Task { await run(EditIntent(action: .crop, aspect: aspect)) }
    }

    public func addText(_ text: String) {
        Task { await run(EditIntent(action: .addText, text: text, placement: .bottom)) }
    }

    /// Adds a shape layer centred at `center` (or in the middle of the canvas) and selects it.
    public func addShape(_ kind: ShapeElement.Kind, at center: PSPoint? = nil) {
        let aspect = max(0.2, document.aspectRatio)
        var shape = ShapeElement(kind: kind, fill: .white)
        switch kind {
        case .line, .arrow:
            shape.relativeSize = PSSize(width: 0.45, height: 0.08 * aspect)
            shape.strokeWidth = 0.012
        case .ellipse:
            shape.relativeSize = PSSize(width: 0.3, height: 0.3 * aspect)
        default:
            shape.relativeSize = PSSize(width: 0.36, height: 0.24 * aspect)
        }
        let layer = Layer(name: kind.displayName, content: .shape(shape), transform: LayerTransform(center: center ?? PSPoint(x: 0.5, y: 0.5)))
        var document = self.document
        document.addLayer(layer)
        document.selectedLayerID = layer.id
        commit(document, label: L("Add Shape"))
        Haptics.tick()
    }

    public func updateShape(layerID: UUID, _ body: (inout ShapeElement) -> Void) {
        var document = self.document
        document.update(layerID: layerID) { layer in
            guard var shape = layer.shapeElement else { return }
            body(&shape)
            layer.shapeElement = shape
        }
        history.commit(document, label: "Edit Shape")
        requestPreview(interactive: true)
    }

    public func updateText(layerID: UUID, _ body: (inout TextElement) -> Void) {
        var document = self.document
        document.update(layerID: layerID) { layer in
            guard var element = layer.textElement else { return }
            body(&element)
            layer.textElement = element
            layer.name = element.text
        }
        history.commit(document, label: "Edit Text")
        requestPreview(interactive: true)
    }

    public func updateLayer(_ layerID: UUID, _ body: (inout Layer) -> Void) {
        var document = self.document
        document.update(layerID: layerID, body)
        history.commit(document, label: "Layer")
        requestPreview(interactive: true)
    }

    public func selectLayer(_ id: UUID?) {
        var document = self.document
        document.selectedLayerID = id
        history.commit(document, label: "Select")
    }

    public func removeLayer(_ id: UUID) {
        var document = self.document
        guard document.removeLayer(id: id) != nil else { return }
        commit(document, label: "Delete Layer")
    }

    public func moveLayer(_ id: UUID, to index: Int) {
        var document = self.document
        document.moveLayer(id: id, to: index)
        commit(document, label: "Reorder Layers")
    }

    /// Commits painted strokes as a heal operation.
    public func commitBrushErase() {
        guard !brushStrokes.isEmpty else { return }
        let strokes = brushStrokes
        brushStrokes = []
        apply(.heal(strokes: strokes), label: L("Erase"))
    }

    // MARK: - Precise tools

    /// Magic-wand selection at a point on the rendered base image.
    public func magicWandSelect(at point: PSPoint) {
        guard let renderer else { return }
        Task {
            do {
                let image = try await renderer.renderBase(document, options: PhotoRenderer.Options(targetLongestSide: 1536))
                guard let cg = ImageSupport.cgImage(from: image) else { return }
                let maskStore = MaskStore(store: app.store, projectID: projectID)
                let mask = try VisionGrounding.magicWandMask(in: cg, seed: point, tolerance: wandTolerance, contiguous: wandContiguous, maskStore: maskStore)
                setSelection(mask)
                Haptics.confirm()
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func commitLasso() {
        guard lassoPoints.count >= 3 else { return }
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        if let mask = try? VisionGrounding.lassoMask(imageSize: document.canvasSize, points: lassoPoints, maskStore: maskStore) {
            setSelection(mask)
            Haptics.confirm()
        }
        lassoPoints = []
    }

    private func setSelection(_ mask: MaskReference) {
        selectionMask = mask
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        if let preview = preview, let image = maskStore.load(mask, fitting: preview.extent) {
            // Tinted overlay for the canvas.
            let tint = CIImage(color: CIColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 0.45)).cropped(to: preview.extent)
            selectionPreview = AdjustmentPipeline.applyingAlpha(mask: image, to: tint)
        }
    }

    public func clearSelection() {
        selectionMask = nil
        selectionPreview = nil
        lassoPoints = []
    }

    public func eraseSelection() {
        guard let mask = selectionMask else { return }
        apply(.removeObject(mask), label: L("Erase selection"))
        clearSelection()
    }

    public func recolorSelection(_ color: PSColor) {
        guard let mask = selectionMask else { return }
        apply(.recolor(mask, color, strength: 0.9), label: L("Recolor"))
    }

    public func generateInSelection(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard hasGenerativeEngine else {
            showToast(L("Install Generative Fill in Settings › On-device models to use prompts."), isError: true)
            return
        }
        if let mask = selectionMask {
            Task {
                isProcessing = true
                processingTitle = String(format: L("Generating “%@”…"), text)
                defer { isProcessing = false }
                var document = self.document
                document.apply(.generativeFill(mask, prompt: text))
                // Render once so failures surface before the change lands in history.
                if let renderer, (try? await renderer.render(document, options: .preview)) != nil {
                    commit(document, label: "Generate “\(text)”")
                    clearSelection()
                    Haptics.success()
                } else {
                    showToast(L("Generation failed."), isError: true)
                }
            }
        } else {
            Task { await run(EditIntent(action: .generativeFill, target: nil, text: text)) }
        }
    }

    public func commitPixelPaint() {
        guard !brushStrokes.isEmpty else { return }
        let strokes = brushStrokes.map { BrushStroke(id: $0.id, points: $0.points, radius: $0.radius, hardness: 1) }
        brushStrokes = []
        apply(.pixelPaint(strokes: strokes, color: paintColor), label: L("Paint"))
    }

    public func commitClone() {
        guard !brushStrokes.isEmpty, let offset = cloneOffset else { return }
        let strokes = brushStrokes
        brushStrokes = []
        apply(.cloneStamp(strokes: strokes, offset: offset), label: L("Clone Stamp"))
    }

    /// First tap in clone mode sets the source; the next stroke defines the offset.
    public func handlePreciseTap(at point: PSPoint) {
        switch preciseMode {
        case .wand: magicWandSelect(at: point)
        case .lasso: lassoPoints.append(point)
        case .clone:
            if cloneSource == nil || brushStrokes.isEmpty { cloneSource = point; cloneOffset = nil; showToast(L("Source set. Now paint where to clone.")) }
        case .generate:
            if selectionMask == nil { magicWandSelect(at: point) }
        case .pixelBrush: break
        }
    }

    public func beginPreciseStroke(at point: PSPoint) {
        if preciseMode == .clone, let source = cloneSource, cloneOffset == nil {
            cloneOffset = PSPoint(x: source.x - point.x, y: source.y - point.y)
        }
    }

    // MARK: - Canvas taps

    public func tapCanvas(at point: PSPoint) {
        lastTapPoint = point
        if activeTool == .precise, pendingClarification == nil {
            handlePreciseTap(at: point)
            return
        }
        if let pending = pendingClarification {
            if let hit = pending.candidates.filter({ $0.boundingBox.insetBy(dx: -0.02, dy: -0.02).contains(point) }).min(by: { $0.boundingBox.area < $1.boundingBox.area }),
               let index = pending.candidates.firstIndex(where: { $0.id == hit.id }) {
                choose(candidateIndex: index)
            }
            return
        }
        if activeTool == .erase, brushStrokes.isEmpty {
            Task { await run(EditIntent(action: .removeObject, target: ObjectTarget(label: "object", originalPhrase: L("that"), point: point))) }
        }
    }

    public func choose(candidateIndex: Int) {
        Task { await run(EditIntent(action: .chooseCandidate, index: candidateIndex + 1)) }
    }

    public func chooseAllCandidates() {
        Task { await run(EditIntent(action: .chooseCandidate, scope: .all)) }
    }

    public func cancelClarification() {
        pendingClarification = nil
        candidateOverlays = []
    }

    // MARK: - Voice pipeline

    public func handleTranscript(_ text: String) async {
        transcript = text
        let plan = await app.router.plan(text, context: intentContext)
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            showToast(reply + "\n" + Replies.suggestions(for: .photo, language: language), isError: true)
            VoiceFeedback.shared.speak(reply, language: plan.language)
            return
        }
        if let clarification = plan.clarification, plan.intents.allSatisfy({ $0.action == .unknown }) {
            showToast(clarification)
            VoiceFeedback.shared.speak(clarification, language: plan.language)
            return
        }
        VoiceFeedback.shared.speak(plan.reply ?? "", language: plan.language)
        for intent in plan.intents where intent.action != .unknown {
            let outcome = await run(intent)
            if case .needsClarification = outcome { break }
            if case .failed = outcome { break }
        }
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        guard var executor else { return .failed(message: "not ready") }
        executor.language = language
        if intent.action == .generativeFill, !hasGenerativeEngine {
            showToast(L("Install Generative Fill in Settings › On-device models to use prompts."), isError: true)
            return .failed(message: "no generative engine")
        }
        if [.removeObject, .removeBackground, .blurBackground, .replaceBackground, .upscale, .selectiveAdjust, .chooseCandidate, .straighten, .generativeFill, .recolor].contains(intent.action) {
            isProcessing = true
            processingTitle = intent.action == .chooseCandidate ? L("Erasing…") : processingLabel(for: intent)
        }
        defer { isProcessing = false }
        let context = intentContext
        let (updated, result) = await executor.execute(intent, on: document, context: context)
        handle(result, updatedDocument: updated, intent: intent)
        return result.outcome
    }

    private func processingLabel(for intent: EditIntent) -> String {
        switch intent.action {
        case .removeObject: return String(format: L("Finding %@…"), intent.target?.originalPhrase ?? L("object"))
        case .generativeFill: return String(format: L("Generating “%@”…"), intent.text ?? "")
        case .recolor: return L("Recolouring…")
        case .removeBackground: return L("Cutting out the subject…")
        case .blurBackground: return L("Blurring the background…")
        case .replaceBackground: return L("Replacing the background…")
        case .upscale: return L("Upscaling…")
        case .straighten: return L("Levelling…")
        default: return L("Working…")
        }
    }

    private func handle(_ result: ExecutionResult, updatedDocument: PhotoDocument, intent: EditIntent) {
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            candidateOverlays = []
            if updatedDocument != document {
                commit(updatedDocument, label: label)
            }
            if !label.isEmpty { showToast(label) }
            Haptics.success()
        case .needsClarification(let request):
            pendingClarification = request
            candidateOverlays = request.candidates
            showToast(request.question)
            VoiceFeedback.shared.speak(request.question, language: language.rawValue)
            Haptics.warning()
            if app.settings.voiceMode != .pushToTalk, isVoiceReady {
                // Listen for the answer right away.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    if app.voice.state == .idle { app.voice.start() }
                }
            }
        case .info(let message):
            showToast(message)
            if result.effects.contains(.message("tapToErase")) { activeTool = .erase }
            if result.effects.contains(.message("crop")) { activeTool = .crop }
        case .failed(let message):
            showToast(message, isError: true)
            Haptics.error()
        case .ignored:
            break
        }
        for effect in result.effects {
            switch effect {
            case .message("selectRegion"):
                activeTool = .precise
                preciseMode = .lasso
                if let text = intent.text, intent.action == .generativeFill { generativePrompt = text }
            case .undo: undo()
            case .redo: redo()
            case .revert: revert()
            case .compare:
                showsOriginal = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    showsOriginal = false
                }
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .selectLayer(let id):
                var document = updatedDocument
                document.selectedLayerID = id
                if document != self.document { history.commit(document, label: "Select") }
                activeTool = .text
            case .pickBackground: activeTool = .cutout
            case .cancel:
                cancelClarification()
                showToast(L("Cancelled."))
            case .zoom(let amount, let target):
                zoomRequest = ZoomRequest(amount: amount, target: target)
            default: break
            }
        }
    }

    public struct ZoomRequest: Equatable {
        var amount: AmountSpec?
        var target: ObjectTarget?
        var id = UUID()
    }

    public var zoomRequest: ZoomRequest?

    // MARK: - Export

    public func export(options: ExportOptions) async {
        guard let renderer else { return }
        exportProgress = 0.05
        defer { exportProgress = nil }
        do {
            let url = try await PhotoExporter.export(document, renderer: renderer, options: options)
            exportedURL = url
            Haptics.success()
            showToast(options.saveToPhotos ? L("Saved to Photos") : L("Exported"))
        } catch {
            Haptics.error()
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    // MARK: - Toast

    public func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = Toast(text: text, isError: isError) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 3.5 : 2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}
#endif
