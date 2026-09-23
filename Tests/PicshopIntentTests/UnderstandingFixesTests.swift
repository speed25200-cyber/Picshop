import XCTest
@testable import PicshopCore
@testable import PicshopIntent

/// What a user reported: a photo left upside down with no way back, "supprime
/// toutes les données du tableau" not understood, and replies in English
/// without the accents they typed.
final class UnderstandingFixesTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func document(_ kinds: [EditOperation.Kind] = []) -> PhotoDocument {
        var document = PhotoDocument(title: "t", baseImage: MediaAsset(kind: .image, relativePath: "a.jpg", pixelSize: PSSize(width: 1709, height: 2048)))
        for kind in kinds { document.apply(kind) }
        return document
    }

    // MARK: - Orientation

    func testMirrorThenHalfTurnIsAVerticalFlip() {
        let stack = document([.flip(.horizontal), .rotate(degrees: 180)]).baseLayer!.edits
        XCTAssertTrue(stack.netOrientation.isVerticallyFlipped)
        XCTAssertTrue(document([.flip(.vertical)]).baseOrientation.isVerticallyFlipped)
        XCTAssertTrue(document([.flip(.vertical), .flip(.vertical)]).baseOrientation.isUpright)
        XCTAssertTrue(document([.rotate(degrees: 90), .rotate(degrees: -90)]).baseOrientation.isUpright)
        XCTAssertTrue(document([.rotate(degrees: 12), .straighten(degrees: 3)]).baseOrientation.isUpright, "tilts are deliberate")
    }

    func testResetOrientationBringsEveryCombinationUpright() {
        let steps: [EditOperation.Kind] = [.flip(.horizontal), .flip(.vertical), .rotate(degrees: 90), .rotate(degrees: 180), .rotate(degrees: -90), .rotate(degrees: 270)]
        for first in steps {
            for second in steps {
                for third in steps {
                    let cropped = document([.crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
                    var doc = document([.crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)), first, second, third])
                    let before = doc.baseLayer!.edits.operations.count
                    let changed = doc.resetOrientation()
                    XCTAssertTrue(doc.baseOrientation.isUpright, "\(first) \(second) \(third)")
                    XCTAssertEqual(changed, doc.baseLayer!.edits.operations.count > before)
                    XCTAssertLessThanOrEqual(doc.baseLayer!.edits.operations.count - before, 2)
                    XCTAssertEqual(doc.baseLayer!.edits.resolvedCrop, PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), "earlier edits stay")
                    XCTAssertEqual(doc.canvasSize, cropped.canvasSize, "upright again means the frame is the cropped photo's own shape")
                }
            }
        }
    }

    func testRestoredToImportDropsEditsFromEarlierSessions() {
        let doc = document([.flip(.horizontal), .rotate(degrees: 90), .crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let restored = doc.restoredToImport()
        XCTAssertTrue(restored.baseLayer!.edits.isEmpty)
        XCTAssertEqual(restored.canvasSize, PSSize(width: 1709, height: 2048))
    }

    func testUpsideDownComplaintPutsItRightWayUp() {
        for phrase in ["c'est à l'envers", "l'image est à l'envers", "la photo s'affiche à l'envers", "remets-la à l'endroit", "mets-la dans le bon sens",
                       "it's upside down", "put it the right way up", "annule le miroir"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.action, .resetOrientation, phrase)
        }
        let turn = engine.parse("mets-la à l'envers", context: .photo).intents.first
        XCTAssertEqual(turn?.action, .rotate)
        XCTAssertEqual(turn?.degrees, 180)
    }

    func testInverseAloneIsNotAMirror() {
        XCTAssertNotEqual(engine.parse("inverse les couleurs", context: .photo).intents.first?.action, .flip)
        XCTAssertEqual(engine.parse("inverse l'image horizontalement", context: .photo).intents.first?.flipAxis, .horizontal)
        XCTAssertEqual(engine.parse("retourne de haut en bas", context: .photo).intents.first?.flipAxis, .vertical)
        XCTAssertEqual(engine.parse("mirror it", context: .photo).intents.first?.flipAxis, .horizontal)
        XCTAssertEqual(Replies.reply(for: EditIntent(action: .flip, flipAxis: .horizontal), language: .french), "Image retournée en miroir.")
    }

    func testResetExecutorUndoesTheFlipOrTurnsAnUpsideDownShot() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        let (fixed, result) = await executor.execute(EditIntent(action: .resetOrientation), on: document([.flip(.horizontal), .rotate(degrees: 180)]), context: .photo)
        XCTAssertTrue(fixed.baseOrientation.isUpright)
        guard case .applied = result.outcome else { return XCTFail("expected an edit") }
        let complaint = engine.parse("c'est à l'envers", context: .photo).intents[0]
        let (turned, _) = await executor.execute(complaint, on: document(), context: .photo)
        XCTAssertEqual(turned.baseLayer?.edits.operations.last?.kind, .rotate(degrees: 180), "a photo shot upside down is turned over")
    }

    /// Asking for the right way up, or saying it is, never turns an upright photo over.
    func testRestoreOrStatementNeverTurnsAnUprightPhoto() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        for phrase in ["remets-la à l'endroit", "mets-la dans le bon sens", "orientation d'origine", "remets l'orientation d'origine", "reset the orientation",
                       "put it the right way up", "à l'endroit", "undo the flip", "unflip it", "annule le miroir",
                       "c'est dans le bon sens maintenant", "it's the right way up now", "c'est à l'endroit", "parfait, elle est à l'endroit",
                       "c'est bon, elle est dans le bon sens", "voilà, c'est à l'endroit maintenant"] {
            var photo = document()
            for intent in engine.parse(phrase, context: .photo).intents {
                let (updated, result) = await executor.execute(intent, on: photo, context: .photo)
                if case .applied(let label) = result.outcome { XCTAssertTrue(label.isEmpty, "\(phrase): \(label)") }
                photo = updated
            }
            XCTAssertTrue(photo.baseLayer!.edits.isEmpty, phrase)
        }
        let statement = engine.parse("c'est à l'endroit maintenant", context: .photo)
        XCTAssertEqual(statement.intents.map(\.action), [.confirm], "it says so; nothing to change")
        XCTAssertEqual(engine.parse("parfait, elle est à l'endroit", context: .photo).reply, "OK.")
        let (_, already) = await executor.execute(engine.parse("remets-la à l'endroit", context: .photo).intents[0], on: document(), context: .photo)
        XCTAssertEqual(already.outcome, .info(message: "La photo est déjà à l'endroit."))
        XCTAssertEqual(engine.parse("elle n'est pas à l'endroit", context: .photo).intents.first?.degrees, 180, "a negation complains")
        XCTAssertEqual(engine.parse("it isn't the right way up", context: .photo).intents.first?.degrees, 180)
    }

    /// "C'est à l'envers" turns an upside-down shot over; "c'est à l'endroit maintenant" then keeps it.
    func testComplaintThenThanksKeepsItFixed() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        var photo = document()
        for phrase in ["c'est à l'envers", "voilà, c'est à l'endroit maintenant"] {
            for intent in engine.parse(phrase, context: .photo).intents { photo = await executor.execute(intent, on: photo, context: .photo).0 }
        }
        XCTAssertEqual(photo.baseOrientation, EditStack.Orientation(mirrored: false, quarterTurns: 2), "turned over once, not back again")
        let both = engine.parse("la photo est à l'envers, tu peux la remettre à l'endroit ?", context: .photo)
        XCTAssertEqual(both.intents.map(\.action), [.resetOrientation], "one request, not a turn and its undoing")
        XCTAssertEqual(both.intents.first?.degrees, 180)
    }

    /// "Annule le miroir" takes the mirror away and keeps a quarter turn made on purpose.
    func testUndoTheMirrorKeepsTheTurns() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        let intent = engine.parse("annule le miroir", context: .photo).intents[0]
        XCTAssertEqual(intent.action, .resetOrientation)
        XCTAssertEqual(intent.flipAxis, .horizontal)
        let (turned, _) = await executor.execute(intent, on: document([.rotate(degrees: 90), .flip(.horizontal)]), context: .photo)
        XCTAssertEqual(turned.baseOrientation, EditStack.Orientation(mirrored: false, quarterTurns: 1))
        let (vertical, _) = await executor.execute(intent, on: document([.flip(.vertical), .rotate(degrees: 90)]), context: .photo)
        XCTAssertEqual(vertical.baseOrientation, EditStack.Orientation(mirrored: false, quarterTurns: 1), "the flip upside down goes, the quarter turn stays")
        let (plain, result) = await executor.execute(intent, on: document([.rotate(degrees: 90)]), context: .photo)
        XCTAssertEqual(plain.baseOrientation, EditStack.Orientation(mirrored: false, quarterTurns: 1))
        XCTAssertEqual(result.outcome, .info(message: "La photo n'est pas en miroir."))
    }

    func testRemoveMirrorTakesOutTheLastFlipOnly() {
        let steps: [EditOperation.Kind] = [.flip(.horizontal), .flip(.vertical), .rotate(degrees: 90), .rotate(degrees: 180), .rotate(degrees: -90)]
        for first in steps {
            for second in steps {
                for third in steps {
                    let kinds = [first, second, third]
                    var doc = document(kinds)
                    guard doc.baseOrientation.mirrored, let last = kinds.lastIndex(where: { if case .flip = $0 { return true } else { return false } }) else {
                        XCTAssertFalse(doc.removeMirror(), "\(kinds)")
                        continue
                    }
                    var without = kinds
                    without.remove(at: last)
                    XCTAssertTrue(doc.removeMirror(), "\(kinds)")
                    XCTAssertEqual(doc.baseOrientation, document(without).baseOrientation, "\(kinds)")
                    XCTAssertEqual(doc.canvasSize, document(without).canvasSize, "\(kinds)")
                }
            }
        }
    }

    /// "À l'endroit où…" is a place; quoted words are text; other commands keep their verbs.
    func testOrientationWordsElsewhereKeepTheirMeaning() {
        let photo: [(String, IntentAction)] = [
            ("écris « Paris » à l'endroit du ciel", .addText), ("ajoute le texte Bonjour à l'endroit où il y a le ciel", .addText),
            ("écris \"c'est à l'envers\" en bas", .addText), ("ajoute le texte « à l'endroit »", .addText), ("ajoute le texte \"Right way up\"", .addText),
            ("Ajoute le texte « Tout est à l'endroit » en haut", .addText), ("supprime la personne qui est à l'envers", .removeObject),
            ("efface le texte qui est à l'envers", .removeObject), ("Efface la tache à l'endroit où j'ai touché", .removeObject),
            ("exporte-la dans le bon sens", .export), ("sauvegarde dans le bon sens", .export), ("zoom à l'endroit du visage", .zoom),
            ("floute le visage à l'endroit", .blurObject), ("Floute le visage à l'endroit indiqué", .blurObject),
            ("tourne-la de 90 degrés dans le bon sens", .rotate), ("flip it so it's upside down", .rotate),
        ]
        for (phrase, action) in photo {
            let plan = engine.parse(phrase, context: .photo)
            XCTAssertEqual(plan.intents.map(\.action), [action], phrase)
        }
        XCTAssertEqual(engine.parse("tourne-la de 90 degrés dans le bon sens", context: .photo).intents.first?.degrees, 90)
        for phrase in ["Mets le chien à l'endroit du chat", "Mets le texte dans le bon sens"] {
            XCTAssertNotEqual(engine.parse(phrase, context: .photo).intents.first?.action, .resetOrientation, phrase)
        }
        let video: [(String, IntentAction)] = [("coupe à l'endroit où je dis bonjour", .cutWords), ("coupe le passage à l'endroit où il rit", .split),
                                               ("zoom à l'endroit du visage", .zoom), ("passe la vidéo à l'envers", .reverse)]
        for (phrase, action) in video {
            XCTAssertEqual(engine.parse(phrase, context: .video).intents.first?.action, action, phrase)
        }
    }

    /// In a video "à l'endroit" plays it forwards again; a clip said to be upside down with
    /// nothing turned is turned over; the reply names neither the photo nor the video.
    func testVideoRightWayUp() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices(), language: .french)
        let timeline = VideoTimeline(title: "Clip", asset: MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 20, frameRate: 30))
        let context = IntentContext(mode: .video, clipCount: 1, timelineDuration: 20)
        let clipID = timeline.clips[0].id

        let complaint = engine.parse("la vidéo est à l'envers", context: context)
        XCTAssertEqual(complaint.intents.first?.degrees, 180)
        XCTAssertFalse(Replies.reply(for: complaint.intents[0], language: .french).contains("photo"))
        let (turned, turnResult) = await executor.execute(complaint.intents[0], on: timeline, context: context)
        XCTAssertEqual(turned.clip(id: clipID)?.rotation, 180, "filmed upside down")
        XCTAssertEqual(turnResult.outcome, .applied(label: "Rotate 180°"))
        let (back, _) = await executor.execute(complaint.intents[0], on: turned, context: context)
        XCTAssertEqual(back.clip(id: clipID)?.rotation, 0)

        let (same, info) = await executor.execute(engine.parse("remets la vidéo à l'endroit", context: context).intents[0], on: timeline, context: context)
        XCTAssertEqual(same, timeline)
        XCTAssertEqual(info.outcome, .info(message: "La vidéo est déjà à l'endroit."))

        var reversed = timeline
        reversed.update(clipID: clipID) { $0.isReversed = true; $0.rotation = 0 }
        for phrase in ["lis la vidéo à l'endroit", "remets la lecture à l'endroit", "joue la vidéo à l'endroit", "remets la vidéo à l'endroit", "play it the right way round"] {
            let intent = engine.parse(phrase, context: context).intents[0]
            XCTAssertEqual(intent.action, .resetOrientation, phrase)
            let (forwards, result) = await executor.execute(intent, on: reversed, context: context)
            XCTAssertEqual(forwards.clip(id: clipID)?.isReversed, false, phrase)
            XCTAssertEqual(result.outcome, .applied(label: "Play Forwards"), phrase)
        }

        var mirrored = timeline
        mirrored.update(clipID: clipID) { $0.rotation = 90; $0.flipHorizontal = true }
        let (unmirrored, _) = await executor.execute(engine.parse("annule le miroir", context: context).intents[0], on: mirrored, context: context)
        XCTAssertEqual(unmirrored.clip(id: clipID)?.flipHorizontal, false)
        XCTAssertEqual(unmirrored.clip(id: clipID)?.rotation, 90, "the rotation stays")
    }

    /// With the voice language on "auto", the French complaints are answered in French.
    func testFrenchOrientationIsAnsweredInFrench() {
        for phrase in ["c'est à l'envers", "C'est à l'envers.", "c’est à l’envers", "l'image est à l'envers", "la photo est à l'envers", "la photo s'affiche à l'envers",
                       "elle est à l'envers", "remets à l'endroit", "retourne-la à l'endroit", "c'est à l'endroit maintenant", "corrige l'orientation", "C'est tête en bas",
                       "c'est a l'envers", "Supprime toutes les données du tableau"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).language, "fr", phrase)
        }
        for phrase in ["it's upside down", "remove all the numbers", "put it the right way up", "remove a person"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).language, "en", phrase)
        }
    }

    // MARK: - Words in pictures

    func testTableDataIsText() {
        let plan = engine.parse("Supprime toutes les données du tableau.", context: .photo)
        let intent = plan.intents.first
        XCTAssertEqual(intent?.action, .removeObject)
        XCTAssertEqual(intent?.target?.label, "text")
        XCTAssertEqual(intent?.target?.matchesAll, true)
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, "understood at once, no model needed")
        XCTAssertEqual(intent?.target?.originalPhrase, "toutes les données du tableau")
        XCTAssertEqual(plan.reply, "J'efface toutes les données du tableau.")
        for phrase in ["efface les chiffres", "enlève les dates", "remove all the numbers", "efface les légendes", "supprime les valeurs du tableau", "erase the data"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.target?.label, "text", phrase)
        }
        XCTAssertEqual(engine.parse("remove the cell phone", context: .photo).intents.first?.target?.label, "phone")
        XCTAssertNotEqual(engine.parse("supprime les données de localisation", context: .photo).intents.first?.target?.label, "text")
    }

    func testRepliesKeepTheWordsAsSaid() {
        XCTAssertEqual(engine.parse("efface l'arbre", context: .photo).reply, "J'efface l'arbre.")
        XCTAssertEqual(engine.parse("enlève le vélo à gauche", context: .photo).intents.first?.target?.originalPhrase, "le vélo à gauche")
        // More tokens than words (elisions, hyphens), and a decimal comma.
        XCTAssertEqual(engine.parse("efface la voiture à l'arrière-plan", context: .photo).reply, "J'efface la voiture à l'arrière-plan.")
        XCTAssertEqual(engine.parse("retire l'homme au T-shirt", context: .photo).reply, "J'efface l'homme au T-shirt.")
        XCTAssertEqual(engine.parse("supprime la valeur 87,3", context: .photo).reply, "J'efface la valeur 87,3.")
        XCTAssertEqual(engine.parse("supprime le chiffre 87,3 du tableau", context: .photo).reply, "J'efface le chiffre 87,3 du tableau.")
    }

    /// Quoted words keep both quotes, so the literal is what is looked for.
    func testQuotedTargetsKeepTheirQuotes() {
        let cases: [(String, String)] = [("efface le texte « SOLDES »", "le texte « SOLDES »"), ("remove the text \"SALE\"", "the text \"SALE\""),
                                         ("supprime l'étiquette « Prix »", "l'étiquette « Prix »"), ("efface le texte «SOLDES»", "le texte «SOLDES»"),
                                         ("efface le texte “SOLDES”", "le texte “SOLDES”"), ("efface « SOLDES »", "« SOLDES »")]
        for (phrase, said) in cases {
            let plan = engine.parse(phrase, context: .photo)
            XCTAssertEqual(plan.intents.first?.target?.originalPhrase, said, phrase)
            XCTAssertEqual(plan.intents.first?.target?.label, "text", phrase)
            XCTAssertGreaterThanOrEqual(plan.confidence, 0.85, "\(phrase): no wait for a model")
        }
        XCTAssertEqual(engine.parse("efface le texte « SOLDES »", context: .photo).reply, "J'efface le texte « SOLDES ».")
        XCTAssertEqual(engine.parse("floute « SOLDES »", context: .photo).intents.first?.target?.label, "text")
    }

    /// "Un certain nombre de personnes" counts people; a number plate is a plate; the table data is data.
    func testQuantitiesPlatesAndTableData() {
        for phrase in ["efface un certain nombre de personnes", "remove a number of people", "enlève le nombre de personnes"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.target?.label, "person", phrase)
        }
        for phrase in ["efface le numéro de la plaque", "remove the number plate", "floute la plaque d'immatriculation", "blur the licence plate"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.target?.label, "sign", phrase)
        }
        for phrase in ["remove the table data", "erase the table numbers", "delete the table values", "clear the table data", "remove the data in the table"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.target?.label, "text", phrase)
        }
        XCTAssertEqual(engine.parse("remove the table", context: .photo).intents.first?.target?.label, "table")
        XCTAssertEqual(engine.parse("efface les chiffres", context: .photo).intents.first?.target?.label, "text")
    }

    /// After "circle the area, then say it again", the blur or move acts on what was circled.
    func testBlurAndMoveFallBackToTheCircledArea() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        let blur = engine.parse("floute la plaque", context: .photo).intents[0]
        let (_, handOver) = await executor.execute(blur, on: document(), context: .photo)
        XCTAssertTrue(handOver.effects.contains(.message("selectRegion")))
        let circled = MaskReference(source: .lasso([PSPoint(x: 0.2, y: 0.2), PSPoint(x: 0.4, y: 0.2), PSPoint(x: 0.3, y: 0.4)]), boundingBox: PSRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        let context = IntentContext(mode: .photo, selectionMask: circled)
        let (blurred, result) = await executor.execute(blur, on: document(), context: context)
        guard case .applied = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(blurred.baseLayer?.edits.operations.last?.kind, .blurRegion(circled, amount: 1))
        XCTAssertTrue(result.effects.contains(.message("selectionUsed")))
        let move = engine.parse("déplace le bidule à gauche", context: .photo).intents[0]
        let (moved, moveResult) = await executor.execute(move, on: document(), context: context)
        guard case .applied = moveResult.outcome else { return XCTFail("\(moveResult.outcome)") }
        guard case .moveObject(let mask, let offset) = moved.baseLayer?.edits.operations.last?.kind else { return XCTFail("expected a move") }
        XCTAssertEqual(mask, circled)
        XCTAssertLessThan(offset.x, 0)
    }

    /// Revert also takes the text-behind cut-out, which copies the photo's edits.
    func testRestoredToImportDropsTheSubjectCutOut() {
        var doc = document([.crop(PSRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))])
        doc.placeTextBehindSubject("Paris", subjectMask: MaskReference(source: .subject), placeholder: "TITRE")
        let restored = doc.restoredToImport()
        XCTAssertFalse(restored.layers.contains { $0.name == PhotoDocument.subjectLayerName })
        XCTAssertTrue(restored.layers.contains { $0.name == "Paris" })
        XCTAssertNil(restored.baseLayer?.edits.resolvedCrop)
        var plain = document()
        plain.placeTextBehindSubject("Paris", subjectMask: MaskReference(source: .subject), placeholder: "TITRE")
        XCTAssertEqual(plain.restoredToImport().layers.count, plain.layers.count, "with nothing to undo on the photo the cut-out still lines up")
    }

    func testUnknownThingsGetTheModelsFullAttention() async {
        struct ThoughtfulEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                try await Task.sleep(for: .milliseconds(300))
                return EditPlan(utterance: utterance, intents: [EditIntent(action: .removeObject, target: ObjectTarget(label: "text"))], confidence: 0.9, engine: .proLocal)
            }
        }
        let router = HybridIntentRouter(preferredEngine: .proLocal, configuration: .init(llmTimeout: .seconds(3), improveTimeout: .milliseconds(50)))
        await router.register(ThoughtfulEngine())
        let plan = await router.plan("efface le zinzin", context: .photo)
        XCTAssertEqual(plan.engine, .proLocal, "a noun the grammar does not know is worth waiting for")
    }
}
