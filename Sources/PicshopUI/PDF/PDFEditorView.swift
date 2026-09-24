#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers
import PicshopCore
import PicshopIntent
import PicshopPDF

/// The PDF editing screen in the studio shell: the pages edge to edge between
/// the bars, a page pill, Live at the bottom (its orb dictates here, and typed
/// text runs on the iPhone), every tool behind Outils.
public struct PDFEditorView: View {
    @State var session: PDFEditorSession
    @State private var activity = PDFViewerActivity()
    @Environment(\.dismiss) private var dismiss
    @State private var pickedImage: PhotosPickerItem?

    public init(session: PDFEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        StudioChrome(bar: bar, actions: actions, live: session.live,
                     catalog: { PDFToolCatalog.make(session: session) },
                     isToolOpen: session.activeTool != nil) {
            PDFCanvas(session: session, activity: activity)
        } panel: {
            if let tool = session.activeTool {
                PDFToolCard(session: session, tool: tool)
            }
        }
        .overlay { EditorStatusOverlay(session: session) }
        .onAppear { session.configure() }
        .onDisappear { session.teardown() }
        .onChange(of: session.activeTool) { _, tool in
            // The signature and image tools open their sheet with the panel.
            if tool == .signature, SignatureStore.currentAsset() == nil { session.showsSignatureSheet = true }
            if tool == .image { session.showsImagePicker = true }
        }
        .sheet(isPresented: $session.showsHelp) {
            HelpSheet(mode: .pdf) { text in session.live.send(text: text) }
        }
        .sheet(isPresented: $session.showsSignatureSheet) { SignatureSheet { strokes in session.saveSignature(strokes: strokes) } }
        .sheet(isPresented: $session.showsExport) { PDFExportSheet(session: session) }
        .sheet(item: $session.textEdit) { edit in
            TextEditSheet(edit: edit, onCommit: { text, font in session.commitTextEdit(text, fontName: font) }, onCancel: { session.textEdit = nil })
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $session.showsMergePicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { session.merge(from: url) }
        }
        .photosPicker(isPresented: $session.showsImagePicker, selection: $pickedImage, matching: .images)
        .onChange(of: pickedImage) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    session.placeImage(image, at: session.lastTapPoint, pageIndex: session.document.currentPageIndex)
                }
                pickedImage = nil
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private var bar: StudioBar {
        StudioBar(canUndo: session.canUndo, canRedo: session.canRedo, undoLabels: session.undoLabels, isBusy: session.isProcessing)
    }

    private var actions: StudioActions {
        let session = session
        let dismiss = dismiss
        return StudioActions(close: { dismiss() },
                             undo: { session.undo() },
                             redo: { session.redo() },
                             undoSteps: { steps in session.undo(steps: steps) },
                             revert: { session.revert() },
                             export: { session.showsExport = true })
    }
}

// MARK: - Canvas

/// The pages under the studio's bars: the viewer fitted between them, edge to
/// edge across, and the page pill 8 points above the dock.
struct PDFCanvas: View {
    let session: PDFEditorSession
    let activity: PDFViewerActivity
    @Environment(\.studioEdges) private var studioEdges

    var body: some View {
        GeometryReader { proxy in
            let chrome = studioEdges.insets(over: proxy.frame(in: .global))
            VStack(spacing: 0) {
                Color.clear.frame(height: chrome.top)
                PDFViewerRepresentable(session: session, activity: activity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        PagePill(session: session, activity: activity)
                            .padding(.bottom, 8)
                    }
                Color.clear.frame(height: chrome.bottom)
            }
        }
        .background(PSTheme.canvas)
    }
}

/// '3 / 12' at the bottom centre: shown while the pages move, gone 1.5 s after
/// they stop; a tap opens Pages. A leaf: the page and the activity are read here only.
private struct PagePill: View {
    let session: PDFEditorSession
    let activity: PDFViewerActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shows = activity.showsPagePill && session.document.pageCount > 1
        Button {
            Haptics.tap()
            session.activeTool = .pages
        } label: {
            Text(verbatim: "\(session.document.currentPageIndex + 1) / \(session.document.pageCount)")
                .font(PSFont.timecode(12))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .psGlass(interactive: true, variant: .clear)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(shows)
        .animation(reduceMotion ? nil : PSMotion.standard, value: shows)
        .accessibilityLabel(String(format: L("Page %d of %d"), session.document.currentPageIndex + 1, session.document.pageCount))
        .accessibilityHint(L("Shows the pages."))
        .accessibilityHidden(!shows)
    }
}

// MARK: - Tools

/// The open tool, inline at the bottom of the studio, with the category's
/// other tools as segments.
struct PDFToolCard: View {
    @Bindable var session: PDFEditorSession
    let tool: PDFEditorSession.Tool

    var body: some View {
        let siblings = PDFToolCatalog.siblings(of: tool)
        ToolPanel(title: siblings.count > 1 ? PDFToolCatalog.categoryTitle(of: tool) : PDFToolCatalog.title(for: tool),
                  live: session.live, onDone: { session.activeTool = nil }) {
            VStack(spacing: 12) {
                if siblings.count > 1 {
                    ModeSegments(modes: siblings, selection: $session.activeTool,
                                 title: { PDFToolCatalog.title(for: $0) }, symbol: { $0.symbol })
                }
                PDFToolContent(session: session, tool: tool)
            }
        }
    }
}

/// The controls of one tool.
private struct PDFToolContent: View {
    @Bindable var session: PDFEditorSession
    let tool: PDFEditorSession.Tool

    var body: some View {
        switch tool {
        case .pages:
            PagesStrip(session: session)
        case .draw:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach([PSColor.red, .blue, .black, .green, .orange, .purple], id: \.self) { color in
                        ColorSwatch(color: color, isSelected: session.inkColor == color, size: 28) { session.inkColor = color }
                    }
                    Spacer()
                    // The stroke as it will land on the page: colour and width, live.
                    PenPreview(color: session.inkColor, width: session.inkWidth)
                    PanelChip(title: L("Undo stroke"), symbol: "arrow.uturn.backward") { session.removeLastMarkup(onPage: session.document.currentPageIndex) }
                }
                DialSlider(value: $session.inkWidth, range: 0.001...0.015, neutral: 0.004, label: L("Pen width"), units: 40, format: { String(format: "%.1f", $0 * 1000) })
                Text(L("Draw directly on the page.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .highlight:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach([PSColor.yellow, .green, .pink, .teal, .orange], id: \.self) { color in
                        HighlightSwatch(color: color, isSelected: session.highlightColor == color) { session.highlightColor = color }
                    }
                    Spacer()
                    PanelChip(title: L("Undo"), symbol: "arrow.uturn.backward") { session.removeLastMarkup(onPage: session.document.currentPageIndex) }
                }
                Text(L("Tap a word to highlight it, or say “surligne « total »”.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(L("New text, then tap where it goes"), text: $session.textDraft)
                        .textFieldStyle(.plain).font(PSFont.body(15)).foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10).psField(Capsule())
                    Button {
                        let text = session.textDraft.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        session.addText(text, at: session.lastTapPoint, pageIndex: session.document.currentPageIndex)
                        session.textDraft = ""
                    } label: { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.onAccent).psAccentFill(Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(L("Add Text"))
                }
                Text(L("Tap any word on the page to change or erase it — scans included."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .signature:
            HStack(spacing: 8) {
                PanelChip(title: L("Place signature"), symbol: "signature", tint: PSTheme.accent) { session.placeSignature(at: session.lastTapPoint, pageIndex: session.document.currentPageIndex) }
                PanelChip(title: L("Redraw"), symbol: "pencil.and.scribble") { session.showsSignatureSheet = true }
                Spacer()
                Text(L("Tap where to sign.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .image:
            HStack(spacing: 8) {
                PanelChip(title: L("Insert photo"), symbol: "photo.badge.plus", tint: PSTheme.accent) { session.showsImagePicker = true }
                PanelChip(title: L("Merge PDF"), symbol: "doc.on.doc") { session.showsMergePicker = true }
                PanelChip(title: L("Page numbers"), symbol: "number") { Task { await session.run(EditIntent(action: .addPageNumbers)) } }
            }
        }
    }
}

/// A short stroke in the current ink, so the pen's colour and thickness are visible before drawing.
struct PenPreview: View {
    let color: PSColor
    let width: Double

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 4, y: 18))
            path.addCurve(to: CGPoint(x: 44, y: 10), control1: CGPoint(x: 16, y: -4), control2: CGPoint(x: 28, y: 30))
        }
        .stroke(Color(cgColor: color.cgColor), style: StrokeStyle(lineWidth: max(1.5, width * 900), lineCap: .round))
        .frame(width: 48, height: 28)
        .animation(PSMotion.quick, value: width)
        .accessibilityHidden(true)
    }
}

/// Highlighter swatch: "Aa" on paper under the translucent colour, the way the mark will read on the page.
struct HighlightSwatch: View {
    let color: PSColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            Text("Aa")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(.black)
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(cgColor: color.cgColor).opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isSelected ? PSTheme.accent : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1))
                .scaleEffect(isSelected ? 1.08 : 1)
                .animation(PSMotion.quick, value: isSelected)
        }
        .buttonStyle(PSPressStyle(scale: 0.9))
        .accessibilityLabel(color.hexString)
    }
}

/// Inline editor for a word tapped on the page.
struct TextEditSheet: View {
    let edit: PDFEditorSession.TextEdit
    let onCommit: (String, String) -> Void
    let onCancel: () -> Void
    @State private var draft: String
    @State private var fontName: String
    @FocusState private var focused: Bool

    /// Faces the user can switch to when the detected one is wrong.
    private static let faces: [(title: String, name: String)] = [
        ("Sans", "Helvetica"), ("Sans bold", "Helvetica-Bold"), ("Serif", "TimesNewRomanPSMT"), ("Serif bold", "TimesNewRomanPS-BoldMT"),
    ]

    init(edit: PDFEditorSession.TextEdit, onCommit: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.edit = edit
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: edit.draft)
        _fontName = State(initialValue: edit.fontName ?? "Helvetica")
    }

    /// The detected face maps onto the nearest of the four choices (Verdana bold → Sans bold).
    private func isActive(_ face: (title: String, name: String)) -> Bool {
        let lower = fontName.lowercased()
        let bold = lower.contains("bold")
        let serif = lower.contains("times") || lower.contains("georgia")
        return face.name == (serif ? (bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT") : (bold ? "Helvetica-Bold" : "Helvetica"))
    }

    private var previewFont: Font {
        Font(UIFont(name: fontName, size: 22) ?? UIFont.systemFont(ofSize: 22))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Edit text")).font(PSFont.headline(17)).foregroundStyle(PSTheme.textPrimary)
                Spacer()
                Text(edit.original).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
            }
            // Live preview on paper, in the face that will be written on the page.
            HStack(spacing: 10) {
                Text(edit.original).font(previewFont).foregroundStyle(.black.opacity(0.35)).strikethrough(true, color: .red.opacity(0.6)).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.35))
                Text(draft.isEmpty ? " " : draft).font(previewFont).foregroundStyle(.black).lineLimit(1).contentTransition(.interpolate)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(red: 0.97, green: 0.96, blue: 0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(PSMotion.quick, value: fontName)
            TextField(L("New text"), text: $draft)
                .textFieldStyle(.plain).font(PSFont.body(17)).foregroundStyle(PSTheme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 12).psField(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { onCommit(draft, fontName) }
            HStack(spacing: 6) {
                ForEach(Self.faces, id: \.name) { face in
                    let active = isActive(face)
                    Button {
                        Haptics.tick()
                        withAnimation(PSMotion.quick) { fontName = face.name }
                    } label: {
                        Text(face.title)
                            .font(Font(UIFont(name: face.name, size: 12) ?? UIFont.systemFont(ofSize: 12)))
                            .foregroundStyle(active ? Color.white : PSTheme.textSecondary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(active ? PSTheme.accent : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(PSPressStyle())
                    .accessibilityAddTraits(active ? [.isSelected] : [])
                }
                Spacer()
                Text(L("Detected from the page")).font(PSFont.caption(10)).foregroundStyle(PSTheme.textTertiary)
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { Haptics.warning(); onCommit("", fontName) } label: {
                    Label(L("Erase"), systemImage: "eraser").font(PSFont.caption(13)).padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.plain).foregroundStyle(PSTheme.danger).psGlass(interactive: true)
                Spacer()
                Button { onCancel() } label: { Text(L("Cancel")).font(PSFont.caption(13)).padding(.horizontal, 14).padding(.vertical, 9) }
                    .buttonStyle(.plain).foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
                Button { onCommit(draft, fontName) } label: { Text(L("Replace")).font(PSFont.headline(13)).padding(.horizontal, 16).padding(.vertical, 9) }
                    .buttonStyle(.plain).foregroundStyle(PSTheme.onAccent).psAccentFill(Capsule())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PSTheme.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}

/// The pages, with rotate, duplicate, save as photo and delete. A tap goes to
/// the page (no recompose, no history entry); the thumbnails are rendered off
/// the main thread and cached by page; only the current page casts a shadow.
struct PagesStrip: View {
    @Bindable var session: PDFEditorSession

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(session.document.pages.enumerated()), id: \.element.id) { index, page in
                            let selected = index == session.document.currentPageIndex
                            VStack(spacing: 5) {
                                PageThumbnail(session: session, index: index, page: page)
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? PSTheme.accent : PSTheme.hairline, lineWidth: selected ? 2.5 : 1))
                                    .background {
                                        if selected {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black)
                                                .shadow(color: PSTheme.accent.opacity(0.35), radius: 10, y: 4)
                                        }
                                    }
                                    .scaleEffect(selected ? 1 : 0.94)
                                    .opacity(selected ? 1 : 0.8)
                                Text(verbatim: "\(index + 1)")
                                    .font(PSFont.caption(10)).foregroundStyle(selected ? Color.white : PSTheme.textSecondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(selected ? PSTheme.accent : Color.clear))
                            }
                            .animation(PSMotion.quick, value: selected)
                            .contentShape(Rectangle())
                            .onTapGesture { Haptics.tick(); session.showPage(index) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(String(format: L("Page %d of %d"), index + 1, session.document.pageCount))
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                            .contextMenu {
                                Button { Task { await session.run(EditIntent(action: .rotatePage, degrees: 90, index: index + 1)) } } label: { Label(L("Rotate"), systemImage: "rotate.right") }
                                Button { Task { await session.run(EditIntent(action: .duplicatePage, index: index + 1)) } } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
                                Button { Task { await session.run(EditIntent(action: .extractPage, index: index + 1)) } } label: { Label(L("Save as photo"), systemImage: "photo") }
                                Button(role: .destructive) { Task { await session.run(EditIntent(action: .deletePage, index: index + 1)) } } label: { Label(L("Delete"), systemImage: "trash") }
                            }
                            .id(page.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    let pages = session.document.pages
                    if pages.indices.contains(session.document.currentPageIndex) { reader.scrollTo(pages[session.document.currentPageIndex].id, anchor: .center) }
                }
            }
            HStack(spacing: 8) {
                PanelChip(title: L("Rotate"), symbol: "rotate.right") { Task { await session.run(EditIntent(action: .rotatePage, degrees: 90)) } }
                PanelChip(title: L("Delete"), symbol: "trash") { Task { await session.run(EditIntent(action: .deletePage)) } }
                PanelChip(title: L("Blank page"), symbol: "doc.badge.plus") { Task { await session.run(EditIntent(action: .insertBlankPage, scope: .selection)) } }
                PanelChip(title: L("Move"), symbol: "arrow.left.arrow.right") { Task { await session.run(EditIntent(action: .movePage, clipIndex: -1)) } }
            }
        }
    }
}

/// One page as it looks with its markups, rendered by the session's worker
/// (off the main thread), again only when that page changes.
struct PageThumbnail: View {
    let session: PDFEditorSession
    let index: Int
    let page: PDFPageModel
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { PSTheme.surfaceElevated.aspectRatio(0.75, contentMode: .fit) }
        }
        .task(id: "\(index)|\(page.hashValue)") {
            let worker = session.worker
            let document = session.document
            let rendered = await worker.pageThumbnail(index, in: document, height: 96)
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

/// PDFKit viewer that forwards taps and pen strokes to the session. Edge to
/// edge: 12 points between pages, each with its own shadow; scrolling shows
/// the page pill.
struct PDFViewerRepresentable: UIViewRepresentable {
    let session: PDFEditorSession
    var activity: PDFViewerActivity?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.backgroundColor = .black
        view.pageShadowsEnabled = true
        view.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.isSyncing = true
        defer { context.coordinator.isSyncing = false }
        if view.document !== session.composed {
            let current = session.document.currentPageIndex
            let scale = view.scaleFactor
            let wasAutoScaling = view.autoScales
            view.document = session.composed
            if !wasAutoScaling, scale > 0 { view.scaleFactor = scale }
            if let page = session.composed?.page(at: current) { view.go(to: page) }
            context.coordinator.appliedQuery = nil
        }
        if let requested = session.requestedPageIndex, let document = view.document, let page = document.page(at: requested), view.currentPage !== page {
            view.go(to: page)
        }
        if session.searchQuery != context.coordinator.appliedQuery {
            context.coordinator.appliedQuery = session.searchQuery
            if let query = session.searchQuery, let document = view.document {
                let selections = document.findString(query, withOptions: [.caseInsensitive])
                view.highlightedSelections = selections
                if let first = selections.first { view.go(to: first) }
            } else {
                view.highlightedSelections = nil
            }
        }
        // Pan is only for drawing; otherwise let the scroll view scroll.
        context.coordinator.pan?.isEnabled = session.activeTool == .draw
        context.coordinator.session = session
        context.coordinator.activity = activity
        context.coordinator.observeScrolling(in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var session: PDFEditorSession
        var activity: PDFViewerActivity?
        var pan: UIPanGestureRecognizer?
        var isSyncing = false
        var appliedQuery: String?
        private var scrollObservation: NSKeyValueObservation?

        /// Watches PDFKit's own scroll view (found once the document is shown) for the page pill.
        func observeScrolling(in view: PDFView) {
            guard scrollObservation == nil, let scrollView = Self.firstScrollView(in: view) else { return }
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.activity?.noteScroll() }
            }
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? UIScrollView { return scrollView }
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }
        private var currentPoints: [PSPoint] = []
        private var drawingPage: PDFPage?

        init(session: PDFEditorSession) { self.session = session }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UITapGestureRecognizer
        }

        @objc func pageChanged(_ notification: Notification) {
            guard !isSyncing, let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            Task { @MainActor in self.session.viewerDidShowPage(index) }
        }

        /// Normalised, displayed (top-left) coordinates of a view point on a page.
        /// `convert(_:to:)` yields unrotated page space (same space as `bounds(for:)`),
        /// so the point is mapped to base space first and then rotated for display.
        func normalized(_ location: CGPoint, in view: PDFView) -> (PDFPage, PSPoint)? {
            guard let page = view.page(for: location, nearest: true) else { return nil }
            let pagePoint = view.convert(location, to: page)
            let bounds = page.bounds(for: .mediaBox)
            let base = PSPoint(x: Double((pagePoint.x - bounds.minX) / bounds.width), y: Double(1 - (pagePoint.y - bounds.minY) / bounds.height))
            return (page, PDFGeometry.displayedPoint(fromBase: base, rotation: page.rotation))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PDFView, let (page, point) = normalized(recognizer.location(in: view), in: view), let document = view.document else { return }
            let index = document.index(for: page)
            let tool = session.activeTool
            Task { @MainActor in
                self.session.lastTapPoint = point
                switch tool {
                case .highlight:
                    let location = view.convert(recognizer.location(in: view), to: page)
                    if let selection = page.selectionForWord(at: location) {
                        let bounds = selection.bounds(for: page)
                        let size = PSSize(page.bounds(for: .mediaBox).size)
                        let base = PDFGeometry.baseNormalized(fromPagePoints: PSRect(bounds), size: size)
                        self.session.update(L("Highlight")) { $0.addMarkup(PDFMarkup(kind: .highlight(rects: [base], color: self.session.highlightColor)), toPageAt: index) }
                        Haptics.tick()
                    }
                case .signature:
                    self.session.placeSignature(at: point, pageIndex: index)
                case .text:
                    self.session.tapText(at: point, pageIndex: index, draft: self.session.textDraft)
                default:
                    break
                }
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view as? PDFView else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                currentPoints = []
                drawingPage = view.page(for: location, nearest: true)
                fallthrough
            case .changed:
                if let (page, point) = normalized(location, in: view), page === drawingPage { currentPoints.append(point) }
            case .ended, .cancelled:
                guard let page = drawingPage, let document = view.document, currentPoints.count > 1 else { return }
                let index = document.index(for: page)
                let points = currentPoints
                let width = session.inkWidth
                Task { @MainActor in
                    self.session.addInk(strokes: [BrushStroke(points: points, radius: width, hardness: 1)], pageIndex: index)
                }
                currentPoints = []
            default:
                break
            }
        }
    }
}

/// Draw-your-signature sheet.
struct SignatureSheet: View {
    let onSave: ([BrushStroke]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [BrushStroke] = []
    @State private var current: [PSPoint] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L("Sign with your finger")).font(PSFont.headline(16)).foregroundStyle(PSTheme.textSecondary)
                GeometryReader { proxy in
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white)
                        Canvas { context, size in
                            for stroke in strokes + (current.isEmpty ? [] : [BrushStroke(points: current, radius: 0.006)]) {
                                var path = Path()
                                let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                                if let first = points.first { path.move(to: first) }
                                for point in points.dropFirst() { path.addLine(to: point) }
                                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            }
                        }
                        Rectangle().fill(PSTheme.hairline).frame(height: 1).offset(y: proxy.size.height * 0.25)
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in current.append(PSPoint(x: Double(value.location.x / proxy.size.width), y: Double(value.location.y / proxy.size.height))) }
                        .onEnded { _ in strokes.append(BrushStroke(points: current, radius: 0.006)); current = [] })
                }
                .aspectRatio(3, contentMode: .fit)
                .padding(.horizontal, 20)
                HStack {
                    Button(L("Clear")) { strokes = []; current = [] }.buttonStyle(SecondaryButtonStyle())
                    Button(L("Use signature")) { onSave(strokes); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(strokes.isEmpty)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 20)
            .background(PSTheme.canvas.ignoresSafeArea())
            .navigationTitle(L("Signature"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}

struct PDFExportSheet: View {
    @Bindable var session: PDFEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?

    private var fileSizeText: String? {
        guard let url = session.exportedURL,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue else { return nil }
        return bytes < 1_048_576 ? String(format: "%.0f KB", bytes / 1024) : String(format: "%.1f MB", bytes / 1_048_576)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PSSpacing.large) {
                    pagePreview
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.document.title).font(PSFont.headline(15)).lineLimit(1)
                                HStack(spacing: 5) {
                                    Text("\(session.document.pageCount) \(L("pages"))")
                                    Text("·")
                                    Text("\(session.document.allMarkups.count) \(L("markups"))")
                                    if let fileSizeText {
                                        Text("·")
                                        Text(fileSizeText).contentTransition(.numericText())
                                    }
                                }
                                .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: session.exportedURL == nil ? "doc.badge.clock" : "checkmark.seal.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(session.exportedURL == nil ? PSTheme.textTertiary : PSTheme.success)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        Divider().overlay(PSTheme.hairline).padding(.leading, 16)
                        Button { Haptics.tap(); Task { await session.run(EditIntent(action: .extractPage)) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "photo.badge.arrow.down")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PSTheme.warning.gradient))
                                Text(L("Save current page to Photos")).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(PSTheme.textTertiary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PSPressStyle(scale: 0.99))
                    }
                    .psCard(cornerRadius: 18, shadow: false)
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .animation(PSMotion.standard, value: session.exportedURL)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Group {
                    if let url = session.exportedURL {
                        ShareLink(item: url) { Label(L("Share PDF"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(PrimaryButtonStyle())
                            .simultaneousGesture(TapGesture().onEnded { Haptics.confirm() })
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().tint(PSTheme.textPrimary)
                            Text(L("Preparing the PDF…")).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .psCard(cornerRadius: 18, shadow: false)
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.vertical, 10)
                .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
                .animation(PSMotion.standard, value: session.exportedURL == nil)
            }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            // Always re-export on open, so the shared file carries the latest edits.
            .task { await session.export() }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The current page as a sheet of paper, with its position in the document.
    private var pagePreview: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                        .padding(14)
                } else {
                    Image(systemName: "doc.text").font(.system(size: 32, weight: .light)).foregroundStyle(PSTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(PSTheme.surfaceElevated)
            Text(String(format: L("Page %d of %d"), session.document.currentPageIndex + 1, session.document.pageCount))
                .font(PSFont.mono(11)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(12)
        }
        .task {
            guard preview == nil else { return }
            preview = await session.worker.pageThumbnail(session.document.currentPageIndex, in: session.document, height: 360)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }
}
#endif
