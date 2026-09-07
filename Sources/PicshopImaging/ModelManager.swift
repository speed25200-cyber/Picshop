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

    public init(id: String, displayName: String, summary: String, kind: Kind, sizeMB: Int, remoteURL: URL? = nil, huggingFaceID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.kind = kind
        self.sizeMB = sizeMB
        self.remoteURL = remoteURL
        self.huggingFaceID = huggingFaceID
    }
}

/// The models Picshop knows how to use. Core ML archives are served from
/// `PICSHOP_MODEL_BASE_URL` (Info.plist) — see docs/MODELS.md for producing
/// them with `Scripts/convert_models.py`.
public enum ModelCatalog {
    public static var baseURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "picshop.modelBaseURL"), let url = URL(string: override) { return url }
        if let value = Bundle.main.object(forInfoDictionaryKey: "PICSHOP_MODEL_BASE_URL") as? String, let url = URL(string: value) { return url }
        return nil
    }

    public static var all: [ModelDescriptor] {
        [
            ModelDescriptor(id: "lama-inpainting", displayName: "Neural Eraser (LaMa)", summary: "Large-mask inpainting network for cleaner object removal on complex backgrounds.",
                            kind: .inpainting, sizeMB: 205, remoteURL: baseURL?.appendingPathComponent("lama-inpainting.zip")),
            ModelDescriptor(id: "realesrgan-x4", displayName: "Super Resolution (Real-ESRGAN ×4)", summary: "Neural upscaler for sharper enlargements.",
                            kind: .superResolution, sizeMB: 67, remoteURL: baseURL?.appendingPathComponent("realesrgan-x4.zip")),
            ModelDescriptor(id: "sd-generative-fill", displayName: "Generative Fill (Stable Diffusion)", summary: "Text-guided replacement: “remplace le ciel par un coucher de soleil”, “add a hat”.",
                            kind: .generative, sizeMB: 1900, remoteURL: baseURL?.appendingPathComponent("sd-generative-fill.zip")),
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

    /// Compiled model URL if installed.
    public func compiledModelURL(for id: String) -> URL? {
        let directory = directory(for: id)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return contents.first { $0.pathExtension == "mlmodelc" }
    }

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

    /// Downloads and compiles a Core ML model archive.
    public func install(_ descriptor: ModelDescriptor) {
        guard activeTasks[descriptor.id] == nil, !isInstalled(descriptor.id) else { return }
        guard let remote = descriptor.remoteURL else {
            set(.failed("No download server configured. Set PICSHOP_MODEL_BASE_URL — see docs/MODELS.md."), for: descriptor.id)
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

    private func clearTask(_ id: String) {
        activeTasks[id] = nil
    }

    public func cancelInstall(_ id: String) {
        activeTasks[id]?.cancel()
    }
}

enum ModelDownloader {
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PicshopError.modelUnavailable("download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let expected = Double(http.expectedContentLength)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received = 0.0
        var lastReport = Date()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                received += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0, Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    progress(min(0.99, received / expected))
                }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1)
        return destination
    }

    /// Minimal zip extraction using Foundation's file coordination is not
    /// available on iOS, so archives are unpacked with `Process`-free logic:
    /// the server is expected to serve *uncompressed* zip (store) archives
    /// produced by `Scripts/package_models.sh`, which this reader supports.
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
                let contents: Data
                switch method {
                case 0: contents = Data(payload)
                case 8: contents = try Inflate.decompress(Data(payload), expectedSize: uncompressedSize)
                default: throw PicshopError.modelUnavailable("unsupported zip method \(method)")
                }
                try contents.write(to: target)
            }
            offset = dataStart + compressedSize
        }
    }
}
#endif
