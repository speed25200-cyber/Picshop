#if canImport(CoreML) && canImport(CryptoKit)
import XCTest
import CoreML
import CryptoKit
import PicshopCore
@testable import PicshopImaging

/// The pinned install path of the mask models (W2, §9.2), against a temporary folder standing in for the
/// repository: the staging layout, SHA-256 checks against the pin, kept staged files, the `installed` mark a new
/// manager reads after a relaunch, and the order of routes (a pinned descriptor never reaches "No download
/// source"). Fake packages compile through a stand-in; the real pinned packages compile with Core ML only when
/// `PICSHOP_MASK_MODELS` points at the folder `Scripts/fetch-mask-models.sh` filled.
final class PinnedInstallTests: XCTestCase {
    private var root: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PinnedInstallTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Models", isDirectory: true)
        repository = base.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Counts fetches across the install's tasks.
    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.withLock { paths.append(path) } }
        var fetched: [String] { lock.withLock { paths } }
    }

    private static let packages = ["FakeEncoder", "FakeDecoder"]
    private static let layout = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes two fake packages into the repository folder and pins them under a catalog id (so `isInstalled`
    /// treats the id as pinned), with each file's real size and SHA-256.
    private func makePinnedSet(id: String = MaskModelCatalog.samTiny.id) throws -> PinnedModelPackageSet {
        var files: [PinnedModelFile] = []
        for (index, package) in Self.packages.enumerated() {
            for (position, name) in Self.layout.enumerated() {
                let path = "\(package).mlpackage/\(name)"
                let data = Data("\(package) \(name) \(index * 10 + position) ".utf8) + Data(repeating: UInt8(index * 3 + position), count: 1_024 * (position + 1))
                let url = repository.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                files.append(PinnedModelFile(path: path, size: Int64(data.count), sha256: Self.hex(data)))
            }
        }
        return PinnedModelPackageSet(id: id, repository: "test/fake", revision: String(repeating: "0", count: 40), license: "apache-2.0",
                                     packages: Self.packages, files: files)
    }

    private func descriptor(for set: PinnedModelPackageSet, kind: ModelDescriptor.Kind = .segmentation) -> ModelDescriptor {
        ModelDescriptor(id: set.id, displayName: "Fake", summary: "Fake pinned packages", kind: kind, sizeMB: 1, pinned: set)
    }

    /// The repository folder, with a stand-in compiler that makes `<package>.mlmodelc` holding a marker.
    private func folderSource(log: FetchLog? = nil) -> PinnedInstallSource {
        let folder = repository!
        let base = PinnedInstallSource.folder(folder, compile: { package in
            let name = package.deletingPathExtension().lastPathComponent
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(name + ".mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: output.appendingPathComponent("compiled-from"))
            return output
        })
        guard let log else { return base }
        return PinnedInstallSource(fetch: { set, file, handle, cellular, resume, progress in
            log.record(file.path)
            return try await base.fetch(set, file, handle, cellular, resume, progress)
        }, compile: base.compile)
    }

    /// Polls until the install ends (installed, failed or cancelled), at most `timeout` seconds.
    private func finalState(_ manager: ModelManager, id: String, timeout: TimeInterval = 20) async -> ModelManager.State {
        let deadline = Date().addingTimeInterval(timeout)
        var state = await manager.state(of: id)
        while Date() < deadline {
            state = await manager.state(of: id)
            switch state {
            case .installed, .failed: return state
            case .notInstalled, .downloading, .compiling: break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return state
    }

    // MARK: Tests

    func testInstallStagesVerifiesCompilesAndMarksInOrder() async throws {
        let set = try makePinnedSet()
        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(folderSource())
        await manager.install(descriptor(for: set), allowsCellular: false)
        let state = await finalState(manager, id: set.id)
        XCTAssertEqual(state, .installed)

        let folder = root.appendingPathComponent(set.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("installed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("staging").path), "staging goes once installed")
        for package in Self.packages {
            let compiled = folder.appendingPathComponent("compiled/\(package).mlmodelc", isDirectory: true)
            XCTAssertEqual(try String(contentsOf: compiled.appendingPathComponent("compiled-from"), encoding: .utf8), package)
            let located = await manager.compiledPackageURL(for: set.id, package: package)
            XCTAssertEqual(located?.standardizedFileURL.path, compiled.standardizedFileURL.path)
        }
        let isInstalled = await manager.isInstalled(set.id)
        XCTAssertTrue(isInstalled)

        // A relaunch: a new manager on the same root reads the mark, not a `<id>/*.mlmodelc` it would never find.
        let relaunched = ModelManager(rootURL: root)
        let relaunchedState = await relaunched.state(of: set.id)
        XCTAssertEqual(relaunchedState, .installed)
        let relocated = await relaunched.compiledPackageURL(for: set.id, package: Self.packages[0])
        XCTAssertNotNil(relocated)
    }

    func testADigestMismatchDeletesTheFileAndFailsVerify() async throws {
        let set = try makePinnedSet()
        // The repository now serves different bytes of the same size for one weights file.
        let tampered = set.files[2]
        let url = repository.appendingPathComponent(tampered.path)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: url)

        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(folderSource())
        await manager.install(descriptor(for: set), allowsCellular: false)
        let state = await finalState(manager, id: set.id)
        XCTAssertEqual(state, .failed(ModelManager.FailureCode.verify))

        let staging = root.appendingPathComponent("\(set.id)/staging", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(tampered.path).path), "the bad file is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(set.files[0].path).path),
                      "files verified before it stay staged for the next attempt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(set.id)/installed").path))
        let isInstalled = await manager.isInstalled(set.id)
        XCTAssertFalse(isInstalled)
    }

    func testAStagedFileWithItsPinnedDigestIsKeptAndADamagedOneFetchedAgain() async throws {
        let set = try makePinnedSet()
        let staging = root.appendingPathComponent("\(set.id)/staging", isDirectory: true)
        // A previous attempt left one file complete and another of the right size but damaged.
        let complete = set.files[2]
        let damaged = set.files[5]
        for file in [complete, damaged] {
            let destination = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: repository.appendingPathComponent(file.path), to: destination)
        }
        let damagedURL = staging.appendingPathComponent(damaged.path)
        var bytes = try Data(contentsOf: damagedURL)
        bytes[0] ^= 0xFF
        try bytes.write(to: damagedURL)
        // The complete file is gone from the repository: fetching it again would fail the install.
        try FileManager.default.removeItem(at: repository.appendingPathComponent(complete.path))

        let log = FetchLog()
        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(folderSource(log: log))
        await manager.install(descriptor(for: set), allowsCellular: false)
        let state = await finalState(manager, id: set.id)
        XCTAssertEqual(state, .installed)
        XCTAssertFalse(log.fetched.contains(complete.path), "a correct staged file is kept")
        XCTAssertTrue(log.fetched.contains(damaged.path), "a damaged staged file downloads again")
        XCTAssertEqual(log.fetched.count, set.files.count - 1)
    }

    func testAPinnedDescriptorNeverReachesNoDownloadSource() async throws {
        for model in ModelCatalog.maskModels {
            XCTAssertNotNil(model.pinned, model.id)
            XCTAssertNil(model.remoteURL, model.id)
            XCTAssertNil(model.huggingFaceFolder, model.id)
            XCTAssertFalse(model.isBundledByDefault, model.id)
            XCTAssertTrue(ModelManager.isWiFiOnlyByDefault(model.kind), model.id)
        }
        XCTAssertEqual(ModelCatalog.descriptor(id: MaskModelCatalog.samTiny.id)?.sizeMB, 80)
        XCTAssertEqual(ModelCatalog.descriptor(id: MaskModelCatalog.depthSmall.id)?.sizeMB, 50)
        XCTAssertEqual(ModelCatalog.descriptor(id: MaskModelCatalog.depthSmall.id)?.kind, .depth)

        // The real descriptor, with a network that is down: the pinned route answers "network", never the
        // archive route's "No download source for this model."
        let offline = PinnedInstallSource(fetch: { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) },
                                          compile: { $0 })
        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(offline)
        let sam = try XCTUnwrap(ModelCatalog.descriptor(id: MaskModelCatalog.samTiny.id))
        await manager.install(sam)
        let state = await finalState(manager, id: sam.id)
        XCTAssertEqual(state, .failed(ModelManager.FailureCode.network))
    }

    func testCellularStaysOffByDefaultForTheMaskModels() async throws {
        let set = try makePinnedSet()
        final class Flags: @unchecked Sendable {
            let lock = NSLock()
            var values: [Bool] = []
        }
        let flags = Flags()
        let base = folderSource()
        let recording = PinnedInstallSource(fetch: { set, file, handle, cellular, resume, progress in
            flags.lock.withLock { flags.values.append(cellular) }
            return try await base.fetch(set, file, handle, cellular, resume, progress)
        }, compile: base.compile)
        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(recording)
        await manager.install(descriptor(for: set, kind: .depth))
        let state = await finalState(manager, id: set.id)
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(flags.lock.withLock { flags.values }, Array(repeating: false, count: set.files.count))
    }

    /// The real pinned packages, fetched by `Scripts/fetch-mask-models.sh`: verified against the pins and compiled
    /// by Core ML, then loaded on the CPU. Skipped without `PICSHOP_MASK_MODELS`; failed when it is set and a file
    /// is missing.
    func testThePinnedPackagesInstallAndCompile() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PICSHOP_MASK_MODELS"], !folder.isEmpty else {
            throw XCTSkip("PICSHOP_MASK_MODELS is not set: the pinned mask models are not on this machine")
        }
        let fetched = URL(fileURLWithPath: folder, isDirectory: true)
        for set in MaskModelCatalog.all {
            for file in set.files {
                let url = fetched.appendingPathComponent(file.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "PICSHOP_MASK_MODELS is set but \(file.path) is missing")
            }
        }
        let manager = ModelManager(rootURL: root)
        await manager.usePinnedSource(.folder(fetched))
        for model in ModelCatalog.maskModels {
            await manager.install(model)
            let state = await finalState(manager, id: model.id, timeout: 600)
            XCTAssertEqual(state, .installed, model.id)
            for package in model.pinned?.packages ?? [] {
                let compiled = await manager.compiledPackageURL(for: model.id, package: package)
                let url = try XCTUnwrap(compiled, "\(model.id)/\(package)")
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuOnly
                XCTAssertNoThrow(try MLModel(contentsOf: url, configuration: configuration), package)
            }
        }
    }
}
#endif
