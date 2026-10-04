// The KV prefix snapshot (W3, D22 steps 3 and 4): the cache that holds exactly the Live prompt's shared prefix (the
// system prompt, the tool specs and the few-shot examples), so a new conversation and every compaction start from a
// copy of it and prefill only what follows (the recap, the first message), instead of the whole 4,000-token prefix.
//
// - In RAM: one snapshot at a time (≤ 160 MB for the 4B, D15), deep copies of every layer plus the model state.
//   Dropped on a memory warning, when Live closes and when the weights go (`dropInMemory`); the disk file stays.
// - On disk (behind `persistedPrefix`): `Library/Caches/LivePrefix/<key.fileStem>.safetensors`, written once per key
//   per build with mlx-swift-lm's own `savePromptCache(url:cache:metadata:state:)` in the background, read back with
//   `loadPromptCacheSnapshot(url:)` and checked against the key and the re-tokenized prefix's length. At most 3 files
//   and 450 MB (LRU by modification date); a model's files go with the model (the `ModelManager` hook); other builds'
//   files go at most once a week. Caches only: never backed up.
// - Built only on the KV worker, inside the container's perform, so it never races a generation on the GPU.
//
// The decisions (key, metadata, retention, header parsing) are PicshopIntent's `LivePrefixKey` and
// `LivePrefixRetention`, Linux-tested; this file only does the MLX and file work.
#if canImport(MLXVLM)
import Foundation
import MLX
import MLXLMCommon
import PicshopCore
import PicshopIntent
import PicshopUI

/// A built prefix: its ids and the cache that holds exactly them. Never fed: every use starts from copies.
final class KVPrefixSnapshot: @unchecked Sendable {
    let key: LivePrefixKey
    let tokens: [Int]
    private let layers: [KVCache]
    private let state: LMOutput.State?
    /// The bytes the layers hold.
    let bytes: Int

    init(key: LivePrefixKey, tokens: [Int], layers: [KVCache], state: LMOutput.State?) {
        self.key = key
        self.tokens = tokens
        self.layers = layers
        self.state = state
        bytes = layers.reduce(0) { total, layer in total + layer.state.reduce(0) { $0 + $1.nbytes } }
    }

    /// A fresh, independent cache at the end of the prefix, with its model state.
    func restored() -> (cache: [KVCache], state: LMOutput.State?) {
        (layers.map { $0.copy() }, state)
    }

    /// For `savePromptCache`: the layers themselves, read only.
    fileprivate var persistable: (layers: [KVCache], state: LMOutput.State?) { (layers, state) }
}

final class MLXPrefixStore: @unchecked Sendable {
    static let shared = MLXPrefixStore()

    /// The pinned mlx-swift-lm revision (project.yml): a runtime change invalidates every snapshot.
    static let runtimeRevision = "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb"

    private let lock = NSLock()
    private var inMemory: KVPrefixSnapshot?
    /// The setup `warmLivePrefix` registered (`LocalModelLiveBrain.prefixSetup`): engines whose setup extends it
    /// (a compaction's recap) share its snapshot.
    private var canonical: LocalChatSetup?
    /// Stems this launch wrote or found on disk: written once per key per build.
    private var written: Set<String> = []
    private var writing: Set<String> = []

    private enum Keys {
        static let lastStaleSweep = "picshop.kv.prefix.lastStaleSweep"
    }

    // MARK: Paths

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("LivePrefix", isDirectory: true)
    }

    static func url(for key: LivePrefixKey) -> URL {
        directory.appendingPathComponent(key.fileStem + ".safetensors")
    }

    /// The app's build number, written into every file (the weekly sweep removes other builds').
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var persists: Bool { FeatureFlags.isOn(.persistedPrefix) }

    // MARK: The canonical prefix

    /// `warmLivePrefix`'s setup: the prefix every conversation of this editor shares.
    func register(_ setup: LocalChatSetup) {
        lock.withLock { canonical = setup }
    }

    /// The part of `setup` that is a shared prefix: the registered canonical setup when `setup` extends it (same
    /// system prompt, tools and picture budget, its history first), else `setup` itself.
    func prefixSetup(for setup: LocalChatSetup) -> (setup: LocalChatSetup, isCanonical: Bool) {
        let registered = lock.withLock { canonical }
        if let registered, registered.system == setup.system, registered.tools == setup.tools,
           registered.imageMaxPixels == setup.imageMaxPixels, setup.history.starts(with: registered.history) {
            return (registered, true)
        }
        return (setup, false)
    }

    /// The snapshot in RAM when it is this key's.
    func inMemorySnapshot(for key: LivePrefixKey) -> KVPrefixSnapshot? {
        lock.withLock { inMemory?.key == key ? inMemory : nil }
    }

    var inMemoryBytes: Int { lock.withLock { inMemory?.bytes ?? 0 } }

    // MARK: Building (on the KV worker)

    /// The snapshot for `key` whose ids are `tokens`: the RAM copy, else the disk file (with `persistedPrefix`), else
    /// a fresh prefill on `context.model.newCache(parameters:)`. A canonical snapshot (`persist`) is then written in
    /// the background. Synchronous: call it on the KV worker, inside the container's perform.
    func snapshot(for key: LivePrefixKey, tokens: [Int], context: ModelContext, persist: Bool) throws -> KVPrefixSnapshot {
        if let cached = inMemorySnapshot(for: key) { return cached }
        let url = Self.url(for: key)
        if Self.persists, let loaded = load(url: url, key: key, tokens: tokens) {
            keep(loaded)
            touch(url)
            lock.withLock { _ = written.insert(key.fileStem) }
            return loaded
        }
        let signpost = PSSignpost.begin("llm.prefixBuild", "\(tokens.count) tokens")
        defer { PSSignpost.end(signpost) }
        let started = Date()
        let parameters = GenerateParameters(maxTokens: 1, temperature: 0)
        let cache = try context.model.newCache(parameters: parameters)
        // Init prefills every id and samples one token without feeding it: the cache holds exactly `tokens`.
        let iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model, cache: cache, state: nil,
                                         parameters: parameters)
        let state = iterator.state
        eval(cache.flatMap { $0.state })
        Stream().synchronize()
        let snapshot = KVPrefixSnapshot(key: key, tokens: tokens, layers: cache, state: state)
        keep(snapshot)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        PSLog.info("live prefix built: \(tokens.count) tokens in \(milliseconds) ms, \(snapshot.bytes / 1_048_576) MB", category: .models)
        Diagnostics.shared.note("live prefix: \(tokens.count) tokens, \(milliseconds) ms, \(snapshot.bytes / 1_048_576) MB")
        if persist, Self.persists { write(snapshot, to: url) }
        return snapshot
    }

    private func keep(_ snapshot: KVPrefixSnapshot) {
        lock.withLock { inMemory = snapshot }
    }

    /// Memory warning, Live closed, weights unloaded: the RAM copy goes (the file stays).
    func dropInMemory(reason: String) {
        let dropped: Int = lock.withLock {
            let bytes = inMemory?.bytes ?? 0
            inMemory = nil
            return bytes
        }
        if dropped > 0 { PSLog.info("live prefix: dropped \(dropped / 1_048_576) MB from RAM (\(reason))", category: .models) }
    }

    // MARK: Disk

    private func load(url: URL, key: LivePrefixKey, tokens: [Int]) -> KVPrefixSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let loaded = try loadPromptCacheSnapshot(url: url)
            guard key.accepts(metadata: loaded.metadata, tokens: tokens.count), !loaded.cache.isEmpty, loaded.state != nil else {
                PSLog.info("live prefix: stale file \(url.lastPathComponent), rebuilding", category: .models)
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            PSLog.info("live prefix: loaded \(tokens.count) tokens from disk", category: .models)
            return KVPrefixSnapshot(key: key, tokens: tokens, layers: loaded.cache, state: loaded.state)
        } catch {
            PSLog.error("live prefix: unreadable file \(url.lastPathComponent): \(error)", category: .models)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Once per key per build, at utility priority, after the RAM snapshot exists. The layers are evaluated and
    /// never written again (every use copies them), so reading them off the worker is safe.
    private func write(_ snapshot: KVPrefixSnapshot, to url: URL) {
        let stem = snapshot.key.fileStem
        let go: Bool = lock.withLock {
            guard !written.contains(stem), !writing.contains(stem) else { return false }
            writing.insert(stem)
            return true
        }
        guard go else { return }
        let metadata = snapshot.key.metadata(tokens: snapshot.tokens.count, build: Self.build)
        Task.detached(priority: .utility) { [self] in
            let (layers, state) = snapshot.persistable
            let directory = Self.directory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let temporary = directory.appendingPathComponent(".\(stem).\(UUID().uuidString).safetensors")
                try savePromptCache(url: temporary, cache: layers, metadata: metadata, state: state)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: temporary, to: url)
                PSLog.info("live prefix: saved \(url.lastPathComponent)", category: .models)
                self.enforceRetention(keeping: stem)
            } catch {
                PSLog.error("live prefix: save failed: \(error)", category: .models)
            }
            self.lock.withLock {
                self.writing.remove(stem)
                self.written.insert(stem)
            }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// The files in `LivePrefix/`, with the metadata their headers carry.
    private func listFiles() -> [LivePrefixFile] {
        let directory = Self.directory
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return [] }
        return urls.filter { $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasPrefix(".") }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let metadata = Self.headerMetadata(url)
            return LivePrefixFile(stem: url.deletingPathExtension().lastPathComponent, bytes: values?.fileSize ?? 0,
                                  modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                  modelID: metadata?["picshop.model"], build: metadata?["picshop.build"])
        }
    }

    /// Reads only the safetensors header (a few kilobytes), never the tensors.
    private static func headerMetadata(_ url: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), let length = LivePrefixRetention.safetensorsHeaderLength(prefix),
              let header = try? handle.read(upToCount: length) else { return nil }
        return LivePrefixRetention.userMetadata(safetensorsPrefix: prefix + header)
    }

    private func remove(_ stems: [String], reason: String) {
        guard !stems.isEmpty else { return }
        for stem in stems {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(stem + ".safetensors"))
        }
        lock.withLock { written.subtract(stems) }
        PSLog.info("live prefix: removed \(stems.count) file(s) (\(reason))", category: .models)
    }

    private func enforceRetention(keeping stem: String?) {
        remove(LivePrefixRetention.evictions(listFiles(), keeping: stem), reason: "retention")
    }

    /// The model was deleted or updated: its prefix files and the RAM copy go.
    func purge(modelID: String) {
        if lock.withLock({ inMemory?.key.modelID == modelID }) { dropInMemory(reason: "model removed") }
        Task.detached(priority: .utility) { [self] in
            guard FileManager.default.fileExists(atPath: Self.directory.path) else { return }
            self.remove(LivePrefixRetention.purge(self.listFiles(), modelID: modelID), reason: "model \(modelID) removed")
        }
    }

    /// At launch, at most once a week: other builds' files go (their runtime or prompt may differ), and the
    /// temporaries a kill left behind.
    func sweepStaleBuilds() {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Keys.lastStaleSweep) as? Double
        let now = Date().timeIntervalSince1970
        if let last, now - last < LivePrefixRetention.staleSweepInterval { return }
        let build = Self.build
        Task.detached(priority: .background) { [self] in
            let directory = Self.directory
            if FileManager.default.fileExists(atPath: directory.path) {
                self.remove(LivePrefixRetention.staleBuildSweep(self.listFiles(), currentBuild: build, lastSweep: last, now: now), reason: "other builds")
                let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasPrefix(".") } ?? []
                for name in leftovers { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            }
            UserDefaults.standard.set(now, forKey: Keys.lastStaleSweep)
        }
    }

    /// Diagnostic Live: "1 fichier · 142 MB · RAM 138 MB".
    func summary() -> String {
        let files = listFiles()
        let disk = files.map(\.bytes).reduce(0, +)
        return "\(files.count) · \(disk / 1_048_576) MB · RAM \(inMemoryBytes / 1_048_576) MB"
    }
}
#endif
