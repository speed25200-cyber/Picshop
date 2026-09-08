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
                PSTheme.canvas.ignoresSafeArea()
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
                EditorHost(project: project)
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
        PSGlassContainer(spacing: 16) {
            HStack(spacing: 14) {
                heroButton(title: L("New Photo"), subtitle: L("Retouch, erase, restyle"), systemImage: "photo.on.rectangle.angled", tint: PSTheme.accent) {
                    pickerFilter = .images
                    showsPicker = true
                }
                heroButton(title: L("New Video"), subtitle: L("Cut, clean up, grade"), systemImage: "film.stack", tint: PSTheme.voice) {
                    pickerFilter = .videos
                    showsPicker = true
                }
                heroButton(title: L("New PDF"), subtitle: L("Sign, mark up, reorder"), systemImage: "doc.richtext", tint: PSTheme.warning) {
                    showsPDFPicker = true
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func heroButton(title: String, subtitle: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(title).font(PSFont.headline(18)).foregroundStyle(PSTheme.textPrimary)
                Text(subtitle).font(PSFont.caption()).foregroundStyle(PSTheme.textSecondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: PSTheme.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .psGlassPanel()
    }

    private func projectGrid(_ projects: [Project]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
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
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        PSTheme.surfaceElevated
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if project.isVideo || project.isPDF {
                    Image(systemName: project.isPDF ? "doc.text.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .padding(7)
                        .psGlass(shape: AnyShape(Circle()))
                        .padding(8)
                }
            }
            Text(project.title)
                .font(PSFont.caption(13))
                .lineLimit(1)
                .foregroundStyle(PSTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.title)
    }
}

/// Routes a project to the right editor. Sessions are created once per presentation.
struct EditorHost: View {
    let project: Project
    @Environment(\.picshop) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var photoSession: PhotoEditorSession?
    @State private var videoSession: VideoEditorSession?
    @State private var pdfSession: PDFEditorSession?

    var body: some View {
        Group {
            if let photoSession {
                PhotoEditorView(session: photoSession)
            } else if let videoSession {
                VideoEditorView(session: videoSession)
            } else if let pdfSession {
                PDFEditorView(session: pdfSession)
            } else {
                PSTheme.canvas.ignoresSafeArea()
            }
        }
        .onAppear {
            guard let app, photoSession == nil, videoSession == nil, pdfSession == nil else { return }
            switch project.content {
            case .photo(let document): photoSession = PhotoEditorSession(document: document, projectID: project.id, app: app)
            case .video(let timeline): videoSession = VideoEditorSession(timeline: timeline, projectID: project.id, app: app)
            case .pdf(let document): pdfSession = PDFEditorSession(document: document, projectID: project.id, app: app)
            }
            if app == nil { dismiss() }
        }
    }
}
#endif
