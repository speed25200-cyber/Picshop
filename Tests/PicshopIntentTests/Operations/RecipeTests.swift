import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (D21): the four recipes expand deterministically, run on the fake hosts as one history step, check each step and
/// stop honestly at the first that fails.
final class RecipeTests: XCTestCase {
    static func recipe(_ name: RecipeName, _ extra: [String: OpValue] = [:]) -> EditIntent {
        var args = extra
        args["name"] = .string(name.rawValue)
        return EditIntent(action: .operation, confidence: 0.9, operation: OperationCall(RecipeExecution.recipeID, args: args, source: .grammar))
    }

    static func run(_ name: RecipeName, _ extra: [String: OpValue] = [:], on document: PhotoDocument,
                    services: OperationPhotoServices = SelectionOperationTests.services(), french: Bool = true) async -> SelectionOperationTests.Run {
        await SelectionOperationTests.execute(recipe(name, extra), on: document, services: services, french: french)
    }

    static func speech(_ result: ExecutionResult) -> [String] {
        result.effects.compactMap { effect in
            if case .message(let text) = effect, text.hasPrefix("speak:") { return String(text.dropFirst(6)) }
            return nil
        }
    }

    func testEveryRecipeExpandsInItsOwnDomainOnly() {
        for name in RecipeName.allCases {
            let home = RecipeBook.domain(of: name)
            let steps = RecipeBook.expand(name, args: [:], context: RecipeContext(domain: home))
            XCTAssertFalse(steps.isEmpty, name.rawValue)
            XCTAssertEqual(steps, RecipeBook.expand(name, args: [:], context: RecipeContext(domain: home)), "\(name): deterministic")
            for other in OpDomain.allCases where other != home {
                XCTAssertEqual(RecipeBook.expand(name, args: [:], context: RecipeContext(domain: other)), [], "\(name) on \(other)")
            }
            XCTAssertEqual(RecipeExecution.label(name), "Recipe: " + RecipeBook.title(of: name).en)
        }
    }

    // MARK: Instagram post

    func testInstagramPostIsOneHistoryStepWithTheExportPreset() async throws {
        let run = await Self.run(.instagramPost, on: OperationFixtures.photo())
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertEqual(run.result.label, "Recipe: Instagram post")
        XCTAssertEqual(run.after.canvasSize.width / run.after.canvasSize.height, 0.8, accuracy: 0.01, "4:5")
        let export = try XCTUnwrap(LayerOperationTests.messages(run).first { $0.hasPrefix(PhotoOperationHandlers.exportPrefix) })
        let preset = try JSONDecoder().decode(ExportPreset.self, from: Data(export.dropFirst(PhotoOperationHandlers.exportPrefix.count).utf8))
        XCTAssertEqual(preset.name, "instagram")
        XCTAssertEqual(preset.outputSize(canvas: run.after.canvasSize).width, 1080)
        XCTAssertEqual(preset.outputSize(canvas: run.after.canvasSize).height, 1350)
        XCTAssertTrue(Self.speech(run.result).contains { $0.hasPrefix("C'est prêt") }, "\(Self.speech(run.result))")
    }

    func testInstagramFormats() async {
        let square = await Self.run(.instagramPost, ["format": "square"], on: OperationFixtures.photo())
        XCTAssertEqual(square.after.canvasSize.width / square.after.canvasSize.height, 1, accuracy: 0.01)
        let story = await Self.run(.instagramPost, ["format": "story9x16"], on: OperationFixtures.photo())
        XCTAssertEqual(story.after.canvasSize.width / story.after.canvasSize.height, 9.0 / 16.0, accuracy: 0.01)
    }

    /// D10b: on a 3-layer document, the subject layer (a copy of the photo's pixels) stays registered with the photo
    /// through the recipe's crop: its placed corners are the photo's corners through the base's geometry chain.
    func testInstagramPostKeepsTheSubjectLayerRegistered() async throws {
        var document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        var caption = TextElement(text: "Été", relativeSize: 0.06, center: PSPoint(x: 0.5, y: 0.85))
        caption.maxRelativeWidth = 0.6
        document.addLayer(Layer(name: "Été", content: .text(caption)), select: false)
        let via = await SelectionOperationTests.execute(
            EditIntent(action: .operation, confidence: 0.9, operation: OperationCall("layerVia", args: ["mode": "copy", "where": "subject"], source: .grammar)),
            on: document, services: SelectionOperationTests.services(), french: true)
        XCTAssertTrue(via.result.outcome.isSuccess, "\(via.result.outcome)")
        XCTAssertEqual(via.after.layers.count, 3)
        let subjectID = try XCTUnwrap(via.after.layers.first { layer in !document.layers.contains { $0.id == layer.id } }?.id)
        let run = await Self.run(.instagramPost, on: via.after)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let base = try XCTUnwrap(run.after.baseLayer)
        let subject = try XCTUnwrap(run.after.layer(id: subjectID))
        let size = try XCTUnwrap(LayerPlacement.contentSize(of: subject, canvasSize: run.after.canvasSize))
        let placed = LayerPlacement.quad(for: subject, contentSize: size, canvasSize: run.after.canvasSize, isBase: false)
        let chain = base.edits.geometryChain(sourceAspect: 4.0 / 3.0).map
        let expected = RasterRef.unitCorners.map(chain.apply)
        XCTAssertEqual(placed.count, expected.count)
        for (got, want) in zip(placed, expected) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-6)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-6)
        }
    }

    // MARK: Product photo

    func testProductPhotoPutsTheProductOnAWhiteBackdrop() async throws {
        let document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        let run = await Self.run(.productPhoto, on: document)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertEqual(run.result.label, "Recipe: Product photo")
        XCTAssertEqual(run.after.canvasSize.width / run.after.canvasSize.height, 1, accuracy: 0.01)
        let product = try XCTUnwrap(run.after.layers.first { $0.name == "Produit" })
        let index = try XCTUnwrap(run.after.layers.firstIndex { $0.id == product.id })
        XCTAssertEqual(run.after.layers[index - 1].content, .fill(.white), "the backdrop right below the product")
        XCTAssertEqual(run.after.selectedLayerID, product.id, "the product stays selected")
        XCTAssertNotEqual(product.edits, run.before.baseLayer?.edits, "autoTone landed on the product")
        XCTAssertTrue(run.result.effects.contains(.selectLayer(product.id)))
    }

    func testProductPhotoTakesTheBackgroundColour() async throws {
        let run = await Self.run(.productPhoto, ["background": "black"], on: PhotoDocument(title: "P", baseImage: OperationFixtures.base))
        XCTAssertTrue(run.after.layers.contains { $0.content == .fill(.black) })
    }

    /// A step that fails stops the recipe: what was done stays (one history step), and it says how far it got.
    func testAFailingStepStopsHonestly() async {
        var services = SelectionOperationTests.services()
        services.masks.absent = [.subject]
        let document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        let run = await Self.run(.productPhoto, on: document, services: services)
        XCTAssertTrue(run.result.outcome.isSuccess, "the square crop stays: \(run.result.outcome)")
        XCTAssertEqual(run.result.label, "Recipe: Product photo")
        XCTAssertTrue(Self.speech(run.result).contains { $0.hasPrefix("J'ai fait 1 étape sur 4 :") }, "\(Self.speech(run.result))")
        XCTAssertFalse(run.result.effects.contains(ExecutionReason.unsupported.effect), "a recipe never says unsupported")
        XCTAssertEqual(run.after.layers.count, 1, "no product layer")

        let english = await Self.run(.productPhoto, on: document, services: services, french: false)
        XCTAssertTrue(Self.speech(english.result).contains { $0.hasPrefix("I did 1 of 4 steps:") }, "\(Self.speech(english.result))")
    }

    // MARK: Portrait retouch

    func testPortraitRetouchMakesItsMasksInOneStep() async {
        let document = OperationFixtures.photo()
        let run = await Self.run(.portraitRetouch, ["strength": 30], on: document)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertEqual(run.result.label, "Recipe: Portrait retouch")
        XCTAssertGreaterThanOrEqual(run.after.allLocalAdjustments.count, 4, "skin, eyes, teeth, subject")
    }

    // MARK: Domains

    func testARecipeOutsideItsDomainSaysWhere() async {
        let run = await Self.run(.vlogCleanup, on: OperationFixtures.photo())
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertEqual(run.result.outcome.message, "Ça se fait dans une vidéo.")
        XCTAssertEqual(run.after, run.before)
    }

    func testVlogCleanupOnAVideoHost() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(), language: .french)
        let timeline = OperationFixtures.video()
        let (_, result) = await executor.execute(Self.recipe(.vlogCleanup), on: timeline, context: OperationFixtures.videoContext)
        XCTAssertNotEqual(result.outcome.message, "Ça se fait sur une photo.")
        if result.outcome.isSuccess { XCTAssertEqual(result.label, "Recipe: Vlog cleanup") }
        let photo = await executor.execute(Self.recipe(.instagramPost), on: timeline, context: OperationFixtures.videoContext)
        XCTAssertEqual(photo.1.outcome.message, "Ça se fait sur une photo.")
    }

    /// « photo produit » through the grammar is the recipe, run on the photo; never the W1 replaceBackground goal.
    func testPhotoProduitThroughTheGrammar() async throws {
        let document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        let run = try await SelectionOperationTests.said("photo produit", on: document)
        XCTAssertEqual(run.intent.operation?.args["name"], .string("productPhoto"))
        XCTAssertEqual(run.result.label, "Recipe: Product photo")
        XCTAssertFalse(run.after.baseLayer?.edits.operations.contains { if case .replaceBackground = $0.kind { return true } else { return false } } ?? true)
    }
}
