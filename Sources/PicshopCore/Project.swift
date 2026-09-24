import Foundation

/// A saved project (photo or video) inside the app's documents directory.
///
/// On disk a project is a package directory:
/// ```
/// <uuid>.picshop/
///   project.json      ← this struct
///   media/…           ← imported originals + AI-rendered derivatives
///   masks/…           ← rasterised masks
///   thumbnail.jpg
/// ```
public struct Project: Hashable, Codable, Sendable, Identifiable {
    public enum Content: Hashable, Codable, Sendable {
        case photo(PhotoDocument)
        case video(VideoTimeline)
        case pdf(PDFDocumentModel)
    }

    public var id: UUID
    public var content: Content
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), content: Content, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var title: String {
        switch content {
        case .photo(let document): return document.title
        case .video(let timeline): return timeline.title
        case .pdf(let document): return document.title
        }
    }

    public var isPDF: Bool {
        if case .pdf = content { return true }
        return false
    }

    public var pdfDocument: PDFDocumentModel? {
        if case .pdf(let document) = content { return document }
        return nil
    }

    public var isVideo: Bool {
        if case .video = content { return true }
        return false
    }

    public var photoDocument: PhotoDocument? {
        if case .photo(let document) = content { return document }
        return nil
    }

    public var videoTimeline: VideoTimeline? {
        if case .video(let timeline) = content { return timeline }
        return nil
    }

    public static let packageExtension = "picshop"
    public static let manifestName = "project.json"
    public static let mediaDirectory = "media"
    public static let masksDirectory = "masks"
    public static let thumbnailName = "thumbnail-2.jpg"
    /// What Home shows for a project, written next to the manifest (see `ProjectSummary`).
    public static let summaryName = "summary.json"
}

/// What Home needs to show a project card, kept small so the library can list
/// hundreds of projects without decoding a single manifest.
public struct ProjectSummary: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case photo, video, pdf }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Video: timeline duration in seconds; nil otherwise.
    public var duration: Double?
    /// PDF: number of pages; nil otherwise.
    public var pageCount: Int?
    /// Width / height of what the card shows: the photo canvas, the video render
    /// size or the first PDF page. 1 when unknown.
    public var aspectRatio: Double

    public init(project: Project) {
        id = project.id
        title = project.title
        createdAt = project.createdAt
        modifiedAt = project.modifiedAt
        switch project.content {
        case .photo(let document):
            kind = .photo
            duration = nil
            pageCount = nil
            aspectRatio = Self.usable(document.aspectRatio)
        case .video(let timeline):
            kind = .video
            duration = timeline.duration
            pageCount = nil
            aspectRatio = Self.usable(timeline.renderSize.aspectRatio)
        case .pdf(let document):
            kind = .pdf
            duration = nil
            pageCount = document.pageCount
            aspectRatio = Self.usable(document.pages.first?.displaySize.aspectRatio ?? 0)
        }
    }

    private static func usable(_ ratio: Double) -> Double {
        ratio.isFinite && ratio > 0 ? ratio : 1
    }
}

/// Errors surfaced to the UI. Every case carries a user-presentable message.
public enum PicshopError: Error, Sendable, Equatable {
    case projectNotFound(UUID)
    case corruptProject(String)
    case mediaUnavailable(String)
    case objectNotFound(String)
    case ambiguousTarget(count: Int)
    case unsupportedOperation(String)
    case modelUnavailable(String)
    case renderFailed(String)
    case exportFailed(String)
    case permissionDenied(String)
    case speechUnavailable(String)
    case cancelled

    /// In the language the device speaks.
    public var message: String { message(french: Self.devicePrefersFrench) }

    public func message(french: Bool) -> String {
        switch self {
        case .projectNotFound: return french ? "Ce projet est introuvable." : "This project could not be found."
        case .corruptProject(let detail): return french ? "Le fichier du projet est abîmé (\(detail))." : "The project file is damaged (\(detail))."
        case .mediaUnavailable(let name): return french ? "Le média « \(name) » est introuvable." : "The media “\(name)” is missing."
        case .objectNotFound(let target): return french ? "Je ne trouve pas « \(target) » sur la photo." : "I couldn't find “\(target)” in the picture."
        case .ambiguousTarget(let count): return french ? "J'en vois \(count) — lequel ?" : "I found \(count) matches — which one?"
        case .unsupportedOperation(let name): return french ? "« \(name) » n'est pas possible ici." : "“\(name)” isn't available here."
        case .modelUnavailable(let name): return french ? "Le modèle \(name) n'est pas encore installé." : "The \(name) model isn't installed yet."
        case .renderFailed(let detail): return french ? "Le rendu a échoué : \(detail)" : "Rendering failed: \(detail)"
        case .exportFailed(let detail): return french ? "L'export a échoué : \(detail)" : "Export failed: \(detail)"
        case .permissionDenied(let what): return french ? "L'accès à \(what) est refusé. Vous pouvez l'autoriser dans Réglages." : "Permission for \(what) was denied. You can enable it in Settings."
        case .speechUnavailable(let detail): return french ? "La commande vocale est indisponible : \(detail)" : "Voice control is unavailable: \(detail)"
        case .cancelled: return french ? "Annulé." : "Cancelled."
        }
    }

    /// Whether the person reads French first, as the interface does.
    public static var devicePrefersFrench: Bool {
        (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("fr")
    }
}

extension PicshopError: LocalizedError {
    public var errorDescription: String? { message }
}

/// File-based persistence for projects. Pure Foundation so it is testable on Linux.
public struct ProjectStore: Sendable {
    public let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) {
        self.rootURL = rootURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func packageURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).\(Project.packageExtension)", isDirectory: true)
    }

    public func mediaURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.mediaDirectory, isDirectory: true)
    }

    public func masksURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.masksDirectory, isDirectory: true)
    }

    public func thumbnailURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.thumbnailName)
    }

    /// Resolves a relative media/mask path inside the package.
    public func url(for relativePath: String, in projectID: UUID) -> URL {
        packageURL(for: projectID).appendingPathComponent(relativePath)
    }

    public func createPackage(for id: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaURL(for: id), withIntermediateDirectories: true)
        try fm.createDirectory(at: masksURL(for: id), withIntermediateDirectories: true)
    }

    public func save(_ project: Project) throws {
        try createPackage(for: project.id)
        var copy = project
        copy.modifiedAt = Date()
        let data = try encoder.encode(copy)
        let manifest = packageURL(for: project.id).appendingPathComponent(Project.manifestName)
        try data.write(to: manifest, options: .atomic)
    }

    public func load(id: UUID) throws -> Project {
        let manifest = packageURL(for: id).appendingPathComponent(Project.manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw PicshopError.projectNotFound(id) }
        do {
            let data = try Data(contentsOf: manifest)
            return try decoder.decode(Project.self, from: data)
        } catch let error as PicshopError {
            throw error
        } catch {
            throw PicshopError.corruptProject(String(describing: error))
        }
    }

    public func delete(id: UUID) throws {
        let url = packageURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Lists all projects, newest first. Corrupt packages are skipped.
    public func listProjects() -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        var projects: [Project] = []
        for entry in entries where entry.pathExtension == Project.packageExtension {
            let name = entry.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name), let project = try? load(id: id) {
                projects.append(project)
            }
        }
        return projects.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Bytes used by a project package.
    public func size(of id: UUID) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: packageURL(for: id), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

extension ProjectStore {
    public func summaryURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.summaryName)
    }

    public func writeSummary(_ summary: ProjectSummary) throws {
        let data = try encoder.encode(summary)
        try data.write(to: summaryURL(for: summary.id), options: .atomic)
    }

    /// Every project's summary, newest first.
    ///
    /// For now built from the manifests, as `listProjects()` does; reading
    /// summary.json and backfilling missing or stale ones comes next.
    public func listSummaries() -> [ProjectSummary] {
        listProjects().map(ProjectSummary.init(project:))
    }
}
