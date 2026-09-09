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
    public let services: PDFEditingService
    public private(set) var history: EditHistory<PDFDocumentModel>
    public var document: PDFDocumentModel { history.present }
    private var executor: PDFCommandExecutor

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
    public var pendingClarification: ClarificationRequest?
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
    public var lastTapPoint: PSPoint?
    /// Pending page index change requested by voice or the pages strip.
    public var requestedPageIndex: Int?

    private var toastTask: Task<Void, Never>?
    private var isConfigured = false

    public init(document: PDFDocumentModel, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: document)
        services = PDFEditingService(store: app.store, projectID: projectID)
        executor = PDFCommandExecutor(services: services)
    }

    public func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        executor.language = language
        app.voice.onFinalTranscript = { [weak self] text in
            Task { await self?.handleTranscript(text) }
        }
        recompose()
    }

    public func teardown() {
        app.voice.cancel()
        app.voice.onFinalTranscript = nil
        save()
    }

    public func save() {
        app.library.save(Project(id: projectID, content: .pdf(document), createdAt: document.createdAt, modifiedAt: Date()))
        if let image = services.thumbnail(for: 0, in: document, height: 400)?.cgImage {
            ThumbnailGenerator.writeThumbnail(image: image, projectID: projectID, store: app.store)
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
        let label = history.undo()
        Haptics.tick()
        showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo"))
        recompose()
    }

    public func redo() {
        guard history.canRedo else { return }
        let label = history.redo()
        Haptics.tick()
        showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo"))
        recompose()
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
        let services = self.services
        let document = self.document
        Task.detached(priority: .userInitiated) { [weak self] in
            let hit = services.word(at: displayedPoint, pageIndex: pageIndex, in: document)
            await MainActor.run {
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

    public func handleTranscript(_ text: String) async {
        transcript = text
        let plan = await app.router.plan(text, context: intentContext)
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            showToast(reply + "\n" + Replies.suggestions(for: .pdf, language: language), isError: true)
            VoiceFeedback.shared.speak(reply, language: plan.language)
            return
        }
        VoiceFeedback.shared.speak(plan.reply ?? "", language: plan.language)
        // Deletions by page number must run from the highest index down.
        let ordered = plan.intents.allSatisfy({ $0.action == .deletePage }) ? plan.intents.sorted { ($0.index ?? 0) > ($1.index ?? 0) } : plan.intents
        for intent in ordered where intent.action != .unknown {
            let outcome = await run(intent)
            if case .failed = outcome { break }
        }
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        if intent.action == .extractPage || intent.action == .findText || intent.action == .highlightText || intent.action == .redactText || intent.action == .underlineText {
            isProcessing = true
            processingTitle = L("Working…")
        }
        defer { isProcessing = false }
        let (updated, result) = await executor.execute(intent, on: document, context: intentContext)
        switch result.outcome {
        case .applied(let label):
            if updated != document { commit(updated, label: label) }
            if !label.isEmpty { showToast(label) }
            Haptics.success()
        case .info(let message):
            if updated != document { commit(updated, label: intent.summary) }
            showToast(message)
        case .failed(let message):
            showToast(message, isError: true)
            Haptics.error()
        case .needsClarification(let request):
            pendingClarification = request
            showToast(request.question)
        case .ignored:
            break
        }
        for effect in result.effects {
            switch effect {
            case .undo: undo()
            case .redo: redo()
            case .revert: history.revertToOriginal(); recompose()
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .message(let message):
                if message == "signature" { showsSignatureSheet = true }
                else if message == "merge" { showsMergePicker = true }
                else if message == "image" { showsImagePicker = true }
                else if message.hasPrefix("find:") { searchQuery = String(message.dropFirst(5)) }
                else if message.hasPrefix("version:") { handleVersionEffect(message) }
                else if message.hasPrefix("read:"), let index = Int(message.dropFirst(5)) { readPage(index) }
            case .cancel: pendingClarification = nil
            default: break
            }
        }
        return result.outcome
    }

    // MARK: Reading aloud

    /// Speaks the page (text layer or OCR), a few hundred words at most.
    public func readPage(_ index: Int) {
        let services = self.services
        let document = self.document
        let french = language == .french
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = services.pageText(pageIndex: index, in: document)
            await MainActor.run {
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

    private func restoreVersion(_ state: PDFDocumentModel, label: String) {
        update(label) { $0 = state }
        showToast(label)
        Haptics.success()
    }

    // MARK: Export

    public func export() {
        do {
            let url = try services.export(document)
            exportedURL = url
            Haptics.success()
            showToast(L("PDF ready to share"))
        } catch {
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    public func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = PhotoEditorSession.Toast(text: text, isError: isError) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 3.5 : 2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}
#endif
