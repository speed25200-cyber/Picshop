import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The documents and services the catalog tests run on: a photo with a text layer (l1), a shape (s1),
/// an imported LUT and a scene map with two objects (o1, o2); a 3-clip timeline; a 6-page PDF.
enum OperationFixtures {
    static let base = MediaAsset(kind: .image, relativePath: "media/photo.jpg", pixelSize: PSSize(width: 4000, height: 3000))
    static let titleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
    static let shapeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2") ?? UUID()
    static let subtitleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3") ?? UUID()

    static let skyMaskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1") ?? UUID()
    static let bottomMaskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2") ?? UUID()

    /// The poster with two masks (a1 the sky, a2 a gradient at the bottom) and the subject selected (W2).
    static func photoWithMasks() -> PhotoDocument {
        var document = photo()
        let sky = MaskSimulation.raster(.sky, label: nil, key: "fixture-sky", coverage: 0.35, document: document)
        document.setLocalAdjustment(LocalAdjustment(id: skyMaskID, region: .sky, stack: MaskStack.single(MaskComponent(.raster(sky))),
                                                    adjustments: Adjustments([.exposure: -0.1])), label: "Mask: Sky")
        if let bottom = MaskStack.defaultComponent(for: .bottom, aspect: 4.0 / 3.0) {
            document.setLocalAdjustment(LocalAdjustment(id: bottomMaskID, region: .bottom, stack: MaskStack.single(bottom),
                                                        adjustments: Adjustments([.exposure: -0.2])), label: "Mask: Bottom")
        }
        let subject = MaskSimulation.raster(.subject, label: nil, key: "fixture-subject", coverage: 0.35, document: document)
        if let layer = document.baseLayerID {
            document.setSelection(PhotoSelection(mask: subject.maskReference, layerID: layer, steps: [SelectionStep(.subject)], coverage: 0.35,
                                                 pixelWidth: subject.pixelWidth, pixelHeight: subject.pixelHeight))
        }
        return document
    }

    static func photo(lut: Bool = true, selectTitle: Bool = true) -> PhotoDocument {
        var document = PhotoDocument(title: "Poster", baseImage: base)
        if lut, let id = document.baseLayerID {
            document.update(layerID: id) { $0.edits.append(.lut(LUTReference(relativePath: "media/lut-teal.cube", title: "Teal", intensity: 1))) }
        }
        var title = TextElement(text: "SOLDES", relativeSize: 0.08, center: PSPoint(x: 0.5, y: 0.2))
        title.maxRelativeWidth = 0.8
        document.addLayer(Layer(id: titleID, name: "SOLDES", content: .text(title)), select: false)
        var subtitle = TextElement(text: "Jusqu'au 31 août", relativeSize: 0.03, center: PSPoint(x: 0.5, y: 0.9))
        subtitle.maxRelativeWidth = 0.8
        document.addLayer(Layer(id: subtitleID, name: "Subtitle", content: .text(subtitle)), select: false)
        document.addLayer(Layer(id: shapeID, name: "Shape", content: .shape(ShapeElement(kind: .rectangle))), select: false)
        if selectTitle { document.selectedLayerID = titleID }
        return document
    }

    static let dog = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.5, width: 0.3, height: 0.4), confidence: 0.9)
    static let person = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.6, y: 0.2, width: 0.25, height: 0.7), confidence: 0.92)

    static func scene() -> SceneMap {
        SceneMap(stateKey: "fixture", canvasSize: PSSize(width: 4000, height: 3000),
                 texts: [
                     SceneMap.TextBlock(id: "t1", text: "PROMO", box: PSRect(x: 0.3, y: 0.05, width: 0.4, height: 0.06)),
                     SceneMap.TextBlock(id: "t2", text: "-50% sur tout", box: PSRect(x: 0.3, y: 0.13, width: 0.4, height: 0.04)),
                     SceneMap.TextBlock(id: "t3", text: "2025", box: PSRect(x: 0.4, y: 0.2, width: 0.2, height: 0.04)),
                 ],
                 objects: [
                     SceneMap.Object(id: "o1", label: "dog", box: dog.boundingBox, confidence: 0.9, kind: .animal),
                     SceneMap.Object(id: "o2", label: "person", box: person.boundingBox, confidence: 0.92, kind: .person),
                 ],
                 freeAreas: [SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.05, y: 0.3, width: 0.3, height: 0.15)),
                             SceneMap.FreeArea(id: "f2", box: PSRect(x: 0.55, y: 0.92, width: 0.4, height: 0.06))])
    }

    static func photoContext(_ document: PhotoDocument) -> IntentContext {
        IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, scene: scene().overlaying(document.layers))
    }

    /// Three 12-second clips (36 s), a title on the timeline.
    static func video() -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/clip.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 12, frameRate: 30)
        let clips = (0..<3).map { _ in VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: 12)) }
        let title = TimelineOverlay(content: .text(TextElement(text: "Vlog d'été")), span: TimeSpan(start: 0, duration: 4))
        return VideoTimeline(title: "Vlog", clips: clips, overlays: [title], renderSize: PSSize(width: 1920, height: 1080))
    }

    static let videoContext = IntentContext(mode: .video, clipCount: 3, playheadSeconds: 5, timelineDuration: 36)

    /// Six pages; a text note on page 2 (the current one).
    static func pdf() -> PDFDocumentModel {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.pdf", pixelSize: .zero)
        var document = PDFDocumentModel(title: "Contrat", sourceAsset: asset, pageSizes: Array(repeating: PSSize(width: 595, height: 842), count: 6))
        document.addMarkup(PDFMarkup(kind: .text(TextElement(text: "Lu et approuvé", relativeSize: 0.02, center: PSPoint(x: 0.3, y: 0.8)))), toPageAt: 1)
        document.goToPage(1)
        return document
    }
}

/// The photo services of the catalog tests: two objects, a subject, a histogram with headroom, and the W2 masks and
/// selections, structurally (`MaskSimulation`: the two objects, one face).
struct OperationPhotoServices: PhotoAIServices {
    var histogramAvailable = true
    var masks = MaskSimulation(objects: [OperationFixtures.dog, OperationFixtures.person])
    /// The vision-language model's boxes: the objects' boxes by name.
    var grounds = true
    /// The faces Vision finds, left to right: a face part (teeth, eyes, lips, skin, face) is one candidate per face
    /// (SelectiveLoweringTests). Nil: one candidate mid-frame, as for any other noun.
    var faces: [PSRect]? = nil
    /// Nouns Vision does not find at all (the SAM offer, the VLM fallback).
    var unseen: Set<String> = []

    /// The dog and the person; anything else named is found once, mid-frame (sky, face, teeth…).
    func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        if unseen.contains(target.label) { return [] }
        if let faces, ["teeth", "eyes", "lips", "skin", "face", "mouth"].contains(target.label) {
            return faces.map { ObjectCandidate(label: target.label, boundingBox: $0, confidence: 0.9) }
        }
        let known = [OperationFixtures.dog, OperationFixtures.person].filter { $0.label == target.label || target.label == "object" }
        if !known.isEmpty { return target.label == "object" ? [known[0]] : known }
        return [ObjectCandidate(label: target.label, boundingBox: PSRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), confidence: 0.9)]
    }

    func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
        let box = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }
        return MaskReference(source: .object(label: target.label, boundingBox: box), boundingBox: box)
    }

    func subjectMask(in document: PhotoDocument) async throws -> MaskReference { MaskReference(source: .subject) }
    func horizonAngle(in document: PhotoDocument) async throws -> Double? { 3 }
    func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? { OperationFixtures.dog.boundingBox }
    func sceneMap(in document: PhotoDocument) async throws -> SceneMap? { OperationFixtures.scene() }

    // W2: masks and selections.
    func aiMask(_ request: AIMaskRequest, in document: PhotoDocument) async throws -> AIMaskResult { try masks.aiMask(request, in: document) }
    func depthMap(in document: PhotoDocument) async throws -> RasterRef { try masks.depthMap(in: document) }
    func rasterize(_ stack: MaskStack, in document: PhotoDocument) async throws -> AIMaskResult { masks.rasterize(stack, in: document) }
    func combineSelection(_ current: PhotoSelection?, with new: RasterRef, mode: CombineMode?, in document: PhotoDocument) async throws -> PhotoSelection {
        masks.combineSelection(current, with: new, mode: mode, in: document)
    }
    func modifySelection(_ selection: PhotoSelection, _ change: SelectionChange, in document: PhotoDocument) async throws -> PhotoSelection {
        masks.modifySelection(selection, change, in: document)
    }
    func refineSelection(_ selection: PhotoSelection, _ refinement: SelectionRefinement, in document: PhotoDocument) async throws -> PhotoSelection {
        masks.refineSelection(selection, refinement, in: document)
    }
    func sampleColors(at points: [PSPoint], radius: Int, in document: PhotoDocument) async throws -> [LabColor] { masks.sampleColors(at: points, radius: radius) }
    func wandMask(at point: PSPoint, tolerance: Double, contiguous: Bool, sampleSize: Int, in document: PhotoDocument) async throws -> AIMaskResult {
        masks.wandMask(at: point, tolerance: tolerance, contiguous: contiguous, in: document)
    }
    func pixelProbes(_ requests: [PixelProbeRequest], before: PhotoDocument, after: PhotoDocument) async -> [PixelProbeResult] {
        masks.pixelProbes(requests, before: before, after: after)
    }
    // W3: layers (synthetic rasters, the layer's own pixels as the photo's, text sizes from the font size).
    func aiMask(_ request: AIMaskRequest, in document: PhotoDocument, layer: UUID?) async throws -> AIMaskResult {
        try masks.aiMask(request, in: document, layer: layer)
    }
    func rasterizeLayers(_ request: LayerRasterRequest, in document: PhotoDocument) async throws -> LayerRasterResult {
        masks.rasterizeLayers(request, in: document)
    }
    func contentSize(of layerID: UUID, in document: PhotoDocument) async -> PSSize? {
        masks.contentSize(of: layerID, in: document)
    }
    func groundBox(_ phrase: String, in document: PhotoDocument) async -> PSRect? { grounds ? masks.groundBox(phrase) : nil }

    /// A low-contrast picture: values between 40 and 200.
    func histogram(of document: PhotoDocument) async -> Histogram? {
        guard histogramAvailable else { return nil }
        var bins = [UInt32](repeating: 0, count: 256)
        for value in 40...200 { bins[value] = 100 }
        return Histogram(red: bins, green: bins, blue: bins, luma: bins)
    }
}

/// W1 validation of catalog operations: the generated path for catalog ids, nearest-operation hints for
/// unknown ones, the legacy path unchanged, and the video refusals.
final class ValidatorCatalogTests: XCTestCase {
    private func use(_ steps: String) -> RawToolUse {
        let arguments = (try? JSONValue.parse("{\"steps\":[\(steps)]}")) ?? .null
        return ToolArgumentCoercer.rawToolUse(id: "t", name: "apply_edits", arguments: arguments)
    }

    private func intents(_ steps: String, mode: EditorMode = .photo, context: IntentContext? = nil) throws -> [EditIntent] {
        let call = try ToolInputValidator(mode: mode).validate(use(steps), context: context ?? IntentContext(mode: mode)).get()
        guard case .applyEdits(let intents) = call.tool else { return [] }
        return intents
    }

    private func problems(_ steps: String, mode: EditorMode = .photo) -> [String] {
        guard case .failure(.problems(let problems)) = ToolInputValidator(mode: mode).validate(use(steps), context: IntentContext(mode: mode, clipCount: 3, timelineDuration: 30)) else { return [] }
        return problems
    }

    func testCurvesJSONBecomesAnOperationThatChangesTheToneCurve() async throws {
        try XCTSkipIf(OperationCatalog.shared.spec("curves") == nil, "the catalog has no curves entry yet")
        let steps = try intents(#"{"action":"curves","preset":"sCurve","amount":30}"#)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].action, .operation)
        XCTAssertEqual(steps[0].operation?.id, "curves")
        let document = OperationFixtures.photo()
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .french)
        let (after, result) = await executor.execute(steps[0], on: document, context: OperationFixtures.photoContext(document))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertNotEqual(after.baseLayer?.edits.resolvedToneCurve, document.baseLayer?.edits.resolvedToneCurve)
        XCTAssertNotNil(OperationPostconditions.report(in: result.effects), "the structural check rides with the result")
    }

    func testUnknownKeysAreRefusedAndUnknownActionsNameTheNearest() throws {
        try XCTSkipIf(OperationCatalog.shared.spec("curves") == nil, "the catalog has no curves entry yet")
        let refused = problems(#"{"action":"curves","preset":"sCurve","wobble":3}"#)
        XCTAssertTrue(refused.contains("steps[0].wobble: unknown field"), "\(refused)")
        let unknown = problems(#"{"action":"toneCurve","preset":"sCurve"}"#)
        XCTAssertEqual(unknown.count, 1)
        XCTAssertTrue(unknown[0].hasPrefix("steps[0].action: 'toneCurve' is not a valid action"), unknown[0])
        if !OperationArguments.nearest(to: "toneCurve", domain: .photo).isEmpty { XCTAssertTrue(unknown[0].contains("nearest:"), unknown[0]) }
    }

    func testLegacyStepsAreUnchanged() throws {
        let steps = try intents(#"{"action":"adjust","parameter":"temperature","amount":15}"#)
        XCTAssertEqual(steps.first?.action, .adjust)
        XCTAssertEqual(steps.first?.parameter, .temperature)
        XCTAssertNil(steps.first?.operation)
        XCTAssertEqual(problems(#"{"action":"operation"}"#), ["steps[0].action: operation is not an editing step"], "the seam word is never a step")
    }

    func testVideoRefusesSelectiveAdjustWithAHintAndPhotoOperations() throws {
        let refused = problems(#"{"action":"selectiveAdjust","target":"sky","parameter":"saturation","amount":20}"#, mode: .video)
        XCTAssertEqual(refused, ["steps[0].action: selectiveAdjust is not available for a video; use adjust (the whole clip)"])
        if OperationCatalog.shared.spec("curves") != nil {
            XCTAssertEqual(problems(#"{"action":"curves","preset":"sCurve"}"#, mode: .video), ["steps[0].action: curves is not available for a video"])
        }
        // A clip is levelled from its horizon (VideoHorizonDetecting), or by the angle given.
        XCTAssertEqual(problems(#"{"action":"straighten"}"#, mode: .video), [])
        XCTAssertEqual(problems(#"{"action":"straighten","degrees":2}"#, mode: .video), [])
    }

    /// A video straighten stays a straighten (the executor sets quarter turns + tilt), never a
    /// rotation that would add to the clip's angle on each repeat.
    func testVideoStraightenIsNotRewrittenAsARotation() throws {
        let raw = try XCTUnwrap(LLMResponseParser.parse(#"{"steps":[{"action":"straighten","degrees":2}],"reply":"ok","language":"fr"}"#))
        let plan = IntentNormalizer.plan(from: raw, utterance: "redresse la vidéo de 2 degrés", context: .video, engine: .proLocal)
        XCTAssertEqual(plan.intents.first?.action, .straighten)
        XCTAssertEqual(plan.intents.first?.degrees, 2)
        let detected = try XCTUnwrap(LLMResponseParser.parse(#"{"steps":[{"action":"straighten"}],"reply":"ok","language":"fr"}"#))
        let levelled = IntentNormalizer.plan(from: detected, utterance: "redresse la vidéo", context: .video, engine: .proLocal)
        XCTAssertEqual(levelled.intents.first?.action, .straighten)
        XCTAssertNil(levelled.intents.first?.degrees)
    }

    func testThePlannerLaneKeepsACatalogOperationsArguments() throws {
        try XCTSkipIf(OperationCatalog.shared.spec("layerBlend") == nil, "the catalog has no layerBlend entry yet")
        let raw = try XCTUnwrap(LLMResponseParser.parse(#"{"steps":[{"action":"layerBlend","mode":"multiply","ref":"l1"}],"reply":"ok","language":"fr"}"#))
        XCTAssertEqual(raw.steps.first?.extra?["mode"], "multiply")
        let plan = IntentNormalizer.plan(from: raw, utterance: "mets le calque en mode produit", context: .photo, engine: .proLocal)
        XCTAssertEqual(plan.intents.first?.action, .operation)
        XCTAssertEqual(plan.intents.first?.operation?.args["mode"], .string("multiply"))
        // And back: the model's own vocabulary for last: lines and ideas.
        let step = RawIntentStep(intent: try XCTUnwrap(plan.intents.first))
        XCTAssertEqual(step.action, "layerBlend")
        XCTAssertEqual(step.extra?["mode"], "multiply")
    }

    func testMovePageContract() throws {
        let context = IntentContext(mode: .pdf, pageCount: 6, currentPage: 2)
        let move = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "movePage", clipNumber: 2, choiceIndex: 5), context: context))
        XCTAssertEqual(move.index, 2, "clipNumber is the page that moves")
        XCTAssertEqual(move.clipIndex, 5, "choiceIndex is where it goes")
        let toEnd = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "movePage", clipNumber: 2, choiceIndex: -1), context: context))
        XCTAssertEqual(toEnd.clipIndex, -1)
        let current = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "movePage", choiceIndex: 5), context: context))
        XCTAssertNil(current.index, "no clipNumber: the current page")
        XCTAssertEqual(RawIntentStep(intent: move).clipNumber, 2)
        XCTAssertEqual(RawIntentStep(intent: move).choiceIndex, 5)
    }

    func testMovePageRunsThePageItNames() async throws {
        var document = OperationFixtures.pdf()
        let ids = document.pages.map(\.id)
        let move = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "movePage", clipNumber: 2, choiceIndex: 5), context: IntentContext(mode: .pdf, pageCount: 6, currentPage: 1)))
        let (moved, result) = await PDFCommandExecutor(services: FakePDFServices()).execute(move, on: document, context: IntentContext(mode: .pdf, pageCount: 6, currentPage: 1))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(moved.pages[4].id, ids[1], "page 2 is now page 5")
        document = moved
    }
}
