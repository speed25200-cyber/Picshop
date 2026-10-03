import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The R lane: per-turn retrieval of operation cards (OperationIndex). The gold operation must be
/// on the cards the model sees, the core block or the retrieved ones (4B: core + 8, 2B: core + 5),
/// small talk must bring no card, and a query must stay well under a millisecond on the device.
final class RetrievalLaneTests: XCTestCase {
    private let catalog = OperationCatalog.shared
    private let index = OperationIndex.shared

    private func query(_ text: String, _ domain: OpDomain, _ language: OpLanguage? = nil, hints: Set<OpStateHint> = [], sticky: [OpID] = []) -> OperationQuery {
        let spoken: NormalizedUtterance.Language = language.map { $0 == .fr ? .french : .english } ?? NormalizedUtterance(text).language
        return OperationQuery(text: text, domain: domain, language: spoken, hints: hints, sticky: sticky)
    }

    /// Whether one of the gold operations is on the cards: the core block or the `limit` retrieved.
    private func shown(_ gold: Set<String>, _ text: String, _ domain: OpDomain, limit: Int, language: OpLanguage? = nil) -> Bool {
        Self.shown(gold, text, domain, limit: limit, language: language)
    }

    static func shown(_ gold: Set<String>, _ text: String, _ domain: OpDomain, limit: Int, language: OpLanguage?) -> Bool {
        let catalog = OperationCatalog.shared
        let spoken: NormalizedUtterance.Language = language.map { $0 == .fr ? .french : .english } ?? NormalizedUtterance(text).language
        let core = Set(catalog.core(for: domain).map(\.id.raw))
        let retrieved = Set(OperationIndex.shared.retrieve(OperationQuery(text: text, domain: domain, language: spoken), limit: limit).map(\.id.raw))
        return !gold.isDisjoint(with: core.union(retrieved))
    }

    /// One labelled utterance of the R lane: the gold operations are catalog ids.
    struct RetrievalCase: Sendable {
        var text: String
        var domain: OpDomain
        var language: OpLanguage
        var gold: Set<String>
    }

    struct Recall {
        var total = 0, top8 = 0, top5 = 0
        var misses: [String] = []
        var at8: Double { total == 0 ? 1 : Double(top8) / Double(total) }
        var at5: Double { total == 0 ? 1 : Double(top5) / Double(total) }
    }

    /// Recall per domain on the cards of the 4B (core + 8) and the 2B (core + 5). Cases whose gold
    /// operation is not in the catalog for their domain are left out (they are refusals).
    static func recall(_ cases: [RetrievalCase]) -> [OpDomain: Recall] {
        var recall: [OpDomain: Recall] = [:]
        for item in cases {
            let gold = item.gold.filter { OperationCatalog.shared.spec(OpID($0))?.domains.contains(item.domain) ?? false }
            guard !gold.isEmpty else { continue }
            var lane = recall[item.domain] ?? Recall()
            lane.total += 1
            if shown(gold, item.text, item.domain, limit: 8, language: item.language) { lane.top8 += 1 } else { lane.misses.append("@8 « \(item.text) »") }
            if shown(gold, item.text, item.domain, limit: 5, language: item.language) { lane.top5 += 1 } else { lane.misses.append("@5 « \(item.text) »") }
            recall[item.domain] = lane
        }
        return recall
    }

    /// The plan's R-lane targets: core + 8 ≥ 98 % (photo, video) and ≥ 99 % (PDF); core + 5 ≥ 95 %, 95 %, 97 %.
    /// E2's held-out utterances (Fixtures/HeldOutUtterances.swift) are checked with this too.
    static func assertRecallTargets(_ cases: [RetrievalCase], minimumPerDomain: Int = 15, file: StaticString = #filePath, line: UInt = #line) {
        let recall = recall(cases)
        let targets: [OpDomain: (Double, Double)] = [.photo: (0.98, 0.95), .video: (0.98, 0.95), .pdf: (0.99, 0.97)]
        for domain in OpDomain.allCases {
            let lane = recall[domain] ?? Recall()
            XCTAssertGreaterThanOrEqual(lane.total, minimumPerDomain, "\(domain)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(lane.at8, targets[domain]!.0, "\(domain) core + 8: \(lane.misses)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(lane.at5, targets[domain]!.1, "\(domain) core + 5: \(lane.misses)", file: file, line: line)
        }
    }

    /// The R lane on the audit's probe corpus: the probes whose gold operation exists in the catalog.
    func testProbeCorpusRecall() {
        Self.assertRecallTargets(ProbeCorpus.all.map { RetrievalCase(text: $0.text, domain: $0.domain, language: $0.language, gold: $0.gold) })
    }

    /// Phrasings written apart from the catalog's triggers and examples (colloquial French, anglicisms,
    /// short orders). The catalog author wrote them, so they are a smoke test, not the held-out gate.
    static let unseenPhrasings: [RetrievalCase] = [
        u("mets un LUT", .photo, ["lutIntensity"]), u("split toning", .photo, ["colorGrade"]), u("fais une courbe en s", .photo, ["curves"]),
        u("baisse l'opa du calque", .photo, ["layerOpacity"]), u("le calque en mode screen", .photo, ["layerBlend"]),
        u("rends les rouges moins saturés", .photo, ["hsl"]), u("teinte les ombres en bleu", .photo, ["colorGrade"]),
        u("point blanc à 240", .photo, ["levels"]), u("niveaux auto stp", .photo, ["levels", "autoTone"]),
        u("redresse les murs du bâtiment", .photo, ["perspective"]), u("focus sur le visage", .photo, ["lensFocus"]),
        u("flou d'objectif sur le fond", .photo, ["lensFocus", "blurBackground"]), u("monte ce calque d'un cran", .photo, ["layerOrder"]),
        u("masque le calque du logo", .photo, ["layerVisibility"]), u("mets un look ciné", .photo, ["applyLook"]),
        u("enlève les gens derrière", .photo, ["cleanUp", "removeObject"]), u("make the reds less saturated", .photo, ["hsl"]),
        u("add some blue to the shadows", .photo, ["colorGrade"]), u("lower the LUT strength", .photo, ["lutIntensity"]),
        u("set the black point to 10", .photo, ["levels"]), u("blend the layer with overlay", .photo, ["layerBlend"]),
        u("hide this layer", .photo, ["layerVisibility"]), u("put the text behind the photo layer", .photo, ["layerOrder"]),
        u("corrige les lignes qui penchent", .photo, ["perspective"]), u("contraste en s doux", .photo, ["curves"]),
        u("rends l'herbe moins verte", .photo, ["hsl", "selectiveAdjust"]), u("agrandis la résolution", .photo, ["upscale"]),
        u("retire le LUT que j'ai mis", .photo, ["removeLUT"]), u("efface le logo en bas", .photo, ["removeObject", "eraseRegion"]),
        u("mets 0 dans les cases vides", .photo, ["fillCells"]),
        u("coupe la fin", .video, ["deleteRange", "trim"]), u("accélère un peu", .video, ["setSpeed"]), u("musique plus forte", .video, ["setVolume"]),
        u("ajoute une transition entre les plans", .video, ["addTransition"]), u("sous-titre la vidéo", .video, ["autoCaptions"]),
        u("enlève la musique de fond", .video, ["removeMusic"]), u("fais un ralenti au milieu", .video, ["speedRamp", "setSpeed"]),
        u("vire les hésitations", .video, ["removeFillers"]), u("mets la vidéo au format reel", .video, ["smartReframe", "crop", "setAspect"]),
        u("baisse la musique pendant que je parle", .video, ["autoDuck"]), u("fige l'image à la fin", .video, ["freezeFrame"]),
        u("traduis en espagnol", .video, ["translateCaptions"]), u("cut the silences", .video, ["removeSilences"]),
        u("add a crossfade", .video, ["addTransition"]), u("slow it down by half", .video, ["setSpeed"]),
        u("make the voice clearer", .video, ["enhanceVoice"]),
        u("va à la page 5", .pdf, ["goToPage"]), u("efface la page 2", .pdf, ["deletePage"]), u("tourne la page 3", .pdf, ["rotatePage"]),
        u("mets ma signature à la fin", .pdf, ["addSignature"]), u("souligne la date", .pdf, ["underlineText"]),
        u("noircis le numéro de sécu", .pdf, ["redactText"]), u("remplace 2024 par 2025", .pdf, ["replaceText"]),
        u("ajoute une page vide à la fin", .pdf, ["insertBlankPage"]), u("sors la page 4 dans un fichier", .pdf, ["extractPage"]),
        u("highlight the total", .pdf, ["highlightText"]), u("number the pages", .pdf, ["addPageNumbers"]), u("copy page 2", .pdf, ["duplicatePage"]),
    ]

    private static func u(_ text: String, _ domain: OpDomain, _ gold: Set<String>) -> RetrievalCase {
        RetrievalCase(text: text, domain: domain, language: NormalizedUtterance(text).language == .french ? .fr : .en, gold: gold)
    }

    func testUnseenPhrasingsRecall() {
        Self.assertRecallTargets(Self.unseenPhrasings, minimumPerDomain: 10)
    }

    /// The R lane's gate (plan §9 and §14): E2's held-out set, written apart from the catalog,
    /// reaches the targets on the 4B's and the 2B's cards.
    func testHeldOutRecallMeetsTheTargets() {
        Self.assertRecallTargets(HeldOutUtterances.retrievalCases)
    }

    /// The speech recogniser's elisions without an apostrophe fold like the written ones, and
    /// only the listed words are cut ("lent", "date" stay whole).
    func testElisionsWithoutAnApostropheAreSplit() {
        XCTAssertEqual(TextFolding.tokens("lhorizon est de travers"), TextFolding.tokens("l'horizon est de travers"))
        XCTAssertEqual(TextFolding.tokens("dabord"), ["d", "abord"])
        XCTAssertEqual(TextFolding.tokens("un zoom lent"), ["un", "zoom", "lent"])
        XCTAssertEqual(TextFolding.tokens("la date"), ["la", "date"])
        XCTAssertEqual(TextFolding.stems("vire la musique"), TextFolding.stems("enlève la musique"), "« virer » is folded onto « enlever »")
    }

    /// Every example (in-sample) brings its operation on the 2B's cards.
    func testExamplesFindTheirOperation() {
        var total = 0, found = 0
        var misses: [String] = []
        for spec in catalog.specs {
            for example in spec.examples {
                if case .negative = example.role { continue }
                for domain in spec.domains {
                    total += 1
                    if shown([spec.id.raw], example.say, domain, limit: 5, language: example.language) { found += 1 } else { misses.append("\(spec.id) « \(example.say) »") }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(found) / Double(total), 0.97, "\(misses)")
    }

    /// The 13 new operations' own words (their triggers) bring them, which is what the model needs
    /// before abstention hands it the request.
    func testNewOperationsAreFoundByTheirTriggers() {
        for spec in catalog.specs where spec.lowering == .handler {
            for language in OpLanguage.allCases {
                for trigger in spec.triggers[language] ?? [] {
                    let ids = index.retrieve(query(trigger, .photo, language, hints: [.importedLUT, .multipleLayers]), limit: 8).map(\.id)
                    XCTAssertTrue(ids.contains(spec.id), "\(spec.id): « \(trigger) » → \(ids)")
                }
            }
        }
    }

    static let smallTalk = [
        "tu penses quoi de la lumière ?", "qu'est-ce que tu ferais ?", "merci beaucoup", "bonjour", "c'est super", "j'adore", "ça me plaît bien",
        "pas mal", "c'est parfait", "génial merci", "on fait une pause", "attends", "je réfléchis", "hmm", "ok", "d'accord", "tu es là ?",
        "comment ça va ?", "raconte-moi une blague", "quelle heure est-il ?", "il fait beau aujourd'hui", "c'est bon comme ça", "laisse comme ça",
        "on verra plus tard", "à ton avis c'est réussi ?", "tu trouves que c'est joli ?", "pourquoi tu dis ça ?", "c'est quoi ton nom ?",
        "what would you do?", "thanks", "hello there", "do you think it's too dark?", "I love it", "looks great", "nice", "wait a second",
        "let me think", "who are you?", "what can you do?", "how are you?", "good job", "perfect", "that's fine", "no thanks",
    ]

    /// τ: small talk retrieves no non-core operation in at least 90 % of cases.
    func testSmallTalkBringsNoCards() {
        XCTAssertGreaterThanOrEqual(Self.smallTalk.count, 40)
        var empty = 0, total = 0
        var noisy: [String] = []
        for text in Self.smallTalk {
            for domain in OpDomain.allCases {
                total += 1
                let retrieved = index.retrieve(query(text, domain), limit: 8)
                if retrieved.isEmpty { empty += 1 } else { noisy.append("\(domain) « \(text) » \(retrieved.map(\.id.raw))") }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(empty) / Double(total), 0.9, "\(noisy)")
    }

    func testRetrievalIsDeterministic() {
        let fresh = OperationIndex(catalog: .shared)
        for probe in ProbeCorpus.all {
            let q = query(probe.text, probe.domain, probe.language)
            XCTAssertEqual(index.retrieve(q, limit: 8), index.retrieve(q, limit: 8))
            XCTAssertEqual(index.ranking(q), fresh.ranking(q), "« \(probe.text) »")
        }
    }

    func testRetrieveKeepsToTheDomainAndLeavesTheCoreOut() {
        let pdf = index.retrieve(query("applique une courbe en S et supprime la page 3", .pdf), limit: 8)
        XCTAssertTrue(pdf.allSatisfy { catalog.spec($0.id)?.domains.contains(.pdf) ?? false }, "\(pdf)")
        let photo = index.retrieve(query("plus lumineux et une courbe en S", .photo), limit: 8).map(\.id)
        XCTAssertFalse(photo.contains("adjust"), "adjust is in the core block")
        XCTAssertTrue(photo.prefix(2).contains("curves"), "\(photo)")
        XCTAssertEqual(index.retrieve(query("une courbe en S", .photo), limit: 8).first?.id, "curves")
        XCTAssertEqual(index.retrieve(query("courbe en S", .photo), limit: 0), [])
        XCTAssertEqual(index.retrieve(query("", .photo), limit: 8), [])
    }

    func testStickyOperationsComeFirst() {
        let retrieved = index.retrieve(query("encore un peu", .photo, sticky: ["curves", "adjust", "levels"]), limit: 5).map(\.id)
        XCTAssertEqual(retrieved, ["curves"], "the last two, minus the core, even below τ")
        let video = index.retrieve(query("pareil sur le clip 2", .video, sticky: ["curves", "kenBurns"]), limit: 5).map(\.id)
        XCTAssertFalse(video.contains("curves"), "a sticky operation of another editor is dropped")
        XCTAssertEqual(video.first, "kenBurns")
    }

    /// Each clause gets its cards ("…et…", "puis", "mais").
    func testEveryClauseGetsItsQuota() {
        let ids = index.retrieve(query("mets une courbe en S, puis baisse l'opacité du calque et passe-le en mode produit", .photo,
                                       hints: [.multipleLayers]), limit: 3).map(\.id)
        XCTAssertEqual(Set(ids), ["curves", "layerOpacity", "layerBlend"], "\(ids)")
    }

    /// Unmet requirements halve the score and mark the card; the hints lift the matching ones.
    func testRequirementsAndHints() throws {
        let without = try XCTUnwrap(index.retrieve(query("mets le LUT à 50 %", .photo), limit: 5).first { $0.id == "lutIntensity" })
        XCTAssertEqual(without.unavailable, "no LUT imported")
        let with = try XCTUnwrap(index.retrieve(query("mets le LUT à 50 %", .photo, hints: [.importedLUT]), limit: 5).first { $0.id == "lutIntensity" })
        XCTAssertNil(with.unavailable)
        XCTAssertGreaterThan(with.score, without.score * 2)
        let layer = try XCTUnwrap(index.retrieve(query("baisse l'opacité du calque", .photo), limit: 5).first { $0.id == "layerOpacity" })
        XCTAssertEqual(layer.unavailable, "only the photo layer")
    }

    func testTopIncludesTheCoreWithItsMargin() throws {
        let top = try XCTUnwrap(index.top(query("augmente le contraste de 20", .photo)))
        XCTAssertEqual(top.id, "adjust")
        XCTAssertGreaterThan(top.margin, 0)
        XCTAssertLessThanOrEqual(top.margin, 1)
        XCTAssertNil(index.top(query("merci beaucoup", .photo)))
        XCTAssertEqual(index.top(query("supprime la page 3", .pdf))?.id, "deletePage")
    }

    func testSlotsAndFolding() {
        XCTAssertEqual(TextFolding.tokens("Mets l'opacité à 50 % et l’exposition à -0,3, puis 16:9"),
                       ["mets", "l", "opacite", "a", "50", "%", "et", "l", "exposition", "a", "-0.3", "puis", "16:9"])
        XCTAssertEqual(TextFolding.stem("saturation"), TextFolding.stem("saturer"))
        XCTAssertEqual(TextFolding.stem("courbes"), "courb")
        XCTAssertEqual(TextFolding.stem("niveaux"), "niveau")
        XCTAssertEqual(TextFolding.stem("focus"), "focus")
        XCTAssertEqual(TextFolding.camelWords("removeLUT"), "remove lut")
        XCTAssertEqual(TextFolding.camelWords("layerOpacity"), "layer opacity")
        let slots = SlotExtractor.extract("désature les bleus de 40 % sur 3 secondes, ombres bleues, page 2, 16:9")
        XCTAssertEqual(slots.bands, ["blue"])
        XCTAssertEqual(slots.tintedRanges, ["shadows"])
        XCTAssertEqual(slots.page, 2)
        XCTAssertTrue(slots.ratio)
        XCTAssertEqual(slots.units, [.percent, .seconds])
        XCTAssertTrue(SlotExtractor.extract("rends le ciel plus bleu").bands.isEmpty, "a colour alone is not a band")
    }

    /// Build ≤ 50 ms and a query p95 ≤ 15 ms on the Linux runner (about 5 ms on device).
    func testPerformance() {
        var builds: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = OperationIndex(catalog: .shared)
            builds.append(Date().timeIntervalSince(start) * 1_000)
        }
        XCTAssertLessThanOrEqual(builds.min() ?? 0, 50, "index build, ms")
        var times: [Double] = []
        for probe in ProbeCorpus.all + ProbeCorpus.all {
            let start = Date()
            _ = index.retrieve(query(probe.text, probe.domain, probe.language), limit: 8)
            times.append(Date().timeIntervalSince(start) * 1_000)
        }
        times.sort()
        XCTAssertLessThanOrEqual(times[Int(Double(times.count) * 0.95)], 15, "retrieve p95, ms")
    }

    /// The optional embedder is fused by reciprocal rank fusion: an operation only it finds is added
    /// above its own threshold; nothing changes without vectors.
    func testEmbedderFusion() {
        struct Fake: OperationEmbedder {
            func vector(for text: String, language: NormalizedUtterance.Language) -> [Float]? {
                let folded = TextFolding.tokens(text)
                if folded.contains("cinema") || folded.contains("curves") || folded.contains("courbes") { return [1, 0] }
                return [0, 1]
            }
        }
        struct Silent: OperationEmbedder {
            func vector(for text: String, language: NormalizedUtterance.Language) -> [Float]? { nil }
        }
        let fused = OperationIndex(catalog: .shared, embedder: Fake())
        XCTAssertTrue(fused.retrieve(query("donne un effet cinéma", .photo), limit: 8).contains { $0.id == "curves" })
        let silent = OperationIndex(catalog: .shared, embedder: Silent())
        let q = query("applique une courbe en S", .photo)
        XCTAssertEqual(silent.retrieve(q, limit: 8), index.retrieve(q, limit: 8))
    }
}
