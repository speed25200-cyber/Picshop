#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The model broker (W2, D12): one actor that decides which on-device models may load, and unloads others to make
/// room. SAM, Depth, LaMa, the upscaler and Stable Diffusion ask it through `ModelResidency.admit` before they load
/// and report `noteLoaded`/`noteUnloaded`; the local LLM registers when LocalBrainHub loads it, and is busy for the
/// length of a Live turn or a push-to-talk plan, so it only goes between turns.
///
/// The policy is Core's `ModelBrokerPolicy` (pure, Linux-tested) through a `ModelBrokerLedger`; this actor adds
/// the live memory figure (`os_proc_available_memory`), the unload closures, the log and a `memory.sample`
/// signpost event per decision. Installed at launch behind `FeatureFlag.modelBroker`; without it every admit is
/// true (W1 behaviour).
actor ModelBroker: ModelResidencyCoordinator {
    private var ledger = ModelBrokerLedger()
    private var unloads: [ModelClient: @Sendable () async -> Void] = [:]
    private let physicalMemory: UInt64
    private let availableBytes: @Sendable () -> Int?
    private let clock: @Sendable () -> Double

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
         availableBytes: @escaping @Sendable () -> Int? = { MemoryBudget.availableBytes },
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.physicalMemory = physicalMemory
        self.availableBytes = availableBytes
        self.clock = clock
    }

    /// At launch (AppEnvironment.init): the broker when its flag is on, else none (every admit true).
    @MainActor
    static func installAtLaunch() {
        guard FeatureFlags.isOn(.modelBroker) else {
            ModelResidency.install(nil)
            return
        }
        ModelResidency.install(ModelBroker())
        PSLog.info("model broker on (\(ProcessInfo.processInfo.physicalMemory / 1_000_000_000) GB, floor \(ModelBrokerPolicy.freeFloorBytes / 1_048_576) MB)", category: .models)
    }

    // MARK: ModelResidencyCoordinator

    func admit(_ client: ModelClient, bytes: Int, priority: ModelPriority) async -> Bool {
        let available = availableBytes()
        let decision = ledger.request(client, bytes: bytes, priority: priority, availableBytes: available,
                                      physicalMemory: physicalMemory, now: clock())
        sample("\(client.rawValue) \(priority) \(bytes / 1_048_576) MB → \(Self.describe(decision))")
        switch decision {
        case .refuse(let reason):
            PSLog.info("model broker: refused \(client.rawValue): \(reason)", category: .models)
            return false
        case .admit(let evicting):
            for evicted in evicting {
                PSLog.info("model broker: unloading \(evicted.rawValue) for \(client.rawValue)", category: .models)
                await unload(evicted, reason: "broker:\(client.rawValue)")
            }
            return true
        }
    }

    func noteLoaded(_ client: ModelClient, bytes: Int, unload: @escaping @Sendable () async -> Void) async {
        ledger.noteLoaded(client, bytes: bytes, now: clock())
        unloads[client] = unload
        sample("\(client.rawValue) loaded (\(bytes / 1_048_576) MB)")
    }

    func noteUnloaded(_ client: ModelClient) async {
        ModelBrokerActivity.shared.setBusy(client, false)
        guard ledger.isResident(client) || unloads[client] != nil else { return }
        ledger.noteUnloaded(client)
        unloads[client] = nil
        sample("\(client.rawValue) unloaded")
    }

    func markBusy(_ client: ModelClient, _ busy: Bool) async {
        let isBusy = ledger.markBusy(client, busy, now: clock())
        ModelBrokerActivity.shared.setBusy(client, isBusy)
        // Depth is transient on the 6 GB class and while an LLM is resident (D12): once idle, it goes.
        if !isBusy, ledger.shouldUnloadWhenIdle(client, physicalMemory: physicalMemory) {
            ledger.noteUnloaded(client)
            await unload(client, reason: "transient")
        }
    }

    func prepareForExport(megapixels: Double) async {
        let available = availableBytes()
        let released = ledger.releaseForExport(megapixels: megapixels, availableBytes: available)
        sample(String(format: "export %.0f MP → release %@", megapixels, released.map(\.rawValue).joined(separator: ", ")))
        for client in released {
            await unload(client, reason: "broker:export")
        }
    }

    /// The longest an export waits for a Live turn to end before it starts anyway (the estimate is an upper bound).
    static let exportLLMWait: Double = 15

    /// W3 (D15): the export rule with the export's own estimate. A `memory.sample` before and after; SAM and Depth
    /// go; the LLM goes when `peakBytes` does not fit in the free memory above the floor and the export margin. A
    /// busy LLM is never evicted mid-turn: the export waits for its turn to end (up to `exportLLMWait`), then asks
    /// again with the memory free then.
    func prepareForExport(megapixels: Double, peakBytes: Int) async {
        ModelBrokerActivity.shared.exportStarted(at: Date())
        sample(String(format: "export %.0f MP, estimate %d MB: before", megapixels, peakBytes / 1_048_576))
        var released = ledger.releaseForExport(peakBytes: peakBytes, megapixels: megapixels, availableBytes: availableBytes())
        for client in released { await unload(client, reason: "broker:export") }
        if ledger.exportWaitsForLLM(peakBytes: peakBytes, availableBytes: availableBytes()) {
            PSLog.info("model broker: export waits for the Live turn to end", category: .models)
            let deadline = clock() + Self.exportLLMWait
            // Actor reentrancy: markBusy(.llm, false) lands while this sleeps.
            while ledger.resident(.llm)?.isBusy == true, clock() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let late = ledger.releaseForExport(peakBytes: peakBytes, megapixels: megapixels, availableBytes: availableBytes())
            for client in late { await unload(client, reason: "broker:export") }
            released += late
        }
        sample(String(format: "export %.0f MP, estimate %d MB: after, released %@", megapixels, peakBytes / 1_048_576,
                      released.isEmpty ? "nothing" : released.map(\.rawValue).joined(separator: ", ")))
    }

    func exportFinished() async {
        ModelBrokerActivity.shared.exportEnded()
        sample("export finished")
    }

    func makeRoom(bytes: Int, for client: ModelClient) async {
        guard let available = availableBytes(), available < bytes else { return }
        for candidate in ModelBrokerPolicy.roomOrder(for: client, residents: ledger.residents) {
            ledger.noteUnloaded(candidate)
            PSLog.info("model broker: unloading \(candidate.rawValue) to make room for \(client.rawValue)", category: .models)
            await unload(candidate, reason: "broker:\(client.rawValue)")
            if (availableBytes() ?? .max) >= bytes { break }
        }
        sample("room for \(client.rawValue) \(bytes / 1_048_576) MB")
    }

    func releaseIdle(reason: String) async {
        let released = ModelBrokerPolicy.roomOrder(for: .llm, residents: ledger.residents)
        guard !released.isEmpty else { return }
        for client in released {
            ledger.noteUnloaded(client)
            await unload(client, reason: reason)
        }
        PSLog.info("model broker: released \(released.map(\.rawValue).joined(separator: ", ")) (\(reason))", category: .models)
        sample("released idle (\(reason))")
    }

    // MARK: Debug

    /// The loaded models, for Diagnostic Live.
    func residents() -> [ModelResident] { ledger.residents }

    // MARK: Private

    /// Runs the client's unload. The LLM goes through LocalBrainHub on the main actor, with the reason in the log.
    private func unload(_ client: ModelClient, reason: String) async {
        let closure = unloads.removeValue(forKey: client)
        if client == .llm {
            await LocalBrainHub.shared.releaseNow(reason: reason)
        } else {
            await closure?()
        }
    }

    private func sample(_ detail: String) {
        let line = "\(detail) · \(MemoryBudget.availableDescription) free · resident \(ledger.residents.map(\.client.rawValue).joined(separator: "+"))"
        PSSignpost.event("memory.sample", line)
        PSLog.debug("model broker: \(line)", category: .models)
    }

    private static func describe(_ decision: ModelBrokerDecision) -> String {
        switch decision {
        case .admit(let evicting): return evicting.isEmpty ? "admit" : "admit, evicting \(evicting.map(\.rawValue).joined(separator: ", "))"
        case .refuse(let reason): return "refuse (\(reason))"
        }
    }
}

// MARK: - Activity (W3)

/// What the broker knows is running, readable synchronously from the main actor: which models are busy and whether an
/// export is under way. The KV self-test (D22 step 5) runs only when none is.
final class ModelBrokerActivity: @unchecked Sendable {
    static let shared = ModelBrokerActivity()

    /// An export that never said it finished stops counting after this long.
    static let exportLifetime: Double = 90

    private let lock = NSLock()
    private var busy: Set<ModelClient> = []
    private var exportSince: Date?

    func setBusy(_ client: ModelClient, _ isBusy: Bool) {
        lock.withLock {
            if isBusy { busy.insert(client) } else { busy.remove(client) }
        }
    }

    func exportStarted(at date: Date) {
        lock.withLock { exportSince = date }
    }

    func exportEnded() {
        lock.withLock { exportSince = nil }
    }

    /// A model is mid-inference (the LLM mid-turn, SAM or Depth mid-analysis) or an export runs.
    func isBusy(now: Date) -> Bool {
        lock.withLock {
            if !busy.isEmpty { return true }
            guard let exportSince else { return false }
            return now.timeIntervalSince(exportSince) < Self.exportLifetime
        }
    }
}

// MARK: - The LLM as a resident

extension LocalBrainHub {
    /// The weights are in: the broker counts them (`memoryNeededToLoad`, above the 4B's 3.9 GB peak), and a
    /// vision-capable model becomes the visual grounder (`groundBox`, D13).
    func brokerNoteLoaded(_ id: String) async {
        guard let entry = LocalModelCatalog.entry(id: id) else { return }
        if entry.info.supportsVision, let runtime {
            VisualGrounding.install(LocalVisualGrounder(makeEngine: { [runtime] setup in try await runtime.makeEngine(setup) }, info: entry.info))
        }
        let bytes = Int(clamping: entry.memoryNeededToLoad)
        await ModelResidency.noteLoaded(.llm, bytes: bytes, unload: { await LocalBrainHub.shared.releaseNow(reason: "broker") })
    }

    /// The weights are gone: no grounder, and the broker stops counting them.
    func brokerNoteUnloaded() async {
        VisualGrounding.install(nil)
        await ModelResidency.noteUnloaded(.llm)
    }

    /// A Live turn or a plan is using the model (or no longer is): a busy LLM is never evicted.
    nonisolated static func markModelBusy(_ busy: Bool) async {
        await ModelResidency.markBusy(.llm, busy)
    }

    /// The broker's residents, for Diagnostic Live ("sam 260 MB · llm 4063 MB"); empty without a broker.
    static func brokerResidentsLine() async -> String {
        guard let broker = ModelResidency.coordinator as? ModelBroker else { return "" }
        let residents = await broker.residents()
        return residents.map { "\($0.client.rawValue) \($0.bytes / 1_048_576) MB\($0.isBusy ? " ·busy" : "")" }.joined(separator: " · ")
    }
}
#endif
