import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Regression tests for natural, conversational phrasings.
final class ColloquialParserTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func first(_ utterance: String, context: IntentContext = .photo) -> EditIntent {
        engine.parse(utterance, context: context).intents.first ?? EditIntent(action: .unknown)
    }

    func testPolitenessAndPronouns() {
        let polite = first("peux-tu enlever le chien s'il te plaît")
        XCTAssertEqual(polite.target?.label, "dog")
        XCTAssertTrue(polite.target?.attributes.isEmpty ?? false, "politeness words must not become attributes")
        XCTAssertEqual(first("can you remove the guy behind me").target?.spatialHint, .background)
        XCTAssertEqual(first("make him disappear").target?.label, "person")
        XCTAssertEqual(first("fais disparaître la personne au fond").target?.spatialHint, .background)
        XCTAssertEqual(first("est-ce que tu peux rendre la photo plus lumineuse").parameter, .brightness)
        XCTAssertEqual(first("I'd like to make it a bit warmer").amount, .relative(0.1))
    }

    func testKeepOnlySubject() {
        XCTAssertEqual(first("remove everything except the person").action, .removeBackground)
        XCTAssertEqual(first("efface tout sauf moi").action, .removeBackground)
    }

    func testSelectiveAdjustments() {
        let sky = first("make the sky bluer")
        XCTAssertEqual(sky.action, .selectiveAdjust)
        XCTAssertEqual(sky.target?.label, "sky")
        XCTAssertEqual(sky.parameter, .saturation)
        XCTAssertGreaterThan(sky.amount?.value ?? 0, 0)
        let ciel = first("rends le ciel plus bleu")
        XCTAssertEqual(ciel.action, .selectiveAdjust)
        XCTAssertEqual(ciel.target?.label, "sky")
        let face = first("éclaircis le visage")
        XCTAssertEqual(face.action, .selectiveAdjust)
        XCTAssertEqual(face.target?.label, "face")
        XCTAssertEqual(face.parameter, .brightness)
        XCTAssertEqual(first("rends la photo plus lumineuse").action, .adjust, "whole-image words stay global")
    }

    func testNoiseSemantics() {
        XCTAssertGreaterThan(first("trop de bruit").amount?.value ?? 0, 0)
        XCTAssertEqual(first("trop de bruit").parameter, .noiseReduction)
        XCTAssertGreaterThan(first("it's too noisy").amount?.value ?? 0, 0)
        XCTAssertGreaterThan(first("less noise").amount?.value ?? 0, 0)
    }

    func testMetaVariants() {
        XCTAssertEqual(first("je veux revenir en arrière").action, .undo)
        XCTAssertEqual(first("montre moi avant après").action, .compare)
        XCTAssertEqual(first("undo the last change").action, .undo)
    }

    func testVideoColloquial() {
        let context = IntentContext(mode: .video, clipCount: 2, playheadSeconds: 6, timelineDuration: 20)
        XCTAssertEqual(first("trim the first second", context: context).timeRange, TimeSpan(start: 0, end: 1))
        XCTAssertEqual(first("enlève les 5 dernières secondes", context: context).timeRange, TimeSpan(start: 15, end: 20))
        XCTAssertEqual(first("coupe la vidéo en deux", context: context).time, 6)
        let music = first("mets la musique moins forte", context: context)
        XCTAssertEqual(music.action, .setVolume)
        XCTAssertEqual(music.scope, .selection)
        XCTAssertLessThan(music.amount?.value ?? 0, 0)
        let back = first("go back 3 seconds", context: context)
        XCTAssertEqual(back.action, .seek)
        XCTAssertEqual(back.time, 3)
        XCTAssertEqual(first("sauvegarde cette image", context: context).action, .extractFrame)
        XCTAssertEqual(first("make it twice as fast", context: context).amount, .absolute(2))
        XCTAssertEqual(first("coupe le son de tous les clips", context: context).scope, .all)
        XCTAssertEqual(first("remove the man walking behind", context: context).target?.label, "person")
    }
}
