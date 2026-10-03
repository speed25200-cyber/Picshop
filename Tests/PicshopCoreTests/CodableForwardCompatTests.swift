import XCTest
@testable import PicshopCore

/// An operation kind written by a newer build survives an older one: decoded as
/// `.unsupported` with its JSON, drawn as nothing, written back unchanged.
final class CodableForwardCompatTests: XCTestCase {
    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private let futureKind = #"{"localAdjust":{"_0":{"components":[{"mode":"add","radius":0.25}],"invert":false},"_1":{"exposure":0.3},"curve":null}}"#

    private func operationJSON(kind: String) -> String {
        #"{"createdAt":"2026-10-01T10:00:00Z","id":"0A1B2C3D-0000-4000-8000-000000000001","kind":"# + kind + #","label":"Local Adjust"}"#
    }

    func testAnUnknownKindIsKeptAsJSON() throws {
        let operation = try decoder().decode(EditOperation.self, from: Data(operationJSON(kind: futureKind).utf8))
        guard case .unsupported(let json) = operation.kind else { return XCTFail("\(operation.kind)") }
        XCTAssertTrue(json.hasPrefix(#"{"localAdjust":"#), json)
        XCTAssertEqual(operation.label, "Local Adjust")
        XCTAssertFalse(operation.kind.isGeometric)
        XCTAssertFalse(operation.kind.isExpensive)
    }

    func testAnUnknownKindIsWrittenBackByteForByte() throws {
        let original = Data(operationJSON(kind: futureKind).utf8)
        let operation = try decoder().decode(EditOperation.self, from: original)
        let written = try sortedEncoder().encode(operation)
        XCTAssertEqual(String(decoding: written, as: UTF8.self), String(decoding: original, as: UTF8.self))
        // And again, after a second trip.
        let again = try sortedEncoder().encode(try decoder().decode(EditOperation.self, from: written))
        XCTAssertEqual(again, written)
    }

    func testADocumentWithAnUnknownKindRoundTrips() throws {
        var document = PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        document.apply(.adjust(.exposure, value: 0.2))
        document.apply(.unsupported(#"{"localAdjust":{"_0":{"invert":true}}}"#))
        document.apply(.levels(Levels(rgb: Levels.Channel(inBlack: 0.05, inWhite: 0.95, gamma: 1.2))))
        let first = try sortedEncoder().encode(document)
        let decoded = try decoder().decode(PhotoDocument.self, from: first)
        // ISO 8601 keeps whole seconds, so the dates are compared through the bytes.
        XCTAssertEqual(try sortedEncoder().encode(decoded), first)
        XCTAssertEqual(decoded.baseLayer?.edits.operations.map(\.kind), document.baseLayer?.edits.operations.map(\.kind))
        XCTAssertEqual(decoded.baseLayer?.edits.resolvedLevels.rgb.gamma, 1.2)
        XCTAssertEqual(decoded.baseLayer?.edits.resolvedAdjustments[.exposure], 0.2)
    }

    func testKnownKindsKeepTheSynthesizedLayout() throws {
        // As every build before W1 wrote them.
        let json = operationJSON(kind: #"{"adjust":{"_0":"exposure","value":0.25}}"#)
        let operation = try decoder().decode(EditOperation.self, from: Data(json.utf8))
        XCTAssertEqual(operation.kind, .adjust(.exposure, value: 0.25))
        XCTAssertEqual(String(decoding: try sortedEncoder().encode(operation), as: UTF8.self), json)
    }

    func testAKindThatIsNotAnObjectIsStillAnError() {
        XCTAssertThrowsError(try decoder().decode(EditOperation.self, from: Data(operationJSON(kind: "42").utf8)))
        XCTAssertThrowsError(try decoder().decode(EditOperation.self, from: Data(operationJSON(kind: #""crop""#).utf8)))
    }
}
