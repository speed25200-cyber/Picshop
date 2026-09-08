#if canImport(CoreML)
import Foundation
import CoreML
import PicshopCore

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
                huggingFaceFolder: HuggingFaceFolder? = nil, isBundledByDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.huggingFaceFolder = huggingFaceFolder
        self.isBundledByDefault = isBundledByDefault
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
            ModelDescriptor(id: "qwen3-4b-4bit", displayName: "Pro Brain (Qwen3 4B)", summary: "Larger on-device language model for complex, multi-step voice commands.",
                            kind: .languageModel, sizeMB: 2500, huggingFaceID: "mlx-community/Qwen3-4B-4bit"),
        ]
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

    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.rootURL = rootURL ?? support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
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
    public func install(_ descriptor: ModelDescriptor) {
        guard activeTasks[descriptor.id] == nil, !isInstalled(descriptor.id) else { return }
        if descriptor.remoteURL == nil, let folder = descriptor.huggingFaceFolder {
            installHuggingFaceFolder(descriptor, folder: folder)
            return
        }
        guard let remote = descriptor.remoteURL else {
            set(.failed(descriptor.isBundledByDefault ? "This build was made without the model. Update the app." : "No download source for this model."), for: descriptor.id)
            return
        }
        set(.downloading(progress: 0), for: descriptor.id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await ModelDownloader.download(remote) { progress in
                    Task { await self.set(.downloading(progress: progress), for: descriptor.id) }
                }
                try Task.checkCancellation()
                await self.set(.compiling, for: descriptor.id)
                let directory = await self.directory(for: descriptor.id)
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let unpacked = try ModelDownloader.unzip(archive, into: directory.appendingPathComponent("unpacked", isDirectory: true))
                if descriptor.kind == .generative {
                    // Keep the compiled resources folder as-is (Unet.mlmodelc, TextEncoder.mlmodelc, …).
                    let resources = try ModelDownloader.findResourcesFolder(in: unpacked)
                    let destination = directory.appendingPathComponent("resources", isDirectory: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: resources, to: destination)
                    try? FileManager.default.removeItem(at: unpacked)
                    try? FileManager.default.removeItem(at: archive)
                    await self.set(.installed, for: descriptor.id)
                    await self.clearTask(descriptor.id)
                    return
                }
                let package = try ModelDownloader.findModelPackage(in: unpacked)
                let compiled = try await MLModel.compileModel(at: package)
                let destination = directory.appendingPathComponent("\(descriptor.id).mlmodelc")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: compiled, to: destination)
                try? FileManager.default.removeItem(at: unpacked)
                try? FileManager.default.removeItem(at: archive)
                await self.set(.installed, for: descriptor.id)
            } catch is CancellationError {
                await self.set(.notInstalled, for: descriptor.id)
            } catch {
                PSLog.error("model install failed: \(error)", category: .models)
                await self.set(.failed(error.localizedDescription), for: descriptor.id)
            }
            await self.clearTask(descriptor.id)
        }
        activeTasks[descriptor.id] = task
    }

    /// Downloads every file of a Hugging Face folder (compiled Stable Diffusion resources)
    /// into `<id>/resources`, with byte-accurate progress.
    private func installHuggingFaceFolder(_ descriptor: ModelDescriptor, folder: ModelDescriptor.HuggingFaceFolder) {
        set(.downloading(progress: 0), for: descriptor.id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await HuggingFaceHub.listFiles(repository: folder.repository, path: folder.path, revision: folder.revision)
                guard !entries.isEmpty else { throw PicshopError.modelUnavailable("empty folder on Hugging Face") }
                let total = max(1, entries.reduce(0) { $0 + $1.size })
                var done: Int64 = 0
                let directory = await self.directory(for: descriptor.id)
                let staging = directory.appendingPathComponent("staging", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                for entry in entries {
                    try Task.checkCancellation()
                    let relative = String(entry.path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let destination = staging.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let url = HuggingFaceHub.fileURL(repository: folder.repository, path: entry.path, revision: folder.revision)
                    let base = done
                    let temporary = try await ModelDownloader.download(url) { fraction in
                        let bytes = base + Int64(fraction * Double(entry.size))
                        Task { await self.set(.downloading(progress: Double(bytes) / Double(total)), for: descriptor.id) }
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    done += entry.size
                }
                await self.set(.compiling, for: descriptor.id)
                let resources = directory.appendingPathComponent("resources", isDirectory: true)
                try? FileManager.default.removeItem(at: resources)
                try FileManager.default.moveItem(at: staging, to: resources)
                guard await self.resourcesURL(for: descriptor.id) != nil else {
                    throw PicshopError.modelUnavailable("Unet.mlmodelc missing after download")
                }
                await self.set(.installed, for: descriptor.id)
            } catch is CancellationError {
                await self.set(.notInstalled, for: descriptor.id)
            } catch {
                PSLog.error("model install failed: \(error)", category: .models)
                await self.set(.failed(error.localizedDescription), for: descriptor.id)
            }
            await self.clearTask(descriptor.id)
        }
        activeTasks[descriptor.id] = task
    }

    private func clearTask(_ id: String) {
        activeTasks[id] = nil
    }

    public func cancelInstall(_ id: String) {
        activeTasks[id]?.cancel()
    }
}

enum ModelDownloader {
    /// Downloads to a temporary file with progress, using a download task so large
    /// archives never pass through memory.
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        private let lock = NSLock()

        init(progress: @escaping @Sendable (Double) -> Void) {
            self.progress = progress
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
            progress(min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(PicshopError.modelUnavailable("download failed (\(http.statusCode))")))
                return
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                progress(1)
                finish(.success(destination))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
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
        var type: String
        var path: String
        var size: Int64?
    }

    struct File: Sendable {
        var path: String
        var size: Int64
    }

    /// Lists every file under a folder (recursively).
    static func listFiles(repository: String, path: String, revision: String) async throws -> [File] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)/\(path)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PicshopError.modelUnavailable("Hugging Face listing failed (\(http.statusCode))")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.filter { $0.type == "file" }.map { File(path: $0.path, size: $0.size ?? 0) }
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
