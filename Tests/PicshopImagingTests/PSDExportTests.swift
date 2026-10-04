#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D16a: a layered PSD read back by Core's `PSDFile`: the structure, the records' fields, straight colour with the
/// alpha in the transparency channel, the composite; a refused export renders nothing. With `PICSHOP_PSD_OUT` set, the
/// files are copied there for L5's `validate_psd.py`.
final class PSDExportTests: XCTestCase {
    private let width = 192, height = 144

    private struct Made {
        var document: PhotoDocument
        var halfAlphaID: UUID
        var maskedID: UUID
        var hiddenID: UUID
        var fillID: UUID
    }

    /// The 10-layer document, with a 50 %-alpha top layer, a linked mask, a hidden layer and a fill below 1.
    private func make(_ fixture: LayerFixtures.Project) throws -> Made {
        let made = try TenLayerDocument.make(fixture, contentSide: 64)
        var document = made.document
        let half = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.3, 0.1, alpha: 0.5, width: 64, height: 48), width: 64, height: 48)
        document.update(layerID: made.movingID) { layer in
            layer.content = .image(half)
            layer.transform = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 0.5)
            layer.fillOpacity = 1
        }
        let maskedID = made.imageIDs[1]
        let masked = try fixture.stack(LayerFixtures.halfMask(width: 64, height: 48), width: 64, height: 48)
        document.update(layerID: maskedID) { $0.maskStack = masked }
        let hiddenID = made.imageIDs[3]
        document.update(layerID: hiddenID) { $0.isVisible = false }
        let fillID = made.imageIDs[0]
        document.update(layerID: fillID) { $0.fillOpacity = 0.6 }
        return Made(document: document, halfAlphaID: made.movingID, maskedID: maskedID, hiddenID: hiddenID, fillID: fillID)
    }

    /// The records the document should give, bottom → top: (name, lsct section type or nil, the layer).
    private func expectedRecords(_ document: PhotoDocument) -> [(name: String, section: Int?, layer: Layer?)] {
        var expected: [(name: String, section: Int?, layer: Layer?)] = []
        var opened: Set<UUID> = []
        for layer in document.layers {
            if let parent = document.parent(of: layer.id)?.id, !opened.contains(parent) {
                expected.append(("</Layer group>", 3, nil))
                opened.insert(parent)
            }
            switch layer.content {
            case .group(let folder):
                if !opened.contains(layer.id) { expected.append(("</Layer group>", 3, nil)) }
                opened.remove(layer.id)
                expected.append((layer.name, folder.isCollapsed ? 2 : 1, layer))
            case .adjustment:
                expected.append(("\(layer.name) (aplati)", nil, layer))
            default:
                expected.append((layer.name, nil, layer))
            }
        }
        return expected
    }

    private func copyForValidation(_ url: URL, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PICSHOP_PSD_OUT"], !directory.isEmpty else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        XCTAssertNoThrow(try FileManager.default.copyItem(at: url, to: target))
    }

    private func byte(_ value: Double) -> UInt8 { UInt8(clamping: Int((value * 255).rounded())) }

    func testATenLayerDocumentReadsBack() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.7, 0.5, 0.4), (0.3, 0.6, 0.5), (0.5, 0.4, 0.7), (0.8, 0.8, 0.6)], width: width, height: height))
        defer { fixture.cleanup() }
        let made = try make(fixture)
        let document = made.document
        let url = try await PhotoExporter.export(document, renderer: fixture.renderer, options: ExportOptions(format: .psd, saveToPhotos: false))
        defer { try? FileManager.default.removeItem(at: url) }
        copyForValidation(url, name: "picshop-ten-layers-8.psd")
        XCTAssertEqual(url.pathExtension, "psd")
        let file = try PSDFile(data: Data(contentsOf: url))
        XCTAssertEqual(file.width, width)
        XCTAssertEqual(file.height, height)
        XCTAssertEqual(file.depth, 8)

        // Structure: names, order, groups.
        let expected = expectedRecords(document)
        XCTAssertEqual(file.layers.map(\.name), expected.map(\.name))
        guard file.layers.count == expected.count else { return }
        for (record, want) in zip(file.layers, expected) {
            if let section = want.section {
                XCTAssertEqual(record.sectionType, section, "\(want.name): section")
            }
            guard let layer = want.layer else { continue }
            let label = want.name
            // Blend keys: pass-through groups "pass", adjustment stamps normal.
            if case .group(let folder) = layer.content {
                XCTAssertEqual(record.blendKey, folder.passThrough ? PSDBlendKey.passThrough : PSDBlendKey.key(for: layer.blendMode), label)
            } else if layer.isAdjustment {
                XCTAssertEqual(record.blendKey, PSDBlendKey.key(for: .normal), label)
            } else {
                XCTAssertEqual(record.blendKey, PSDBlendKey.key(for: layer.blendMode), label)
            }
            XCTAssertEqual(record.opacity, byte(layer.opacity), "\(label): opacity")
            if !layer.isGroup { XCTAssertEqual(record.fillOpacity, byte(layer.fillOpacity), "\(label): fill") }
            XCTAssertEqual(record.clipped, layer.isClipped && document.clippingBase(of: layer.id) != nil, "\(label): clipping")
            XCTAssertEqual(record.visible, layer.isVisible, "\(label): visibility")
            XCTAssertEqual(record.flags & 2 != 0, !layer.isVisible, "\(label): the hidden flag")
            let hasMask = layer.mask != nil || (layer.maskStack.map { !$0.isEmpty } ?? false)
            XCTAssertEqual(record.maskRect != nil, hasMask, "\(label): mask")
        }
        XCTAssertEqual(file.layers.first { $0.name == document.layer(id: made.fillID)?.name }?.fillOpacity, byte(0.6))
        XCTAssertEqual(file.layers.first { $0.name == document.layer(id: made.hiddenID)?.name }?.visible, false)

        // The composite equals the whole render (opaque: straight = premultiplied).
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        XCTAssertEqual(rendered.width, width)
        var worst = 0
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                guard let plane = file.composite[channel], pixel < plane.count else { continue }
                worst = max(worst, abs(Int(plane[pixel]) - Int(rendered.bytes[pixel * 4 + channel])))
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "the merged image is the render")

        // The 50 %-alpha layer: straight colour in 0…2, its alpha in −1.
        guard let halfName = document.layer(id: made.halfAlphaID)?.name,
              let record = file.layers.first(where: { $0.name == halfName }) else { return XCTFail("no 50 % layer") }
        let w = record.rect.width, h = record.rect.height
        XCTAssertGreaterThan(w, 0)
        let centre = (h / 2) * w + w / 2
        guard let red = record.channels[0], let green = record.channels[1], let alpha = record.channels[-1], centre < red.count else {
            return XCTFail("channels missing")
        }
        XCTAssertEqual(Double(red[centre]), 0.9 * 255, accuracy: 3, "straight red")
        XCTAssertEqual(Double(green[centre]), 0.3 * 255, accuracy: 3, "straight green")
        XCTAssertEqual(Double(alpha[centre]), 0.5 * 255, accuracy: 2, "transparency channel")
    }

    func testA16BitPSDKeepsItsDepth() async throws {
        let fixture = try LayerFixtures.project(width: 96, height: 72,
                                                base: LayerFixtures.quadrants([(0.7, 0.5, 0.4), (0.3, 0.6, 0.5)], width: 96, height: 72))
        defer { fixture.cleanup() }
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.2, 0.4, 0.9, alpha: 0.5, width: 32, height: 24), width: 32, height: 24)
        document.layers.append(Layer(name: "Bleu", content: .image(asset), transform: LayerTransform(scale: 0.5)))
        let url = try await PhotoExporter.export(document, renderer: fixture.renderer, options: ExportOptions(format: .psd, saveToPhotos: false, bitDepth: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        copyForValidation(url, name: "picshop-two-layers-16.psd")
        let file = try PSDFile(data: Data(contentsOf: url))
        XCTAssertEqual(file.depth, 16)
        XCTAssertEqual(file.layers.map(\.name), [document.layers[0].name, "Bleu"])
        // 16-bit samples are big-endian pairs: the blue layer's centre alpha ≈ 0.5.
        guard let record = file.layers.last, let alpha = record.channels[-1] else { return XCTFail("no alpha") }
        let w = record.rect.width, h = record.rect.height
        let index = ((h / 2) * w + w / 2) * 2
        guard index + 1 < alpha.count else { return XCTFail("short alpha") }
        let value = Int(alpha[index]) << 8 | Int(alpha[index + 1])
        XCTAssertEqual(Double(value) / 65535, 0.5, accuracy: 0.01)
    }

    func testAFlattenedPSDIsOneLayer() async throws {
        let fixture = try LayerFixtures.project(width: 64, height: 48, base: LayerFixtures.solid(0.4, 0.5, 0.6, width: 64, height: 48))
        defer { fixture.cleanup() }
        var document = fixture.document
        document.layers.append(Layer(name: "Couleur", content: .fill(PSColor(red: 1, green: 0, blue: 0)), opacity: 0.5))
        let url = try await PhotoExporter.export(document, renderer: fixture.renderer, options: ExportOptions(format: .psd, saveToPhotos: false, layered: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PSDFile(data: Data(contentsOf: url))
        XCTAssertEqual(file.layers.count, 1)
    }

    func testAnEstimateOverTheLimitThrowsBeforeAnyRendering() async throws {
        let fixture = try LayerFixtures.project(width: 8, height: 8, base: LayerFixtures.solid(0.5, 0.5, 0.5, width: 8, height: 8))
        defer { fixture.cleanup() }
        // A 29,000 px square whose file does not exist: any render would fail on the missing file, not on the budget.
        let missing = MediaAsset(kind: .image, relativePath: "media/missing.jpg", pixelSize: PSSize(width: 29_000, height: 29_000))
        var document = PhotoDocument(title: "Énorme", baseImage: missing)
        document.layers.append(Layer(name: "Copie", content: .image(missing)))
        do {
            _ = try await PhotoExporter.export(document, renderer: fixture.renderer, options: ExportOptions(format: .psd, saveToPhotos: false, bitDepth: 16))
            XCTFail("a 29,000 px 16-bit PSD is over 2 GB")
        } catch let error as PSDError {
            XCTAssertEqual(error, .tooHeavy)
            XCTAssertEqual(PSDExport.message(for: error, french: true), "Trop lourd pour un PSD : réduis la taille ou passe en 8 bits")
        }
        let runs = await fixture.renderer.expensiveRuns
        XCTAssertEqual(runs, 0)
        // Larger than 30,000 px: too large, whatever the depth.
        let wide = MediaAsset(kind: .image, relativePath: "media/missing.jpg", pixelSize: PSSize(width: 31_000, height: 100))
        do {
            _ = try await PhotoExporter.export(PhotoDocument(title: "Large", baseImage: wide), renderer: fixture.renderer,
                                               options: ExportOptions(format: .psd, saveToPhotos: false))
            XCTFail("over 30,000 px")
        } catch let error as PSDError {
            XCTAssertEqual(error, .tooLarge)
        }
    }
}
#endif
