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
/// renders previews, and runs the command pipeline:
/// transcript → `HybridIntentRouter` → `PhotoCommandExecutor` → history → render.
///
/// Views never read `history`: they read the coarse mirrors below, brought up to
/// date by didChangeHistory() after every history write. A dial drag edits a
/// private copy of the document (read by the renderer and `dial` only) and
/// commits once, when it ends.
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
    /// Views never read it: they read the mirrors below.
    @ObservationIgnored public private(set) var history: EditHistory<PhotoDocument> {
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
    /// revert() would change the photo: also true on a reopened photo, whose earlier edits Undo cannot reach.
    public private(set) var canRevertToImport = false
    /// Bumped whenever the document changes (undo and redo included); Live's document version.
    public private(set) var revision = 0
    /// The tools whose edits are in the picture (Photos' yellow dot).
    public private(set) var modifiedTools: Set<Tool>
    /// The value of the dial being dragged; only the dial reads it.
    public let dial: DialValue
    /// Picshop Live in this editor, attached at the end of init.
    public let live: LiveSession
    /// True for the whole of a Live session: no toast for Live steps, no spoken reply, no recogniser start.
    /// Live grounds its steps on the table and the scene map: they are read as soon as it starts.
    @ObservationIgnored public var liveSpeechSuppressed = false {
        didSet { if liveSpeechSuppressed, !oldValue { prefetchSceneAnalysis() } }
    }
    @ObservationIgnored private var isTornDown = false
    /// > 0 while Live runs a step (liveRun, a chip, a choice, an undo): no toast, no speech.
    @ObservationIgnored var liveRunDepth = 0
    /// The effects the last executed step reported (Live reads needs_user hints from them).
    @ObservationIgnored var lastEffects: [EditorEffect] = []
    /// The heavy step running now; cancelProcessing() drops its result.
    @ObservationIgnored private var processingTask: Task<(PhotoDocument, ExecutionResult), Never>?
    @ObservationIgnored private var processingGeneration = 0
    @ObservationIgnored private var droppedGenerations: Set<Int> = []
    /// Undo and redo are not new steps: Live is told no label for them.
    @ObservationIgnored private var isStepping = false
    /// The dial being dragged: its label and its latest (absolute) edit. The
    /// document is committed once, when the drag ends; meanwhile the renderer
    /// draws `interactiveDocument`, the document with that edit applied.
    @ObservationIgnored private var interaction: (label: String, edit: ((inout PhotoDocument) -> Void)?)?
    @ObservationIgnored private var interactiveDocument: PhotoDocument?
    /// Live's picture: one JPEG per revision.
    @ObservationIgnored var snapshotCache: (revision: Int, image: LiveImage)?
    /// The wand's analysis pixels for one picture state (lookThumbnailKey).
    @ObservationIgnored private var wandAnalysis: (key: String, analysis: VisionGrounding.WandAnalysis)?
    /// Revision at the last thumbnail handed to the library.
    @ObservationIgnored private var thumbnailRevision = 0
    /// The photo as this session opened it: Revert starts from it, so layers added since go too.
    private let openedDocument: PhotoDocument

    public private(set) var renderer: PhotoRenderer?
    private var services: VisionPhotoServices?
    private var executor: PhotoCommandExecutor?

    public private(set) var preview: CIImage?
    @ObservationIgnored public private(set) var isRendering = false
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
    public var selectionMask: MaskReference? {
        didSet { if selectionMask != oldValue { live.noteContextChanged() } }
    }
    public var selectionPreview: CIImage?
    public var paintColor: PSColor = .white
    public var pixelBrushRadius: Double = 0.004
    /// Clone source (normalised) and the offset between source and destination.
    public var cloneSource: PSPoint?
    public var cloneOffset: PSPoint?
    public var generativePrompt = ""
    public var hasGenerativeEngine = false
    @ObservationIgnored public var lastTapPoint: PSPoint?
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
    public var pendingClarification: ClarificationRequest? {
        didSet { if pendingClarification != oldValue { live.noteContextChanged() } }
    }
    public var candidateOverlays: [ObjectCandidate] = []
    /// Main objects found in the picture, offered as one-tap erase targets.
    public var sceneObjects: [ObjectCandidate] = []
    /// The object tapped in the Magic tool, with its actions floating beside it.
    public var magicSelection: ObjectCandidate? {
        didSet { if magicSelection != oldValue { live.noteContextChanged() } }
    }
    /// What the picture is (people, sky, product…), so Magic can lead with what suits it.
    public var sceneDescription: SceneDescription? {
        didSet { if sceneDescription != oldValue { live.noteContextChanged() } }
    }
    /// The main table of the picture (canvas space, top-left), read once per base state when the
    /// picture has text or a remembered table (D7); nil when there is none or it is not read yet.
    /// Live and the grammar see it overlaid with Picshop's layers (`liveTable`).
    public private(set) var tableGrid: TableGrid? {
        didSet { if tableGrid != oldValue { live.noteContextChanged() } }
    }
    /// What the picture holds for the current base state (text blocks, objects, the table, free
    /// areas), without Picshop's text layers: Live and the grammar read it overlaid (`liveSceneMap`).
    public private(set) var sceneMap: SceneMap? {
        didSet { if sceneMap != oldValue { live.noteContextChanged() } }
    }
    /// The last table edit that applied: "les autres aussi" reuses its value (IntentContext.lastTableEdit).
    @ObservationIgnored var lastTableEdit: TableEditSpec?
    /// The last step that applied, by any lane: "encore", "pareil", "plus gros" start from it.
    @ObservationIgnored var lastIntent: EditIntent?
    /// The layers of the table step that just applied, flashed for a moment on the canvas (0.6 s).
    public private(set) var pulsingGroupID: UUID?
    /// Act-then-verify: where the check of the last result failed (a cell that does not read as
    /// written, text still there, an object still visible), ringed on the canvas for a moment so the
    /// person sees what to look at. Cleared by the next change.
    public private(set) var verificationMarks: [PSRect] = []
    /// The table step running now and how many cells it touches, for the spinner and Live's line
    /// ("Je remplis 45 cases…"); nil otherwise.
    public private(set) var cellWork: LiveCellWork?
    /// Where the running step works, for the shimmer over the picture: the table while a table step runs.
    public var workingRegion: PSRect? { cellWork != nil ? tableGrid?.bounds : nil }
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

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// The voice command running now; the next one waits for it.
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveDeadline = ContinuousClock.now
    @ObservationIgnored private var lastSavedDocument: PhotoDocument?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Parameter and direction of the most recent adjustment, so "a bit more" / "encore un peu" can refer to it.
    @ObservationIgnored public private(set) var lastAdjustment: (parameter: AdjustmentParameter, direction: Int)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var isConfigured = false
    /// Look thumbnails rendered for the current photo state (see `LooksPanel`).
    public var lookThumbnails: (key: String, images: [FilterPreset: UIImage])?
    /// Changes whenever the base photo's pixels change (crop, erase, look…), invalidating the thumbnails.
    /// Computed once per document change.
    public private(set) var lookThumbnailKey: String
    /// `document.baseStateKey`, brought up to date by didChangeHistory(): the table and the scene map
    /// belong to one base state and are read again when it changes.
    @ObservationIgnored private var baseStateKey: String
    /// The base states the scene map and the table were read for.
    @ObservationIgnored private var sceneMapKey: String?
    @ObservationIgnored private var tableGridKey: String?
    @ObservationIgnored private var isAnalysingScene = false
    /// The scene map overlaid with the text layers, once per revision: Live's state and the intent
    /// context share it, so the ids the model reads are the ids its steps resolve against.
    @ObservationIgnored private var overlaidScene: (revision: Int, stateKey: String, map: SceneMap)?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    /// > 0 while a result is checked (one render, one text pass): the scene analysis waits for it,
    /// as it waits for a long step, so two Vision passes never compete for memory.
    @ObservationIgnored private var verifyDepth = 0

    public init(document: PhotoDocument, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: document)
        self.document = document
        modifiedTools = Self.modifiedTools(in: document)
        lookThumbnailKey = Self.lookThumbnailKey(for: document, thumbnailSide: app.performance.thumbnailSide)
        baseStateKey = document.baseStateKey
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
        // Nor for the upscaler's model: it is handed over once located.
        let pipeline = InpaintingPipeline()
        let renderer = PhotoRenderer(store: app.store, projectID: projectID, inpainting: pipeline)
        self.renderer = renderer
        let services = VisionPhotoServices(renderer: renderer, store: app.store, projectID: projectID)
        self.services = services
        executor = PhotoCommandExecutor(services: services, language: language)
        isVoiceReady = true
        lastSavedDocument = document
        canRevertToImport = differsFromImport()
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
        Task { [environment = app] in
            let upscaler = await environment.makeUpscaler()
            await renderer.setUpscaler(upscaler)
        }
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
        Diagnostics.shared.note("photo editor teardown")
        // A drag cut short by the close still counts.
        if interaction != nil { endInteraction() }
        live.teardown()
        app.voice.cancel()
        renderTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        save()
    }

    /// Saves off the main thread (the library orders the writes), and hands the
    /// library the new thumbnail, rendered off the main thread too: Home shows it
    /// at once, with no blank in between.
    public func save() {
        autosaveTask?.cancel()
        autosaveTask = nil
        let modifiedAt = Date()
        let library = app.library
        if document != lastSavedDocument {
            let project = Project(id: projectID, content: .photo(document), createdAt: document.createdAt, modifiedAt: modifiedAt)
            lastSavedDocument = document
            Task { await library.persist(project) }
        }
        app.styles.rememberLast(currentStyle)
        guard let renderer, revision != thumbnailRevision else { return }
        thumbnailRevision = revision
        let saved = document
        let id = projectID
        Task.detached(priority: .utility) {
            guard let image = try? await renderer.render(saved, options: .thumbnail) else { return }
            let background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: image.extent)
            guard let cgImage = ImageSupport.cgImage(from: image.composited(over: background)) else { return }
            let thumbnail = UIImage(cgImage: cgImage)
            await MainActor.run { library.setThumbnail(thumbnail, for: id, modifiedAt: modifiedAt) }
        }
    }

    // MARK: - Autosave

    /// Saves ~0.8 s after the last change, so a crash or a kill loses at most that
    /// much. Written off the main actor; the library orders it with every other write.
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
        let project = Project(id: projectID, content: .photo(document), createdAt: document.createdAt, modifiedAt: Date())
        let library = app.library
        if synchronously {
            // Going to the background: this must land before the app is suspended.
            library.saveNow(project)
        } else {
            Task { await library.persist(project) }
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
                      selectionMask: selectionMask, table: liveTable, lastTableEdit: lastTableEdit, scene: liveSceneMap, lastIntent: lastIntent)
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

    @ObservationIgnored private var dirtyInteractive = false
    @ObservationIgnored private var renderGeneration = 0

    /// What the canvas shows: the dragged copy during a dial drag, with the crop tool's pending geometry.
    private func previewDocument() -> PhotoDocument {
        var document = interactiveDocument ?? self.document
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
            if !isRendering { isRendering = true }
            defer { if renderGeneration == generation, isRendering { isRendering = false } }
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

    /// The one place the mirrors are brought up to date, after every write to
    /// `history` (commit, undo, redo, revert, versions, styles, a rebased result,
    /// transactions): each is assigned only when its value changes, then Live is told.
    private func didChangeHistory() {
        let present = history.present
        let documentChanged = present != document
        let labels = history.past.map(\.label)
        // A new step (not an undo or a redo): the list grew, or at the limit its oldest entry went.
        let isNewStep = !isStepping && !history.canRedo && labels != undoLabels
            && (labels.count > undoLabels.count || labels.count == history.limit)
        var changed = documentChanged
        if documentChanged { document = present }
        if canUndo != history.canUndo { canUndo = history.canUndo; changed = true }
        if canRedo != history.canRedo { canRedo = history.canRedo; changed = true }
        if labels != undoLabels { undoLabels = labels; changed = true }
        if documentChanged {
            revision += 1
            let revertible = differsFromImport()
            if revertible != canRevertToImport { canRevertToImport = revertible }
            let tools = Self.modifiedTools(in: present)
            if tools != modifiedTools { modifiedTools = tools }
            let key = Self.lookThumbnailKey(for: present, thumbnailSide: app.performance.thumbnailSide)
            if key != lookThumbnailKey { lookThumbnailKey = key }
            let baseKey = present.baseStateKey
            if baseKey != baseStateKey { baseStateDidChange(to: baseKey) }
            // The rings of a failed check belong to the result they checked: an undo or a new step takes them away.
            if !verificationMarks.isEmpty { clearVerificationMarks() }
            // A step landed under a dial drag (a voice edit, an erase finishing): the drag carries on over it.
            if let edit = interaction?.edit {
                var working = present
                edit(&working)
                interactiveDocument = working
            } else if interaction != nil {
                interactiveDocument = present
            }
        }
        // A text drag is one change, told when it ends.
        guard changed, !history.isInTransaction else { return }
        live.noteDocumentChanged(label: isNewStep ? history.undoLabel : nil)
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
        if interaction != nil { endInteraction() }
        magicSelection = nil
        isStepping = true
        let label = history.undo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        requestPreview()
    }

    /// Goes back several steps at once (the History list): one refresh, one toast.
    /// Returns the labels undone, newest first.
    @discardableResult
    public func undo(steps: Int) -> [String] {
        guard steps > 0, history.canUndo else { return [] }
        if interaction != nil { endInteraction() }
        magicSelection = nil
        var labels: [String] = []
        isStepping = true
        for _ in 0..<steps where history.canUndo {
            if let label = history.undo() { labels.append(label) }
        }
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(labels.last.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        requestPreview()
        return labels
    }

    /// Returns the label redone, nil when there was nothing to redo.
    @discardableResult
    public func redo() -> String? {
        guard history.canRedo else { return nil }
        if interaction != nil { endInteraction() }
        isStepping = true
        let label = history.redo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo")) }
        requestPreview()
        return label
    }

    /// Back to the photo as imported, including edits saved in earlier
    /// sessions — which Undo cannot reach — and without the layers added since
    /// this session opened. Itself undoable. False when there was nothing to revert.
    @discardableResult
    public func revert() -> Bool {
        guard differsFromImport() else { return false }
        commit(openedDocument.restoredToImport(), label: L("Revert to Original"))
        // Follow-ups start afresh: "les autres aussi" has nothing to follow.
        lastTableEdit = nil
        lastIntent = nil
        Haptics.confirm()
        return true
    }

    /// Whether the photo differs from the import revert() goes back to (the date and the selection do not count).
    private func differsFromImport() -> Bool {
        var compared = openedDocument.restoredToImport()
        compared.modifiedAt = document.modifiedAt
        compared.selectedLayerID = document.selectedLayerID
        return compared != document
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
        beginInteraction(label: parameter.englishName)
        setDial(parameter: parameter, group: nil, value: document.activeAdjustments[parameter])
    }

    public func endSliderInteraction() {
        endInteraction()
    }

    public func setAdjustment(_ parameter: AdjustmentParameter, value: Double) {
        guard let layerID = document.activeImageLayerID else { return }
        let previous = (interactiveDocument ?? document).activeAdjustments[parameter]
        if abs(value - previous) > 0.0005 { lastAdjustment = (parameter, value > previous ? 1 : -1) }
        if interaction != nil { setDial(parameter: parameter, group: nil, value: value) }
        interactiveEdit(label: parameter.englishName) { document in
            document.update(layerID: layerID) { $0.edits.setAdjustment(parameter, value: value) }
        }
    }

    // MARK: - Dial drags

    /// Starts a drag: the document stays as it is until the drag ends.
    private func beginInteraction(label: String) {
        if interaction != nil, interactiveDocument != document { endInteraction() }
        interaction = (label, nil)
        interactiveDocument = document
    }

    /// Applies a dial's latest value: to the dragged copy during a drag (the
    /// renderer and the dial see it, nothing else), else as one committed step.
    private func interactiveEdit(label: String, _ edit: @escaping (inout PhotoDocument) -> Void) {
        guard interaction != nil else {
            var updated = document
            edit(&updated)
            guard updated != document else { return }
            commit(updated, label: label)
            return
        }
        interaction = (label, edit)
        var working = document
        edit(&working)
        interactiveDocument = working
        requestPreview(interactive: true)
    }

    /// Ends a drag: one commit (one undo step, one revision, one note to Live).
    private func endInteraction() {
        guard let current = interaction else {
            setDial(parameter: nil, group: nil, value: dial.value)
            requestPreview()
            return
        }
        let working = interactiveDocument
        interaction = nil
        interactiveDocument = nil
        setDial(parameter: nil, group: nil, value: dial.value)
        if let working, working != document {
            commit(working, label: current.label)
        } else {
            requestPreview()
        }
    }

    /// The dial's leaf reads these; each is assigned only when it changes.
    private func setDial(parameter: AdjustmentParameter?, group: String?, value: Double) {
        if dial.parameter != parameter { dial.parameter = parameter }
        if dial.group != group { dial.group = group }
        if dial.value != value { dial.value = value }
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

    public func beginApertureInteraction() {
        beginInteraction(label: "Aperture")
        setDial(parameter: nil, group: "aperture", value: focusAperture)
    }

    public func endApertureInteraction() {
        endInteraction()
    }

    public func setAperture(_ aperture: Double) {
        guard let baseID = document.baseLayerID, let lens = document.baseLayer?.edits.resolvedLensBlur ?? document.baseLayer?.edits.operations.reversed().compactMap({ operation -> (focus: PSPoint, aperture: Double, mask: MaskReference?)? in
            if case .lensBlur(let focus, let aperture, let mask) = operation.kind { return (focus, aperture, mask) }
            return nil
        }).first else { return }
        if interaction != nil { setDial(parameter: nil, group: "aperture", value: aperture) }
        interactiveEdit(label: "Aperture") { document in
            document.update(layerID: baseID) { $0.edits.setColor(.lensBlur(focus: lens.focus, aperture: aperture, mask: lens.mask)) }
        }
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

    public func beginColorInteraction(_ label: String) {
        beginInteraction(label: label)
    }

    public func endColorInteraction() {
        endInteraction()
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

    public func setColorMixer(_ mixer: ColorMixer) {
        if interaction != nil { setDial(parameter: nil, group: "colorMixer", value: dial.value) }
        setColor(.colorMixer(mixer), label: "Colour Mixer")
    }

    public func setColorGrade(_ grade: ColorGrade) {
        if interaction != nil { setDial(parameter: nil, group: "colorGrade", value: dial.value) }
        setColor(.colorGrade(grade), label: "Colour Grading")
    }

    private func setColor(_ kind: EditOperation.Kind, label: String) {
        guard let layerID = document.activeImageLayerID else { return }
        interactiveEdit(label: label) { document in
            document.update(layerID: layerID) { $0.edits.setColor(kind) }
        }
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
        guard let look = document.baseLayer?.edits.resolvedLook, let layerID = document.activeImageLayerID else { return }
        // The looks dial starts its drag as an adjustment: it is the look's own dial.
        if interaction != nil { setDial(parameter: nil, group: "look", value: intensity) }
        interactiveEdit(label: "Look Intensity") { document in
            document.update(layerID: layerID) { layer in
                if let last = layer.edits.operations.last, case .look = last.kind {
                    layer.edits.operations[layer.edits.operations.count - 1] = EditOperation(id: last.id, kind: .look(look.preset, intensity: intensity), createdAt: last.createdAt, label: last.label)
                } else {
                    layer.edits.append(.look(look.preset, intensity: intensity))
                }
            }
        }
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
        // With the description known (text or not), the scene map and the table, off this task
        // so the objects row does not wait for them.
        Task { [weak self] in await self?.loadSceneAnalysis() }
    }

    // MARK: - What the picture holds (scene map, table) and act-then-verify

    /// The base picture changed (an erase, a crop, a look): what was read from it no longer holds.
    /// While Live is on it is read again at once, since Live grounds its next step on it.
    private func baseStateDidChange(to key: String) {
        baseStateKey = key
        // An undo can bring back a state read before: it is read again (the services' cache answers).
        // The last map and table stay until the new read lands, so "le titre", the texts: and table: lines and
        // "la case à droite" keep working meanwhile: the executor re-reads a stale map (`currentScene` compares
        // state keys, carrying the ids over) and always re-detects the table, and `liveSceneMap` drops the
        // printed blocks an erase covered.
        sceneMapKey = nil
        tableGridKey = nil
        if liveSpeechSuppressed { prefetchSceneAnalysis() }
    }

    /// Live starts, or the picture changed under it: the objects and the description, then the scene
    /// map and the table, in the background (each once per state).
    private func prefetchSceneAnalysis() {
        guard isConfigured, !isTornDown else { return }
        Task { [weak self] in
            await self?.loadSceneObjects()
            await self?.loadSceneAnalysis()
        }
    }

    /// Reads the scene map, and the table when the picture may hold one, for the current base state:
    /// once per state (the services cache them too, off the main actor), after any long step or
    /// render, since Vision next to them competes for memory. A state that changes meanwhile is read
    /// again; what was read for an older one is dropped.
    func loadSceneAnalysis() async {
        guard let services, !isAnalysingScene else { return }
        isAnalysingScene = true
        defer { isAnalysingScene = false }
        while !Task.isCancelled, !isTornDown {
            let key = document.baseStateKey
            let needsMap = sceneMapKey != key
            let needsTable = tableGridKey != key && wantsTable
            guard needsMap || needsTable else { return }
            while isProcessing || isRendering || verifyDepth > 0 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !isTornDown else { return }
            }
            let analysed = document
            guard analysed.baseStateKey == key else { continue }
            if needsMap {
                let map: SceneMap? = try? await services.sceneMap(in: analysed)
                guard key == document.baseStateKey else { continue }
                sceneMapKey = key
                sceneMap = map
            }
            if tableGridKey != key, wantsTable {
                let grid: TableGrid? = try? await services.tableGrid(in: analysed, remembered: analysed.rememberedTable)
                guard key == document.baseStateKey else { continue }
                tableGridKey = key
                tableGrid = grid ?? sceneMap?.table
            }
        }
    }

    /// Worth a look for a table: text in the picture, or a table remembered from before its values were erased.
    private var wantsTable: Bool {
        sceneDescription?.hasText == true || document.tableMemory != nil || sceneMap?.table != nil || sceneMap?.texts.isEmpty == false
    }

    /// The main table overlaid with Picshop's layers (cells a fill wrote read as `.layer`): what Live's
    /// state shows and what the grammar and the model's steps resolve against.
    var liveTable: TableGrid? {
        tableGrid?.overlaying(document.layers)
    }

    /// The scene map overlaid with Picshop's text layers (`l<n>`), one per revision, the ids of the
    /// previous one carried over: Live's state and the intent context read the same map.
    var liveSceneMap: SceneMap? {
        guard var base = sceneMap else { return nil }
        if let cached = overlaidScene, cached.revision == revision, cached.stateKey == base.stateKey { return cached.map }
        // Read before the last erase: the printed blocks an erase covered (half of them or more) are gone from
        // the picture, so neither the model nor the grammar sees them until the new read lands.
        if base.stateKey != document.baseStateKey {
            let erased = (document.baseLayer?.edits.operations ?? []).compactMap { operation -> PSRect? in
                if case .removeObject(let mask) = operation.kind { return mask.boundingBox }
                return nil
            }
            if !erased.isEmpty {
                base.texts.removeAll { block in !block.isLayer && erased.contains { $0.intersection(block.box).area >= block.box.area * 0.5 } }
            }
        }
        var overlaid = base.overlaying(document.layers)
        if let previous = overlaidScene?.map { overlaid = overlaid.carryingIDs(from: previous) }
        overlaidScene = (revision, base.stateKey, overlaid)
        return overlaid
    }

    /// Act-then-verify: the services look at the committed picture once for every request (one render,
    /// one text pass, the detectors over the erased places only). Where a check failed is ringed on
    /// the canvas while the picture is still the one checked. Empty when they cannot look; never
    /// changes the document. Live batches a run's requests into one call (`liveVerify`); the command
    /// path checks after its reply (`checkInBackground`).
    func checkResult(_ requests: [VerificationRequest]) async -> [VerificationReport] {
        guard !requests.isEmpty, let services, !isTornDown else { return [] }
        let checked = document
        let checkedRevision = revision
        verifyDepth += 1
        defer { verifyDepth -= 1 }
        let reports = (try? await services.verify(requests, in: checked)) ?? []
        let failed = reports.filter { $0.status == .failed }
        for report in failed { Diagnostics.shared.note("verify \(report.action.rawValue): \(report.summary)") }
        if revision == checkedRevision {
            showVerificationMarks(failed.flatMap { $0.failures.map(\.check.region) })
        }
        return reports
    }

    /// The command path (outside Live): its reply is already out, so the check runs after it, off the
    /// command's way. Only a failure shows: the honest line in a toast with Undo, the places ringed.
    private func checkInBackground(_ requests: [VerificationRequest], language: NormalizedUtterance.Language) {
        guard !requests.isEmpty else { return }
        let checkedRevision = revision
        Task { [weak self] in
            guard let self else { return }
            let reports = await self.checkResult(requests)
            guard self.revision == checkedRevision, !self.isQuiet,
                  let failed = reports.first(where: { $0.status == .failed }) else { return }
            self.showToast(LiveLines.verification(failed, language), undoable: self.canUndo)
            Haptics.warning()
        }
    }

    /// Rings the places a check found wrong for 3 s (at most 60).
    private func showVerificationMarks(_ regions: [PSRect]) {
        marksTask?.cancel()
        let marks = Array(regions.prefix(60))
        guard !marks.isEmpty else {
            if !verificationMarks.isEmpty { verificationMarks = [] }
            return
        }
        withAnimation(PSMotion.quick) { verificationMarks = marks }
        marksTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.verificationMarks = [] }
        }
    }

    private func clearVerificationMarks() {
        marksTask?.cancel()
        marksTask = nil
        verificationMarks = []
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
            // A table cell keeps its address as its name ("Agentic coding · Opus 5"); editing it edits only it.
            if layer.group == nil { layer.name = element.text }
        }
        history.commit(document, label: "Edit Text")
        requestPreview(interactive: true)
    }

    // MARK: - Layer groups (a table's cells, a highlight's boxes)

    /// Shows or hides every layer of a group (a table's cells) in one step.
    public func setGroupVisible(_ groupID: UUID, _ visible: Bool) {
        var document = self.document
        let members = document.layers.filter { $0.group?.id == groupID && $0.isVisible != visible }.map(\.id)
        guard !members.isEmpty else { return }
        for id in members { document.update(layerID: id) { $0.isVisible = visible } }
        history.commit(document, label: "Layer")
        requestPreview()
    }

    /// Deletes every layer of a group in one step: one undo brings them all back.
    public func removeGroup(_ groupID: UUID) {
        var document = self.document
        guard document.removeLayers(inGroup: groupID) > 0 else { return }
        commit(document, label: "Delete Layer")
        Haptics.warning()
    }

    /// Selects a group through its first layer: "plus gros", "en rouge" then apply to the whole table
    /// (the executor widens an edit on a cell layer to its group); a cell tapped alone edits only itself.
    public func selectGroup(_ groupID: UUID) {
        guard let first = document.layers.first(where: { $0.group?.id == groupID }) else { return }
        if document.selectedLayerID != first.id { selectLayer(first.id) }
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

    /// Magic-wand selection at a point on the rendered base image. The picture is
    /// rendered without expensive work and read back once per picture state; the
    /// flood fill, the despeckle and the PNG write run off the main thread.
    public func magicWandSelect(at point: PSPoint) {
        guard let renderer else { return }
        let key = lookThumbnailKey
        let cached = wandAnalysis?.key == key ? wandAnalysis?.analysis : nil
        let document = self.document
        let tolerance = wandTolerance, contiguous = wandContiguous
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        Task { [weak self] in
            do {
                let analysis: VisionGrounding.WandAnalysis
                if let cached {
                    analysis = cached
                } else {
                    let image = try await renderer.renderBase(document, options: PhotoRenderer.Options(targetLongestSide: 1536, allowExpensiveWork: false))
                    guard let read = await Task.detached(priority: .userInitiated, operation: { () -> VisionGrounding.WandAnalysis? in
                        ImageSupport.cgImage(from: image).map(VisionGrounding.wandAnalysis(of:))
                    }).value else { return }
                    analysis = read
                    self?.wandAnalysis = (key, read)
                }
                let selection = try await Task.detached(priority: .userInitiated) {
                    try VisionGrounding.magicWandSelection(in: analysis, seed: point, tolerance: tolerance, contiguous: contiguous, maskStore: maskStore)
                }.value
                self?.setSelection(selection)
                Haptics.confirm()
            } catch {
                self?.showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func commitLasso() {
        guard lassoPoints.count >= 3 else { return }
        let points = lassoPoints
        let size = document.canvasSize
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        lassoPoints = []
        Task { [weak self] in
            let selection = try? await Task.detached(priority: .userInitiated) {
                try VisionGrounding.lassoSelection(imageSize: size, points: points, maskStore: maskStore)
            }.value
            guard let selection else { return }
            self?.setSelection(selection)
            Haptics.confirm()
        }
    }

    /// The selection, and its tint on the canvas built from the bytes in memory.
    private func setSelection(_ selection: VisionGrounding.SelectionResult) {
        selectionMask = selection.reference
        guard let preview, let mask = ImageSupport.ciImage(gray: selection.bytes, width: selection.width, height: selection.height) else { return }
        let extent = preview.extent
        let fitted = mask.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(selection.width), y: extent.height / CGFloat(selection.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let tint = CIImage(color: CIColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 0.45)).cropped(to: extent)
        selectionPreview = AdjustmentPipeline.applyingAlpha(mask: fitted, to: tint)
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
        if lastTapPoint != point {
            lastTapPoint = point
            // "Efface ça" points here: Live hears of it.
            live.noteContextChanged()
        }
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
        var plan = await app.router.plan(text, context: intentContext)
        // What is shown and said never carries an internal word (D11), whichever brain planned it.
        let replyLanguage = plan.language.flatMap(NormalizedUtterance.Language.init(rawValue:)) ?? language
        plan.reply = plan.reply.map { LiveSpeechSanitizer.clean($0, language: replyLanguage) }
        plan.clarification = plan.clarification.map { LiveSpeechSanitizer.clean($0, language: replyLanguage) }
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            lastPlan?.reply = reply
            lastReplyIsProblem = true
            if !isQuiet {
                // Through Live's composer the reply capsule says it; the suggestions follow in a toast.
                let suggestions = Replies.suggestions(for: .photo, language: language)
                showToast(repliesInCapsule ? suggestions : reply + "\n" + suggestions, isError: true)
            }
            speak(reply, language: plan.language)
            return
        }
        // The grammar's own question ("Quelle case ?", "Avec quoi ?") comes before any table step it could only
        // guess: a table step below the fast lane's confidence is never run with its question pending.
        if let clarification = plan.clarification,
           plan.intents.allSatisfy({ $0.action == .unknown || (IntentNormalizer.tableActions.contains($0.action) && $0.confidence < 0.9) }) {
            lastPlan?.reply = clarification
            if !isQuiet, !repliesInCapsule { showToast(clarification) }
            speak(clarification, language: plan.language)
            return
        }
        // What has to be found in the picture is confirmed once it is found, never before.
        let mustFindFirst = plan.intents.contains { Self.findsBeforeActing.contains($0.action) }
        if !mustFindFirst { speak(plan.reply ?? "", language: plan.language) }
        isRunningVoiceCommand = true
        defer { isRunningVoiceCommand = false }
        var told: String?
        /// Act-then-verify: what the applied steps should show, checked once the reply is out.
        var checks: [VerificationRequest] = []
        defer { checkInBackground(checks, language: replyLanguage) }
        steps: for intent in plan.intents where intent.action != .unknown {
            lastOutcomeNeedsHand = false
            let step = await runStep(intent)
            if let request = step.verification { checks.append(request) }
            switch step.outcome {
            case .info(let message):
                told = message
                lastReplyIsProblem = lastOutcomeNeedsHand
            case .failed(let message):
                told = message
                lastReplyIsProblem = true
                lastReplyIsError = true
                break steps
            case .needsClarification(let request):
                // The question is the reply; the numbered choices show under it.
                lastPlan?.reply = LiveSpeechSanitizer.clean(request.question, language: replyLanguage)
                replyID = UUID()
                return
            case .applied, .ignored:
                continue
            }
        }
        if let told {
            // The reply says what really happened, not what was hoped for, and shows it afresh,
            // never with an internal word in it (D11).
            let line = LiveSpeechSanitizer.clean(told, language: replyLanguage)
            lastPlan?.reply = line
            replyID = UUID()
            speak(line, language: plan.language)
        } else if mustFindFirst {
            speak(plan.reply ?? "", language: plan.language)
        }
    }

    /// The last command handed over to the finger (tap or lasso what was not found).
    @ObservationIgnored private var lastOutcomeNeedsHand = false

    /// A command typed or dictated through Live's composer: its reply shows in Live's capsule.
    @ObservationIgnored var repliesInCapsule = false

    /// Live runs this step, or a Live conversation is on: Live says what happened, the editor stays quiet.
    var isQuiet: Bool { liveRunDepth > 0 || liveSpeechSuppressed }

    /// Spoken replies outside Live only.
    private func speak(_ text: String, language: String?, force: Bool = false) {
        guard !isQuiet, !text.isEmpty else { return }
        VoiceFeedback.shared.speak(text, language: language, force: force)
    }

    /// Says what happened: in the reply during a command, in a toast otherwise, and nothing while Live tells it.
    private func tell(_ message: String) {
        if isRunningVoiceCommand {
            lastPlan?.reply = message
            replyID = UUID()
        } else if !isQuiet {
            showToast(message)
        }
    }

    /// History labels are English keys (DYNAMIC_KEYS); "Remove …" carries the target as it was said.
    private func toastText(for label: String) -> String {
        let localized = LD(label)
        guard psPrefersFrench, localized == label, label.hasPrefix("Remove ") else { return localized }
        return String(format: L("Erase %@"), String(label.dropFirst("Remove ".count)))
    }

    /// "45 cells filled": what a table step did, in the toast with Undo.
    private func tableToast(_ report: TableEditReport) -> String {
        let count = report.changed
        switch report.action {
        case .clearCells: return count == 1 ? L("1 cell cleared") : String(format: L("%d cells cleared"), count)
        case .highlightCells: return count == 1 ? L("1 cell highlighted") : String(format: L("%d cells highlighted"), count)
        default: return count == 1 ? L("1 cell filled") : String(format: L("%d cells filled"), count)
        }
    }

    /// The layers of a table step flash for 0.6 s (the canvas reads `pulsingGroupID`).
    private func pulse(group: UUID) {
        pulseTask?.cancel()
        pulsingGroupID = group
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.pulsingGroupID == group else { return }
            self.pulsingGroupID = nil
        }
    }

    private static let findsBeforeActing: Set<IntentAction> = [.removeObject, .moveObject, .blurObject, .recolor, .generativeFill, .selectiveAdjust, .cleanUp, .chooseCandidate]

    /// Drops the heavy step that is running, if any: its result is discarded when it
    /// arrives (the service may finish in the background), and the editor is free
    /// at once. True when something was running.
    @discardableResult
    public func cancelProcessing() -> Bool {
        guard isProcessing, processingTask != nil else { return false }
        droppedGenerations.insert(processingGeneration)
        processingTask = nil
        isProcessing = false
        cellWork = nil
        Diagnostics.shared.note("processing cancelled")
        return true
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        await runStep(intent).outcome
    }

    /// run(_:), with the checks its result deserves (act-then-verify): what the rendered picture should
    /// show after the step, from the documents before and after it and the scene map it was planned
    /// on (`EditVerifier.request`). Nil when the step did not apply or there is nothing to look at.
    func runStep(_ intent: EditIntent) async -> (outcome: CommandOutcome, verification: VerificationRequest?) {
        lastEffects = []
        guard var executor else { return (outcome: .failed(message: L("Still getting ready — try again in a moment.")), verification: nil) }
        executor.language = language
        func refuse(_ message: String) -> CommandOutcome {
            if !isRunningVoiceCommand, !isQuiet { showToast(message, isError: true) }
            return .failed(message: message)
        }
        if intent.action == .generativeFill, !hasGenerativeEngine {
            return (outcome: refuse(L("Install Generative Fill in Settings › On-device models to use prompts.")), verification: nil)
        }
        if [.generativeFill, .upscale, .expandCanvas].contains(intent.action), !app.performance.allowsHeavyWork {
            return (outcome: refuse(L("The iPhone is too hot for generation right now. Let it cool for a moment.")), verification: nil)
        }
        // Table steps may read the picture first (one OCR pass); a printed block is erased before it is rewritten.
        let isHeavy = [.removeObject, .removeBackground, .blurBackground, .replaceBackground, .upscale, .selectiveAdjust, .chooseCandidate, .straighten, .generativeFill, .recolor,
                       .moveObject, .cleanUp, .expandCanvas, .textBehind, .autoCrop, .blurObject,
                       .fillCells, .clearCells, .highlightCells, .eraseRegion, .moveText].contains(intent.action) || Self.erasesPrintedText(intent)
        var generation: Int?
        if isHeavy {
            // One long step at a time (a tap during a spoken erase, a second chip…).
            guard !isProcessing else {
                let message = L("One moment…")
                if !isRunningVoiceCommand, !isQuiet { showToast(message) }
                return (outcome: .info(message: message), verification: nil)
            }
            // A drag in progress is committed first: the step starts from what is on screen.
            if interaction != nil { endInteraction() }
            isProcessing = true
            // A table step says how many cells it is about to touch, read on the table as it is shown.
            let work = plannedCellWork(intent)
            cellWork = work
            processingTitle = intent.action == .chooseCandidate ? L("Erasing…") : processingLabel(for: intent, cells: work?.count)
            processingGeneration += 1
            generation = processingGeneration
            Diagnostics.shared.note("run \(intent.action)")
            // Short of memory before a long step: previews go a size down until it recovers.
            if MemoryBudget.isLow { app.performance.constrainMemory() }
        }
        // Only the step that raised the flag lowers it, unless it was dropped and another began.
        defer {
            if let generation, generation == processingGeneration {
                if isProcessing { isProcessing = false }
                if cellWork != nil { cellWork = nil }
            }
        }
        let context = intentContext
        let base = document
        let updated: PhotoDocument
        let result: ExecutionResult
        if let generation {
            // Held in a task so cancelProcessing() can let go of it.
            let running = executor
            let task = Task { await running.execute(intent, on: base, context: context) }
            processingTask = task
            (updated, result) = await task.value
            if processingTask == task { processingTask = nil }
            if droppedGenerations.remove(generation) != nil {
                Diagnostics.shared.note("dropped result: \(intent.action)")
                return (outcome: .failed(message: L("Cancelled.")), verification: nil)
            }
        } else {
            (updated, result) = await executor.execute(intent, on: base, context: context)
        }
        let outcome = handle(result, updatedDocument: updated, intent: intent, base: base)
        var verification: VerificationRequest?
        if case .applied = outcome {
            let ran = Self.stepAsRun(intent, context: context)
            remember(ran)
            // After: what was committed (a result carried over a change made meanwhile included).
            verification = EditVerifier.request(for: ran, before: base, after: document, result: result, scene: context.scene)
        }
        if case .applied = outcome, intent.action == .adjust || intent.action == .selectiveAdjust, let parameter = intent.parameter {
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
        return (outcome: outcome, verification: verification)
    }

    static let tableActions: Set<IntentAction> = [.fillCells, .clearCells, .highlightCells]

    /// editText or removeText on a printed block ("t3") erase its pixels first: a long step.
    private static func erasesPrintedText(_ intent: EditIntent) -> Bool {
        guard intent.action == .editText || intent.action == .removeText, case .text(_)? = intent.ref else { return false }
        return true
    }

    /// The step as it ran: a choice among candidates runs the question's pending step (its checks
    /// keep the id of the step Live ran).
    private static func stepAsRun(_ intent: EditIntent, context: IntentContext) -> EditIntent {
        guard intent.action == .chooseCandidate, var pending = context.pendingClarification?.pendingIntent else { return intent }
        pending.id = intent.id
        return pending
    }

    /// Follow-ups start from what last applied: the step ("encore", "pareil", "plus gros") and the
    /// table edit ("les autres aussi"). A table spec that names no value (a clear, a highlight)
    /// keeps the value of the fill before it.
    private func remember(_ intent: EditIntent) {
        guard !intent.action.isMeta, intent.action != .revert, intent.action != .export, intent.action != .share else { return }
        lastIntent = intent
        guard Self.tableActions.contains(intent.action), var spec = intent.table else { return }
        if spec.value == nil {
            spec.value = lastTableEdit?.value
            spec.alternative = spec.alternative ?? lastTableEdit?.alternative
        }
        lastTableEdit = spec
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

    /// How many cells a table step is about to touch, on the table as the editor shows it (nil when
    /// the table is not read yet or the step names nothing there: the executor answers that itself).
    private func plannedCellWork(_ intent: EditIntent) -> LiveCellWork? {
        guard Self.tableActions.contains(intent.action) else { return nil }
        guard let spec = intent.table, let grid = liveTable else { return LiveCellWork(action: intent.action, count: nil) }
        let count: Int?
        switch intent.action {
        case .fillCells:
            count = (try? TableSelection.cells(for: spec, in: grid))?.count
        case .clearCells:
            count = (try? TableSelection.scope(for: spec, in: grid))?.filter { $0.state == .printed || $0.state == .layer }.count
        default:
            count = nil
        }
        return LiveCellWork(action: intent.action, count: count.flatMap { $0 > 0 ? $0 : nil })
    }

    private func processingLabel(for intent: EditIntent, cells: Int? = nil) -> String {
        switch intent.action {
        case .fillCells:
            guard let cells else { return L("Filling the table…") }
            return cells == 1 ? L("Filling 1 cell…") : String(format: L("Filling %d cells…"), cells)
        case .clearCells:
            guard let cells else { return L("Clearing cells…") }
            return cells == 1 ? L("Clearing 1 cell…") : String(format: L("Clearing %d cells…"), cells)
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
        case .highlightCells: return L("Highlighting…")
        case .eraseRegion, .removeText: return L("Erasing…")
        case .moveText: return L("Moving the text…")
        case .editText: return L("Rewriting the text…")
        default: return L("Working…")
        }
    }

    /// Lands an executor's result and returns what really happened: a result
    /// dropped because the photo changed meanwhile comes back as failed.
    /// - Parameter base: the document the command started from.
    @discardableResult
    private func handle(_ result: ExecutionResult, updatedDocument: PhotoDocument, intent: EditIntent, base: PhotoDocument) -> CommandOutcome {
        lastEffects = result.effects
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            candidateOverlays = []
            var resultDocument = updatedDocument
            if base != document, updatedDocument != base {
                // Something else was committed while this ran: carry its new steps over, or drop it.
                guard let rebased = Self.rebase(updatedDocument, from: base, onto: document) else {
                    Diagnostics.shared.note("stale result dropped: \(label)")
                    let message = L("The photo changed in the meantime. Try again.")
                    if isRunningVoiceCommand { lastReplyIsProblem = true }
                    tell(message)
                    Haptics.warning()
                    lastEffects = []
                    return .failed(message: message)
                }
                resultDocument = rebased
            }
            let changed = resultDocument != document
            if changed {
                commit(resultDocument, label: label)
            }
            // A table step says how many cells it changed; its cells flash on the canvas, in Live too.
            let report = result.tableReport
            if !label.isEmpty, !isQuiet { showToast(report.map { tableToast($0) } ?? toastText(for: label), undoable: changed) }
            if changed, let group = report?.groupID { pulse(group: group) }
            // The new title is ready to be rewritten or moved.
            if intent.action == .textBehind, changed { activeTool = .text }
            if !isQuiet { Haptics.success() }
        case .needsClarification(let request):
            pendingClarification = request
            candidateOverlays = request.candidates
            // Live asks the question itself (and shows the numbered choices).
            if !isQuiet {
                let question = LiveSpeechSanitizer.clean(request.question, language: language)
                if !isRunningVoiceCommand { showToast(question) }
                speak(question, language: language.rawValue)
                Haptics.warning()
            }
        case .info(let message):
            lastOutcomeNeedsHand = result.effects.contains(.message("tapToErase")) || result.effects.contains(.message("selectRegion"))
            if !isRunningVoiceCommand, !isQuiet { showToast(LiveSpeechSanitizer.clean(message, language: language)) }
            if result.effects.contains(.message("tapToErase")) { activeTool = .erase }
            if result.effects.contains(.message("crop")) { activeTool = .crop }
        case .failed(let message):
            // Executor text on screen never carries an internal word (D11).
            if !isRunningVoiceCommand, !isQuiet { showToast(LiveSpeechSanitizer.clean(message, language: language), isError: true) }
            if !isQuiet { Haptics.error() }
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
                compareBeforeAfter(seconds: 1.5)
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .selectLayer(let id):
                var document = updatedDocument
                document.selectedLayerID = id
                if document != self.document { history.commit(document, label: "Select") }
                // A table step never opens the text tool over its cells.
                if !Self.tableActions.contains(intent.action) { activeTool = .text }
            case .pickBackground: activeTool = .cutout
            case .pickColorReference:
                activeTool = .magic
                showsColorReferencePicker = true
            case .cancel:
                cancelClarification()
                if !isQuiet { showToast(L("Cancelled.")) }
            case .zoom(let amount, let target):
                zoomRequest = ZoomRequest(amount: amount, target: target)
            case .message(let message) where message.hasPrefix("version:"):
                handleVersionEffect(message)
            case .message(let message) where message.hasPrefix("style:"):
                handleStyleEffect(message)
            case .message("summary"):
                summarizeEdits(labels: history.past.map(\.label))
            case .message(let message) where message.hasPrefix("speak:"):
                speak(String(message.dropFirst(6)), language: language == .french ? "fr" : "en", force: true)
            default: break
            }
        }
        return result.outcome
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

    @ObservationIgnored private var compareTask: Task<Void, Never>?

    /// Shows the original for a moment, then the edit again.
    func compareBeforeAfter(seconds: Double) {
        compareTask?.cancel()
        showsOriginal = true
        compareTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.3, min(seconds, 10))))
            guard !Task.isCancelled else { return }
            self?.showsOriginal = false
        }
    }

    // MARK: - Export

    /// True once the file is written (and saved to Photos when asked).
    @discardableResult
    public func export(options: ExportOptions) async -> Bool {
        guard let renderer, exportProgress == nil else { return false }
        exportProgress = 0.05
        defer { exportProgress = nil }
        do {
            let url = try await PhotoExporter.export(document, renderer: renderer, options: options)
            exportedURL = url
            Haptics.success()
            showToast(options.saveToPhotos ? L("Saved to Photos") : L("Exported"))
            return true
        } catch {
            Haptics.error()
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
            return false
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
extension PhotoEditorSession: EditorStatus {
    /// The photo tasks report completion rather than a fraction.
    var processingProgress: Double? { nil }
    /// Work shimmers over the picture instead (and Live says it); export has its own HUD.
    var showsProcessingHUD: Bool { false }

    func performToastAction(_ action: Toast.Action) {
        switch action {
        case .rightWayUp: putRightWayUp()
        }
    }
}
#endif
