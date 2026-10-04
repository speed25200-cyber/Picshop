import XCTest
@testable import PicshopCore

/// The pinned SAM 2.1 tiny and Depth Anything V2 Small packages (W2, §4.7): every file pinned by size and
/// SHA-256 at a fixed revision, laid out as complete .mlpackage directories.
final class MaskModelCatalogTests: XCTestCase {
    func testEveryFileIsPinnedByALowercaseSHA256AndAPositiveSize() {
        let hex = Set("0123456789abcdef")
        for set in MaskModelCatalog.all {
            XCTAssertFalse(set.files.isEmpty, set.id)
            for file in set.files {
                XCTAssertEqual(file.sha256.count, 64, file.path)
                XCTAssertTrue(file.sha256.allSatisfy { hex.contains($0) }, "\(file.path): \(file.sha256)")
                XCTAssertGreaterThan(file.size, 0, file.path)
            }
            XCTAssertEqual(Set(set.files.map(\.path)).count, set.files.count, "\(set.id): a path is pinned twice")
            XCTAssertEqual(Set(set.files.map(\.sha256)).count, set.files.count, "\(set.id): two files share a digest")
        }
    }

    func testEveryPathSitsInsideAListedPackage() {
        for set in MaskModelCatalog.all {
            for file in set.files {
                XCTAssertTrue(set.packages.contains { file.path.hasPrefix($0 + ".mlpackage/") }, "\(set.id): \(file.path)")
                XCTAssertFalse(file.path.contains(".."), file.path)
                XCTAssertFalse(file.path.hasPrefix("/"), file.path)
            }
        }
    }

    func testEachPackageIsComplete() {
        let required = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
        for set in MaskModelCatalog.all {
            XCTAssertFalse(set.packages.isEmpty, set.id)
            for package in set.packages {
                let paths = set.files.map(\.path).filter { $0.hasPrefix(package + ".mlpackage/") }
                XCTAssertEqual(Set(paths), Set(required.map { "\(package).mlpackage/\($0)" }), package)
            }
        }
    }

    func testTotalsRevisionsAndLicences() {
        XCTAssertEqual(MaskModelCatalog.samTiny.totalBytes, 79_644_968)
        XCTAssertEqual(MaskModelCatalog.depthSmall.totalBytes, 49_819_122)
        XCTAssertEqual(MaskModelCatalog.samTiny.id, "sam21-tiny")
        XCTAssertEqual(MaskModelCatalog.depthSmall.id, "depth-anything-v2-small")
        XCTAssertEqual(MaskModelCatalog.samTiny.repository, "apple/coreml-sam2.1-tiny")
        XCTAssertEqual(MaskModelCatalog.depthSmall.repository, "apple/coreml-depth-anything-v2-small")
        XCTAssertEqual(MaskModelCatalog.samTiny.packages,
                       ["SAM2_1TinyImageEncoderFLOAT16", "SAM2_1TinyPromptEncoderFLOAT16", "SAM2_1TinyMaskDecoderFLOAT16"],
                       "compiled in this order: encoder, prompt encoder, decoder")
        XCTAssertEqual(MaskModelCatalog.depthSmall.packages, ["DepthAnythingV2SmallF16"])
        for set in MaskModelCatalog.all {
            XCTAssertEqual(set.license, "apache-2.0", set.id)
            XCTAssertEqual(set.revision.count, 40, "\(set.id): a full commit, never a branch")
            XCTAssertTrue(set.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase }, set.id)
        }
        XCTAssertEqual(MaskModelCatalog.all.map(\.id), ["sam21-tiny", "depth-anything-v2-small"])
    }

    func testThePackageSetsAreHashable() {
        // ModelDescriptor (Hashable, synthesized, Apple-only) stores a PinnedModelPackageSet?: Linux proves the
        // conformance here, since the descriptor itself never compiles on this platform.
        let sets: Set<PinnedModelPackageSet> = [MaskModelCatalog.samTiny, MaskModelCatalog.depthSmall, MaskModelCatalog.samTiny]
        XCTAssertEqual(sets.count, 2)
        let files = Set(MaskModelCatalog.all.flatMap(\.files))
        XCTAssertEqual(files.count, 12)
        XCTAssertNotEqual(MaskModelCatalog.samTiny, MaskModelCatalog.depthSmall)
    }
}
