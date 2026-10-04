import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (§8.4): the layer requests W3 does not do answer honestly with their nearest operation, in French and English,
/// cap a grammar plan that names them, and answer without a model; the two with an operation of their own run it.
final class UnsupportedLayerRequestTests: XCTestCase {
    /// One French and one English request per family.
    static let requests: [(id: String, fr: String, en: String)] = [
        ("blackWhiteLayer", "ajoute un calque noir et blanc", "add a black and white adjustment layer"),
        ("dropShadow", "mets une ombre portée sous le logo", "add a drop shadow to the logo"),
        ("stroke", "ajoute un contour autour du logo", "add a stroke around the logo"),
        ("glowBevel", "une lueur externe sur le titre", "an outer glow on the title"),
        ("layerStyle", "applique un style de calque", "apply a layer style"),
        ("gradientMap", "ajoute une courbe de transfert de dégradé", "add a gradient map"),
        ("selectiveColor", "fais une correction sélective des rouges", "selective color on the reds"),
        ("pattern", "ajoute un calque de motif", "add a pattern layer"),
        ("warp", "déforme le calque en vague", "warp the layer"),
        ("rasterizeText", "pixellise le texte", "rasterize the text"),
        ("nestedGroup", "mets un groupe dans le groupe", "put a group inside a group"),
        ("openPSD", "ouvre ce PSD", "open this psd"),
        ("smartObject", "convertis en objet dynamique", "convert to a smart object"),
        ("artboard", "ajoute un plan de travail", "add an artboard"),
        ("layerComps", "enregistre une composition de calques", "save a layer comp"),
        ("transformTogether", "transforme ces calques ensemble", "transform these layers together"),
        ("blendIf", "ouvre les options de fusion avancées", "open the blending options"),
    ]

    func testEveryFamilyIsRecognisedInBothLanguages() {
        XCTAssertEqual(Set(Self.requests.map(\.id)), Set(UnsupportedLayerRequests.families.map(\.id)), "one request per family")
        for request in Self.requests {
            XCTAssertEqual(UnsupportedLayerRequests.match(request.fr)?.id, request.id, request.fr)
            XCTAssertEqual(UnsupportedLayerRequests.match(request.en)?.id, request.id, request.en)
            XCTAssertNil(UnsupportedLayerRequests.match(request.fr, domain: .video), "photo only")
        }
    }

    /// Each family's answer is honest (« pas encore », "isn't", or what is done instead) and its nearest operation is a
    /// catalog one.
    func testAnswersAreHonestWithTheNearestOperation() {
        for family in UnsupportedLayerRequests.families {
            XCTAssertFalse(family.french.isEmpty || family.english.isEmpty, family.id)
            XCTAssertFalse(family.french.contains("\""), "French quotes are « »: \(family.id)")
            if let nearest = family.nearest { XCTAssertNotNil(OperationCatalog.shared.spec(nearest), "\(family.id) → \(nearest)") }
            if let offer = family.offer {
                XCTAssertEqual(offer.id, family.nearest, "\(family.id): the offer is the nearest operation")
                XCTAssertNotNil(OperationCatalog.shared.spec(offer.id))
            }
            XCTAssertFalse(family.reply(french: true).isEmpty)
        }
    }

    /// Without a model: the honest sentence and no step, or the family's own operation.
    func testThePlanWithoutAModel() throws {
        let shadow = try XCTUnwrap(UnsupportedLayerRequests.match("ajoute une ombre portée au logo"))
        let plan = UnsupportedLayerRequests.plan(shadow, utterance: "ajoute une ombre portée au logo", language: .french)
        XCTAssertTrue(plan.intents.allSatisfy { $0.action == .unknown }, "\(plan.intents.map(\.action))")
        XCTAssertEqual(plan.reply, shadow.french)
        let english = UnsupportedLayerRequests.plan(shadow, utterance: "add a drop shadow", language: .english)
        XCTAssertEqual(english.reply, shadow.english)

        let mono = try XCTUnwrap(UnsupportedLayerRequests.match("ajoute un calque noir et blanc"))
        let monoPlan = UnsupportedLayerRequests.plan(mono, utterance: "ajoute un calque noir et blanc", language: .french)
        let call = try XCTUnwrap(monoPlan.intents.first?.operation)
        XCTAssertEqual(call.id, "addAdjustmentLayer")
        XCTAssertEqual(call.args["parameter"], .string("saturation"))
        XCTAssertEqual(call.args["amount"], .number(-100))
    }

    /// The black-and-white layer runs: a Light layer with the saturation at −100, the photo untouched.
    func testTheBlackAndWhiteLayerRuns() async throws {
        let mono = try XCTUnwrap(UnsupportedLayerRequests.match("ajoute un calque noir et blanc"))
        let plan = UnsupportedLayerRequests.plan(mono, utterance: "ajoute un calque noir et blanc", language: .french)
        let run = await SelectionOperationTests.execute(plan.intents[0], on: OperationFixtures.photoWithLayers(), services: SelectionOperationTests.services(),
                                                        french: true)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let made = try XCTUnwrap(run.after.layers.first { layer in !run.before.layers.contains { $0.id == layer.id } })
        guard case .adjustment(let dials) = made.content else { return XCTFail("\(made.content)") }
        XCTAssertEqual(dials[.saturation], -1, accuracy: 1e-9)
    }

    /// A grammar plan that names a family is capped (the model, or the honest answer, decides), unless it is the
    /// family's own operation.
    func testAbstentionCapsAGrammarPlanThatNamesAFamily() {
        let engine = RuleBasedIntentEngine()
        for request in Self.requests where request.id != "blackWhiteLayer" {
            let plan = OperationAbstention.capped(engine.parse(request.fr, context: IntentContext(mode: .photo)), utterance: request.fr, domain: .photo)
            XCTAssertFalse(plan.confidence >= 0.85 && plan.intents.contains { $0.action != .unknown }, "« \(request.fr) » → \(plan.intents.map(\.action))")
        }
    }

    /// The router without a model answers with the family.
    func testTheRouterWithoutAModelAnswersHonestly() async {
        let router = HybridIntentRouter(preferredEngine: .rules)
        let plan = await router.plan("ajoute une ombre portée au logo", context: IntentContext(mode: .photo))
        XCTAssertEqual(plan.reply, UnsupportedLayerRequests.match("ombre portée")?.french)
        XCTAssertTrue(plan.intents.allSatisfy { $0.action == .unknown })
    }
}
