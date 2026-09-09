#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import Observation
import UniformTypeIdentifiers
import PicshopCore
import PicshopImaging
import PicshopVideo
import PicshopPDF

/// Creates, lists and deletes projects; imports media from the photo library.
@MainActor
@Observable
public final class ProjectLibrary {
    public let store: ProjectStore
    public private(set) var projects: [Project] = []
    public private(set) var isImporting = false
    public var errorMessage: String?

    public init(store: ProjectStore) {
        self.store = store
        refresh()
    }

    public func refresh() {
        projects = store.listProjects()
    }

    public func thumbnail(for project: Project) -> UIImage? {
        if let image = UIImage(contentsOfFile: store.thumbnailURL(for: project.id).path) { return image }
        regenerateThumbnail(for: project)
        return nil
    }

    private var regenerating: Set<UUID> = []

    /// Projects saved by older builds have no current thumbnail: rebuild one from the
    /// original media in the background, then refresh the grid.
    private func regenerateThumbnail(for project: Project) {
        guard !regenerating.contains(project.id) else { return }
        regenerating.insert(project.id)
        let store = self.store
        let id = project.id
        Task.detached(priority: .utility) {
            switch project.content {
            case .photo(let document):
                if let asset = document.baseLayer?.imageAsset, let cg = try? ImageSupport.loadCGImage(at: store.url(for: asset.relativePath, in: id), maxPixelSize: 512) {
                    ThumbnailGenerator.writeThumbnail(image: cg, projectID: id, store: store)
                }
            case .video(let timeline):
                if let poster = await VideoThumbnailer(store: store, projectID: id).poster(for: timeline) {
                    ThumbnailGenerator.writeThumbnail(image: poster, projectID: id, store: store)
                }
            case .pdf(let model):
                let services = PDFEditingService(store: store, projectID: id)
                if let cg = services.thumbnail(for: 0, in: model, height: 400)?.cgImage {
                    ThumbnailGenerator.writeThumbnail(image: cg, projectID: id, store: store)
                }
            }
            await MainActor.run { [weak self] in
                self?.regenerating.remove(id)
                self?.refresh()
            }
        }
    }

    public func delete(_ project: Project) {
        try? store.delete(id: project.id)
        refresh()
    }

    /// Renames a project in place; the title lives on the content model.
    public func rename(_ project: Project, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.title else { return }
        var copy = project
        switch copy.content {
        case .photo(var document): document.title = trimmed; copy.content = .photo(document)
        case .video(var timeline): timeline.title = trimmed; copy.content = .video(timeline)
        case .pdf(var document): document.title = trimmed; copy.content = .pdf(document)
        }
        do {
            try store.save(copy)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func duplicate(_ project: Project) {
        var copy = project
        let newID = UUID()
        copy.id = newID
        switch copy.content {
        case .photo(var document):
            document.id = newID
            document.title += " copy"
            copy.content = .photo(document)
        case .video(var timeline):
            timeline.id = newID
            timeline.title += " copy"
            copy.content = .video(timeline)
        case .pdf(var document):
            document.id = newID
            document.title += " copy"
            copy.content = .pdf(document)
        }
        do {
            try FileManager.default.copyItem(at: store.packageURL(for: project.id), to: store.packageURL(for: newID))
            try store.save(copy)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Imports the selected item and creates a project. Returns the new project.
    public func importProject(from item: PhotosPickerItem) async -> Project? {
        isImporting = true
        defer { isImporting = false }
        do {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            if isVideo {
                guard let file = try await item.loadTransferable(type: ImportedMovie.self) else { throw PicshopError.mediaUnavailable("video") }
                return try await createVideoProject(from: file.url, title: defaultTitle(video: true))
            }
            guard let data = try await item.loadTransferable(type: Data.self) else { throw PicshopError.mediaUnavailable("photo") }
            return try createPhotoProject(from: data, title: defaultTitle(video: false))
        } catch {
            errorMessage = (error as? PicshopError)?.message ?? error.localizedDescription
            return nil
        }
    }

    public func createPhotoProject(from data: Data, title: String) throws -> Project {
        let id = UUID()
        try store.createPackage(for: id)
        let type = UTType(filenameExtension: "heic")
        let extensionName = data.starts(with: [0xFF, 0xD8]) ? "jpg" : (data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "heic")
        _ = type
        let relative = "\(Project.mediaDirectory)/original.\(extensionName)"
        let url = store.url(for: relative, in: id)
        try data.write(to: url, options: .atomic)
        guard let size = ImageSupport.pixelSize(at: url) else { throw PicshopError.mediaUnavailable("photo") }
        let asset = MediaAsset(kind: .image, relativePath: relative, pixelSize: size, origin: .photoLibrary(localIdentifier: ""))
        var document = PhotoDocument(title: title, baseImage: asset)
        document.id = id
        let project = Project(id: id, content: .photo(document))
        try store.save(project)
        if let cg = try? ImageSupport.loadCGImage(at: url, maxPixelSize: 512) {
            ThumbnailGenerator.writeThumbnail(image: cg, projectID: id, store: store)
        }
        refresh()
        return project
    }

    public func createVideoProject(from sourceURL: URL, title: String) async throws -> Project {
        let id = UUID()
        try store.createPackage(for: id)
        let relative = "\(Project.mediaDirectory)/original.\(sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)"
        let destination = store.url(for: relative, in: id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let metadata = try await VideoThumbnailer.metadata(for: destination)
        let asset = MediaAsset(kind: .video, relativePath: relative, pixelSize: metadata.size, duration: metadata.duration, origin: .photoLibrary(localIdentifier: ""), frameRate: metadata.frameRate)
        var timeline = VideoTimeline(title: title, asset: asset)
        timeline.id = id
        let project = Project(id: id, content: .video(timeline))
        try store.save(project)
        if let poster = await VideoThumbnailer(store: store, projectID: id).poster(for: timeline) {
            ThumbnailGenerator.writeThumbnail(image: poster, projectID: id, store: store)
        }
        refresh()
        return project
    }

    public func createPDFProject(from url: URL) -> Project? {
        isImporting = true
        defer { isImporting = false }
        do {
            let model = try PDFEditingService.importDocument(from: url, store: store, title: url.deletingPathExtension().lastPathComponent)
            let project = Project(id: model.id, content: .pdf(model))
            try store.save(project)
            refresh()
            return project
        } catch {
            errorMessage = (error as? PicshopError)?.message ?? error.localizedDescription
            return nil
        }
    }

    public func save(_ project: Project) {
        do {
            try store.save(project)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultTitle(video: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(video ? L("Video") : L("Photo")) · \(formatter.string(from: Date()))"
    }
}

/// Transferable wrapper that keeps picked movies as files instead of loading them in memory.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
#endif
