#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore

/// The first screen.
///
/// The rhythm of Apple's media apps: a large title with its chrome in glass
/// beside it, your latest project as the hero, three quiet ways to start, a
/// row of Magic — one-tap results that open the editor already doing the
/// thing — and your projects. Colour comes from your own pictures; the
/// spectrum only marks what the AI does.
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
    @State private var filter: LibraryFilter = .all
    @State private var renameTarget: Project?
    @State private var renameText = ""
    @State private var deleteTarget: Project?
    @Namespace private var cardTransition
    @Namespace private var headerGlass

    /// The zoom source of the hero card.
    static let heroSourceID = "hero"
    /// The projects filter appears once the library is this large.
    static let filterThreshold = 6

    /// A project opened in an editor, with the command to run once it is ready.
    struct OpenedProject: Identifiable {
        let project: Project
        var command: String?
        /// The view the editor zooms out of; the project's card when nil.
        var sourceID: String? = nil
        var id: UUID { project.id }
        var zoomSourceID: String { sourceID ?? project.id.uuidString }
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, photos, videos, pdfs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All")
            case .photos: return L("Photos")
            case .videos: return L("Videos")
            case .pdfs: return L("PDFs")
            }
        }
        func matches(_ project: Project) -> Bool {
            switch self {
            case .all: return true
            case .photos: return !project.isVideo && !project.isPDF
            case .videos: return project.isVideo
            case .pdfs: return project.isPDF
            }
        }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                HomeBackdrop(image: app?.library.projects.first.flatMap { app?.library.thumbnail(for: $0) })
                    .ignoresSafeArea()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsMagicMovie) {
                MagicMovieSheet { project in
                    openProject = OpenedProject(project: project, command: nil, sourceID: Self.heroSourceID)
                }
            }
            .fullScreenCover(item: $openProject) { opened in
                if let app {
                    EditorHost(project: opened.project, app: app, command: opened.command)
                        .navigationTransition(.zoom(sourceID: opened.zoomSourceID, in: cardTransition))
                }
            }
            .photosPicker(isPresented: $showsPicker, selection: $pickedItem, matching: pickerFilter, photoLibrary: .shared())
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result, let app else { return }
                if let project = app.library.createPDFProject(from: url) {
                    Haptics.success()
                    openProject = OpenedProject(project: project, command: nil, sourceID: Self.heroSourceID)
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item, let app else { return }
                let magic = pendingMagic
                pendingMagic = nil
                Task {
                    if let project = await app.library.importProject(from: item) {
                        Haptics.success()
                        openProject = OpenedProject(project: project, command: magic?.command, sourceID: Self.heroSourceID)
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
                    if let renameTarget { app?.library.rename(renameTarget, to: renameText) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: PSSpacing.section) {
                header
                hero
                createRow
                magicSection
                library
            }
            .padding(.top, PSSpacing.small)
            .padding(.bottom, PSSpacing.xxLarge + PSSpacing.small)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if app?.library.isImporting == true, !showsMagicMovie {
                ProgressHUD(title: L("Importing…"))
            }
        }
    }

    /// Models downloading or a hot phone: the one reason to show the AI status.
    private var showsStatus: Bool {
        guard let app else { return false }
        return app.modelInstallProgress != nil || app.performance.tier >= .conserve
    }

    /// The large title, and beside it Settings and — only while there is
    /// something to say — the AI status, in one glass group so the status
    /// grows out of the settings button.
    private var header: some View {
        HStack(alignment: .center, spacing: PSSpacing.medium) {
            Text("PicShop")
                .font(PSFont.largeTitle())
                .foregroundStyle(PSTheme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            PSGlassContainer(spacing: PSSpacing.small) {
                HStack(spacing: PSSpacing.small) {
                    if let app, showsStatus {
                        HomeAIStatusButton(progress: app.modelInstallProgress, governor: app.performance, namespace: headerGlass)
                            .transition(.scale.combined(with: .opacity))
                    }
                    HomeCircleButton(label: L("Settings"), glassID: "settings", namespace: headerGlass) {
                        showsSettings = true
                    } content: {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .medium)).foregroundStyle(PSTheme.textPrimary)
                            // A report from a session that ended badly waits in Settings.
                            .overlay(alignment: .topTrailing) {
                                if app?.pendingCrashReport != nil {
                                    Circle().fill(PSTheme.warning).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                }
                            }
                    }
                    .accessibilityValue(app?.pendingCrashReport != nil ? L("A diagnostics report is waiting") : "")
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .animation(PSMotion.standard, value: showsStatus)
    }

    /// The latest project, full width, to pick up where you left off; or,
    /// on a first visit, an invitation to just say it.
    @ViewBuilder
    private var hero: some View {
        if let library = app?.library, let latest = library.projects.first {
            Button {
                Haptics.tap()
                openProject = OpenedProject(project: latest, command: nil, sourceID: Self.heroSourceID)
            } label: {
                HomeResumeCard(project: latest, library: library)
            }
            .buttonStyle(PSPressStyle(scale: 0.98))
            // The editor grows out of the hero.
            .matchedTransitionSource(id: Self.heroSourceID, in: cardTransition)
            .contextMenu { projectMenu(latest) }
            .padding(.horizontal, PSSpacing.page)
        } else if app != nil {
            Button {
                Haptics.tap()
                pick(.any(of: [.images, .videos]))
            } label: {
                HomeEmptyHero()
            }
            .buttonStyle(PSPressStyle(scale: 0.98))
            .accessibilityLabel(L("Say what you want to do"))
            .accessibilityHint(L("Pick a photo or a video, then just say what you want."))
            .padding(.horizontal, PSSpacing.page)
        }
    }

    /// Three quiet ways to start.
    private var createRow: some View {
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            SectionTitle(title: L("New"))
            PSGlassContainer(spacing: PSSpacing.xSmall) {
                HStack(spacing: PSSpacing.medium) {
                    HomeCreateButton(title: L("Photo"), symbol: "photo") { pick(.images) }
                    HomeCreateButton(title: L("Video"), symbol: "video") { pick(.videos) }
                    HomeCreateButton(title: L("PDF"), symbol: "doc.richtext") { showsPDFPicker = true }
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
    }

    private func pick(_ filter: PHPickerFilter) {
        pendingMagic = nil
        pickerFilter = filter
        showsPicker = true
    }

    private var magicSection: some View {
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            SectionTitle(title: L("Magic"))
                .padding(.horizontal, PSSpacing.page)
            ScrollView(.horizontal) {
                HStack(spacing: PSSpacing.medium) {
                    MagicMovieCard { showsMagicMovie = true }
                    ForEach(MagicShortcut.allCases) { shortcut in
                        MagicCard(shortcut: shortcut) {
                            pendingMagic = shortcut
                            pickerFilter = shortcut.isVideo ? .videos : .images
                            showsPicker = true
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, PSSpacing.page, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private var library: some View {
        if let library = app?.library, !library.projects.isEmpty {
            let filterable = library.projects.count > Self.filterThreshold
            let active = filterable ? filter : .all
            let shown = library.projects.filter(active.matches)
            VStack(alignment: .leading, spacing: PSSpacing.medium) {
                HStack(alignment: .center, spacing: PSSpacing.small) {
                    SectionTitle(title: active == .all ? L("Projects") : active.title, count: shown.count)
                    if filterable { filterMenu }
                }
                .padding(.horizontal, PSSpacing.page)
                if shown.isEmpty {
                    filterEmptyState
                } else {
                    projectGrid(shown)
                }
            }
        }
    }

    /// Shown once the library is large enough to need it.
    private var filterMenu: some View {
        Menu {
            Picker(L("Projects"), selection: $filter.animation(PSMotion.standard)) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(filter == .all ? PSTheme.textPrimary : Color.black)
                .frame(width: 44, height: 44)
                .modifier(HomeCircleSurface(isSelected: filter != .all))
                .contentShape(Circle())
        }
        .accessibilityLabel(L("Filter"))
        .accessibilityValue(filter.title)
        .onChange(of: filter) { _, _ in Haptics.tick() }
    }

    private func projectGrid(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: PSSpacing.medium), GridItem(.flexible(), spacing: PSSpacing.medium)], spacing: PSSpacing.mediumLarge) {
            ForEach(projects) { project in
                Button {
                    Haptics.tap()
                    openProject = OpenedProject(project: project, command: nil)
                } label: {
                    // The editor grows out of the picture the user tapped.
                    ProjectCard(project: project, library: app?.library, transitionNamespace: cardTransition)
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .contextMenu {
                    projectMenu(project)
                } preview: {
                    ProjectCard(project: project, library: app?.library)
                        .frame(width: 260)
                        .padding(PSSpacing.medium)
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .animation(PSMotion.standard, value: projects.map(\.id))
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button { renameText = project.title; renameTarget = project } label: { Label(L("Rename"), systemImage: "pencil") }
        Button { Haptics.tap(); app?.library.duplicate(project) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { deleteTarget = project } label: { Label(L("Delete"), systemImage: "trash") }
    }

    private var filterEmptyState: some View {
        VStack(spacing: PSSpacing.small) {
            Image(systemName: filter == .videos ? "film" : (filter == .pdfs ? "doc.text" : "photo.on.rectangle"))
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(PSTheme.textTertiary)
            Text(L("Nothing here yet.")).font(PSFont.control(selected: true)).foregroundStyle(PSTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PSSpacing.xxLarge)
        .padding(.horizontal, PSSpacing.page)
        .transition(.opacity)
    }
}

// MARK: - Header

/// The glass of a 44-point round header control, flat at `.minimal`
/// effects. Selected is white, for black content.
private struct HomeCircleSurface: ViewModifier {
    var isSelected = false
    var glassID: String?
    var namespace: Namespace.ID?
    @Environment(\.psEffects) private var effects

    @ViewBuilder
    func body(content: Content) -> some View {
        if effects == .minimal {
            content.background(Circle().fill(isSelected ? Color.white : PSTheme.surfaceFlat))
        } else if let glassID, let namespace {
            content
                .glassEffect(glass, in: .circle)
                .glassEffectID(glassID, in: namespace)
        } else {
            content.glassEffect(glass, in: .circle)
        }
    }

    private var glass: Glass {
        isSelected ? Glass.regular.tint(.white).interactive() : Glass.regular.interactive()
    }
}

/// A round glass button in the Home header.
private struct HomeCircleButton<Content: View>: View {
    let label: String
    let glassID: String
    let namespace: Namespace.ID
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            content()
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(HomeCircleSurface(glassID: glassID, namespace: namespace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small ring beside Settings while the large AI models download, or a
/// thermometer while the phone runs hot. The details are in a popover.
private struct HomeAIStatusButton: View {
    let progress: Double?
    let governor: PerformanceGovernor
    let namespace: Namespace.ID
    @State var showsDetails = false

    private var isHot: Bool { governor.tier >= .conserve }

    var body: some View {
        HomeCircleButton(label: progress != nil ? L("Installing AI models") : governor.statusTitle, glassID: "status", namespace: namespace) {
            showsDetails = true
        } content: {
            glyph
        }
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) %" } ?? "")
        .popover(isPresented: $showsDetails) {
            details
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if let progress {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                    .stroke(PSTheme.voice, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(PSMotion.standard, value: progress)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PSTheme.textPrimary)
            }
            .frame(width: 22, height: 22)
        } else {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PSTheme.warning)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PSSpacing.large) {
            if let progress {
                VStack(alignment: .leading, spacing: PSSpacing.small) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Installing AI models")).font(PSFont.headline())
                        Spacer(minLength: PSSpacing.small)
                        Text("\(Int((progress * 100).rounded())) %")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(PSTheme.textSecondary)
                            .contentTransition(.numericText())
                    }
                    ProgressView(value: progress).tint(PSTheme.voice)
                    Text(L("The large models download over Wi‑Fi. Everything else already works."))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isHot {
                VStack(alignment: .leading, spacing: PSSpacing.xSmall) {
                    Label(governor.statusTitle, systemImage: governor.statusSymbol)
                        .font(PSFont.headline())
                        .symbolRenderingMode(.hierarchical)
                    Text(L("PicShop is rendering lighter previews to keep your iPhone cool."))
                        .font(PSFont.footnote())
                        .foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(PSTheme.textPrimary)
        .padding(PSSpacing.mediumLarge)
        .frame(width: 300, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Hero

/// Your latest project, full width: the picture, a clear-glass caption and
/// an arrow to step back in.
private struct HomeResumeCard: View {
    let project: Project
    /// Read here rather than by the caller, so a thumbnail arriving repaints only this card.
    let library: ProjectLibrary?
    @State var width: CGFloat = 0
    @Environment(\.psEffects) private var effects

    private static let maxHeight: CGFloat = 440

    /// 4:5 for a portrait picture, 16:10 otherwise, never taller than 440.
    private func height(for image: UIImage?) -> CGFloat {
        let portrait = image.map { $0.size.height > $0.size.width } ?? false
        let ratio: CGFloat = portrait ? 4.0 / 5.0 : 16.0 / 10.0
        guard width > 0 else { return portrait ? Self.maxHeight : 220 }
        return min(Self.maxHeight, (width / ratio).rounded())
    }

    var body: some View {
        let image = library?.thumbnail(for: project)
        let shape = RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height(for: image))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                width = newWidth
            }
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        PSTheme.surface
                        Image(systemName: project.isPDF ? "doc.text" : (project.isVideo ? "film" : "photo"))
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(PSTheme.textTertiary)
                    }
                }
            }
            // A soft floor so clear glass stays legible over bright pictures.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { caption }
            .clipShape(shape)
            .shadow(color: .black.opacity(effects == .rich ? 0.4 : 0), radius: 30, y: 16)
            .contentShape(shape)
            .animation(PSMotion.standard, value: image == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Resume") + ", " + project.title)
    }

    private var caption: some View {
        HStack(alignment: .bottom, spacing: PSSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Text(L("Resume"))
                    Text(verbatim: "·")
                    Text(project.modifiedAt, format: .relative(presentation: .named))
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

/// First visit: nothing to resume yet, so the hero invites the one thing
/// PicShop is for. The spectrum is earned here — it is the voice.
private struct HomeEmptyHero: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            PSTheme.surface
            IntelligenceField().opacity(0.5)
            LinearGradient(colors: [.clear, PSTheme.ink.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: PSSpacing.medium) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Say what you want to do"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Pick a photo or a video, then just say what you want."))
                        .font(PSFont.footnote())
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .psGlass(shape: AnyShape(Circle()), variant: .clear)
            }
            .padding(PSSpacing.mediumLarge)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// A calm glass capsule to start a project.
private struct HomeCreateButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.psEffects) private var effects
    @ScaledMetric(relativeTo: .subheadline) var height: CGFloat = 52

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(PSFont.control(selected: true))
            }
            .foregroundStyle(PSTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Capsule())
            .modifier(HomeCreateSurface(isFlat: effects == .minimal))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct HomeCreateSurface: ViewModifier {
    let isFlat: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFlat {
            content.background(Capsule().fill(PSTheme.surfaceFlat))
        } else {
            content.glassEffect(Glass.regular.interactive(), in: .capsule)
        }
    }
}

// MARK: - Magic shortcuts

/// One-tap results from Home: pick a photo or a video and the editor opens
/// already doing the thing, through the same command pipeline as the voice.
enum MagicShortcut: String, CaseIterable, Identifiable {
    case captions, highlights, jumpCuts, fillers, vertical, eraseObjects, expand, cutout, enhance, portrait

    var id: String { rawValue }

    var isVideo: Bool {
        switch self {
        case .captions, .highlights, .jumpCuts, .fillers, .vertical: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .captions: return L("Auto captions")
        case .jumpCuts: return L("Jump cuts")
        case .highlights: return L("Highlights")
        case .fillers: return L("No more “euh”")
        case .vertical: return L("Vertical video")
        case .eraseObjects: return L("Clean up")
        case .expand: return L("Expand")
        case .cutout: return L("Cut out")
        case .enhance: return L("Enhance")
        case .portrait: return L("Portrait blur")
        }
    }

    var subtitle: String {
        switch self {
        case .captions: return L("Subtitles from the voice, word by word")
        case .jumpCuts: return L("Every pause, gone")
        case .highlights: return L("A 30-second recap of the best moments")
        case .fillers: return L("Hesitations and stutters, cut")
        case .vertical: return L("9:16 that follows the subject")
        case .eraseObjects: return L("Clear the background of passers-by")
        case .expand: return L("More picture around it, invented")
        case .cutout: return L("The subject, on a clean background")
        case .enhance: return L("Light, colour and detail in one tap")
        case .portrait: return L("A soft background, like a big lens")
        }
    }

    var symbol: String {
        switch self {
        case .captions: return "captions.bubble.fill"
        case .jumpCuts: return "scissors"
        case .highlights: return "star.square.on.square"
        case .fillers: return "waveform.badge.minus"
        case .vertical: return "rectangle.portrait.and.arrow.forward"
        case .eraseObjects: return "person.2.slash"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .cutout: return "person.crop.rectangle.stack"
        case .enhance: return "wand.and.stars"
        case .portrait: return "camera.aperture"
        }
    }

    /// The command the editor runs, in the interface language.
    var command: String {
        let fr = psPrefersFrench
        switch self {
        case .captions: return fr ? "ajoute des sous-titres" : "add captions"
        case .jumpCuts: return fr ? "enlève les blancs" : "remove the pauses"
        case .highlights: return fr ? "fais un résumé de 30 secondes" : "make a 30 second recap"
        case .fillers: return fr ? "enlève les euh" : "remove the ums"
        case .vertical: return fr ? "passe en vertical en suivant le sujet" : "smart reframe to vertical"
        case .eraseObjects: return fr ? "enlève les passants" : "remove the passers-by"
        case .expand: return fr ? "étends l'image" : "expand the image"
        case .cutout: return fr ? "enlève le fond" : "remove the background"
        case .enhance: return fr ? "améliore la photo" : "auto enhance"
        case .portrait: return fr ? "floute l'arrière-plan" : "blur the background"
        }
    }
}

/// A Magic shortcut: a calm card; the spectrum lives on the glyph only.
private struct MagicCard: View {
    let shortcut: MagicShortcut
    let action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) var width: CGFloat = 152
    @ScaledMetric(relativeTo: .subheadline) var height: CGFloat = 168

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous)
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    MagicGlyph(size: 17, symbol: shortcut.symbol)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.08), in: Circle())
                    Spacer(minLength: 0)
                    Image(systemName: shortcut.isVideo ? "film" : "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(PSTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: PSSpacing.medium)
                Text(shortcut.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PSTheme.textPrimary)
                    .lineLimit(1)
                Text(shortcut.subtitle)
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(PSSpacing.large)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color.white.opacity(0.06), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .accessibilityLabel(shortcut.title)
        .accessibilityHint(shortcut.subtitle)
    }
}

/// The lead Magic card and the one colourful card on Home: a still
/// spectrum behind "Magic Movie".
private struct MagicMovieCard: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) var width: CGFloat = 232
    @ScaledMetric(relativeTo: .subheadline) var height: CGFloat = 168

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous)
        Button {
            Haptics.magic()
            action()
        } label: {
            ZStack(alignment: .bottomLeading) {
                IntelligenceField(animated: false)
                Color.black.opacity(0.25)
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: PSSpacing.medium)
                    Text(L("Magic Movie"))
                        .font(PSFont.section())
                        .foregroundStyle(.white)
                    Text(L("Clips + a song → an edit on the beat"))
                        .font(PSFont.footnote())
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PSSpacing.large)
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .accessibilityLabel(L("Magic Movie"))
        .accessibilityHint(L("Clips + a song → an edit on the beat"))
    }
}

// MARK: - Backdrop and cards

/// The latest project, blurred into a faint light at the top of the screen —
/// the library takes the colour of your own work, like Music does with
/// album art. Plain ink before there is any.
struct HomeBackdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            PSTheme.ink
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 520)
                    .blur(radius: 80, opaque: true)
                    .saturation(1.1)
                    .opacity(0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .transition(.opacity)
                LinearGradient(stops: [
                    .init(color: PSTheme.ink.opacity(0.2), location: 0),
                    .init(color: PSTheme.ink.opacity(0.75), location: 0.3),
                    .init(color: PSTheme.ink, location: 0.55),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: image == nil)
        .drawingGroup(opaque: true)
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

/// A project in the grid: the picture (4:5, no border), then its title and
/// a quiet date underneath, as in Photos' albums.
struct ProjectCard: View {
    let project: Project
    /// The card reads its own thumbnail: read in the grid's body instead, one
    /// image arriving would repaint every card.
    let library: ProjectLibrary?
    /// When set, the picture (not the caption) is the editor's zoom source,
    /// under the project's id.
    var transitionNamespace: Namespace.ID? = nil

    private var thumbnail: UIImage? { library?.thumbnail(for: project) }

    /// Duration or page count; photos need none.
    private var meta: String? {
        switch project.content {
        case .photo: return nil
        case .video(let timeline):
            let total = Int(max(0, timeline.duration).rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        case .pdf(let document): return String(format: L("%d pages"), document.pageCount)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(PSFont.control(selected: true))
                    .foregroundStyle(PSTheme.textPrimary)
                Text(project.modifiedAt, format: .relative(presentation: .named))
                    .font(PSFont.footnote())
                    .foregroundStyle(PSTheme.textSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.title)
    }

    @ViewBuilder
    private var picture: some View {
        if let transitionNamespace {
            image.matchedTransitionSource(id: project.id.uuidString, in: transitionNamespace)
        } else {
            image
        }
    }

    private var image: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous)
        return Color.clear
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    ZStack {
                        PSTheme.surface
                        Image(systemName: project.isPDF ? "doc.text" : (project.isVideo ? "film" : "photo"))
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(PSTheme.textTertiary)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let meta {
                    HStack(spacing: 4) {
                        Image(systemName: project.isPDF ? "doc.text.fill" : "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(meta).font(.caption2.monospacedDigit().weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, PSSpacing.small)
                    .frame(height: 24)
                    .psGlass(variant: .clear)
                    .padding(PSSpacing.small)
                }
            }
            .clipShape(shape)
            .contentShape(shape)
    }
}

/// Routes a project to the right editor. The session is created once, when the
/// cover is presented, so the editor is the first and only content of the cover.
struct EditorHost: View {
    enum Session {
        case photo(PhotoEditorSession)
        case video(VideoEditorSession)
        case pdf(PDFEditorSession)
    }

    @State private var session: Session

    init(project: Project, app: AppEnvironment, command: String? = nil) {
        let session: Session
        switch project.content {
        case .photo(let document):
            let photo = PhotoEditorSession(document: document, projectID: project.id, app: app)
            photo.pendingCommand = command
            session = .photo(photo)
        case .video(let timeline):
            let video = VideoEditorSession(timeline: timeline, projectID: project.id, app: app)
            video.pendingCommand = command
            session = .video(video)
        case .pdf(let document): session = .pdf(PDFEditorSession(document: document, projectID: project.id, app: app))
        }
        _session = State(initialValue: session)
    }

    var body: some View {
        switch session {
        case .photo(let session): PhotoEditorView(session: session)
        case .video(let session): VideoEditorView(session: session)
        case .pdf(let session): PDFEditorView(session: session)
        }
    }
}
#endif
