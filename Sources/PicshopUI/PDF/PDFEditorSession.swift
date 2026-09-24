#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import SwiftUI
import PDFKit
import Observation
import PicshopCore
import PicshopIntent
import PicshopPDF
import PicshopImaging
import PicshopSpeech

/// State and behaviour of the PDF editor.
///
/// Views never read `history`: `document`, `canUndo`, `canRedo` and
/// `undoLabels` are stored mirrors brought up to date by didChangeHistory().
/// Page thumbnails, the library thumbnail, the export and reading the page
/// run on `worker`, off the main thread.
@MainActor
@Observable
public final class PDFEditorSession {
    public enum Tool: String, CaseIterable, Identifiable {
        case pages, draw, highlight, text, signature, image
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .pages: return L("Pages")
            case .draw: return L("Draw")
            case .highlight: return L("Highlight")
            case .text: return L("Text")
            case .signature: return L("Sign")
            case .image: return L("Image")
            }
        }
        var symbol: String {
            switch self {
            case .pages: return "doc.on.doc"
            case .draw: return "pencil.tip"
            case .highlight: return "highlighter"
            case .text: return "textformat"
            case .signature: return "signature"
            case .image: return "photo"
            }
        }
    }

    public let projectID: UUID
    public let app: AppEnvironment
    /// The viewer's PDFKit service: main thread only.
    public let services: PDFEditingService
    /// PDFKit work off the main thread, on its own documents.
    let worker: PDFBackgroundWorker
    @ObservationIgnored public private(set) var history: EditHistory<PDFDocumentModel> {
        didSet { didChangeHistory() }
    }
    /// Stored mirror of `history.present`, updated by didChangeHistory() only.
    public private(set) var document: PDFDocumentModel
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Past labels, oldest first.
    public private(set) var undoLabels: [String] = []
    /// Bumped whenever the document changes; Live's document version.
    private(set) var revision = 0
    /// Picshop Live in this editor, attached at the end of init. On PDF the orb dictates.
    public let live: LiveSession
    /// True for the whole of a Live session: no toast for Live steps, no spoken reply, no recogniser start.
    @ObservationIgnored public var liveSpeechSuppressed = false
    @ObservationIgnored private var isTornDown = false
    @ObservationIgnored private var executor: PDFCommandExecutor
    /// > 0 while Live runs a step: no toast, no speech.
    @ObservationIgnored var liveRunDepth = 0
    /// The effects the last executed step reported.
    @ObservationIgnored var lastEffects: [EditorEffect] = []
    @ObservationIgnored private var isStepping = false
    @ObservationIgnored private var lastSavedDocument: PDFDocumentModel?
    /// Revision at the last thumbnail handed to the library.
    @ObservationIgnored private var thumbnailRevision = 0

    /// Composed PDFKit document shown by the viewer (rebuilt on every change).
    public private(set) var composed: PDFDocument?
    public var activeTool: Tool?
    public var inkColor: PSColor = .red
    public var inkWidth: Double = 0.004
    public var highlightColor: PSColor = .yellow
    public var isProcessing = false
    public var processingTitle = ""
    public var toast: PhotoEditorSession.Toast?
    public var transcript = ""
    public var lastPlan: EditPlan?
    public private(set) var lastReplyIsProblem = false
    public private(set) var lastReplyIsError = false
    public var pendingClarification: ClarificationRequest? {
        didSet { if pendingClarification != oldValue { live.noteContextChanged() } }
    }
    public var showsExport = false
    public var showsHelp = false
    public var showsSignatureSheet = false
    public var showsMergePicker = false
    public var showsImagePicker = false
    public var exportedURL: URL?
    public var searchQuery: String?
    /// Text typed in the Text tool, placed by the next tap on empty paper.
    public var textDraft = ""
    /// Word being edited in place after a tap with the Text tool.
    public var textEdit: TextEdit?

    public struct TextEdit: Identifiable, Equatable {
        public let id = UUID()
        public var pageIndex: Int
        public var original: String
        public var rect: PSRect
        public var background: PSColor?
        public var draft: String
        public var fontName: String? = nil
        public var relativeFontSize: Double? = nil
        public var suffix: String = ""
    }
    /// Tap location on the current page (displayed, normalised) for text/image placement.
    @ObservationIgnored public var lastTapPoint: PSPoint?
    /// Pending page index change requested by voice or the pages strip.
    public var requestedPageIndex: Int?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var isConfigured = false

    public init(document: PDFDocumentModel, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: document)
        self.document = document
        services = PDFEditingService(store: app.store, projectID: projectID)
        worker = PDFBackgroundWorker(store: app.store, projectID: projectID)
        executor = PDFCommandExecutor(services: services)
        live = LiveSession(app: app, mode: .pdf, canGoLive: false)
        live.attach(self)
    }

    public func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        executor.language = language
        lastSavedDocument = document
        recompose()
    }

    /// Ends the session: Live and the voice stop, and the document is saved. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        Diagnostics.shared.note("pdf editor teardown")
        live.teardown()
        app.voice.cancel()
        save()
    }

    /// Saves off the main thread (the library orders the writes), and hands the
    /// library page 1 as composed and rendered by the worker.
    public func save() {
        let modifiedAt = Date()
        let library = app.library
        if document != lastSavedDocument {
            let project = Project(id: projectID, content: .pdf(document), createdAt: document.createdAt, modifiedAt: modifiedAt)
            lastSavedDocument = document
            Task { await library.persist(project) }
        }
        guard revision != thumbnailRevision else { return }
        thumbnailRevision = revision
        let saved = document
        let worker = self.worker
        let id = projectID
        Task {
            guard let image = await worker.pageThumbnail(0, in: saved, height: 400) else { return }
            library.setThumbnail(image, for: id, modifiedAt: modifiedAt)
        }
    }

    var language: NormalizedUtterance.Language {
        if let hint = app.settings.languageHint { return hint == "fr" ? .french : .english }
        return Locale.current.language.languageCode?.identifier == "fr" ? .french : .english
    }

    var intentContext: IntentContext {
        IntentContext(mode: .pdf, pendingClarification: pendingClarification, lastTapPoint: lastTapPoint, canUndo: history.canUndo, canRedo: history.canRedo,
                      preferredLanguage: app.settings.languageHint, pageCount: document.pageCount, currentPage: document.currentPageIndex + 1,
                      hasSignature: FileManager.default.fileExists(atPath: SignatureStore.fileURL.path))
    }

    /// Total rotation of the page as displayed (original + edits).
    public func displayRotation(of page: PDFPageModel) -> Int {
        (services.originalRotation(of: page, in: document) + page.rotation) % 360
    }

    // MARK: History

    /// Brings the stored mirrors up to date after any change to `history`, each
    /// assigned only when its value changes, then tells Live.
    private func didChangeHistory() {
        let present = history.present
        // The page the viewer shows is view state, not a change to the document.
        var samePage = present
        samePage.currentPageIndex = document.currentPageIndex
        let documentChanged = samePage != document
        let labels = history.past.map(\.label)
        let isNewStep = !isStepping && !history.canRedo && labels != undoLabels
            && (labels.count > undoLabels.count || labels.count == history.limit)
        var changed = documentChanged
        if present != document { document = present }
        if documentChanged { revision += 1 }
        if canUndo != history.canUndo { canUndo = history.canUndo; changed = true }
        if canRedo != history.canRedo { canRedo = history.canRedo; changed = true }
        if labels != undoLabels { undoLabels = labels; changed = true }
        guard changed, !history.isInTransaction else { return }
        live.noteDocumentChanged(label: isNewStep ? history.undoLabel : nil)
    }

    private func commit(_ updated: PDFDocumentModel, label: String) {
        var copy = updated
        copy.touch()
        history.commit(copy, label: label)
        recompose()
    }

    private func recompose() {
        composed = services.compose(document)
        requestedPageIndex = document.currentPageIndex
    }

    public func undo() {
        guard history.canUndo else { return }
        isStepping = true
        let label = history.undo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        recompose()
    }

    /// Goes back several steps at once (the History list): one refresh, one toast.
    /// Returns the labels undone, newest first.
    @discardableResult
    public func undo(steps: Int) -> [String] {
        guard steps > 0, history.canUndo else { return [] }
        var labels: [String] = []
        isStepping = true
        for _ in 0..<steps where history.canUndo {
            if let label = history.undo() { labels.append(label) }
        }
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(labels.last.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        recompose()
        return labels
    }

    /// Returns the label redone, nil when there was nothing to redo.
    @discardableResult
    public func redo() -> String? {
        guard history.canRedo else { return nil }
        isStepping = true
        let label = history.redo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo")) }
        recompose()
        return label
    }

    /// Back to the document as this session opened it, as one undoable step. False when there was nothing to revert.
    @discardableResult
    public func revert() -> Bool {
        guard let original = history.past.first?.state, original != document else { return false }
        history.revertToOriginal()
        recompose()
        return true
    }

    public func update(_ label: String, _ body: (inout PDFDocumentModel) -> Void) {
        var document = self.document
        body(&document)
        commit(document, label: label)
    }

    /// Records the page the viewer is showing without creating history.
    public func viewerDidShowPage(_ index: Int) {
        guard document.currentPageIndex != index, document.pages.indices.contains(index) else { return }
        var document = self.document
        document.goToPage(index)
        history.replacePresent(document)
        requestedPageIndex = index
    }

    /// Goes to a page (the pages strip, the page pill, a voice command): no
    /// recompose and no history entry, the viewer just scrolls there.
    public func showPage(_ index: Int) {
        guard document.pages.indices.contains(index) else { return }
        if document.currentPageIndex != index {
            var document = self.document
            document.goToPage(index)
            history.replacePresent(document)
        }
        requestedPageIndex = index
    }

    // MARK: Direct edits

    public func addInk(strokes: [BrushStroke], pageIndex: Int) {
        guard !strokes.isEmpty, let page = document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil else { return }
        let rotation = displayRotation(of: page)
        let baseStrokes = strokes.map { stroke in
            BrushStroke(id: stroke.id, points: stroke.points.map { PDFGeometry.basePoint(fromDisplayed: $0, rotation: rotation) }, radius: stroke.radius, hardness: 1, mode: .add)
        }
        update(L("Drawing")) { $0.addMarkup(PDFMarkup(kind: .ink(strokes: baseStrokes, color: inkColor, width: inkWidth)), toPageAt: pageIndex) }
    }

    public func addHighlight(displayedRects: [PSRect], pageIndex: Int, kind: String = "highlight") {
        guard let page = document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil else { return }
        let rotation = displayRotation(of: page)
        let base = displayedRects.map { PDFGeometry.baseRect(fromDisplayed: $0, rotation: rotation) }
        let markup: PDFMarkup.Kind = kind == "underline" ? .underline(rects: base, color: highlightColor) : .highlight(rects: base, color: highlightColor)
        update(L("Highlight")) { $0.addMarkup(PDFMarkup(kind: markup), toPageAt: pageIndex) }
    }

    public func addText(_ text: String, at displayedPoint: PSPoint?, pageIndex: Int) {
        guard let page = document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil else { return }
        let rotation = displayRotation(of: page)
        let center = PDFGeometry.basePoint(fromDisplayed: displayedPoint ?? PSPoint(x: 0.5, y: 0.5), rotation: rotation)
        var element = TextElement(text: text, fontName: "SFPro-Semibold", relativeSize: 0.025, color: inkColor, style: .plain, center: center)
        element.maxRelativeWidth = 0.8
        update(L("Add Text")) { $0.addMarkup(PDFMarkup(kind: .text(element)), toPageAt: pageIndex) }
    }

    /// Text tool tap: an existing word opens the inline editor; empty paper places `draft` (if any).
    public func tapText(at displayedPoint: PSPoint, pageIndex: Int, draft: String) {
        lastTapPoint = displayedPoint
        guard !isProcessing else { return }
        isProcessing = true
        processingTitle = L("Reading the page…")
        let worker = self.worker
        let document = self.document
        Task { [weak self] in
            let hit = await worker.word(at: displayedPoint, pageIndex: pageIndex, in: document)
            guard let self else { return }
            self.isProcessing = false
            if let hit {
                self.textEdit = TextEdit(pageIndex: pageIndex, original: hit.text, rect: hit.rect, background: hit.background, draft: hit.text, fontName: hit.fontName, relativeFontSize: hit.relativeFontSize, suffix: hit.suffix)
                Haptics.tick()
                return
            }
            let text = draft.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { self.addText(text, at: displayedPoint, pageIndex: pageIndex) } else { Haptics.tick() }
        }
    }

    /// Commits the inline editor: the original word is covered and the new text written in place.
    public func commitTextEdit(_ newText: String, fontName: String? = nil) {
        guard let edit = textEdit else { return }
        textEdit = nil
        var text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != edit.original || (fontName != nil && fontName != edit.fontName) else { return }
        if !text.isEmpty, !edit.suffix.isEmpty, !(text.last.map { ",.;:!?".contains($0) } ?? false) { text += edit.suffix }
        let element = TextElement(text: text, fontName: fontName ?? edit.fontName ?? "Helvetica", relativeSize: edit.relativeFontSize ?? 0, color: inkColor == .red ? .black : inkColor, alignment: .leading, style: .plain)
        update(text.isEmpty ? L("Erase text") : L("Edit text")) {
            $0.addMarkup(PDFMarkup(kind: .replacement(rects: [edit.rect], text: element, background: edit.background)), toPageAt: edit.pageIndex)
        }
        Haptics.success()
    }

    public func placeSignature(at displayedPoint: PSPoint?, pageIndex: Int) {
        guard let signature = SignatureStore.currentAsset() else { showsSignatureSheet = true; return }
        guard let page = document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil else { return }
        let rotation = displayRotation(of: page)
        let center = PDFGeometry.basePoint(fromDisplayed: displayedPoint ?? PSPoint(x: 0.75, y: 0.86), rotation: rotation)
        let width = 0.28
        let height = width / max(0.5, signature.pixelSize.aspectRatio) * (page.size.width / max(1, page.size.height))
        let frame = PSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height).clampedToUnit()
        update(L("Signature")) { $0.addMarkup(PDFMarkup(kind: .signature(signature, frame: frame)), toPageAt: pageIndex) }
    }

    public func placeImage(_ image: UIImage, at displayedPoint: PSPoint?, pageIndex: Int) {
        guard let page = document.pages.indices.contains(pageIndex) ? document.pages[pageIndex] : nil, let asset = try? services.importImage(image) else { return }
        let rotation = displayRotation(of: page)
        let center = PDFGeometry.basePoint(fromDisplayed: displayedPoint ?? PSPoint(x: 0.5, y: 0.5), rotation: rotation)
        let width = 0.4
        let height = width / max(0.2, asset.pixelSize.aspectRatio) * (page.size.width / max(1, page.size.height))
        let frame = PSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: min(0.9, height)).clampedToUnit()
        update(L("Image")) { $0.addMarkup(PDFMarkup(kind: .image(asset, frame: frame)), toPageAt: pageIndex) }
    }

    public func removeLastMarkup(onPage pageIndex: Int) {
        guard let last = document.pages[pageIndex].markups.last else { return }
        update(L("Remove")) { $0.removeMarkup(id: last.id) }
    }

    public func merge(from url: URL) {
        do {
            let pages = try services.importForMerge(url)
            update(L("Merge")) { document in
                for page in pages { document.pages.append(page) }
            }
            Haptics.success()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    public func saveSignature(strokes: [BrushStroke]) {
        do {
            try SignatureStore.save(strokes: strokes)
            showsSignatureSheet = false
            placeSignature(at: nil, pageIndex: document.currentPageIndex)
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Voice pipeline

    /// Runs a spoken or typed command, one step after another; the reply says what really happened.
    public func handleTranscript(_ text: String) async {
        transcript = text
        lastReplyIsProblem = false
        lastReplyIsError = false
        let plan = await app.router.plan(text, context: intentContext)
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            lastPlan?.reply = reply
            lastReplyIsProblem = true
            if !isQuiet {
                let suggestions = Replies.suggestions(for: .pdf, language: language)
                showToast(repliesInCapsule ? suggestions : reply + "\n" + suggestions, isError: true)
            }
            speak(reply, language: plan.language)
            return
        }
        speak(plan.reply ?? "", language: plan.language)
        isRunningVoiceCommand = true
        defer { isRunningVoiceCommand = false }
        // Deletions by page number must run from the highest index down.
        let ordered = plan.intents.allSatisfy({ $0.action == .deletePage }) ? plan.intents.sorted { ($0.index ?? 0) > ($1.index ?? 0) } : plan.intents
        var told: String?
        steps: for intent in ordered where intent.action != .unknown {
            switch await run(intent) {
            case .failed(let message):
                told = message
                lastReplyIsProblem = true
                lastReplyIsError = true
                break steps
            case .needsClarification(let request):
                lastPlan?.reply = request.question
                return
            case .info(let message):
                told = message
            case .applied, .ignored:
                continue
            }
        }
        if let told { lastPlan?.reply = told }
    }

    /// A command typed or dictated through Live's composer: its reply shows in Live's capsule.
    @ObservationIgnored var repliesInCapsule = false
    @ObservationIgnored private var isRunningVoiceCommand = false

    /// Live runs this step: Live says what happened, the editor stays quiet.
    var isQuiet: Bool { liveRunDepth > 0 || liveSpeechSuppressed }

    /// Spoken replies outside Live only.
    private func speak(_ text: String, language: String?, force: Bool = false) {
        guard !isQuiet, !text.isEmpty else { return }
        VoiceFeedback.shared.speak(text, language: language, force: force)
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        lastEffects = []
        let isHeavy = intent.action == .extractPage || intent.action == .findText || intent.action == .highlightText || intent.action == .redactText || intent.action == .underlineText
        if isHeavy {
            guard !isProcessing else {
                let message = L("One moment…")
                if !isRunningVoiceCommand, !isQuiet { showToast(message) }
                return .info(message: message)
            }
            isProcessing = true
            processingTitle = L("Working…")
        }
        defer { if isHeavy { isProcessing = false } }
        let base = document
        let (updated, result) = await executor.execute(intent, on: base, context: intentContext)
        lastEffects = result.effects
        var outcome = result.outcome
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            if base != document, updated != base {
                // Something else landed while this ran: drop it rather than undo that.
                let message = L("The document changed in the meantime. Try again.")
                if !isRunningVoiceCommand, !isQuiet { showToast(message, isError: true) }
                lastEffects = []
                return .failed(message: message)
            }
            land(updated, label: label)
            if !label.isEmpty, !isQuiet { showToast(label, undoable: history.canUndo) }
            if !isQuiet { Haptics.success() }
        case .info(let message):
            if updated != document, base == document { land(updated, label: intent.summary) }
            if !isRunningVoiceCommand, !isQuiet { showToast(message) }
        case .failed(let message):
            if !isRunningVoiceCommand, !isQuiet { showToast(message, isError: true) }
            if !isQuiet { Haptics.error() }
        case .needsClarification(let request):
            pendingClarification = request
            if !isRunningVoiceCommand, !isQuiet { showToast(request.question) }
        case .ignored:
            break
        }
        for effect in result.effects {
            switch effect {
            case .undo: undo()
            case .redo: redo()
            case .revert:
                if !revert() { outcome = .info(message: L("This is already the original.")) }
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .message(let message):
                if message == "signature" { showsSignatureSheet = true }
                else if message == "merge" { showsMergePicker = true }
                else if message == "image" { showsImagePicker = true }
                else if message.hasPrefix("find:") { searchQuery = String(message.dropFirst(5)) }
                else if message.hasPrefix("version:") { handleVersionEffect(message) }
                else if message == "summary" { summarizeEdits(labels: history.past.map(\.label)) }
                else if message.hasPrefix("read:"), let index = Int(message.dropFirst(5)) { readPage(index) }
            case .cancel: pendingClarification = nil
            default: break
            }
        }
        return outcome
    }

    /// A page change alone scrolls the viewer (no recompose, no history entry); anything else is committed.
    private func land(_ updated: PDFDocumentModel, label: String) {
        guard updated != document else { return }
        var samePage = updated
        samePage.currentPageIndex = document.currentPageIndex
        if samePage == document {
            showPage(updated.currentPageIndex)
        } else {
            commit(updated, label: label)
        }
    }

    // MARK: Reading aloud

    /// Speaks the page (text layer or OCR), a few hundred words at most.
    public func readPage(_ index: Int) {
        let worker = self.worker
        let document = self.document
        let french = language == .french
        Task { [weak self] in
            let text = await worker.pageText(pageIndex: index, in: document)
            guard let self else { return }
            guard !text.isEmpty else {
                self.showToast(french ? "Je ne trouve pas de texte sur cette page." : "I can't find any text on this page.", isError: true)
                return
            }
            let words = text.split(whereSeparator: { $0.isWhitespace })
            let spoken = words.prefix(400).joined(separator: " ")
            VoiceFeedback.shared.speak(spoken, language: french ? "fr" : "en", force: true)
            self.showToast(words.count > 400 ? (french ? "Je lis le début de la page." : "Reading the start of the page.") : (french ? "Je lis la page." : "Reading the page."))
        }
    }

    // MARK: - Named versions

    /// Snapshots the user named by voice ("enregistre cette version sous brouillon").
    public private(set) var versions: [(name: String, state: PDFDocumentModel)] = []

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

    private func restoreVersion(_ state: PDFDocumentModel, label: String) {
        update(label) { $0 = state }
        showToast(label)
        Haptics.success()
    }

    // MARK: Export

    /// Writes the flattened PDF off the main thread, for the share sheet.
    public func export() async {
        exportedURL = nil
        do {
            let url = try await worker.export(document)
            exportedURL = url
            Haptics.success()
            showToast(L("PDF ready to share"))
        } catch {
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    public func showToast(_ text: String, isError: Bool = false, undoable: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = PhotoEditorSession.Toast(text: text, isError: isError, undoable: undoable) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 3.5 : (undoable ? 4 : 2.2)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}
extension PDFEditorSession: EditorStatus {
    var processingProgress: Double? { nil }
    /// The PDF export writes the file in one step and shares it.
    var exportProgress: Double? { nil }
}

/// What the viewer is doing, for the page pill: shown while the pages move,
/// gone 1.5 s after they stop. Only the pill reads it.
@MainActor
@Observable
final class PDFViewerActivity {
    private(set) var showsPagePill = false
    @ObservationIgnored private var lastScroll = Date.distantPast
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func noteScroll() {
        lastScroll = Date()
        if !showsPagePill { showsPagePill = true }
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while let self {
                let remaining = self.lastScroll.addingTimeInterval(1.5).timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining))
                if Task.isCancelled { return }
            }
            self?.hideTask = nil
            self?.showsPagePill = false
        }
    }
}
#endif
