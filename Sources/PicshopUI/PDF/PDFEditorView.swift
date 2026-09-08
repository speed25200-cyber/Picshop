#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers
import PicshopCore
import PicshopIntent
import PicshopPDF

/// The PDF editing screen: PDFKit viewer, page strip, markup tools, voice orb.
public struct PDFEditorView: View {
    @State var session: PDFEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var textDraft = ""
    @State private var pickedImage: PhotosPickerItem?

    public init(session: PDFEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        EditorChrome {
            PDFViewerRepresentable(session: session)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        } top: {
            EditorTopBar(
                title: L("PDF"),
                subtitle: String(format: L("Page %d of %d"), session.document.currentPageIndex + 1, session.document.pageCount),
                canUndo: session.history.canUndo, canRedo: session.history.canRedo,
                onClose: { session.teardown(); dismiss() },
                onUndo: { session.undo() }, onRedo: { session.redo() },
                onHelp: { session.showsHelp = true }, onExport: { session.export(); session.showsExport = true })
        } bottom: {
            bottomArea
        }
        .overlay {
            if session.isProcessing { ProgressHUD(title: session.processingTitle) }
        }
        .overlay(alignment: .top) {
            if let toast = session.toast {
                ToastView(text: toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", tint: toast.isError ? PSTheme.danger : PSTheme.success)
                    .padding(.top, 60).id(toast.id)
            }
        }
        .onAppear { session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .pdf) }
        .sheet(isPresented: $session.showsSignatureSheet) { SignatureSheet { strokes in session.saveSignature(strokes: strokes) } }
        .sheet(isPresented: $session.showsExport) { PDFExportSheet(session: session) }
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

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let tool = session.activeTool {
                let group = PDFEditorSession.Tool.groups.first { $0.contains(tool) }
                let grouped = (group?.tools.count ?? 1) > 1
                ToolPanelContainer(title: grouped ? group?.title ?? tool.title : tool.title, symbol: grouped ? group?.symbol ?? tool.symbol : tool.symbol,
                                   onClose: { session.activeTool = nil },
                                   modes: grouped ? AnyView(ModeSegments(modes: group?.tools ?? [], selection: $session.activeTool, title: { $0.title }, symbol: { $0.symbol })) : nil) {
                    toolPanel(tool)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let app {
                VoiceStrip(voice: app.voice, isBusy: session.isProcessing, busyTitle: session.processingTitle,
                           transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                           showsHint: session.activeTool == nil,
                           onChoose: { _ in }, onChooseAll: {}, onCancel: { session.pendingClarification = nil })
            }
            HStack(spacing: 8) {
                GroupedToolDock(groups: PDFEditorSession.Tool.groups, selection: $session.activeTool)
                if let app { MicButton(voice: app.voice, isBusy: session.isProcessing) }
            }
        }
        .onChange(of: session.activeTool) { _, tool in
            if tool == .signature, SignatureStore.currentAsset() == nil { session.showsSignatureSheet = true }
            if tool == .image { session.showsImagePicker = true }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(PSTheme.canvas.ignoresSafeArea(edges: .bottom))
        .animation(.spring(duration: 0.32, bounce: 0.12), value: session.activeTool)
    }

    @ViewBuilder
    private func toolPanel(_ tool: PDFEditorSession.Tool) -> some View {
        switch tool {
        case .pages:
            PagesStrip(session: session)
        case .draw:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach([PSColor.red, .blue, .black, .green, .orange, .purple], id: \.self) { color in
                        Button { session.inkColor = color } label: {
                            Circle().fill(Color(cgColor: color.cgColor)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(session.inkColor == color ? PSTheme.accent : PSTheme.hairline, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    PanelChip(title: L("Undo stroke"), symbol: "arrow.uturn.backward") { session.removeLastMarkup(onPage: session.document.currentPageIndex) }
                }
                ParameterSlider(title: L("Pen width"), value: $session.inkWidth, range: 0.001...0.015, bipolar: false)
                Text(L("Draw directly on the page.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .highlight:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach([PSColor.yellow, .green, .pink, .teal, .orange], id: \.self) { color in
                        Button { session.highlightColor = color } label: {
                            Circle().fill(Color(cgColor: color.cgColor)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(session.highlightColor == color ? PSTheme.accent : PSTheme.hairline, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    PanelChip(title: L("Undo"), symbol: "arrow.uturn.backward") { session.removeLastMarkup(onPage: session.document.currentPageIndex) }
                }
                Text(L("Tap a word to highlight it, or say “surligne « total »”.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .text:
            HStack(spacing: 8) {
                TextField(L("Type text, then tap the page"), text: $textDraft)
                    .textFieldStyle(.plain).font(PSFont.body(15)).foregroundStyle(PSTheme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10).background(PSTheme.hairline, in: Capsule())
                Button {
                    let text = textDraft.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    session.addText(text, at: session.lastTapPoint, pageIndex: session.document.currentPageIndex)
                    textDraft = ""
                } label: { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                    .buttonStyle(.plain).foregroundStyle(.black).psGlass(tint: PSTheme.accent, interactive: true, shape: AnyShape(Circle()))
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

/// Thumbnail strip with delete/rotate/duplicate actions.
struct PagesStrip: View {
    @Bindable var session: PDFEditorSession

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(session.document.pages.enumerated()), id: \.element.id) { index, page in
                        let selected = index == session.document.currentPageIndex
                        VStack(spacing: 4) {
                            PageThumbnail(session: session, index: index)
                                .frame(height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? PSTheme.accent : PSTheme.hairline, lineWidth: selected ? 2.5 : 1))
                            Text("\(index + 1)").font(PSFont.caption(10)).foregroundStyle(selected ? PSTheme.accent : PSTheme.textSecondary)
                        }
                        .onTapGesture { Haptics.tick(); session.update(L("Page")) { $0.goToPage(index) } }
                        .contextMenu {
                            Button { Task { await session.run(EditIntent(action: .rotatePage, degrees: 90, index: index + 1)) } } label: { Label(L("Rotate"), systemImage: "rotate.right") }
                            Button { Task { await session.run(EditIntent(action: .duplicatePage, index: index + 1)) } } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
                            Button { Task { await session.run(EditIntent(action: .extractPage, index: index + 1)) } } label: { Label(L("Save as photo"), systemImage: "photo") }
                            Button(role: .destructive) { Task { await session.run(EditIntent(action: .deletePage, index: index + 1)) } } label: { Label(L("Delete"), systemImage: "trash") }
                        }
                        .id(page.id)
                    }
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

struct PageThumbnail: View {
    let session: PDFEditorSession
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { PSTheme.surfaceElevated }
        }
        .task(id: session.document.pages[index].hashValue) {
            if let page = session.composed?.page(at: index) { image = session.services.thumbnail(page: page, height: 96) }
        }
    }
}

/// PDFKit viewer that forwards taps and pen strokes to the session.
struct PDFViewerRepresentable: UIViewRepresentable {
    let session: PDFEditorSession

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(PSTheme.canvas)
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
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var session: PDFEditorSession
        var pan: UIPanGestureRecognizer?
        var isSyncing = false
        var appliedQuery: String?
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
                    Haptics.tick()
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(session.document.pageCount) \(L("pages")) · \(session.document.allMarkups.count) \(L("markups"))").font(PSFont.caption()).foregroundStyle(PSTheme.textSecondary)
                    if let url = session.exportedURL {
                        ShareLink(item: url) { Label(L("Share PDF"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(PrimaryButtonStyle()).listRowBackground(Color.clear)
                    }
                    Button { Task { await session.run(EditIntent(action: .extractPage)) } } label: { Label(L("Save current page to Photos"), systemImage: "photo").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle()).listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Export"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            .onAppear { if session.exportedURL == nil { session.export() } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}

extension PDFEditorSession.Tool {
    /// Dock entries, grouped by purpose. Sub-modes appear as segments in the panel.
    static var groups: [ToolGroup<PDFEditorSession.Tool>] {
        [
            ToolGroup(id: "pages", title: L("Pages"), symbol: "doc.on.doc", tools: [.pages]),
            ToolGroup(id: "markup", title: L("Mark up"), symbol: "highlighter", tools: [.highlight, .draw]),
            ToolGroup(id: "add", title: L("Add"), symbol: "plus.square.on.square", tools: [.text, .signature, .image]),
        ]
    }
}
#endif
