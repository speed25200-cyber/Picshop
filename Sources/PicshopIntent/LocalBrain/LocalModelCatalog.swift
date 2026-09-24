import Foundation

// The two Live models, pinned: which repository, which revision, which files,
// how big. Pure, so the downloader (ModelManager), the hub and the tests all
// read the same table. Only one of them is installed at a time.

/// One downloadable Live model.
public struct LocalModelEntry: Sendable, Equatable {
    public var info: LocalModelInfo
    /// Hugging Face repository, e.g. "mlx-community/Qwen3.5-4B-MLX-4bit".
    public var repository: String
    /// The tier it serves.
    public var tier: LocalModelTier
    /// Download size, also roughly what the weights take once loaded.
    public var downloadBytes: Int64

    public init(info: LocalModelInfo, repository: String, tier: LocalModelTier, downloadBytes: Int64) {
        self.info = info
        self.repository = repository
        self.tier = tier
        self.downloadBytes = downloadBytes
    }

    /// D13: free memory a load needs, the weights plus 1.2 GB.
    public var memoryNeededToLoad: UInt64 { UInt64(downloadBytes) + LocalModelCatalog.loadHeadroomBytes }

    /// D12: free storage a download needs, the weights plus 1 GB.
    public var storageNeededToDownload: Int64 { downloadBytes + LocalModelCatalog.storageHeadroomBytes }
}

public enum LocalModelCatalog {
    /// The budget the brain works within (not the model's own limit).
    public static let contextTokens = 8_192
    /// Pixel budget of an attached picture: 512×384 (D7).
    public static let imageMaxPixels = 196_608
    public static let loadHeadroomBytes: UInt64 = 1_200_000_000
    public static let storageHeadroomBytes: Int64 = 1_000_000_000

    /// The only files fetched (checked against the Hugging Face API for both revisions).
    public static let fileAllowlist = [
        "config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
        "chat_template.jinja", "preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json",
    ]
    /// Without these a download is incomplete, whatever the listing says.
    public static let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    /// Qwen3.5 4B, 4-bit MLX: Max tier (A18 Pro, A19, A19 Pro).
    public static let max = LocalModelEntry(
        info: LocalModelInfo(id: LocalModelTiering.maxModelID, displayName: "Qwen3.5 4B", revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
                             contextTokens: contextTokens, supportsVision: true, promptSize: .full),
        repository: "mlx-community/Qwen3.5-4B-MLX-4bit", tier: .max, downloadBytes: 3_060_000_000)

    /// Qwen3.5 2B, 4-bit MLX: Rapide tier (A17 Pro, A18).
    public static let fast = LocalModelEntry(
        info: LocalModelInfo(id: LocalModelTiering.fastModelID, displayName: "Qwen3.5 2B", revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
                             contextTokens: contextTokens, supportsVision: true, promptSize: .compact),
        repository: "mlx-community/Qwen3.5-2B-MLX-4bit", tier: .fast, downloadBytes: 1_750_000_000)

    public static let all = [max, fast]

    /// Models that left the catalog; their folders are deleted once (the old Pro Brain, about 2.3 GB).
    public static let retiredModelIDs = ["qwen3-4b-4bit"]

    public static func entry(id: String) -> LocalModelEntry? {
        all.first { $0.info.id == id }
    }

    public static func entry(for tier: LocalModelTier) -> LocalModelEntry? {
        LocalModelTiering.modelID(for: tier).flatMap(entry(id:))
    }

    /// Whether a file from the repository listing is one we fetch.
    public static func isAllowed(_ path: String) -> Bool {
        fileAllowlist.contains(path)
    }
}
