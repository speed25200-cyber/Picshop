import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class SpeechChunkerTests: XCTestCase {
    /// Feeds the text in deltas of `size` characters and returns every chunk.
    private func chunks(_ text: String, size: Int = 3, language: NormalizedUtterance.Language = .french) -> ([String], Bool) {
        var chunker = SpeechChunker(language: language)
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result += chunker.append(String(text[index..<end]))
            index = end
        }
        result += chunker.finish()
        return (result, chunker.lastEndsWithQuestion)
    }

    func testFirstChunkFlushesEarlyThenSentences() {
        let (result, question) = chunks("Bonne idée pour la lumière, je réchauffe un peu les tons. Ensuite on regarde le ciel ensemble. Tu veux un recadrage aussi ?")
        XCTAssertEqual(result, ["Bonne idée pour la lumière,", "je réchauffe un peu les tons.", "Ensuite on regarde le ciel ensemble.", "Tu veux un recadrage aussi ?"])
        XCTAssertTrue(question)
    }

    func testShortFirstClauseWaitsForFourWords() {
        let (result, _) = chunks("Oui, je le fais tout de suite. Voilà.")
        XCTAssertEqual(result, ["Oui, je le fais tout de suite.", "Voilà."])
    }

    func testTwelveWordFirstChunk() {
        let (result, _) = chunks("Je vais retirer le chien qui est assis juste à gauche du banc en bois puis éclaircir.")
        XCTAssertEqual(result.first, "Je vais retirer le chien qui est assis juste à gauche du")
        XCTAssertEqual(result.count, 2)
    }

    func testNeverSplitsNumbersAbbreviationsURLsOrQuotes() {
        let (numbers, _) = chunks("C'est prêt. On passe de 3.5 à 10:30 environ puis ça repart pour la suite. Fin.")
        XCTAssertEqual(numbers, ["C'est prêt.", "On passe de 3.5 à 10:30 environ puis ça repart pour la suite.", "Fin."])
        let (abbreviations, _) = chunks("Voilà. Il y a M. Dupont, Mme Martin, etc. sur la photo. Fin.")
        XCTAssertEqual(abbreviations, ["Voilà.", "Il y a M. Dupont, Mme Martin, etc. sur la photo.", "Fin."])
        let (english, _) = chunks("Sure. Use a warm look, e.g. golden hour or vs. matte. Done.", language: .english)
        XCTAssertEqual(english, ["Sure.", "Use a warm look, e.g. golden hour or vs. matte.", "Done."])
        let (quoted, _) = chunks("D'accord. J'écris « Été 2026. Le retour. » en haut. Voilà.")
        XCTAssertEqual(quoted, ["D'accord.", "J'écris « Été 2026. Le retour. » en haut.", "Voilà."])
        let (url, _) = chunks("Regarde. Le site picshop.app. explique tout. Fin.")
        XCTAssertEqual(url.first, "Regarde.")
    }

    func testFrenchSpacingBeforePunctuation() {
        let (result, question) = chunks("On y va\u{202F}! Tu préfères le ciel ou la mer\u{202F}?")
        XCTAssertEqual(result, ["On y va\u{202F}!", "Tu préfères le ciel ou la mer\u{202F}?"])
        XCTAssertTrue(question)
    }

    func testLongSentencesSplitPastTwentyEightWords() {
        let long = "Premier. " + (1...40).map { "mot\($0)" }.joined(separator: " ") + "."
        let (result, _) = chunks(long)
        XCTAssertEqual(result.first, "Premier.")
        XCTAssertEqual(result[1].split(separator: " ").count, 28)
        let withComma = "Premier. " + (1...20).map { "mot\($0)" }.joined(separator: " ") + ", " + (21...40).map { "mot\($0)" }.joined(separator: " ") + "."
        let (commas, _) = chunks(withComma)
        XCTAssertTrue(commas[1].hasSuffix("mot20,"))
    }

    func testChunkerIsIndependentOfDeltaSizes() {
        let text = "Bonne idée pour la lumière, je réchauffe un peu. Puis le ciel ? Enfin, e.g. un filtre. Ok !"
        let reference = chunks(text, size: 1000).0
        for size in [1, 2, 5, 11] { XCTAssertEqual(chunks(text, size: size).0, reference, "\(size)") }
    }

    func testSpeakableText() {
        XCTAssertEqual(SpeakableText.clean("**Super** idée 😀 : un _look_ `mono` !"), "Super idée : un look mono !")
        XCTAssertEqual(SpeakableText.clean("# Titre\n- un\n- deux\n1. trois"), "Titre un deux trois")
        XCTAssertEqual(SpeakableText.clean("Voir https://picshop.app/aide et www.example.com maintenant"), "Voir et maintenant")
        XCTAssertEqual(SpeakableText.clean("Accélère ×2 puis x3 la vidéo"), "Accélère fois deux puis fois trois la vidéo")
        XCTAssertEqual(SpeakableText.clean("Speed it up x2 please"), "Speed it up times two please")
        XCTAssertEqual(SpeakableText.clean("Avant → après <b>net</b> 👍🏽"), "Avant après net")
        XCTAssertEqual(SpeakableText.clean("  trop   d'espaces \n ici  "), "trop d'espaces ici")
        XCTAssertEqual(SpeakableText.clean("snake_case_name reste"), "snake_case_name reste")
    }
}

final class VoiceSelectorTests: XCTestCase {
    private func voice(_ id: String, _ language: String, _ quality: VoiceCandidate.Quality, novelty: Bool = false, personal: Bool = false) -> VoiceCandidate {
        VoiceCandidate(identifier: id, name: id.capitalized, language: language, quality: quality, isNovelty: novelty, isPersonalVoice: personal)
    }

    func testScoring() {
        let voices = [
            voice("thomas", "fr-FR", .standard), voice("amelie", "fr-CA", .premium), voice("audrey", "fr-FR", .premium),
            voice("bells", "fr-FR", .premium, novelty: true), voice("me", "fr-FR", .premium, personal: true), voice("ava", "en-US", .premium),
            voice("zoe", "fr-FR", .enhanced),
        ]
        XCTAssertEqual(VoiceSelector.best(for: "fr", among: voices)?.identifier, "audrey", "premium + exact region")
        XCTAssertEqual(VoiceSelector.best(for: "fr-FR", among: voices, region: "CA")?.identifier, "amelie")
        XCTAssertEqual(VoiceSelector.best(for: "fr", among: voices, preferredIdentifier: "thomas")?.identifier, "thomas")
        XCTAssertEqual(VoiceSelector.best(for: "fr", among: voices, preferredIdentifier: "me")?.identifier, "me", "personal voices only when chosen")
        XCTAssertEqual(VoiceSelector.best(for: "en-US", among: voices)?.identifier, "ava")
        XCTAssertNil(VoiceSelector.best(for: "de", among: voices))
        XCTAssertEqual(VoiceSelector.best(for: "fr", among: [voice("bells", "fr-FR", .premium, novelty: true), voice("thomas", "fr-FR", .standard)])?.identifier, "thomas")
        let tie = [voice("b-voice", "fr-FR", .enhanced), voice("a-voice", "fr-FR", .enhanced)]
        XCTAssertEqual(VoiceSelector.best(for: "fr", among: tie)?.identifier, "a-voice", "ties go by name")
    }

    func testPickerOrderAndHint() {
        let voices = [voice("thomas", "fr-FR", .standard), voice("amelie", "fr-CA", .premium), voice("audrey", "fr-FR", .premium),
                      voice("bells", "fr-FR", .premium, novelty: true), voice("zoe", "fr-FR", .enhanced), voice("ava", "en-US", .premium)]
        XCTAssertEqual(VoiceSelector.sorted(voices, language: "fr").map(\.identifier), ["audrey", "amelie", "zoe", "thomas"])
        XCTAssertTrue(VoiceSelector.needsBetterVoiceHint(nil))
        XCTAssertTrue(VoiceSelector.needsBetterVoiceHint(voices[0]))
        XCTAssertFalse(VoiceSelector.needsBetterVoiceHint(voices[4]))
    }
}

final class LiveTurnRouterTests: XCTestCase {
    private let engine = RuleBasedIntentEngine()

    private func route(_ text: String, brain: LiveBrainKind = .claude, ideas: Int = 3, jobRunning: Bool = false, fastLane: Bool = true) -> LiveLane {
        LiveTurnRouter.route(text, grammar: engine.parse(text, context: .photo), brain: brain, ideasOnScreen: ideas, jobRunning: jobRunning, fastLane: fastLane)
    }

    func testControlPhrases() {
        XCTAssertEqual(route("tais-toi"), .control(.stopTalking))
        XCTAssertEqual(route("stop"), .control(.stopTalking))
        XCTAssertEqual(route("chut"), .control(.stopTalking))
        XCTAssertEqual(route("arrête le mode live"), .control(.endLive))
        XCTAssertEqual(route("au revoir"), .control(.endLive))
        XCTAssertEqual(route("end live"), .control(.endLive))
        XCTAssertEqual(route("bye"), .control(.endLive))
        XCTAssertEqual(route("répète"), .control(.repeatLast))
        XCTAssertEqual(route("say that again"), .control(.repeatLast))
        XCTAssertEqual(route("on recommence"), .control(.startOver))
        XCTAssertEqual(route("start over"), .control(.startOver))
        XCTAssertEqual(route("nouvelle conversation"), .control(.startOver))
        XCTAssertEqual(route("annule", jobRunning: true), .control(.cancelJob))
        XCTAssertNotEqual(route("annule", jobRunning: false), .control(.cancelJob), "annule without a job is an undo request")
    }

    func testIdeaReferences() {
        XCTAssertEqual(route("la deuxième"), .control(.chooseIdea(2)))
        XCTAssertEqual(route("la première idée"), .control(.chooseIdea(1)))
        XCTAssertEqual(route("prends la troisième"), .control(.chooseIdea(3)))
        XCTAssertEqual(route("idea two"), .control(.chooseIdea(2)))
        XCTAssertEqual(route("the last one"), .control(.chooseIdea(3)))
        XCTAssertEqual(route("la dernière", ideas: 2), .control(.chooseIdea(2)))
        XCTAssertNotEqual(route("la deuxième", ideas: 0), .control(.chooseIdea(2)), "no chips, no idea")
        XCTAssertNotEqual(route("la troisième", ideas: 2), .control(.chooseIdea(3)))
        XCTAssertNotEqual(route("efface la deuxième personne"), .control(.chooseIdea(2)), "a candidate, not a chip")
    }

    func testAnswersToAPendingChoiceStayLocal() {
        let dogs = [ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
                    ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.75, y: 0.4, width: 0.2, height: 0.3), confidence: 0.88)]
        let request = ClarificationRequest(question: "Lequel ?", candidates: dogs, pendingIntent: EditIntent(action: .removeObject, target: ObjectTarget(label: "dog")))
        let context = IntentContext(mode: .photo, pendingClarification: request)
        func lane(_ text: String, fastLane: Bool = true) -> LiveLane {
            // A choice hides the idea chips: the session passes 0 ideas on screen.
            LiveTurnRouter.route(text, grammar: engine.parse(text, context: context), brain: .claude, ideasOnScreen: 0, jobRunning: false, fastLane: fastLane)
        }
        for text in ["le deuxième", "la dernière", "les deux", "celui de gauche", "the second one"] {
            XCTAssertTrue(isLocal(lane(text)), text)
            XCTAssertTrue(isLocal(lane(text, fastLane: false)), "\(text): no brain can pick a candidate")
        }
        XCTAssertEqual(route("la dernière", ideas: 3), .control(.chooseIdea(3)), "with chips on screen and nothing pending, an idea")
        let cancel = engine.parse("annule", context: context)
        XCTAssertTrue(LiveTurnRouter.dismissesPendingChoice(cancel))
        XCTAssertFalse(LiveTurnRouter.answersPendingChoice(cancel))
        XCTAssertFalse(LiveTurnRouter.dismissesPendingChoice(engine.parse("plus chaud", context: context)))
        XCTAssertFalse(LiveTurnRouter.answersPendingChoice(engine.parse("le deuxième", context: .photo)), "no choice pending, no candidate")
    }

    private func isLocal(_ lane: LiveLane) -> Bool {
        if case .local = lane { return true }
        return false
    }

    func testLocalBrainTakesEverything() {
        XCTAssertTrue(isLocal(route("pourquoi ?", brain: .local)))
        XCTAssertEqual(route("tais-toi", brain: .local), .control(.stopTalking), "control phrases still come first")
    }

    func testQuestionsGoToTheBrain() {
        for text in ["tu penses quoi du ciel ?", "pourquoi c'est flou", "qu'est-ce que tu ferais", "à ton avis", "une idée pour la lumière",
                     "what would you do", "should I crop it", "any advice", "comment rendre ça plus chaud"] {
            XCTAssertEqual(route(text), .brain(isQuestion: true), text)
        }
    }

    func testFastLane() {
        XCTAssertTrue(isLocal(route("plus lumineux")))
        XCTAssertTrue(isLocal(route("tourne à droite")))
        XCTAssertTrue(isLocal(route("annule")), "undo is instant")
        XCTAssertEqual(route("plus lumineux", fastLane: false), .brain(isQuestion: false))
        XCTAssertEqual(route("efface le chien"), .brain(isQuestion: false), "not an instant action")
        XCTAssertEqual(route("plus lumineux et plus contrasté mais sans toucher au ciel ni au visage de la dame"), .brain(isQuestion: false), "too long")
        XCTAssertEqual(route("mets un chapeau au chien"), .brain(isQuestion: false))
    }
}

final class IdeaEngineTests: XCTestCase {
    private func valid(_ ideas: [LiveIdea], mode: EditorMode) {
        let context = mode == .video ? IntentContext(mode: .video, clipCount: 3, timelineDuration: 120) : IntentContext.photo
        for idea in ideas {
            XCTAssertNoThrow(try ToolInputValidator(mode: mode).steps(raw: idea.steps, context: context).get(), idea.title)
            XCTAssertTrue((1...4).contains(idea.steps.count))
            XCTAssertLessThanOrEqual(idea.title.count, 26)
            XCTAssertLessThanOrEqual(idea.title.split(separator: " ").count, 4)
            XCTAssertLessThanOrEqual(idea.why.count, 90)
            XCTAssertTrue(IdeaSymbols.allowed.contains(idea.symbol))
            XCTAssertEqual(idea.source, .heuristic)
        }
    }

    private func photo(_ scene: SceneDescription?, applied: [String] = [], generative: Bool = true) -> LiveEditorState {
        var state = LiveEditorState(mode: .photo, version: 1)
        state.scene = scene
        state.appliedEdits = applied
        state.hasGenerativeEngine = generative
        return state
    }

    func testPortraitLandscapeProductDarkAndDull() {
        let portrait = IdeaEngine.heuristic(photo(SceneDescription(people: 1, faces: 1, labels: ["portrait"])), dismissed: [], language: .french)
        XCTAssertEqual(portrait.map(\.title), ["Portrait doux", "Flouter le fond", "Rééclairer"])
        let landscape = IdeaEngine.heuristic(photo(SceneDescription(labels: ["beach", "sky"])), dismissed: [], language: .english)
        XCTAssertEqual(landscape.first?.title, "Brighten the sky")
        let product = IdeaEngine.heuristic(photo(SceneDescription(labels: ["shoe", "product"])), dismissed: [], language: .french)
        XCTAssertEqual(product.first?.title, "Fond blanc")
        let dark = IdeaEngine.heuristic(photo(SceneDescription(labels: ["room"], brightness: 0.2, colourfulness: 0.1)), dismissed: [], language: .french)
        XCTAssertEqual(Array(dark.prefix(2)).map(\.title), ["Déboucher les ombres", "Raviver les couleurs"])
        let crowd = IdeaEngine.heuristic(photo(SceneDescription(people: 4, labels: ["street"])), dismissed: [], language: .french)
        XCTAssertTrue(crowd.map(\.title).contains("Enlever les passants"))
        for ideas in [portrait, landscape, product, dark, crowd] {
            XCTAssertLessThanOrEqual(ideas.count, 3)
            valid(ideas, mode: .photo)
        }
    }

    func testExclusionsAndGenericSet() {
        let generic = IdeaEngine.heuristic(photo(nil), dismissed: [], language: .french)
        XCTAssertEqual(generic.map(\.title), ["Améliorer", "Recadrer", "Look éclatant"])
        valid(generic, mode: .photo)
        let applied = IdeaEngine.heuristic(photo(nil, applied: ["Auto Enhance"]), dismissed: [], language: .french)
        XCTAssertFalse(applied.map(\.title).contains("Améliorer"), "already applied")
        let dismissed = IdeaEngine.heuristic(photo(nil), dismissed: [generic[1].id], language: .french)
        XCTAssertFalse(dismissed.contains { $0.id == generic[1].id })
        let noEngine = IdeaEngine.heuristic(photo(SceneDescription(labels: ["beach", "sky"]), generative: false), dismissed: [], language: .french)
        XCTAssertFalse(noEngine.contains { $0.steps.contains { $0.action == "generativeFill" || $0.action == "expandCanvas" } })
        XCTAssertEqual(IdeaEngine.generic(mode: .pdf, language: .french), [])
    }

    func testVideoIdeas() {
        var state = LiveEditorState(mode: .video, version: 1)
        state.video = VideoFacts(duration: 120, playhead: 0, clipDurations: [120], currentClip: 1, musicTracks: 1, hasCaptions: false, isVertical: false)
        let ideas = IdeaEngine.heuristic(state, dismissed: [], language: .french)
        XCTAssertEqual(ideas.map(\.title), ["Résumé de 30 s", "Caler sur le rythme", "Sous-titrer"])
        valid(ideas, mode: .video)
        state.video?.hasCaptions = true
        state.video?.musicTracks = 0
        state.video?.duration = 20
        state.video?.isVertical = true
        let later = IdeaEngine.heuristic(state, dismissed: [], language: .english)
        XCTAssertFalse(later.map(\.title).contains("Add captions"))
        XCTAssertFalse(later.map(\.title).contains("Go vertical"))
        valid(later, mode: .video)
        valid(IdeaEngine.generic(mode: .video, language: .french), mode: .video)
    }

    func testDeterministicIDs() {
        let first = IdeaEngine.heuristic(photo(SceneDescription(people: 1, faces: 1)), dismissed: [], language: .french)
        let english = IdeaEngine.heuristic(photo(SceneDescription(people: 1, faces: 1)), dismissed: [], language: .english)
        XCTAssertEqual(first.map(\.id), english.map(\.id), "the id hashes the steps, not the words")
    }

    func testMerge() {
        let heuristic = IdeaEngine.generic(mode: .photo, language: .french)
        let claude = [LiveIdea(title: "Noir et blanc", why: "", symbol: nil, steps: [RawIntentStep(action: "applyLook", look: "mono")], source: .claude),
                      LiveIdea(title: "Plus chaud", why: "", symbol: nil, steps: [RawIntentStep(action: "adjust", parameter: "temperature", amount: 20)], source: .claude)]
        let merged = IdeaEngine.merge(current: heuristic, incoming: claude, dismissed: [], fill: heuristic)
        XCTAssertEqual(merged.map(\.title), ["Noir et blanc", "Plus chaud", "Améliorer"])
        // A refresh keeps Claude's chips and refills the rest.
        let refreshed = IdeaEngine.merge(current: merged, incoming: [], dismissed: [claude[0].id], fill: heuristic)
        XCTAssertEqual(refreshed.map(\.title), ["Plus chaud", "Améliorer", "Recadrer"])
        let duplicates = IdeaEngine.merge(current: [], incoming: [heuristic[0], heuristic[0]], dismissed: [], fill: heuristic)
        XCTAssertEqual(duplicates.map(\.title), ["Améliorer", "Recadrer", "Look éclatant"])
        let broken = LiveIdea(title: "Cassé", why: "", symbol: nil, steps: [], source: .claude)
        XCTAssertFalse(IdeaEngine.merge(current: [], incoming: [broken], dismissed: [], fill: heuristic).contains(broken))
    }
}

final class BrainSelectorTests: XCTestCase {
    private func inputs(_ now: Double, allowed: Bool = true, online: Bool = true, onDevice: Bool = true) -> BrainSelector.Inputs {
        .init(claudeAllowed: allowed, online: online, onDeviceAvailable: onDevice, now: now)
    }

    func testPriority() {
        var selector = BrainSelector()
        XCTAssertEqual(selector.choose(inputs(0)), .claude)
        XCTAssertEqual(selector.choose(inputs(0, allowed: false)), .onDevice)
        XCTAssertEqual(selector.choose(inputs(0, online: false)), .onDevice)
        XCTAssertEqual(selector.choose(inputs(0, allowed: false, onDevice: false)), .local)
    }

    func testKeyProblemsTurnClaudeOffUntilReset() {
        for (error, problem) in [(LiveBrainError.invalidKey, LiveProblem.keyInvalid), (.noCredit, .noCredit), (.forbidden, .noAccess), (.modelUnavailable, .noAccess)] {
            var selector = BrainSelector()
            selector.recordFailure(error, now: 0)
            XCTAssertEqual(selector.claudeDisabledReason, problem)
            XCTAssertEqual(selector.choose(inputs(10_000)), .onDevice)
            selector.resetClaude()
            XCTAssertEqual(selector.choose(inputs(10_000)), .claude)
        }
    }

    func testCooldowns() {
        var selector = BrainSelector()
        selector.recordFailure(.rateLimited(retryAfter: 30), now: 0)
        XCTAssertEqual(selector.choose(inputs(59)), .onDevice)
        XCTAssertEqual(selector.choose(inputs(61)), .claude)
        var twice = BrainSelector()
        twice.recordFailure(.overloaded, now: 100)
        XCTAssertEqual(twice.choose(inputs(101)), .claude, "one failed turn is not a pattern")
        twice.recordFailure(.timeout(stage: "first_byte"), now: 102)
        XCTAssertEqual(twice.choose(inputs(150)), .onDevice)
        XCTAssertEqual(twice.choose(inputs(163)), .claude)
        var recovered = BrainSelector()
        recovered.recordFailure(.overloaded, now: 0)
        recovered.recordSuccess()
        recovered.recordFailure(.overloaded, now: 1_000)
        XCTAssertEqual(recovered.choose(inputs(1_001)), .claude, "a success in between resets the streak")
    }

    func testThreeFailuresInTenMinutesEndClaudeForTheSession() {
        var selector = BrainSelector()
        selector.recordFailure(.overloaded, now: 0)
        selector.recordSuccess()
        selector.recordFailure(.server(status: 500), now: 200)
        selector.recordSuccess()
        selector.recordFailure(.network("lost"), now: 500)
        XCTAssertTrue(selector.offForSession)
        XCTAssertEqual(selector.choose(inputs(100_000)), .onDevice)
        selector.resetClaude()
        XCTAssertEqual(selector.choose(inputs(100_000)), .onDevice, "a new key does not bring it back this session")
        var spread = BrainSelector()
        for time in [0.0, 400, 800] {
            spread.recordFailure(.overloaded, now: time)
            spread.recordSuccess()
        }
        XCTAssertFalse(spread.offForSession, "not within 10 minutes")
        XCTAssertEqual(BrainSelector.problem(for: .network("x")), .offline)
        XCTAssertEqual(BrainSelector.problem(for: .rateLimited(retryAfter: nil)), .rateLimited)
    }
}

final class LiveLinesAndLatencyTests: XCTestCase {
    func testLines() {
        XCTAssertEqual(LiveLines.line(.greetingLocal, .french), "Je t'écoute. Dis-moi ce que tu veux changer.")
        XCTAssertEqual(LiveLines.line(.greetingLocal, .english), "I'm listening. Tell me what to change.")
        XCTAssertEqual(LiveLines.line(.refusal, .french), "Je ne peux pas faire ça. Une autre idée ?")
        XCTAssertEqual(LiveLines.problem(.keyInvalid, .french), "Ta clé Claude est refusée — je continue sur l'iPhone.")
        XCTAssertEqual(LiveLines.problem(.noSpeechRecognition(language: "de-DE"), .french), "La dictée n'est pas disponible en allemand — écris ta demande.")
        XCTAssertEqual(LiveLines.ideaApplied("Portrait doux", .french), "« Portrait doux » appliqué.")
        XCTAssertEqual(LiveLines.ideaApplied("Soft portrait", .english), "Soft portrait applied.")
        for language in [NormalizedUtterance.Language.french, .english] {
            for key in LiveLineKey.allCases { XCTAssertFalse(LiveLines.line(key, language).isEmpty) }
            for problem in [LiveProblem.noMicrophone, .offline, .refusal, .keyInvalid, .noCredit, .noAccess, .rateLimited, .unavailable("x")] {
                XCTAssertFalse(LiveLines.problem(problem, language).isEmpty)
            }
        }
    }

    func testFillersRotateAndNeverRepeat() {
        var last: String?
        var seen: Set<String> = []
        for _ in 0..<12 {
            let line = LiveLines.filler(.french, avoiding: last)
            XCTAssertNotEqual(line, last)
            seen.insert(line)
            last = line
        }
        XCTAssertEqual(seen.count, 6)
        XCTAssertEqual(LiveLines.filler(.english, avoiding: nil), "Hmm, let me see…")
    }

    func testLatency() {
        var tracker = LatencyTracker()
        XCTAssertNil(tracker.percentiles(.firstAudio))
        for turn in 1...10 {
            tracker.mark(.speechEnd, at: 100, turn: turn)
            tracker.mark(.committed, at: 100.55, turn: turn)
            tracker.mark(.firstAudio, at: 100 + Double(turn) * 0.2, turn: turn)
            tracker.mark(.firstAudio, at: 999, turn: turn)
        }
        XCTAssertEqual(tracker.report(turn: 3), ["committed": 550, "firstAudio": 600])
        let percentiles = tracker.percentiles(.firstAudio)
        XCTAssertEqual(percentiles?.p50, 1000)
        XCTAssertEqual(percentiles?.p90, 1800)
        var usage = ClaudeUsage()
        usage.cacheReadInputTokens = 900
        tracker.record(usage: usage, bodyBytes: 2048, turn: 3)
        XCTAssertEqual(tracker.usage(turn: 3)?.cacheReadInputTokens, 900)
        tracker.mark(.committed, at: 5, turn: 99)
        tracker.mark(.firstText, at: 6.2, turn: 99)
        XCTAssertEqual(tracker.report(turn: 99), ["firstText": 1200], "typed turns count from the commit")
        for turn in 100...200 { tracker.mark(.speechEnd, at: 0, turn: turn) }
        XCTAssertEqual(tracker.report(turn: 1), [:], "only the last 50 turns are kept")
    }
}
