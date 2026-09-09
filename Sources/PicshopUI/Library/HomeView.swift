#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore

/// Project library: the first screen. A large title, one hero action, two
/// secondary ones, then the recents grid — the same rhythm as Apple's own
/// media apps, on a quiet lit ground.
public struct HomeView: View {
    @Environment(\.picshop) private var app
    @State private var pickedItem: PhotosPickerItem?
    @State private var openProject: Project?
    @State private var showsSettings = false
    @State private var pickerFilter: PHPickerFilter = .images
    @State private var showsPicker = false
    @State private var showsPDFPicker = false
    @State private var filter: LibraryFilter = .all
    @State private var renameTarget: Project?
    @State private var renameText = ""
    @State private var deleteTarget: Project?
    @Namespace private var filterIndicator

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
            ZStack {
                AmbientBackground().ignoresSafeArea()
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showsSettings = true } label: { Image(systemName: "gearshape.fill").symbolRenderingMode(.hierarchical) }
                        .accessibilityLabel(L("Settings"))
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .fullScreenCover(item: $openProject) { project in
                if let app { EditorHost(project: project, app: app) }
            }
            .photosPicker(isPresented: $showsPicker, selection: $pickedItem, matching: pickerFilter, photoLibrary: .shared())
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result, let app else { return }
                if let project = app.library.createPDFProject(from: url) {
                    Haptics.success()
                    openProject = project
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item, let app else { return }
                Task {
                    if let project = await app.library.importProject(from: item) {
                        Haptics.success()
                        openProject = project
                    } else {
                        Haptics.error()
                    }
                    pickedItem = nil
                }
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

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PSSpacing.xLarge) {
                header
                heroActions
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
                if let library = app?.library, !library.projects.isEmpty {
                    let shown = library.projects.filter(filter.matches)
                    VStack(alignment: .leading, spacing: PSSpacing.medium) {
                        SectionTitle(title: L("Recent"), count: shown.count)
                        filterRow
                    }
                    .padding(.horizontal, PSSpacing.page)
                    if shown.isEmpty {
                        filterEmptyState
                    } else {
                        projectGrid(shown)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.vertical, PSSpacing.medium)
            .animation(PSMotion.standard, value: app?.modelInstallProgress == nil)
            .animation(PSMotion.standard, value: app?.performance.tier)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if app?.library.isImporting == true {
                ProgressHUD(title: L("Importing…"))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                Text("·")
                // Build stamp, so any screenshot says which code produced it.
                Text(BuildInfo.commit).font(PSFont.mono(11))
            }
            .font(PSFont.caption(12)).textCase(.uppercase).tracking(0.8)
            .foregroundStyle(PSTheme.textTertiary)
            Text("PicShop").font(PSFont.display(40)).foregroundStyle(PSTheme.textPrimary).tracking(-1.4)
            Text(L("Photos, videos and PDFs. Just say it."))
                .font(PSFont.body(15)).foregroundStyle(PSTheme.textSecondary)
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.top, 4)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(LibraryFilter.allCases) { item in
                    let isActive = filter == item
                    Button {
                        Haptics.tick()
                        withAnimation(PSMotion.standard) { filter = item }
                    } label: {
                        Text(item.title).font(PSFont.caption(12)).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                            .background {
                                if isActive {
                                    Capsule().fill(PSTheme.accentGradient).overlay(Capsule().fill(PSTheme.accentHighlight))
                                        .matchedGeometryEffect(id: "filter", in: filterIndicator)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.06))
                                }
                            }
                    }
                    .buttonStyle(PSPressStyle())
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
        }
    }

    /// The cards are deliberately not wrapped in a `GlassEffectContainer`: the
    /// container merges nested glass into one layer and samples the cards'
    /// own content into the blur.
    private var heroActions: some View {
        VStack(spacing: PSSpacing.medium) {
            heroCard(title: L("New Photo"), subtitle: L("Retouch, erase, restyle"), systemImage: "photo.on.rectangle.angled", tint: PSTheme.accent, prominent: true) {
                pickerFilter = .images
                showsPicker = true
            }
            HStack(spacing: PSSpacing.medium) {
                heroCard(title: L("New Video"), subtitle: L("Cut, clean up, grade"), systemImage: "film.stack", tint: PSTheme.voice) {
                    pickerFilter = .videos
                    showsPicker = true
                }
                heroCard(title: L("New PDF"), subtitle: L("Sign, mark up, reorder"), systemImage: "doc.richtext", tint: PSTheme.warning) {
                    showsPDFPicker = true
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
    }

    private func heroCard(title: String, subtitle: String, systemImage: String, tint: Color, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            Group {
                if prominent {
                    HStack(spacing: 14) {
                        heroIcon(systemImage, tint: tint, prominent: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(PSFont.headline(19)).foregroundStyle(PSTheme.textPrimary)
                            Text(subtitle).font(PSFont.caption(13)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.white.opacity(0.8))
                    }
                } else {
                    // Secondary cards stack vertically so the subtitle never wraps into the icon.
                    VStack(alignment: .leading, spacing: 12) {
                        heroIcon(systemImage, tint: tint, prominent: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(PSFont.headline(16)).foregroundStyle(PSTheme.textPrimary)
                            Text(subtitle).font(PSFont.caption(11.5)).foregroundStyle(PSTheme.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, prominent ? 18 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(PSPressStyle(scale: 0.985))
        .modifier(HeroSurface(prominent: prominent, tint: tint))
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private func heroIcon(_ systemImage: String, tint: Color, prominent: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: prominent ? 26 : 20, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(prominent ? Color.white : tint)
            .frame(width: prominent ? 56 : 44, height: prominent ? 56 : 44)
            .background(prominent ? Color.white.opacity(0.22) : tint.opacity(0.18), in: RoundedRectangle(cornerRadius: prominent ? 18 : 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 18 : 14, style: .continuous).strokeBorder(prominent ? Color.white.opacity(0.25) : tint.opacity(0.35), lineWidth: 1))
    }

    private func projectGrid(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: PSSpacing.medium), GridItem(.flexible(), spacing: PSSpacing.medium)], spacing: PSSpacing.large) {
            ForEach(projects) { project in
                Button {
                    Haptics.tap()
                    openProject = project
                } label: {
                    ProjectCard(project: project, library: app?.library)
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
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

    /// Shown when a filter has nothing to show: a quiet tile, not a bare line of text.
    private var filterEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .videos ? "film" : (filter == .pdfs ? "doc.text" : "photo.on.rectangle"))
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(PSTheme.textTertiary)
            Text(L("Nothing here yet.")).font(PSFont.headline(14)).foregroundStyle(PSTheme.textSecondary)
            Text(L("Import one from the cards above.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .psCard(cornerRadius: 22, shadow: false)
        .padding(.horizontal, PSSpacing.page)
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(PSTheme.voiceGradient)
                .symbolRenderingMode(.hierarchical)
            Text(L("Pick a photo or video, then just say what you want."))
                .font(PSFont.body(16))
                .multilineTextAlignment(.center)
                .foregroundStyle(PSTheme.textSecondary)
            Text(L("“Efface le chien” · “Make it warmer” · “Coupe les 3 premières secondes”"))
                .font(PSFont.caption())
                .multilineTextAlignment(.center)
                .foregroundStyle(PSTheme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}

/// The prominent card paints a mesh gradient; the others a tinted, layered
/// surface. They are deliberately not glass: on device the glass sampled the
/// cards' own icon and text into its blur.
struct HeroSurface: ViewModifier {
    let prominent: Bool
    var tint: Color = PSTheme.accent
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        if prominent {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            content
                .background {
                    ZStack {
                        HeroMesh()
                        shape.fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                    }
                }
                .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .clipShape(shape)
                .shadow(color: PSTheme.accent.opacity(effects == .rich ? 0.35 : 0), radius: 22, y: 10)
        } else {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            content
                .background {
                    ZStack {
                        shape.fill(PSTheme.surfaceElevated)
                        shape.fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        shape.fill(PSTheme.sheen)
                    }
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [tint.opacity(0.55), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .clipShape(shape)
                .shadow(color: .black.opacity(effects == .rich ? 0.35 : 0), radius: 18, y: 10)
        }
    }
}

/// Static mesh gradient used behind hero surfaces (GPU-cheap, no blur).
struct HeroMesh: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            MeshGradient(width: 3, height: 3, points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.42, 0.55], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ], colors: PSTheme.heroMesh)
        } else {
            LinearGradient(colors: [PSTheme.heroMesh[0], PSTheme.heroMesh[4], PSTheme.heroMesh[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct ProjectCard: View {
    let project: Project
    /// The card reads its own thumbnail: read in the grid's body instead, one
    /// image arriving would repaint every card.
    let library: ProjectLibrary?
    @Environment(\.psEffects) private var effects

    private var thumbnail: UIImage? { library?.thumbnail(for: project) }

    private var tint: Color { project.isPDF ? PSTheme.warning : (project.isVideo ? PSTheme.voice : PSTheme.accent) }

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
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                // Scrim so the title reads on any picture: long and soft, like the Photos memories tiles.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.18), location: 0.45), .init(color: .black.opacity(0.78), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title).font(PSFont.headline(13)).lineLimit(1).foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text(project.modifiedAt, format: .relative(presentation: .named))
                        Text("·")
                        Text(meta)
                    }
                    .font(PSFont.caption(10.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: project.isPDF ? "doc.text.fill" : (project.isVideo ? "play.fill" : "photo.fill"))
                        .font(.system(size: 9, weight: .bold))
                    if project.isVideo { Text(meta).font(PSFont.mono(10)) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, project.isVideo ? 8 : 0)
                .frame(minWidth: 24, minHeight: 24)
                .background(Capsule().fill(tint.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .padding(8)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
            .shadow(color: .black.opacity(effects == .rich ? 0.5 : 0), radius: 18, y: 10)
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.title)
    }
}

/// Deep, softly lit ground behind the library — the app should feel like a lit studio, not a void.
/// Three static radial washes: no blur, no animation, one GPU pass.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            PSTheme.ink
            RadialGradient(colors: [Color(red: 0.24, green: 0.44, blue: 0.98).opacity(0.28), .clear], center: .init(x: 0.15, y: 0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.62, green: 0.40, blue: 1.0).opacity(0.18), .clear], center: .init(x: 0.95, y: 0.25), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.35).opacity(0.10), .clear], center: .init(x: 0.5, y: 1.0), startRadius: 0, endRadius: 500)
        }
    }
}

/// Quiet progress row shown while the large models download themselves.
struct ModelInstallBanner: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(PSTheme.accent).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Installing AI models")).font(PSFont.headline(13)).foregroundStyle(PSTheme.textPrimary)
                ProgressView(value: progress).tint(PSTheme.accent)
            }
            Text("\(Int((progress * 100).rounded()))%").font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary).contentTransition(.numericText())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .psCard(cornerRadius: 18, shadow: false)
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
        .psCard(cornerRadius: 18, shadow: false)
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

    init(project: Project, app: AppEnvironment) {
        let session: Session
        switch project.content {
        case .photo(let document): session = .photo(PhotoEditorSession(document: document, projectID: project.id, app: app))
        case .video(let timeline): session = .video(VideoEditorSession(timeline: timeline, projectID: project.id, app: app))
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
