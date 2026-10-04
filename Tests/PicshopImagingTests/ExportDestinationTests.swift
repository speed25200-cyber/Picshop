#if canImport(CoreImage) && canImport(Metal) && canImport(Photos)
import XCTest
import CoreImage
import ImageIO
import PicshopCore
@testable import PicshopImaging

/// Counts what would have gone to Photos.
final class PhotoLibraryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [URL] = []

    func record(_ url: URL) { lock.withLock { saved.append(url) } }
    var urls: [URL] { lock.withLock { saved } }
}

/// D16: where exports go and what they keep. PDF and PSD never reach Photos; PNG and TIFF keep alpha; JPEG is
/// flattened on white; the instagram preset's sizes.
final class ExportDestinationTests: XCTestCase {
    private var counter = PhotoLibraryCounter()

    override func setUp() {
        super.setUp()
        counter = PhotoLibraryCounter()
        let counter = self.counter
        PhotoLibrary.setSaveHandlerForTesting { counter.record($0) }
    }

    override func tearDown() {
        PhotoLibrary.setSaveHandlerForTesting(nil)
        super.tearDown()
    }

    /// A canvas whose left half is transparent: the base is clear there and the background is clear.
    private func halfClear(width: Int, height: Int) throws -> LayerFixtures.Project {
        var base = LayerFixtures.solid(0.2, 0.4, 0.8, width: width, height: height)
        for y in 0..<height { for x in 0..<(width / 2) { for k in 0..<4 { base[(y * width + x) * 4 + k] = 0 } } }
        var fixture = try LayerFixtures.project(width: width, height: height, base: base)
        fixture.document.backgroundColor = .clear
        return fixture
    }

    func testPSDAndPDFNeverGoToPhotos() async throws {
        let fixture = try LayerFixtures.project(width: 64, height: 48, base: LayerFixtures.solid(0.5, 0.6, 0.7, width: 64, height: 48))
        defer { fixture.cleanup() }
        for format in [ExportOptions.Format.psd, .pdf] {
            let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: ExportOptions(format: format, saveToPhotos: true))
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(format) is written")
            XCTAssertFalse(format.canSaveToPhotos)
        }
        XCTAssertTrue(counter.urls.isEmpty, "Photos never sees a PDF or a PSD")
        // A JPEG asked for Photos does go there (the fake counts it).
        let jpeg = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: ExportOptions(format: .jpeg, saveToPhotos: true))
        defer { try? FileManager.default.removeItem(at: jpeg) }
        XCTAssertEqual(counter.urls, [jpeg])
    }

    func testPNGAndTIFFKeepAlphaAndJPEGIsFlattenedOnWhite() async throws {
        let width = 64, height = 48
        let fixture = try halfClear(width: width, height: height)
        defer { fixture.cleanup() }
        for format in [ExportOptions.Format.png, .tiff] {
            let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: ExportOptions(format: format, saveToPhotos: false))
            defer { try? FileManager.default.removeItem(at: url) }
            guard let samples = ExportReadback.samples(url), let alpha = samples.alphaOffset else { return XCTFail("\(format): no alpha channel") }
            let left = samples.values[(height / 2 * width + 4) * samples.components + alpha]
            let right = samples.values[(height / 2 * width + width - 4) * samples.components + alpha]
            XCTAssertEqual(left, 0, "\(format): the clear half stays clear")
            XCTAssertEqual(right, 255, "\(format): the photo stays opaque")
        }
        let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: ExportOptions(format: .jpeg, saveToPhotos: false))
        defer { try? FileManager.default.removeItem(at: url) }
        guard let samples = ExportReadback.samples(url) else { return XCTFail("JPEG unreadable") }
        let offset = (height / 2 * width + 4) * samples.components + samples.redOffset
        for channel in 0..<3 { XCTAssertGreaterThan(samples.values[offset + channel], 245, "JPEG: white where the picture is clear") }
    }

    func testTheInstagramPresetSizes() async throws {
        for (canvas, expected) in [((400, 500), (1080, 1350)), ((300, 300), (1080, 1080)), ((360, 640), (1080, 1920))] {
            let fixture = try LayerFixtures.project(width: canvas.0, height: canvas.1, base: LayerFixtures.solid(0.6, 0.5, 0.4, width: canvas.0, height: canvas.1))
            defer { fixture.cleanup() }
            var options = ExportOptions(preset: .instagram)
            options.saveToPhotos = false
            XCTAssertEqual(options.format, .jpeg)
            XCTAssertEqual(options.colorSpace, .sRGB)
            let size = options.outputSize(canvas: PSSize(width: Double(canvas.0), height: Double(canvas.1)))
            XCTAssertEqual(size, PSSize(width: Double(expected.0), height: Double(expected.1)))
            let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: options)
            defer { try? FileManager.default.removeItem(at: url) }
            let properties = ExportReadback.properties(url)
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, expected.0, "\(canvas)")
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, expected.1, "\(canvas)")
            XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1")
        }
    }
}
#endif
