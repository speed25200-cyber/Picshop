import Foundation

// The model broker's policy (W2, D12): pure, Linux-tested. The coordinator that applies it is an actor in
// PicshopUI (LocalBrainHub+Broker) adopting Imaging's ModelResidencyCoordinator; SAM, Depth, LaMa, the
// upscaler and Stable Diffusion ask it before they load, and the LLM registers as a resident.
//
// Memory classes, as this codebase has them (D12):
// - 6 GB class (physical memory < 7.0 GB): LocalModelTiering never loads an LLM there, so an `.llm` request is
//   refused; Stable Diffusion runs alone; Depth is load, infer, unload; SAM may stay resident.
// - 8 GB class and above: the per-app ceiling is about 6 GB and the 4B peaks near 3.9 GB, so the LLM plus SAM must
//   keep the 700 MB floor; Depth stays transient while an LLM is resident; SD and the LLM never co-reside.
// Eviction goes lowest priority first, then least recently used; a busy resident is never evicted, so the LLM
// (busy for the length of a Live turn) only goes between turns.

/// A model that takes memory while it is loaded.
public enum ModelClient: String, Codable, Sendable, CaseIterable { case llm, stableDiffusion, sam, depth, lama, upscaler }

/// How much a load matters now: eviction goes lowest priority first.
public enum ModelPriority: Int, Codable, Sendable, Comparable {
    case background, preload, interactive, userWaiting

    // Raw-value enums get no synthesized Comparable (see OpPhase).
    public static func < (lhs: ModelPriority, rhs: ModelPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A loaded model as the broker sees it.
public struct ModelResident: Sendable, Equatable {
    public var client: ModelClient
    public var bytes: Int
    public var priority: ModelPriority
    /// Mid-inference (or, for the LLM, mid-turn): never evicted.
    public var isBusy: Bool
    /// Seconds on any monotonic clock: least recently used goes first among equal priorities.
    public var lastUse: Double

    public init(client: ModelClient, bytes: Int, priority: ModelPriority, isBusy: Bool = false, lastUse: Double = 0) {
        self.client = client
        self.bytes = bytes
        self.priority = priority
        self.isBusy = isBusy
        self.lastUse = lastUse
    }
}

public enum ModelBrokerDecision: Sendable, Equatable {
    case admit(evicting: [ModelClient])
    case refuse(reason: String)

    public var isAdmitted: Bool {
        if case .admit = self { return true }
        return false
    }

    /// The residents to unload before the load (empty for a refusal).
    public var evicting: [ModelClient] {
        if case .admit(let evicting) = self { return evicting }
        return []
    }
}

public enum ModelBrokerPolicy {
    /// `os_proc_available_memory` must stay at or above this after a load: 700 MiB.
    public static let freeFloorBytes: Int = 700 * 1_048_576
    /// Physical bytes below which a device is the 6 GB class: never an LLM there (D12).
    public static let sixGBClassLimit: UInt64 = 7_000_000_000
    /// An export from this many megapixels also releases the LLM (D12).
    public static let exportLargeMegapixels: Double = 24
    /// An export with less free memory than this also releases the LLM: 1.5 GB, MemoryGuard's app reserve.
    public static let exportLowMemoryBytes: Int = 1_500_000_000

    private static let mebibyte = 1_048_576

    /// sam 260 MB, depth 170 MB, lama 380 MB, upscaler 140 MB, stableDiffusion 2,300 MB; `.llm` returns `llmBytes`
    /// (the caller passes LocalModelEntry.memoryNeededToLoad, which Core cannot see).
    public static func estimatedBytes(_ client: ModelClient, llmBytes: Int = 0) -> Int {
        switch client {
        case .llm: return llmBytes
        case .sam: return 260 * mebibyte
        case .depth: return 170 * mebibyte
        case .lama: return 380 * mebibyte
        case .upscaler: return 140 * mebibyte
        case .stableDiffusion: return 2_300 * mebibyte
        }
    }

    /// The 6 GB class: below 7.0 GB of physical memory (an iPhone 15, an iPhone 14 Pro).
    public static func isSixGBClass(_ physicalMemory: UInt64) -> Bool {
        physicalMemory < sixGBClassLimit
    }

    /// The residents that cannot stay loaded next to `client`, whatever the free memory says:
    /// Stable Diffusion and the LLM never co-reside, and on the 6 GB class SD runs alone.
    public static func conflicts(of client: ModelClient, among residents: [ModelResident], physicalMemory: UInt64) -> [ModelClient] {
        let sixGB = isSixGBClass(physicalMemory)
        var found: [ModelClient] = []
        for resident in residents where resident.client != client && !found.contains(resident.client) {
            switch (client, resident.client) {
            case (.stableDiffusion, .llm), (.llm, .stableDiffusion):
                found.append(resident.client)
            case (.stableDiffusion, _), (_, .stableDiffusion):
                if sixGB { found.append(resident.client) }
            default:
                break
            }
        }
        return found
    }

    /// Whether `client` may stay loaded once its work is done. Depth is transient (load, infer, unload) on the
    /// 6 GB class and, elsewhere, while an LLM is resident; everything else may stay until it is evicted.
    public static func keepsResident(_ client: ModelClient, residents: [ModelResident], physicalMemory: UInt64) -> Bool {
        guard client == .depth else { return true }
        if isSixGBClass(physicalMemory) { return false }
        return !residents.contains { $0.client == .llm }
    }

    /// Admit (evicting some residents) or refuse a load of `bytes` for `client`.
    ///
    /// - The 6 GB class refuses an `.llm` request outright.
    /// - Conflicting residents (`conflicts(of:among:physicalMemory:)`) are evicted first, whatever their priority;
    ///   a busy one refuses the request.
    /// - Unknown `availableBytes` (macOS, tests) then admits.
    /// - Otherwise the load is admitted when `availableBytes − bytes ≥ freeFloorBytes` after those evictions; if
    ///   not, non-busy residents with a lower priority than the request go, lowest priority first, then least
    ///   recently used, until the floor holds. When it cannot hold, the request is refused and nothing is evicted.
    /// - A client already resident only needs the bytes it adds, and is never its own eviction.
    public static func decide(_ client: ModelClient, bytes: Int, priority: ModelPriority, residents: [ModelResident],
                              availableBytes: Int?, physicalMemory: UInt64) -> ModelBrokerDecision {
        if client == .llm, isSixGBClass(physicalMemory) {
            return .refuse(reason: "no local language model on a 6 GB device")
        }
        let others = residents.filter { $0.client != client }
        let alreadyLoaded = residents.filter { $0.client == client }.map(\.bytes).max() ?? 0
        let needed = max(0, bytes - alreadyLoaded)

        var evicting: [ModelClient] = []
        var freed = 0
        for conflict in conflicts(of: client, among: others, physicalMemory: physicalMemory) {
            let held = others.filter { $0.client == conflict }
            if held.contains(where: \.isBusy) {
                return .refuse(reason: "\(conflict.rawValue) is busy and cannot share memory with \(client.rawValue)")
            }
            evicting.append(conflict)
            freed += held.map(\.bytes).reduce(0, +)
        }

        guard let availableBytes else { return .admit(evicting: evicting) }
        func floorHolds() -> Bool { availableBytes + freed - needed >= freeFloorBytes }
        if floorHolds() { return .admit(evicting: evicting) }

        let candidates = others
            .filter { !$0.isBusy && $0.priority < priority && !evicting.contains($0.client) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.lastUse < rhs.lastUse
            }
        for candidate in candidates {
            if !evicting.contains(candidate.client) { evicting.append(candidate.client) }
            freed += candidate.bytes
            if floorHolds() { return .admit(evicting: evicting) }
        }
        let short = needed + freeFloorBytes - availableBytes - freed
        return .refuse(reason: "\(client.rawValue) needs \(max(1, short / mebibyte)) MB more than the evictable models free")
    }

    /// The residents to unload, in order, for a client that loads without asking (the LLM, D12) or for a memory
    /// warning and the background: idle ones other than `client`, lowest priority first, then least recently used.
    /// The LLM is never one (LocalBrainHub releases it itself) and a busy model is never one. No floor here: the
    /// caller re-reads free memory after each unload and stops once it has what it needs.
    public static func roomOrder(for client: ModelClient, residents: [ModelResident]) -> [ModelClient] {
        let idle = residents
            .filter { $0.client != client && $0.client != .llm && !$0.isBusy }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.lastUse < rhs.lastUse
            }
        var order: [ModelClient] = []
        for resident in idle where !order.contains(resident.client) && !residents.contains(where: { $0.client == resident.client && $0.isBusy }) {
            order.append(resident.client)
        }
        return order
    }

    /// What to release before a full-resolution export: SAM and Depth always, the LLM too from 24 MP or under
    /// 1.5 GB free. Only residents that are loaded and idle are listed (a busy one is never evicted).
    public static func exportReleases(residents: [ModelResident], megapixels: Double, availableBytes: Int?) -> [ModelClient] {
        let releasesLLM = megapixels >= exportLargeMegapixels || (availableBytes.map { $0 < exportLowMemoryBytes } ?? false)
        let wanted: [ModelClient] = releasesLLM ? [.sam, .depth, .llm] : [.sam, .depth]
        return wanted.filter { client in
            let held = residents.filter { $0.client == client }
            return !held.isEmpty && !held.contains(where: \.isBusy)
        }
    }
}

/// The broker's bookkeeping (W2, D12), pure so that Linux tests it: who is loaded, how big, how busy, when last
/// used, and which admissions have not loaded yet. The coordinator actor (LocalBrainHub+Broker) owns one, adds the
/// unload closures and the measurements, and carries out the evictions this ledger decides.
public struct ModelBrokerLedger: Sendable, Equatable {
    /// An admission whose model has not reported `noteLoaded` yet: its bytes are not in the free-memory figure
    /// yet, so a second admission in the meantime must count them.
    public struct Pending: Sendable, Equatable {
        public var bytes: Int
        public var priority: ModelPriority
        public var since: Double
    }

    /// A pending admission older than this no longer counts (the load failed or was abandoned), in seconds.
    public static let pendingLifetime: Double = 30

    /// Loaded models, in load order.
    public private(set) var residents: [ModelResident] = []
    public private(set) var pending: [ModelClient: Pending] = [:]
    private var busyCounts: [ModelClient: Int] = [:]

    public init() {}

    public func resident(_ client: ModelClient) -> ModelResident? { residents.first { $0.client == client } }
    public func isResident(_ client: ModelClient) -> Bool { resident(client) != nil }
    public var residentBytes: Int { residents.map(\.bytes).reduce(0, +) }

    /// Decides a load and, when it is admitted, removes the evicted residents and records the admission as
    /// pending. The caller unloads the evicted clients.
    public mutating func request(_ client: ModelClient, bytes: Int, priority: ModelPriority, availableBytes: Int?,
                                 physicalMemory: UInt64, now: Double) -> ModelBrokerDecision {
        expirePending(now: now)
        let reserved = pending.filter { $0.key != client }.values.map(\.bytes).reduce(0, +)
        let available = availableBytes.map { $0 - reserved }
        let decision = ModelBrokerPolicy.decide(client, bytes: bytes, priority: priority, residents: residents,
                                                availableBytes: available, physicalMemory: physicalMemory)
        guard case .admit(let evicting) = decision else { return decision }
        for evicted in evicting { remove(evicted) }
        if let index = residents.firstIndex(where: { $0.client == client }) {
            // Already loaded: the request only refreshes it.
            residents[index].lastUse = now
            residents[index].priority = max(residents[index].priority, Self.keptPriority(priority))
        } else {
            pending[client] = Pending(bytes: bytes, priority: priority, since: now)
        }
        return decision
    }

    /// A model finished loading. It keeps the priority it was admitted with, capped at `.interactive` (a
    /// user-waiting load must not pin itself above the next user-waiting request); the LLM, which loads without
    /// asking, is `.interactive`.
    public mutating func noteLoaded(_ client: ModelClient, bytes: Int, now: Double) {
        let admitted = pending.removeValue(forKey: client)?.priority ?? .interactive
        let resident = ModelResident(client: client, bytes: bytes, priority: Self.keptPriority(admitted),
                                     isBusy: (busyCounts[client] ?? 0) > 0, lastUse: now)
        if let index = residents.firstIndex(where: { $0.client == client }) {
            residents[index] = resident
        } else {
            residents.append(resident)
        }
    }

    public mutating func noteUnloaded(_ client: ModelClient) {
        remove(client)
    }

    /// Busy marks nest: SAM's deferred "not busy" may land after its next "busy", so the ledger counts them.
    /// Returns whether the client is busy now.
    @discardableResult
    public mutating func markBusy(_ client: ModelClient, _ busy: Bool, now: Double) -> Bool {
        let count = max(0, (busyCounts[client] ?? 0) + (busy ? 1 : -1))
        busyCounts[client] = count == 0 ? nil : count
        if let index = residents.firstIndex(where: { $0.client == client }) {
            residents[index].isBusy = count > 0
            residents[index].lastUse = now
        }
        return count > 0
    }

    /// The residents to release before an export, removed from the ledger.
    public mutating func releaseForExport(megapixels: Double, availableBytes: Int?) -> [ModelClient] {
        let released = ModelBrokerPolicy.exportReleases(residents: residents, megapixels: megapixels, availableBytes: availableBytes)
        for client in released { remove(client) }
        return released
    }

    /// Whether an idle `client` should be unloaded now (Depth, D12).
    public func shouldUnloadWhenIdle(_ client: ModelClient, physicalMemory: UInt64) -> Bool {
        guard let resident = resident(client), !resident.isBusy else { return false }
        return !ModelBrokerPolicy.keepsResident(client, residents: residents, physicalMemory: physicalMemory)
    }

    private mutating func remove(_ client: ModelClient) {
        residents.removeAll { $0.client == client }
        pending.removeValue(forKey: client)
        busyCounts.removeValue(forKey: client)
    }

    private mutating func expirePending(now: Double) {
        pending = pending.filter { now - $0.value.since < Self.pendingLifetime }
    }

    private static func keptPriority(_ priority: ModelPriority) -> ModelPriority { min(priority, .interactive) }
}
