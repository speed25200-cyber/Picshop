#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore

/// The first screen.
///
/// A large title over a backdrop made from your latest work, two big ways to
/// start (a photo, a video), a row of Magic — one-tap results that open the
/// editor already doing the thing — and your projects. The same rhythm as
/// Apple's own media apps.
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
    @Namespace private var filterIndicator
    @Namespace private var cardTransition

    /// A project opened in an editor, with the command to run once it is ready.
    struct OpenedProject: Identifiable {
        let project: Project
        var command: String?
        var id: UUID { project.id }
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
                    openProject = OpenedProject(project: project, command: nil)
                }
            }
            .fullScreenCover(item: $openProject) { opened in
                if let app {
                    EditorHost(project: opened.project, app: app, command: opened.command)
                        .navigationTransition(.zoom(sourceID: opened.project.id, in: cardTransition))
                }
            }
            .photosPicker(isPresented: $showsPicker, selection: $pickedItem, matching: pickerFilter, photoLibrary: .shared())
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result, let app else { return }
                if let project = app.library.createPDFProject(from: url) {
                    Haptics.success()
                    openProject = OpenedProject(project: project, command: nil)
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item, let app else { return }
                let magic = pendingMagic
                pendingMagic = nil
                Task {
                    if let project = await app.library.importProject(from: item) {
                        Haptics.success()
                        openProject = OpenedProject(project: project, command: magic?.command)
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
        .tint(PSTheme.accent)
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PSSpacing.xxLarge) {
                header
                createRow
                magicSection
                if let app, let progress = app.modelInstallProgress {
                    ModelInstallBanner(progress: progress)
                        .padding(.horizontal, PSSpacing.page)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let app, app.performance.tier >= .conserve {
                    ThermalBanner(governor: app.performance)
                        .padding(.horizontal, PSSpacing.page)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                library
            }
            .padding(.top, 6)
            .padding(.bottom, 40)
            .animation(PSMotion.standard, value: app?.modelInstallProgress == nil)
            .animation(PSMotion.standard, value: app?.performance.tier)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if app?.library.isImporting == true, !showsMagicMovie {
                ProgressHUD(title: L("Importing…"))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(PSFont.label(12)).textCase(.uppercase).tracking(0.9)
                    .foregroundStyle(PSTheme.textTertiary)
                Text("PicShop").font(PSFont.display(42)).foregroundStyle(PSTheme.textPrimary).tracking(-1.6)
                Text(L("Photo and video, magically.")).font(PSFont.body(16)).foregroundStyle(PSTheme.textSecondary)
            }
            Spacer()
            GlassIconButton("gearshape", label: L("Settings"), size: 40) { showsSettings = true }
                .padding(.top, 14)
        }
        .padding(.horizontal, PSSpacing.page)
    }

    /// Two large ways to start, and a quiet third for documents.
    private var createRow: some View {
        VStack(spacing: PSSpacing.medium) {
            HStack(spacing: PSSpacing.medium) {
                CreateTile(title: L("Photo"), subtitle: L("Retouch, erase, restyle"), symbol: "camera.macro", colors: [Color(red: 0.16, green: 0.38, blue: 0.95), Color(red: 0.05, green: 0.10, blue: 0.30)]) {
                    pendingMagic = nil
                    pickerFilter = .images
                    showsPicker = true
                }
                CreateTile(title: L("Video"), subtitle: L("Cut, grade, caption"), symbol: "film", colors: [Color(red: 0.62, green: 0.22, blue: 0.86), Color(red: 0.16, green: 0.05, blue: 0.28)]) {
                    pendingMagic = nil
                    pickerFilter = .videos
                    showsPicker = true
                }
            }
            Button {
                Haptics.tap()
                showsPDFPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 16, weight: .semibold)).foregroundStyle(PSTheme.textPrimary)
                        .frame(width: 34, height: 34).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Edit a PDF")).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                        Text(L("Mark up, sign, replace words")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(PSTheme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .psCard(cornerRadius: 22, shadow: false)
            }
            .buttonStyle(PSPressStyle(scale: 0.98))
        }
        .padding(.horizontal, PSSpacing.page)
    }

    private var magicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MagicGlyph(size: 18)
                Text(L("Magic")).font(PSFont.title(22)).foregroundStyle(PSTheme.textPrimary).tracking(-0.4)
                Spacer()
            }
            .padding(.horizontal, PSSpacing.page)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    MagicMovieCard { showsMagicMovie = true }
                    ForEach(MagicShortcut.allCases) { shortcut in
                        MagicCard(shortcut: shortcut) {
                            pendingMagic = shortcut
                            pickerFilter = shortcut.isVideo ? .videos : .images
                            showsPicker = true
                        }
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private var library: some View {
        if let library = app?.library, !library.projects.isEmpty {
            let shown = library.projects.filter(filter.matches)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: L("Projects"), count: shown.count)
                    filterRow
                }
                .padding(.horizontal, PSSpacing.page)
                if shown.isEmpty {
                    filterEmptyState
                } else {
                    projectGrid(shown)
                }
            }
        } else {
            emptyState
        }
    }

    private var filterRow: some View {
        HStack(spacing: 0) {
            ForEach(LibraryFilter.allCases) { item in
                let isActive = filter == item
                Button {
                    Haptics.tick()
                    withAnimation(PSMotion.standard) { filter = item }
                } label: {
                    Text(item.title).font(PSFont.label(12))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(isActive ? PSTheme.textPrimary : PSTheme.textSecondary)
                        .background {
                            if isActive {
                                Capsule().fill(PSTheme.selection)
                                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.75))
                                    .matchedGeometryEffect(id: "filter", in: filterIndicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle())
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(3)
        .psGlass()
    }

    private func projectGrid(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: PSSpacing.medium), GridItem(.flexible(), spacing: PSSpacing.medium)], spacing: PSSpacing.medium) {
            ForEach(projects) { project in
                Button {
                    Haptics.tap()
                    openProject = OpenedProject(project: project, command: nil)
                } label: {
                    ProjectCard(project: project, library: app?.library)
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                // The editor grows out of the card the user tapped.
                .matchedTransitionSource(id: project.id, in: cardTransition)
                .contextMenu {
                    Button { renameText = project.title; renameTarget = project } label: { Label(L("Rename"), systemImage: "pencil") }
                    Button { Haptics.tap(); app?.library.duplicate(project) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
                    Divider()
                    Button(role: .destructive) { deleteTarget = project } label: { Label(L("Delete"), systemImage: "trash") }
                } preview: {
                    ProjectCard(project: project, library: app?.library)
                        .frame(width: 260)
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .animation(PSMotion.standard, value: projects.map(\.id))
    }

    private var filterEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .videos ? "film" : (filter == .pdfs ? "doc.text" : "photo.on.rectangle"))
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(PSTheme.textTertiary)
            Text(L("Nothing here yet.")).font(PSFont.headline(14)).foregroundStyle(PSTheme.textSecondary)
            Text(L("Start one from the tiles above.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .psCard(cornerRadius: 24, shadow: false)
        .padding(.horizontal, PSSpacing.page)
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            MagicGlyph(size: 34, symbol: "waveform.and.mic")
            Text(L("Pick a photo or a video, then just say what you want."))
                .font(PSFont.body(16))
                .multilineTextAlignment(.center)
                .foregroundStyle(PSTheme.textSecondary)
            Text(L("“Efface le chien” · “Make it warmer” · “Ajoute des sous-titres”"))
                .font(PSFont.caption())
                .multilineTextAlignment(.center)
                .foregroundStyle(PSTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 8)
    }
}

// MARK: - Magic shortcuts

/// One-tap results from Home: pick a photo or a video and the editor opens
/// already doing the thing, through the same command pipeline as the voice.
enum MagicShortcut: String, CaseIterable, Identifiable {
    case captions, jumpCuts, vertical, eraseObjects, cutout, enhance, portrait

    var id: String { rawValue }

    var isVideo: Bool {
        switch self {
        case .captions, .jumpCuts, .vertical: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .captions: return L("Auto captions")
        case .jumpCuts: return L("Jump cuts")
        case .vertical: return L("Vertical video")
        case .eraseObjects: return L("Erase people")
        case .cutout: return L("Cut out")
        case .enhance: return L("Enhance")
        case .portrait: return L("Portrait blur")
        }
    }

    var subtitle: String {
        switch self {
        case .captions: return L("Subtitles from the voice, word by word")
        case .jumpCuts: return L("Every pause, gone")
        case .vertical: return L("9:16 that follows the subject")
        case .eraseObjects: return L("Clear the background of passers-by")
        case .cutout: return L("The subject, on a clean background")
        case .enhance: return L("Light, colour and detail in one tap")
        case .portrait: return L("A soft background, like a big lens")
        }
    }

    var symbol: String {
        switch self {
        case .captions: return "captions.bubble.fill"
        case .jumpCuts: return "scissors"
        case .vertical: return "rectangle.portrait.and.arrow.forward"
        case .eraseObjects: return "person.2.slash"
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
        case .vertical: return fr ? "passe en vertical en suivant le sujet" : "smart reframe to vertical"
        case .eraseObjects: return fr ? "efface les personnes en arrière-plan" : "remove the people in the background"
        case .cutout: return fr ? "enlève le fond" : "remove the background"
        case .enhance: return fr ? "améliore la photo" : "auto enhance"
        case .portrait: return fr ? "floute l'arrière-plan" : "blur the background"
        }
    }
}

private struct MagicCard: View {
    let shortcut: MagicShortcut
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: shortcut.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .psIntelligenceForeground()
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                    Text(shortcut.subtitle).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Image(systemName: shortcut.isVideo ? "film" : "photo").font(.system(size: 9, weight: .bold))
                    Text(shortcut.isVideo ? L("Video") : L("Photo")).font(PSFont.label(10))
                }
                .foregroundStyle(PSTheme.textTertiary)
            }
            .padding(14)
            .frame(width: 164, height: 188, alignment: .topLeading)
            .psCard(cornerRadius: 26, shadow: false)
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(PSTheme.intelligenceAngular.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityLabel(shortcut.title)
        .accessibilityHint(shortcut.subtitle)
    }
}

/// The lead Magic card: a living spectrum behind "Magic Movie".
private struct MagicMovieCard: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.magic()
            action()
        } label: {
            ZStack(alignment: .bottomLeading) {
                IntelligenceField(animated: true)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "film.stack.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text(L("Magic Movie")).font(PSFont.title(20)).foregroundStyle(.white).tracking(-0.4)
                    Text(L("Clips + a song → an edit on the beat")).font(PSFont.caption(12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                .padding(16)
            }
            .frame(width: 220, height: 188)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityLabel(L("Magic Movie"))
    }
}

/// A large start tile: a deep gradient, a big glyph, a word.
private struct CreateTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.white.opacity(0.18), in: Circle())
                }
                Spacer(minLength: 18)
                Text(title).font(PSFont.title(24)).foregroundStyle(.white).tracking(-0.5)
                Text(subtitle).font(PSFont.caption(12)).foregroundStyle(.white.opacity(0.78)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 170)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
            .shadow(color: colors[0].opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

// MARK: - Backdrop and cards

/// The latest project, blurred into light behind the screen — the library
/// takes the colour of your own work, like Music does with album art.
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
                    .blur(radius: 70, opaque: true)
                    .saturation(1.35)
                    .opacity(0.55)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .transition(.opacity)
            } else {
                IntelligenceField()
                    .frame(height: 420)
                    .blur(radius: 60)
                    .opacity(0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            LinearGradient(stops: [
                .init(color: PSTheme.ink.opacity(0.1), location: 0),
                .init(color: PSTheme.ink.opacity(0.7), location: 0.35),
                .init(color: PSTheme.ink, location: 0.62),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.8), value: image == nil)
        .drawingGroup(opaque: true)
    }
}

/// Deep ground used behind sheets and settings.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            PSTheme.ink
            IntelligenceField()
                .frame(height: 360)
                .blur(radius: 70)
                .opacity(0.22)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.clear, PSTheme.ink], startPoint: .top, endPoint: .center)
        }
        .drawingGroup(opaque: true)
    }
}

/// Static mesh gradient used behind hero surfaces (GPU-cheap, no blur).
struct HeroMesh: View {
    var body: some View { IntelligenceField() }
}

struct ProjectCard: View {
    let project: Project
    /// The card reads its own thumbnail: read in the grid's body instead, one
    /// image arriving would repaint every card.
    let library: ProjectLibrary?
    @Environment(\.psEffects) private var effects

    private var thumbnail: UIImage? { library?.thumbnail(for: project) }

    /// Duration, page count or pixel size, depending on the project type.
    private var meta: String {
        switch project.content {
        case .photo(let document): return "\(Int(document.canvasSize.width)) × \(Int(document.canvasSize.height))"
        case .video(let timeline):
            let total = Int(max(0, timeline.duration).rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        case .pdf(let document): return String(format: L("%d pages"), document.pageCount)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        Color.clear
            .aspectRatio(4 / 5, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    ZStack {
                        PSTheme.surfaceElevated
                        Image(systemName: project.isPDF ? "doc.text" : (project.isVideo ? "film" : "photo")).font(.system(size: 28, weight: .light)).foregroundStyle(PSTheme.textTertiary)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.2), location: 0.45), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title).font(PSFont.headline(13)).lineLimit(1).foregroundStyle(.white)
                    Text(project.modifiedAt, format: .relative(presentation: .named))
                        .font(PSFont.caption(11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.bottom, 11)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: project.isPDF ? "doc.text.fill" : (project.isVideo ? "play.fill" : "photo.fill"))
                        .font(.system(size: 9, weight: .bold))
                    Text(meta).font(PSFont.mono(10))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(8)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
            .shadow(color: .black.opacity(effects == .rich ? 0.45 : 0), radius: 16, y: 8)
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.title)
    }
}

/// Quiet progress row shown while the large models download themselves.
struct ModelInstallBanner: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            MagicGlyph(size: 18, symbol: "arrow.down.circle.fill")
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Installing AI models")).font(PSFont.headline(13)).foregroundStyle(PSTheme.textPrimary)
                ProgressView(value: progress).tint(PSTheme.voice)
            }
            Text("\(Int((progress * 100).rounded()))%").font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).contentTransition(.numericText())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .psCard(cornerRadius: 20, shadow: false)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when the phone is hot: explains why previews look softer for a moment.
struct ThermalBanner: View {
    let governor: PerformanceGovernor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: governor.statusSymbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(governor.statusTint).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(governor.statusTitle).font(PSFont.headline(13)).foregroundStyle(PSTheme.textPrimary)
                Text(L("PicShop is rendering lighter previews to keep your iPhone cool.")).font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .psCard(cornerRadius: 20, shadow: false)
        .accessibilityElement(children: .combine)
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
