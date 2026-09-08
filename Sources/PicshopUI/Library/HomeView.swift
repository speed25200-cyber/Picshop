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

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground().ignoresSafeArea()
                content
            }
            .navigationTitle("PicShop")
            .toolbarColorScheme(.dark, for: .navigationBar)
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
                heroActions
                if let app, let progress = app.modelInstallProgress {
                    ModelInstallBanner(progress: progress)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let library = app?.library, !library.projects.isEmpty {
                    Text(L("Recent"))
                        .font(PSFont.headline(20))
                        .foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 20)
                    projectGrid(library.projects)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            PSTheme.surfaceElevated
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                Image(systemName: project.isPDF ? "doc.text.fill" : (project.isVideo ? "play.fill" : "photo.fill"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(project.isPDF ? PSTheme.warning : (project.isVideo ? PSTheme.voice : PSTheme.accent))
                    .padding(7)
                    .psGlass(shape: AnyShape(Circle()))
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(PSFont.headline(13)).lineLimit(1).foregroundStyle(PSTheme.textPrimary)
                Text(project.modifiedAt, format: .relative(presentation: .named)).font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
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
            content.psGlass(interactive: true, shape: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
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
        .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
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
