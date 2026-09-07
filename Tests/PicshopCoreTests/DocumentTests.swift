import XCTest
@testable import PicshopCore

final class DocumentTests: XCTestCase {
    private func makeDocument() -> PhotoDocument {
        let asset = MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000))
        return PhotoDocument(title: "Test", baseImage: asset)
    }

    func testAdjustmentsNeutralAndClamping() {
        var adjustments = Adjustments()
        XCTAssertTrue(adjustments.isNeutral)
        adjustments[.exposure] = 2
        XCTAssertEqual(adjustments[.exposure], 1)
        adjustments[.vignette] = -0.5
        XCTAssertEqual(adjustments[.vignette], 0)
        adjustments.nudge(.exposure, by: -0.5)
        XCTAssertEqual(adjustments[.exposure], 0.5, accuracy: 1e-9)
        adjustments[.exposure] = 0.0001
        XCTAssertTrue(adjustments.isNeutral)
    }

    func testAdjustmentsCodableRoundTrip() throws {
        let adjustments = Adjustments([.contrast: 0.3, .temperature: -0.2])
        let data = try JSONEncoder().encode(adjustments)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: data)
        XCTAssertEqual(decoded, adjustments)
    }

    func testEditStackResolvesLatestAdjustment() {
        var stack = EditStack()
        stack.setAdjustment(.exposure, value: 0.2)
        stack.setAdjustment(.exposure, value: 0.4)
        XCTAssertEqual(stack.operations.count, 1, "consecutive slider updates coalesce")
        stack.append(.adjust(.contrast, value: 0.1))
        stack.setAdjustment(.exposure, value: 0.6)
        XCTAssertEqual(stack.operations.count, 3)
        XCTAssertEqual(stack.resolvedAdjustments[.exposure], 0.6)
        XCTAssertEqual(stack.resolvedAdjustments[.contrast], 0.1)
        stack.append(.look(.mono, intensity: 1))
        XCTAssertEqual(stack.resolvedLook?.preset, .mono)
        stack.append(.look(.original, intensity: 1))
        XCTAssertNil(stack.resolvedLook)
    }

    func testCropUpdatesCanvasSize() {
        var document = makeDocument()
        document.apply(.crop(PSRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(document.canvasSize, PSSize(width: 2000, height: 3000))
        document.apply(.rotate(degrees: 90))
        XCTAssertEqual(document.canvasSize, PSSize(width: 3000, height: 2000))
        XCTAssertEqual(document.baseLayer?.edits.resolvedRotation, 90)
    }

    func testLayerManagement() {
        var document = makeDocument()
        let text = Layer(name: "Title", content: .text(TextElement(text: "Hello")))
        document.addLayer(text)
        XCTAssertEqual(document.layers.count, 2)
        XCTAssertEqual(document.selectedLayerID, text.id)
        XCTAssertEqual(document.activeImageLayerID, document.baseLayerID, "voice commands still target the photo")
        XCTAssertNil(document.removeLayer(id: document.baseLayerID!), "base photo cannot be deleted")
        XCTAssertNotNil(document.removeLayer(id: text.id))
        XCTAssertEqual(document.layers.count, 1)
    }

    func testDocumentCodableRoundTrip() throws {
        var document = makeDocument()
        document.apply(.adjust(.saturation, value: 0.3))
        document.apply(.removeObject(MaskReference(source: .object(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)))))
        document.addLayer(Layer(name: "Text", content: .text(TextElement(text: "Sunset", color: .yellow))))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let decoded = try decoder.decode(PhotoDocument.self, from: data)
        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.baseLayer?.edits.operations.count, 2)
        XCTAssertEqual(decoded.activeAdjustments[.saturation], 0.3)
    }

    func testHistoryUndoRedoAndTransactions() {
        var history = EditHistory(initial: 0, limit: 3)
        history.commit(1, label: "one")
        history.commit(2, label: "two")
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo(), "two")
        XCTAssertEqual(history.present, 1)
        XCTAssertEqual(history.redo(), "two")
        XCTAssertEqual(history.present, 2)
        history.beginTransaction(label: "drag")
        history.commit(3, label: "x")
        history.commit(4, label: "x")
        history.commit(5, label: "x")
        history.endTransaction()
        XCTAssertEqual(history.present, 5)
        XCTAssertEqual(history.undoLabel, "drag")
        history.undo()
        XCTAssertEqual(history.present, 2, "transaction collapses into a single step")
        history.commit(6, label: "a")
        history.commit(7, label: "b")
        history.commit(8, label: "c")
        history.commit(9, label: "d")
        XCTAssertEqual(history.count, 3, "history is bounded")
        history.beginTransaction(label: "cancelled")
        history.commit(100, label: "x")
        history.cancelTransaction()
        XCTAssertEqual(history.present, 9)
    }

    func testFilterMatching() {
        XCTAssertEqual(FilterPreset.matching("noir et blanc"), .mono)
        XCTAssertEqual(FilterPreset.matching("Black And White"), .mono)
        XCTAssertEqual(FilterPreset.matching("cinématique"), .cinematic)
        XCTAssertEqual(FilterPreset.matching("golden hour"), .goldenHour)
        XCTAssertEqual(FilterPreset.matching("heure dorée"), .goldenHour)
        XCTAssertEqual(FilterPreset.matching("vintage"), .vintage)
        XCTAssertNil(FilterPreset.matching("zzz"))
    }

    func testAspectMatchingAndCrop() {
        XCTAssertEqual(AspectPreset.matching("carré"), .square)
        XCTAssertEqual(AspectPreset.matching("16:9"), .ratio16x9)
        XCTAssertEqual(AspectPreset.matching("format story"), .ratio9x16)
        XCTAssertEqual(AspectPreset.matching("4 par 5"), .ratio4x5)
        let rect = AspectPreset.square.cropRect(in: PSSize(width: 4000, height: 3000))
        XCTAssertEqual(rect.width, 0.75, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 1)
        XCTAssertEqual(rect.minX, 0.125, accuracy: 1e-9)
    }

    func testProjectStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        let project = Project(content: .photo(makeDocument()))
        try store.save(project)
        let loaded = try store.load(id: project.id)
        XCTAssertEqual(loaded.title, "Test")
        XCTAssertEqual(store.listProjects().count, 1)
        try store.delete(id: project.id)
        XCTAssertTrue(store.listProjects().isEmpty)
        XCTAssertThrowsError(try store.load(id: project.id))
    }
}
