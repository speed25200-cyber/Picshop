import XCTest
@testable import PicshopCore

/// The document's selection (D7): its Codable layout, lenient decoding, alignment, its raster as a mask
/// component, and how geometry moves it.
final class PhotoSelectionTests: XCTestCase {
    private let layerID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000B1")!

    private func selection(box: PSRect = PSRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), corners: [PSPoint] = RasterRef.unitCorners) -> PhotoSelection {
        PhotoSelection(mask: MaskReference(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000B2")!, source: .region("selection"), boundingBox: box, feather: 0.003),
                       layerID: layerID, steps: [SelectionStep(.subject), SelectionStep(.object, mode: .subtract, label: "cup")],
                       refinement: .automatic, coverage: 0.25, pixelWidth: 1536, pixelHeight: 1024, corners: corners)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func testTheFrozenLayout() throws {
        let json = String(decoding: try encoder().encode(selection()), as: UTF8.self)
        for key in [#""mask":"#, #""layerID":"#, #""steps":"#, #""refinement":"#, #""coverage":0.25"#, #""pixelWidth":1536"#, #""pixelHeight":1024"#, #""corners":"#] {
            XCTAssertTrue(json.contains(key), key)
        }
        XCTAssertTrue(json.contains(#"{"label":"cup","mode":"subtract","source":"object"}"#), json)
        XCTAssertTrue(json.contains(#"{"source":"subject"}"#), json)
        let decoded = try JSONDecoder().decode(PhotoSelection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, selection())
        XCTAssertEqual(SelectionRefinement.automatic, SelectionRefinement(radius: 0.3, smooth: 0.15))
        XCTAssertEqual(PhotoSelection.workingLongestSide, 1536)
    }

    func testAMinimalSelectionDecodesWithDefaults() throws {
        let mask = String(decoding: try encoder().encode(MaskReference(source: .lasso([.zero, PSPoint(x: 1, y: 0), PSPoint(x: 1, y: 1)]))), as: UTF8.self)
        let json = #"{"layerID":"\#(layerID.uuidString)","mask":\#(mask)}"#
        let decoded = try JSONDecoder().decode(PhotoSelection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.steps, [])
        XCTAssertNil(decoded.refinement)
        XCTAssertEqual(decoded.coverage, 0)
        XCTAssertEqual(decoded.corners, RasterRef.unitCorners)
        XCTAssertTrue(decoded.isAligned)
        // Malformed corners fall back to the unit square; an unreadable refinement is left out.
        let odd = #"{"corners":[{"x":0,"y":0}],"layerID":"\#(layerID.uuidString)","mask":\#(mask),"refinement":{"radius":"wide"}}"#
        let lenient = try JSONDecoder().decode(PhotoSelection.self, from: Data(odd.utf8))
        XCTAssertEqual(lenient.corners, RasterRef.unitCorners)
        XCTAssertNil(lenient.refinement)
        // Without a layer it cannot be placed: an error (the document then opens without it).
        XCTAssertThrowsError(try JSONDecoder().decode(PhotoSelection.self, from: Data(#"{"mask":\#(mask)}"#.utf8)))
    }

    func testOnlyTwelveStepsAreKeptByConvention() {
        XCTAssertEqual(PhotoSelection.maxSteps, 12)
    }

    func testTheRasterAsAMaskComponent() {
        let moved = selection(corners: [PSPoint(x: 0.1, y: 0), PSPoint(x: 1.1, y: 0), PSPoint(x: 1.1, y: 1), PSPoint(x: 0.1, y: 1)])
        XCTAssertFalse(moved.isAligned)
        let raster = moved.raster
        XCTAssertEqual(raster.origin, .selection)
        XCTAssertEqual(raster.path, moved.mask.relativePath)
        XCTAssertEqual(raster.corners, moved.corners)
        XCTAssertEqual(raster.pixelWidth, 1536)
        XCTAssertEqual(raster.bitDepth, 8)
        XCTAssertEqual(raster.boundingBox, moved.mask.boundingBox)
        // As a legacy mask: the same file, no feather, a region source.
        XCTAssertEqual(raster.maskReference.relativePath, moved.mask.relativePath)
        XCTAssertEqual(raster.maskReference.feather, 0)
        XCTAssertEqual(raster.maskReference.source, .region("selection"))
    }

    func testRemappingMovesTheCornersAndEstimatesCoverage() throws {
        let original = selection()
        // Shift right by a quarter (as a crop of x 0.25…1 would): the box stays inside.
        let crop = EditOperation.Kind.crop(PSRect(x: 0.25, y: 0, width: 0.75, height: 1)).geometryMap(aspectBefore: 1.5)!
        let remapped = try XCTUnwrap(original.remapped(by: crop))
        XCTAssertEqual(remapped.corners[0].x, -1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(remapped.corners[1].x, 1, accuracy: 1e-12)
        // The quad grew by 4/3 and the box (0.25…0.75 → 0…2/3) is all on the canvas.
        XCTAssertEqual(remapped.coverage, 0.25 * 4 / 3, accuracy: 1e-12)
        XCTAssertEqual(remapped.mask, original.mask)
        XCTAssertEqual(remapped.steps, original.steps)
        // A crop that cuts the box in half halves the estimate's share.
        let half = EditOperation.Kind.crop(PSRect(x: 0.5, y: 0, width: 0.5, height: 1)).geometryMap(aspectBefore: 1.5)!
        XCTAssertEqual(try XCTUnwrap(original.remapped(by: half)).coverage, 0.25 * 2 * 0.5, accuracy: 1e-12)
        // A crop past the box: gone.
        let away = EditOperation.Kind.crop(PSRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)).geometryMap(aspectBefore: 1.5)!
        XCTAssertNil(original.remapped(by: away))
        // A quarter turn keeps the coverage.
        let turn = EditOperation.Kind.rotate(degrees: 90).geometryMap(aspectBefore: 1.5)!
        XCTAssertEqual(try XCTUnwrap(original.remapped(by: turn)).coverage, 0.25, accuracy: 1e-12)
    }

    func testSettingTheSelectionTouchesTheDocument() {
        var document = PhotoDocument(title: "Sel", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 300, height: 200)))
        document.modifiedAt = Date(timeIntervalSince1970: 0)
        document.setSelection(selection())
        XCTAssertGreaterThan(document.modifiedAt, Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(document.selection)
        document.setSelection(nil)
        XCTAssertNil(document.selection)
    }
}
