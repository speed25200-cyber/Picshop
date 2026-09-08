import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The grammar must read what people mean, not only what they say: goals,
/// follow-ups, corrections, contrasts and subjective adjectives.
final class DeepUnderstandingTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func plan(_ utterance: String, context: IntentContext = .photo) -> EditPlan {
        engine.parse(utterance, context: context)
    }

    private func first(_ utterance: String, context: IntentContext = .photo) -> EditIntent {
        plan(utterance, context: context).intents.first ?? EditIntent(action: .unknown)
    }

    // MARK: Goals

    func testProfilePictureGoal() {
        let result = plan("transforme ça en photo de profil")
        XCTAssertEqual(result.intents.map(\.action), [.autoEnhance, .crop])
        XCTAssertEqual(result.intents[1].aspect, .square)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85, "goals are deterministic and must not wait for a model")
        let english = plan("I need this for my LinkedIn profile picture")
        XCTAssertEqual(english.intents.map(\.action), [.autoEnhance, .crop])
    }

    func testProductAndIdentityGoals() {
        let product = plan("product photo for vinted")
        XCTAssertEqual(product.intents.map(\.action), [.replaceBackground, .autoEnhance])
        XCTAssertEqual(product.intents[0].color, .white)
        let identity = plan("fais-en une photo d'identité")
        XCTAssertEqual(identity.intents.map(\.action), [.replaceBackground, .crop])
        XCTAssertEqual(identity.intents[1].aspect, .ratio3x4)
    }

    func testRestoreNightAndWallpaperGoals() {
        let restore = plan("restore this old photo")
        XCTAssertEqual(restore.intents.first?.action, .autoEnhance)
        XCTAssertTrue(restore.intents.contains { $0.action == .adjust && $0.parameter == .noiseReduction && ($0.amount?.value ?? 0) > 0 })
        let night = plan("c'est une photo de nuit")
        XCTAssertTrue(night.intents.contains { $0.parameter == .shadows && ($0.amount?.value ?? 0) > 0 })
        XCTAssertEqual(first("mets la en fond d'écran").aspect, .ratio9x16)
    }

    func testCropWordsKeepOnlyTheFrame() {
        let result = plan("crop it for my profile picture")
        XCTAssertEqual(result.intents.map(\.action), [.crop])
        XCTAssertEqual(result.intents[0].aspect, .square)
    }

    // MARK: Follow-ups

    func testFollowUpsReferToTheLastAdjustment() {
        var context = IntentContext.photo
        context.lastParameter = .brightness
        context.lastAdjustmentDirection = 1
        let again = first("encore un peu", context: context)
        XCTAssertEqual(again.action, .adjust)
        XCTAssertEqual(again.parameter, .brightness)
        XCTAssertEqual(again.amount, .relative(0.1))
        XCTAssertEqual(first("a bit more", context: context).amount, .relative(0.1))
        XCTAssertEqual(first("less", context: context).amount, .relative(-0.15))
        let tooMuch = first("trop", context: context)
        XCTAssertEqual(tooMuch.parameter, .brightness)
        XCTAssertLessThan(tooMuch.amount?.value ?? 0, 0)
        XCTAssertEqual(first("beaucoup plus", context: context).amount, .relative(0.3))
    }

    func testFollowUpsNeedAPreviousAdjustment() {
        XCTAssertTrue(plan("encore un peu").isEmpty)
        var context = IntentContext.photo
        context.lastParameter = .contrast
        XCTAssertEqual(first("plus lumineux", context: context).parameter, .brightness, "a named parameter always wins over the memory")
    }

    // MARK: Contrast clauses and corrections

    func testButSplitsTwoRequests() {
        let result = plan("make it brighter but less saturated")
        XCTAssertEqual(result.intents.map(\.action), [.adjust, .adjust])
        XCTAssertEqual(result.intents[0].parameter, .brightness)
        XCTAssertGreaterThan(result.intents[0].amount?.value ?? 0, 0)
        XCTAssertEqual(result.intents[1].parameter, .saturation)
        XCTAssertLessThan(result.intents[1].amount?.value ?? 0, 0)
        let french = plan("plus chaud mais moins de contraste")
        XCTAssertEqual(french.intents.map(\.parameter), [.temperature, .contrast])
        XCTAssertEqual(first("remove everything but the dog").action, .removeBackground, "'everything but' is one phrase")
    }

    func testCorrectionDuringClarification() {
        let candidates = [
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.7, y: 0.4, width: 0.2, height: 0.3), confidence: 0.85),
        ]
        let pending = ClarificationRequest(question: "Which one?", candidates: candidates, pendingIntent: EditIntent(action: .removeObject, target: ObjectTarget(label: "dog")))
        var context = IntentContext.photo
        context.pendingClarification = pending
        let corrected = first("non, le chat", context: context)
        XCTAssertEqual(corrected.action, .removeObject)
        XCTAssertEqual(corrected.target?.label, "cat")
        XCTAssertEqual(first("no", context: context).action, .cancel)
        XCTAssertEqual(first("laisse tomber", context: context).action, .cancel)
        XCTAssertEqual(first("à gauche", context: context).target?.spatialHint, .left)
    }

    // MARK: Subjective and photographic vocabulary

    func testSubjectiveAdjectives() {
        let dull = first("it looks dull")
        XCTAssertEqual(dull.action, .adjust)
        XCTAssertEqual(dull.parameter, .vibrance)
        XCTAssertGreaterThan(dull.amount?.value ?? 0, 0)
        let yellow = first("c'est un peu jaunâtre")
        XCTAssertEqual(yellow.parameter, .temperature)
        XCTAssertEqual(yellow.amount, .relative(-0.1))
        let harsh = first("it's way too harsh")
        XCTAssertEqual(harsh.parameter, .highlights)
        XCTAssertEqual(harsh.amount, .relative(-0.4))
        let lighting = first("fix the lighting")
        XCTAssertEqual(lighting.action, .autoEnhance)
    }

    func testPortraitRetouching() {
        let skin = first("lisse la peau")
        XCTAssertEqual(skin.action, .selectiveAdjust)
        XCTAssertEqual(skin.target?.label, "face")
        XCTAssertEqual(skin.parameter, .noiseReduction)
        XCTAssertEqual(skin.amount, .relative(0.5))
        let teeth = first("whiten the teeth")
        XCTAssertEqual(teeth.action, .selectiveAdjust)
        XCTAssertEqual(teeth.target?.label, "teeth")
        XCTAssertEqual(teeth.parameter, .brightness)
        XCTAssertGreaterThan(teeth.amount?.value ?? 0, 0)
    }

    func testEchoedPhraseStopsAtTheObject() {
        let laptop = first("efface le pc portable sur cette image")
        XCTAssertEqual(laptop.action, .removeObject)
        XCTAssertEqual(laptop.target?.label, "laptop")
        XCTAssertEqual(laptop.target?.originalPhrase, "le pc portable")
        XCTAssertEqual(first("remove the lamp in this picture").target?.originalPhrase, "the lamp")
        XCTAssertEqual(first("remove the dog on the left").target?.spatialHint, .left)
    }

    func testVagueDissatisfactionBecomesAutoEnhance() {
        XCTAssertEqual(first("c'est moche").action, .autoEnhance)
        XCTAssertEqual(first("do your magic").action, .autoEnhance)
    }

    func testSkySwapWithoutReplacement() {
        let sky = first("change le ciel")
        XCTAssertEqual(sky.action, .generativeFill)
        XCTAssertEqual(sky.target?.label, "sky")
        XCTAssertFalse(sky.text?.isEmpty ?? true)
        XCTAssertEqual(first("rends le ciel plus bleu").action, .selectiveAdjust, "comparatives stay selective adjustments")
        XCTAssertEqual(first("remplace le ciel par un coucher de soleil").text, "un coucher de soleil")
    }

    func testPromptCarriesTheInterpretationGuide() {
        var context = IntentContext.photo
        context.lastParameter = .temperature
        context.lastAdjustmentDirection = 1
        let prompt = IntentPrompt.systemInstructions(context: context)
        XCTAssertTrue(prompt.contains("photo de profil"))
        XCTAssertTrue(prompt.contains("temperature"))
        XCTAssertTrue(prompt.contains("follow-ups"))
        XCTAssertFalse(IntentPrompt.systemInstructions(context: .video).contains("How to read photo requests"))
    }
}
