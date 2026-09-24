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
///
/// Home reads `summaries` (small, decoded off the main thread by `reload()`)
/// and one `ThumbnailSlot` per card. Nothing here decodes a manifest or an
/// image on the main thread, and every change updates its one summary in
/// place: no rescan.
@MainActor
@Observable
public final class ProjectLibrary {
    public let store: ProjectStore
    /// Full projects, filled only by `refresh()`. Phase 2 removes it.
    public private(set) var projects: [Project] = []
    public internal(set) var isImporting = false
    public var errorMessage: String?

    /// Home's list, newest first, filled by `reload()` and kept current in place.
    public private(set) var summaries: [ProjectSummary] = []
    /// False until the first `reload()` finishes, so Home does not flash its empty state.
    public private(set) var hasLoaded = false

    @ObservationIgnored private var slots: [UUID: ThumbnailSlot] = [:]
    /// Least recently used first.
    @ObservationIgnored private var slotOrder: [UUID] = []
    @ObservationIgnored private let sequencer = WriteSequencer()
    /// Deleted this session: a late write or listing never brings them back.
    @ObservationIgnored private var removed: Set<UUID> = []
    /// Summary changes made while a `reload()` is listing, replayed over its result.
    @ObservationIgnored private var edits: [(seq: Int, id: UUID, summary: ProjectSummary?)] = []
    @ObservationIgnored private var editSeq = 0
    @ObservationIgnored private var activeReloads = 0
    /// Cards whose file check is running, with the newest summary asked for meanwhile.
    @ObservationIgnored private var thumbnailChecks: [UUID: ProjectSummary?] = [:]
    @ObservationIgnored private var regenerated: Set<UUID> = []

    /// A decoded 512 px thumbnail is about a megabyte: slots beyond this are dropped.
    static let slotLimit = 48

    /// Does no I/O: Home calls `reload()`.
    public init(store: ProjectStore) {
        self.store = store
    }

    // MARK: Summaries

    /// Reads every project's summary off the main thread.
    public func reload() async {
        let store = self.store
        let startSeq = editSeq
        activeReloads += 1
        var loaded = await Task.detached(priority: .userInitiated) { store.listSummaries() }.value
        activeReloads -= 1
        for edit in edits where edit.seq > startSeq {
            loaded.removeAll { $0.id == edit.id }
            if let summary = edit.summary { loaded.append(summary) }
        }
        if activeReloads == 0 { edits.removeAll() }
        loaded.removeAll { removed.contains($0.id) }
        loaded.sort(by: Self.newestFirst)
        if loaded != summaries { summaries = loaded }
        if !hasLoaded { hasLoaded = true }
        let live = Set(loaded.map(\.id))
        for id in slots.keys where !live.contains(id) { dropSlot(id) }
    }

    /// Decodes a whole project off the main thread, for the editor about to open.
    public func load(_ id: UUID) async throws -> Project {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) { try store.load(id: id) }.value
    }

    /// Saves a project from an editor: encode and atomic write off the main
    /// thread, then its summary updated in place. Writes of one project land in
    /// the order they were asked for; one overtaken by a newer save is skipped.
    public func persist(_ project: Project) async {
        let id = project.id
        let store = self.store
        let sequencer = self.sequencer
        let ticket = sequencer.issue(id)
        let result = await Task.detached(priority: .utility) { () -> Result<ProjectSummary?, Error> in
            Result { try sequencer.perform(ticket, for: id) { try store.saveWithSummary(project) } }
        }.value
        switch result {
        case .success(let summary): if let summary { upsert(summary) }
        case .failure(let error): errorMessage = Self.message(for: error)
        }
    }

    /// Saves synchronously. Termination paths only.
    public func saveNow(_ project: Project) {
        let store = self.store
        let ticket = sequencer.issue(project.id)
        do {
            if let summary = try sequencer.perform(ticket, for: project.id, { try store.saveWithSummary(project) }) {
                upsert(summary)
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Replaces or adds one summary and keeps the list newest first.
    func upsert(_ summary: ProjectSummary) {
        guard !removed.contains(summary.id) else { return }
        var list = summaries
        if let index = list.firstIndex(where: { $0.id == summary.id }) {
            guard list[index] != summary else { return }
            list[index] = summary
        } else {
            list.append(summary)
        }
        list.sort(by: Self.newestFirst)
        summaries = list
        logEdit(summary.id, summary)
    }

    private func logEdit(_ id: UUID, _ summary: ProjectSummary?) {
        editSeq += 1
        if activeReloads > 0 { edits.append((editSeq, id, summary)) }
    }

    nonisolated static func newestFirst(_ lhs: ProjectSummary, _ rhs: ProjectSummary) -> Bool {
        lhs.modifiedAt != rhs.modifiedAt ? lhs.modifiedAt > rhs.modifiedAt : lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: Thumbnails

    /// The one thumbnail slot of a project; a card reads only its own.
    public func slot(for id: UUID) -> ThumbnailSlot {
        if let slot = slots[id] {
            if slotOrder.last != id, let index = slotOrder.firstIndex(of: id) {
                slotOrder.remove(at: index)
                slotOrder.append(id)
            }
            return slot
        }
        let slot = ThumbnailSlot()
        slots[id] = slot
        slotOrder.append(id)
        trimSlots()
        return slot
    }

    /// Shows a new thumbnail on the project's card at once (never an empty
    /// slot in between) and writes the 512 px file off the main thread.
    public func setThumbnail(_ image: UIImage, for id: UUID, modifiedAt: Date) {
        let slot = slot(for: id)
        slot.update(image, modifiedAt: modifiedAt, freshAsOf: Date())
        let store = self.store
        let sequencer = self.sequencer
        let ticket = sequencer.issueThumbnail(id)
        Task.detached(priority: .utility) {
            guard let cgImage = ThumbnailIO.cgImage(from: image) else { return }
            let written = sequencer.performThumbnail(ticket, for: id) {
                ThumbnailGenerator.writeThumbnail(image: cgImage, projectID: id, store: store)
                return ThumbnailIO.modificationDate(of: store.thumbnailURL(for: id))
            }
            guard let written else { return }
            await MainActor.run {
                // The file now holds this image: a later check need not decode it again.
                if slot.image === image, (slot.freshAsOf ?? .distantPast) < written { slot.freshAsOf = written }
            }
        }
    }

    /// Brings a card's slot up to date with its summary: decodes the thumbnail
    /// file off the main thread when the slot is empty or older than the file,
    /// and rebuilds a missing file from the media. Never empties a slot.
    public func loadThumbnail(for summary: ProjectSummary) async {
        let id = summary.id
        if thumbnailChecks[id] != nil {
            thumbnailChecks[id] = .some(summary)
            return
        }
        var next: ProjectSummary? = summary
        thumbnailChecks[id] = .some(nil)
        while let current = next {
            await checkThumbnail(for: current)
            let pending = thumbnailChecks[id] ?? nil
            thumbnailChecks[id] = .some(nil)
            next = pending.flatMap { $0.modifiedAt != current.modifiedAt ? $0 : nil }
        }
        thumbnailChecks[id] = nil
    }

    private func checkThumbnail(for summary: ProjectSummary) async {
        let slot = slot(for: summary.id)
        guard slot.image == nil || slot.checkedFor != summary.modifiedAt else { return }
        let url = store.thumbnailURL(for: summary.id)
        let known = slot.image == nil ? nil : slot.freshAsOf
        let found = await Task.detached(priority: .userInitiated) { ThumbnailIO.read(url, ifNewerThan: known) }.value
        switch found {
        case .image(let image, let date):
            if slot.image == nil || (slot.freshAsOf ?? .distantPast) < date {
                slot.update(image, modifiedAt: date, freshAsOf: date)
            }
        case .current:
            break
        case .missing:
            await regenerateThumbnail(for: summary)
        }
        slot.checkedFor = summary.modifiedAt
    }

    /// Projects saved by older builds may have no current thumbnail: one is
    /// rebuilt from the original media in the background, once per session,
    /// and only that card's slot changes.
    private func regenerateThumbnail(for summary: ProjectSummary) async {
        let id = summary.id
        guard !regenerated.contains(id) else { return }
        regenerated.insert(id)
        let store = self.store
        let result = await Task.detached(priority: .utility) { () async -> (image: UIImage, date: Date)? in
            guard let project = try? store.load(id: id) else { return nil }
            var image: CGImage?
            switch project.content {
            case .photo(let document):
                if let asset = document.baseLayer?.imageAsset {
                    image = try? ImageSupport.loadCGImage(at: store.url(for: asset.relativePath, in: id), maxPixelSize: 512)
                }
            case .video(let timeline):
                image = await VideoThumbnailer(store: store, projectID: id).poster(for: timeline)
            case .pdf(let model):
                image = PDFEditingService(store: store, projectID: id).thumbnail(for: 0, in: model, height: 400)?.cgImage
            }
            guard let image else { return nil }
            ThumbnailGenerator.writeThumbnail(image: image, projectID: id, store: store)
            if case .image(let decoded, let date) = ThumbnailIO.read(store.thumbnailURL(for: id), ifNewerThan: nil) { return (image: decoded, date: date) }
            return nil
        }.value
        guard let result, !removed.contains(id) else { return }
        let slot = slot(for: id)
        if slot.image == nil || (slot.freshAsOf ?? .distantPast) < result.date {
            slot.update(result.image, modifiedAt: result.date, freshAsOf: result.date)
        }
    }

    private func trimSlots() {
        // The newest project feeds the hero and the backdrop: it always keeps its slot.
        let pinned = summaries.first?.id
        var index = 0
        while slotOrder.count > Self.slotLimit, index < slotOrder.count {
            let id = slotOrder[index]
            if id == pinned { index += 1; continue }
            slotOrder.remove(at: index)
            slots[id] = nil
        }
    }

    private func dropSlot(_ id: UUID) {
        slots[id] = nil
        slotOrder.removeAll { $0 == id }
    }

    /// Phase 2 removes: the card's slot image, loading it when needed.
    public func thumbnail(for project: Project) -> UIImage? {
        let slot = slot(for: project.id)
        let summary = ProjectSummary(project: project)
        if slot.checkedFor != summary.modifiedAt {
            Task { await loadThumbnail(for: summary) }
        }
        return slot.image
    }

    /// Phase 2 removes: re-reads a thumbnail rewritten on disk, keeping the
    /// current image until the new one is decoded. No rescan.
    public func invalidateThumbnail(for id: UUID) {
        guard let slot = slots[id] else { return }
        slot.checkedFor = nil
        let summary = summaries.first { $0.id == id }
        let url = store.thumbnailURL(for: id)
        let known = slot.freshAsOf
        Task {
            if let summary {
                await loadThumbnail(for: summary)
                return
            }
            let found = await Task.detached(priority: .userInitiated) { ThumbnailIO.read(url, ifNewerThan: known) }.value
            if case .image(let image, let date) = found { slot.update(image, modifiedAt: date, freshAsOf: date) }
        }
    }

    // MARK: Changes

    public func delete(_ summary: ProjectSummary) {
        deleteProject(summary.id)
    }

    /// Phase 2 removes.
    public func delete(_ project: Project) {
        deleteProject(project.id)
    }

    private func deleteProject(_ id: UUID) {
        removed.insert(id)
        if summaries.contains(where: { $0.id == id }) { summaries.removeAll { $0.id == id } }
        logEdit(id, nil)
        dropSlot(id)
        let store = self.store
        let sequencer = self.sequencer
        // Any save still queued for it is overtaken, so it cannot recreate the package.
        let ticket = sequencer.issue(id)
        Task.detached(priority: .utility) {
            _ = try? sequencer.perform(ticket, for: id) { try store.delete(id: id) }
        }
    }

    /// Renames a project; the title lives on the content model. The card
    /// changes at once, the manifest off the main thread.
    public func rename(_ summary: ProjectSummary, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != summary.title else { return }
        var renamed = summary
        renamed.title = trimmed
        upsert(renamed)
        do {
            var project = try await load(summary.id)
            Self.retitle(&project, trimmed)
            await persist(project)
        } catch {
            upsert(summary)
            errorMessage = Self.message(for: error)
        }
    }

    /// Phase 2 removes.
    public func rename(_ project: Project, to title: String) {
        let summary = summaries.first { $0.id == project.id } ?? ProjectSummary(project: project)
        Task { await rename(summary, to: title) }
    }

    /// Copies a project's package under a new id, with its card image shown at once.
    public func duplicate(_ summary: ProjectSummary) async {
        let store = self.store
        let newID = UUID()
        let title = String(format: L("%@ copy"), summary.title)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ProjectSummary, Error> in
            Result {
                var project = try store.load(id: summary.id)
                project.id = newID
                switch project.content {
                case .photo(var document): document.id = newID; project.content = .photo(document)
                case .video(var timeline): timeline.id = newID; project.content = .video(timeline)
                case .pdf(var document): document.id = newID; project.content = .pdf(document)
                }
                ProjectLibrary.retitle(&project, title)
                project.createdAt = Date()
                try FileManager.default.copyItem(at: store.packageURL(for: summary.id), to: store.packageURL(for: newID))
                return try store.saveWithSummary(project)
            }
        }.value
        switch result {
        case .success(let copy):
            if let image = slots[summary.id]?.image {
                slot(for: newID).update(image, modifiedAt: copy.modifiedAt, freshAsOf: Date())
            }
            upsert(copy)
        case .failure(let error):
            errorMessage = Self.message(for: error)
        }
    }

    /// Phase 2 removes.
    public func duplicate(_ project: Project) {
        let summary = summaries.first { $0.id == project.id } ?? ProjectSummary(project: project)
        Task { await duplicate(summary) }
    }

    nonisolated static func retitle(_ project: inout Project, _ title: String) {
        switch project.content {
        case .photo(var document): document.title = title; project.content = .photo(document)
        case .video(var timeline): timeline.title = title; project.content = .video(timeline)
        case .pdf(var document): document.title = title; project.content = .pdf(document)
        }
    }

    // MARK: Creating

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
            return try await createPhotoProject(from: data, title: defaultTitle(video: false))
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Writes the picture, its manifest and its thumbnail off the main thread.
    public func createPhotoProject(from data: Data, title: String) async throws -> Project {
        let store = self.store
        let created = try await Task.detached(priority: .userInitiated) { () throws -> CreatedProject in
            let id = UUID()
            try store.createPackage(for: id)
            let extensionName = data.starts(with: [0xFF, 0xD8]) ? "jpg" : (data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "heic")
            let relative = "\(Project.mediaDirectory)/original.\(extensionName)"
            let url = store.url(for: relative, in: id)
            try data.write(to: url, options: .atomic)
            guard let size = ImageSupport.pixelSize(at: url) else { throw PicshopError.mediaUnavailable("photo") }
            let asset = MediaAsset(kind: .image, relativePath: relative, pixelSize: size, origin: .photoLibrary(localIdentifier: ""))
            var document = PhotoDocument(title: title, baseImage: asset)
            document.id = id
            let poster = try? ImageSupport.loadCGImage(at: url, maxPixelSize: 512)
            return try CreatedProject.finish(Project(id: id, content: .photo(document)), poster: poster, store: store)
        }.value
        return adopt(created)
    }

    /// Copies the movie into the project and writes its manifest and poster off the main thread.
    public func createVideoProject(from sourceURL: URL, title: String) async throws -> Project {
        let store = self.store
        let created = try await Task.detached(priority: .userInitiated) { () async throws -> CreatedProject in
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
            let poster = await VideoThumbnailer(store: store, projectID: id).poster(for: timeline)
            return try CreatedProject.finish(Project(id: id, content: .video(timeline)), poster: poster, store: store)
        }.value
        return adopt(created)
    }

    /// Imports a PDF off the main thread.
    public func createPDFProject(from url: URL) async -> Project? {
        isImporting = true
        defer { isImporting = false }
        let store = self.store
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let created = try await Task.detached(priority: .userInitiated) { () throws -> CreatedProject in
                let model = try PDFEditingService.importDocument(from: url, store: store, title: title)
                return try CreatedProject.finish(Project(id: model.id, content: .pdf(model), createdAt: model.createdAt), poster: nil, store: store)
            }.value
            return adopt(created)
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Puts a created project on Home: its summary and, at once, its thumbnail.
    func adopt(_ created: CreatedProject) -> Project {
        if let image = created.thumbnail {
            let slot = slot(for: created.project.id)
            slot.update(image, modifiedAt: created.summary.modifiedAt, freshAsOf: created.thumbnailDate ?? Date())
            slot.checkedFor = created.summary.modifiedAt
        }
        upsert(created.summary)
        return created.project
    }

    // MARK: Phase 2 removes

    /// Decodes every manifest on the calling thread. Nothing calls it any more.
    public func refresh() {
        projects = store.listProjects()
    }

    /// Saves synchronously and updates the one summary; no rescan.
    public func save(_ project: Project) {
        saveNow(project)
    }

    private func defaultTitle(video: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(video ? L("Video") : L("Photo")) · \(formatter.string(from: Date()))"
    }

    static func message(for error: Error) -> String {
        (error as? PicshopError)?.message ?? error.localizedDescription
    }
}

/// A project's thumbnail on Home. Each card, the hero and the backdrop read
/// only their own slot, so a thumbnail arriving redraws that view alone.
@MainActor
@Observable
public final class ThumbnailSlot {
    public private(set) var image: UIImage?
    public private(set) var modifiedAt: Date?
    /// The image is at least as new as the thumbnail file of this date.
    @ObservationIgnored var freshAsOf: Date?
    /// The summary date last checked against the file.
    @ObservationIgnored var checkedFor: Date?

    init() {}

    fileprivate func update(_ image: UIImage, modifiedAt: Date, freshAsOf: Date) {
        self.image = image
        if self.modifiedAt != modifiedAt { self.modifiedAt = modifiedAt }
        self.freshAsOf = freshAsOf
    }
}

/// A project just written by a create path: its manifest, summary and
/// thumbnail file written, and the thumbnail decoded, all off the main thread.
struct CreatedProject: @unchecked Sendable {
    let project: Project
    let summary: ProjectSummary
    let thumbnail: UIImage?
    let thumbnailDate: Date?

    static func finish(_ project: Project, poster: CGImage?, store: ProjectStore) throws -> CreatedProject {
        if let poster { ThumbnailGenerator.writeThumbnail(image: poster, projectID: project.id, store: store) }
        let summary = try store.saveWithSummary(project)
        var saved = project
        saved.createdAt = summary.createdAt
        saved.modifiedAt = summary.modifiedAt
        var thumbnail: UIImage?
        var date: Date?
        if case .image(let image, let written) = ThumbnailIO.read(store.thumbnailURL(for: project.id), ifNewerThan: nil) {
            thumbnail = image
            date = written
        }
        return CreatedProject(project: saved, summary: summary, thumbnail: thumbnail, thumbnailDate: date)
    }
}

/// Orders the writes of each project, from any thread. A write runs only if
/// no newer one was issued for the same project since, so an older save that
/// finishes late never overwrites a newer one.
final class WriteSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [UUID: Int] = [:]
    private var latestThumbnail: [UUID: Int] = [:]
    private var counter = 0

    func issue(_ id: UUID) -> Int {
        lock.withLock {
            counter += 1
            latest[id] = counter
            return counter
        }
    }

    /// Runs `work` under the lock when `ticket` is still the newest for `id`; nil when overtaken.
    func perform<T>(_ ticket: Int, for id: UUID, _ work: () throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard latest[id] == ticket else { return nil }
        return try work()
    }

    func issueThumbnail(_ id: UUID) -> Int {
        lock.withLock {
            counter += 1
            latestThumbnail[id] = counter
            return counter
        }
    }

    func performThumbnail<T>(_ ticket: Int, for id: UUID, _ work: () -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard latestThumbnail[id] == ticket else { return nil }
        return work()
    }
}

/// Thumbnail file reads and conversions, off the main thread.
enum ThumbnailIO {
    enum Found: @unchecked Sendable {
        case image(UIImage, Date)
        /// The file is no newer than the image already shown.
        case current
        case missing
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Decodes the file, ready to draw, when it is newer than `known` (or `known` is nil).
    static func read(_ url: URL, ifNewerThan known: Date?) -> Found {
        guard let date = modificationDate(of: url) else { return .missing }
        if let known, date <= known { return .current }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = UIImage(data: data) else { return .missing }
        // Decoded here rather than at draw time, so the first frame costs nothing.
        return .image(image.preparingForDisplay() ?? image, date)
    }

    static func cgImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage { return cgImage }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
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
