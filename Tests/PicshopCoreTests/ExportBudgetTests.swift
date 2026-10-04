import XCTest
@testable import PicshopCore

/// W3 export memory and presets (D14, D15, D16, D16a): the peak-bytes estimate the broker releases against, the PSD
/// size guard, the presets the LLM encodes and the sheet decodes, and the Photos destinations.
final class ExportBudgetTests: XCTestCase {
    private let mib = 1_048_576
    /// An iPhone 48 MP frame (8064 × 6048) and a 12 MP one.
    private let big = (width: 8_064, height: 6_048)
    private let small = (width: 4_032, height: 3_024)

    // MARK: peakBytes

    func testPeakBytesGrowWithSizeDepthAndLayers() {
        for format in ExportFileFormat.allCases {
            for streaming in [false, true] {
                let base = ExportBudget.peakBytes(format: format, bitDepth: 8, width: small.width, height: small.height, layers: 1, streaming: streaming)
                let wider = ExportBudget.peakBytes(format: format, bitDepth: 8, width: small.width * 2, height: small.height, layers: 1, streaming: streaming)
                let taller = ExportBudget.peakBytes(format: format, bitDepth: 8, width: small.width, height: small.height * 2, layers: 1, streaming: streaming)
                let deeper = ExportBudget.peakBytes(format: format, bitDepth: 16, width: small.width, height: small.height, layers: 1, streaming: streaming)
                let layered = ExportBudget.peakBytes(format: format, bitDepth: 8, width: small.width, height: small.height, layers: 10, streaming: streaming)
                XCTAssertGreaterThan(wider, base, "\(format) streaming \(streaming): width")
                XCTAssertGreaterThanOrEqual(taller, base, "\(format) streaming \(streaming): height")
                XCTAssertGreaterThan(deeper, base, "\(format) streaming \(streaming): depth")
                XCTAssertGreaterThanOrEqual(layered, base, "\(format) streaming \(streaming): layers")
            }
        }
        // Taller only costs more without strips (a strip is 512 rows whatever the height), or for HEIC.
        let stripTall = ExportBudget.peakBytes(format: .png, bitDepth: 8, width: 4_000, height: 12_000, layers: 1, streaming: true)
        let stripShort = ExportBudget.peakBytes(format: .png, bitDepth: 8, width: 4_000, height: 6_000, layers: 1, streaming: true)
        XCTAssertEqual(stripTall, stripShort)
        XCTAssertGreaterThan(ExportBudget.peakBytes(format: .png, bitDepth: 8, width: 4_000, height: 12_000, layers: 1, streaming: false),
                             ExportBudget.peakBytes(format: .png, bitDepth: 8, width: 4_000, height: 6_000, layers: 1, streaming: false))
        // A layered PSD keeps one row table per layer until the file is assembled.
        XCTAssertGreaterThan(ExportBudget.peakBytes(format: .psd, bitDepth: 8, width: big.width, height: big.height, layers: 10, streaming: true),
                             ExportBudget.peakBytes(format: .psd, bitDepth: 8, width: big.width, height: big.height, layers: 1, streaming: true))
    }

    func testStreamingA48MPSixteenBitExportStaysUnder80MB() {
        for format in [ExportFileFormat.png, .tiff, .psd] {
            let peak = ExportBudget.peakBytes(format: format, bitDepth: 16, width: big.width, height: big.height, layers: 6, streaming: true)
            XCTAssertLessThanOrEqual(peak, 80 * mib, "\(format): \(peak / mib) MB")
            XCTAssertGreaterThan(peak, 2 * big.width * ExportBudget.stripRows * 8, "\(format): two strips in flight")
        }
        let jpeg = ExportBudget.peakBytes(format: .jpeg, bitDepth: 8, width: big.width, height: big.height, layers: 1, streaming: true)
        XCTAssertLessThanOrEqual(jpeg, 80 * mib)
    }

    func testTheNonStreamingFallbackCountsTheFullSurface() {
        let surface16 = big.width * big.height * 8
        let fallback = ExportBudget.peakBytes(format: .png, bitDepth: 16, width: big.width, height: big.height, layers: 1, streaming: false)
        XCTAssertGreaterThanOrEqual(fallback, surface16)
        XCTAssertLessThan(fallback, surface16 + 32 * mib, "the surface plus the encoder, not two surfaces")
        // ≈ 390 MB at 48 MP 16-bit (D15's table).
        XCTAssertEqual(Double(fallback) / 1_000_000, 398, accuracy: 15)
        let tiff8 = ExportBudget.peakBytes(format: .tiff, bitDepth: 8, width: big.width, height: big.height, layers: 1, streaming: false)
        XCTAssertGreaterThanOrEqual(tiff8, big.width * big.height * 4)
    }

    func testHEICCountsItsFullSurfaceEvenWhenTheCallerStreams() {
        let heic10 = ExportBudget.peakBytes(format: .heic, bitDepth: 10, width: big.width, height: big.height, layers: 1, streaming: true)
        let surface = big.width * big.height * 8
        XCTAssertGreaterThan(heic10, surface, "the 10-bit surface plus the 4:2:0 frame")
        XCTAssertEqual(heic10, ExportBudget.peakBytes(format: .heic, bitDepth: 10, width: big.width, height: big.height, layers: 1, streaming: false))
        let heic8 = ExportBudget.peakBytes(format: .heic, bitDepth: 8, width: big.width, height: big.height, layers: 1, streaming: true)
        XCTAssertGreaterThan(heic8, big.width * big.height * 4)
        XCTAssertLessThan(heic8, heic10)
    }

    func testPinnedBytesAdd() {
        let plain = ExportBudget.peakBytes(format: .jpeg, bitDepth: 8, width: big.width, height: big.height, layers: 3, streaming: true)
        let pinned = ExportBudget.peakBytes(format: .jpeg, bitDepth: 8, width: big.width, height: big.height, layers: 3, streaming: true,
                                            pinnedBytes: 192 * mib)
        XCTAssertEqual(pinned - plain, 192 * mib)
        // Nonsense inputs never make the estimate negative.
        XCTAssertGreaterThanOrEqual(ExportBudget.peakBytes(format: .png, bitDepth: 0, width: -5, height: -5, layers: -1, streaming: true,
                                                           pinnedBytes: -10), 0)
    }

    func testStreamsFrom24MPSixteenBitOrLayered() {
        XCTAssertFalse(ExportBudget.streams(width: small.width, height: small.height, bitDepth: 8, layered: false))
        XCTAssertTrue(ExportBudget.streams(width: big.width, height: big.height, bitDepth: 8, layered: false))
        XCTAssertTrue(ExportBudget.streams(width: 6_000, height: 4_000, bitDepth: 8, layered: false), "24 MP exactly")
        XCTAssertTrue(ExportBudget.streams(width: small.width, height: small.height, bitDepth: 16, layered: false))
        XCTAssertTrue(ExportBudget.streams(width: small.width, height: small.height, bitDepth: 8, layered: true))
        XCTAssertEqual(ExportBudget.stripRows, 512)
        XCTAssertEqual(ExportBudget.streamingThresholdMegapixels, 24)
    }

    // MARK: PSD

    func testThePSDEstimateGuardsTwoGigabytes() {
        let canvas = 8_000 * 6_000
        let ten = ExportBudget.psdBytesEstimate(width: 8_000, height: 6_000, depth: 8, layerPixels: canvas * 10)
        let six = ExportBudget.psdBytesEstimate(width: 8_000, height: 6_000, depth: 8, layerPixels: canvas * 6)
        XCTAssertGreaterThan(ten, PSDWriter.maxBytes, "48 MP, 8-bit, 10 full-canvas layers: « Trop lourd pour un PSD »")
        XCTAssertLessThan(six, PSDWriter.maxBytes, "48 MP, 8-bit, 6 full-canvas layers fit")
        // 16-bit doubles it; layers at their bounds cost less than full-canvas ones.
        XCTAssertEqual(Double(ExportBudget.psdBytesEstimate(width: 8_000, height: 6_000, depth: 16, layerPixels: canvas * 6)),
                       Double(six) * 2, accuracy: 4)
        XCTAssertLessThan(ExportBudget.psdBytesEstimate(width: 8_000, height: 6_000, depth: 8, layerPixels: canvas * 10 / 4), six)
        // The bound covers the raw channels.
        XCTAssertGreaterThanOrEqual(six, canvas * 4 * 7)
    }

    // MARK: Presets

    func testInstagramIsAlways1080Wide() {
        let preset = ExportPreset.instagram
        XCTAssertEqual(preset.outputSize(canvas: PSSize(width: 3_024, height: 3_780)), PSSize(width: 1_080, height: 1_350), "4:5")
        XCTAssertEqual(preset.outputSize(canvas: PSSize(width: 3_024, height: 3_024)), PSSize(width: 1_080, height: 1_080), "1:1")
        XCTAssertEqual(preset.outputSize(canvas: PSSize(width: 3_024, height: 5_376)), PSSize(width: 1_080, height: 1_920), "9:16")
        XCTAssertEqual(preset.outputSize(canvas: PSSize(width: 6_048, height: 4_032)), PSSize(width: 1_080, height: 720), "3:2 landscape")
        XCTAssertEqual(preset.format, .jpeg)
        XCTAssertEqual(preset.colorSpace, "sRGB")
        XCTAssertEqual(preset.quality, 0.9)
        XCTAssertFalse(preset.keepsLocation)
        XCTAssertEqual(preset.name, "instagram")
    }

    func testWebIs2048OnTheLongSideAndPrintIsFullSize() {
        XCTAssertEqual(ExportPreset.web.outputSize(canvas: PSSize(width: 4_032, height: 3_024)), PSSize(width: 2_048, height: 1_536))
        XCTAssertEqual(ExportPreset.web.outputSize(canvas: PSSize(width: 3_024, height: 4_032)), PSSize(width: 1_536, height: 2_048))
        XCTAssertEqual(ExportPreset.web.quality, 0.85)
        XCTAssertEqual(ExportPreset.web.format, .jpeg)
        XCTAssertEqual(ExportPreset.print.outputSize(canvas: PSSize(width: 4_032, height: 3_024)), PSSize(width: 4_032, height: 3_024))
        XCTAssertEqual(ExportPreset.print.format, .tiff)
        XCTAssertEqual(ExportPreset.print.bitDepth, 8)
        XCTAssertEqual(ExportPreset.print.resolution, 300)
    }

    func testARuleNeverEnlarges() {
        let tiny = PSSize(width: 800, height: 600)
        XCTAssertEqual(ExportPreset.web.outputSize(canvas: tiny), tiny)
        XCTAssertEqual(ExportPreset.instagram.outputSize(canvas: tiny), tiny)
        XCTAssertEqual(ExportPreset(format: .png, size: .longSide(0)).outputSize(canvas: tiny), tiny)
        XCTAssertEqual(ExportPreset.web.outputSize(canvas: .zero), .zero)
        // Sides are whole pixels, at least one.
        let sliver = ExportPreset(format: .png, size: .longSide(100)).outputSize(canvas: PSSize(width: 10_000, height: 3))
        XCTAssertEqual(sliver, PSSize(width: 100, height: 1))
    }

    func testPresetsRoundTripAndDecodeWithDefaults() throws {
        for preset in [ExportPreset.instagram, .print, .web, ExportPreset(format: .psd, bitDepth: 16, size: .longSide(4_096))] {
            let data = try JSONEncoder().encode(preset)
            XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: data), preset)
        }
        let minimal = try JSONDecoder().decode(ExportPreset.self, from: Data(#"{"format":"png"}"#.utf8))
        XCTAssertEqual(minimal, ExportPreset(format: .png))
        XCTAssertEqual(minimal.bitDepth, 8)
        XCTAssertEqual(minimal.colorSpace, "displayP3")
        XCTAssertEqual(minimal.size, .full)
        XCTAssertTrue(minimal.layered)
        XCTAssertTrue(minimal.keepsLocation)
        XCTAssertThrowsError(try JSONDecoder().decode(ExportPreset.self, from: Data(#"{"bitDepth":16}"#.utf8)), "format is required")
    }

    func testPDFAndPSDNeverGoToPhotos() {
        XCTAssertFalse(ExportFileFormat.pdf.canSaveToPhotos)
        XCTAssertFalse(ExportFileFormat.psd.canSaveToPhotos)
        for format in [ExportFileFormat.jpeg, .heic, .png, .tiff] { XCTAssertTrue(format.canSaveToPhotos, format.rawValue) }
        XCTAssertEqual(ExportFileFormat.allCases.count, 6)
    }
}
