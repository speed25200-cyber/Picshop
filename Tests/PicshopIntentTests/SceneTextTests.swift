import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The composable primitives on the poster scene: text placed in a box or a free area in a matched
/// style, printed blocks rewritten, restyled, moved or erased in one step, regions erased — and the
/// grammar that reaches them by what the text is ("le titre", "le prix", « SOLDES ») and the follow-ups.
final class SceneTextTests: XCTestCase {
    let engine = RuleBasedIntentEngine()
    let scene = SceneFixtures.posterScene()

    private func execute(_ intent: EditIntent, on document: PhotoDocument = SceneFixtures.posterDocument(), services: TableFakeServices = SceneFixtures.posterServices(),
                         context: IntentContext? = nil) async -> (PhotoDocument, ExecutionResult) {
        let ctx = context ?? IntentContext(mode: .photo, scene: scene.overlaying(document.layers))
        return await PhotoCommandExecutor(services: services, language: .french).execute(intent, on: document, context: ctx)
    }

    // MARK: addText in a place and a style

    func testTextInAFreeAreaFitsAndReads() async throws {
        let (after, result) = await execute(EditIntent(action: .addText, text: "Nouveau", ref: .area(1)))
        XCTAssertEqual(result.label, "Add Text")
        let element = try XCTUnwrap(after.textLayers.last?.textElement)
        let area = scene.freeAreas[0].box
        XCTAssertEqual(element.center.x, area.midX, accuracy: 1e-9)
        XCTAssertEqual(element.center.y, area.midY, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(PhotoCommandExecutor.estimatedWidth("Nouveau", relativeSize: element.relativeSize, canvas: SceneFixtures.posterCanvas), area.width * 0.85 + 1e-9)
        XCTAssertEqual(element.style, .plain)
        XCTAssertEqual(element.color, PSColor(hex: "#1C1C1E"), "dark on the light sky")
        XCTAssertEqual(after.textLayers.last?.transform.center, element.center)
    }

    func testTextInTheStyleOfTheTitleAndUnderIt() async throws {
        let styled = EditIntent(action: .addText, text: "Jusqu'à dimanche", placement: .bottom, textStyle: TextStyleSpec(match: .ref(.text(1))))
        let (after, _) = await execute(styled)
        let element = try XCTUnwrap(after.textLayers.last?.textElement)
        XCTAssertEqual(element.fontName, "SFPro-Bold")
        XCTAssertEqual(element.relativeSize, 0.075, accuracy: 1e-9)
        XCTAssertEqual(element.color, .white)
        // At the bottom, moved up off the price (t3) the title-sized line would cover at the bottom anchor.
        XCTAssertEqual(element.center.x, TextElement.Placement.bottom.center.x, accuracy: 1e-9)
        XCTAssertGreaterThan(element.center.y, 0.75, "still at the bottom")
        let box = element.estimatedBox(canvasSize: SceneFixtures.posterCanvas)
        XCTAssertLessThanOrEqual(box.intersection(scene.texts[2].box).area, 1e-4, "clear of the price")

        let under = EditIntent(action: .addText, text: "Nouveau", ref: .text(2))
        let (placed, _) = await execute(under)
        let below = try XCTUnwrap(placed.textLayers.last?.textElement)
        let subtitle = scene.texts[1].box
        XCTAssertGreaterThan(below.center.y, subtitle.maxY)
        XCTAssertEqual(below.fontName, "SFPro-Medium", "the block it goes under gives the style")
        XCTAssertEqual(below.relativeSize, 0.032, accuracy: 0.006)
    }

    // MARK: Printed blocks

    func testRewriteAPrintedTitleInOneStep() async throws {
        let services = SceneFixtures.posterServices()
        let before = SceneFixtures.posterDocument()
        let intent = EditIntent(action: .editText, text: "PROMO", ref: .text(1))
        let (after, result) = await execute(intent, on: before, services: services)
        XCTAssertEqual(result.label, "Edit Text")
        XCTAssertEqual(services.calls.mask, 1, "the old words erased with a tight mask")
        guard case .removeObject(let mask)? = after.baseLayer?.edits.operations.last?.kind else { return XCTFail("an erase") }
        XCTAssertTrue(mask.boundingBox.insetBy(dx: -0.01, dy: -0.01).contains(scene.texts[0].box.center))
        let element = try XCTUnwrap(after.textLayers.last?.textElement)
        XCTAssertEqual(element.text, "PROMO")
        XCTAssertEqual(element.fontName, "SFPro-Bold")
        XCTAssertEqual(element.color, .white)
        XCTAssertEqual(element.relativeSize, 0.075, accuracy: 1e-9)
        XCTAssertEqual(element.center, scene.texts[0].box.center)
        // What the host checks afterwards: the new words read there, the old ones are gone.
        let request = try XCTUnwrap(EditVerifier.request(for: intent, before: before, after: after, result: result, scene: scene))
        XCTAssertEqual(Set(request.checks.map(\.kind)), [.textPresent, .textAbsent])
        let report = EditVerifier.structural(request, in: after)
        XCTAssertNotEqual(report.status, .failed)
    }

    func testRestyleAPrintedPriceKeepsItsWordsAndEdge() async throws {
        let (after, _) = await execute(EditIntent(action: .editText, color: .red, ref: .text(3)))
        let element = try XCTUnwrap(after.textLayers.last?.textElement)
        XCTAssertEqual(element.text, "29,99 €")
        XCTAssertEqual(element.color, .red)
        XCTAssertEqual(element.alignment, .leading)
        let frame = try XCTUnwrap(element.frameWidth)
        XCTAssertEqual(element.center.x - frame / 2, scene.texts[2].box.minX, accuracy: 1e-9, "left edge kept")
    }

    func testLayersAreEditedMovedAndRemovedInPlace() async throws {
        var document = SceneFixtures.posterDocument()
        let layer = Layer(name: "Hello", content: .text(TextElement(text: "Hello", center: PSPoint(x: 0.5, y: 0.5))))
        document.addLayer(layer)
        let (edited, _) = await execute(EditIntent(action: .editText, text: "Salut", ref: .layer(1), textStyle: TextStyleSpec(weight: .regular)), on: document)
        XCTAssertEqual(edited.layer(id: layer.id)?.textElement?.text, "Salut")
        XCTAssertEqual(edited.layer(id: layer.id)?.textElement?.fontName, "SFProRounded-Regular")
        XCTAssertEqual(edited.layers.count, document.layers.count)
        let (moved, result) = await execute(EditIntent(action: .moveText, placement: .top, ref: .layer(1)), on: document)
        XCTAssertEqual(result.label, "Move Text")
        XCTAssertEqual(moved.layer(id: layer.id)?.textElement?.center, TextElement.Placement.top.center)
        XCTAssertEqual(moved.layer(id: layer.id)?.transform.center, TextElement.Placement.top.center)
        let (removed, _) = await execute(EditIntent(action: .removeText, ref: .layer(1)), on: document)
        XCTAssertNil(removed.layer(id: layer.id))
    }

    func testMoveAndEraseAPrintedBlock() async throws {
        let services = SceneFixtures.posterServices()
        let (moved, result) = await execute(EditIntent(action: .moveText, placement: .bottom, ref: .text(1)), services: services)
        XCTAssertEqual(result.label, "Move Text")
        XCTAssertEqual(services.calls.mask, 1)
        XCTAssertEqual(moved.textLayers.last?.textElement?.text, "SOLDES D'ÉTÉ")
        XCTAssertEqual(moved.textLayers.last?.textElement?.center, TextElement.Placement.bottom.center)
        let (erased, removal) = await execute(EditIntent(action: .removeText, ref: .text(2)))
        XCTAssertEqual(removal.label, "Remove Text")
        XCTAssertEqual(erased.textLayers.count, 0)
        guard case .removeObject? = erased.baseLayer?.edits.operations.last?.kind else { return XCTFail("an erase") }
    }

    func testEraseRegionsAndObjectsByID() async {
        let (erased, result) = await execute(EditIntent(action: .eraseRegion, region: PSRect(x: 0.7, y: 0.25, width: 0.2, height: 0.1)))
        XCTAssertEqual(result.label, "Erase Area")
        guard case .removeObject? = erased.baseLayer?.edits.operations.last?.kind else { return XCTFail("an erase") }
        let (_, sliver) = await execute(EditIntent(action: .eraseRegion, region: PSRect(x: 0.5, y: 0.5, width: 0.001, height: 0.2)))
        XCTAssertEqual(sliver.reason, .badRegion)
        let (_, huge) = await execute(EditIntent(action: .eraseRegion, region: PSRect(x: 0, y: 0, width: 0.95, height: 0.95)))
        XCTAssertEqual(huge.reason, .badRegion)
        let (_, none) = await execute(EditIntent(action: .eraseRegion))
        XCTAssertEqual(none.reason, .needsSelection)
        let (person, removal) = await execute(EditIntent(action: .removeObject, ref: .object(1)))
        XCTAssertTrue(removal.outcome.isSuccess, "\(removal.outcome)")
        guard case .removeObject(let mask)? = person.baseLayer?.edits.operations.last?.kind else { return XCTFail("an erase") }
        XCTAssertEqual(mask.boundingBox, scene.objects[0].box)
        let (_, gone) = await execute(EditIntent(action: .eraseRegion, ref: .object(7)))
        XCTAssertEqual(gone.reason, .unknownRef)
    }

    func testUnknownIDsAreRefused() async {
        for intent in [EditIntent(action: .editText, text: "x", ref: .text(9)), EditIntent(action: .removeText, ref: .text(9)),
                       EditIntent(action: .moveText, placement: .top, ref: .layer(4)), EditIntent(action: .addText, text: "x", ref: .area(5))] {
            let before = SceneFixtures.posterDocument()
            let (document, result) = await execute(intent, on: before)
            XCTAssertEqual(result.reason, .unknownRef, "\(intent.action)")
            XCTAssertEqual(document, before, "\(intent.action): nothing changed")
        }
    }

    // MARK: The grammar reaches blocks by what they are

    func testSceneGrammar() {
        let context = IntentContext(mode: .photo, scene: scene)
        func parse(_ phrase: String) -> EditIntent? { engine.parse(phrase, context: context).intents.first }
        let replaced = parse("remplace le titre par « PROMO »")
        XCTAssertEqual(replaced?.action, .editText)
        XCTAssertEqual(replaced?.ref, .text(1))
        XCTAssertEqual(replaced?.text, "PROMO")
        XCTAssertEqual(parse("remplace « SOLDES D'ÉTÉ » par « PROMO »")?.ref, .text(1))
        XCTAssertEqual(parse("change le prix en 19,99 €")?.text, "19,99 €")
        let red = parse("mets le prix en rouge")
        XCTAssertEqual(red?.action, .editText)
        XCTAssertEqual(red?.ref, .text(3))
        XCTAssertEqual(red?.color, .red)
        XCTAssertEqual(parse("agrandis le titre")?.textStyle?.size, .scale(1.35))
        XCTAssertEqual(parse("mets le sous-titre en gras")?.textStyle?.weight, .bold)
        XCTAssertEqual(parse("mets le sous-titre en gras")?.ref, .text(2))
        let moved = parse("déplace le titre en bas")
        XCTAssertEqual(moved?.action, .moveText)
        XCTAssertEqual(moved?.placement, .bottom)
        XCTAssertEqual(parse("monte un peu le prix")?.degrees, 90)
        XCTAssertEqual(parse("mets le titre en bas")?.action, .moveText)
        let erased = parse("efface le sous-titre")
        XCTAssertEqual(erased?.action, .removeText)
        XCTAssertEqual(erased?.ref, .text(2))
        let under = parse("écris « Jusqu'à dimanche » sous le titre")
        XCTAssertEqual(under?.action, .addText)
        XCTAssertEqual(under?.text, "Jusqu'à dimanche")
        XCTAssertEqual(under?.ref, .text(1))
        let matched = parse("ajoute « -30 % » dans le même style que le prix")
        XCTAssertEqual(matched?.textStyle?.match, .ref(.text(3)))
        XCTAssertEqual(parse("replace the title with “SALE”")?.text, "SALE")
        XCTAssertEqual(parse("make the price bigger")?.textStyle?.size, .scale(1.35))
        XCTAssertEqual(parse("erase the subtitle")?.ref, .text(2))
        XCTAssertEqual(parse("write “New” under the title")?.ref, .text(1))
        // No scene: the old paths.
        XCTAssertEqual(engine.parse("efface le texte « SOLDES »", context: .photo).intents.first?.target?.label, "text")
    }

    func testFollowUpsReuseTheLastStep() {
        let added = EditIntent(action: .addText, text: "Nouveau")
        let bigger = engine.parse("plus gros", context: IntentContext(mode: .photo, textLayerCount: 1, lastIntent: added)).intents.first
        XCTAssertEqual(bigger?.action, .editText)
        XCTAssertEqual(bigger?.amount, .multiplier(1.35))
        XCTAssertEqual(engine.parse("en rouge", context: IntentContext(mode: .photo, lastIntent: added)).intents.first?.color, .red)
        XCTAssertEqual(engine.parse("passe-la en noir et blanc", context: IntentContext(mode: .photo, lastIntent: added)).intents.first?.action, .applyLook,
                       "a look, not black text")
        // A printed block edited is a new layer now, the one the step selected: the follow-up names no dead id.
        let title = EditIntent(action: .editText, color: .red, ref: .text(1))
        XCTAssertNil(engine.parse("plus gros", context: IntentContext(mode: .photo, scene: scene, lastIntent: title)).intents.first?.ref)
        // A layer edited stays the one.
        let layer = EditIntent(action: .editText, color: .red, ref: .layer(1))
        XCTAssertEqual(engine.parse("plus gros", context: IntentContext(mode: .photo, scene: scene, lastIntent: layer)).intents.first?.ref, .layer(1))
        let fill = EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1")))
        XCTAssertEqual(engine.parse("en gras", context: IntentContext(mode: .photo, lastIntent: fill)).intents.first?.textStyle?.weight, .bold)
        let rotate = EditIntent(action: .rotate, degrees: 90)
        let again = engine.parse("encore", context: IntentContext(mode: .photo, lastIntent: rotate)).intents.first
        XCTAssertEqual(again?.action, .rotate)
        XCTAssertNotEqual(again?.id, rotate.id)
        let removal = EditIntent(action: .removeObject, target: ObjectTarget(label: "person", originalPhrase: "la personne"))
        let dog = engine.parse("pareil pour le chien", context: IntentContext(mode: .photo, lastIntent: removal)).intents.first
        XCTAssertEqual(dog?.action, .removeObject)
        XCTAssertEqual(dog?.target?.label, "dog")
        let subtitle = engine.parse("pareil pour le sous-titre", context: IntentContext(mode: .photo, scene: scene, lastIntent: title)).intents.first
        XCTAssertEqual(subtitle?.ref, .text(2))
        XCTAssertEqual(subtitle?.color, .red)
        // After an adjustment, "encore" stays the adjustment's.
        let brighter = engine.parse("encore", context: IntentContext(mode: .photo, lastParameter: .brightness, lastAdjustmentDirection: 1,
                                                                    lastIntent: EditIntent(action: .adjust, parameter: .brightness)))
        XCTAssertEqual(brighter.intents.first?.action, .adjust)
    }

    // MARK: Review: relations, replacements, questions, follow-ups after a rewrite

    func testRelationsNameTheBlockNextToTheOneSaid() {
        let context = IntentContext(mode: .photo, scene: scene)
        let under = engine.parse("efface le texte sous le titre", context: context).intents.first
        XCTAssertEqual(under?.action, .removeText)
        XCTAssertEqual(under?.ref, .text(2), "the subtitle, never the title")
        XCTAssertEqual(engine.parse("erase the text below the title", context: context).intents.first?.ref, .text(2))
        XCTAssertEqual(engine.parse("efface le texte au-dessus du sous-titre", context: context).intents.first?.ref, .text(1))
        let instead = engine.parse("mets « -70% » à la place du sous-titre", context: context).intents.first
        XCTAssertEqual(instead?.action, .editText)
        XCTAssertEqual(instead?.ref, .text(2))
        XCTAssertEqual(instead?.text, "-70%")
        XCTAssertEqual(engine.parse("write “Promo” instead of the price", context: context).intents.first?.ref, .text(3))
        // New text still goes under the title (a relation that places, not one that names).
        XCTAssertEqual(engine.parse("écris « Nouveau » sous le titre", context: context).intents.first?.ref, .text(1))
    }

    func testQuestionsAndFollowUpsNeverBecomeText() {
        let context = IntentContext(mode: .photo, scene: scene)
        for question in ["pourquoi tu ne peux pas écrire derrière ?", "est-ce que le titre est lisible ?"] {
            XCTAssertFalse(engine.parse(question, context: context).intents.contains { $0.action == .addText }, question)
            XCTAssertFalse(engine.parse(question, context: .photo).intents.contains { $0.action == .addText }, question)
        }
        let erasedPrice = IntentContext(mode: .photo, scene: scene, lastIntent: EditIntent(action: .removeText, ref: .text(3)))
        let too = engine.parse("le sous-titre aussi", context: erasedPrice).intents.first
        XCTAssertEqual(too?.action, .removeText)
        XCTAssertEqual(too?.ref, .text(2))
        let red = IntentContext(mode: .photo, scene: scene, lastIntent: EditIntent(action: .editText, color: .red, ref: .text(1)))
        XCTAssertEqual(engine.parse("le sous-titre aussi", context: red).intents.first?.color, .red)
        // No scene map (between an erase and the next read): a replacement is an edit to ask about, never new text.
        let replace = engine.parse("remplace le titre par Benchmark 2026", context: .photo)
        XCTAssertEqual(replace.intents.first?.action, .editText)
        XCTAssertEqual(replace.intents.first?.text, "Benchmark 2026")
        XCTAssertLessThan(replace.confidence, 0.9)
        // An id said is checked by the executor (unknown_ref), never written at the bottom.
        let unknown = engine.parse("écris « X » dans la zone f7", context: context).intents.first
        XCTAssertEqual(unknown?.action, .addText)
        XCTAssertEqual(unknown?.ref, .area(7))
        // "titre" alone adds nothing.
        XCTAssertNotEqual(engine.parse("le titre", context: .photo).intents.first?.action, .addText)
    }

    func testFollowUpsAfterReplacingPrintedText() async throws {
        // « remplace le titre par Benchmark 2026 », then « plus gros », then « en rouge »: each on the new layer.
        let (layers, problems) = await SceneScenarios.replaceThenRestyle(["remplace le titre par Benchmark 2026", "plus gros", "en rouge"])
        XCTAssertEqual(problems, [])
        let layer = try XCTUnwrap(layers.last)
        XCTAssertEqual(layer.text, "Benchmark 2026")
        XCTAssertGreaterThan(layer.relativeSize, 0.075)
        XCTAssertEqual(SceneMap.colorClass(of: layer.color), "red")
        XCTAssertEqual(layers.count, 1, "one layer, edited twice")

        // Between the erase and the next text pass (no scene map at all), the follow-ups still reach the layer the
        // replacement wrote: its id, never the erased printed block.
        let (unread, unreadProblems) = await SceneScenarios.replaceThenRestyle(["remplace le titre par Benchmark 2026", "plus gros", "en rouge"],
                                                                               dropsSceneUntilRead: true)
        XCTAssertEqual(unreadProblems, [])
        XCTAssertEqual(unread.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(unread.last).relativeSize, 0.075)
        XCTAssertEqual(SceneMap.colorClass(of: try XCTUnwrap(unread.last).color), "red")
    }

    /// « écris 'Brouillon' en haut à droite en petit » on the benchmark: in the free band, small, in the page's
    /// plain style, off the table.
    func testSmallTextTopRightOnTheBenchmark() async throws {
        let benchmark = SceneFixtures.benchmarkScene()
        let context = IntentContext(mode: .photo, table: TableFixtures.benchmark(), scene: benchmark)
        let intent = try XCTUnwrap(engine.parse("écris 'Brouillon' en haut à droite en petit", context: context).intents.first)
        XCTAssertEqual(intent.action, .addText)
        XCTAssertEqual(intent.ref, .area(1))
        XCTAssertEqual(intent.textStyle?.size, .preset(.small))
        XCTAssertEqual(intent.textStyle?.match, .nearby)
        let services = TableFakeServices(grid: TableFixtures.benchmark(), scene: benchmark)
        let (after, _) = await PhotoCommandExecutor(services: services, language: .french).execute(intent, on: TableFixtures.document(), context: context)
        let element = try XCTUnwrap(after.textLayers.last?.textElement)
        let box = element.estimatedBox(canvasSize: TableFixtures.canvas)
        XCTAssertTrue(benchmark.freeAreas[0].box.insetBy(dx: -0.001, dy: -0.001).contains(element.center), "inside f1")
        XCTAssertLessThan(element.relativeSize, 0.02)
        XCTAssertEqual(element.style, .plain)
        XCTAssertFalse(element.fontName.hasPrefix("SFProRounded"), "the page's typography, not the title default")
        XCTAssertEqual(box.intersection(TableFixtures.benchmark().bounds).area, 0, accuracy: 1e-9, "off the table")
        // On the poster, the free sky; an edge with no free area moves off the text it would cover.
        let poster = IntentContext(mode: .photo, scene: scene)
        XCTAssertEqual(engine.parse("écris « Nouveau » dans le ciel en haut à droite", context: poster).intents.first?.ref, .area(1))
        let top = try XCTUnwrap(engine.parse("ajoute « Été 2026 » en haut", context: poster).intents.first)
        let region = try XCTUnwrap(top.region)
        XCTAssertFalse(scene.texts.contains { $0.box.intersection(region).area > 0.0001 }, "never over the title or the subtitle")
    }

    func testTableCellGroupsAreRestyledTogether() async throws {
        let services = TableFakeServices()
        let executor = PhotoCommandExecutor(services: services, language: .french)
        let fill = EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1")))
        let (filled, _) = await executor.execute(fill, on: TableFixtures.document(), context: IntentContext(mode: .photo, table: TableFixtures.benchmark()))
        let (bigger, result) = await executor.execute(EditIntent(action: .editText, amount: .multiplier(1.35)), on: filled, context: .photo)
        XCTAssertEqual(result.label, "Edit Text")
        let sizes = Set(bigger.layers.compactMap { $0.group != nil ? $0.textElement?.relativeSize : nil })
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(sizes.first ?? 0, TableFixtures.style.relativeSize * 1.35, accuracy: 1e-6, "all 45 at once")
        let (bold, _) = await executor.execute(EditIntent(action: .editText, textStyle: TextStyleSpec(weight: .bold)), on: filled, context: .photo)
        XCTAssertEqual(Set(bold.layers.compactMap { $0.group != nil ? $0.textElement?.fontName : nil }), ["SFProDigits-Bold"])
    }
}

/// Turns run on the executor-backed editor, as Live's grammar lane runs them.
@MainActor private enum SceneScenarios {
    static func replaceThenRestyle(_ turns: [String], dropsSceneUntilRead: Bool = false) async -> (layers: [TextElement], problems: [String]) {
        let host = TableEditorHost.poster()
        host.dropsSceneUntilRead = dropsSceneUntilRead
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        var problems: [String] = []
        for words in turns {
            let plan = RuleBasedIntentEngine().parse(words, context: host.liveIntentContext())
            let execution = await handler.runPlan(plan)
            if !execution.allApplied { problems.append("\(words): \(execution.steps.map { "\($0.status) \($0.reason?.rawValue ?? "")" })") }
        }
        return (host.textLayers, problems)
    }
}
