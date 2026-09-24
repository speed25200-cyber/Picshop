// The local brain's memory policy (contract D13). The per-app ceiling is about
// 6 GB even with the increased-memory-limit entitlement, and the 4B model peaks
// near 3.9 GB next to the editor, so a load is gated on the memory still free and
// MLX is kept on a short leash: a 64 MB buffer cache and an allocation limit.
#if canImport(MLXVLM)
import Foundation
import Metal
import PicshopImaging
import PicshopIntent
#if canImport(MLX)
import MLX
#endif

enum MemoryGuard {
    /// MLX's buffer cache: 64 MB (512 MB let jetsam in on iPhones).
    static let cacheLimit = 64 * 1_048_576
    /// What the rest of the app keeps once the model is in: 1.5 GB.
    static let appReserve: UInt64 = 1_500_000_000

    /// Memory the app may still use (os_proc_available_memory); nil where the system does not say.
    static var availableBytes: UInt64? {
        MemoryBudget.availableBytes.map { UInt64($0) }
    }

    /// False on the simulator (MLX builds there but cannot run) and without a Metal GPU.
    static var deviceCanRun: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return MTLCreateSystemDefaultDevice() != nil
        #endif
    }

    /// Whether `entry` may load now: its weights plus 1.2 GB still free.
    static func canLoad(_ entry: LocalModelEntry) -> Bool {
        guard let available = availableBytes else { return true }
        return available >= entry.memoryNeededToLoad
    }

    /// Before a load: the cache limit, and an allocation limit of what is free
    /// minus the app's reserve (never below the weights plus some room to run).
    static func applyLimits(for entry: LocalModelEntry) {
        #if canImport(MLX)
        MLX.Memory.cacheLimit = cacheLimit
        if let available = availableBytes {
            let floor = UInt64(entry.downloadBytes) + 600_000_000
            let limit = max(available > appReserve ? available - appReserve : 0, floor)
            MLX.Memory.memoryLimit = Int(clamping: limit)
        }
        #endif
    }

    /// Hands MLX's cached buffers back (after a load, an unload, a big prefill).
    static func clearCache() {
        #if canImport(MLX)
        MLX.Memory.clearCache()
        #endif
    }

    /// MLX's resident bytes, for the log; nil without MLX.
    static var activeBytes: Int? {
        #if canImport(MLX)
        return MLX.Memory.activeMemory
        #else
        return nil
        #endif
    }
}
#endif
