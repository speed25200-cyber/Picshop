#if canImport(CoreML)
import Foundation
import CoreML
import CryptoKit
import PicshopCore
import PicshopIntent

/// A downloadable on-device model.
public struct ModelDescriptor: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case inpainting
        case superResolution
        case languageModel
        /// Stable Diffusion resources folder (text-guided fill).
        case generative
    }

    public var id: String
    public var displayName: String
    public var summary: String
    public var kind: Kind
    /// Approximate download size in megabytes.
    public var sizeMB: Int
    /// Remote archive (`.zip` of an `.mlpackage`, or a bare `.mlpackage` directory zipped).
    public var remoteURL: URL?
    /// Hugging Face repository for MLX language models.
    public var huggingFaceID: String?
    /// Hugging Face repository + folder holding compiled Core ML resources (downloaded file by file).
    public var huggingFaceFolder: HuggingFaceFolder?
    /// Ships inside the app bundle as `<id>.mlmodelc` (converted at build time).
    public var isBundledByDefault: Bool
    /// For a language model's Hugging Face folder: the only files fetched (nil: every file).
    public var fileAllowlist: [String]?

    public struct HuggingFaceFolder: Hashable, Sendable {
        public var repository: String
        public var path: String
        public var revision: String

        public init(repository: String, path: String, revision: String = "main") {
            self.repository = repository
            self.path = path
            self.revision = revision
        }
    }

    public init(id: String, displayName: String, summary: String, kind: Kind, sizeMB: Int, remoteURL: URL? = nil, huggingFaceID: String? = nil,
                huggingFaceFolder: HuggingFaceFolder? = nil, isBundledByDefault: Bool = false, fileAllowlist: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.huggingFaceFolder = huggingFaceFolder
        self.isBundledByDefault = isBundledByDefault
        self.fileAllowlist = fileAllowlist
        self.summary = summary
        self.kind = kind
        self.sizeMB = sizeMB
        self.remoteURL = remoteURL
        self.huggingFaceID = huggingFaceID
    }
}

/// The models Picshop knows how to use. The Core ML eraser and upscaler are
/// converted at build time and shipped inside the app; the larger runtimes are
/// fetched straight from Hugging Face on demand. An optional
/// `PICSHOP_MODEL_BASE_URL` (Info.plist or Settings) can still serve `<id>.zip` archives.
public enum ModelCatalog {
    public static var baseURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "picshop.modelBaseURL"), !override.isEmpty, let url = URL(string: override) { return url }
        if let value = Bundle.main.object(forInfoDictionaryKey: "PICSHOP_MODEL_BASE_URL") as? String, !value.isEmpty, let url = URL(string: value) { return url }
        return nil
    }

    public static var all: [ModelDescriptor] {
        [
            ModelDescriptor(id: "lama-inpainting", displayName: "Neural Eraser (LaMa)", summary: "Large-mask inpainting network for cleaner object removal on complex backgrounds.",
                            kind: .inpainting, sizeMB: 100, remoteURL: baseURL?.appendingPathComponent("lama-inpainting.zip"), isBundledByDefault: true),
            ModelDescriptor(id: "realesrgan-x4", displayName: "Super Resolution (Real-ESRGAN ×4)", summary: "Neural upscaler for sharper enlargements.",
                            kind: .superResolution, sizeMB: 33, remoteURL: baseURL?.appendingPathComponent("realesrgan-x4.zip"), isBundledByDefault: true),
            ModelDescriptor(id: "sd-generative-fill", displayName: "Generative Fill (Stable Diffusion)", summary: "Text-guided replacement: “remplace le ciel par un coucher de soleil”, “add a hat”.",
                            kind: .generative, sizeMB: 1900, remoteURL: baseURL?.appendingPathComponent("sd-generative-fill.zip"),
                            huggingFaceFolder: ModelDescriptor.HuggingFaceFolder(repository: "apple/coreml-stable-diffusion-v1-5", path: "split_einsum/compiled")),
        ] + LocalModelCatalog.all.map(liveModel)
    }

    /// A Live model (Qwen3.5 through MLX): its pinned Hugging Face files, installed into `<id>/model`.
    static func liveModel(_ entry: LocalModelEntry) -> ModelDescriptor {
        ModelDescriptor(id: entry.info.id, displayName: "Live brain (\(entry.info.displayName))",
                        summary: "The on-device model Picshop Live talks, looks and edits with. Everything stays on the iPhone.",
                        kind: .languageModel, sizeMB: Int(entry.downloadBytes / 1_000_000), huggingFaceID: entry.repository,
                        huggingFaceFolder: ModelDescriptor.HuggingFaceFolder(repository: entry.repository, path: "", revision: entry.info.revision),
                        fileAllowlist: LocalModelCatalog.fileAllowlist)
    }

    public static func descriptor(id: String) -> ModelDescriptor? { all.first { $0.id == id } }
}

/// Downloads, compiles and locates models. Files live in
/// `Application Support/Models/<id>/` and survive app updates.
public actor ModelManager {
    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(progress: Double)
        case compiling
        case installed
        case failed(String)
    }

    public static let shared = ModelManager()

    private var states: [String: State] = [:]
    private var observers: [UUID: @Sendable (String, State) -> Void] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    /// The downloads in flight, so an open editor can pause them.
    private var downloads: [String: DownloadHandle] = [:]
    /// True between pauseAll() and resumeAll(): new downloads wait too.
    private var isPaused = false
    /// Models that keep downloading while the others are paused (the Live model while an editor is open).
    private var pauseExemptions: Set<String> = []
    /// Every state change from a download, in order, through one stream rather than a task per chunk.
    private nonisolated let updates: AsyncStream<StateUpdate>.Continuation
    private let updateStream: AsyncStream<StateUpdate>
    private var updatePump: Task<Void, Never>?

    private struct StateUpdate: Sendable {
        var id: String
        var state: State
    }

    public let rootURL: URL

    /// Why a language-model install failed, as the `.failed` message: LocalBrainHub turns it into words.
    public enum FailureCode {
        /// "storage:<bytes needed>"
        public static let storage = "storage"
        public static let network = "network"
        /// A file's size or SHA-256 did not match the pinned revision.
        public static let verify = "verify"
        /// "server:<HTTP status>"
        public static let server = "server"
        /// The pinned revision lacks a file the model needs.
        public static let files = "files"
    }

    /// Retries after a network error, keeping what was downloaded (D12).
    static let retryDelays: [Double] = [2, 8, 30]

    public init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.rootURL = rootURL ?? support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        // Gigabytes of weights never go into iCloud backups; they download again.
        var root = self.rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let (stream, continuation) = AsyncStream.makeStream(of: StateUpdate.self, bufferingPolicy: .unbounded)
        updateStream = stream
        updates = continuation
        Self.removeRetiredModels(root: self.rootURL)
    }

    /// Models that left the catalog (the old Pro Brain, Qwen3 4B): their folders
    /// and the MLX hub's cached copy go, once, off the caller's thread. Idempotent.
    private static func removeRetiredModels(root: URL) {
        var folders = LocalModelCatalog.retiredModelIDs.map { root.appendingPathComponent($0, isDirectory: true) }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            folders.append(caches.appendingPathComponent("models/mlx-community/Qwen3-4B-4bit", isDirectory: true))
        }
        let present = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return }
        Task.detached(priority: .utility) {
            for folder in present {
                do {
                    try FileManager.default.removeItem(at: folder)
                    PSLog.info("removed retired model \(folder.lastPathComponent)", category: .models)
                } catch {
                    PSLog.error("could not remove retired model \(folder.lastPathComponent): \(error)", category: .models)
                }
            }
        }
    }

    /// Queues a state change behind the ones already sent: the progress ring never jumps back.
    private nonisolated func post(_ state: State, for id: String) {
        updates.yield(StateUpdate(id: id, state: state))
    }

    /// Starts the one consumer of the update stream (installs call it first).
    private func startUpdatePump() {
        guard updatePump == nil else { return }
        let stream = updateStream
        updatePump = Task { [weak self] in
            for await update in stream {
                await self?.set(update.state, for: update.id)
            }
        }
    }

    /// A download handle for a model, paused already when the editor holds installs.
    private func downloadHandle(for id: String) -> DownloadHandle {
        let handle = DownloadHandle()
        if isPaused, !pauseExemptions.contains(id) { handle.pause() }
        downloads[id] = handle
        return handle
    }

    public func directory(for id: String) -> URL {
        rootURL.appendingPathComponent(id, isDirectory: true)
    }

    /// Compiled model URL: a user-installed copy first, otherwise the copy shipped in the app bundle.
    public func compiledModelURL(for id: String) -> URL? {
        let directory = directory(for: id)
        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           let compiled = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
            return compiled
        }
        return Self.bundledModelURL(for: id)
    }

    /// The model compiled into the app bundle at build time, if any.
    public nonisolated static func bundledModelURL(for id: String) -> URL? {
        if let url = Bundle.main.url(forResource: id, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: id, withExtension: "mlmodelc", subdirectory: "Models") { return url }
        return nil
    }

    public nonisolated static func isBundled(_ id: String) -> Bool { bundledModelURL(for: id) != nil }

    public func isInstalled(_ id: String) -> Bool {
        if let descriptor = ModelCatalog.descriptor(id: id), descriptor.kind == .languageModel {
            return FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent("installed").path)
        }
        if let descriptor = ModelCatalog.descriptor(id: id), descriptor.kind == .generative {
            return resourcesURL(for: id) != nil
        }
        return compiledModelURL(for: id) != nil
    }

    /// A language model's weights folder, `<id>/model`, once installed.
    public func languageModelDirectory(for id: String) -> URL? {
        guard isInstalled(id) else { return nil }
        let url = directory(for: id).appendingPathComponent("model", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Bytes a model takes on disk (its whole folder, partial downloads included).
    public func bytesOnDisk(_ id: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory(for: id), includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Folder of compiled Stable Diffusion resources, if installed.
    public func resourcesURL(for id: String) -> URL? {
        let url = directory(for: id).appendingPathComponent("resources", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Unet.mlmodelc").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("UnetChunk1.mlmodelc").path) ? url : nil
    }

    public func state(of id: String) -> State {
        if let state = states[id] { return state }
        return isInstalled(id) ? .installed : .notInstalled
    }

    public func observe(_ handler: @escaping @Sendable (String, State) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func set(_ state: State, for id: String) {
        states[id] = state
        for observer in observers.values { observer(id, state) }
    }

    /// Progress reporting hooks for externally-managed downloads (MLX weights).
    public func setDownloadProgress(_ id: String, _ progress: Double) {
        set(.downloading(progress: progress.clamped(to: 0...1)), for: id)
    }

    public func setFailure(_ id: String, _ message: String) {
        set(.failed(message), for: id)
    }

    /// Marks an externally-managed model (MLX weights) as installed.
    public func markInstalled(_ id: String) throws {
        let directory = directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("installed"))
        set(.installed, for: id)
    }

    public func delete(_ id: String) throws {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        let directory = directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        set(.notInstalled, for: id)
    }

    /// Downloads and compiles a Core ML model archive, or fetches a Hugging Face folder.
    /// Unpacking and moving files run off the actor, so a call to the manager never
    /// waits behind an install. Language models download over Wi‑Fi only this way.
    public func install(_ descriptor: ModelDescriptor) {
        install(descriptor, allowsCellular: descriptor.kind != .languageModel)
    }

    /// install(_:), choosing whether the transfer may use cellular data (or a
    /// hotspot, or Low Data Mode). Without it, losing Wi‑Fi fails the install with
    /// `FailureCode.network`, keeping what was downloaded for the next attempt.
    public func install(_ descriptor: ModelDescriptor, allowsCellular: Bool) {
        guard activeTasks[descriptor.id] == nil, !isInstalled(descriptor.id) else { return }
        startUpdatePump()
        if descriptor.kind == .languageModel, let folder = descriptor.huggingFaceFolder {
            installLanguageModel(descriptor, folder: folder, allowsCellular: allowsCellular)
            return
        }
        if descriptor.remoteURL == nil, let folder = descriptor.huggingFaceFolder {
            installHuggingFaceFolder(descriptor, folder: folder)
            return
        }
        guard let remote = descriptor.remoteURL else {
            set(.failed(descriptor.isBundledByDefault ? "This build was made without the model. Update the app." : "No download source for this model."), for: descriptor.id)
            return
        }
        set(.downloading(progress: 0), for: descriptor.id)
        let id = descriptor.id
        let kind = descriptor.kind
        let directory = directory(for: id)
        let handle = downloadHandle(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await ModelDownloader.download(remote, handle: handle) { progress in
                    self.post(.downloading(progress: progress), for: id)
                }
                try Task.checkCancellation()
                self.post(.compiling, for: id)
                let installed: URL? = try await Task.detached(priority: .utility) { () throws -> URL? in
                    try? FileManager.default.removeItem(at: directory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let unpacked = try ModelDownloader.unzip(archive, into: directory.appendingPathComponent("unpacked", isDirectory: true))
                    guard kind != .generative else {
                        // Keep the compiled resources folder as-is (Unet.mlmodelc, TextEncoder.mlmodelc, …).
                        let resources = try ModelDownloader.findResourcesFolder(in: unpacked)
                        let destination = directory.appendingPathComponent("resources", isDirectory: true)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: resources, to: destination)
                        try? FileManager.default.removeItem(at: unpacked)
                        try? FileManager.default.removeItem(at: archive)
                        return nil
                    }
                    return try ModelDownloader.findModelPackage(in: unpacked)
                }.value
                if let package = installed {
                    let compiled = try await MLModel.compileModel(at: package)
                    try await Task.detached(priority: .utility) {
                        let destination = directory.appendingPathComponent("\(id).mlmodelc")
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: compiled, to: destination)
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent("unpacked", isDirectory: true))
                        try? FileManager.default.removeItem(at: archive)
                    }.value
                }
                self.post(.installed, for: id)
            } catch is CancellationError {
                self.post(.notInstalled, for: id)
            } catch {
                PSLog.error("model install failed: \(error)", category: .models)
                self.post(.failed(error.localizedDescription), for: id)
            }
            await self.clearTask(id)
        }
        activeTasks[id] = task
    }

    /// Downloads every file of a Hugging Face folder (compiled Stable Diffusion resources)
    /// into `<id>/resources`, with byte-accurate progress.
    private func installHuggingFaceFolder(_ descriptor: ModelDescriptor, folder: ModelDescriptor.HuggingFaceFolder) {
        set(.downloading(progress: 0), for: descriptor.id)
        let id = descriptor.id
        let directory = directory(for: id)
        let handle = downloadHandle(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await HuggingFaceHub.listFiles(repository: folder.repository, path: folder.path, revision: folder.revision)
                guard !entries.isEmpty else { throw PicshopError.modelUnavailable("empty folder on Hugging Face") }
                let total = max(1, entries.reduce(0) { $0 + $1.size })
                var done: Int64 = 0
                let staging = directory.appendingPathComponent("staging", isDirectory: true)
                try await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                }.value
                for entry in entries {
                    try Task.checkCancellation()
                    let relative = String(entry.path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let destination = staging.appendingPathComponent(relative)
                    let url = HuggingFaceHub.fileURL(repository: folder.repository, path: entry.path, revision: folder.revision)
                    let base = done
                    let size = entry.size
                    let temporary = try await ModelDownloader.download(url, handle: handle) { fraction in
                        let bytes = base + Int64(fraction * Double(size))
                        self.post(.downloading(progress: Double(bytes) / Double(total)), for: id)
                    }
                    try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }.value
                    done += entry.size
                }
                self.post(.compiling, for: id)
                let resources = directory.appendingPathComponent("resources", isDirectory: true)
                try await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: resources)
                    try FileManager.default.moveItem(at: staging, to: resources)
                }.value
                guard await self.resourcesURL(for: id) != nil else {
                    throw PicshopError.modelUnavailable("Unet.mlmodelc missing after download")
                }
                self.post(.installed, for: id)
            } catch is CancellationError {
                self.post(.notInstalled, for: id)
            } catch {
                PSLog.error("model install failed: \(error)", category: .models)
                self.post(.failed(error.localizedDescription), for: id)
            }
            await self.clearTask(id)
        }
        activeTasks[id] = task
    }

    /// A language model's pinned files into `<id>/model`:
    /// 1. the revision's listing, filtered by the allowlist (the required files must be there);
    /// 2. free storage for what is left plus 1 GB;
    /// 3. each file into `<id>/staging`, byte-accurate progress, 3 retries that keep
    ///    the resume data (also saved beside the file, for the next attempt); a file
    ///    already staged with the right size is kept, so a relaunch picks up there;
    /// 4. every size, then every LFS file's SHA-256 against the listing's `lfs.oid`;
    /// 5. one move of the whole folder, the `installed` mark, and the other Live
    ///    model's folder removed (one installed at a time).
    private func installLanguageModel(_ descriptor: ModelDescriptor, folder: ModelDescriptor.HuggingFaceFolder, allowsCellular: Bool) {
        set(.downloading(progress: 0), for: descriptor.id)
        let id = descriptor.id
        let directory = directory(for: id)
        let root = rootURL
        let allowlist = Set(descriptor.fileAllowlist ?? [])
        let others = ModelCatalog.all.filter { $0.kind == .languageModel && $0.id != id }.map { self.directory(for: $0.id) }
        let handle = downloadHandle(for: id)
        let task = Task { [weak self] in
            guard let self else { return }
            let staging = directory.appendingPathComponent("staging", isDirectory: true)
            do {
                let listing = try await HuggingFaceHub.listFiles(repository: folder.repository, path: folder.path, revision: folder.revision, recursive: false)
                let files = listing.filter { allowlist.isEmpty || allowlist.contains($0.path) }
                let names = Set(files.map(\.path))
                let hasWeights = names.contains("model.safetensors") || names.contains("model.safetensors.index.json")
                guard hasWeights, LocalModelCatalog.requiredFiles.allSatisfy(names.contains) else {
                    throw LanguageModelInstallError(code: FailureCode.files)
                }
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                }.value
                let total = max(1, files.reduce(0) { $0 + $1.size })
                let staged = await Task.detached(priority: .utility) { Self.stagedBytes(files, in: staging) }.value
                let free = Self.availableCapacity(at: root)
                let needed = total - staged + LocalModelCatalog.storageHeadroomBytes
                if let free, free < needed {
                    throw LanguageModelInstallError(code: "\(FailureCode.storage):\(needed)")
                }
                var done: Int64 = 0
                for file in files {
                    try Task.checkCancellation()
                    let destination = staging.appendingPathComponent(file.path)
                    if Self.fileSize(destination) == file.size, file.size > 0 {
                        done += file.size
                        self.post(.downloading(progress: Double(done) / Double(total)), for: id)
                        continue
                    }
                    let url = HuggingFaceHub.fileURL(repository: folder.repository, path: file.path, revision: folder.revision)
                    let base = done
                    let size = file.size
                    let resumeFile = staging.appendingPathComponent("." + file.path + ".resume")
                    let temporary: URL
                    do {
                        temporary = try await ModelDownloader.download(url, handle: handle, allowsCellular: allowsCellular, retryDelays: Self.retryDelays,
                                                                       resumeFile: resumeFile) { fraction in
                            let bytes = base + Int64(fraction * Double(size))
                            self.post(.downloading(progress: min(0.999, Double(bytes) / Double(total))), for: id)
                        }
                    } catch let error as DownloadHTTPError {
                        throw LanguageModelInstallError(code: "\(FailureCode.server):\(error.status)")
                    } catch let error as NSError where error.domain == NSURLErrorDomain && error.code != NSURLErrorCancelled {
                        throw LanguageModelInstallError(code: FailureCode.network)
                    }
                    try await Task.detached(priority: .utility) {
                        defer { try? FileManager.default.removeItem(at: resumeFile) }
                        if size > 0, Self.fileSize(temporary) != size {
                            try? FileManager.default.removeItem(at: temporary)
                            throw LanguageModelInstallError(code: FailureCode.verify)
                        }
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }.value
                    done += file.size
                }
                // Verifying: sizes first, then the SHA-256 of every LFS file.
                self.post(.compiling, for: id)
                try await Task.detached(priority: .utility) {
                    for file in files {
                        try Task.checkCancellation()
                        let url = staging.appendingPathComponent(file.path)
                        guard Self.fileSize(url) == file.size || file.size == 0 else {
                            try? FileManager.default.removeItem(at: url)
                            throw LanguageModelInstallError(code: FailureCode.verify)
                        }
                        if let expected = file.sha256, try Self.sha256(of: url) != expected.lowercased() {
                            try? FileManager.default.removeItem(at: url)
                            throw LanguageModelInstallError(code: FailureCode.verify)
                        }
                    }
                    let model = directory.appendingPathComponent("model", isDirectory: true)
                    try? FileManager.default.removeItem(at: model)
                    try FileManager.default.moveItem(at: staging, to: model)
                    try Data().write(to: directory.appendingPathComponent("installed"))
                    for other in others where FileManager.default.fileExists(atPath: other.path) {
                        try? FileManager.default.removeItem(at: other)
                    }
                }.value
                for other in ModelCatalog.all where other.kind == .languageModel && other.id != id {
                    self.post(.notInstalled, for: other.id)
                }
                PSLog.info("language model \(id) installed (\(total / 1_000_000) MB)", category: .models)
                self.post(.installed, for: id)
            } catch is CancellationError {
                self.post(.notInstalled, for: id)
            } catch let error as LanguageModelInstallError {
                PSLog.error("language model install failed: \(error.code)", category: .models)
                self.post(.failed(error.code), for: id)
            } catch let error as DownloadHTTPError {
                PSLog.error("language model listing failed: HTTP \(error.status)", category: .models)
                self.post(.failed("\(FailureCode.server):\(error.status)"), for: id)
            } catch {
                PSLog.error("language model install failed: \(error)", category: .models)
                let nsError = error as NSError
                self.post(.failed(nsError.domain == NSURLErrorDomain ? FailureCode.network : String(describing: error).prefix(80).description), for: id)
            }
            await self.clearTask(id)
        }
        activeTasks[id] = task
    }

    /// Bytes already staged with their final size (a download picked up after a relaunch).
    private static func stagedBytes(_ files: [HuggingFaceHub.File], in staging: URL) -> Int64 {
        files.reduce(0) { total, file in
            file.size > 0 && fileSize(staging.appendingPathComponent(file.path)) == file.size ? total + file.size : total
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Free space for large, important downloads; nil where the system does not say.
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity > 0 else { return nil }
        return capacity
    }

    /// Streams the file through SHA-256 (lowercase hex), 8 MB at a time.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 * 1_048_576) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func clearTask(_ id: String) {
        activeTasks[id] = nil
        downloads[id] = nil
    }

    public func cancelInstall(_ id: String) {
        activeTasks[id]?.cancel()
    }

    /// Pauses every download in flight while an editor is open, keeping what was
    /// already downloaded (`cancel(byProducingResumeData:)`); downloads that start
    /// meanwhile wait. Unpacking or compiling already under way finishes.
    public func pauseAll() async {
        await pauseAll(except: [])
    }

    /// pauseAll(), except for `ids`, which keep downloading (the Live model while an editor is open).
    public func pauseAll(except ids: Set<String>) async {
        guard !isPaused || pauseExemptions != ids else { return }
        isPaused = true
        pauseExemptions = ids
        for (id, handle) in downloads {
            if ids.contains(id) { handle.resume() } else { handle.pause() }
        }
    }

    /// Resumes the downloads pauseAll() stopped, from where they were.
    public func resumeAll() async {
        guard isPaused else { return }
        isPaused = false
        pauseExemptions = []
        for handle in downloads.values { handle.resume() }
    }
}

/// Pause and resume for one model's downloads (thread-safe). While paused, the
/// running transfer is cancelled with its resume data, and the next one waits.
final class DownloadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var task: URLSessionDownloadTask?
    /// Transfers cancelled by a pause, told apart from a real cancellation.
    private var pausedTasks: Set<ObjectIdentifier> = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Starts a transfer, or stops it at once (keeping what there is) when paused meanwhile.
    func start(_ task: URLSessionDownloadTask) {
        let stop: Bool = lock.withLock {
            self.task = task
            if paused { pausedTasks.insert(ObjectIdentifier(task)) }
            return paused
        }
        if stop { task.cancel() } else { task.resume() }
    }

    func finished() {
        lock.withLock { task = nil }
    }

    /// Whether this transfer ended because of a pause (asked once, by the delegate).
    func consumePause(of task: URLSessionTask) -> Bool {
        lock.withLock { pausedTasks.remove(ObjectIdentifier(task)) != nil }
    }

    func pause() {
        let running: URLSessionDownloadTask? = lock.withLock {
            paused = true
            guard let task else { return nil }
            pausedTasks.insert(ObjectIdentifier(task))
            return task
        }
        // The delegate hears a cancellation carrying the resume data and hands it back.
        running?.cancel(byProducingResumeData: { _ in })
    }

    func resume() {
        let resumed: [CheckedContinuation<Void, Error>] = lock.withLock {
            paused = false
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in resumed { waiter.resume() }
    }

    private enum Wait { case go, wait, cancelled }

    /// Returns at once when not paused; else when resume() is called. Throws when the install is cancelled.
    func waitUntilResumed() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let wait: Wait = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    guard paused else { return .go }
                    waiters[token] = continuation
                    return .wait
                }
                switch wait {
                case .go: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: token) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// A transfer stopped by pauseAll(), with what it needs to continue.
struct DownloadPaused: Error {
    var resumeData: Data?
}

/// The server answered, but not with the file.
struct DownloadHTTPError: Error {
    var status: Int

    /// Worth another try: rate limits and server errors.
    var isTransient: Bool { status == 429 || status >= 500 }
}

/// A language-model install that failed for a reason the hub can name (ModelManager.FailureCode).
struct LanguageModelInstallError: Error {
    var code: String
}

enum ModelDownloader {
    /// Downloads to a temporary file with progress, using a download task so large
    /// archives never pass through memory. A pause through `handle` keeps the
    /// resume data and continues from there once resumed.
    ///
    /// A network error (or a rate limit, or a server error) is retried after each
    /// of `retryDelays`, from the resume data it left. When the retries run out,
    /// the resume data is written to `resumeFile`, where the next call picks it up.
    static func download(_ url: URL, handle: DownloadHandle? = nil, allowsCellular: Bool = true, retryDelays: [Double] = ModelManager.retryDelays,
                         resumeFile: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var resumeData: Data? = resumeFile.flatMap { try? Data(contentsOf: $0) }
        var attempt = 0
        while true {
            if let handle { try await handle.waitUntilResumed() }
            do {
                return try await transfer(url, resumeData: resumeData, handle: handle, allowsCellular: allowsCellular, progress: progress)
            } catch let paused as DownloadPaused {
                // Stopped before it started: the earlier resume data still holds.
                resumeData = paused.resumeData ?? resumeData
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                let nsError = error as NSError
                let isNetwork = nsError.domain == NSURLErrorDomain && nsError.code != NSURLErrorCancelled
                let isTransientHTTP = (error as? DownloadHTTPError)?.isTransient ?? false
                // Go on from what this transfer got; with nothing new (or stale resume data), start the file over.
                resumeData = isNetwork ? nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data : nil
                guard isNetwork || isTransientHTTP, attempt < retryDelays.count else {
                    if let resumeFile {
                        if let resumeData { try? resumeData.write(to: resumeFile, options: .atomic) } else { try? FileManager.default.removeItem(at: resumeFile) }
                    }
                    throw error
                }
                PSLog.info("download retry \(attempt + 1) in \(Int(retryDelays[attempt])) s (\(isNetwork ? "network \(nsError.code)" : "http"))", category: .models)
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private static func transfer(_ url: URL, resumeData: Data?, handle: DownloadHandle?, allowsCellular: Bool,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress, handle: handle)
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = allowsCellular
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            handle?.finished()
            session.finishTasksAndInvalidate()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                delegate.task = task
                if let handle { handle.start(task) } else { task.resume() }
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        let handle: DownloadHandle?
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        private let lock = NSLock()
        /// Progress goes out on a 1 % change or every 250 ms, never per chunk.
        private var lastReported: Double = -1
        private var lastReportTime: TimeInterval = 0

        init(progress: @escaping @Sendable (Double) -> Void, handle: DownloadHandle?) {
            self.progress = progress
            self.handle = handle
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            let now = ProcessInfo.processInfo.systemUptime
            let shouldReport: Bool = lock.withLock {
                guard fraction - lastReported >= 0.01 || now - lastReportTime >= 0.25 else { return false }
                lastReported = fraction
                lastReportTime = now
                return true
            }
            if shouldReport { progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(DownloadHTTPError(status: http.statusCode)))
                return
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                // The end always goes out.
                progress(1)
                finish(.success(destination))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let nsError = error as NSError
            if let handle, handle.consumePause(of: task), nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                finish(.failure(DownloadPaused(resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)))
                return
            }
            finish(.failure(error))
        }
    }

    /// Unpacks a zip produced by `Scripts/package_models.sh` (stored or deflated entries),
    /// streaming each entry to disk.
    static func unzip(_ archive: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        try StoredZipReader.extract(data, to: directory)
        return directory
    }

    static func findResourcesFolder(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw PicshopError.modelUnavailable("empty archive")
        }
        for case let url as URL in enumerator where url.lastPathComponent == "Unet.mlmodelc" || url.lastPathComponent == "UnetChunk1.mlmodelc" {
            return url.deletingLastPathComponent()
        }
        throw PicshopError.modelUnavailable("no Stable Diffusion resources in archive")
    }

    static func findModelPackage(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw PicshopError.modelUnavailable("empty archive")
        }
        for case let url as URL in enumerator where url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
            return url
        }
        throw PicshopError.modelUnavailable("no .mlpackage in archive")
    }
}

/// Minimal Hugging Face Hub client: folder listing and file URLs.
enum HuggingFaceHub {
    struct Entry: Decodable {
        struct LFS: Decodable {
            /// The SHA-256 of the file's content.
            var oid: String
            var size: Int64?
        }

        var type: String
        var path: String
        var size: Int64?
        var lfs: LFS?
    }

    struct File: Sendable {
        var path: String
        var size: Int64
        /// LFS files only: the SHA-256 the content must have.
        var sha256: String?
    }

    /// Lists the files under a folder ("" for the repository root), recursively by default.
    static func listFiles(repository: String, path: String, revision: String, recursive: Bool = true) async throws -> [File] {
        let folder = path.isEmpty ? "" : "/" + path
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)\(folder)")!
        if recursive { components.queryItems = [URLQueryItem(name: "recursive", value: "true")] }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadHTTPError(status: http.statusCode)
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.filter { $0.type == "file" }.map { File(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.oid) }
    }

    static func fileURL(repository: String, path: String, revision: String) -> URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(escaped)")!
    }
}

/// Reads zip archives whose entries are stored (method 0) or deflated (method 8, via
/// Compression framework). Enough for model bundles we produce ourselves.
enum StoredZipReader {
    static func extract(_ data: Data, to directory: URL) throws {
        var offset = 0
        let count = data.count
        func u16(_ at: Int) -> Int { Int(data[at]) | (Int(data[at + 1]) << 8) }
        func u32(_ at: Int) -> Int { u16(at) | (u16(at + 2) << 16) }
        while offset + 30 <= count {
            guard u32(offset) == 0x04034b50 else { break }
            guard u16(offset + 6) & 0x8 == 0 else { throw PicshopError.modelUnavailable("streamed zip archives are not supported") }
            let method = u16(offset + 8)
            let compressedSize = u32(offset + 18)
            let uncompressedSize = u32(offset + 22)
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let nameStart = offset + 30
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + compressedSize <= count else { throw PicshopError.modelUnavailable("truncated archive") }
            let payload = data[dataStart..<(dataStart + compressedSize)]
            let target = directory.appendingPathComponent(name)
            guard target.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else { throw PicshopError.modelUnavailable("unsafe archive path") }
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch method {
                case 0:
                    try payload.write(to: target)
                case 8:
                    try Inflate.decompressToFile(payload, expectedSize: uncompressedSize, to: target)
                default:
                    throw PicshopError.modelUnavailable("unsupported zip method \(method)")
                }
            }
            offset = dataStart + compressedSize
        }
    }
}
#endif
