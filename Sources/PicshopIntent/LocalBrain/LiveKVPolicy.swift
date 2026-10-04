import Foundation
import PicshopCore

// D22 and D23, the pure side of the KV engine: compaction limits per engine, the persisted prefix's key and its
// retention, the per-turn decision between appending, restoring and rebuilding, the picture payload a suffix
// carries, the stop-string filter and the self-test's verdict. Linux-tested by L5; the engine that runs them on the
// weights is App/LocalBrain (MLXKVEngine, MLXPrefixStore, KVSelfTest), which never decides anything these do not.

/// What the brain compacts at, how many pictures it keeps, and how big it looks (D23).
public struct LiveContextLimits: Sendable, Equatable {
    public var compactAt: Int
    public var maxImagesInContext: Int
    public var firstLookMaxPixel: Int
    public var verifyLookMaxPixel: Int

    public init(compactAt: Int, maxImagesInContext: Int, firstLookMaxPixel: Int, verifyLookMaxPixel: Int) {
        self.compactAt = compactAt
        self.maxImagesInContext = maxImagesInContext
        self.firstLookMaxPixel = firstLookMaxPixel
        self.verifyLookMaxPixel = verifyLookMaxPixel
    }
}

public enum LiveContextPolicy {
    /// W2's limits, kept for ChatSession on both models: a compaction there costs a full rebuild, and every picture
    /// turn rebuilds the cache anyway.
    public static let chatSession = LiveContextLimits(compactAt: 7_000, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768)

    /// D23's table:
    ///
    /// |                                   | compactAt | images | looks     |
    /// |-----------------------------------|-----------|--------|-----------|
    /// | 4B, kvEngine with media append    | 9,500     | 5      | 768 / 512 |
    /// | 4B, kvEngine, media not verified  | 9,500     | 2      | 768 / 768 |
    /// | 2B, kvEngine with media append    | 8,500     | 5      | 768 / 512 |
    /// | 2B, kvEngine, media not verified  | 8,500     | 2      | 768 / 768 |
    /// | either, ChatSession               | 7,000     | 2      | 768 / 768 |
    ///
    /// With the KV engine a compaction costs only the recap's prefill (the prefix snapshot is reused), so the
    /// conversation runs longer; KV at 9,500 tokens is about 300 MB for the 4B's attention layers (D15). With media
    /// append verified, pictures count by their token cost and the image cap is only a safety net; without it each
    /// picture turn re-prefills the tail with every picture in it, so two stay the cap. A verify look at 512 px
    /// costs fewer tokens than the first look. Any model other than the 4B gets the 2B's (smaller) row.
    public static func limits(for info: LocalModelInfo, engine: LocalEngineKind, mediaAppendVerified: Bool) -> LiveContextLimits {
        switch engine {
        case .chatSession:
            return chatSession
        case .kvEngine:
            let compactAt = info.id == LocalModelTiering.maxModelID ? 9_500 : 8_500
            return mediaAppendVerified
                ? LiveContextLimits(compactAt: compactAt, maxImagesInContext: 5, firstLookMaxPixel: 768, verifyLookMaxPixel: 512)
                : LiveContextLimits(compactAt: compactAt, maxImagesInContext: 2, firstLookMaxPixel: 768, verifyLookMaxPixel: 768)
        }
    }

    /// D23 suffix budgets in tokens (warm turn without and with new cards).
    public static let warmSuffixBudget = 250
    public static let warmSuffixBudgetWithCards = 450
}

// MARK: - The persisted prefix

/// What a persisted prefix snapshot was built from (D22 step 4): any change invalidates it.
public struct LivePrefixKey: Hashable, Codable, Sendable {
    public var modelID: String, revision: String, runtimeRevision: String
    public var mode: String, size: String, layout: String
    public var prefixHash: String, templateHash: String

    public init(modelID: String, revision: String, runtimeRevision: String, mode: String, size: String, layout: String,
                prefixHash: String, templateHash: String) {
        self.modelID = modelID
        self.revision = revision
        self.runtimeRevision = runtimeRevision
        self.mode = mode
        self.size = size
        self.layout = layout
        self.prefixHash = prefixHash
        self.templateHash = templateHash
    }

    /// StableHash.hex of every field joined with "|".
    public var fileStem: String {
        StableHash.hex([modelID, revision, runtimeRevision, mode, size, layout, prefixHash, templateHash].joined(separator: "|"))
    }

    /// `prefixHash`: StableHash.hex of the prefix token ids joined by ",".
    public static func prefixHash(tokens: [Int]) -> String {
        StableHash.hex(tokens.map(String.init).joined(separator: ","))
    }

    /// `templateHash`: StableHash.hex of the patched chat template's text.
    public static func templateHash(_ template: String) -> String {
        StableHash.hex(template)
    }

    /// The safetensors metadata a snapshot file is written with (`savePromptCache(url:cache:metadata:state:)`), the
    /// `picshop.*` keys of D22 step 4. `build` is the app build that wrote it (stale builds are swept weekly).
    public func metadata(tokens: Int, build: String) -> [String: String] {
        [
            "picshop.key": fileStem,
            "picshop.tokens": String(tokens),
            "picshop.model": modelID,
            "picshop.revision": revision,
            "picshop.mode": mode,
            "picshop.size": size,
            "picshop.layout": layout,
            "picshop.prefixHash": prefixHash,
            "picshop.templateHash": templateHash,
            "picshop.runtime": runtimeRevision,
            "picshop.build": build,
        ]
    }

    /// Whether a loaded file's metadata belongs to this key and holds exactly `tokens` prefix tokens (the count of
    /// the freshly re-tokenized prefix). Any other file is stale: it is deleted and the snapshot rebuilt.
    public func accepts(metadata: [String: String], tokens: Int) -> Bool {
        metadata["picshop.key"] == fileStem
            && metadata["picshop.tokens"] == String(tokens)
            && metadata["picshop.model"] == modelID
            && metadata["picshop.revision"] == revision
            && metadata["picshop.runtime"] == runtimeRevision
            && metadata["picshop.prefixHash"] == prefixHash
            && metadata["picshop.templateHash"] == templateHash
    }
}

/// One persisted prefix file, as the store lists `Library/Caches/LivePrefix/`.
public struct LivePrefixFile: Sendable, Equatable {
    public var stem: String
    public var bytes: Int
    /// Seconds since any fixed epoch (the file's modification date): least recently used goes first.
    public var modified: Double
    /// The model the file belongs to (`picshop.model`), nil when unreadable.
    public var modelID: String?
    /// The build that wrote it (`picshop.build`), nil when unreadable.
    public var build: String?

    public init(stem: String, bytes: Int, modified: Double, modelID: String? = nil, build: String? = nil) {
        self.stem = stem
        self.bytes = bytes
        self.modified = modified
        self.modelID = modelID
        self.build = build
    }
}

/// D22 step 4's retention: at most 3 files and 450 MB, LRU by modification date; the files of a removed model;
/// at most once a week, the files another build wrote.
public enum LivePrefixRetention {
    public static let maxFiles = 3
    public static let maxBytes = 450 * 1_048_576
    /// The stale-build sweep runs at most this often: a week.
    public static let staleSweepInterval: Double = 7 * 24 * 3_600

    /// The stems to delete so that what stays fits, oldest first. `keeping` (the file just written or in use) is
    /// never one, even when it alone is over the byte budget.
    public static func evictions(_ files: [LivePrefixFile], keeping: String? = nil) -> [String] {
        let byAge = files.sorted { lhs, rhs in
            lhs.modified != rhs.modified ? lhs.modified < rhs.modified : lhs.stem < rhs.stem
        }
        var count = files.count
        var bytes = files.map(\.bytes).reduce(0, +)
        var evicted: [String] = []
        for file in byAge where count > maxFiles || bytes > maxBytes {
            guard file.stem != keeping else { continue }
            evicted.append(file.stem)
            count -= 1
            bytes -= file.bytes
        }
        return evicted
    }

    /// The files of a model that was deleted or updated (`ModelManager.onModelRemoved`).
    public static func purge(_ files: [LivePrefixFile], modelID: String) -> [String] {
        files.filter { $0.modelID == modelID }.map(\.stem)
    }

    /// The weekly sweep: every file another build wrote (or whose metadata cannot be read), when the last sweep is
    /// a week old or never ran; nothing otherwise.
    public static func staleBuildSweep(_ files: [LivePrefixFile], currentBuild: String, lastSweep: Double?, now: Double) -> [String] {
        if let lastSweep, now - lastSweep < staleSweepInterval { return [] }
        return files.filter { $0.build != currentBuild }.map(\.stem)
    }

    /// A safetensors header is at most this long here (a prompt cache's is a few kilobytes); anything larger is
    /// not one of ours.
    public static let maxHeaderBytes = 4 * 1_048_576

    /// The JSON header's length from a safetensors file's first 8 bytes (little-endian), nil when implausible.
    public static func safetensorsHeaderLength(_ prefix: Data) -> Int? {
        guard prefix.count >= 8 else { return nil }
        var length: UInt64 = 0
        for (shift, byte) in prefix.prefix(8).enumerated() { length |= UInt64(byte) << (8 * UInt64(shift)) }
        guard length >= 2, length <= UInt64(maxHeaderBytes) else { return nil }
        return Int(length)
    }

    /// The user metadata `savePromptCache` wrote (`1.<key>` in the header's `__metadata__`), read from the file's
    /// first `8 + headerLength` bytes without loading a tensor: what the retention sweep needs (model, build).
    /// Nil when the bytes are not a safetensors header.
    public static func userMetadata(safetensorsPrefix data: Data) -> [String: String]? {
        guard let length = safetensorsHeaderLength(data), data.count >= 8 + length else { return nil }
        let header = data.subdata(in: data.startIndex + 8 ..< data.startIndex + 8 + length)
        guard let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return nil }
        let metadata = (object["__metadata__"] as? [String: Any]) ?? [:]
        var user: [String: String] = [:]
        for (key, value) in metadata where key.hasPrefix("1.") {
            if let text = value as? String { user[String(key.dropFirst(2))] = text }
        }
        return user
    }
}

// MARK: - The turn

/// D22 step 2.2: how a turn's prompt meets the cache.
public enum KVTurnDecision: Equatable, Sendable {
    /// The prompt starts with the ledger: prefill only `prompt[from...]` on the warm cache.
    case appendSuffix(from: Int)
    /// The prompt starts with the ledger up to the turn checkpoint only: restore the checkpoint, then prefill.
    case restoreTurn(thenAppendFrom: Int)
    /// The prompt starts with the prefix snapshot only: restore a copy of it, then prefill the rest.
    case restorePrefix(thenAppendFrom: Int)
    /// Nothing reusable: a fresh cache and the whole prompt.
    case rebuild

    /// Where prefill starts in the prompt (0 for a rebuild).
    public var appendFrom: Int {
        switch self {
        case .appendSuffix(let from), .restoreTurn(let from), .restorePrefix(let from): return from
        case .rebuild: return 0
        }
    }

    /// The signpost and stats path (D23): "picture" for a turn that feeds a new picture, else "warm", "restored",
    /// "prefix" or "cold".
    public func path(hasNewMedia: Bool) -> String {
        if hasNewMedia { return "picture" }
        switch self {
        case .appendSuffix: return "warm"
        case .restoreTurn: return "restored"
        case .restorePrefix: return "prefix"
        case .rebuild: return "cold"
        }
    }
}

public enum KVTurnPlanner {
    /// D22 step 3. `ledger` is every token id the cache holds, exactly: the prompt ids fed and every id `next()`
    /// returned, the stop token included (step 2.2). `prefixCount` leading ids of it are the prefix snapshot's;
    /// `turnCheckpoint` is the ledger count saved after the last turn's suffix prefill (nil when there is none).
    ///
    /// In order:
    /// 1. The prompt starts with the whole ledger and adds at least one id → `.appendSuffix(from: ledger.count)`,
    ///    unless the turn brings a new picture and media append is not verified.
    /// 2. It starts with the ledger up to the checkpoint (the last assistant message re-rendered differently from
    ///    the generated ids, a cut generation) → `.restoreTurn(thenAppendFrom: checkpoint)`, under the same picture
    ///    condition.
    /// 3. It starts with the prefix → `.restorePrefix(thenAppendFrom: prefixCount)`: the whole tail is prefilled
    ///    from the prefix, which never holds a picture.
    /// 4. Otherwise (a prompt-layout or template change, an empty ledger) → `.rebuild`.
    /// A prompt that equals what would be restored has nothing to feed (the next token needs logits), so every
    /// branch needs at least one id after its start.
    public static func decide(ledger: [Int], prompt: [Int], prefixCount: Int, turnCheckpoint: Int?,
                              hasNewMedia: Bool, mediaAppendVerified: Bool) -> KVTurnDecision {
        guard !ledger.isEmpty, !prompt.isEmpty else { return .rebuild }
        let prefix = (0...ledger.count).contains(prefixCount) ? prefixCount : 0
        let shared = commonPrefixCount(ledger, prompt)
        let continues = !hasNewMedia || mediaAppendVerified

        if continues, shared == ledger.count, prompt.count > ledger.count {
            return .appendSuffix(from: ledger.count)
        }
        if continues, let checkpoint = turnCheckpoint, checkpoint > prefix, checkpoint <= ledger.count,
           shared >= checkpoint, prompt.count > checkpoint {
            return .restoreTurn(thenAppendFrom: checkpoint)
        }
        if prefix > 0, shared >= prefix, prompt.count > prefix {
            return .restorePrefix(thenAppendFrom: prefix)
        }
        return .rebuild
    }

    /// How many leading ids two sequences share.
    public static func commonPrefixCount(_ a: [Int], _ b: [Int]) -> Int {
        let limit = min(a.count, b.count)
        var index = 0
        while index < limit, a[index] == b[index] { index += 1 }
        return index
    }

    /// D22 step 3: the prefix snapshot's ids. `rendered` is `[.system] + setup.history` through the processor (it
    /// ends with the generation prompt, `<|im_start|>assistant\n<think>\n\n</think>\n\n`), `generationPrompt` those
    /// ids. A render that does not end with them gets no snapshot (nil), and neither does an empty prefix.
    public static func prefixTokens(rendered: [Int], generationPrompt: [Int]) -> [Int]? {
        guard !generationPrompt.isEmpty, rendered.count > generationPrompt.count,
              Array(rendered.suffix(generationPrompt.count)) == generationPrompt else { return nil }
        return Array(rendered.dropLast(generationPrompt.count))
    }
}

// MARK: - Pictures in a suffix

/// D22 step 2.3: which pictures a suffix carries. The processor's payload is every picture's patch rows in prompt
/// order, and each picture writes a run of `<|image_pad|>` ids (one per merged patch); a suffix that starts at
/// `from` carries the pictures whose runs lie after it. This is `QwenVL.splitPreparedInput`'s bookkeeping (it is
/// only adopted by Qwen2.5-VL upstream), kept pure here; the engine slices the arrays.
public enum KVMediaSlice {
    public struct Plan: Equatable, Sendable {
        /// The index of the first picture the suffix carries; `pictureCount` when it carries none.
        public var firstPicture: Int
        /// Patch rows to drop from the front of the payload.
        public var droppedRows: Int
        public var pictureCount: Int

        public var carriesPictures: Bool { firstPicture < pictureCount }
    }

    /// The runs of `padToken` in `tokens`, one per picture, in order.
    public static func pictureRuns(in tokens: [Int], padToken: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, token) in tokens.enumerated() {
            if token == padToken {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        if let open = start { runs.append(open..<tokens.count) }
        return runs
    }

    /// The slice for a suffix from `from`. `rowsPerPicture[i]` is picture i's patch rows (`frames[i].product`);
    /// `mergeLength` (2 × 2 for Qwen) divides it into its pad ids. Nil when the payload does not describe the
    /// prompt's runs exactly, or when `from` falls inside a run: the caller then prefills from an earlier point.
    public static func plan(tokens: [Int], padToken: Int, rowsPerPicture: [Int], mergeLength: Int, from: Int) -> Plan? {
        guard mergeLength > 0, from >= 0, from <= tokens.count else { return nil }
        let runs = pictureRuns(in: tokens, padToken: padToken)
        guard runs.count == rowsPerPicture.count else { return nil }
        for (run, rows) in zip(runs, rowsPerPicture) {
            guard rows > 0, rows % mergeLength == 0, rows / mergeLength == run.count else { return nil }
        }
        var first = 0
        var dropped = 0
        for (index, run) in runs.enumerated() {
            if run.upperBound <= from {
                first = index + 1
                dropped += rowsPerPicture[index]
            } else if run.lowerBound < from {
                return nil
            } else {
                break
            }
        }
        return Plan(firstPicture: first, droppedRows: dropped, pictureCount: runs.count)
    }
}

// MARK: - Stop strings

/// The streamed-text stop-string filter of D22 step 2.5. mlx-swift-lm's own (`StopStringFilter`) is package-internal
/// at the pinned revision, so the KV engine uses this one over `configuration.effectiveStopStrings`: it holds back
/// only a tail that could still become a stop string, and at a stop emits what came before it.
public struct KVStopStringFilter: Sendable, Equatable {
    public let stopStrings: [String]
    private var buffer = ""
    public private(set) var stopped = false

    public init(stopStrings: Set<String>) {
        self.stopStrings = stopStrings.filter { !$0.isEmpty }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// The text safe to emit now, and whether a stop string was reached (nothing passes after it).
    public mutating func process(_ chunk: String) -> (text: String?, stopped: Bool) {
        guard !stopped else { return (nil, true) }
        guard !stopStrings.isEmpty else { return (chunk.isEmpty ? nil : chunk, false) }
        buffer += chunk
        if let range = earliestStop(in: buffer) {
            let text = String(buffer[..<range.lowerBound])
            buffer = ""
            stopped = true
            return (text.isEmpty ? nil : text, true)
        }
        let held = heldSuffixLength(buffer)
        let end = buffer.index(buffer.endIndex, offsetBy: -held)
        let text = String(buffer[..<end])
        buffer = String(buffer[end...])
        return (text.isEmpty ? nil : text, false)
    }

    /// The held tail at the end of the generation (it never became a stop string).
    public mutating func finish() -> String? {
        guard !stopped, !buffer.isEmpty else { return nil }
        defer { buffer = "" }
        return buffer
    }

    private func earliestStop(in text: String) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for stop in stopStrings {
            guard let range = text.range(of: stop) else { continue }
            if let current = earliest, current.lowerBound <= range.lowerBound { continue }
            earliest = range
        }
        return earliest
    }

    private func heldSuffixLength(_ text: String) -> Int {
        var longest = 0
        for stop in stopStrings {
            let maxLength = min(text.count, stop.count - 1)
            guard maxLength > longest else { continue }
            for length in stride(from: maxLength, through: longest + 1, by: -1) where text.suffix(length) == stop.prefix(length) {
                longest = length
                break
            }
        }
        return longest
    }
}

// MARK: - The self-test

/// One turn's output as the self-test compares it (D22 step 5).
public struct KVSelfTestTurn: Sendable, Equatable {
    public var tokenIDs: [Int]
    /// The calls the turn made: name and arguments as sorted-key JSON.
    public var calls: [String]

    public init(tokenIDs: [Int], calls: [String]) {
        self.tokenIDs = tokenIDs
        self.calls = calls
    }
}

/// The verdict of KVSelfTest: the KV engine warm (its restore or suffix path) against the same engine cold (a fresh
/// cache and the whole prompt).
public enum KVSelfTestVerdict {
    /// Text turns must agree on this many leading ids (greedy decoding; 4-bit maths may drift later).
    public static let comparedTextTokens = 8

    /// A tool turn: the same calls, names and argument JSON, in order. A text turn: the same first
    /// `comparedTextTokens` ids (fewer when both stopped earlier at the same place).
    public static func agrees(warm: KVSelfTestTurn, cold: KVSelfTestTurn) -> Bool {
        if !warm.calls.isEmpty || !cold.calls.isEmpty { return warm.calls == cold.calls }
        let count = min(comparedTextTokens, max(warm.tokenIDs.count, cold.tokenIDs.count))
        guard count > 0 else { return false }
        return Array(warm.tokenIDs.prefix(count)) == Array(cold.tokenIDs.prefix(count))
    }

    /// The UserDefaults key of a verdict: `picshop.kv.verified.<model>.<revision>.<runtime>.<build>` (and `.media`
    /// for the picture bit).
    public static func defaultsKey(modelID: String, revision: String, runtimeRevision: String, build: String, media: Bool = false) -> String {
        "picshop.kv.verified.\(modelID).\(revision).\(runtimeRevision).\(build)" + (media ? ".media" : "")
    }
}
