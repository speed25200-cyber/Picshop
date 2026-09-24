#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The first screen, calm: the name and Settings, your latest project to pick
/// up, your recent work, and the dock — '+' to start, three ideas, the field
/// and the orb. Colour comes from your own pictures.
///
/// The body reads only the summaries. Thumbnails, download progress, the
/// crash report and the microphone are read by leaves, so none of them
/// redraws the screen.
public struct HomeView: View {
    @Environment(\.picshop) private var app
    @State private var pickedItem: PhotosPickerItem?
    @State private var openProject: OpenedProject?
    @State private var showsSettings = false
    @State private var pickerFilter: PHPickerFilter = .images
    @State private var showsPicker = false
    @State private var showsPDFPicker = false
    @State private var showsMagicMovie = false
    @State private var pendingMagic: MagicShortcut?
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""
    @State private var deleteTarget: ProjectSummary?
    @Namespace private var cardTransition

    /// The zoom source of the hero card.
    static let heroSourceID = "hero"

    /// A project opened in an editor, with the command to run once it is ready.
    struct OpenedProject: Identifiable {
        let summary: ProjectSummary
        /// Already in memory after an import: the editor skips the load.
        var project: Project?
        var command: String?
        /// The view the editor zooms out of; the project's cell when nil.
        var sourceID: String?
        var id: UUID { summary.id }
        var zoomSourceID: String { sourceID ?? summary.id.uuidString }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PSTheme.ink.ignoresSafeArea()
                if let library = app?.library {
                    HomeBackdropHost(library: library).ignoresSafeArea()
                }
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .bottom) { dock }
            .overlay {
                if let library = app?.library { HomeImportHUD(library: library, isHidden: showsMagicMovie) }
            }
            .task { await app?.library.reload() }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsMagicMovie) {
                MagicMovieSheet { project in
                    open(project, command: nil, sourceID: Self.heroSourceID)
                }
            }
            .fullScreenCover(item: $openProject) { opened in
                if let app {
                    EditorHost(summary: opened.summary, project: opened.project, app: app, command: opened.command)
                        .navigationTransition(.zoom(sourceID: opened.zoomSourceID, in: cardTransition))
                }
            }
            .photosPicker(isPresented: $showsPicker, selection: $pickedItem, matching: pickerFilter, photoLibrary: .shared())
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result, let app else { return }
                Task {
                    if let project = await app.library.createPDFProject(from: url) {
                        Haptics.success()
                        open(project, command: nil, sourceID: Self.heroSourceID)
                    } else {
                        Haptics.error()
                    }
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item, let app else { return }
                let magic = pendingMagic
                pendingMagic = nil
                Task {
                    if let project = await app.library.importProject(from: item) {
                        Haptics.success()
                        open(project, command: magic?.command, sourceID: Self.heroSourceID)
                    } else {
                        Haptics.error()
                    }
                    pickedItem = nil
                }
            }
            .onChange(of: showsPicker) { _, showing in
                // Dismissing the picker without a choice forgets the Magic that asked for it.
                if !showing, pickedItem == nil { pendingMagic = nil }
            }
            .alert(L("Something went wrong"), isPresented: Binding(get: { app?.library.errorMessage != nil }, set: { if !$0 { app?.library.errorMessage = nil } })) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(app?.library.errorMessage ?? "")
            }
            .alert(L("Rename"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField(L("Name"), text: $renameText)
                Button(L("Cancel"), role: .cancel) { renameTarget = nil }
                Button(L("Save")) {
                    if let target = renameTarget, let library = app?.library {
                        let title = renameText
                        Task { await library.rename(target, to: title) }
                    }
                    renameTarget = nil
                }
            }
            .confirmationDialog(deleteTarget.map { String(format: L("Delete “%@”?"), $0.title) } ?? "", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                Button(L("Delete"), role: .destructive) {
                    if let deleteTarget { Haptics.confirm(); app?.library.delete(deleteTarget) }
                    deleteTarget = nil
                }
                Button(L("Cancel"), role: .cancel) { deleteTarget = nil }
            } message: {
                Text(L("The project and its edits are removed from this iPhone. The original in Photos stays."))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        if let app {
            let library = app.library
            let summaries = library.summaries
            if let latest = summaries.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: PSSpacing.section) {
                        HomeHeader(app: app) { showsSettings = true }
                        hero(latest, library: library)
                        HomeRecentsGrid(summaries: summaries, library: library, namespace: cardTransition, actions: projectActions)
                    }
                    .padding(.bottom, PSSpacing.large)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 0) {
                    HomeHeader(app: app) { showsSettings = true }
                    if library.hasLoaded {
                        HomeEmptyState(onOpenMedia: { pick(.any(of: [.images, .videos])) }, onImportPDF: { showsPDFPicker = true })
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .animation(PSMotion.standard, value: library.hasLoaded)
            }
        }
    }

    /// The latest project, full width, to pick up where you left off.
    private func hero(_ summary: ProjectSummary, library: ProjectLibrary) -> some View {
        Button {
            Haptics.tap()
            openProject = OpenedProject(summary: summary, sourceID: Self.heroSourceID)
        } label: {
            HomeResumeCard(summary: summary, slot: library.slot(for: summary.id))
        }
        .buttonStyle(PSPressStyle(scale: 0.98))
        // The editor grows out of the hero.
        .matchedTransitionSource(id: Self.heroSourceID, in: cardTransition)
        .contextMenu { HomeProjectMenu(summary: summary, actions: projectActions) }
        .task(id: summary.modifiedAt) { await library.loadThumbnail(for: summary) }
        .padding(.horizontal, PSSpacing.page)
    }

    @ViewBuilder
    private var dock: some View {
        if let app {
            HomeDock(app: app, lastKind: app.library.summaries.first?.kind, projects: { app.library.summaries }, actions: HomeDockActions(
                pick: { pick($0) },
                importPDF: { showsPDFPicker = true },
                magicMovie: { showsMagicMovie = true },
                magic: { shortcut in
                    pendingMagic = shortcut
                    pickerFilter = shortcut.isVideo ? .videos : .images
                    showsPicker = true
                },
                open: { id in
                    guard let summary = app.library.summaries.first(where: { $0.id == id }) else { return }
                    Haptics.tap()
                    openProject = OpenedProject(summary: summary, sourceID: summary.id == app.library.summaries.first?.id ? Self.heroSourceID : nil)
                }
            ))
        }
    }

    private var projectActions: HomeProjectActions {
        HomeProjectActions(
            open: { summary in
                Haptics.tap()
                openProject = OpenedProject(summary: summary)
            },
            rename: { summary in
                renameText = summary.title
                renameTarget = summary
            },
            duplicate: { summary in
                Haptics.tap()
                guard let library = app?.library else { return }
                Task { await library.duplicate(summary) }
            },
            delete: { summary in deleteTarget = summary }
        )
    }

    private func pick(_ filter: PHPickerFilter) {
        pendingMagic = nil
        pickerFilter = filter
        showsPicker = true
    }

    private func open(_ project: Project, command: String?, sourceID: String?) {
        openProject = OpenedProject(summary: ProjectSummary(project: project), project: project, command: command, sourceID: sourceID)
    }
}

// MARK: - Header

/// The name, and the one control Home keeps at the top: Settings.
private struct HomeHeader: View {
    let app: AppEnvironment
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PSSpacing.medium) {
            Text(verbatim: "PicShop")
                .font(PSFont.largeTitle())
                .foregroundStyle(PSTheme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            PSCircleButton(systemImage: "gearshape", accessibilityLabel: L("Settings"), action: onSettings)
                .overlay { HomeHeaderStatus(app: app).allowsHitTesting(false) }
                // A report from a session that ended badly waits in Settings.
                .accessibilityValue(app.pendingCrashReport != nil ? L("A diagnostics report is waiting") : "")
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.top, PSSpacing.small)
    }
}

/// An 8 pt dot when a diagnostics report waits, and a 2 pt ring around
/// Settings while models download. A leaf: progress redraws only this.
private struct HomeHeaderStatus: View {
    let app: AppEnvironment

    var body: some View {
        let progress = app.modelInstallProgress
        ZStack {
            if let progress {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                    .stroke(PSTheme.textPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: PSMetrics.barButton + 6, height: PSMetrics.barButton + 6)
        .overlay(alignment: .topTrailing) {
            if app.pendingCrashReport != nil {
                Circle().fill(PSTheme.warning).frame(width: 8, height: 8).offset(x: -3, y: 3)
            }
        }
        .animation(PSMotion.standard, value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Hero

/// Your latest project, full width: the picture, a clear-glass caption and
/// an arrow to step back in. Its height comes from the summary, never from
/// the image, so it does not move while the picture loads or the editor
/// zooms back into it.
private struct HomeResumeCard: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot
    @Environment(\.psEffects) private var effects

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous)
        HeroFrame(isPortrait: summary.aspectRatio < 1) {
            Color.clear
                .overlay { ThumbnailImage(slot: slot, kind: summary.kind, glyphSize: 34) }
                // A soft floor so clear glass stays legible over bright pictures.
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) { caption }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(effects == .rich ? 0.4 : 0), radius: 30, y: 16)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Resume") + ", " + summary.title)
        .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        HStack(alignment: .bottom, spacing: PSSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Text(L("Edited"))
                    Text(summary.modifiedAt, format: .relative(presentation: .named))
                }
                .font(PSFont.footnote())
                .foregroundStyle(.white.opacity(0.7))
            }
            .lineLimit(1)
            .padding(.horizontal, PSSpacing.large)
            .padding(.vertical, 10)
            .psGlass(variant: .clear)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .psGlass(shape: AnyShape(Circle()), variant: .clear)
        }
        .padding(PSSpacing.medium)
    }
}

/// Full width; min(width × 5/4, 420) tall for a portrait picture, width × 10/16 otherwise.
private struct HeroFrame: Layout {
    let isPortrait: Bool
    static let maxHeight: CGFloat = 420

    func height(for width: CGFloat) -> CGFloat {
        (isPortrait ? min(width * 5 / 4, Self.maxHeight) : width * 10 / 16).rounded()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 360, height: 0)).width
        return CGSize(width: width, height: height(for: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// A project's picture from its slot, or a quiet placeholder until it
/// arrives. A leaf: only this redraws when the image lands.
struct ThumbnailImage: View {
    let slot: ThumbnailSlot
    let kind: ProjectSummary.Kind
    var glyphSize: CGFloat = 26

    var body: some View {
        ZStack {
            if let image = slot.image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                PSTheme.surface
                Image(systemName: Self.symbol(for: kind))
                    .font(.system(size: glyphSize, weight: .light))
                    .foregroundStyle(PSTheme.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: slot.image == nil)
    }

    static func symbol(for kind: ProjectSummary.Kind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "film"
        case .pdf: return "doc.text"
        }
    }
}

// MARK: - Project actions

struct HomeProjectActions {
    var open: (ProjectSummary) -> Void
    var rename: (ProjectSummary) -> Void
    var duplicate: (ProjectSummary) -> Void
    var delete: (ProjectSummary) -> Void
}

struct HomeProjectMenu: View {
    let summary: ProjectSummary
    let actions: HomeProjectActions

    var body: some View {
        Button { actions.rename(summary) } label: { Label(L("Rename"), systemImage: "pencil") }
        Button { actions.duplicate(summary) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { actions.delete(summary) } label: { Label(L("Delete"), systemImage: "trash") }
    }
}

/// 'Importing…' while a picked photo, video or PDF is copied in.
private struct HomeImportHUD: View {
    let library: ProjectLibrary
    let isHidden: Bool

    var body: some View {
        if library.isImporting, !isHidden {
            ProgressHUD(title: L("Importing…"), tone: .neutral)
        }
    }
}

// MARK: - Backdrop

/// Feeds the backdrop with the newest project's slot.
struct HomeBackdropHost: View {
    let library: ProjectLibrary

    var body: some View {
        HomeBackdrop(slot: library.summaries.first.map { library.slot(for: $0.id) })
    }
}

/// The latest project as a faint light at the top of the screen — the library
/// takes the colour of your own work, like Music does with album art. A 64 px
/// copy blurred once with Core Image and scaled up: no live blur.
struct HomeBackdrop: View {
    let slot: ThumbnailSlot?
    @State private var glow: UIImage?

    static let height: CGFloat = 420

    var body: some View {
        let source = slot?.image
        ZStack(alignment: .top) {
            PSTheme.ink
            if let glow {
                Image(uiImage: glow)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(height: Self.height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .opacity(0.35)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: PSTheme.ink.opacity(0), location: 0),
                            .init(color: PSTheme.ink.opacity(0.6), location: 0.55),
                            .init(color: PSTheme.ink, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: glow.map { ObjectIdentifier($0) })
        .task(id: source.map { ObjectIdentifier($0) }) {
            guard let source else {
                glow = nil
                return
            }
            let blurred = await Self.makeGlow(from: source)
            if !Task.isCancelled, let blurred { glow = blurred }
        }
        .accessibilityHidden(true)
    }

    /// 64 px, blurred, off the main thread.
    static func makeGlow(from image: UIImage) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let cgImage = ThumbnailIO.cgImage(from: image) else { return nil }
            let input = CIImage(cgImage: cgImage)
            let longest = max(input.extent.width, input.extent.height)
            guard longest > 0 else { return nil }
            let scale = 64 / longest
            let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 5).cropped(to: small.extent)
            guard let output = RenderContext.shared.createCGImage(blurred, from: small.extent) else { return nil }
            return UIImage(cgImage: output)
        }.value
    }
}

/// Ground behind sheets and settings: neutral ink with a faint light from
/// above, so glass has something to catch.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            PSTheme.ink
            RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .top, startRadius: 0, endRadius: 460)
        }
        .drawingGroup(opaque: true)
    }
}

/// Static mesh gradient used behind hero surfaces (GPU-cheap, no blur).
struct HeroMesh: View {
    var body: some View { IntelligenceField() }
}

// MARK: - Editor host

/// Routes a project to the right editor. The project is decoded off the main
/// thread while the card's picture holds the zoom transition; the session is
/// created once, then, and never again when Home redraws.
struct EditorHost: View {
    enum Session {
        case photo(PhotoEditorSession)
        case video(VideoEditorSession)
        case pdf(PDFEditorSession)
    }

    let summary: ProjectSummary
    let project: Project?
    let app: AppEnvironment
    let command: String?
    @State private var session: Session?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(summary: ProjectSummary, project: Project? = nil, app: AppEnvironment, command: String? = nil) {
        self.summary = summary
        self.project = project
        self.app = app
        self.command = command
    }

    var body: some View {
        ZStack {
            switch session {
            case .photo(let session)?: PhotoEditorView(session: session)
            case .video(let session)?: VideoEditorView(session: session)
            case .pdf(let session)?: PDFEditorView(session: session)
            case nil:
                EditorOpening(summary: summary, slot: app.library.slot(for: summary.id), failure: failure) { dismiss() }
            }
        }
        .task { await open() }
        .onAppear {
            app.isEditorOpen = true
            app.prewarmIntentEngine(mode: mode)
        }
        .onDisappear { app.isEditorOpen = false }
    }

    private var mode: EditorMode {
        switch summary.kind {
        case .photo: return .photo
        case .video: return .video
        case .pdf: return .pdf
        }
    }

    private func open() async {
        guard session == nil else { return }
        do {
            let loaded: Project
            if let project { loaded = project } else { loaded = try await app.library.load(summary.id) }
            session = makeSession(loaded)
        } catch {
            failure = ProjectLibrary.message(for: error)
            Haptics.error()
        }
    }

    private func makeSession(_ project: Project) -> Session {
        switch project.content {
        case .photo(let document):
            let photo = PhotoEditorSession(document: document, projectID: project.id, app: app)
            photo.pendingCommand = command
            return .photo(photo)
        case .video(let timeline):
            let video = VideoEditorSession(timeline: timeline, projectID: project.id, app: app)
            video.pendingCommand = command
            return .video(video)
        case .pdf(let document):
            return .pdf(PDFEditorSession(document: document, projectID: project.id, app: app))
        }
    }
}

/// What the editor shows while its project loads: the card's picture, fitted
/// on black, so the zoom lands on the same image. A card with Close when the
/// project cannot be read.
private struct EditorOpening: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot
    let failure: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PSTheme.canvas.ignoresSafeArea()
            if let image = slot.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.vertical, 120)
                    .opacity(failure == nil ? 1 : 0.25)
                    .ignoresSafeArea(edges: .horizontal)
            }
            if let failure {
                VStack(spacing: PSSpacing.medium) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(PSTheme.warning)
                    Text(L("This project can't be opened"))
                        .font(PSFont.headline())
                        .foregroundStyle(PSTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(failure)
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    PSCapsuleButton(L("Close"), kind: .prominent, action: onClose)
                        .padding(.top, PSSpacing.small)
                }
                .padding(PSSpacing.xLarge)
                .frame(maxWidth: 340)
                .psCard(cornerRadius: PSRadius.onboardingCard, shadow: false)
                .padding(PSSpacing.page)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if slot.image == nil {
                ProgressView().tint(PSTheme.textSecondary)
            }
        }
        .animation(PSMotion.standard, value: failure)
        .preferredColorScheme(.dark)
    }
}
#endif
