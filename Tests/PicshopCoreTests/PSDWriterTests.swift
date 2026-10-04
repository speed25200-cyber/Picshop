import XCTest
@testable import PicshopCore

/// D16a writer limits and streaming: sizes over 30,000 px, an estimate over 2 GB refused before anything is written,
/// bad depths and short rows, the temporary directory removed, progress to 1, and a 4,000 × 3,000 document written by
/// pulling each row once, in order, without holding the image.
final class PSDWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-psd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Rows made on demand from their index; records every request and never keeps more than the row it returns.
    final class InstrumentedRows: PSDRowSource {
        let width: Int, height: Int, channels: Int
        private(set) var requests: [Int] = []
        private(set) var largestRow = 0

        init(width: Int, height: Int, channels: Int = 4) {
            self.width = width
            self.height = height
            self.channels = channels
        }

        /// One template row (runs of 8 and ramps), stamped with the row index so no two rows are alike.
        private lazy var template: [UInt8] = (0..<(width * channels)).map { UInt8(truncatingIfNeeded: ($0 / channels) >> 3 &+ $0 % channels * 37) }

        func row(_ y: Int) throws -> [UInt8] {
            requests.append(y)
            var row = template
            row[0] = UInt8(truncatingIfNeeded: y)
            row[row.count / 2] = UInt8(truncatingIfNeeded: y >> 8)
            largestRow = max(largestRow, row.count)
            return row
        }
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("psd-") }
    }

    func testTooLargeSidesAreRefused() {
        let rows = InstrumentedRows(width: 1, height: 1)
        let url = directory.appendingPathComponent("large.psd")
        let wide = PSDDocumentSpec(width: 30_001, height: 10, layers: [], composite: rows)
        XCTAssertThrowsError(try PSDWriter.write(wide, to: url, temporaryDirectory: directory)) { XCTAssertEqual($0 as? PSDError, .tooLarge) }
        let tall = PSDDocumentSpec(width: 10, height: 30_001, layers: [], composite: rows)
        XCTAssertThrowsError(try PSDWriter.write(tall, to: url, temporaryDirectory: directory)) { XCTAssertEqual($0 as? PSDError, .tooLarge) }
        let layer = PSDLayer(name: "Grand", rect: PSDRect(top: 0, left: 0, bottom: 1, right: 30_001), layerID: 1, pixels: rows)
        let big = PSDDocumentSpec(width: 10, height: 10, layers: [layer], composite: rows)
        XCTAssertThrowsError(try PSDWriter.write(big, to: url, temporaryDirectory: directory)) { XCTAssertEqual($0 as? PSDError, .tooLarge) }
        XCTAssertEqual(rows.requests, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnEstimateOverTwoGigabytesIsRefusedBeforeWriting() {
        // 30,000 × 25,000 RGBA with two full layers: 9 GB raw.
        let rows = InstrumentedRows(width: 30_000, height: 25_000)
        let full = PSDRect(top: 0, left: 0, bottom: 25_000, right: 30_000)
        let layers = (1...2).map { PSDLayer(name: "C\($0)", rect: full, layerID: UInt32($0), pixels: rows) }
        let spec = PSDDocumentSpec(width: 30_000, height: 25_000, layers: layers, composite: rows)
        XCTAssertGreaterThan(PSDWriter.estimatedBytes(spec), PSDWriter.maxBytes)
        let url = directory.appendingPathComponent("heavy.psd")
        XCTAssertThrowsError(try PSDWriter.write(spec, to: url, temporaryDirectory: directory)) { XCTAssertEqual($0 as? PSDError, .tooHeavy) }
        XCTAssertEqual(rows.requests, [], "nothing was pulled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(leftovers(), [])
    }

    func testTheEstimateIsAnUpperBound() throws {
        let made = PSDTestDocuments.threeLayers(depth: 8)
        let url = directory.appendingPathComponent("three.psd")
        try PSDWriter.write(made.spec, to: url, temporaryDirectory: directory)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, PSDWriter.estimatedBytes(made.spec))
        // 16 bits doubles the samples.
        let wide = PSDTestDocuments.threeLayers(depth: 16).spec
        XCTAssertGreaterThan(PSDWriter.estimatedBytes(wide), PSDWriter.estimatedBytes(made.spec) * 3 / 2)
    }

    func testBadDepthsAndShortRowsFailWithoutLeavingFiles() {
        let rows = InstrumentedRows(width: 4, height: 4)
        let url = directory.appendingPathComponent("bad.psd")
        let twelve = PSDDocumentSpec(width: 4, height: 4, depth: 12, layers: [], composite: rows)
        XCTAssertThrowsError(try PSDWriter.write(twelve, to: url, temporaryDirectory: directory)) { XCTAssertEqual($0 as? PSDError, .unsupportedDepth) }
        // A source two bytes short.
        let short = PSDMemoryRows(width: 4, height: 4, channels: 4, depth: 8, bytes: [UInt8](repeating: 1, count: 4 * 4 * 4 - 2))
        let layer = PSDLayer(name: "Court", rect: PSDRect(top: 0, left: 0, bottom: 4, right: 4), layerID: 1, pixels: short)
        let spec = PSDDocumentSpec(width: 4, height: 4, layers: [layer], composite: rows)
        XCTAssertThrowsError(try PSDWriter.write(spec, to: url, temporaryDirectory: directory)) { error in
            guard case .badRow = error as? PSDError else { return XCTFail("\(error)") }
        }
        // Two channels are not a layer.
        let gray = PSDLayer(name: "Gris", rect: PSDRect(top: 0, left: 0, bottom: 4, right: 4), layerID: 2,
                            pixels: PSDMemoryRows(width: 4, height: 4, channels: 2, depth: 8, bytes: [UInt8](repeating: 1, count: 32)))
        XCTAssertThrowsError(try PSDWriter.write(PSDDocumentSpec(width: 4, height: 4, layers: [gray], composite: rows), to: url,
                                                 temporaryDirectory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(leftovers(), [])
    }

    func testTemporariesAreRemovedAndProgressReachesOne() throws {
        let made = PSDTestDocuments.threeLayers(depth: 8)
        let url = directory.appendingPathComponent("progress.psd")
        var values: [Double] = []
        try PSDWriter.write(made.spec, to: url, temporaryDirectory: directory) { values.append($0) }
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress never goes back")
        XCTAssertEqual(leftovers(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // An RGB merged image gets an opaque alpha.
        let rgb = PSDMemoryRows(width: 2, height: 2, channels: 3, depth: 8, bytes: [UInt8](repeating: 9, count: 12))
        let opaque = directory.appendingPathComponent("rgb.psd")
        try PSDWriter.write(PSDDocumentSpec(width: 2, height: 2, layers: [], composite: rgb), to: opaque, temporaryDirectory: directory)
        let psd = try PSDFile(data: try Data(contentsOf: opaque))
        XCTAssertEqual(psd.composite[3], [255, 255, 255, 255])
        XCTAssertEqual(psd.composite[0], [9, 9, 9, 9])
        XCTAssertEqual(psd.layers.count, 0)
    }

    /// The process's peak resident size in bytes (Linux), nil elsewhere.
    private func peakResidentBytes() -> Int? {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return nil }
        for line in status.split(separator: "\n") where line.hasPrefix("VmHWM:") {
            let digits = line.split(separator: " ").compactMap { Int($0) }
            return digits.first.map { $0 * 1024 }
        }
        return nil
    }

    func testAFourThousandByThreeThousandDocumentStreams() throws {
        let width = 4000, height = 3000
        let full = PSDRect(top: 0, left: 0, bottom: Int32(height), right: Int32(width))
        let sources = (0..<3).map { _ in InstrumentedRows(width: width, height: height) }
        let layers = [PSDLayer(name: "Fond", rect: full, layerID: 1, pixels: sources[0]),
                      PSDLayer(name: "Calque", rect: full, blendKey: "mul ", layerID: 2, pixels: sources[1])]
        let spec = PSDDocumentSpec(width: width, height: height, layers: layers, composite: sources[2])
        let url = directory.appendingPathComponent("large.psd")
        let before = peakResidentBytes()
        try PSDWriter.write(spec, to: url, temporaryDirectory: directory)
        // Each row pulled once, in order: nothing is kept to be read again.
        for source in sources {
            XCTAssertEqual(source.requests, Array(0..<height))
            XCTAssertEqual(source.largestRow, width * 4)
        }
        XCTAssertEqual(leftovers(), [])
        // A layer held whole would be 48 MB, the three sources 144 MB; streaming stays an order of magnitude below.
        if let before, let after = peakResidentBytes() {
            XCTAssertLessThan(after - before, 40_000_000, "peak memory grew by \(after - before) bytes")
        }
        // The file opens and has the right shape.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try XCTUnwrap(try handle.read(upToCount: 26))
        XCTAssertEqual(Array(header.prefix(4)), Array("8BPS".utf8))
        XCTAssertEqual(Array(header[14..<22]), [0, 0, 0x0B, 0xB8, 0, 0, 0x0F, 0xA0], "height 3000, width 4000")
    }
}
