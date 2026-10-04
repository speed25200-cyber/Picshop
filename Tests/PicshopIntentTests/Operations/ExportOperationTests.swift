import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (D16, §8.3): `exportPhoto` opens the sheet on a Core `ExportPreset` (never writes a file by itself); the effect's
/// JSON round-trips, the depths fit the format, the presets size the output, and the reply names where it goes.
final class ExportOperationTests: XCTestCase {
    static func run(_ args: [String: OpValue], french: Bool = true) async throws -> SelectionOperationTests.Run {
        try await LayerOperationTests.model("exportPhoto", args, on: OperationFixtures.photoWithLayers(), french: french)
    }

    static func preset(_ run: SelectionOperationTests.Run) throws -> ExportPreset {
        let message = try XCTUnwrap(LayerOperationTests.messages(run).first { $0.hasPrefix(PhotoOperationHandlers.exportPrefix) })
        return try JSONDecoder().decode(ExportPreset.self, from: Data(message.dropFirst(PhotoOperationHandlers.exportPrefix.count).utf8))
    }

    func testTheEffectRoundTripsThroughTheCorePreset() async throws {
        let args: [String: OpValue] = ["format": "psd", "layers": true, "bitDepth": "16", "colorSpace": "sRGB", "size": "2048"]
        let run = try await Self.run(args)
        XCTAssertEqual(run.after, run.before, "the sheet opens; nothing is written")
        guard case .info = run.result.outcome else { return XCTFail("\(run.result.outcome)") }
        let preset = try Self.preset(run)
        XCTAssertEqual(preset, PhotoOperationHandlers.exportPreset(args))
        XCTAssertEqual(preset.format, .psd)
        XCTAssertEqual(preset.bitDepth, 16)
        XCTAssertEqual(preset.colorSpace, "sRGB")
        XCTAssertEqual(preset.size, .longSide(2048))
        XCTAssertTrue(preset.layered)
        let json = try XCTUnwrap(PhotoOperationHandlers.exportJSON(preset))
        XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: Data(json.utf8)), preset)
        XCTAssertEqual(PhotoOperationHandlers.exportJSON(preset), json, "sorted keys: the same text every time")
    }

    func testDepthsFitTheFormat() {
        func depth(_ format: String, _ bits: String) -> Int { PhotoOperationHandlers.exportPreset(["format": .string(format), "bitDepth": .string(bits)]).bitDepth }
        XCTAssertEqual(depth("jpeg", "16"), 8)
        XCTAssertEqual(depth("pdf", "16"), 8)
        XCTAssertEqual(depth("heic", "16"), 10)
        XCTAssertEqual(depth("heic", "10"), 10)
        XCTAssertEqual(depth("png", "10"), 8)
        XCTAssertEqual(depth("png", "16"), 16)
        XCTAssertEqual(depth("tiff", "16"), 16)
        XCTAssertEqual(depth("psd", "16"), 16)
    }

    func testPresetsAndTheirOutputSizes() {
        XCTAssertEqual(PhotoOperationHandlers.exportPreset(["preset": "instagram"]), .instagram)
        XCTAssertEqual(PhotoOperationHandlers.exportPreset(["preset": "print"]), .print)
        XCTAssertEqual(PhotoOperationHandlers.exportPreset(["preset": "web"]), .web)
        XCTAssertEqual(PhotoOperationHandlers.exportPreset(["preset": "print", "format": "png"]).format, .png, "a format said overrides the preset's")
        let instagram = ExportPreset.instagram
        XCTAssertEqual(instagram.outputSize(canvas: PSSize(width: 3200, height: 4000)), PSSize(width: 1080, height: 1350))
        XCTAssertEqual(instagram.outputSize(canvas: PSSize(width: 3000, height: 3000)), PSSize(width: 1080, height: 1080))
        XCTAssertEqual(instagram.outputSize(canvas: PSSize(width: 2160, height: 3840)), PSSize(width: 1080, height: 1920))
        XCTAssertFalse(instagram.keepsLocation)
    }

    func testTheReplyNamesWhereTheFileGoes() async throws {
        for format in ["psd", "pdf"] {
            let run = try await Self.run(["format": .string(format)])
            XCTAssertTrue((run.result.outcome.message ?? "").contains("Fichiers"), "\(format): \(String(describing: run.result.outcome.message))")
        }
        for format in ["jpeg", "png", "heic", "tiff"] {
            let run = try await Self.run(["format": .string(format)])
            XCTAssertTrue((run.result.outcome.message ?? "").contains("Photos"), "\(format): \(String(describing: run.result.outcome.message))")
        }
        let english = try await Self.run(["format": "psd"], french: false)
        XCTAssertTrue((english.result.outcome.message ?? "").contains("Files"))
        XCTAssertTrue(LayerOperationTests.spoken(english).contains { $0.contains("PSD") })
    }

    func testFormatOrPresetIsRequiredFromAModel() async {
        do {
            _ = try await Self.run(["bitDepth": "16"])
            XCTFail("the validator wants a format or a preset")
        } catch {}
    }
}
