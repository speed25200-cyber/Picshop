import XCTest
@testable import PicshopCore

/// The PSD fixtures the round-trip tests read back and PSDFixtureExportTests hands to psd-tools: every record field the
/// writer sets, with the values it was given, so a reader can check them one by one.
enum PSDTestDocuments {
    struct Expected {
        var name: String
        var kind: PSDLayer.Kind
        var rect: PSDRect
        var blendKey: String
        var opacity: UInt8
        var fillOpacity: UInt8
        var clipped: Bool
        var visible: Bool
        var lockFlags: UInt32
        var layerID: UInt32
        /// Interleaved RGBA over the rect (nil for markers).
        var pixels: [UInt8]?
        var maskRect: PSDRect?
        var maskDefaultColor: UInt8?
        var mask: [UInt8]?
    }

    static let width = 40, height = 30

    /// Interleaved samples (8 bits: 1 byte; 16 bits: the value × 257, big-endian) from a pattern of the position.
    static func samples(width: Int, height: Int, channels: Int, depth: Int, seed: Int, alpha: UInt8? = nil) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * channels * depth / 8)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    // Flat stretches (runs) and ramps (literals) both.
                    var value = UInt8(truncatingIfNeeded: (x / 4) * 13 + y * 7 + c * 61 + seed * 29)
                    if c == 3, let alpha { value = alpha }
                    if depth == 16 {
                        let wide = UInt16(value) * 257 &+ UInt16(truncatingIfNeeded: x)
                        bytes += [UInt8(wide >> 8), UInt8(wide & 0xFF)]
                    } else {
                        bytes.append(value)
                    }
                }
            }
        }
        return bytes
    }

    /// Three layers (« Été » pixels; « Groupe 1 », pass-through, holding « Tasse » and « Ombre » clipped onto it;
    /// « Masqué », masked, multiply at 60 % fill), bottom → top with the group's divider and opening records.
    static func threeLayers(depth: Int) -> (spec: PSDDocumentSpec, expected: [Expected], composite: [UInt8]) {
        func rows(_ rect: PSDRect, seed: Int, channels: Int = 4, alpha: UInt8? = nil) -> (PSDMemoryRows, [UInt8]) {
            let bytes = samples(width: rect.width, height: rect.height, channels: channels, depth: depth, seed: seed, alpha: alpha)
            return (PSDMemoryRows(width: rect.width, height: rect.height, channels: channels, depth: depth, bytes: bytes), bytes)
        }
        let full = PSDRect(top: 0, left: 0, bottom: Int32(height), right: Int32(width))
        let cup = PSDRect(top: 4, left: 6, bottom: 20, right: 26)
        let shadow = PSDRect(top: 8, left: 10, bottom: 18, right: 30)
        let masked = PSDRect(top: 2, left: 3, bottom: 28, right: 37)
        let maskRect = PSDRect(top: 5, left: 5, bottom: 25, right: 30)
        let (fondRows, fondBytes) = rows(full, seed: 1, alpha: 255)
        let (cupRows, cupBytes) = rows(cup, seed: 2)
        let (shadowRows, shadowBytes) = rows(shadow, seed: 3)
        let (maskedRows, maskedBytes) = rows(masked, seed: 4)
        let (maskRows, maskBytes) = rows(maskRect, seed: 5, channels: 1)
        let mask = PSDLayerMask(rect: maskRect, defaultColor: 0, disabled: false, rows: maskRows)
        let layers = [
            PSDLayer(name: "Été", rect: full, lockFlags: 0x8000_0000, layerID: 1, pixels: fondRows),
            PSDLayer(kind: .groupEnd, name: "", rect: .empty, layerID: 2, pixels: nil),
            PSDLayer(name: "Tasse", rect: cup, blendKey: "scrn", opacity: 200, layerID: 3, pixels: cupRows),
            PSDLayer(name: "Ombre", rect: shadow, blendKey: PSDBlendKey.key(for: .darkerColor), clipped: true, visible: false, layerID: 4,
                     pixels: shadowRows),
            PSDLayer(kind: .groupOpen(collapsed: false), name: "Groupe 1", rect: .empty, blendKey: PSDBlendKey.passThrough, opacity: 230,
                     lockFlags: 4, layerID: 5, pixels: nil),
            PSDLayer(name: "Masqué", rect: masked, blendKey: PSDBlendKey.key(for: .multiply), fillOpacity: 153, lockFlags: 1, layerID: 6,
                     pixels: maskedRows, mask: mask),
        ]
        let expected = [
            Expected(name: "Été", kind: .pixels, rect: full, blendKey: "norm", opacity: 255, fillOpacity: 255, clipped: false, visible: true,
                     lockFlags: 0x8000_0000, layerID: 1, pixels: fondBytes),
            Expected(name: "</Layer group>", kind: .groupEnd, rect: .empty, blendKey: "norm", opacity: 255, fillOpacity: 255, clipped: false,
                     visible: true, lockFlags: 0, layerID: 2),
            Expected(name: "Tasse", kind: .pixels, rect: cup, blendKey: "scrn", opacity: 200, fillOpacity: 255, clipped: false, visible: true,
                     lockFlags: 0, layerID: 3, pixels: cupBytes),
            Expected(name: "Ombre", kind: .pixels, rect: shadow, blendKey: "dkCl", opacity: 255, fillOpacity: 255, clipped: true, visible: false,
                     lockFlags: 0, layerID: 4, pixels: shadowBytes),
            Expected(name: "Groupe 1", kind: .groupOpen(collapsed: false), rect: .empty, blendKey: "pass", opacity: 230, fillOpacity: 255,
                     clipped: false, visible: true, lockFlags: 4, layerID: 5),
            Expected(name: "Masqué", kind: .pixels, rect: masked, blendKey: "mul ", opacity: 255, fillOpacity: 153, clipped: false, visible: true,
                     lockFlags: 1, layerID: 6, pixels: maskedBytes, maskRect: maskRect, maskDefaultColor: 0, mask: maskBytes),
        ]
        let composite = samples(width: width, height: height, channels: 4, depth: depth, seed: 9, alpha: 255)
        let spec = PSDDocumentSpec(width: width, height: height, depth: depth, iccProfile: Data((0..<132).map { UInt8($0) }), layers: layers,
                                   composite: PSDMemoryRows(width: width, height: height, channels: 4, depth: depth, bytes: composite))
        return (spec, expected, composite)
    }

    /// One layer at 50 % alpha over the whole canvas.
    static func halfAlpha() -> (spec: PSDDocumentSpec, pixels: [UInt8]) {
        let rect = PSDRect(top: 0, left: 0, bottom: 4, right: 6)
        var pixels: [UInt8] = []
        for _ in 0..<(6 * 4) { pixels += [200, 100, 50, 128] }
        let layer = PSDLayer(name: "Demi", rect: rect, layerID: 1, pixels: PSDMemoryRows(width: 6, height: 4, channels: 4, depth: 8, bytes: pixels))
        let spec = PSDDocumentSpec(width: 6, height: 4, layers: [layer], composite: PSDMemoryRows(width: 6, height: 4, channels: 4, depth: 8, bytes: pixels))
        return (spec, pixels)
    }

    /// Planar channels from interleaved samples.
    static func planes(_ bytes: [UInt8], width: Int, height: Int, channels: Int, bytesPerSample: Int) -> [[UInt8]] {
        var result = [[UInt8]](repeating: [], count: channels)
        for pixel in 0..<(width * height) {
            for c in 0..<channels {
                let start = (pixel * channels + c) * bytesPerSample
                result[c] += bytes[start..<(start + bytesPerSample)]
            }
        }
        return result
    }

    static func write(_ spec: PSDDocumentSpec, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).psd")
        try PSDWriter.write(spec, to: url, temporaryDirectory: FileManager.default.temporaryDirectory)
        return url
    }
}

/// D16a–c: the three-layer document parses back with every field and sample, at 8 and 16 bits; the composite, the
/// resources; straight colour under 50 % alpha.
final class PSDRoundTripTests: XCTestCase {
    private func assertRoundTrip(depth: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let made = PSDTestDocuments.threeLayers(depth: depth)
        let url = try PSDTestDocuments.write(made.spec, name: "roundtrip-\(depth)")
        defer { try? FileManager.default.removeItem(at: url) }
        let psd = try PSDFile(data: try Data(contentsOf: url))
        let bytesPerSample = depth / 8
        XCTAssertEqual(psd.width, PSDTestDocuments.width, file: file, line: line)
        XCTAssertEqual(psd.height, PSDTestDocuments.height, file: file, line: line)
        XCTAssertEqual(psd.depth, depth, file: file, line: line)
        XCTAssertEqual(psd.channelCount, 4, file: file, line: line)
        XCTAssertEqual(psd.layers.count, made.expected.count, file: file, line: line)
        for (record, want) in zip(psd.layers, made.expected) {
            let label = "\(depth) bits, \(want.name)"
            XCTAssertEqual(record.name, want.name, label, file: file, line: line)
            XCTAssertEqual(record.rect, want.rect, label, file: file, line: line)
            XCTAssertEqual(record.blendKey, want.kind == .groupEnd ? "norm" : want.blendKey, label, file: file, line: line)
            XCTAssertEqual(record.opacity, want.opacity, label, file: file, line: line)
            XCTAssertEqual(record.fillOpacity, want.fillOpacity, label, file: file, line: line)
            XCTAssertEqual(record.clipped, want.clipped, label, file: file, line: line)
            XCTAssertEqual(record.visible, want.visible, label, file: file, line: line)
            XCTAssertEqual(record.lockFlags, want.lockFlags, label, file: file, line: line)
            XCTAssertEqual(record.layerID, want.layerID, label, file: file, line: line)
            XCTAssertEqual(record.flags & 1 != 0, want.lockFlags & 0x8000_0001 != 0, "\(label): transparency protected", file: file, line: line)
            switch want.kind {
            case .pixels:
                XCTAssertNil(record.sectionType, label, file: file, line: line)
                XCTAssertEqual(record.flags & 16, 0, label, file: file, line: line)
            case .groupOpen(let collapsed):
                XCTAssertEqual(record.sectionType, collapsed ? 2 : 1, label, file: file, line: line)
                XCTAssertEqual(record.sectionBlendKey, want.blendKey, label, file: file, line: line)
                XCTAssertEqual(record.flags & 24, 24, "\(label): pixel data irrelevant", file: file, line: line)
            case .groupEnd:
                XCTAssertEqual(record.sectionType, 3, label, file: file, line: line)
            }
            // Every sample, planar, transparency in −1.
            if let pixels = want.pixels {
                let planes = PSDTestDocuments.planes(pixels, width: want.rect.width, height: want.rect.height, channels: 4, bytesPerSample: bytesPerSample)
                for (index, id) in [Int16(0), 1, 2, -1].enumerated() {
                    XCTAssertEqual(record.channels[id], planes[index], "\(label): channel \(id)", file: file, line: line)
                }
            } else {
                XCTAssertTrue(record.channels.values.allSatisfy(\.isEmpty), label, file: file, line: line)
            }
            XCTAssertEqual(record.maskRect, want.maskRect, label, file: file, line: line)
            XCTAssertEqual(record.maskDefaultColor, want.maskDefaultColor, label, file: file, line: line)
            if let mask = want.mask {
                XCTAssertEqual(record.channels[-2], mask, "\(label): mask", file: file, line: line)
                XCTAssertEqual(record.maskDisabled, false, label, file: file, line: line)
            }
        }
        // The composite rows.
        let planes = PSDTestDocuments.planes(made.composite, width: PSDTestDocuments.width, height: PSDTestDocuments.height, channels: 4,
                                             bytesPerSample: bytesPerSample)
        for channel in 0..<4 { XCTAssertEqual(psd.composite[channel], planes[channel], "composite \(channel)", file: file, line: line) }
        // Resolution (300 ppi in 16.16) and the ICC profile.
        let resolution = try XCTUnwrap(psd.resources[0x03ED], file: file, line: line)
        XCTAssertEqual(resolution.count, 16, file: file, line: line)
        XCTAssertEqual(Array(resolution.prefix(4)), [0x01, 0x2C, 0x00, 0x00], file: file, line: line)
        XCTAssertEqual(psd.resources[0x040F], Data((0..<132).map { UInt8($0) }), file: file, line: line)
    }

    func testAThreeLayer8BitDocumentReadsBack() throws {
        try assertRoundTrip(depth: 8)
    }

    func testThe16BitDocumentReadsBackThroughLr16() throws {
        try assertRoundTrip(depth: 16)
        // The layer info is in an Lr16 block: the plain layer info is empty.
        let url = try PSDTestDocuments.write(PSDTestDocuments.threeLayers(depth: 16).spec, name: "lr16")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("8BIMLr16".utf8)))
    }

    func testFiftyPercentAlphaKeepsStraightColour() throws {
        let made = PSDTestDocuments.halfAlpha()
        let url = try PSDTestDocuments.write(made.spec, name: "alpha")
        defer { try? FileManager.default.removeItem(at: url) }
        let psd = try PSDFile(data: try Data(contentsOf: url))
        let record = try XCTUnwrap(psd.layers.first)
        XCTAssertEqual(record.channels[0], [UInt8](repeating: 200, count: 24), "colour is not darkened by the alpha")
        XCTAssertEqual(record.channels[1], [UInt8](repeating: 100, count: 24))
        XCTAssertEqual(record.channels[2], [UInt8](repeating: 50, count: 24))
        XCTAssertEqual(record.channels[-1], [UInt8](repeating: 128, count: 24))
        XCTAssertEqual(psd.composite[3], [UInt8](repeating: 128, count: 24))
        XCTAssertNil(psd.resources[0x040F], "no profile given, none written")
    }

    func testEveryBlendKeyNamesItsMode() {
        XCTAssertEqual(Set(BlendMode.allCases.map(PSDBlendKey.key(for:))).count, 27)
        for mode in BlendMode.allCases {
            XCTAssertEqual(PSDBlendKey.key(for: mode).utf8.count, 4)
            XCTAssertEqual(PSDBlendKey.mode(for: PSDBlendKey.key(for: mode)), mode)
        }
        XCTAssertNil(PSDBlendKey.mode(for: PSDBlendKey.passThrough))
    }
}
