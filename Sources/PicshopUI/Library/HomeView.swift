#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The first screen, calm: the lockup, search and Settings, your latest
/// project to pick up, a one-tap strip of your photo library, your recent
/// work, and the dock — '+' to start, three ideas, the field and the orb.
/// Colour comes from your own pictures (PSBackdrop).
///
/// The body reads only the summaries. Thumbnails, the palette, the scroll
/// offset, download progress, the crash report and the microphone are read by
/// leaves, so none of them redraws the screen.
///
/// With the psBackdrop flag off, Home is the W0 screen (flat ink, a blurred
/// glow, the large title, three square columns).
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
    /// psBackdrop, read once: a flag change takes effect the next time Home appears.
    @State private var isStudio = FeatureFlags.isOn(.psBackdrop)
    /// UX 2.0: « Créer » with named tiles at the top, the projects under it, no resume hero and no bottom dock.
    @State private var isUX2 = FeatureFlags.isOn(.ux2)
    /// The latest picture's palette: read by the backdrop and the hero, never by this body.
    @State private var palette = HomePaletteModel()
    /// The scroll offset, read only by the backdrop.
    @State private var scroll = HomeScrollState()
    @State private var isSearching = false
    @State private var query = ""
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
                if isStudio {
                    if let library = app?.library {
                        HomePaletteBackdrop(library: library, palette: palette, scroll: scroll).ignoresSafeArea()
                    } else {
                        Color.psBase.ignoresSafeArea()
                    }
                } else {
                    Color.psBase.ignoresSafeArea()
                    if let library = app?.library {
                        HomeBackdropHost(library: library).ignoresSafeArea()
                    }
                }
                if isStudio { studioContent } else { content }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .bottom) { dock }
            .overlay {
                if let library = app?.library { HomeImportHUD(library: library, isHidden: showsMagicMovie) }
            }
            .task { await app?.library.reload() }
            // Once, for people onboarded before the local brain: download it over Wi‑Fi?
            .modifier(LocalBrainFirstRunPrompt(isBusy: openProject != nil || showsSettings || showsMagicMovie || showsPicker || showsPDFPicker))
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

    /// The W1 Home: lockup, Reprendre, Depuis la photothèque, Récents with a
    /// sticky filter; or, with no project, the invitation and the strip.
    @ViewBuilder
    private var studioContent: some View {
        if let app {
            let library = app.library
            let summaries = library.summaries
            if let latest = summaries.first {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PSSpacing.section, pinnedViews: [.sectionHeaders]) {
                        HomeStudioHeader(app: app, isSearching: $isSearching, query: $query) { showsSettings = true }
                        if !isSearching {
                            if isUX2 {
                                createRow
                            } else {
                                hero(latest, library: library)
                                HomeLibraryStrip(selection: $pickedItem)
                                    .padding(.horizontal, PSSpacing.page)
                            }
                        }
                        HomeRecentsGrid(summaries: isSearching ? HomeCommands.search(query, in: summaries) : summaries,
                                        library: library, namespace: cardTransition, actions: projectActions,
                                        style: .studio, searchQuery: isSearching ? query : nil)
                    }
                    .padding(.bottom, PSSpacing.large)
                    .animation(PSSpring.standard, value: isSearching)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    scroll.update(offset)
                }
            } else {
                VStack(spacing: 0) {
                    HomeStudioHeader(app: app, isSearching: .constant(false), query: .constant(""), showsSearch: false) { showsSettings = true }
                    if library.hasLoaded, isUX2 {
                        createRow
                            .padding(.top, PSSpacing.medium)
                        Text(L("No project yet. Choose Photo, Video or PDF to start."))
                            .font(.body)
                            .foregroundStyle(Color.psTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(PSSpacing.page)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    } else if library.hasLoaded {
                        HomeStudioEmptyState(selection: $pickedItem, actions: HomeStartActions(
                            pickVideo: { pick(.videos) },
                            importPDF: { showsPDFPicker = true },
                            magicMovie: { showsMagicMovie = true }
                        ))
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .animation(PSSpring.standard, value: library.hasLoaded)
            }
        }
    }

    /// The latest project, full width, to pick up where you left off.
    private func hero(_ summary: ProjectSummary, library: ProjectLibrary) -> some View {
        Button {
            Haptics.tap()
            openProject = OpenedProject(summary: summary, sourceID: Self.heroSourceID)
        } label: {
            HomeResumeCard(summary: summary, slot: library.slot(for: summary.id), palette: isStudio ? palette : nil)
        }
        .buttonStyle(PSPressStyle(scale: 0.98))
        // The editor grows out of the hero.
        .matchedTransitionSource(id: Self.heroSourceID, in: cardTransition)
        .contextMenu { HomeProjectMenu(summary: summary, actions: projectActions) }
        .task(id: summary.modifiedAt) { await library.loadThumbnail(for: summary) }
        .padding(.horizontal, PSSpacing.page)
    }

    /// UX 2.0: Photo, Vidéo, PDF, Film magique.
    private var createRow: some View {
        HomeCreateRow(pickPhoto: { pick(.images) }, pickVideo: { pick(.videos) },
                      importPDF: { showsPDFPicker = true }, magicMovie: { showsMagicMovie = true })
    }

    @ViewBuilder
    private var dock: some View {
        if let app, !isUX2 {
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

/// W0: the name, and the one control Home keeps at the top: Settings.
private struct HomeHeader: View {
    let app: AppEnvironment
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PSSpacing.medium) {
            Text(verbatim: "PicShop")
                .font(PSFont.largeTitle())
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HomeSettingsButton(app: app, action: onSettings)
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.top, PSSpacing.small)
    }
}

/// W1: the lockup (22-point mark, 28-point expanded wordmark), then Search and
/// Settings as 44-point glass circles. Search turns the lockup into a field
/// that filters the projects by title, on the device.
private struct HomeStudioHeader: View {
    let app: AppEnvironment
    @Binding var isSearching: Bool
    @Binding var query: String
    var showsSearch = true
    let onSettings: () -> Void

    @FocusState private var fieldFocused: Bool
    @Namespace private var glass

    var body: some View {
        PSGlassContainer(spacing: PSSpacing.small) {
            HStack(alignment: .center, spacing: PSSpacing.small) {
                if isSearching {
                    searchField
                        .glassEffectID("search", in: glass)
                        .transition(.opacity)
                    PSCircleButton(systemImage: "xmark", accessibilityLabel: L("Cancel")) { close() }
                        .glassEffectID("settings", in: glass)
                } else {
                    PSLockup()
                        .transition(.opacity)
                    Spacer(minLength: 0)
                    // Search and Settings: one glass shape on Home's budget.
                    if showsSearch {
                        PSCircleButton(systemImage: "magnifyingglass", accessibilityLabel: L("Search projects")) { open() }
                            .glassEffectID("search", in: glass)
                    }
                    // Two separate circles: melted into one shape, they drew an empty bubble between them.
                    HomeSettingsButton(app: app, action: onSettings)
                        .glassEffectID("settings", in: glass)
                }
            }
        }
        .frame(minHeight: PSMetrics.barButton)
        .padding(.horizontal, PSSpacing.page)
        .padding(.top, PSSpacing.small)
        .animation(PSSpring.morph, value: isSearching)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var searchField: some View {
        HStack(spacing: PSSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(PSFont.glyph(.chip))
                .foregroundStyle(Color.psTextSecondary)
            TextField(text: $query, prompt: Text(L("Search projects")).foregroundStyle(Color.psTextTertiary)) {
                Text(L("Search projects"))
            }
            .font(.body)
            .foregroundStyle(Color.psTextPrimary)
            .tint(Color.psTextPrimary)
            .focused($fieldFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, PSSpacing.large)
        .frame(maxWidth: .infinity, minHeight: PSMetrics.barButton)
        .psGlass(interactive: true)
        // The field exists only once the morph has started: focus it then.
        .onAppear { fieldFocused = true }
    }

    private func open() {
        withAnimation(PSSpring.morph) { isSearching = true }
    }

    private func close() {
        fieldFocused = false
        query = ""
        withAnimation(PSSpring.morph) { isSearching = false }
    }
}

/// Settings, with the download ring and the diagnostics dot.
private struct HomeSettingsButton: View {
    let app: AppEnvironment
    let action: () -> Void

    var body: some View {
        PSCircleButton(systemImage: "gearshape", accessibilityLabel: L("Settings"), action: action)
            .overlay { HomeHeaderStatus(app: app).allowsHitTesting(false) }
            // A report from a session that ended badly waits in Settings.
            .accessibilityValue(app.pendingCrashReport != nil ? L("A diagnostics report is waiting") : "")
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
                Circle().stroke(Color.psStrokeStrong, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                    .stroke(Color.psTextPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: PSMetrics.barButton + 6, height: PSMetrics.barButton + 6)
        .overlay(alignment: .topTrailing) {
            if app.pendingCrashReport != nil {
                Circle().fill(Color.psWarning).frame(width: 8, height: 8).offset(x: -3, y: 3)
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
///
/// The light under it is a sibling shape filled with a soft gradient of the
/// palette's glow (black without a palette), not a shadow on the picture, so
/// scrolling never pays for an offscreen blur.
private struct HomeResumeCard: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot
    var palette: HomePaletteModel?
    @Environment(\.psEffects) private var effects
    @Namespace private var glass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous)
        HeroFrame(isPortrait: summary.aspectRatio < 1) {
            Color.clear
                .overlay { ThumbnailImage(slot: slot, kind: summary.kind, glyphSize: 34) }
                // A soft floor so clear glass stays legible over bright pictures.
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, Color.psScrim], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) { caption }
        }
        .clipShape(shape)
        .background {
            if effects == .rich {
                HomeHeroGlow(palette: palette)
            }
        }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Resume") + ", " + summary.title)
        .accessibilityAddTraits(.isButton)
    }

    /// The title and the arrow: one clear-glass union (one shape on Home's glass budget), over the scrim.
    private var caption: some View {
        PSGlassContainer(spacing: PSSpacing.small) {
            captionRow
        }
        .padding(PSSpacing.medium)
    }

    private var captionRow: some View {
        HStack(alignment: .bottom, spacing: PSSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.psTextPrimary)
                HStack(spacing: 4) {
                    Text(L("Edited"))
                    Text(summary.modifiedAt, format: .relative(presentation: .named))
                }
                .font(PSFont.footnote())
                .foregroundStyle(Color.psTextSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, PSSpacing.large)
            .padding(.vertical, 10)
            .psGlass(variant: .clear)
            .glassEffectUnion(id: "hero", namespace: glass)
            Spacer(minLength: 0)
            // A capsule as wide as it is tall (a circle), so it unions with the title's capsule.
            Image(systemName: "arrow.up.right")
                .font(PSFont.glyph(.bar))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: PSMetrics.barButton, height: PSMetrics.barButton)
                .psGlass(variant: .clear)
                .glassEffectUnion(id: "hero", namespace: glass)
        }
    }
}

/// The hero's light: the palette's glow at 45 %, fading out below the card,
/// 24 points down. A gradient on a sibling shape; it cross-fades with the palette.
private struct HomeHeroGlow: View {
    let palette: HomePaletteModel?

    var body: some View {
        let glow = palette?.palette.map { Color(psColor: $0.glow) } ?? Color.psCanvas
        RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous)
            .fill(EllipticalGradient(colors: [glow.opacity(0.45), glow.opacity(0)], center: .center,
                                     startRadiusFraction: 0.3, endRadiusFraction: 0.62))
            .scaleEffect(x: 1.12, y: 1.18)
            .offset(y: 24)
            .animation(PSSpring.paletteFade, value: palette?.palette)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                Color.psRaised
                Image(systemName: Self.symbol(for: kind))
                    .font(glyphSize > 30 ? .largeTitle.weight(.light) : .title2.weight(.light))
                    .foregroundStyle(Color.psTextTertiary)
            }
        }
        .animation(PSSpring.fade, value: slot.image == nil)
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

/// The latest picture's palette, shared by the backdrop and the hero's glow.
/// Only those two leaves read it.
@MainActor
@Observable
final class HomePaletteModel {
    /// Nil until the latest thumbnail has been read (the backdrop shows the fallback).
    var palette: PSPalette?
}

/// Home's scroll offset, for the backdrop's parallax. Only the backdrop reads
/// it, so scrolling never re-evaluates Home; it moves in whole points and stops
/// changing once the mesh has faded (past 600 points).
@MainActor
@Observable
final class HomeScrollState {
    private(set) var offset: CGFloat = 0

    func update(_ raw: CGFloat) {
        let clamped = min(600, max(0, raw)).rounded()
        if clamped != offset { offset = clamped }
    }
}

/// PSBackdrop fed with the newest project's picture: its palette is derived
/// off the main thread once per picture (and cached), then cross-fades in.
/// A library without pictures keeps the fallback palette.
struct HomePaletteBackdrop: View {
    let library: ProjectLibrary
    let palette: HomePaletteModel
    let scroll: HomeScrollState

    var body: some View {
        let latest = library.summaries.first
        let slot = latest.map { library.slot(for: $0.id) }
        let image = slot?.image
        PSBackdrop(palette: palette.palette, style: .home, scrollOffset: scroll.offset)
            .task(id: image.map { ObjectIdentifier($0) }) {
                guard let image, let latest else { return }
                let key = latest.id.uuidString + "|" + String(latest.modifiedAt.timeIntervalSinceReferenceDate)
                if let cached = PSPaletteCache.cached(key) {
                    if palette.palette != cached { palette.palette = cached }
                    return
                }
                let derived = await PSPaletteCache.palette(for: image, key: key)
                guard !Task.isCancelled, let derived, derived != palette.palette else { return }
                palette.palette = derived
            }
    }
}

/// W0: feeds the backdrop with the newest project's slot.
struct HomeBackdropHost: View {
    let library: ProjectLibrary

    var body: some View {
        HomeBackdrop(slot: library.summaries.first.map { library.slot(for: $0.id) })
    }
}

/// W0: the latest project as a faint light at the top of the screen — the
/// library takes the colour of your own work, like Music does with album art.
/// A 64 px copy blurred once with Core Image and scaled up: no live blur.
struct HomeBackdrop: View {
    let slot: ThumbnailSlot?
    @State private var glow: UIImage?

    static let height: CGFloat = 420

    var body: some View {
        let source = slot?.image
        ZStack(alignment: .top) {
            Color.psBase
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
                            .init(color: Color.psBase.opacity(0), location: 0),
                            .init(color: Color.psBase.opacity(0.6), location: 0.55),
                            .init(color: Color.psBase, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .transition(.opacity)
            }
        }
        .animation(PSSpring.paletteFade, value: glow.map { ObjectIdentifier($0) })
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
            guard let output = RenderContext.background.createCGImage(blurred, from: small.extent) else { return nil }
            return UIImage(cgImage: output)
        }.value
    }
}

/// Ground behind sheets and settings (Settings, Help, the export sheets): the
/// calm PSBackdrop — the base, a light from above and grain, no mesh. With the
/// psBackdrop flag off, the W0 ink and faint light.
struct AmbientBackground: View {
    var body: some View {
        if FeatureFlags.isOn(.psBackdrop) {
            PSBackdrop(palette: nil, style: .calm)
        } else {
            ZStack {
                Color.psBase
                PSTopLight(glow: .clear, amount: 0.05)
            }
            .drawingGroup(opaque: true)
        }
    }
}

/// Static mesh gradient used behind hero surfaces (GPU-cheap, no blur).
@available(*, deprecated, message: "Use PSBackdrop or PSMark.")
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
            case .photo(let session)?: PhotoEditorView(session: session, title: summary.title)
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
            Color.psCanvas.ignoresSafeArea()
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
                        .font(.title.weight(.medium))
                        .foregroundStyle(Color.psWarning)
                    Text(L("This project can't be opened"))
                        .font(PSFont.headline())
                        .foregroundStyle(Color.psTextPrimary)
                        .multilineTextAlignment(.center)
                    Text(failure)
                        .font(PSFont.footnote())
                        .foregroundStyle(Color.psTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    PSCapsuleButton(L("Close"), kind: .prominent, action: onClose)
                        .padding(.top, PSSpacing.small)
                }
                .padding(PSSpacing.xLarge)
                .frame(maxWidth: 340)
                .psCard(cornerRadius: PSRadius.card, shadow: false)
                .padding(PSSpacing.page)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if slot.image == nil {
                ProgressView().tint(Color.psTextSecondary)
            }
        }
        .animation(PSMotion.standard, value: failure)
    }
}
#endif
