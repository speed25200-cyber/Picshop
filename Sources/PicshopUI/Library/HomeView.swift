#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore

/// Project library: the first screen.
public struct HomeView: View {
    @Environment(\.picshop) private var app
    @State private var pickedItem: PhotosPickerItem?
    @State private var openProject: Project?
    @State private var showsSettings = false
    @State private var pickerFilter: PHPickerFilter = .images
    @State private var showsPicker = false
    @State private var showsPDFPicker = false
    @State private var filter: LibraryFilter = .all

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
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
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
        }
        .preferredColorScheme(.dark)
        .tint(PSTheme.accent)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PicShop").font(PSFont.display(38)).foregroundStyle(PSTheme.textPrimary).tracking(-1.2)
                    Text(L("Photos, videos and PDFs. Just say it."))
                        .font(PSFont.body(15)).foregroundStyle(PSTheme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                heroActions
                if let app, let progress = app.modelInstallProgress {
                    ModelInstallBanner(progress: progress)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let library = app?.library, !library.projects.isEmpty {
                    let shown = library.projects.filter(filter.matches)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L("Recent")).font(PSFont.title(22)).foregroundStyle(PSTheme.textPrimary).tracking(-0.4)
                            Text("\(shown.count)").font(PSFont.mono(12)).foregroundStyle(PSTheme.textTertiary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(LibraryFilter.allCases) { item in
                                    Button {
                                        Haptics.tick()
                                        withAnimation(.snappy) { filter = item }
                                    } label: {
                                        Text(item.title).font(PSFont.caption(12)).padding(.horizontal, 12).padding(.vertical, 7)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(filter == item ? Color.white : PSTheme.textSecondary)
                                    .background(Color.white.opacity(filter == item ? 0 : 0.06), in: Capsule())
                                    .psActivePill(Capsule(), isActive: filter == item, glow: false)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    if shown.isEmpty {
                        Text(L("Nothing here yet.")).font(PSFont.body(14)).foregroundStyle(PSTheme.textTertiary).padding(.horizontal, 20)
                    } else {
                        projectGrid(shown)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.vertical, 12)
        }
        .overlay {
            if app?.library.isImporting == true {
                ProgressHUD(title: L("Importing…"))
            }
        }
    }

    private var heroActions: some View {
        PSGlassContainer(spacing: 14) {
            VStack(spacing: 12) {
                heroCard(title: L("New Photo"), subtitle: L("Retouch, erase, restyle"), systemImage: "photo.on.rectangle.angled", tint: PSTheme.accent, prominent: true) {
                    pickerFilter = .images
                    showsPicker = true
                }
                HStack(spacing: 12) {
                    heroCard(title: L("New Video"), subtitle: L("Cut, clean up, grade"), systemImage: "film.stack", tint: PSTheme.voice) {
                        pickerFilter = .videos
                        showsPicker = true
                    }
                    heroCard(title: L("New PDF"), subtitle: L("Sign, mark up, reorder"), systemImage: "doc.richtext", tint: PSTheme.warning) {
                        showsPDFPicker = true
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func heroCard(title: String, subtitle: String, systemImage: String, tint: Color, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: prominent ? 26 : 20, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : tint)
                    .frame(width: prominent ? 56 : 44, height: prominent ? 56 : 44)
                    .background(prominent ? Color.white.opacity(0.22) : tint.opacity(0.18), in: RoundedRectangle(cornerRadius: prominent ? 18 : 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(PSFont.headline(prominent ? 19 : 15)).foregroundStyle(PSTheme.textPrimary)
                    Text(subtitle).font(PSFont.caption(prominent ? 13 : 11)).foregroundStyle(prominent ? Color.white.opacity(0.8) : PSTheme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if prominent {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, prominent ? 18 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if prominent {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.42, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(Color.white.opacity(0.14)).frame(width: 160, height: 160).blur(radius: 24).offset(x: 40, y: -60)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color(red: 0.36, green: 0.55, blue: 1.0).opacity(0.35), radius: 22, y: 10)
            }
        }
        .modifier(GlassWhenNotProminent(prominent: prominent))
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private func projectGrid(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
            ForEach(projects) { project in
                ProjectCard(project: project, thumbnail: app?.library.thumbnail(for: project))
                    .onTapGesture {
                        Haptics.tap()
                        openProject = project
                    }
                    .contextMenu {
                        Button { app?.library.duplicate(project) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { app?.library.delete(project) } label: { Label(L("Delete"), systemImage: "trash") }
                    }
            }
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(PSTheme.voiceGradient)
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

struct ProjectCard: View {
    let project: Project
    let thumbnail: UIImage?

    private var tint: Color { project.isPDF ? PSTheme.warning : (project.isVideo ? PSTheme.voice : PSTheme.accent) }

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
                // Scrim so the title reads on any picture.
                LinearGradient(colors: [.clear, .black.opacity(0.05), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(PSFont.headline(13)).lineLimit(1).foregroundStyle(.white)
                    Text(project.modifiedAt, format: .relative(presentation: .named)).font(PSFont.caption(10.5)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: project.isPDF ? "doc.text.fill" : (project.isVideo ? "play.fill" : "photo.fill"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.9)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .padding(8)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.title)
    }
}

/// Deep, softly lit ground behind the library — the app should feel like a lit studio, not a void.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.05)
            RadialGradient(colors: [Color(red: 0.30, green: 0.42, blue: 0.95).opacity(0.28), .clear], center: .init(x: 0.15, y: 0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.62, green: 0.40, blue: 1.0).opacity(0.18), .clear], center: .init(x: 0.95, y: 0.25), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.35).opacity(0.10), .clear], center: .init(x: 0.5, y: 1.0), startRadius: 0, endRadius: 500)
        }
    }
}

/// Glass for the secondary hero cards; the prominent one paints its own gradient.
struct GlassWhenNotProminent: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content
        } else {
            content.psCard(cornerRadius: 24)
        }
    }
}

/// Quiet progress row shown while the large models download themselves.
struct ModelInstallBanner: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(PSTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Installing AI models")).font(PSFont.headline(13)).foregroundStyle(PSTheme.textPrimary)
                ProgressView(value: progress).tint(PSTheme.accent)
            }
            Text("\(Int((progress * 100).rounded()))%").font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary)
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
