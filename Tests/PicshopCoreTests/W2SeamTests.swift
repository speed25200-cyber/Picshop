import XCTest
@testable import PicshopCore

/// The W2 seam (Day 0): every new Codable layout round-trips with its defaults, decoding is lenient, a W1
/// document opens and writes back byte for byte, `localAdjust` round-trips while a malformed one stays
/// `.unsupported`, and the moved rebase keeps its W1 rules. M1 owns this file after the seam.
final class W2SeamTests: XCTestCase {
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

    private let raster = RasterRef(path: "masks/0A1B2C3D-0000-4000-8000-0000000000AA.png", origin: .sky, pixelWidth: 1536, pixelHeight: 1152)

    // MARK: Round trips

    func testEveryNewTypeRoundTripsWithItsDefaults() throws {
        try assertRoundTrips(LabColor(l: 50, a: -3, b: 12))
        try assertRoundTrips(raster)
        try assertRoundTrips(RasterRef(path: "masks/depth-0123456789abcdef.png", origin: .depth, pixelWidth: 518, pixelHeight: 392, bitDepth: 16,
                                       corners: [PSPoint(x: 0.1, y: 0), PSPoint(x: 1, y: 0.1), PSPoint(x: 0.9, y: 1), PSPoint(x: 0, y: 0.9)],
                                       boundingBox: PSRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), label: "2", stateKey: "0011223344556677"))
        try assertRoundTrips(BrushSpec())
        try assertRoundTrips(BrushSpec(strokes: [BrushStroke(points: [PSPoint(x: 0.2, y: 0.3)], radius: 0.04, flow: 0.5)], autoMask: true))
        try assertRoundTrips(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0), end: PSPoint(x: 0.5, y: 0.5)))
        try assertRoundTrips(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.3))
        try assertRoundTrips(ColorRangeSpec())
        try assertRoundTrips(ColorRangeSpec(samples: [LabColor(l: 60, a: 20, b: 30)], fuzziness: 0.2, preset: .skinTones))
        try assertRoundTrips(LuminanceRangeSpec(low: 0, high: 0.25))
        try assertRoundTrips(DepthRangeSpec(depth: raster, low: 0.6, high: 1))
        try assertRoundTrips(MaskStack())
        let kinds: [MaskComponent.Kind] = [
            .raster(raster), .brush(BrushSpec()), .linear(LinearGradientSpec(start: .zero, end: PSPoint(x: 1, y: 1))),
            .radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)), .colorRange(ColorRangeSpec(preset: .blues)),
            .luminanceRange(LuminanceRangeSpec(low: 0.75, high: 1)), .depthRange(DepthRangeSpec(depth: raster, low: 0, high: 0.35)),
        ]
        let stack = MaskStack(components: kinds.map { MaskComponent($0, mode: .subtract, isInverted: true, opacity: 0.5) }, isInverted: true,
                              feather: 0.2, expand: -0.1, density: 0.8)
        try assertRoundTrips(stack)
        try assertRoundTrips(LocalAdjustment(stack: MaskStack()))
        try assertRoundTrips(LocalAdjustment(name: "Ciel", region: .sky, label: nil, stack: stack, adjustments: Adjustments([.exposure: 0.3]),
                                             curve: .sCurve(strength: 0.5), mixer: ColorMixer(saturation: [0.2]),
                                             grade: ColorGrade(midtones: ColorWheel(hue: 30, amount: 0.2)), amount: 0.7, isVisible: false))
        try assertRoundTrips(SelectionRefinement())
        try assertRoundTrips(SelectionRefinement.automatic)
        try assertRoundTrips(SelectionStep(.object, mode: .add, label: "cup"))
        let mask = MaskReference(source: .region("selection"), feather: 0.003, decontaminate: 0.5)
        try assertRoundTrips(mask)
        try assertRoundTrips(PhotoSelection(mask: mask, layerID: UUID(), steps: [SelectionStep(.subject)], refinement: .automatic, coverage: 0.4,
                                            pixelWidth: 1536, pixelHeight: 1024))
        try assertRoundTrips(PSHomography.identity)
    }

    func testTheFrozenKeys() throws {
        let component = MaskComponent(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!, .luminanceRange(LuminanceRangeSpec(low: 0.1, high: 0.4)))
        XCTAssertEqual(try json(component),
                       #"{"id":"0A1B2C3D-0000-4000-8000-000000000001","inverted":false,"mode":"add","opacity":1,"spec":{"feather":0.15,"high":0.4,"low":0.1},"type":"luminanceRange"}"#)
        XCTAssertEqual(try json(MaskStack()), #"{"components":[],"density":1,"expand":0,"feather":0,"inverted":false}"#)
        XCTAssertEqual(try json(raster),
                       #"{"bits":8,"box":{"origin":{"x":0,"y":0},"size":{"height":1,"width":1}},"corners":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"h":1152,"origin":"sky","path":"masks\/0A1B2C3D-0000-4000-8000-0000000000AA.png","w":1536}"#)
        let adjustment = LocalAdjustment(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!, region: .bottom, stack: MaskStack())
        XCTAssertEqual(try json(adjustment),
                       #"{"adjustments":{},"amount":1,"id":"0A1B2C3D-0000-4000-8000-000000000002","region":"bottom","stack":{"components":[],"density":1,"expand":0,"feather":0,"inverted":false},"visible":true}"#)
        // BrushStroke.flow and MaskReference.decontaminate are absent when nil: W1 files stay byte-identical.
        XCTAssertFalse(try json(BrushStroke(points: [.zero], radius: 0.1)).contains("flow"))
        XCTAssertFalse(try json(MaskReference(source: .subject)).contains("decontaminate"))
    }

    // MARK: Lenient decoding

    func testMinimalPayloadsDecodeWithDefaults() throws {
        let decoded = try decoder().decode(RasterRef.self, from: Data(#"{"path":"masks/a.png","origin":"hologram"}"#.utf8))
        XCTAssertEqual(decoded.origin, .imported)
        XCTAssertEqual(decoded.corners, RasterRef.unitCorners)
        XCTAssertEqual(decoded.bitDepth, 8)
        XCTAssertEqual(decoded.boundingBox, .unit)
        XCTAssertEqual(try decoder().decode(MaskStack.self, from: Data("{}".utf8)), MaskStack())
        XCTAssertEqual(try decoder().decode(BrushSpec.self, from: Data("{}".utf8)), BrushSpec())
        XCTAssertEqual(try decoder().decode(SelectionRefinement.self, from: Data("{}".utf8)), SelectionRefinement())
        XCTAssertEqual(try decoder().decode(ColorRangeSpec.self, from: Data(#"{"preset":"ultraviolets"}"#.utf8)), ColorRangeSpec())
        let id = UUID()
        let adjustment = try decoder().decode(LocalAdjustment.self, from: Data(#"{"id":"\#(id.uuidString)","stack":{},"region":"aurora"}"#.utf8))
        XCTAssertEqual(adjustment, LocalAdjustment(id: id, stack: MaskStack()))
        XCTAssertNil(adjustment.region)
        // `id` and `stack` are required.
        XCTAssertThrowsError(try decoder().decode(LocalAdjustment.self, from: Data(#"{"stack":{}}"#.utf8)))
        XCTAssertThrowsError(try decoder().decode(LocalAdjustment.self, from: Data(#"{"id":"\#(id.uuidString)"}"#.utf8)))
    }

    func testAComponentFromANewerBuildIsKeptAndWrittenBack() throws {
        let original = [
            #"{"components":["#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000003","inverted":false,"mode":"add","opacity":1,"spec":{"turns":3},"type":"spiral"},"#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000004","inverted":false,"mode":"xor","opacity":1,"spec":{"end":{"x":1,"y":1},"start":{"x":0,"y":0}},"type":"linear"},"#,
            #"{"id":"0A1B2C3D-0000-4000-8000-000000000005","inverted":true,"mode":"subtract","opacity":0.5,"spec":{"feather":0.15,"high":1,"low":0.75},"type":"luminanceRange"}"#,
            #"],"density":1,"expand":0,"feather":0,"inverted":false}"#,
        ].joined()
        let stack = try decoder().decode(MaskStack.self, from: Data(original.utf8))
        XCTAssertEqual(stack.components.count, 3)
        guard case .unsupported(let spiral) = stack.components[0].kind else { return XCTFail("\(stack.components[0].kind)") }
        XCTAssertTrue(spiral.contains(#""type":"spiral""#), spiral)
        guard case .unsupported = stack.components[1].kind else { return XCTFail("an unknown mode must be unsupported") }
        XCTAssertEqual(stack.components[2].kind, .luminanceRange(LuminanceRangeSpec(low: 0.75, high: 1)))
        XCTAssertEqual(stack.components[2].mode, .subtract)
        XCTAssertTrue(stack.hasPixelDependentComponents)
        XCTAssertEqual(try json(stack), original)
    }

    func testASelectionDecodesLeniently() throws {
        let layerID = UUID()
        let mask = try json(MaskReference(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000006")!, source: .subject, feather: 0.003))
        let selection = #"{"coverage":0.3,"layerID":"\#(layerID.uuidString)","mask":\#(mask),"steps":[{"source":"subject"},{"source":"teleport"},{"mode":"xor","source":"sky"},{"label":"cup","mode":"add","source":"object"}]}"#
        let decoded = try decoder().decode(PhotoSelection.self, from: Data(selection.utf8))
        XCTAssertEqual(decoded.steps, [SelectionStep(.subject), SelectionStep(.object, mode: .add, label: "cup")])
        XCTAssertEqual(decoded.corners, RasterRef.unitCorners)
        XCTAssertTrue(decoded.isAligned)
        XCTAssertEqual(decoded.raster.origin, .selection)
        XCTAssertEqual(decoded.raster.path, decoded.mask.relativePath)
        // A mask this build cannot read (an unknown MaskSource) fails the selection, never the document.
        let unreadable = selection.replacingOccurrences(of: #""source":{"subject":{}}"#, with: #""source":{"halo":{}}"#)
        XCTAssertNotEqual(unreadable, selection)
        XCTAssertThrowsError(try decoder().decode(PhotoSelection.self, from: Data(unreadable.utf8)))
        var document = try decoder().decode(PhotoDocument.self, from: Data(Self.w1Document.utf8))
        XCTAssertNil(document.selection)
        let withSelection = Self.w1Document.replacingOccurrences(of: #","title":"Fixture"}"#, with: #","selection":\#(unreadable),"title":"Fixture"}"#)
        XCTAssertNotEqual(withSelection, Self.w1Document)
        document = try decoder().decode(PhotoDocument.self, from: Data(withSelection.utf8))
        XCTAssertNil(document.selection)
        XCTAssertEqual(document.layers.count, 2)
        let readable = Self.w1Document.replacingOccurrences(of: #","title":"Fixture"}"#, with: #","selection":\#(selection),"title":"Fixture"}"#)
        XCTAssertEqual(try decoder().decode(PhotoDocument.self, from: Data(readable.utf8)).selection, decoded)
    }

    // MARK: Documents

    func testAW1DocumentOpensWithoutSelectionAndWritesTheSameBytes() throws {
        let document = try decoder().decode(PhotoDocument.self, from: Data(Self.w1Document.utf8))
        XCTAssertNil(document.selection)
        XCTAssertTrue(document.localAdjustments.isEmpty)
        XCTAssertEqual(document.layers.count, 2)
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 5)
        XCTAssertEqual(try json(document), Self.w1Document)
    }

    func testALocalAdjustRoundTripsInADocument() throws {
        var document = PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        let sky = LocalAdjustment(region: .sky, stack: .single(MaskComponent(.raster(raster))), adjustments: Adjustments([.exposure: 0.3]))
        document.setLocalAdjustment(sky, label: "Mask: Ciel")
        document.setSelection(PhotoSelection(mask: MaskReference(source: .subject), layerID: document.baseLayerID!, coverage: 0.2, pixelWidth: 1536, pixelHeight: 1152))
        let data = try encoder().encode(document)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""kind":{"localAdjust":{"_0":{"#))
        let decoded = try decoder().decode(PhotoDocument.self, from: data)
        XCTAssertEqual(decoded.localAdjustments, [sky])
        XCTAssertEqual(decoded.selection, document.selection)
        XCTAssertEqual(try encoder().encode(decoded), data)
        guard case .localAdjust = decoded.baseLayer?.edits.operations.last?.kind else { return XCTFail("not a local adjustment") }
        XCTAssertEqual(decoded.baseLayer?.edits.operations.last?.label, "Mask: Ciel")
        XCTAssertEqual(EditOperation.Kind.localAdjust(sky).defaultLabel, "Local Adjustment")
        XCTAssertFalse(EditOperation.Kind.localAdjust(sky).isGeometric)
        XCTAssertFalse(EditOperation.Kind.localAdjust(sky).isExpensive)
    }

    func testAMalformedLocalAdjustStaysUnsupported() throws {
        // The two payloads W1's forward-compatibility tests used: neither has `id` nor `stack`.
        for kind in [#"{"localAdjust":{"_0":{"components":[{"mode":"add","radius":0.25}],"invert":false},"_1":{"exposure":0.3},"curve":null}}"#,
                     #"{"localAdjust":{"_0":{"invert":true}}}"#] {
            let text = #"{"createdAt":"2026-10-01T10:00:00Z","id":"0A1B2C3D-0000-4000-8000-000000000001","kind":"# + kind + #","label":"Local Adjust"}"#
            let operation = try decoder().decode(EditOperation.self, from: Data(text.utf8))
            guard case .unsupported = operation.kind else { return XCTFail("\(operation.kind)") }
            XCTAssertEqual(String(decoding: try encoder().encode(operation), as: UTF8.self), text)
        }
    }

    func testOneOperationPerLocalAdjustment() {
        var document = PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        var bottom = LocalAdjustment(region: .bottom, stack: MaskStack())
        document.setLocalAdjustment(bottom)
        document.apply(.adjust(.contrast, value: 0.2))
        let operationID = document.baseLayer?.edits.operations.first?.id
        bottom.adjustments[.exposure] = -0.2
        document.setLocalAdjustment(bottom)
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 2)
        XCTAssertEqual(document.baseLayer?.edits.operations.first?.id, operationID)
        XCTAssertEqual(document.localAdjustments, [bottom])
        XCTAssertTrue(document.removeLocalAdjustment(id: bottom.id))
        XCTAssertFalse(document.removeLocalAdjustment(id: bottom.id))
        XCTAssertTrue(document.localAdjustments.isEmpty)
        XCTAssertEqual(document.localAdjustmentsLayerID, document.baseLayerID)
    }

    func testRestoringToImportDropsTheSelection() {
        var document = PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 1)))
        document.setSelection(PhotoSelection(mask: MaskReference(source: .subject), layerID: document.baseLayerID!, coverage: 0.2, pixelWidth: 768, pixelHeight: 1152))
        XCTAssertNil(document.restoredToImport().selection)
    }

    // MARK: The rebase, moved from the session (W1 rules)

    func testTheRebaseKeepsItsW1Rules() {
        var base = PhotoDocument(title: "Rebase", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        base.apply(.adjust(.exposure, value: 0.1))
        var updated = base
        updated.apply(.removeObject(MaskReference(source: .object(label: "dog", boundingBox: .unit))))
        // Meanwhile only a dial moved: the command's step carries over.
        var current = base
        current.apply(.adjust(.contrast, value: 0.3))
        let rebased = current.rebased(updated, from: base)
        XCTAssertEqual(rebased?.baseLayer?.edits.operations.count, 3)
        XCTAssertEqual(rebased?.baseLayer?.edits.resolvedAdjustments[.contrast], 0.3)
        // Meanwhile a crop: nil.
        var cropped = base
        cropped.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertNil(cropped.rebased(updated, from: base))
        // Nothing appended: the current document as it is.
        XCTAssertEqual(current.rebased(base, from: base), current)
    }

    // MARK: Seam stubs and data

    /// The seam's no-op cases stay no-ops now that the bodies are real (the other lanes' stubs are tested by their
    /// owners: the catalog and the panel inventory fill up during W2).
    func testTheNoOpCasesChangeNothing() {
        var document = PhotoDocument(title: "Stubs", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        let before = document
        XCTAssertFalse(document.applyLocalEdit(.setAmount(0.5), to: UUID()))
        document.reconcileMasks(previousBaseEdits: EditStack())
        XCTAssertEqual(document, before)
        XCTAssertEqual(EditStack().outputAspect(sourceAspect: 1.5), 1.5)
        XCTAssertEqual(RefKind.mask.prefix, "a")
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.llm, llmBytes: 42), 42)
        XCTAssertEqual(MaskModelCatalog.samTiny.totalBytes, 79_644_968)
        XCTAssertEqual(MaskModelCatalog.depthSmall.totalBytes, 49_819_122)
        XCTAssertEqual(Set(MaskModelCatalog.all).count, 2)
        XCTAssertTrue(ModelPriority.background < ModelPriority.userWaiting)
    }

    func testSmallHelpers() {
        let identity = PSHomography.identity
        XCTAssertEqual(identity.apply(PSPoint(x: 0.3, y: 0.7)), PSPoint(x: 0.3, y: 0.7))
        let shift = PSHomography.affine(a: 2, b: 0, c: 0, d: 1, tx: 0.1, ty: 0)
        let back = shift.inverse!
        let point = shift.then(back).apply(PSPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(point.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(MaskStack.defaultComponent(for: .bottom, aspect: 1.5)?.kind, .linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 1), end: PSPoint(x: 0.5, y: 0.5))))
        XCTAssertNil(MaskStack.defaultComponent(for: .sky, aspect: 1.5))
        XCTAssertTrue(MaskRegion.sky.isAI)
        XCTAssertFalse(MaskRegion.bottom.isAI)
        XCTAssertTrue(LocalAdjustment(stack: MaskStack()).isNeutral)
        XCTAssertTrue(LocalAdjustment(region: .sky, stack: .single(MaskComponent(.raster(raster)))).matches(region: .sky, label: nil))
        XCTAssertEqual(raster.maskReference.id, raster.maskReference.id)
        XCTAssertEqual(raster.maskReference.relativePath, raster.path)
        XCTAssertFalse(BrushSpec(strokes: Array(repeating: BrushStroke(points: [.zero], radius: 0.1), count: BrushSpec.maxStrokes)).needsFlatten)
    }

    /// A photo document as the W1 build (226d5c0) wrote it: sorted keys, ISO 8601 dates, a crop, a selective
    /// edit with a brush stroke, an unknown kind and Levels, plus a text layer.
    static let w1Document = [
        #"{"backgroundColor":{"alpha":0,"blue":0,"green":0,"red":0},"canvasSize":{"height":3024,"width":3024},"createdAt":"#,
        #""2026-09-21T14:13:20Z","formatVersion":1,"id":"66666666-6666-4666-8666-666666666666","layers":[{"blendMode":"nor"#,
        #"mal","content":{"image":{"_0":{"duration":0,"frameRate":0,"id":"11111111-1111-4111-8111-111111111111","kind":"im"#,
        #"age","origin":{"photoLibrary":{"localIdentifier":"ABC\/L0\/001"}},"pixelSize":{"height":3024,"width":4032},"rela"#,
        #"tivePath":"media\/base.jpg"}}},"edits":{"operations":[{"createdAt":"2026-09-21T14:13:20Z","id":"44444444-4444-44"#,
        #"44-8444-444444444441","kind":{"adjust":{"_0":"exposure","value":0.25}},"label":"Exposure +25"},{"createdAt":"202"#,
        #"6-09-21T14:13:20Z","id":"44444444-4444-4444-8444-444444444442","kind":{"crop":{"_0":{"origin":{"x":0,"y":0},"siz"#,
        #"e":{"height":1,"width":0.75}}}},"label":"Crop"},{"createdAt":"2026-09-21T14:13:20Z","id":"44444444-4444-4444-844"#,
        #"4-444444444443","kind":{"selectiveAdjust":{"_0":{"boundingBox":{"origin":{"x":0.2,"y":0.3},"size":{"height":0.2,"#,
        #""width":0.25}},"feather":0.01,"id":"33333333-3333-4333-8333-333333333333","isInverted":false,"relativePath":"mas"#,
        #"ks\/33333333-3333-4333-8333-333333333333.png","source":{"object":{"boundingBox":{"origin":{"x":0.2,"y":0.3},"siz"#,
        #"e":{"height":0.2,"width":0.25}},"label":"cup"}},"strokes":[{"hardness":0.7,"id":"22222222-2222-4222-8222-2222222"#,
        #"22222","mode":"add","points":[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4}],"radius":0.05}]},"_1":{"brightness":0.2,"satu"#,
        #"ration":-0.1}}},"label":"Selective Edit"},{"createdAt":"2026-09-21T14:13:20Z","id":"44444444-4444-4444-8444-4444"#,
        #"44444444","kind":{"liquify":{"_0":{"invert":true}}},"label":"Unsupported Edit"},{"createdAt":"2026-09-21T14:13:2"#,
        #"0Z","id":"44444444-4444-4444-8444-444444444445","kind":{"levels":{"_0":{"blue":{"gamma":1,"inBlack":0,"inWhite":"#,
        #"1,"outBlack":0,"outWhite":1},"green":{"gamma":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"red":{"gamma"#,
        #"":1,"inBlack":0,"inWhite":1,"outBlack":0,"outWhite":1},"rgb":{"gamma":1.2,"inBlack":0.05,"inWhite":0.95,"outBlac"#,
        #"k":0,"outWhite":1}}}},"label":"Levels"}]},"id":"55555555-5555-4555-8555-555555555551","isLocked":false,"isVisibl"#,
        #"e":true,"name":"Photo","opacity":1,"transform":{"center":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlip"#,
        #"pedVertically":false,"rotation":0,"scale":1}},{"blendMode":"screen","content":{"text":{"_0":{"alignment":"center"#,
        #"","center":{"x":0.5,"y":0.86},"color":{"alpha":1,"blue":1,"green":1,"red":1},"fontName":"SFProRounded-Bold","id""#,
        #":"77777777-7777-4777-8777-777777777777","letterSpacing":0,"lineSpacing":1.1,"maxRelativeWidth":0.85,"opacity":1,"#,
        #""relativeSize":0.06,"rotation":0,"style":"shadowed","text":"Hello"}}},"edits":{"operations":[]},"id":"55555555-5"#,
        #"555-4555-8555-555555555552","isLocked":false,"isVisible":true,"name":"Hello","opacity":0.8,"transform":{"center""#,
        #":{"x":0.5,"y":0.5},"isFlippedHorizontally":false,"isFlippedVertically":false,"rotation":0,"scale":1}}],"modified"#,
        #"At":"2026-09-21T14:13:20Z","selectedLayerID":"55555555-5555-4555-8555-555555555552","title":"Fixture"}"#,
    ].joined()
}
