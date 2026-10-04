import Foundation

/// A saved project (photo or video) inside the app's documents directory.
///
/// On disk a project is a package directory:
/// ```
/// <uuid>.picshop/
///   project.json      ← this struct (a photo document as its v1 projection, D3)
///   document-v2.json  ← photo projects: the lossless format 2 document (W3, D2)
///   summary.json      ← what Home shows (`ProjectSummary`)
///   media/…           ← imported originals + AI-rendered derivatives
///   masks/…           ← rasterised masks
///   thumbnail-2.jpg
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
    /// No person and no main subject to cut out (a screenshot, a table, a landscape): what the
    /// subject mask throws, instead of objectNotFound with an internal English label.
    case noSubject

    /// In the language the device speaks.
    public var message: String { message(french: Self.devicePrefersFrench) }

    public func message(french: Bool) -> String {
        switch self {
        case .projectNotFound: return french ? "Ce projet est introuvable." : "This project could not be found."
        case .corruptProject(let detail): return french ? "Le fichier du projet est abîmé (\(detail))." : "The project file is damaged (\(detail))."
        case .mediaUnavailable(let name): return french ? "Le média « \(name) » est introuvable." : "The media “\(name)” is missing."
        case .objectNotFound(let target):
            // Never an internal English label inside a French sentence: "subject" is said "pas de sujet".
            if french, let noun = Self.frenchLabel(for: target) {
                let elided = ["a", "e", "i", "o", "u", "é", "â", "h"].contains { noun.hasPrefix($0) }
                return "Je ne trouve pas \(elided ? "d'" : "de ")\(noun) sur la photo."
            }
            return french ? "Je ne trouve pas « \(target) » sur la photo." : "I couldn't find “\(target)” in the picture."
        case .ambiguousTarget(let count): return french ? "J'en vois \(count) — lequel ?" : "I found \(count) matches — which one?"
        // The name is the feature's English one: in French it is left out rather than quoted.
        case .unsupportedOperation(let name): return french ? "Ce n'est pas possible ici." : "“\(name)” isn't available here."
        case .modelUnavailable(let name): return french ? "Le modèle \(name) n'est pas encore installé." : "The \(name) model isn't installed yet."
        case .renderFailed(let detail): return french ? "Le rendu a échoué : \(detail)" : "Rendering failed: \(detail)"
        case .exportFailed(let detail): return french ? "L'export a échoué : \(detail)" : "Export failed: \(detail)"
        case .permissionDenied(let what): return french ? "L'accès à \(what) est refusé. Tu peux l'autoriser dans Réglages." : "Permission for \(what) was denied. You can enable it in Settings."
        case .speechUnavailable(let detail): return french ? "La commande vocale est indisponible : \(detail)" : "Voice control is unavailable: \(detail)"
        case .cancelled: return french ? "Annulé." : "Cancelled."
        case .noSubject: return french ? "Je ne vois ni personne ni sujet à détacher sur cette image." : "There's no person or main subject to cut out in this picture."
        }
    }

    /// The French noun for an internal English label ("subject" -> "sujet", "the person" -> "personne"),
    /// nil for anything else (words the person said are kept as said).
    public static func frenchLabel(for label: String) -> String? {
        let table: [String: String] = [
            "subject": "sujet", "object": "objet", "person": "personne", "people": "personnes", "face": "visage", "faces": "visages", "hand": "main",
            "text": "texte", "background": "arrière-plan", "foreground": "premier plan", "sky": "ciel", "dog": "chien", "cat": "chat", "bird": "oiseau",
            "horse": "cheval", "cow": "vache", "sheep": "mouton", "animal": "animal", "car": "voiture", "truck": "camion", "bus": "bus", "bicycle": "vélo",
            "motorcycle": "moto", "boat": "bateau", "airplane": "avion", "tree": "arbre", "blemish": "imperfection", "logo": "logo", "watermark": "filigrane",
            "sign": "panneau", "table": "tableau", "cell": "case", "cells": "cases", "number": "nombre", "numbers": "nombres", "data": "données",
            "region": "zone", "area": "zone", "selection": "sélection", "phone": "téléphone", "window": "fenêtre", "building": "bâtiment", "lamp": "lampe",
            "chair": "chaise", "bottle": "bouteille", "cup": "tasse", "glasses": "lunettes", "hat": "chapeau", "shadow": "ombre", "teeth": "dents",
            "eyes": "yeux", "hair": "cheveux", "skin": "peau", "wire": "fil", "wires": "fils", "pole": "poteau", "trash": "déchet", "plate": "plaque",
        ]
        var key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) { key.removeFirst(article.count) }
        return table[key]
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
        // Compact: smaller and faster than pretty, sorted output. Both decode.
        encoder = JSONEncoder()
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

    /// Writes the manifest, then its summary (see `saveWithSummary(_:)`).
    public func save(_ project: Project) throws {
        try saveWithSummary(project)
    }

    /// Writes the manifest with `modifiedAt` set to now, then `summary.json`
    /// after it, and returns that summary. A summary that fails to write is
    /// rebuilt by the next `listSummaries()`.
    @discardableResult
    public func saveWithSummary(_ project: Project) throws -> ProjectSummary {
        try createPackage(for: project.id)
        var copy = project
        // Whole seconds, as ISO 8601 stores them: the summary returned here
        // equals the one a later reload decodes.
        copy.createdAt = Self.wholeSeconds(copy.createdAt)
        copy.modifiedAt = Self.wholeSeconds(Date())
        // D2: project.json keeps the v1 projection every W2 build opens (D3); document-v2.json, written after it with
        // the digest of exactly those bytes, keeps the lossless format 2 document.
        var lossless: PhotoDocument?
        if case .photo(let document) = copy.content {
            lossless = document
            let id = project.id
            copy.content = .photo(DocumentCodec.v1Projection(of: document, maskFileExists: { path in
                FileManager.default.fileExists(atPath: self.url(for: path, in: id).path)
            }))
        }
        let data = try encoder.encode(copy)
        try data.write(to: manifestURL(for: project.id), options: .atomic)
        if let lossless {
            try writeDocumentV2(lossless, manifest: data, projectID: project.id)
        }
        let summary = ProjectSummary(project: copy)
        try? writeSummary(summary)
        return summary
    }

    /// D2 step 3: never over a newer build's file (its header's format version above 2); otherwise written when the
    /// document holds v2-only state or the file already exists (so a later save drops nothing).
    private func writeDocumentV2(_ document: PhotoDocument, manifest: Data, projectID: UUID) throws {
        let url = documentV2URL(for: projectID)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, let header = documentV2Header(for: projectID), header.formatVersion > PhotoDocument.formatVersion { return }
        guard exists || DocumentCodec.needsV2(document) else { return }
        var stored = document
        stored.formatVersion = PhotoDocument.formatVersion
        let envelope = PhotoDocumentEnvelope(document: stored, v1Digest: DocumentCodec.digest(manifest), writer: PhotoDocumentEnvelope.currentWriter)
        try encoder.encode(envelope).write(to: url, options: .atomic)
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public func manifestURL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.manifestName)
    }

    /// The project, its photo document at format 2 from project.json and document-v2.json (D2, `loadWithSource`).
    public func load(id: UUID) throws -> Project {
        try loadWithSource(id: id).project
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

    /// Every project's summary, newest first, without decoding a manifest
    /// whose summary is current.
    ///
    /// A summary that is missing, unreadable or older than its manifest (a
    /// build before summaries, an interrupted save, a manifest written by
    /// another path) is rebuilt from project.json once and written back. A
    /// package whose manifest cannot be read keeps its last summary, so the
    /// card stays and opening it reports the damage; with neither, it is skipped.
    public func listSummaries() -> [ProjectSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        var summaries: [ProjectSummary] = []
        for entry in entries where entry.pathExtension == Project.packageExtension {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent) else { continue }
            if let summary = summary(for: id) { summaries.append(summary) }
        }
        return summaries.sorted { lhs, rhs in
            lhs.modifiedAt != rhs.modifiedAt ? lhs.modifiedAt > rhs.modifiedAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// One project's summary: summary.json when current, else rebuilt from the manifest.
    public func summary(for id: UUID) -> ProjectSummary? {
        let manifestDate = Self.modificationDate(of: manifestURL(for: id))
        let summaryURL = summaryURL(for: id)
        let stored = (try? Data(contentsOf: summaryURL)).flatMap { try? decoder.decode(ProjectSummary.self, from: $0) }
        if let stored, stored.id == id, let summaryDate = Self.modificationDate(of: summaryURL),
           manifestDate.map({ summaryDate >= $0 }) ?? true {
            return stored
        }
        guard let manifestDate, let project = try? load(id: id) else { return stored }
        let rebuilt = ProjectSummary(project: project)
        if (try? writeSummary(rebuilt)) != nil, manifestDate > Date() {
            // A manifest dated in the future (a clock change) must not force a rebuild on every launch.
            try? FileManager.default.setAttributes([.modificationDate: manifestDate], ofItemAtPath: summaryURL.path)
        }
        return rebuilt
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - W3: document v2 (D2, D17)

public extension Project {
    /// The lossless photo document next to project.json (D2).
    static let documentV2Name = PhotoDocumentEnvelope.fileName
}

public extension ProjectStore {
    func documentV2URL(for id: UUID) -> URL {
        packageURL(for: id).appendingPathComponent(Project.documentV2Name)
    }

    /// load(id:) plus where the photo document came from (D2):
    /// - no document-v2.json, or one whose header does not decode or names another format: project.json migrated (.v1);
    /// - a header with a format version above 2 (a newer build): project.json migrated, the file untouched (.newerFormat);
    /// - a format 2 envelope whose digest matches project.json's bytes: its document (.v2); one that does not decode:
    ///   project.json (.v1); a digest that differs (an older build saved meanwhile): the merge (.merged), which the
    ///   session saves again so both files agree.
    func loadWithSource(id: UUID) throws -> (project: Project, source: DocumentCodec.LoadSource) {
        let manifest = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw PicshopError.projectNotFound(id) }
        let data: Data
        var project: Project
        do {
            data = try Data(contentsOf: manifest)
            project = try decoder.decode(Project.self, from: data)
        } catch let error as PicshopError {
            throw error
        } catch {
            throw PicshopError.corruptProject(String(describing: error))
        }
        guard case .photo(let v1) = project.content else { return (project, .v1) }
        func finish(_ document: PhotoDocument, _ source: DocumentCodec.LoadSource) -> (project: Project, source: DocumentCodec.LoadSource) {
            project.content = .photo(document)
            return (project, source)
        }
        let url = documentV2URL(for: id)
        guard let envelopeData = try? Data(contentsOf: url) else { return finish(DocumentCodec.migrated(v1), .v1) }
        guard let header = try? decoder.decode(PhotoDocumentEnvelopeHeader.self, from: envelopeData), header.format == PhotoDocumentEnvelope.format else {
            PSLog.error("document-v2.json of \(id) has no readable header: opening project.json", category: .core)
            return finish(DocumentCodec.migrated(v1), .v1)
        }
        if header.formatVersion > PhotoDocument.formatVersion {
            PSLog.info("document-v2.json of \(id) is format \(header.formatVersion): opening the v1 projection", category: .core)
            return finish(DocumentCodec.migrated(v1), .newerFormat)
        }
        guard header.formatVersion == PhotoDocument.formatVersion, let envelope = try? decoder.decode(PhotoDocumentEnvelope.self, from: envelopeData) else {
            PSLog.error("document-v2.json of \(id) does not decode: opening project.json", category: .core)
            return finish(DocumentCodec.migrated(v1), .v1)
        }
        if envelope.v1Digest == DocumentCodec.digest(data) {
            return finish(DocumentCodec.migrated(envelope.document), .v2)
        }
        PSLog.info("project.json of \(id) changed since document-v2.json was written: merging", category: .core)
        let merged = DocumentCodec.merge(v1: v1, v2: envelope.document, maskFileExists: { path in
            FileManager.default.fileExists(atPath: self.url(for: path, in: id).path)
        })
        return finish(merged, .merged)
    }

    /// The existing document-v2.json's header, nil when absent or unreadable; cached by the file's modification date
    /// and size, so a save checks it without decoding the file again.
    func documentV2Header(for id: UUID) -> PhotoDocumentEnvelopeHeader? {
        let url = documentV2URL(for: id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            EnvelopeHeaderCache.shared.remove(url.path)
            return nil
        }
        let stamp = EnvelopeHeaderCache.Stamp(date: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.int64Value ?? -1)
        if let cached = EnvelopeHeaderCache.shared.header(for: url.path, stamp: stamp) { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let header = try? decoder.decode(PhotoDocumentEnvelopeHeader.self, from: data) else { return nil }
        EnvelopeHeaderCache.shared.store(header, for: url.path, stamp: stamp)
        return header
    }

    /// D17 storage: deletes files under media/ and masks/ not in `keeping` (relative paths, as documents store them)
    /// and not modified in the last 24 hours (in-flight writes); returns (files, bytes). Nothing outside those two
    /// directories is touched.
    @discardableResult
    func collectGarbage(projectID: UUID, keeping: Set<String>) throws -> (files: Int, bytes: Int) {
        try collectGarbage(projectID: projectID, keeping: keeping, now: Date())
    }

    /// `collectGarbage(projectID:keeping:)` at a given time (tests).
    @discardableResult
    func collectGarbage(projectID: UUID, keeping: Set<String>, now: Date) throws -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        let package = packageURL(for: projectID).standardizedFileURL
        // Both documents on disk keep their files, whichever build wrote them: a document-v2.json from a newer build
        // (this build edits its v1 projection and never rewrites it) or one it cannot decode still owns its layers'
        // media, mask stacks and retained fields for when the newer build opens the project again (D2).
        var keeping = keeping
        for url in [documentV2URL(for: projectID), manifestURL(for: projectID)] {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            PhotoDocument.collectPaths(in: object, into: &keeping)
        }
        var files = 0, bytes = 0
        for directory in [Project.mediaDirectory, Project.masksDirectory] {
            let root = package.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let standardized = url.standardizedFileURL.path
                guard standardized.hasPrefix(package.path + "/") else { continue }
                let relative = String(standardized.dropFirst(package.path.count + 1))
                guard !keeping.contains(relative) else { continue }
                let modified = values?.contentModificationDate ?? now
                guard now.timeIntervalSince(modified) >= 24 * 3600 else { continue }
                let size = values?.fileSize ?? 0
                do {
                    try fm.removeItem(at: url)
                    files += 1
                    bytes += size
                } catch {
                    PSLog.error("could not delete \(relative): \(error)", category: .core)
                }
            }
        }
        if files > 0 { PSLog.info("project \(projectID): removed \(files) unused files (\(bytes) bytes)", category: .core) }
        return (files, bytes)
    }
}

/// document-v2.json headers by path, keyed by the file's modification date and size (D2: the save checks the header
/// every time without decoding the file).
final class EnvelopeHeaderCache: @unchecked Sendable {
    struct Stamp: Equatable {
        var date: Date?
        var size: Int64
    }

    static let shared = EnvelopeHeaderCache()
    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, header: PhotoDocumentEnvelopeHeader)] = [:]

    func header(for path: String, stamp: Stamp) -> PhotoDocumentEnvelopeHeader? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.stamp == stamp else { return nil }
        return entry.header
    }

    func store(_ header: PhotoDocumentEnvelopeHeader, for path: String, stamp: Stamp) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count > 64 { entries.removeAll() }
        entries[path] = (stamp, header)
    }

    func remove(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = nil
    }
}
