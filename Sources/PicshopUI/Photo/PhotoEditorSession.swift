#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import UIKit
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
        case magic, focus, adjust, looks, color, erase, precise, cutout, crop, text, shapes, layers
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .magic: return L("Magic")
            case .focus: return L("Focus")
            case .adjust: return L("Adjust")
            case .looks: return L("Filters")
            case .color: return L("Colour")
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
            case .magic: return "sparkles"
            case .focus: return "camera.aperture"
            case .color: return "paintpalette"
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
        /// Offers an Undo button in the toast (applied edits).
        var undoable = false
        /// A one-tap fix offered in the toast instead of Undo.
        var action: Action?
        var id = UUID()

        public enum Action: Equatable {
            case rightWayUp
        }
    }

    public let projectID: UUID
    public let app: AppEnvironment
    public private(set) var history: EditHistory<PhotoDocument> {
        didSet {
            didChangeHistory()
            scheduleAutosave()
        }
    }
    /// Stored mirror of `history.present`, updated by didChangeHistory() only.
    public private(set) var document: PhotoDocument
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Past labels, oldest first.
    public private(set) var undoLabels: [String] = []
    /// Bumped whenever the document changes (undo and redo included); Live's document version.
    public private(set) var revision = 0
    /// The tools whose edits are in the picture (Photos' yellow dot).
    public private(set) var modifiedTools: Set<Tool>
    /// The value of the dial being dragged; only the dial reads it.
    public let dial: DialValue
    /// Picshop Live in this editor, attached at the end of init.
    public let live: LiveSession
    /// True for the whole of a Live session: no toast for Live steps, no spoken reply, no recogniser start.
    @ObservationIgnored public var liveSpeechSuppressed = false
    @ObservationIgnored private var isTornDown = false
    /// The photo as this session opened it: Revert starts from it, so layers added since go too.
    private let openedDocument: PhotoDocument

    public private(set) var renderer: PhotoRenderer?
    private var services: VisionPhotoServices?
    private var executor: PhotoCommandExecutor?

    public private(set) var preview: CIImage?
    public private(set) var isRendering = false
    public var showsOriginal = false { didSet { requestPreview() } }
    /// Split before/after: the original shows left of this point (0…1), nil when off.
    public var compareSplit: Double? {
        didSet { if (oldValue == nil) != (compareSplit == nil) { Task { await loadOriginalPreview() } } }
    }
    /// The untouched photo at preview size, for the split compare.
    public private(set) var originalPreview: CIImage?
    /// The split compare lines pixels up, so it is offered only while the frame is the original one.
    public var canSplitCompare: Bool { !(document.baseLayer?.edits.hasGeometry ?? false) && history.canUndo }

    private func loadOriginalPreview() async {
        guard compareSplit != nil, let renderer else { originalPreview = nil; return }
        let options = PhotoRenderer.Options(targetLongestSide: app.performance.previewLongestSide, showOriginal: true, allowExpensiveWork: false)
        originalPreview = try? await renderer.render(previewDocument(), options: options)
    }
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
    /// The voice strip reports what really happened: true when the command could not be done as said.
    public private(set) var lastReplyIsProblem = false
    /// The command failed (an error, not a hand-over to the finger).
    public private(set) var lastReplyIsError = false
    /// Changes with every reply to show, so the strip shows it again for the same words said
    /// twice, or for an outcome that arrives long after the words.
    public private(set) var replyID = UUID()
    /// While a spoken command runs, its outcome is told in the voice strip rather than a second banner.
    private var isRunningVoiceCommand = false
    public var pendingClarification: ClarificationRequest?
    public var candidateOverlays: [ObjectCandidate] = []
    /// Main objects found in the picture, offered as one-tap erase targets.
    public var sceneObjects: [ObjectCandidate] = []
    /// The object tapped in the Magic tool, with its actions floating beside it.
    public var magicSelection: ObjectCandidate?
    /// What the picture is (people, sky, product…), so Magic can lead with what suits it.
    public var sceneDescription: SceneDescription?
    /// The picker for a picture whose colours this photo should take.
    public var showsColorReferencePicker = false
    public var isFindingObjects = false
    private var sceneObjectsKey: String?
    public var showsExport = false
    /// A command to run as soon as the editor is ready (Magic shortcuts on Home).
    public var pendingCommand: String?
    public var exportedURL: URL?
    public var exportProgress: Double?
    public var showsHelp = false
    public var isVoiceReady = false

    private var renderTask: Task<Void, Never>?
    /// The voice command running now; the next one waits for it.
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveDeadline = ContinuousClock.now
    @ObservationIgnored private var lastSavedDocument: PhotoDocument?
    @ObservationIgnored private var saveSequence = 0
    @ObservationIgnored private let writeGate = ProjectWriteGate()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Parameter and direction of the most recent adjustment, so "a bit more" / "encore un peu" can refer to it.
    public private(set) var lastAdjustment: (parameter: AdjustmentParameter, direction: Int)?
    private var toastTask: Task<Void, Never>?
    private var isConfigured = false
    /// Look thumbnails rendered for the current photo state (see `LooksPanel`).
    public var lookThumbnails: (key: String, images: [FilterPreset: UIImage])?
    /// Changes whenever the base photo's pixels change (crop, erase, look…), invalidating the thumbnails.
    /// Computed once per document change.
    public private(set) var lookThumbnailKey: String

    public init(document: PhotoDocument, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: document)
        self.document = document
        modifiedTools = Self.modifiedTools(in: document)
        lookThumbnailKey = Self.lookThumbnailKey(for: document, thumbnailSide: app.performance.thumbnailSide)
        openedDocument = document
        previewAspectRatio = document.aspectRatio
        dial = DialValue()
        live = LiveSession(app: app, mode: .photo, canGoLive: true)
        live.attach(self)
    }

    // MARK: - Lifecycle

    public func configure() async {
        guard !isConfigured else { return }
        isConfigured = true
        // The photo must appear immediately. The neural models are attached to
        // the pipeline in the background: it is a reference type, so the
        // renderer built here picks them up as soon as they land, and a fill
        // that arrives first waits for them rather than using the fallback.
        let pipeline = InpaintingPipeline()
        let renderer = PhotoRenderer(store: app.store, projectID: projectID, inpainting: pipeline, upscaler: await app.makeUpscaler())
        self.renderer = renderer
        let services = VisionPhotoServices(renderer: renderer, store: app.store, projectID: projectID)
        self.services = services
        executor = PhotoCommandExecutor(services: services, language: language)
        app.voice.onFinalTranscript = { [weak self] text in
            Task { await self?.handleTranscript(text) }
        }
        isVoiceReady = true
        lastSavedDocument = document
        observeLifecycle()
        requestPreview()
        // Upside down with the reading order kept is never a look anyone chose, and a flip
        // made in an earlier session is out of Undo's reach: offer the way back.
        if document.baseOrientation.isVerticallyFlipped, pendingCommand == nil {
            showToast(L("This photo is upside down."), action: .rightWayUp)
        }
        if let command = pendingCommand {
            pendingCommand = nil
            Task { [weak self] in await self?.handleTranscript(command) }
        }
        let load = Task { [weak self] in
            guard let self else { return }
            await app.attachEngines(to: pipeline)
            hasGenerativeEngine = pipeline.hasGenerativeEngine
        }
        pipeline.setLoading(load)
        // Reading the file's auxiliary data is disk I/O: off the main thread, once (the base image never changes).
        if let asset = document.baseLayer?.imageAsset {
            let url = app.store.url(for: asset.relativePath, in: projectID)
            Task { [weak self] in
                let hasDepth = await Task.detached(priority: .utility) { ImageSupport.hasDepthData(at: url) }.value
                guard let self, hasDepth != hasDepthMap else { return }
                hasDepthMap = hasDepth
            }
        }
    }

    /// Ends the session: Live, the voice, rendering and observers stop, and the photo is saved. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        live.teardown()
        app.voice.cancel()
        app.voice.onFinalTranscript = nil
        renderTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        save()
    }

    public func save() {
        autosaveTask?.cancel()
        autosaveTask = nil
        let project = Project(id: projectID, content: .photo(document), createdAt: document.createdAt, modifiedAt: Date())
        saveSequence += 1
        lastSavedDocument = document
        let library = app.library
        writeGate.write(sequence: saveSequence) { library.save(project) }
        app.styles.rememberLast(currentStyle)
        if let renderer {
            let store = app.store
            let document = self.document
            let library = app.library
            let id = projectID
            Task.detached(priority: .utility) {
                await ThumbnailGenerator.writeThumbnail(for: document, renderer: renderer, store: store)
                await MainActor.run { library.invalidateThumbnail(for: id) }
            }
        }
    }

    // MARK: - Autosave

    /// Saves ~0.8 s after the last change, so a crash or a kill loses at most that
    /// much. Written off the main actor, without refreshing the library.
    private func scheduleAutosave() {
        guard isConfigured else { return }
        autosaveDeadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        guard autosaveTask == nil else { return }
        autosaveTask = Task { [weak self] in
            while let self {
                let deadline = self.autosaveDeadline
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                if self.autosaveDeadline <= ContinuousClock.now {
                    self.autosaveTask = nil
                    self.autosave(synchronously: false)
                    return
                }
            }
        }
    }

    private func autosave(synchronously: Bool) {
        let document = self.document
        guard document != lastSavedDocument else { return }
        lastSavedDocument = document
        saveSequence += 1
        let sequence = saveSequence
        let project = Project(id: projectID, content: .photo(document), createdAt: document.createdAt, modifiedAt: Date())
        let store = app.store
        let gate = writeGate
        let write: @Sendable () -> Void = {
            gate.write(sequence: sequence) {
                do { try store.save(project) } catch { PSLog.error("autosave failed: \(error)", category: .ui) }
            }
        }
        if synchronously {
            write()
        } else {
            Task.detached(priority: .utility) { write() }
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // Synchronous on the main queue: a hop through a task could run after the app is suspended.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosaveTask?.cancel()
                self.autosaveTask = nil
                self.autosave(synchronously: true)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relieveMemoryPressure() }
        })
    }

    /// Memory warning: everything this editor can rebuild goes, the current erase stays.
    private func relieveMemoryPressure() {
        lookThumbnails = nil
        if compareSplit == nil { originalPreview = nil }
        Diagnostics.shared.note("editor trimmed its caches")
        if let renderer { Task { await renderer.trimForMemoryPressure() } }
    }

    var language: NormalizedUtterance.Language {
        if let hint = app.settings.languageHint { return hint == "fr" ? .french : .english }
        return Locale.current.language.languageCode?.identifier == "fr" ? .french : .english
    }

    var intentContext: IntentContext {
        IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, hasSelection: document.selectedLayer?.isText == true,
                      selectedIndex: document.selectedLayerID.flatMap { document.index(of: $0) }, clipCount: 0, textLayerCount: document.textLayers.count,
                      pendingClarification: pendingClarification, lastTapPoint: lastTapPoint, canUndo: history.canUndo, canRedo: history.canRedo,
                      preferredLanguage: app.settings.languageHint, lastParameter: lastAdjustment?.parameter, lastAdjustmentDirection: lastAdjustment?.direction ?? 0,
                      selectionMask: selectionMask)
    }

    // MARK: - Rendering

    /// Renders the document for the canvas.
    ///
    /// Interactive requests (dial drags) are coalesced: at most one render is in
    /// flight, and a request that arrives while one is running only marks the
    /// preview dirty, so the renderer always draws the latest state instead of
    /// queuing a frame per tick. Sizes come from the performance governor, so a
    /// hot phone renders smaller previews before it drops frames.
    public func requestPreview(interactive: Bool = false) {
        guard renderer != nil else { return }
        if interactive {
            dirtyInteractive = true
            if isRendering { return }
            renderLoop(interactive: true)
        } else {
            renderTask?.cancel()
            dirtyInteractive = false
            renderLoop(interactive: false)
        }
    }

    private var dirtyInteractive = false
    private var renderGeneration = 0

    private func previewDocument() -> PhotoDocument {
        var document = self.document
        if straightenPreview != 0 { document.apply(.straighten(degrees: straightenPreview)) }
        if perspectiveHorizontal != 0 || perspectiveVertical != 0 { document.apply(.perspective(horizontal: perspectiveHorizontal, vertical: perspectiveVertical)) }
        return document
    }

    private func renderLoop(interactive: Bool) {
        guard let renderer else { return }
        let governor = app.performance
        renderGeneration += 1
        let generation = renderGeneration
        renderTask = Task { [weak self] in
            guard let self else { return }
            isRendering = true
            defer { if renderGeneration == generation { isRendering = false } }
            var interactive = interactive
            while !Task.isCancelled {
                dirtyInteractive = false
                let document = previewDocument()
                let side = interactive ? governor.interactivePreviewSide : governor.previewLongestSide
                // A dial drag never starts an erase or an upscale: it reuses a finished one, scaled.
                let options = PhotoRenderer.Options(targetLongestSide: side, showOriginal: showsOriginal, allowExpensiveWork: !interactive, isDisplayed: true)
                do {
                    let image = try await renderer.render(document, options: options)
                    guard !Task.isCancelled else { return }
                    preview = image
                    let ratio = image.extent.height > 0 ? Double(image.extent.width / image.extent.height) : document.aspectRatio
                    if abs(ratio - previewAspectRatio) > 0.0005 { previewAspectRatio = ratio }
                    if !hasRenderedPreview { hasRenderedPreview = true }
                } catch {
                    PSLog.error("preview failed: \(error)", category: .ui)
                }
                if interactive {
                    // Give the display a chance to present before the next frame.
                    try? await Task.sleep(for: governor.interactiveRenderInterval)
                    guard !Task.isCancelled else { return }
                    if dirtyInteractive { continue }
                    // Interaction settled: follow up with the sharp frame.
                    try? await Task.sleep(for: governor.settleDelay)
                    guard !Task.isCancelled else { return }
                    if dirtyInteractive { continue }
                    interactive = false
                } else if dirtyInteractive {
                    interactive = true
                } else {
                    return
                }
            }
        }
    }

    // MARK: - History

    /// Brings the stored mirrors up to date after any change to `history`, each
    /// assigned only when its value changes, then tells Live.
    private func didChangeHistory() {
        let present = history.present
        let documentChanged = present != document
        let grew = history.past.count > undoLabels.count
        var changed = documentChanged
        if documentChanged { document = present }
        if canUndo != history.canUndo { canUndo = history.canUndo; changed = true }
        if canRedo != history.canRedo { canRedo = history.canRedo; changed = true }
        let labels = history.past.map(\.label)
        if labels != undoLabels { undoLabels = labels; changed = true }
        if documentChanged {
            revision += 1
            let tools = Self.modifiedTools(in: present)
            if tools != modifiedTools { modifiedTools = tools }
            let key = Self.lookThumbnailKey(for: present, thumbnailSide: app.performance.thumbnailSide)
            if key != lookThumbnailKey { lookThumbnailKey = key }
        }
        // A dial drag is one change, told when it ends.
        guard changed, !history.isInTransaction else { return }
        live.noteDocumentChanged(label: grew ? history.undoLabel : nil)
    }

    /// Which tools' edits are in the picture: the dock's yellow dots, one per tool.
    static func modifiedTools(in document: PhotoDocument) -> Set<Tool> {
        var tools: Set<Tool> = []
        let base = document.baseLayer?.edits
        let active = document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits }
        if base?.resolvedLensBlur != nil { tools.insert(.focus) }
        if !document.activeAdjustments.isNeutral { tools.insert(.adjust) }
        if base?.resolvedLook != nil { tools.insert(.looks) }
        if active?.resolvedColorMixer != nil || active?.resolvedColorGrade != nil || active?.resolvedLUT != nil { tools.insert(.color) }
        for operation in base?.operations ?? [] {
            switch operation.kind {
            case .removeObject, .heal, .blurRegion, .moveObject: tools.insert(.erase)
            case .removeBackground, .replaceBackground, .blurBackground: tools.insert(.cutout)
            case .generativeFill, .recolor, .cloneStamp, .pixelPaint: tools.insert(.precise)
            default: break
            }
        }
        if base?.hasGeometry == true { tools.insert(.crop) }
        if !document.textLayers.isEmpty { tools.insert(.text) }
        if !document.shapeLayers.isEmpty { tools.insert(.shapes) }
        if document.layers.count > 1 { tools.insert(.layers) }
        return tools
    }

    /// Changes whenever the base photo's pixels change (crop, erase, look…): tonal steps leave it alone.
    static func lookThumbnailKey(for document: PhotoDocument, thumbnailSide: Double) -> String {
        let operations = document.baseLayer?.edits.operations.filter { operation in
            switch operation.kind {
            case .adjust, .adjustments, .toneCurve, .look, .autoEnhance: return false
            default: return true
            }
        } ?? []
        return operations.map(\.id.uuidString).joined(separator: "|") + "@\(Int(thumbnailSide))"
    }

    private func commit(_ newDocument: PhotoDocument, label: String) {
        Diagnostics.shared.note("commit \(label)")
        magicSelection = nil
        var updated = newDocument
        updated.touch()
        history.commit(updated, label: label)
        requestPreview()
    }

    public func undo() {
        guard history.canUndo else { return }
        magicSelection = nil
        let label = history.undo()
        Haptics.tick()
        showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo"))
        requestPreview()
    }

    /// Goes back several steps at once (the History list): one refresh, one toast.
    public func undo(steps: Int) {
        guard steps > 0, history.canUndo else { return }
        magicSelection = nil
        var last: String?
        for _ in 0..<steps where history.canUndo { last = history.undo() }
        Haptics.tick()
        showToast(last.map { "\(L("Undo")) · \($0)" } ?? L("Undo"))
        requestPreview()
    }

    public func redo() {
        guard history.canRedo else { return }
        let label = history.redo()
        Haptics.tick()
        showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo"))
        requestPreview()
    }

    /// Back to the photo as imported, including edits saved in earlier
    /// sessions — which Undo cannot reach — and without the layers added since
    /// this session opened. Itself undoable. False when there was nothing to revert.
    @discardableResult
    public func revert() -> Bool {
        let restored = openedDocument.restoredToImport()
        var compared = restored
        compared.modifiedAt = document.modifiedAt
        compared.selectedLayerID = document.selectedLayerID
        guard compared != document else { return false }
        commit(restored, label: L("Revert to Original"))
        Haptics.confirm()
        return true
    }

    /// Whether earlier flips or quarter turns left the photo upside down, on its side or mirrored.
    public var isTurnedOrMirrored: Bool { !document.baseOrientation.isUpright }

    /// Undoes every flip and quarter turn in one step, whenever they were made.
    public func putRightWayUp() {
        var document = self.document
        guard document.resetOrientation(label: L("Right Way Up")) else { return }
        commit(document, label: L("Right Way Up"))
        Haptics.confirm()
        showToast(L("Back the right way up."), undoable: true)
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
        let previous = document.activeAdjustments[parameter]
        document.update(layerID: layerID) { $0.edits.setAdjustment(parameter, value: value) }
        history.commit(document, label: parameter.englishName)
        if abs(value - previous) > 0.0005 { lastAdjustment = (parameter, value > previous ? 1 : -1) }
        requestPreview(interactive: true)
    }

    // MARK: - Depth and colour magic

    static let subjectLayerName = PhotoDocument.subjectLayerName

    /// The Lock Screen depth effect: the subject is lifted onto its own layer
    /// above everything, so the title sits behind the person. Adds a big title
    /// first when the photo has no text yet.
    public func textBehindSubject() async {
        guard let services, !isProcessing else { return }
        guard document.baseLayer?.imageAsset != nil else { return }
        isProcessing = true
        processingTitle = L("Lifting the subject…")
        defer { isProcessing = false }
        do {
            let mask = try await services.subjectMask(in: document)
            var updated = document
            updated.placeTextBehindSubject(nil, subjectMask: mask, placeholder: L("TITLE"))
            commit(updated, label: L("Text behind subject"))
            activeTool = .text
            Haptics.magic()
            showToast(L("Double-tap the title to write your own."))
        } catch {
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    /// Gives this photo the colour mood of another one (Reinhard transfer in Lab, as a LUT).
    public func matchColors(to referenceData: Data) async {
        guard let asset = document.baseLayer?.imageAsset else { return }
        let store = app.store
        let projectID = projectID
        let result = await Task.detached(priority: .userInitiated) { () -> ColorMatch? in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (try? referenceData.write(to: temporary)) != nil,
                  let reference = try? ImageSupport.loadCGImage(at: temporary, maxPixelSize: 256),
                  let source = try? ImageSupport.loadCGImage(at: store.url(for: asset.relativePath, in: projectID), maxPixelSize: 256) else { return nil }
            return ColorMatch(source: ColorStatistics.measure(rgba: ImageSupport.rgbaBytes(from: source)),
                              reference: ColorStatistics.measure(rgba: ImageSupport.rgbaBytes(from: reference)), strength: 0.8)
        }.value
        guard let result else {
            showToast(L("That picture couldn't be read."), isError: true)
            return
        }
        apply(.colorMatch(result), label: L("Match Colour"))
        Haptics.magic()
        showToast(L("Colours matched."), undoable: true)
    }

    // MARK: - Focus after the shot

    /// Where the lens blur is focused, when there is one.
    public var focusPoint: PSPoint? { document.baseLayer?.edits.resolvedLensBlur?.focus }
    /// 0 = everything sharp … 1 = the widest aperture.
    public var focusAperture: Double { document.baseLayer?.edits.resolvedLensBlur?.aperture ?? 0.55 }
    /// Whether the photo carries the camera's depth map (else the subject is used). Filled in configure().
    public private(set) var hasDepthMap = false

    @ObservationIgnored private var focusMask: MaskReference?

    /// Refocuses the photo on a point: the depth map sets what is near and
    /// far; without one, the tapped side of the subject outline stays sharp.
    public func setFocus(at point: PSPoint) async {
        guard let services, let baseID = document.baseLayerID else { return }
        let aperture = document.baseLayer?.edits.resolvedLensBlur?.aperture ?? 0.55
        var mask: MaskReference?
        if !hasDepthMap || document.baseLayer?.edits.hasGeometry == true {
            if focusMask == nil {
                isProcessing = true
                processingTitle = L("Finding the subject…")
                focusMask = try? await services.subjectMask(in: document)
                isProcessing = false
            }
            mask = focusMask
            guard mask != nil else {
                showToast(L("PicShop couldn't find a subject to focus on."), isError: true)
                return
            }
        }
        var updated = document
        updated.update(layerID: baseID) { $0.edits.setColor(.lensBlur(focus: point, aperture: aperture, mask: mask)) }
        commit(updated, label: L("Focus"))
        Haptics.soft(0.8)
    }

    public func beginApertureInteraction() { history.beginTransaction(label: "Aperture") }

    public func endApertureInteraction() {
        history.endTransaction()
        requestPreview()
    }

    public func setAperture(_ aperture: Double) {
        guard let baseID = document.baseLayerID, let lens = document.baseLayer?.edits.resolvedLensBlur ?? document.baseLayer?.edits.operations.reversed().compactMap({ operation -> (focus: PSPoint, aperture: Double, mask: MaskReference?)? in
            if case .lensBlur(let focus, let aperture, let mask) = operation.kind { return (focus, aperture, mask) }
            return nil
        }).first else { return }
        var updated = document
        updated.update(layerID: baseID) { $0.edits.setColor(.lensBlur(focus: lens.focus, aperture: aperture, mask: lens.mask)) }
        history.commit(updated, label: "Aperture")
        requestPreview(interactive: true)
    }

    public func removeFocusBlur() {
        guard let baseID = document.baseLayerID, let lens = document.baseLayer?.edits.resolvedLensBlur else { return }
        var updated = document
        updated.update(layerID: baseID) { $0.edits.setColor(.lensBlur(focus: lens.focus, aperture: 0, mask: lens.mask)) }
        commit(updated, label: L("Remove Focus Blur"))
    }

    // MARK: - Colour (mixer and wheels)

    /// The active layer's colour mixer, neutral when none.
    public var colorMixer: ColorMixer {
        document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedColorMixer } ?? .neutral
    }

    /// The active layer's three-way grade, neutral when none.
    public var colorGrade: ColorGrade {
        document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedColorGrade } ?? .neutral
    }

    public func beginColorInteraction(_ label: String) { history.beginTransaction(label: label) }

    public func endColorInteraction() {
        history.endTransaction()
        requestPreview()
    }

    /// The active layer's imported look, nil when none.
    public var lut: LUTReference? {
        document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedLUT }
    }

    public func importLUT(from url: URL) {
        do {
            let reference = try LUTImporter.save(url, store: app.store, projectID: projectID)
            setColor(.lut(reference), label: "LUT")
            requestPreview()
            Haptics.success()
            showToast(String(format: L("Look “%@” applied"), reference.title), undoable: true)
        } catch {
            showToast(L("That file is not a 3D .cube LUT."), isError: true)
        }
    }

    public func setLUTIntensity(_ value: Double) {
        guard var reference = lut else { return }
        reference.intensity = value.clamped(to: 0.05...1)
        setColor(.lut(reference), label: "LUT Intensity")
    }

    public func removeLUT() {
        guard var reference = lut else { return }
        reference.intensity = 0
        setColor(.lut(reference), label: "Remove LUT")
        requestPreview()
    }

    public func setColorMixer(_ mixer: ColorMixer) { setColor(.colorMixer(mixer), label: "Colour Mixer") }
    public func setColorGrade(_ grade: ColorGrade) { setColor(.colorGrade(grade), label: "Colour Grading") }

    private func setColor(_ kind: EditOperation.Kind, label: String) {
        var document = self.document
        guard let layerID = document.activeImageLayerID else { return }
        document.update(layerID: layerID) { $0.edits.setColor(kind) }
        history.commit(document, label: label)
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
        if activeTool != .magic { magicSelection = nil }
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
    ///
    /// Stored rather than derived from `preview`: the canvas lays itself out
    /// from this, and reading the preview here would make the whole layout —
    /// crop frame, handles, gestures — depend on every rendered frame. It only
    /// changes when the shape of the picture changes.
    public private(set) var previewAspectRatio: Double = 1
    /// False until the first frame has been drawn, so the canvas can show that
    /// it is loading without reading the preview itself.
    public private(set) var hasRenderedPreview = false

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

    /// Generative expand from the crop tool: rather than cutting the picture to
    /// the chosen shape, it grows to it (or by a quarter all round) and the
    /// new edges are invented to match.
    public func expandCanvas() {
        var intent = EditIntent(action: .expandCanvas)
        if cropAspect != .free, cropAspect != .original { intent.aspect = cropAspect }
        cancelCrop()
        Task {
            await run(intent)
            if activeTool == .crop { beginCrop() }
        }
    }

    /// Best crop from the crop tool: the framing an aesthetics model prefers.
    public func autoCrop() {
        cancelCrop()
        Task {
            await run(EditIntent(action: .autoCrop))
            if activeTool == .crop { beginCrop() }
        }
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

    public func flipVertically() {
        apply(.flip(.vertical), label: L("Flip Vertical"))
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

    /// Finds the main objects once per photo state (cheap re-entry).
    public func loadSceneObjects() async {
        let key = lookThumbnailKey
        guard sceneObjectsKey != key, let services, !isFindingObjects else { return }
        // Vision and a second erase pass would compete with the running one for memory: wait for it.
        while isProcessing || isRendering {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        guard sceneObjectsKey != key, key == lookThumbnailKey, !isFindingObjects else { return }
        isFindingObjects = true
        defer { isFindingObjects = false }
        let found = (try? await services.namedObjects(in: document)) ?? []
        let scene = try? await services.describe(document)
        sceneObjectsKey = key
        withAnimation(PSMotion.standard) {
            sceneObjects = found
            if let scene { sceneDescription = scene }
        }
    }

    /// Erases one of the objects found in the picture.
    public func erase(_ candidate: ObjectCandidate) {
        let target = ObjectTarget(label: candidate.label, originalPhrase: candidate.label, point: candidate.boundingBox.center)
        Task { await run(EditIntent(action: .removeObject, target: target)) }
    }

    /// Magic move for a detected object: it lifts off, where it stood is filled
    /// in, and it lands a step away in `degrees` (0 right, 90 up) — or in the middle.
    public func move(_ candidate: ObjectCandidate, degrees: Double?) {
        var intent = EditIntent(action: .moveObject, target: ObjectTarget(label: candidate.label, originalPhrase: candidate.label, point: candidate.boundingBox.center))
        if let degrees {
            intent.degrees = degrees
            intent.amount = .absolute(0.15)
        } else {
            intent.placement = .center
        }
        Task { await run(intent) }
    }

    /// A privacy blur over one of the objects found in the picture.
    public func blur(_ candidate: ObjectCandidate) {
        let target = ObjectTarget(label: candidate.label, originalPhrase: candidate.label, point: candidate.boundingBox.center)
        Task { await run(EditIntent(action: .blurObject, target: target)) }
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
        guard app.performance.allowsHeavyWork else {
            showToast(L("The iPhone is too hot for generation right now. Let it cool for a moment."), isError: true)
            return
        }
        if let mask = selectionMask {
            Task {
                guard !isProcessing else {
                    showToast(L("One moment…"))
                    return
                }
                isProcessing = true
                processingTitle = String(format: L("Generating “%@”…"), text)
                defer { isProcessing = false }
                let base = self.document
                var updated = base
                updated.apply(.generativeFill(mask, prompt: text))
                // Render once so failures surface before the change lands in history.
                if let renderer, (try? await renderer.render(updated, options: .preview)) != nil {
                    // A dial moved meanwhile carries over; anything else drops the result.
                    guard let result = base == self.document ? updated : Self.rebase(updated, from: base, onto: self.document) else {
                        showToast(L("The photo changed in the meantime. Try again."), isError: true)
                        Haptics.warning()
                        return
                    }
                    commit(result, label: "Generate “\(text)”")
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
        if activeTool == .focus {
            Task { await setFocus(at: point) }
            return
        }
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
        if activeTool == .magic {
            // The most specific object under the finger; tapping it again, or nothing, lets go.
            let hit = sceneObjects.filter { $0.boundingBox.insetBy(dx: -0.01, dy: -0.01).contains(point) }.min { $0.boundingBox.area < $1.boundingBox.area }
            if hit != nil { Haptics.tick() }
            magicSelection = hit?.id == magicSelection?.id ? nil : hit
        }
    }

    public func choose(candidateIndex: Int) {
        Task { await run(EditIntent(action: .chooseCandidate, index: candidateIndex + 1)) }
    }

    /// Small crop of the preview around a candidate, so the clarification
    /// chips show the actual object rather than only a number.
    public func candidateThumbnail(_ candidate: ObjectCandidate) async -> UIImage? {
        guard let preview else { return nil }
        let extent = preview.extent
        let box = candidate.boundingBox
        let pad = 0.08
        let x0 = max(0, box.origin.x - pad), y0 = max(0, box.origin.y - pad)
        let x1 = min(1, box.origin.x + box.size.width + pad), y1 = min(1, box.origin.y + box.size.height + pad)
        // Boxes are top-left normalised; Core Image is bottom-left.
        let rect = CGRect(x: extent.minX + x0 * extent.width, y: extent.minY + (1 - y1) * extent.height,
                          width: (x1 - x0) * extent.width, height: (y1 - y0) * extent.height).integral
        guard rect.width > 1, rect.height > 1 else { return nil }
        let scale = min(1, 160 / max(rect.width, rect.height))
        let cropped = preview.cropped(to: rect).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
        // The preview is a lazy graph (a fill, blurs, a resample): rendering it can take a while, so not on the main thread.
        let cgImage = await Task.detached(priority: .userInitiated) { ImageSupport.cgImage(from: image) }.value
        return cgImage.map { UIImage(cgImage: $0) }
    }

    public func chooseAllCandidates() {
        Task { await run(EditIntent(action: .chooseCandidate, scope: .all)) }
    }

    public func cancelClarification() {
        pendingClarification = nil
        candidateOverlays = []
    }

    // MARK: - Voice pipeline

    /// Runs a spoken or typed command. Commands run one at a time: the next waits
    /// for the previous one, and while an erase or another long step is running a
    /// new one gets "One moment…" instead of starting from the photo as it was.
    public func handleTranscript(_ text: String) async {
        if isProcessing {
            Diagnostics.shared.note("busy, command set aside")
            Haptics.warning()
            showToast(L("One moment…"))
            return
        }
        let previous = commandTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.processTranscript(text)
        }
        commandTask = task
        await task.value
    }

    private func processTranscript(_ text: String) async {
        Diagnostics.shared.noteCommand(text)
        transcript = text
        lastReplyIsProblem = false
        lastReplyIsError = false
        replyID = UUID()
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
        // What has to be found in the picture is confirmed once it is found, never before.
        let mustFindFirst = plan.intents.contains { Self.findsBeforeActing.contains($0.action) }
        if !mustFindFirst { VoiceFeedback.shared.speak(plan.reply ?? "", language: plan.language) }
        isRunningVoiceCommand = true
        defer { isRunningVoiceCommand = false }
        var told: String?
        steps: for intent in plan.intents where intent.action != .unknown {
            lastOutcomeNeedsHand = false
            let outcome = await run(intent)
            switch outcome {
            case .info(let message):
                told = message
                lastReplyIsProblem = lastOutcomeNeedsHand
            case .failed(let message):
                told = message
                lastReplyIsProblem = true
                lastReplyIsError = true
                break steps
            case .needsClarification:
                return
            case .applied, .ignored:
                continue
            }
        }
        if let told {
            // The strip says what really happened, not what was hoped for, and shows it afresh.
            lastPlan?.reply = told
            replyID = UUID()
            VoiceFeedback.shared.speak(told, language: plan.language)
        } else if mustFindFirst {
            VoiceFeedback.shared.speak(plan.reply ?? "", language: plan.language)
        }
    }

    /// The last command handed over to the finger (tap or lasso what was not found).
    private var lastOutcomeNeedsHand = false

    /// Says what happened: in the voice strip during a spoken command, in a toast otherwise.
    private func tell(_ message: String) {
        if isRunningVoiceCommand {
            lastPlan?.reply = message
            replyID = UUID()
        } else {
            showToast(message)
        }
    }

    /// History labels are English keys (DYNAMIC_KEYS); "Remove …" carries the target as it was said.
    private func toastText(for label: String) -> String {
        let localized = LD(label)
        guard psPrefersFrench, localized == label, label.hasPrefix("Remove ") else { return localized }
        return String(format: L("Erase %@"), String(label.dropFirst("Remove ".count)))
    }

    private static let findsBeforeActing: Set<IntentAction> = [.removeObject, .moveObject, .blurObject, .recolor, .generativeFill, .selectiveAdjust, .cleanUp, .chooseCandidate]

    /// Drops the heavy step that is running, if any: its result is discarded when it
    /// arrives. True when something was running. Phase 0: nothing is cancellable yet.
    @discardableResult
    public func cancelProcessing() -> Bool {
        false
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        guard var executor else { return .failed(message: L("Still getting ready — try again in a moment.")) }
        executor.language = language
        func refuse(_ message: String) -> CommandOutcome {
            if !isRunningVoiceCommand { showToast(message, isError: true) }
            return .failed(message: message)
        }
        if intent.action == .generativeFill, !hasGenerativeEngine {
            return refuse(L("Install Generative Fill in Settings › On-device models to use prompts."))
        }
        if [.generativeFill, .upscale, .expandCanvas].contains(intent.action), !app.performance.allowsHeavyWork {
            return refuse(L("The iPhone is too hot for generation right now. Let it cool for a moment."))
        }
        let isHeavy = [.removeObject, .removeBackground, .blurBackground, .replaceBackground, .upscale, .selectiveAdjust, .chooseCandidate, .straighten, .generativeFill, .recolor,
                       .moveObject, .cleanUp, .expandCanvas, .textBehind, .autoCrop, .blurObject].contains(intent.action)
        if isHeavy {
            // One long step at a time (a tap during a spoken erase, a second chip…).
            guard !isProcessing else {
                let message = L("One moment…")
                if !isRunningVoiceCommand { showToast(message) }
                return .info(message: message)
            }
            isProcessing = true
            processingTitle = intent.action == .chooseCandidate ? L("Erasing…") : processingLabel(for: intent)
            Diagnostics.shared.note("run \(intent.action)")
            // Short of memory before a long step: previews go a size down until it recovers.
            if MemoryBudget.isLow { app.performance.constrainMemory() }
        }
        // Only the step that raised the flag lowers it.
        defer { if isHeavy { isProcessing = false } }
        let context = intentContext
        let base = document
        let (updated, result) = await executor.execute(intent, on: base, context: context)
        handle(result, updatedDocument: updated, intent: intent, base: base)
        if case .applied = result.outcome, intent.action == .adjust || intent.action == .selectiveAdjust, let parameter = intent.parameter {
            let direction: Int
            if let amount = intent.amount {
                switch amount.mode {
                case .relative: direction = amount.value >= 0 ? 1 : -1
                case .absolute: direction = amount.value >= context.currentAdjustments[parameter] ? 1 : -1
                case .multiplier: direction = amount.value >= 1 ? 1 : -1
                }
            } else {
                direction = 1
            }
            lastAdjustment = (parameter, direction)
        }
        return result.outcome
    }

    /// A command's result replayed onto what was committed while it ran. Only the
    /// operations it appended carry over, and only when the photo meanwhile got
    /// nothing but tonal steps (a slider, a look): a crop or an undo in between
    /// would put its mask in the wrong place, so then nil. Tone is applied after
    /// every other step, so tonal steps are left out of the comparison: a dial
    /// nudged again rewrites its last step in place.
    static func rebase(_ updated: PhotoDocument, from base: PhotoDocument, onto current: PhotoDocument) -> PhotoDocument? {
        guard updated.canvasSize == base.canvasSize, current.canvasSize == base.canvasSize,
              updated.layers.map(\.id) == base.layers.map(\.id) else { return nil }
        var result = current
        for (before, after) in zip(base.layers, updated.layers) {
            var untouched = after
            untouched.edits = before.edits
            guard untouched == before else { return nil }
            let old = before.edits.operations, new = after.edits.operations
            guard new.count >= old.count, Array(new.prefix(old.count)) == old else { return nil }
            let added = new.dropFirst(old.count)
            guard !added.isEmpty else { continue }
            guard let index = result.index(of: after.id) else { return nil }
            let now = result.layers[index].edits.operations
            guard now.filter({ !isTonal($0.kind) }) == old.filter({ !isTonal($0.kind) }) else { return nil }
            result.layers[index].edits.operations.append(contentsOf: added)
        }
        return result
    }

    private static func isTonal(_ kind: EditOperation.Kind) -> Bool {
        switch kind {
        case .adjust, .adjustments, .toneCurve, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut: return true
        default: return false
        }
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
        case .expandCanvas: return L("Imagining the edges…")
        case .moveObject: return String(format: L("Moving %@…"), intent.target?.originalPhrase ?? L("object"))
        case .cleanUp: return L("Finding the passers-by…")
        case .textBehind: return L("Lifting the subject…")
        case .autoCrop: return L("Trying framings…")
        case .blurObject: return String(format: L("Finding %@…"), intent.target?.originalPhrase ?? L("object"))
        case .straighten: return L("Levelling…")
        default: return L("Working…")
        }
    }

    /// - Parameter base: the document the command started from.
    private func handle(_ result: ExecutionResult, updatedDocument: PhotoDocument, intent: EditIntent, base: PhotoDocument) {
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            candidateOverlays = []
            var resultDocument = updatedDocument
            if base != document, updatedDocument != base {
                // Something else was committed while this ran: carry its new steps over, or drop it.
                guard let rebased = Self.rebase(updatedDocument, from: base, onto: document) else {
                    Diagnostics.shared.note("stale result dropped: \(label)")
                    if isRunningVoiceCommand { lastReplyIsProblem = true }
                    tell(L("The photo changed in the meantime. Try again."))
                    Haptics.warning()
                    return
                }
                resultDocument = rebased
            }
            let changed = resultDocument != document
            if changed {
                commit(resultDocument, label: label)
            }
            if !label.isEmpty { showToast(toastText(for: label), undoable: changed) }
            // The new title is ready to be rewritten or moved.
            if intent.action == .textBehind, changed { activeTool = .text }
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
                    // After the question has been spoken, so the microphone does not hear it.
                    if app.voice.state == .idle { app.voice.start(waitingForSpeech: true) }
                }
            }
        case .info(let message):
            lastOutcomeNeedsHand = result.effects.contains(.message("tapToErase")) || result.effects.contains(.message("selectRegion"))
            if !isRunningVoiceCommand { showToast(message) }
            if result.effects.contains(.message("tapToErase")) { activeTool = .erase }
            if result.effects.contains(.message("crop")) { activeTool = .crop }
        case .failed(let message):
            if !isRunningVoiceCommand { showToast(message, isError: true) }
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
            case .message("selectionUsed"): clearSelection()
            case .undo: undo()
            case .redo: redo()
            case .revert:
                if !revert() { tell(L("This is already the original photo.")) }
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
            case .pickColorReference:
                activeTool = .magic
                showsColorReferencePicker = true
            case .cancel:
                cancelClarification()
                showToast(L("Cancelled."))
            case .zoom(let amount, let target):
                zoomRequest = ZoomRequest(amount: amount, target: target)
            case .message(let message) where message.hasPrefix("version:"):
                handleVersionEffect(message)
            case .message(let message) where message.hasPrefix("style:"):
                handleStyleEffect(message)
            case .message("summary"):
                summarizeEdits(labels: history.past.map(\.label))
            case .message(let message) where message.hasPrefix("speak:"):
                VoiceFeedback.shared.speak(String(message.dropFirst(6)), language: language == .french ? "fr" : "en", force: true)
            default: break
            }
        }
    }

    // MARK: - Named versions

    /// Snapshots the user named by voice ("enregistre cette version sous brouillon").
    public private(set) var versions: [(name: String, state: PhotoDocument)] = []

    func handleVersionEffect(_ message: String) {
        let parts = message.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let requested = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        if parts[1] == "save" {
            let name = requested.isEmpty ? "v\(versions.count + 1)" : requested
            versions.removeAll { $0.name.lowercased() == name.lowercased() }
            versions.append((name, document))
            showToast(String(format: L("Version “%@” saved"), name))
            Haptics.success()
        } else if parts[1] == "restore" {
            let match = requested.isEmpty ? versions.last : versions.last { $0.name.lowercased() == requested.lowercased() } ?? versions.last { $0.name.lowercased().contains(requested.lowercased()) }
            guard let match else {
                showToast(versions.isEmpty ? L("No saved version yet. Say “save this version as …”.") : String(format: L("No version named “%@”"), requested), isError: true)
                return
            }
            restoreVersion(match.state, label: String(format: L("Version “%@”"), match.name))
        }
    }

    // MARK: - Styles

    /// The tonal recipe of the current photo.
    public var currentStyle: [EditOperation.Kind] {
        StyleLibrary.recipe(from: document.baseLayer?.edits ?? EditStack())
    }

    func handleStyleEffect(_ message: String) {
        let parts = message.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let requested = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        let french = language == .french
        if parts[1] == "save" {
            let name = requested.isEmpty ? String(format: L("Style %d"), app.styles.named.count + 1) : requested
            guard app.styles.save(currentStyle, as: name) else {
                showToast(french ? "Aucun réglage à enregistrer : ajuste d'abord la photo." : "Nothing to save yet: adjust the photo first.", isError: true)
                return
            }
            showToast(String(format: L("Style “%@” saved"), name))
            Haptics.success()
        } else if parts[1] == "apply" {
            let style: StyleLibrary.Style?
            if requested.isEmpty || requested == StyleLibrary.lastName {
                style = app.styles.style(named: StyleLibrary.lastName) ?? app.styles.named.first
            } else {
                style = app.styles.style(named: requested)
            }
            guard let style else {
                showToast(app.styles.styles.isEmpty ? L("No saved style yet. Say “save this style as …”.") : String(format: L("No style named “%@”"), requested), isError: true)
                return
            }
            applyStyle(style)
        }
    }

    public func applyStyle(_ style: StyleLibrary.Style) {
        var document = self.document
        for kind in style.operations { document.apply(kind) }
        let label = style.id == StyleLibrary.lastName ? L("Last photo's style") : String(format: L("Style “%@”"), style.name)
        commit(document, label: label)
        showToast(label)
        Haptics.success()
    }

    /// Spoken and shown recap of the edits made so far.
    func summarizeEdits(labels: [String]) {
        let french = language == .french
        let meaningful = labels.filter { !$0.isEmpty && $0 != "Select" }
        guard !meaningful.isEmpty else {
            let text = french ? "Tu n'as encore rien modifié." : "You haven't changed anything yet."
            showToast(text)
            VoiceFeedback.shared.speak(text, language: french ? "fr" : "en", force: true)
            return
        }
        var counts: [(String, Int)] = []
        for label in meaningful {
            if let index = counts.firstIndex(where: { $0.0 == label }) { counts[index].1 += 1 } else { counts.append((label, 1)) }
        }
        let parts = counts.suffix(8).map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }
        let list = parts.joined(separator: ", ")
        let text = french ? "\(meaningful.count) modification\(meaningful.count > 1 ? "s" : "") : \(list)." : "\(meaningful.count) edit\(meaningful.count > 1 ? "s" : ""): \(list)."
        showToast(text)
        VoiceFeedback.shared.speak(text, language: french ? "fr" : "en", force: true)
    }

    private func restoreVersion(_ state: PhotoDocument, label: String) {
        history.commit(state, label: label)
        requestPreview()
        showToast(label)
        Haptics.success()
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

    public func showToast(_ text: String, isError: Bool = false, undoable: Bool = false, action: Toast.Action? = nil) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = Toast(text: text, isError: isError, undoable: undoable, action: action) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(action != nil ? 6 : isError ? 3.5 : (undoable ? 4 : 2.2)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}
/// Orders project writes from the main actor and background tasks, so an older
/// snapshot never lands after a newer one.
final class ProjectWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0

    func write(sequence: Int, _ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > written else { return }
        body()
        written = sequence
    }
}

extension PhotoEditorSession: EditorStatus {
    /// The photo tasks report completion rather than a fraction.
    var processingProgress: Double? { nil }
    /// Work shimmers over the picture instead; export has its own HUD.
    var showsProcessingHUD: Bool { false }

    func performToastAction(_ action: Toast.Action) {
        switch action {
        case .rightWayUp: putRightWayUp()
        }
    }
}
#endif
