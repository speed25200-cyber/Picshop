import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class RuleParserTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func first(_ utterance: String, context: IntentContext = .photo, file: StaticString = #filePath, line: UInt = #line) -> EditIntent {
        let plan = engine.parse(utterance, context: context)
        XCTAssertFalse(plan.intents.isEmpty, "no intents for \(utterance)", file: file, line: line)
        return plan.intents.first ?? EditIntent(action: .unknown)
    }

    // MARK: Object removal

    func testRemoveObjectFrench() {
        let intent = first("efface le chien sur l'image")
        XCTAssertEqual(intent.action, .removeObject)
        XCTAssertEqual(intent.target?.label, "dog")
        XCTAssertNil(intent.target?.spatialHint)
        XCTAssertGreaterThan(intent.confidence, 0.85)
    }

    func testRemoveObjectWithSpatialHintAndAccents() {
        let intent = first("Enlève la personne à gauche, s'il te plaît")
        XCTAssertEqual(intent.action, .removeObject)
        XCTAssertEqual(intent.target?.label, "person")
        XCTAssertEqual(intent.target?.spatialHint, .left)
    }

    func testRemoveObjectEnglishVariants() {
        XCTAssertEqual(first("remove the car in the background").target?.label, "car")
        XCTAssertEqual(first("remove the car in the background").target?.spatialHint, .background)
        XCTAssertEqual(first("get rid of the power lines").target?.label, "wire")
        XCTAssertEqual(first("erase that guy on the right").target?.spatialHint, .right)
        XCTAssertEqual(first("delete the trash can").target?.label, "trash")
        XCTAssertEqual(first("can you clean up the pimple on my forehead").target?.label, "blemish")
    }

    func testRemoveAllAndOrdinal() {
        let all = first("supprime toutes les personnes en arrière-plan")
        XCTAssertEqual(all.target?.label, "person")
        XCTAssertTrue(all.target?.matchesAll ?? false)
        XCTAssertEqual(all.target?.spatialHint, .background)
        let second = first("remove the second person from the left")
        XCTAssertEqual(second.target?.ordinal, 2)
        XCTAssertEqual(second.target?.spatialHint, .left)
        let two = first("efface les deux voitures")
        XCTAssertEqual(two.target?.label, "car")
        XCTAssertTrue(two.target?.matchesAll ?? false)
    }

    func testRemoveUnknownNounKeepsWords() {
        let intent = first("remove the surfboard")
        XCTAssertEqual(intent.action, .removeObject)
        XCTAssertEqual(intent.target?.label, "surfboard")
        XCTAssertLessThan(intent.confidence, 0.85, "unknown nouns are low confidence so the LLM is consulted")
    }

    func testRemoveThisUsesTapPoint() {
        var context = IntentContext.photo
        context.lastTapPoint = PSPoint(x: 0.3, y: 0.4)
        let intent = first("efface ça", context: context)
        XCTAssertEqual(intent.action, .removeObject)
        XCTAssertEqual(intent.target?.label, "object")
        XCTAssertEqual(intent.target?.point, PSPoint(x: 0.3, y: 0.4))
    }

    func testRemoveTextPrefersLayerWhenPresent() {
        var context = IntentContext.photo
        context.textLayerCount = 1
        XCTAssertEqual(first("remove the text", context: context).action, .removeText)
        XCTAssertEqual(first("enlève le texte").action, .removeObject)
        XCTAssertEqual(first("enlève le texte").target?.label, "text")
    }

    // MARK: Background

    func testBackgroundCommands() {
        XCTAssertEqual(first("enlève le fond").action, .removeBackground)
        XCTAssertEqual(first("remove the background").action, .removeBackground)
        XCTAssertEqual(first("détoure le sujet").action, .removeBackground)
        let white = first("mets un fond blanc")
        XCTAssertEqual(white.action, .replaceBackground)
        XCTAssertEqual(white.color, .white)
        let blue = first("change the background to light blue")
        XCTAssertEqual(blue.action, .replaceBackground)
        XCTAssertEqual(blue.color, PSColor.named("light blue"))
        let blur = first("floute l'arrière-plan")
        XCTAssertEqual(blur.action, .blurBackground)
        XCTAssertEqual(first("portrait mode").action, .blurBackground)
        XCTAssertEqual(first("fond transparent").action, .removeBackground)
    }

    // MARK: Adjustments

    func testAdjustDirectionalWords() {
        let brighter = first("make it brighter")
        XCTAssertEqual(brighter.action, .adjust)
        XCTAssertEqual(brighter.parameter, .brightness)
        XCTAssertEqual(brighter.amount?.mode, .relative)
        XCTAssertGreaterThan(brighter.amount?.value ?? 0, 0)

        let darker = first("un peu plus sombre")
        XCTAssertEqual(darker.parameter, .brightness)
        XCTAssertLessThan(darker.amount?.value ?? 0, 0)
        XCTAssertEqual(darker.amount?.value ?? 0, -0.1, accuracy: 1e-9)

        let tooDark = first("c'est trop sombre")
        XCTAssertEqual(tooDark.parameter, .brightness)
        XCTAssertGreaterThan(tooDark.amount?.value ?? 0, 0)

        let lessDark = first("moins sombre")
        XCTAssertGreaterThan(lessDark.amount?.value ?? 0, 0)

        let warmer = first("réchauffe un peu l'image")
        XCTAssertEqual(warmer.parameter, .temperature)
        XCTAssertGreaterThan(warmer.amount?.value ?? 0, 0)

        let cooler = first("make it cooler")
        XCTAssertEqual(cooler.parameter, .temperature)
        XCTAssertLessThan(cooler.amount?.value ?? 0, 0)

        let tooMuchContrast = first("there's way too much contrast")
        XCTAssertEqual(tooMuchContrast.parameter, .contrast)
        XCTAssertLessThan(tooMuchContrast.amount?.value ?? 0, 0)
        XCTAssertEqual(tooMuchContrast.amount?.value ?? 0, -0.4, accuracy: 1e-9)
    }

    func testAdjustExplicitNumbers() {
        let absolute = first("mets la luminosité à 50")
        XCTAssertEqual(absolute.parameter, .brightness)
        XCTAssertEqual(absolute.amount, .absolute(0.5))

        let relative = first("augmente le contraste de 20 pourcent")
        XCTAssertEqual(relative.parameter, .contrast)
        XCTAssertEqual(relative.amount, .relative(0.2))

        let decrease = first("baisse la saturation de 30%")
        XCTAssertEqual(decrease.amount, .relative(-0.3))

        let setTo = first("set exposure to -20")
        XCTAssertEqual(setTo.parameter, .exposure)
        XCTAssertEqual(setTo.amount, .absolute(-0.2))

        let plus = first("brightness +15")
        XCTAssertEqual(plus.amount, .relative(0.15))
    }

    func testAdjustMaxAndReset() {
        XCTAssertEqual(first("saturation à fond").amount, .absolute(1))
        XCTAssertEqual(first("reset the contrast").amount, .absolute(0))
        XCTAssertEqual(first("remets la chaleur à zéro").amount, .absolute(0))
        XCTAssertEqual(first("enlève la vignette").parameter, .vignette)
        XCTAssertEqual(first("enlève la vignette").amount, .absolute(0))
    }

    func testUnipolarParameters() {
        let sharper = first("rends la photo plus nette")
        XCTAssertEqual(sharper.parameter, .sharpness)
        XCTAssertGreaterThan(sharper.amount?.value ?? 0, 0)
        let vignette = first("ajoute une vignette")
        XCTAssertEqual(vignette.parameter, .vignette)
        XCTAssertGreaterThan(vignette.amount?.value ?? 0, 0)
        let grain = first("add some film grain")
        XCTAssertEqual(grain.parameter, .grain)
        let noise = first("reduce the noise")
        XCTAssertEqual(noise.parameter, .noiseReduction)
        XCTAssertGreaterThan(noise.amount?.value ?? 0, 0)
    }

    func testMultipleCommandsInOneSentence() {
        let plan = engine.parse("efface le chien et rends l'image plus lumineuse puis recadre en carré", context: .photo)
        XCTAssertEqual(plan.intents.map(\.action), [.removeObject, .adjust, .crop])
        XCTAssertEqual(plan.intents[2].aspect, .square)
        let english = engine.parse("make it black and white and add a vignette", context: .photo)
        XCTAssertEqual(english.intents.map(\.action), [.applyLook, .adjust])
        XCTAssertEqual(english.intents[0].look, .mono)
    }

    // MARK: Looks

    func testLooks() {
        XCTAssertEqual(first("mets en noir et blanc").look, .mono)
        XCTAssertEqual(first("apply the cinematic filter").look, .cinematic)
        XCTAssertEqual(first("give it a vintage look").look, .vintage)
        XCTAssertEqual(first("filtre heure dorée").look, .goldenHour)
        XCTAssertEqual(first("un style dramatique").look, .dramatic)
        XCTAssertEqual(first("enlève le filtre").look, .original)
        let subtle = first("apply a subtle matte look")
        XCTAssertEqual(subtle.look, .matte)
        XCTAssertEqual(subtle.amount?.value ?? 1, 0.5)
    }

    func testAutoEnhance() {
        XCTAssertEqual(first("améliore la photo").action, .autoEnhance)
        XCTAssertEqual(first("auto enhance").action, .autoEnhance)
        XCTAssertEqual(first("make it look better").action, .autoEnhance)
    }

    // MARK: Geometry

    func testCropRotateFlip() {
        XCTAssertEqual(first("recadre en 16:9").aspect, .ratio16x9)
        XCTAssertEqual(first("crop for instagram story").aspect, .ratio9x16)
        XCTAssertEqual(first("crop to square").aspect, .square)
        let crop = first("crop to 4 par 5")
        XCTAssertEqual(crop.action, .crop)
        XCTAssertEqual(crop.aspect, .ratio4x5)
        let rotate = first("tourne de 90 degrés vers la gauche")
        XCTAssertEqual(rotate.action, .rotate)
        XCTAssertEqual(rotate.degrees, -90)
        XCTAssertEqual(first("rotate right").degrees, 90)
        XCTAssertEqual(first("mets la à l'envers").degrees, 180)
        XCTAssertEqual(first("flip it horizontally").flipAxis, .horizontal)
        XCTAssertEqual(first("retourne verticalement").flipAxis, .vertical)
        XCTAssertEqual(first("redresse l'horizon").action, .straighten)
        XCTAssertEqual(first("straighten by 2 degrees").degrees, 2)
        let face = first("recadre sur le visage")
        XCTAssertEqual(face.action, .crop)
        XCTAssertEqual(face.target?.label, "face")
    }

    // MARK: Text

    func testAddText() {
        let quoted = first("ajoute le texte « Été 2026 » en haut en jaune")
        XCTAssertEqual(quoted.action, .addText)
        XCTAssertEqual(quoted.text, "Été 2026")
        XCTAssertEqual(quoted.placement, .top)
        XCTAssertEqual(quoted.color, .yellow)

        let plain = first("add text saying Happy Birthday at the bottom")
        XCTAssertEqual(plain.action, .addText)
        XCTAssertEqual(plain.text, "Happy Birthday")
        XCTAssertEqual(plain.placement, .bottom)

        let french = first("écris Bonjour Paris au centre")
        XCTAssertEqual(french.text, "Bonjour Paris")
        XCTAssertEqual(french.placement, .center)
    }

    func testEditTextWhenLayerExists() {
        var context = IntentContext.photo
        context.textLayerCount = 1
        let bigger = first("make the text bigger", context: context)
        XCTAssertEqual(bigger.action, .editText)
        XCTAssertEqual(bigger.amount?.mode, .multiplier)
        let change = first("change le texte en Hello", context: context)
        XCTAssertEqual(change.action, .editText)
        XCTAssertEqual(change.text, "hello")
    }

    // MARK: Meta

    func testMetaCommands() {
        XCTAssertEqual(first("annule").action, .undo)
        XCTAssertEqual(first("undo that").action, .undo)
        XCTAssertEqual(first("rétablis").action, .redo)
        XCTAssertEqual(first("reviens à l'original").action, .revert)
        XCTAssertEqual(first("montre l'original").action, .compare)
        XCTAssertEqual(first("enregistre la photo").action, .export)
        XCTAssertEqual(first("share it").action, .share)
        XCTAssertEqual(first("zoom out").amount, .multiplier(0.5))
        XCTAssertEqual(first("zoom sur le visage").target?.label, "face")
        XCTAssertEqual(first("what can you do").action, .help)
        XCTAssertEqual(first("upscale x2").action, .upscale)
        XCTAssertEqual(first("augmente la résolution").amount, .absolute(2))
    }

    func testUnknownUtterance() {
        let plan = engine.parse("quelle heure est-il", context: .photo)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.confidence, 0)
    }

    func testLanguageDetection() {
        XCTAssertEqual(engine.parse("efface le chien", context: .photo).language, "fr")
        XCTAssertEqual(engine.parse("remove the dog", context: .photo).language, "en")
        XCTAssertTrue(engine.parse("efface le chien", context: .photo).reply?.contains("efface") ?? false)
    }

    // MARK: Clarification replies

    func testClarificationChoice() {
        let candidates = [
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.7, y: 0.4, width: 0.2, height: 0.3), confidence: 0.85),
        ]
        let pending = ClarificationRequest(question: "Which one?", candidates: candidates, pendingIntent: EditIntent(action: .removeObject, target: ObjectTarget(label: "dog")))
        var context = IntentContext.photo
        context.pendingClarification = pending
        XCTAssertEqual(first("the second one", context: context).index, 2)
        XCTAssertEqual(first("le premier", context: context).index, 1)
        XCTAssertEqual(first("celui de gauche", context: context).target?.spatialHint, .left)
        XCTAssertEqual(first("both", context: context).scope, .all)
        XCTAssertEqual(first("les deux", context: context).action, .chooseCandidate)
        XCTAssertEqual(first("laisse tomber", context: context).action, .cancel)
        XCTAssertEqual(first("number 2", context: context).index, 2)
    }

    // MARK: Video

    func testVideoCutting() {
        let context = IntentContext(mode: .video, clipCount: 1, playheadSeconds: 4, timelineDuration: 20)
        let split = first("coupe ici", context: context)
        XCTAssertEqual(split.action, .split)
        XCTAssertEqual(split.time, 4)
        XCTAssertEqual(first("split at 10 seconds", context: context).time, 10)
        let firstSeconds = first("coupe les 3 premières secondes", context: context)
        XCTAssertEqual(firstSeconds.action, .deleteRange)
        XCTAssertEqual(firstSeconds.timeRange, TimeSpan(start: 0, end: 3))
        let lastSeconds = first("remove the last 2 seconds", context: context)
        XCTAssertEqual(lastSeconds.timeRange, TimeSpan(start: 18, end: 20))
        let range = first("supprime de 5 à 12 secondes", context: context)
        XCTAssertEqual(range.action, .deleteRange)
        XCTAssertEqual(range.timeRange, TimeSpan(start: 5, end: 12))
        let keep = first("keep only from 2 to 8 seconds", context: context)
        XCTAssertEqual(keep.action, .trim)
        XCTAssertEqual(keep.timeRange, TimeSpan(start: 2, end: 8))
        let shorten = first("raccourcis la vidéo à 15 secondes", context: context)
        XCTAssertEqual(shorten.action, .trim)
        XCTAssertEqual(shorten.timeRange, TimeSpan(start: 0, end: 15))
        let clip = first("supprime le clip 2", context: context)
        XCTAssertEqual(clip.action, .deleteClip)
        XCTAssertEqual(clip.clipIndex, 2)
        let beginning = first("delete the beginning", context: context)
        XCTAssertEqual(beginning.timeRange, TimeSpan(start: 0, end: 4))
        let minuteRange = first("cut from 0:30 to 1 minute 10", context: context)
        XCTAssertEqual(minuteRange.timeRange, TimeSpan(start: 30, end: 70))
    }

    func testVideoSpeedAndAudio() {
        let context = IntentContext.video
        XCTAssertEqual(first("accélère x2", context: context).amount, .absolute(2))
        XCTAssertEqual(first("slow motion", context: context).amount, .absolute(0.5))
        XCTAssertEqual(first("ralenti deux fois", context: context).amount, .absolute(0.5))
        XCTAssertEqual(first("speed up a lot", context: context).amount, .absolute(4))
        XCTAssertEqual(first("vitesse normale", context: context).amount, .absolute(1))
        XCTAssertEqual(first("mets la vidéo à l'envers", context: context).action, .reverse)
        XCTAssertEqual(first("coupe le son", context: context).action, .mute)
        XCTAssertEqual(first("remets le son", context: context).action, .unmute)
        let volume = first("baisse le son de 20%", context: context)
        XCTAssertEqual(volume.action, .setVolume)
        XCTAssertEqual(volume.amount, .relative(-0.2))
        XCTAssertEqual(first("louder", context: context).amount?.value ?? 0 > 0, true)
    }

    func testVideoTransitionsMusicAndFrames() {
        let context = IntentContext(mode: .video, clipCount: 3, playheadSeconds: 5, timelineDuration: 30)
        let transition = first("ajoute un fondu enchaîné entre tous les clips", context: context)
        XCTAssertEqual(transition.action, .addTransition)
        XCTAssertEqual(transition.transition, .crossDissolve)
        XCTAssertEqual(transition.scope, .all)
        let black = first("add a fade to black of 1 second", context: context)
        XCTAssertEqual(black.transition, .fadeToBlack)
        XCTAssertEqual(black.time, 1)
        XCTAssertEqual(first("enlève les transitions", context: context).action, .removeTransition)
        let music = first("ajoute une musique lo-fi", context: context)
        XCTAssertEqual(music.action, .addMusic)
        XCTAssertEqual(music.text, "lo fi")
        XCTAssertEqual(first("remove the music", context: context).action, .removeMusic)
        let frame = first("extrais cette image", context: context)
        XCTAssertEqual(frame.action, .extractFrame)
        XCTAssertEqual(frame.time, 5)
        XCTAssertEqual(first("va à 12 secondes", context: context).time, 12)
        XCTAssertEqual(first("go to the beginning", context: context).time, 0)
        XCTAssertEqual(first("avance de 5 secondes", context: context).time, 10)
        XCTAssertEqual(first("stabilise la vidéo", context: context).action, .stabilize)
        XCTAssertEqual(first("freeze frame", context: context).action, .freezeFrame)
        XCTAssertEqual(first("pause", context: context).action, .pause)
        XCTAssertEqual(first("lecture", context: context).action, .play)
    }

    func testVideoSharedCommands() {
        let context = IntentContext.video
        let remove = first("efface le passant derrière moi", context: context)
        XCTAssertEqual(remove.action, .removeObject)
        XCTAssertEqual(remove.target?.label, "person")
        let text = first("ajoute le texte Vacances pendant 3 secondes", context: context)
        XCTAssertEqual(text.action, .addText)
        XCTAssertEqual(text.text, "Vacances")
        XCTAssertEqual(text.timeRange?.duration ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(first("mets en 9:16", context: context).aspect, .ratio9x16)
        XCTAssertEqual(first("plus lumineux", context: context).parameter, .brightness)
        XCTAssertEqual(first("filtre cinéma", context: context).look, .cinematic)
    }
}
