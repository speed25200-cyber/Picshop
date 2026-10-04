import XCTest
@testable import PicshopCore

/// The W3 seam (Day 0): the document v2 Codable layouts are final and forward compatible (D2): W1 and W2 documents
/// decode unchanged and write back byte for byte under sorted keys, every v2 key round-trips and is absent at its
/// default, unknown keys and content kinds are kept, the envelope header reads a newer file whatever it holds,
/// export presets decode with their defaults, and the 14 W3 flags and the "g" ref exist. L1 owns this file after the seam;
/// the behaviour checks below follow W3 (L1).
final class W3SeamTests: XCTestCase {
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

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    /// Decodes, checks equality, and checks the bytes are stable on a second trip.
    private func assertRoundTrips<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let first = try encoder().encode(value)
        let decoded = try decoder().decode(T.self, from: first)
        XCTAssertEqual(decoded, value, file: file, line: line)
        XCTAssertEqual(try encoder().encode(decoded), first, file: file, line: line)
    }

    private let asset = MediaAsset(id: UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!, kind: .image, relativePath: "media/base.heic",
                                   pixelSize: PSSize(width: 4032, height: 3024))

    // MARK: Layer and LayerTransform

    func testALayerWithEveryV2FieldRoundTrips() throws {
        let stack = MaskStack(components: [MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2)))],
                              feather: 0.1)
        var layer = Layer(name: "Tasse", content: .image(asset), opacity: 0.8, blendMode: .multiply,
                          fillOpacity: 0.5, maskStack: stack, isMaskEnabled: false, isMaskLinked: false, isClipped: true,
                          lockOptions: [.position, .transparency], parentID: UUID(), recipeKind: .curves, refNumber: 3)
        layer.bakedMask = MaskReference(source: .region("layer"))
        layer.transform = LayerTransform(center: PSPoint(x: 0.4, y: 0.6), scale: 0.9, rotation: 12, scaleX: 1.2, scaleY: 0.8, skewX: 10, skewY: -5,
                                         quad: [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.9, y: 0.15), PSPoint(x: 0.85, y: 0.9), PSPoint(x: 0.12, y: 0.8)])
        try assertRoundTrips(layer)
        let text = try json(layer)
        for key in ["\"fill\":", "\"maskStack\":", "\"maskEnabled\":false", "\"maskLinked\":false", "\"clipped\":true", "\"lock\":5", "\"parent\":",
                    "\"recipeKind\":\"curves\"", "\"bakedMask\":", "\"ref\":3", "\"scaleX\":1.2", "\"skewY\":-5", "\"quad\":"] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertTrue(layer.usesV2State)
    }

    func testDefaultV2FieldsAreNotWritten() throws {
        let layer = Layer(id: UUID(uuidString: "E5555555-5555-4555-8555-555555555551")!, name: "Photo", content: .image(asset))
        let text = try json(layer)
        for key in ["\"fill\"", "maskStack", "maskEnabled", "maskLinked", "clipped", "\"lock\"", "\"parent\"", "recipeKind", "bakedMask", "\"ref\"",
                    "scaleX", "scaleY", "skewX", "skewY", "quad"] {
            XCTAssertFalse(text.contains(key), key)
        }
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).keys),
                       ["id", "name", "content", "transform", "opacity", "blendMode", "isVisible", "isLocked", "edits"])
        XCTAssertFalse(layer.usesV2State)
        // A stored ref number and a baked mask alone are not v2 state (D2, D19).
        var numbered = layer
        numbered.refNumber = 1
        numbered.bakedMask = MaskReference(source: .subject)
        XCTAssertFalse(numbered.usesV2State)
    }

    func testLayerTransformV2FieldsDecodeWithDefaultsAndABadQuadIsNil() throws {
        let w1 = #"{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1}"#
        let decoded = try decoder().decode(LayerTransform.self, from: Data(w1.utf8))
        XCTAssertEqual(decoded, .identity)
        XCTAssertTrue(decoded.isAffineIdentityExtras)
        XCTAssertEqual(try json(decoded), w1)
        let three = #"{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"quad":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1}],"rotation":0,"scale":1,"skewX":4}"#
        let lenient = try decoder().decode(LayerTransform.self, from: Data(three.utf8))
        XCTAssertNil(lenient.quad)
        XCTAssertEqual(lenient.skewX, 4)
        XCTAssertFalse(lenient.isAffineIdentityExtras)
        try assertRoundTrips(LayerTransform(scaleX: 2, scaleY: 0.5, skewX: 30, skewY: -30, quad: RasterRef.unitCorners))
    }

    func testTheNewContentsAndModelValuesRoundTrip() throws {
        try assertRoundTrips(Layer(name: "Groupe 1", content: .group(LayerFolder(passThrough: false, isCollapsed: true))))
        try assertRoundTrips(Layer(name: "Dégradé", content: .gradientFill(.twoColor(.red, .blue, style: .radial, angle: 30))))
        try assertRoundTrips(LayerFolder())
        try assertRoundTrips(GradientFill.blackToTransparent)
        XCTAssertEqual(try json(GradientStop(location: 0.25, color: .white)), #"{"at":0.25,"color":{"alpha":1,"blue":1,"green":1,"red":1}}"#)
        XCTAssertEqual(try json(LayerLockOptions.all), "7")
        // Unknown lock bits are kept as read.
        XCTAssertEqual(try decoder().decode(LayerLockOptions.self, from: Data("13".utf8)).rawValue, 13)
        // A folder and a gradient with missing keys take the init defaults; an unknown style is linear; stops are sorted and 2…8.
        XCTAssertEqual(try decoder().decode(LayerFolder.self, from: Data("{}".utf8)), LayerFolder())
        let gradient = try decoder().decode(GradientFill.self, from: Data(#"{"style":"diamond","stops":[{"at":1,"color":{"alpha":1,"blue":0,"green":0,"red":1}},{"at":0,"color":{"alpha":1,"blue":1,"green":0,"red":0}}]}"#.utf8))
        XCTAssertEqual(gradient.style, .linear)
        XCTAssertEqual(gradient.stops.map(\.location), [0, 1])
        XCTAssertEqual(gradient.angle, 90)
        XCTAssertEqual(gradient.scale, 100)
        XCTAssertTrue(gradient.dither)
        XCTAssertEqual(try decoder().decode(GradientFill.self, from: Data("{}".utf8)).stops, GradientFill.blackToTransparent.stops)
        XCTAssertEqual(GradientFill.normalizedStops(Array(repeating: GradientStop(location: 0.5, color: .white), count: 11)).count, 8)
        XCTAssertEqual(AdjustmentLayerKind.allCases.map(\.frenchName),
                       ["Lumière", "Courbes", "Niveaux", "Teinte/Saturation", "Étalonnage", "LUT", "Look"])
        // An unknown recipe kind decodes as nil.
        var layer = Layer(name: "Courbes", content: .adjustment(.neutral), recipeKind: .curves)
        let text = try json(layer).replacingOccurrences(of: #""recipeKind":"curves""#, with: #""recipeKind":"posterize""#)
        layer = try decoder().decode(Layer.self, from: Data(text.utf8))
        XCTAssertNil(layer.recipeKind)
    }

    // MARK: Forward compatibility (D2)

    func testAnUnknownContentKindIsKeptVerbatim() throws {
        let original = #"{"blendMode":"normal","content":{"smartObject":{"_0":{"source":"media\/x.psb","z":[1,2]}}},"edits":{"operations":[]},"#
            + #""id":"E5555555-5555-4555-8555-555555555559","isLocked":false,"isVisible":true,"name":"Objet","opacity":1,"#
            + #""transform":{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1}}"#
        let layer = try decoder().decode(Layer.self, from: Data(original.utf8))
        guard case .unsupported(let raw) = layer.content else { return XCTFail("expected .unsupported, got \(layer.content)") }
        XCTAssertEqual(raw, #"{"smartObject":{"_0":{"source":"media/x.psb","z":[1,2]}}}"#)
        XCTAssertEqual(try json(layer), original)
        XCTAssertTrue(layer.usesV2State)
        XCTAssertEqual(layer.symbolName, "questionmark.square.dashed")
        XCTAssertNil(layer.overlayRasterKey)
    }

    func testUnknownLayerAndDocumentKeysAreWrittenBack() throws {
        var document = try decoder().decode(PhotoDocument.self, from: Data(Self.w2Document.utf8))
        XCTAssertEqual(document.retainedFields, [:])
        // "zStyles" sorts after every known key, so the sorted re-encoding puts it back at the end.
        let layerText = try json(document.layers[0]).dropLast() + #","zStyles":{"dropShadow":{"opacity":0.5}}}"#
        let layer = try decoder().decode(Layer.self, from: Data(layerText.utf8))
        XCTAssertEqual(layer.retainedFields, ["zStyles": #"{"dropShadow":{"opacity":0.5}}"#])
        XCTAssertEqual(try json(layer), String(layerText))
        XCTAssertTrue(layer.usesV2State)
        document.layers[0] = layer
        let documentText = try json(document).dropLast() + #","zGuides":[0.25,0.75]}"#
        let reread = try decoder().decode(PhotoDocument.self, from: Data(documentText.utf8))
        XCTAssertEqual(reread.retainedFields, ["zGuides": "[0.25,0.75]"])
        XCTAssertEqual(try json(reread), String(documentText))
    }

    func testW1AndW2DocumentsDecodeUnchangedAndWriteBackByteForByte() throws {
        for fixture in [W2SeamTests.w1Document, Self.w2Document] {
            let document = try decoder().decode(PhotoDocument.self, from: Data(fixture.utf8))
            XCTAssertEqual(document.formatVersion, 1, "decoding never migrates")
            XCTAssertEqual(document.retainedFields, [:])
            XCTAssertTrue(document.layers.allSatisfy { !$0.usesV2State && $0.refNumber == nil })
            XCTAssertEqual(try json(document), fixture)
        }
        let w2 = try decoder().decode(PhotoDocument.self, from: Data(Self.w2Document.utf8))
        XCTAssertEqual(w2.layers.count, 5)
        XCTAssertNotNil(w2.selection)
        XCTAssertEqual(w2.localAdjustments.count, 1)
        XCTAssertEqual(w2.layers[1].group?.kind, .tableCells)
        XCTAssertTrue(w2.layers[2].isLocked)
        XCTAssertEqual(w2.layers[2].ownLock, .all)
        XCTAssertNotNil(w2.layers[3].mask)
    }

    // MARK: Envelope and store (D2)

    func testTheEnvelopeRoundTripsAndItsHeaderReadsANewerFile() throws {
        let document = try decoder().decode(PhotoDocument.self, from: Data(Self.w2Document.utf8))
        let envelope = PhotoDocumentEnvelope(document: DocumentCodec.migrated(document), v1Digest: DocumentCodec.digest(Data("{}".utf8)), writer: "PicShop")
        XCTAssertEqual(envelope.format, "picshop.photo")
        XCTAssertEqual(envelope.formatVersion, 2)
        XCTAssertEqual(envelope.minorVersion, 0)
        XCTAssertEqual(envelope.v1Digest, "2-" + StableHash.hex("{}"))
        let data = try encoder().encode(envelope)
        let decoded = try decoder().decode(PhotoDocumentEnvelope.self, from: data)
        XCTAssertEqual(decoded.document, envelope.document)
        XCTAssertEqual(try encoder().encode(decoded), data)
        XCTAssertEqual(try decoder().decode(PhotoDocumentEnvelopeHeader.self, from: data),
                       PhotoDocumentEnvelopeHeader(format: "picshop.photo", formatVersion: 2, minorVersion: 0, v1Digest: envelope.v1Digest))
        // A newer build's file: its document is not a v2 document, the header still reads.
        let newer = #"{"document":{"pages":"not a photo document"},"format":"picshop.photo","formatVersion":3,"minorVersion":1,"v1Digest":"5-0000000000000000","writer":"PicShop 9"}"#
        XCTAssertThrowsError(try decoder().decode(PhotoDocumentEnvelope.self, from: Data(newer.utf8)))
        let header = try decoder().decode(PhotoDocumentEnvelopeHeader.self, from: Data(newer.utf8))
        XCTAssertEqual(header.formatVersion, 3)
        XCTAssertEqual(header.minorVersion, 1)
        XCTAssertEqual(header.v1Digest, "5-0000000000000000")
        XCTAssertEqual(Project.documentV2Name, "document-v2.json")
    }

    func testTheStoreWritesFormatOneAndLoadsFormatTwo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-w3seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        let document = PhotoDocument(title: "Seam", baseImage: asset)
        XCTAssertEqual(document.formatVersion, 2)
        let project = Project(content: .photo(document))
        try store.save(project)
        let manifest = try Data(contentsOf: store.manifestURL(for: project.id))
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains(#""formatVersion":1"#), "project.json keeps the v1 projection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.documentV2URL(for: project.id).path), "the seam never writes document-v2.json")
        XCTAssertNil(store.documentV2Header(for: project.id))
        let (loaded, source) = try store.loadWithSource(id: project.id)
        XCTAssertEqual(source, .v1)
        XCTAssertEqual(loaded.photoDocument?.formatVersion, 2)
        // Loading migrates: the base photo gets its stored ref (i0, D19), nothing else changes.
        XCTAssertEqual(loaded.photoDocument?.layers, DocumentCodec.migrated(document).layers)
        XCTAssertEqual(loaded.photoDocument?.layers.first?.refNumber, 0)
        XCTAssertEqual(try store.collectGarbage(projectID: project.id, keeping: []).files, 0)
    }

    // MARK: Platform and vocabulary

    func testExportPresetsDecodeWithTheirDefaults() throws {
        try assertRoundTrips(ExportPreset.instagram)
        try assertRoundTrips(ExportPreset.print)
        try assertRoundTrips(ExportPreset.web)
        try assertRoundTrips(ExportPreset(format: .psd, bitDepth: 16, size: .longSide(4096), layered: false))
        let minimal = try decoder().decode(ExportPreset.self, from: Data(#"{"format":"png"}"#.utf8))
        XCTAssertEqual(minimal, ExportPreset(format: .png))
        XCTAssertEqual(minimal.bitDepth, 8)
        XCTAssertEqual(minimal.colorSpace, "displayP3")
        XCTAssertEqual(minimal.size, .full)
        XCTAssertEqual(minimal.quality, 0.92)
        XCTAssertTrue(minimal.layered)
        XCTAssertTrue(minimal.keepsLocation)
        XCTAssertNil(minimal.resolution)
        XCTAssertNil(minimal.name)
        XCTAssertThrowsError(try decoder().decode(ExportPreset.self, from: Data(#"{"bitDepth":16}"#.utf8)), "format is required")
        XCTAssertEqual(ExportFileFormat.allCases.filter { !$0.canSaveToPhotos }, [.pdf, .psd])
        XCTAssertEqual(ExportPreset.instagram.size, .width(1080))
        XCTAssertFalse(ExportPreset.instagram.keepsLocation)
    }

    func testTheW3FlagsAndTheGroupRef() {
        let w3: [FeatureFlag] = [.proLayers, .freeTransform, .layersColumn, .paramInspector, .contentHashCache, .interactiveSnapshot, .tiledRendering,
                                 .proExport, .psdExport, .layerOps, .outlineFill, .recipes, .kvEngine, .persistedPrefix]
        XCTAssertEqual(Set(w3).count, 14)
        XCTAssertEqual(FeatureFlag.allCases.count, 31)
        XCTAssertTrue(w3.allSatisfy(\.releaseDefault))
        XCTAssertEqual(RefKind.layerGroup.prefix, "g")
        XCTAssertEqual(Set(RefKind.allCases.map(\.prefix)).count, RefKind.allCases.count)
    }

    // MARK: Behaviour the seam keeps

    func testThePlanKeepsTodaysOrderAndTheEditsKeepW2Behaviour() {
        var document = PhotoDocument(title: "Seam", baseImage: asset)
        let text = Layer(name: "Titre", content: .text(TextElement(text: "Titre", center: PSPoint(x: 0.3, y: 0.2), rotation: 10)))
        let hidden = Layer(name: "Caché", content: .fill(.red), isVisible: false)
        let adjustment = Layer(name: "Réglage", content: .adjustment(.neutral))
        let group = Layer(name: "Groupe", content: .group(LayerFolder()))
        for layer in [text, hidden, adjustment, group] { document.addLayer(layer, select: false) }
        let plan = CompositePlan.make(document)
        XCTAssertEqual(plan.flatMap(\.layerIDs), [document.layers[0].id, text.id, adjustment.id])
        if case .adjustment = plan[2] {} else { XCTFail("adjustment layers stay .adjustment") }
        // The text placement rule moved into Core unchanged.
        XCTAssertEqual(LayerPlacement.textPlacement(of: text).center, PSPoint(x: 0.3, y: 0.2))
        XCTAssertEqual(LayerPlacement.textPlacement(of: text).rotation, 10)
        // applyLayerEdit applies the W2 properties, refuses the rest at the seam.
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.5), to: text.id), .applied)
        XCTAssertEqual(document.layer(id: text.id)?.opacity, 0.5)
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.5), to: text.id), .unchanged)
        // W3: clipping onto the photo below; the base itself never clips.
        XCTAssertEqual(document.applyLayerEdit(.clipped(true), to: text.id), .applied)
        XCTAssertEqual(document.applyLayerEdit(.clipped(true), to: document.layers[0].id), .refused(.baseLayer))
        XCTAssertEqual(document.applyLayerEdit(.clipped(false), to: text.id), .applied)
        XCTAssertEqual(document.applyLayerEdit(.visible(false), to: UUID()), .refused(.notFound))
        // Structure edits: add, duplicate and remove as W2; the base cannot be removed.
        let duplicate = document.applyStructureEdit(.duplicate(text.id))
        XCTAssertEqual(duplicate.outcome, .applied)
        XCTAssertEqual(document.selectedLayerID, duplicate.layerID)
        XCTAssertEqual(document.applyStructureEdit(.remove(document.layers[0].id)).outcome, .refused(.baseLayer))
        let grouped = document.applyStructureEdit(.group([text.id], name: nil))
        XCTAssertEqual(grouped.outcome, .applied)
        XCTAssertEqual(document.parent(of: text.id)?.id, grouped.layerID)
        XCTAssertEqual(document.applyStructureEdit(.ungroup(grouped.layerID!)).outcome, .applied)
        // apply and moveLayer report what they did.
        XCTAssertTrue(document.apply(.adjust(.exposure, value: 0.2)))
        XCTAssertFalse(document.apply(.adjust(.exposure, value: 0.2), to: UUID()))
        XCTAssertTrue(document.moveLayer(id: text.id, to: 2))
        XCTAssertFalse(document.moveLayer(id: text.id, to: 99))
        // Locks: the policy table (D7).
        XCTAssertFalse(LayerLockPolicy.allows(.content, lock: [.pixels]))
        XCTAssertTrue(LayerLockPolicy.allows(.placement, lock: [.pixels]))
        XCTAssertFalse(LayerLockPolicy.allows(.alpha, lock: [.transparency]))
        XCTAssertFalse(LayerLockPolicy.allows(.order, lock: .all))
        XCTAssertEqual(LayerLockPolicy.mutation(for: .removeBackground(nil)), .alpha)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .adjust(.exposure, value: 1)), .content)
        XCTAssertEqual(StableHash.fnv1a64(bytes: Data("abc".utf8)), StableHash.fnv1a64("abc"))
        XCTAssertEqual(StableHash.hex(bytes: Data("abc".utf8)), StableHash.hex("abc"))
    }

    /// A photo document with every W2 feature as the W2 build (e043f81) wrote it: sorted keys, ISO 8601 dates; a base
    /// with a local adjustment (raster and linear components), a crop and Levels; a table-cell text layer; a locked,
    /// flipped, multiplied shape; a hidden fill with a legacy mask; an adjustment layer with Levels; a selection.
    static let w2Document = [
        #"{"backgroundColor":{"alpha":0,"blue":0,"green":0,"red":0},"canvasSize":{"height":2419,"width":4032},"createdAt":"#,
        #""2026-09-21T14:13:20Z","formatVersion":1,"id":"99999999-9999-4999-8999-999999999999","layers":[{"blendMode":"nor"#,
        #"mal","content":{"image":{"_0":{"duration":0,"frameRate":0,"id":"A1111111-1111-4111-8111-111111111111","kind":"im"#,
        #"age","origin":{"photoLibrary":{"localIdentifier":"XYZ\/L0\/001"}},"pixelSize":{"height":3024,"width":4032},"rela"#,
        #"tivePath":"media\/base.heic"}}},"edits":{"operations":[{"createdAt":"2026-09-21T14:13:20Z","id":"D4444444-4444-4"#,
        #"444-8444-444444444441","kind":{"adjust":{"_0":"contrast","value":0.2}},"label":"Contrast +20"},{"createdAt":"202"#,
        #"6-09-21T14:13:20Z","id":"D4444444-4444-4444-8444-444444444442","kind":{"crop":{"_0":{"origin":{"x":0,"y":0.1},"s"#,
        #"ize":{"height":0.8,"width":1}}}},"label":"Crop"},{"createdAt":"2026-09-21T14:13:20Z","id":"D4444444-4444-4444-84"#,
        #"44-444444444443","kind":{"localAdjust":{"_0":{"adjustments":{"exposure":-0.35},"amount":0.8,"id":"C3333333-3333-"#,
        #"4333-8333-333333333333","region":"sky","stack":{"components":[{"id":"C3333333-3333-4333-8333-33333333333A","inve"#,
        #"rted":false,"mode":"add","opacity":1,"spec":{"bits":8,"box":{"origin":{"x":0,"y":0},"size":{"height":0.45,"width"#,
        #"":1}},"corners":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"h":1152,"origin":"sky","path":"masks\"#,
        #"/B2222222-2222-4222-8222-222222222222.png","stateKey":"0123456789abcdef","w":1536},"type":"raster"},{"id":"C3333"#,
        #"333-3333-4333-8333-33333333333B","inverted":false,"mode":"intersect","opacity":1,"spec":{"end":{"x":0.5,"y":0.5}"#,
        #","start":{"x":0.5,"y":0}},"type":"linear"}],"density":1,"expand":0,"feather":0.2,"inverted":false},"visible":tru"#,
        #"e}}},"label":"Ciel"},{"createdAt":"2026-09-21T14:13:20Z","id":"D4444444-4444-4444-8444-444444444444","kind":{"le"#,
        #"vels":{"_0":{"blue":{"gamma":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"green":{"gamma":1,"inBlack":0"#,
        #","inWhite":1,"outBlack":0,"outWhite":1},"red":{"gamma":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"rgb"#,
        #"":{"gamma":1.1,"inBlack":0.04,"inWhite":0.96,"outBlack":0,"outWhite":1}}}},"label":"Levels"}]},"id":"E5555555-55"#,
        #"55-4555-8555-555555555551","isLocked":false,"isVisible":true,"name":"Photo","opacity":1,"transform":{"center":{""#,
        #"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1}},{"blendMode":"#,
        #""normal","content":{"text":{"_0":{"alignment":"center","center":{"x":0.61,"y":0.33},"color":{"alpha":1,"blue":1,"#,
        #""green":1,"red":1},"fontName":"SFProRounded-Bold","id":"A7777777-7777-4777-8777-777777777777","letterSpacing":0,"#,
        #""lineSpacing":1.1,"maxRelativeWidth":0.85,"opacity":1,"relativeSize":0.06,"rotation":0,"style":"shadowed","text""#,
        #":"42"}}},"edits":{"operations":[]},"group":{"column":3,"id":"F6666666-6666-4666-8666-666666666666","kind":"table"#,
        #"Cells","row":2},"id":"E5555555-5555-4555-8555-555555555552","isLocked":false,"isVisible":true,"name":"42","opaci"#,
        #"ty":1,"transform":{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotatio"#,
        #"n":0,"scale":1}},{"blendMode":"multiply","content":{"shape":{"_0":{"cornerRadius":0.02,"fill":{"alpha":1,"blue":"#,
        #"0,"green":0.8,"red":1},"kind":"roundedRectangle","relativeSize":{"height":0.2,"width":0.4},"stroke":{"alpha":1,""#,
        #"blue":0,"green":0,"red":0},"strokeWidth":0.01}}},"edits":{"operations":[]},"id":"E5555555-5555-4555-8555-5555555"#,
        #"55553","isLocked":true,"isVisible":true,"name":"Rounded","opacity":0.6,"transform":{"center":{"x":0.3,"y":0.7},""#,
        #"isFlippedHorizontally":true,"isFlippedVertically":false,"rotation":15,"scale":1.2}},{"blendMode":"softLight","co"#,
        #"ntent":{"fill":{"_0":{"alpha":0.5,"blue":0.8,"green":0.2,"red":0.1}}},"edits":{"operations":[]},"id":"E5555555-5"#,
        #"555-4555-8555-555555555554","isLocked":false,"isVisible":false,"mask":{"boundingBox":{"origin":{"x":0.2,"y":0.2}"#,
        #","size":{"height":0.6,"width":0.5}},"feather":0.02,"id":"B2222222-2222-4222-8222-22222222222C","isInverted":true"#,
        #","relativePath":"masks\/B2222222-2222-4222-8222-22222222222C.png","source":{"subject":{}},"strokes":[]},"name":""#,
        #"Fill","opacity":1,"transform":{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":fa"#,
        #"lse,"rotation":0,"scale":1}},{"blendMode":"normal","content":{"adjustment":{"_0":{"saturation":-0.4}}},"edits":{"#,
        #""operations":[{"createdAt":"2026-09-21T14:13:20Z","id":"D4444444-4444-4444-8444-444444444445","kind":{"levels":{"#,
        #""_0":{"blue":{"gamma":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"green":{"gamma":1,"inBlack":0,"inWhi"#,
        #"te":1,"outBlack":0,"outWhite":1},"red":{"gamma":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"rgb":{"gam"#,
        #"ma":1.3,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1}}}},"label":"Levels"}]},"id":"E5555555-5555-4555-8555-"#,
        #"555555555555","isLocked":false,"isVisible":true,"name":"Adjustment","opacity":0.75,"transform":{"center":{"x":0."#,
        #"5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1}}],"modifiedAt":"202"#,
        #"6-09-21T14:13:20Z","selectedLayerID":"E5555555-5555-4555-8555-555555555553","selection":{"corners":[{"x":0,"y":0"#,
        #"},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"coverage":0.42,"layerID":"E5555555-5555-4555-8555-555555555551","m"#,
        #"ask":{"boundingBox":{"origin":{"x":0,"y":0},"size":{"height":1,"width":1}},"feather":0,"id":"B2222222-2222-4222-"#,
        #"8222-22222222222D","isInverted":false,"relativePath":"masks\/B2222222-2222-4222-8222-22222222222D.png","source":"#,
        #"{"region":{"_0":"selection"}},"strokes":[]},"pixelHeight":922,"pixelWidth":1536,"refinement":{"contrast":0,"deco"#,
        #"ntaminate":0,"feather":0,"radius":0.3,"shiftEdge":0,"smooth":0.1},"steps":[{"label":"subject","source":"subject""#,
        #"}]},"title":"W2 fixture"}"#,
    ].joined()
}
