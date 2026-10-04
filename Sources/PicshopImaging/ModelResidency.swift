import Foundation
import PicshopCore

// The model broker's seam in Imaging (W2, D12): SAM, Depth, LaMa, the upscaler and Stable Diffusion ask
// `ModelResidency.admit` before they load and report `noteLoaded`/`noteUnloaded` after. The app installs the
// coordinator (LocalBrainHub+Broker) behind the `modelBroker` flag; without one every admit is true (W1).

/// The broker the app installs.
public protocol ModelResidencyCoordinator: AnyObject, Sendable {
    func admit(_ client: ModelClient, bytes: Int, priority: ModelPriority) async -> Bool
    func noteLoaded(_ client: ModelClient, bytes: Int, unload: @escaping @Sendable () async -> Void) async
    func noteUnloaded(_ client: ModelClient) async
    func markBusy(_ client: ModelClient, _ busy: Bool) async
    func prepareForExport(megapixels: Double) async
    /// For a client that loads without asking (the LLM): unload idle models, lowest priority first, until `bytes`
    /// are free or none is left. No floor: the client checks free memory again itself.
    func makeRoom(bytes: Int, for client: ModelClient) async
    /// A memory warning or the background: every idle model but the LLM goes (LocalBrainHub releases that one).
    func releaseIdle(reason: String) async
    /// W3 (D15): the export rule with the export's own estimate (`ExportBudget.peakBytes`).
    func prepareForExport(megapixels: Double, peakBytes: Int) async
    /// W3: the export that `prepareForExport` announced is over (written, failed or cancelled). Background model
    /// work (the KV self-test) waits for it.
    func exportFinished() async
}

public extension ModelResidencyCoordinator {
    func makeRoom(bytes: Int, for client: ModelClient) async {}
    func releaseIdle(reason: String) async {}
    /// Seam default: the W2 behaviour.
    func prepareForExport(megapixels: Double, peakBytes: Int) async { await prepareForExport(megapixels: megapixels) }
    func exportFinished() async {}
}

public enum ModelResidency {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var coordinator: (any ModelResidencyCoordinator)?
    }

    private static let box = Box()

    public static var coordinator: (any ModelResidencyCoordinator)? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.coordinator
    }

    public static func install(_ coordinator: (any ModelResidencyCoordinator)?) {
        box.lock.lock()
        box.coordinator = coordinator
        box.lock.unlock()
    }

    /// True when no coordinator is installed (tests, macOS).
    public static func admit(_ client: ModelClient, bytes: Int, priority: ModelPriority) async -> Bool {
        guard let coordinator else { return true }
        return await coordinator.admit(client, bytes: bytes, priority: priority)
    }

    public static func noteLoaded(_ client: ModelClient, bytes: Int, unload: @escaping @Sendable () async -> Void) async {
        await coordinator?.noteLoaded(client, bytes: bytes, unload: unload)
    }

    public static func noteUnloaded(_ client: ModelClient) async {
        await coordinator?.noteUnloaded(client)
    }

    public static func markBusy(_ client: ModelClient, _ busy: Bool) async {
        await coordinator?.markBusy(client, busy)
    }

    public static func prepareForExport(megapixels: Double) async {
        await coordinator?.prepareForExport(megapixels: megapixels)
    }

    /// W3 (D15): forwards to the coordinator with the export's peak-bytes estimate. The broker releases SAM and
    /// Depth, and the LLM when the estimate does not fit above the floor (waiting for a Live turn to end first).
    public static func prepareForExport(megapixels: Double, peakBytes: Int) async {
        await coordinator?.prepareForExport(megapixels: megapixels, peakBytes: peakBytes)
    }

    /// W3: the export is over; call it on every path out of an export that called `prepareForExport`.
    public static func exportFinished() async {
        await coordinator?.exportFinished()
    }

    /// Nothing without a coordinator: the caller's own memory check decides alone (W1).
    public static func makeRoom(bytes: Int, for client: ModelClient) async {
        await coordinator?.makeRoom(bytes: bytes, for: client)
    }

    public static func releaseIdle(reason: String) async {
        await coordinator?.releaseIdle(reason: reason)
    }
}
