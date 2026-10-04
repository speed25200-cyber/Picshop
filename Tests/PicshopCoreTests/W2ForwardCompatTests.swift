import XCTest
@testable import PicshopCore

/// Documents across builds (D7, §5 Codable): a malformed `localAdjust` stays `.unsupported`, a W1 build keeps a W2
/// local adjustment as JSON and writes it back, a selection this build cannot read never stops a document from
/// opening, and the W2 additions to W1 types are absent when unset.
final class W2ForwardCompatTests: XCTestCase {
    private func encoder() -> JSONEncoder {
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

    private func operationJSON(kind: String) -> String {
        #"{"createdAt":"2026-10-01T10:00:00Z","id":"0A1B2C3D-0000-4000-8000-000000000001","kind":"# + kind + #","label":"Local Adjust"}"#
    }

    /// The two payloads W1's CodableForwardCompatTests used as a fake "localAdjust": neither has `id` nor
    /// `stack`, so they stay `.unsupported` and are written back byte for byte.
    func testTheW1LocalAdjustFixturesStayUnsupported() throws {
        for kind in [#"{"localAdjust":{"_0":{"components":[{"mode":"add","radius":0.25}],"invert":false},"_1":{"exposure":0.3},"curve":null}}"#,
                     #"{"localAdjust":{"_0":{"invert":true}}}"#] {
            let original = operationJSON(kind: kind)
            let operation = try decoder().decode(EditOperation.self, from: Data(original.utf8))
            guard case .unsupported(let json) = operation.kind else { return XCTFail("\(operation.kind)") }
            XCTAssertTrue(json.hasPrefix(#"{"localAdjust":"#))
            let written = try encoder().encode(operation)
            XCTAssertEqual(String(decoding: written, as: UTF8.self), original)
            XCTAssertEqual(try encoder().encode(try decoder().decode(EditOperation.self, from: written)), written)
        }
    }

    /// A W2 document's local adjustment, read by a W1 build (simulated: the same decoding path with W1's kinds),
    /// is kept as `.unsupported` and written back unchanged, so a round trip through W1 loses nothing but the
    /// selection.
    func testAW1BuildKeepsAW2LocalAdjustment() throws {
        var document = PhotoDocument(title: "W2", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        document.apply(.adjust(.exposure, value: 0.2))
        document.setLocalAdjustment(LocalAdjustment(region: .sky, stack: .single(MaskComponent(.linear(LinearGradientSpec(start: .zero, end: PSPoint(x: 0, y: 0.5))))),
                                                    adjustments: Adjustments([.exposure: -0.3])), label: "Mask: Ciel")
        let operations = try encoder().encode(document.baseLayer!.edits.operations)
        let w1 = try decoder().decode([W1Operation].self, from: operations)
        XCTAssertEqual(w1.count, 2)
        XCTAssertEqual(w1[0].kind, .adjust(.exposure, value: 0.2))
        guard case .unsupported(let json) = w1[1].kind else { return XCTFail("\(w1[1].kind)") }
        XCTAssertTrue(json.hasPrefix(#"{"localAdjust":{"_0":{"#), json)
        // Written back by W1, read again by W2: the same local adjustment.
        let backAgain = try encoder().encode(w1)
        XCTAssertEqual(backAgain, operations)
        let reread = try decoder().decode([EditOperation].self, from: backAgain)
        XCTAssertEqual(reread.map(\.kind), document.baseLayer!.edits.operations.map(\.kind))
    }

    /// A selection with an unknown step source keeps its other steps; one whose mask has an unknown MaskSource
    /// cannot be read, and the document opens with no selection.
    func testUnreadableSelectionsNeverStopADocument() throws {
        var document = PhotoDocument(title: "Sel", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        document.setSelection(PhotoSelection(mask: MaskReference(source: .subject, feather: 0.003), layerID: document.baseLayerID!,
                                             steps: [SelectionStep(.subject), SelectionStep(.wand, mode: .add)], coverage: 0.3, pixelWidth: 1536, pixelHeight: 1152))
        let text = String(decoding: try encoder().encode(document), as: UTF8.self)
        // A newer step source: that step is dropped, the rest of the selection stays.
        let newerStep = text.replacingOccurrences(of: #"{"source":"subject"}"#, with: #"{"source":"magneticLasso"}"#)
        XCTAssertNotEqual(newerStep, text)
        let partial = try decoder().decode(PhotoDocument.self, from: Data(newerStep.utf8))
        XCTAssertEqual(partial.selection?.steps, [SelectionStep(.wand, mode: .add)])
        // Plus a newer MaskSource on the mask: no selection, and the document still opens.
        let newerSource = newerStep.replacingOccurrences(of: #""source":{"subject":{}}"#, with: #""source":{"channel":{"name":"alpha 1"}}"#)
        XCTAssertNotEqual(newerSource, newerStep)
        let opened = try decoder().decode(PhotoDocument.self, from: Data(newerSource.utf8))
        XCTAssertNil(opened.selection)
        XCTAssertEqual(opened.layers.map(\.id), document.layers.map(\.id))
        // A selection that is not even an object: still no selection, still a document.
        let garbage = text.replacingOccurrences(of: #""selection":{"#, with: #""selection":42,"ignored":{"#)
        XCTAssertNil(try decoder().decode(PhotoDocument.self, from: Data(garbage.utf8)).selection)
    }

    func testFlowAndAutoMaskAbsentAndPresent() throws {
        // Absent: W1 strokes decode with flow nil and encode without it.
        let w1Stroke = #"{"hardness":0.7,"id":"22222222-2222-4222-8222-222222222222","mode":"add","points":[{"x":0.1,"y":0.2}],"radius":0.05}"#
        let stroke = try decoder().decode(BrushStroke.self, from: Data(w1Stroke.utf8))
        XCTAssertNil(stroke.flow)
        XCTAssertEqual(String(decoding: try encoder().encode(stroke), as: UTF8.self), w1Stroke)
        // Present.
        var flowing = stroke
        flowing.flow = 0.4
        let json = String(decoding: try encoder().encode(flowing), as: UTF8.self)
        XCTAssertTrue(json.contains(#""flow":0.4"#), json)
        XCTAssertEqual(try decoder().decode(BrushStroke.self, from: Data(json.utf8)).flow, 0.4)
        // BrushSpec.autoMask: absent is false; present round-trips.
        XCTAssertFalse(try decoder().decode(BrushSpec.self, from: Data(#"{"strokes":[]}"#.utf8)).autoMask)
        XCTAssertTrue(try decoder().decode(BrushSpec.self, from: Data(#"{"autoMask":true,"strokes":[]}"#.utf8)).autoMask)
        XCTAssertEqual(try decoder().decode(BrushSpec.self, from: Data(#"{"strokes":[\#(json)]}"#.utf8)).strokes, [flowing])
        // MaskReference.decontaminate likewise.
        let reference = MaskReference(source: .subject, decontaminate: 0.6)
        XCTAssertTrue(String(decoding: try encoder().encode(reference), as: UTF8.self).contains(#""decontaminate":0.6"#))
        XCTAssertEqual(try decoder().decode(MaskReference.self, from: try encoder().encode(reference)).decontaminate, 0.6)
    }

    func testAW1DocumentHasNoSelectionAndNoMasks() throws {
        let document = try decoder().decode(PhotoDocument.self, from: Data(W2SeamTests.w1Document.utf8))
        XCTAssertNil(document.selection)
        XCTAssertTrue(document.localAdjustments.isEmpty)
        XCTAssertEqual(String(decoding: try encoder().encode(document), as: UTF8.self), W2SeamTests.w1Document)
    }
}

/// An edit operation as a W1 build decodes it: the same Codable logic as `EditOperation`, with a kind enum that
/// has no `localAdjust` (a few W1 cases are enough: anything else fails and is kept as JSON).
private struct W1Operation: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case adjust(AdjustmentParameter, value: Double)
        case crop(PSRect)
        case unsupported(String)
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date
    var label: String

    private enum CodingKeys: String, CodingKey { case id, kind, createdAt, label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        label = try container.decode(String.self, forKey: .label)
        do {
            kind = try container.decode(Kind.self, forKey: .kind)
        } catch let error as DecodingError {
            guard let raw = try? container.decode(OpaqueJSON.self, forKey: .kind), case .object = raw, let text = raw.text else { throw error }
            kind = .unsupported(text)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if case .unsupported(let text) = kind, let raw = OpaqueJSON(text: text) {
            try container.encode(raw, forKey: .kind)
        } else {
            try container.encode(kind, forKey: .kind)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(label, forKey: .label)
    }
}
