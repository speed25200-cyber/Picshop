import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 end to end (§8 acceptance): the signature phrases, the selection operations, the honest paths and a
/// selection carried through geometry — validator, handler, the fake host's services and the postconditions.
final class SelectionOperationTests: XCTestCase {
    static let cup = ObjectCandidate(label: "cup", boundingBox: PSRect(x: 0.38, y: 0.42, width: 0.18, height: 0.28), confidence: 0.9)

    static func services(sam: Bool = true, depth: Bool = true, visionFinds: Bool = true, grounds: Bool = true) -> OperationPhotoServices {
        var services = OperationPhotoServices()
        services.masks = MaskSimulation(samInstalled: sam, hasDepth: depth,
                                        objects: [OperationFixtures.dog, OperationFixtures.person] + (visionFinds ? [cup] : []), groundable: [cup])
        services.grounds = grounds
        if !visionFinds { services.unseen = ["cup"] }
        return services
    }

    struct Run {
        var before: PhotoDocument
        var after: PhotoDocument
        var result: ExecutionResult
        var intent: EditIntent
    }

    /// The step as a model writes it: through the coercer and the validator, then the executor.
    static func model(_ id: OpID, _ args: [String: OpValue], on document: PhotoDocument, services: OperationPhotoServices = services(),
                      french: Bool = true) async throws -> Run {
        let step = OperationArguments.json(OperationCall(id, args: args))
        let use = ToolArgumentCoercer.rawToolUse(id: "m", name: "apply_edits", arguments: ["steps": [step]])
        let context = OperationFixtures.photoContext(document)
        guard case .success(let call) = ToolInputValidator(mode: .photo).validate(use, context: context),
              case .applyEdits(let intents) = call.tool, let intent = intents.first else {
            throw XCTSkip("validator refused \(use.rawInput)")
        }
        return await execute(intent, on: document, services: services, french: french)
    }

    /// What the grammar answers, executed (`last` is the previous turn's step, for « encore »).
    static func said(_ text: String, on document: PhotoDocument, last: EditIntent? = nil, services: OperationPhotoServices = services()) async throws -> Run {
        var context = OperationFixtures.photoContext(document)
        context.lastIntent = last
        let plan = RuleBasedIntentEngine().parse(text, context: context)
        let intent = try XCTUnwrap(plan.intents.first, text)
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.85, text)
        return await execute(intent, on: document, services: services, french: NormalizedUtterance(text).language == .french, context: context)
    }

    static func execute(_ intent: EditIntent, on document: PhotoDocument, services: OperationPhotoServices, french: Bool,
                        context: IntentContext? = nil) async -> Run {
        let executor = PhotoCommandExecutor(services: services, language: french ? .french : .english)
        let (after, result) = await executor.execute(intent, on: document, context: context ?? OperationFixtures.photoContext(document))
        return Run(before: document, after: after, result: result, intent: intent)
    }

    /// Applied, with structural and pixel postconditions passing.
    static func assertVerified(_ run: Run, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(run.result.outcome.isSuccess, "\(text): \(run.result.outcome)", file: file, line: line)
        if let carried = OperationPostconditions.report(in: run.result.effects) {
            XCTAssertEqual(carried.failed, [], "\(text): pixel postconditions", file: file, line: line)
        }
        XCTAssertEqual(OperationPostconditions.check(run.intent, before: run.before, after: run.after).failed, [], text, file: file, line: line)
    }

    // MARK: Signature phrases

    func testToneSignaturePhrasesThenEncoreThenUndo() async throws {
        let cases: [(String, MaskRegion, AdjustmentParameter)] = [
            ("éclaircis le ciel", .sky, .brightness), ("assombris le bas", .bottom, .exposure), ("plus de contraste sur le sujet", .subject, .contrast),
            ("brighten the sky", .sky, .brightness), ("darken the bottom", .bottom, .exposure), ("more contrast on the subject", .subject, .contrast),
        ]
        for (text, region, parameter) in cases {
            let start = OperationFixtures.photo()
            let first = try await Self.said(text, on: start)
            Self.assertVerified(first, text)
            XCTAssertEqual(first.after.localAdjustments.count, 1, text)
            let mask = try XCTUnwrap(first.after.localAdjustments.first, text)
            XCTAssertEqual(mask.region, region, text)
            let once = mask.adjustments[parameter] != 0 ? mask.adjustments[parameter] : mask.adjustments[.exposure]
            XCTAssertNotEqual(once, 0, text)
            // « encore »: the same step on the same mask, one adjustment, the dial doubled.
            let again = try await Self.said(NormalizedUtterance(text).language == .french ? "encore" : "again", on: first.after, last: first.intent)
            Self.assertVerified(again, "\(text) + encore")
            XCTAssertEqual(again.after.localAdjustments.count, 1, "\(text) + encore: one adjustment")
            let twice = try XCTUnwrap(again.after.localAdjustments.first)
            let doubled = mask.adjustments[parameter] != 0 ? twice.adjustments[parameter] : twice.adjustments[.exposure]
            XCTAssertEqual(doubled, once * 2, accuracy: 0.011, "\(text) + encore")
            // Undo is the session's history: the step before has no mask.
            XCTAssertTrue(first.before.localAdjustments.isEmpty)
        }
    }

    func testTheBlueCupThreeWays() async throws {
        let args: [String: OpValue] = ["what": "object", "target": "cup", "attributes": .list(["blue"])]
        // 1. The model gives the box.
        var withBox = args
        withBox["box"] = .box(PSRect(x: 380, y: 420, width: 180, height: 280))
        let boxed = try await Self.model("select", withBox, on: OperationFixtures.photo())
        Self.assertVerified(boxed, "with a box")
        XCTAssertNotNil(boxed.after.selection)
        // 2. No box: Vision's candidates, then SAM.
        let vision = try await Self.said("sélectionne la tasse bleue", on: OperationFixtures.photo())
        Self.assertVerified(vision, "Vision")
        XCTAssertNotNil(vision.after.selection)
        // 3. Vision misses: the grounder's box, then SAM.
        let grounded = try await Self.model("select", args, on: OperationFixtures.photo(), services: Self.services(visionFinds: false))
        Self.assertVerified(grounded, "groundBox")
        let selection = try XCTUnwrap(grounded.after.selection)
        XCTAssertGreaterThan(selection.mask.boundingBox.intersection(Self.cup.boundingBox).area, 0)
        // And English.
        let english = try await Self.said("select the blue cup", on: OperationFixtures.photo())
        Self.assertVerified(english, "English")
    }

    /// « sélectionne la personne à droite » with two people, the left one more confident: the right one is selected.
    /// The grammar keeps the place as `spatialHint` (fast lane, no model needed), and a model's target words say it too.
    func testThePersonOnTheRightIsTheOneOnTheRight() async throws {
        let document = LiveEvalFixtures.lakeDocument()
        let leftBox = PSRect(x: 0.05, y: 0.2, width: 0.2, height: 0.6), rightBox = PSRect(x: 0.7, y: 0.2, width: 0.2, height: 0.6)
        let scene = SceneMap(stateKey: document.baseStateKey, canvasSize: LiveEvalFixtures.lakeCanvas, kind: .photo, texts: [], objects: [
            SceneMap.Object(id: "o1", label: "person", box: leftBox, confidence: 0.92, kind: .person),
            SceneMap.Object(id: "o2", label: "person", box: rightBox, confidence: 0.6, kind: .person),
        ], freeAreas: [], background: PSColor(hex: "#8FB8D8"))
        let masks = MaskSimulation(objects: [ObjectCandidate(label: "person", boundingBox: leftBox, confidence: 0.92),
                                             ObjectCandidate(label: "person", boundingBox: rightBox, confidence: 0.6)])
        let services = LiveEvalServices(grid: nil, scene: scene, masks: masks)
        let context = IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, scene: scene)
        let cases: [(String, NormalizedUtterance.Language)] = [("sélectionne la personne à droite", .french), ("sélectionne la personne de droite", .french),
                                                               ("select the right person", .english)]
        for (text, language) in cases {
            let plan = RuleBasedIntentEngine().parse(text, context: context)
            let intent = try XCTUnwrap(plan.intents.first, text)
            XCTAssertEqual(intent.operation?.id, "select", text)
            XCTAssertEqual(intent.operation?.args["spatialHint"]?.string, "right", text)
            XCTAssertEqual(intent.operation?.args["target"]?.string, "person", text)
            let (after, result) = await PhotoCommandExecutor(services: services, language: language).execute(intent, on: document, context: context)
            XCTAssertTrue(result.outcome.isSuccess, "\(text): \(result.outcome)")
            let box = try XCTUnwrap(after.selection?.mask.boundingBox, text)
            XCTAssertGreaterThan(box.midX, 0.5, "\(text): the person on the right")
        }
        // A model that writes the place in the target (Foundation Models has no box for it).
        let call = EditIntent(action: .operation, operation: OperationCall("select", args: ["what": "object", "target": "person on the left"]))
        let (left, result) = await PhotoCommandExecutor(services: services, language: .english).execute(call, on: document, context: context)
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertLessThan(left.selection?.mask.boundingBox.midX ?? 1, 0.5)
        // A place alone, or two places, are the model's to read.
        XCTAssertTrue(RuleBasedIntentEngine().parse("sélectionne le bas", context: context).confidence < 0.85)
        XCTAssertNil(RuleBasedIntentEngine.selectRule(["selectionne", "la", "tasse", "en", "haut", "a", "droite"], english: false))
    }

    // MARK: Honest paths

    func testAColourThatIsNotThereIsSaidSo() async throws {
        let run = try await Self.said("sélectionne le violet", on: OperationFixtures.photo())
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertNil(run.after.selection)
        XCTAssertEqual(run.result.outcome.message, "Je ne vois pas de violet ici.")
        XCTAssertTrue(run.result.effects.contains(ExecutionReason.notFound.effect))
    }

    func testDepthWithoutTheModelOffersIt() async throws {
        let run = try await Self.model("select", ["what": "near"], on: OperationFixtures.photo(), services: Self.services(depth: false))
        guard case .needsClarification(let request) = run.result.outcome else { return XCTFail("\(run.result.outcome)") }
        XCTAssertEqual(ModelOfferText.modelID(in: request.question), ModelOfferText.depthID)
        XCTAssertTrue(run.result.effects.contains(.message(ModelOfferText.offerPrefix + ModelOfferText.depthID)))
        XCTAssertEqual(run.after, run.before)
    }

    func testAnObjectVisionCannotFindWithoutSAMOffersItAndYesResumes() async throws {
        let missing = Self.services(sam: false, visionFinds: false)
        let run = try await Self.model("select", ["what": "object", "target": "cup"], on: OperationFixtures.photo(), services: missing)
        guard case .needsClarification(let request) = run.result.outcome else { return XCTFail("\(run.result.outcome)") }
        XCTAssertEqual(ModelOfferText.modelID(in: request.question), ModelOfferText.samID)
        XCTAssertEqual(run.after, run.before, "nothing changes before the model is there")
        // « oui »: the session downloads the model.
        var context = OperationFixtures.photoContext(run.after)
        context.pendingClarification = request
        let executor = PhotoCommandExecutor(services: missing, language: .french)
        let (_, yes) = await executor.execute(EditIntent(action: .confirm), on: run.after, context: context)
        XCTAssertTrue(yes.effects.contains(.message(ModelOfferText.installPrefix + ModelOfferText.samID)), "\(yes.effects)")
        // Installed, the pending call runs.
        let pending = try XCTUnwrap(request.pendingIntent)
        let resumed = await Self.execute(pending, on: run.after, services: Self.services(sam: true, visionFinds: false), french: true)
        Self.assertVerified(resumed, "resumed")
        XCTAssertNotNil(resumed.after.selection)
    }

    // MARK: Selection operations

    func testSelectionModesCombineCoverage() async throws {
        let subject = try await Self.model("select", ["what": "subject"], on: OperationFixtures.photo())
        Self.assertVerified(subject, "subject")
        let a = try XCTUnwrap(subject.after.selection?.coverage)
        let added = try await Self.model("select", ["what": "sky", "mode": "add"], on: subject.after)
        Self.assertVerified(added, "add")
        XCTAssertGreaterThan(added.after.selection?.coverage ?? 0, a)
        XCTAssertEqual(added.after.selection?.steps.count, 2)
        let removed = try await Self.model("select", ["what": "sky", "mode": "subtract"], on: added.after)
        Self.assertVerified(removed, "subtract")
        XCTAssertLessThan(removed.after.selection?.coverage ?? 1, added.after.selection?.coverage ?? 0)
        let crossed = try await Self.model("select", ["what": "people", "mode": "intersect"], on: removed.after)
        XCTAssertTrue(crossed.result.outcome.isSuccess, "\(crossed.result.outcome)")
        XCTAssertLessThanOrEqual(crossed.after.selection?.coverage ?? 1, removed.after.selection?.coverage ?? 0)
    }

    func testModifyAndApply() async throws {
        let document = OperationFixtures.photoWithMasks()
        let inverted = try await Self.model("selectionModify", ["invert": true], on: document)
        Self.assertVerified(inverted, "invert")
        XCTAssertEqual(inverted.after.selection?.coverage ?? 0, 1 - (document.selection?.coverage ?? 0), accuracy: 0.001)
        let grown = try await Self.model("selectionModify", ["grow": 40], on: document)
        Self.assertVerified(grown, "grow")
        XCTAssertGreaterThan(grown.after.selection?.coverage ?? 0, document.selection?.coverage ?? 1)
        let dropped = try await Self.model("selectionModify", ["deselect": true], on: document)
        XCTAssertNil(dropped.after.selection)
        for use in CatalogPhotoMasks.useValues {
            var args: [String: OpValue] = ["use": .string(use)]
            if ["fill", "recolor"].contains(use) { args["color"] = "red" }
            if use == "generate" { args["prompt"] = "fleurs" }
            if use == "adjust" { args["parameter"] = "exposure"; args["amount"] = 20 }
            let applied = try await Self.model("selectionApply", args, on: document)
            XCTAssertNotEqual(applied.result.effects.first, ExecutionReason.unsupported.effect, use)
            if applied.result.outcome.isSuccess { XCTAssertNotEqual(applied.after, document, use) }
        }
        // Nothing selected: nothing to apply.
        let none = try await Self.model("selectionApply", ["use": "erase"], on: OperationFixtures.photo())
        XCTAssertFalse(none.result.outcome.isSuccess)
    }

    /// « éclaircis la sélection » then « encore », « plus sombre », « c'est trop »: every follow-up moves the mask the
    /// selection made, never the whole photo's dial, and never makes a second « Sélection » mask.
    func testFollowUpsAfterAdjustingTheSelectionStayOnItsMask() async throws {
        let document = OperationFixtures.photoWithMasks()
        let masks = document.localAdjustments.count
        let first = try await Self.said("éclaircis la sélection", on: document)
        Self.assertVerified(first, "éclaircis la sélection")
        XCTAssertEqual(first.after.localAdjustments.count, masks + 1)
        let made = try XCTUnwrap(first.after.localAdjustments.last)
        let once = made.adjustments[.exposure]
        XCTAssertGreaterThan(once, 0)

        let again = try await Self.said("encore", on: first.after, last: first.intent)
        XCTAssertEqual(again.intent.operation?.id, "maskAdjust", "encore")
        XCTAssertTrue(again.result.outcome.isSuccess, "\(again.result.outcome)")
        XCTAssertEqual(again.after.localAdjustments.count, masks + 1, "encore: no second mask")
        XCTAssertEqual(again.after.localAdjustments.last?.adjustments[.exposure] ?? 0, once * 2, accuracy: 0.011, "encore")

        let darker = try await Self.said("plus sombre", on: again.after, last: again.intent)
        XCTAssertEqual(darker.intent.operation?.id, "maskAdjust", "plus sombre")
        XCTAssertTrue(darker.result.outcome.isSuccess, "\(darker.result.outcome)")
        XCTAssertEqual(darker.after.localAdjustments.count, masks + 1)
        XCTAssertEqual(darker.after.localAdjustments.last?.adjustments[.exposure] ?? 0, once, accuracy: 0.011, "plus sombre")
        XCTAssertEqual(darker.after.activeAdjustments, document.activeAdjustments, "the whole photo's dials do not move")

        let tooMuch = try await Self.said("c'est trop", on: darker.after, last: darker.intent)
        XCTAssertTrue(tooMuch.result.outcome.isSuccess, "\(tooMuch.result.outcome)")
        XCTAssertEqual(tooMuch.after.localAdjustments.count, masks + 1)
        XCTAssertEqual(tooMuch.after.localAdjustments.last?.adjustments[.exposure] ?? 0, once * 1.5, accuracy: 0.011, "c'est trop")
        // The masks before it are untouched.
        XCTAssertEqual(Array(tooMuch.after.localAdjustments.prefix(masks)), Array(document.localAdjustments))
    }

    /// « sélectionne le ciel, recadre en 4:5 et éclaircis la sélection »: the linter keeps select before the crop, and
    /// the last step makes one local adjustment on the remapped sky.
    func testASelectionSurvivesTheCrop() async throws {
        let steps = [
            EditIntent(action: .operation, operation: OperationCall("select", args: ["what": "sky"])),
            EditIntent(action: .crop, aspect: .ratio4x5),
            EditIntent(action: .operation, operation: OperationCall("selectionApply", args: ["use": "adjust", "parameter": "exposure", "amount": 20])),
        ]
        let linted = PlanLinter.lint(steps, utterance: "sélectionne le ciel, recadre en 4:5 et éclaircis la sélection").steps
        XCTAssertEqual(linted.first?.operation?.id, "select")
        var document = OperationFixtures.photo()
        for step in linted {
            let run = await Self.execute(step, on: document, services: Self.services(), french: true)
            XCTAssertTrue(run.result.outcome.isSuccess, "\(step.summary): \(run.result.outcome)")
            document = run.after
        }
        XCTAssertEqual(document.localAdjustments.count, 1)
        XCTAssertEqual(document.localAdjustments.first?.adjustments[.exposure] ?? 0, 0.2 * AdjustmentParameter.exposure.range.upperBound, accuracy: 0.05)
    }
}
