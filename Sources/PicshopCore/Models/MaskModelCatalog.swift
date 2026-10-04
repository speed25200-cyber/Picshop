import Foundation

// The Core ML packages the masks use (W2, D9–D11), pinned file by file: each is downloaded over Wi‑Fi on
// request, checked against its SHA-256 here (never against a listing), and compiled on the device. Both are
// Apache-2.0 (`cardData.license` on their Hugging Face repositories). Pinned against the Hugging Face API on
// 2026-10-03.

/// One file of a pinned package set, at its path inside the repository.
public struct PinnedModelFile: Hashable, Sendable {
    public let path: String
    public let size: Int64
    /// Lowercase hex.
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// Hashable, because ModelDescriptor (Hashable, synthesized) stores a PinnedModelPackageSet?.
public struct PinnedModelPackageSet: Hashable, Sendable {
    public let id: String
    public let repository: String
    public let revision: String
    public let license: String
    /// .mlpackage directory names, compiled in this order.
    public let packages: [String]
    public let files: [PinnedModelFile]

    public init(id: String, repository: String, revision: String, license: String, packages: [String], files: [PinnedModelFile]) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.license = license
        self.packages = packages
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The files of one package, in pinned order.
    public func files(of package: String) -> [PinnedModelFile] {
        files.filter { $0.path.hasPrefix(package + ".mlpackage/") }
    }
}

public enum MaskModelCatalog {
    /// SAM 2.1 tiny: image encoder, prompt encoder and mask decoder (79,644,968 bytes).
    public static let samTiny = PinnedModelPackageSet(
        id: "sam21-tiny",
        repository: "apple/coreml-sam2.1-tiny",
        revision: "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306",
        license: "apache-2.0",
        packages: ["SAM2_1TinyImageEncoderFLOAT16", "SAM2_1TinyPromptEncoderFLOAT16", "SAM2_1TinyMaskDecoderFLOAT16"],
        files: [
            PinnedModelFile(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Manifest.json", size: 617,
                            sha256: "dd72aa75e3f2f92d0653696bf4d8350d87690d92b116b34912fe640f2b116e08"),
            PinnedModelFile(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 154_372,
                            sha256: "6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7"),
            PinnedModelFile(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 67_069_504,
                            sha256: "eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97"),
            PinnedModelFile(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Manifest.json", size: 617,
                            sha256: "0c0f9b80f0445017dac52f81e93aeb50b9c2c9918708c882df4a65671fda2bd4"),
            PinnedModelFile(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 20_618,
                            sha256: "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"),
            PinnedModelFile(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 2_101_056,
                            sha256: "af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2"),
            PinnedModelFile(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Manifest.json", size: 617,
                            sha256: "dc6121b61ac560498080d55f9d5fb293cdb305f942a85adb5b71dc8e9d14a8aa"),
            PinnedModelFile(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 75_167,
                            sha256: "4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577"),
            PinnedModelFile(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 10_222_400,
                            sha256: "f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de"),
        ]
    )

    /// Depth Anything V2 Small (49,819,122 bytes).
    public static let depthSmall = PinnedModelPackageSet(
        id: "depth-anything-v2-small",
        repository: "apple/coreml-depth-anything-v2-small",
        revision: "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
        license: "apache-2.0",
        packages: ["DepthAnythingV2SmallF16"],
        files: [
            PinnedModelFile(path: "DepthAnythingV2SmallF16.mlpackage/Manifest.json", size: 617,
                            sha256: "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"),
            PinnedModelFile(path: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 399_433,
                            sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
            PinnedModelFile(path: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 49_419_072,
                            sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"),
        ]
    )

    public static let all: [PinnedModelPackageSet] = [samTiny, depthSmall]
}
