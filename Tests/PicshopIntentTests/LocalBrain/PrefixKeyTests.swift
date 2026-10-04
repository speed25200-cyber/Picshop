import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D22 step 4: the persisted prefix's key (any field change invalidates the file, the stem is the same on every
/// launch), its safetensors metadata, and the store's retention (3 files, 450 MB, model removal, the weekly sweep).
final class PrefixKeyTests: XCTestCase {
    private let key = LivePrefixKey(modelID: "live-qwen35-4b", revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
                                    runtimeRevision: "ee673d6a71d76e67b532dc7eaf91d92edc3bb8bb", mode: "photo", size: "full",
                                    layout: "catalog", prefixHash: "0123456789abcdef", templateHash: "fedcba9876543210")

    func testTheStemIsStableAcrossRuns() {
        // FNV-1a 64 of the fields joined by "|", computed once outside Swift: never Hasher's per-launch seed.
        XCTAssertEqual(key.fileStem, "77b3cd805124473c")
        XCTAssertEqual(key.fileStem.count, 16)
        XCTAssertEqual(key.fileStem, LivePrefixKey(modelID: key.modelID, revision: key.revision, runtimeRevision: key.runtimeRevision,
                                                   mode: key.mode, size: key.size, layout: key.layout, prefixHash: key.prefixHash,
                                                   templateHash: key.templateHash).fileStem)
        XCTAssertEqual(LivePrefixKey.prefixHash(tokens: [1, 2, 3]), "ff3635971fa88157")
        XCTAssertEqual(LivePrefixKey.templateHash("{%- if true %}"), StableHash.hex("{%- if true %}"))
    }

    func testAnyFieldChangesTheStem() {
        let fields: [WritableKeyPath<LivePrefixKey, String>] = [\.modelID, \.revision, \.runtimeRevision, \.mode, \.size, \.layout,
                                                                \.prefixHash, \.templateHash]
        var stems: Set<String> = [key.fileStem]
        for field in fields {
            var changed = key
            changed[keyPath: field] += "x"
            XCTAssertNotEqual(changed.fileStem, key.fileStem)
            stems.insert(changed.fileStem)
        }
        XCTAssertEqual(stems.count, fields.count + 1, "every field moves the stem somewhere else")
        // The separator keeps neighbouring fields apart: moving a character across a "|" is a different key.
        var shifted = key
        shifted.mode = "photof"
        shifted.size = "ull"
        XCTAssertNotEqual(shifted.fileStem, key.fileStem)
        XCTAssertNotEqual(LivePrefixKey.prefixHash(tokens: [12, 3]), LivePrefixKey.prefixHash(tokens: [1, 23]))
    }

    func testTheMetadataRoundTripsAndRejectsAnythingElse() {
        let metadata = key.metadata(tokens: 4_210, build: "412")
        XCTAssertEqual(Set(metadata.keys), ["picshop.key", "picshop.tokens", "picshop.model", "picshop.revision", "picshop.mode", "picshop.size",
                                            "picshop.layout", "picshop.prefixHash", "picshop.templateHash", "picshop.runtime", "picshop.build"])
        XCTAssertTrue(key.accepts(metadata: metadata, tokens: 4_210))
        XCTAssertFalse(key.accepts(metadata: metadata, tokens: 4_211), "the re-tokenized prefix has another length")
        for field in ["picshop.key", "picshop.model", "picshop.revision", "picshop.runtime", "picshop.prefixHash", "picshop.templateHash"] {
            var tampered = metadata
            tampered[field] = "other"
            XCTAssertFalse(key.accepts(metadata: tampered, tokens: 4_210), field)
            tampered[field] = nil
            XCTAssertFalse(key.accepts(metadata: tampered, tokens: 4_210), field)
        }
        // Another build's file of the same key is still good (the weekly sweep removes it, not the load).
        var otherBuild = metadata
        otherBuild["picshop.build"] = "413"
        XCTAssertTrue(key.accepts(metadata: otherBuild, tokens: 4_210))
        let decoded = try? JSONDecoder().decode(LivePrefixKey.self, from: JSONEncoder().encode(key))
        XCTAssertEqual(decoded, key)
    }

    // MARK: Retention

    private let mib = 1_048_576

    func testAtMostThreeFilesLeastRecentlyUsedFirst() {
        let files = [LivePrefixFile(stem: "a", bytes: 100 * mib, modified: 10), LivePrefixFile(stem: "b", bytes: 100 * mib, modified: 30),
                     LivePrefixFile(stem: "c", bytes: 100 * mib, modified: 20), LivePrefixFile(stem: "d", bytes: 100 * mib, modified: 40)]
        XCTAssertEqual(LivePrefixRetention.evictions(files), ["a"])
        XCTAssertEqual(LivePrefixRetention.evictions(Array(files.prefix(3))), [])
        XCTAssertEqual(LivePrefixRetention.evictions(files, keeping: "a"), ["c"], "the file in use stays")
    }

    func testAtMost450MB() {
        let files = [LivePrefixFile(stem: "old", bytes: 200 * mib, modified: 1), LivePrefixFile(stem: "mid", bytes: 160 * mib, modified: 2),
                     LivePrefixFile(stem: "new", bytes: 160 * mib, modified: 3)]
        XCTAssertEqual(LivePrefixRetention.evictions(files), ["old"])
        XCTAssertEqual(LivePrefixRetention.maxBytes, 450 * mib)
        XCTAssertEqual(LivePrefixRetention.maxFiles, 3)
        // A single file over the budget that is in use is kept; everything else goes.
        let huge = [LivePrefixFile(stem: "big", bytes: 600 * mib, modified: 5), LivePrefixFile(stem: "x", bytes: 10 * mib, modified: 1)]
        XCTAssertEqual(LivePrefixRetention.evictions(huge, keeping: "big"), ["x"])
        XCTAssertEqual(LivePrefixRetention.evictions([]), [])
    }

    func testAModelRemovalPurgesItsFilesOnly() {
        let files = [LivePrefixFile(stem: "a", bytes: 1, modified: 1, modelID: "live-qwen35-4b", build: "1"),
                     LivePrefixFile(stem: "b", bytes: 1, modified: 2, modelID: "live-qwen35-2b", build: "1"),
                     LivePrefixFile(stem: "c", bytes: 1, modified: 3, modelID: nil, build: nil)]
        XCTAssertEqual(LivePrefixRetention.purge(files, modelID: "live-qwen35-4b"), ["a"])
        XCTAssertEqual(LivePrefixRetention.purge(files, modelID: "other"), [])
    }

    func testTheStaleBuildSweepRunsWeekly() {
        let files = [LivePrefixFile(stem: "now", bytes: 1, modified: 1, modelID: "m", build: "412"),
                     LivePrefixFile(stem: "old", bytes: 1, modified: 1, modelID: "m", build: "400"),
                     LivePrefixFile(stem: "unreadable", bytes: 1, modified: 1)]
        let week = LivePrefixRetention.staleSweepInterval
        XCTAssertEqual(week, 604_800)
        XCTAssertEqual(LivePrefixRetention.staleBuildSweep(files, currentBuild: "412", lastSweep: nil, now: 1_000), ["old", "unreadable"])
        XCTAssertEqual(LivePrefixRetention.staleBuildSweep(files, currentBuild: "412", lastSweep: 1_000, now: 1_000 + week - 1), [])
        XCTAssertEqual(LivePrefixRetention.staleBuildSweep(files, currentBuild: "412", lastSweep: 1_000, now: 1_000 + week), ["old", "unreadable"])
    }
}

/// The safetensors header the retention sweep reads without loading tensors.
final class PrefixFileHeaderTests: XCTestCase {
    private func file(header: String) -> Data {
        let json = Data(header.utf8)
        var length = UInt64(json.count)
        var data = Data()
        for _ in 0..<8 {
            data.append(UInt8(length & 0xFF))
            length >>= 8
        }
        return data + json + Data([0, 1, 2, 3])
    }

    func testTheUserMetadataComesFromTheHeader() {
        let data = file(header: #"{"__metadata__":{"0.0.0":"x","1.picshop.model":"live-qwen35-4b","1.picshop.build":"412","2.0":"KVCache"},"0.0":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#)
        XCTAssertEqual(LivePrefixRetention.userMetadata(safetensorsPrefix: data), ["picshop.model": "live-qwen35-4b", "picshop.build": "412"])
        XCTAssertEqual(LivePrefixRetention.safetensorsHeaderLength(data), data.count - 12)
    }

    func testAnythingElseIsNotAHeader() {
        XCTAssertNil(LivePrefixRetention.userMetadata(safetensorsPrefix: Data([1, 2, 3])))
        XCTAssertNil(LivePrefixRetention.userMetadata(safetensorsPrefix: Data(repeating: 0xFF, count: 64)), "an absurd length")
        XCTAssertNil(LivePrefixRetention.userMetadata(safetensorsPrefix: file(header: "not json")))
        let truncated = file(header: #"{"__metadata__":{"1.a":"b"}}"#).prefix(12)
        XCTAssertNil(LivePrefixRetention.userMetadata(safetensorsPrefix: Data(truncated)))
        XCTAssertEqual(LivePrefixRetention.userMetadata(safetensorsPrefix: file(header: #"{"0.0":{}}"#)), [:], "no metadata block")
    }
}
