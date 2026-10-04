import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The G lane: the rule grammar with catalog abstention. A grammar answer at confidence ≥ 0.85
/// skips the model (the planner's fast path, Live's fast lane at 0.9), so it must be right; when the
/// words are pro vocabulary the grammar does not own, abstention caps it at 0.5 instead.
final class GrammarLaneTests: XCTestCase {
    private let engine = RuleBasedIntentEngine()

    static func context(_ domain: OpDomain) -> IntentContext {
        switch domain {
        case .photo: return IntentContext(mode: .photo)
        case .video: return IntentContext(mode: .video, clipCount: 3, playheadSeconds: 4, timelineDuration: 30)
        case .pdf: return IntentContext(mode: .pdf, pageCount: 6, currentPage: 1)
        }
    }

    /// What the grammar's plan names, as catalog ids (an existing action's id is its raw value).
    private func answered(_ plan: EditPlan) -> Set<String> {
        Set(plan.intents.map { $0.operation?.id.raw ?? $0.action.rawValue }).subtracting(["unknown"])
    }

    /// On the audit's 127 pro-skewed probes, at most 1 confidently wrong answer survives abstention
    /// (the audit measured 20 without it).
    func testProbesAreNeverConfidentlyWrong() {
        var before: [String] = []
        var after: [String] = []
        for probe in ProbeCorpus.all {
            let plan = engine.parse(probe.text, context: Self.context(probe.domain))
            let ops = answered(plan)
            guard !ops.isEmpty else { continue }
            let right = !probe.gold.isEmpty && !ops.isDisjoint(with: probe.gold)
            guard !right else { continue }
            if plan.confidence >= 0.85 { before.append("\(probe.domain) « \(probe.text) » → \(ops.sorted())") }
            let capped = OperationAbstention.capped(plan, utterance: probe.text, domain: probe.domain)
            if capped.confidence >= 0.85 { after.append("\(probe.domain) « \(probe.text) » → \(ops.sorted())") }
            XCTAssertTrue(capped.intents.allSatisfy { $0.confidence <= max(capped.confidence, 0.5) || capped.confidence >= 0.85 })
        }
        XCTAssertGreaterThanOrEqual(before.count, 10, "the probes still exercise the grammar's blind spots")
        XCTAssertLessThanOrEqual(after.count, 1, "\(after)")
        XCTAssertLessThanOrEqual(Double(after.count) / Double(ProbeCorpus.all.count), 0.008)
    }

    /// W2 (§8.4): at most 1 confidently wrong answer across the mask and selection probes, and the phrases a
    /// « sélectionne… » or tone-on-a-region rule could steal keep their owners.
    func testW2ProbesAreNeverConfidentlyWrong() {
        XCTAssertGreaterThanOrEqual(ProbeCorpus.w2.count, 60)
        var wrong: [String] = []
        for probe in ProbeCorpus.w2 {
            let plan = OperationAbstention.capped(engine.parse(probe.text, context: Self.context(probe.domain)), utterance: probe.text, domain: probe.domain)
            let ops = answered(plan)
            guard !ops.isEmpty, plan.confidence >= 0.85, ops.isDisjoint(with: probe.gold) else { continue }
            wrong.append("« \(probe.text) » → \(ops.sorted())")
        }
        XCTAssertLessThanOrEqual(wrong.count, 1, "\(wrong)")
        let owners = ["sélectionne le calque 2": "selectLayer", "remplace le ciel par un coucher de soleil": "generativeFill",
                      "supprime le fond": "removeBackground", "floute le fond": "blurBackground"]
        for (text, owner) in owners {
            let ops = answered(engine.parse(text, context: Self.context(.photo)))
            XCTAssertFalse(ops.contains { ["select", "selectionModify", "selectionApply", "maskAdjust", "maskEdit", "maskDelete"].contains($0) }, "\(text) → \(ops)")
            if !ops.isEmpty { XCTAssertTrue(ops.contains(owner), "\(text) → \(ops)") }
        }
    }

    /// The grammar's own W2 patterns (§8.4) answer at 0.9 with the right operation and arguments.
    func testTheSignaturePatternsAnswer() {
        let cases: [(String, String, [String: OpValue])] = [
            ("assombris le bas", "maskAdjust", ["where": "bottom", "parameter": "exposure"]),
            ("plus de contraste sur le sujet", "maskAdjust", ["where": "subject", "parameter": "contrast", "amount": 20]),
            ("more contrast on the subject", "maskAdjust", ["where": "subject", "parameter": "contrast", "amount": 20]),
            ("darken the bottom", "maskAdjust", ["where": "bottom", "parameter": "exposure"]),
            ("sélectionne la tasse bleue", "select", ["what": "object", "target": "cup", "attributes": .list(["blue"])]),
            ("select the subject", "select", ["what": "subject"]),
            ("sélectionne le sujet", "select", ["what": "subject"]),
            ("inverse la sélection", "selectionModify", ["invert": true]),
            ("désélectionne", "selectionModify", ["deselect": true]),
            ("efface la sélection", "selectionApply", ["use": "erase"]),
            ("remplis la sélection de blanc", "selectionApply", ["use": "fill", "color": "white"]),
        ]
        for (text, id, args) in cases {
            let plan = engine.parse(text, context: Self.context(.photo))
            guard let call = plan.intents.first?.operation else { XCTFail("\(text): \(plan.intents.map(\.action))"); continue }
            XCTAssertEqual(call.id.raw, id, text)
            XCTAssertEqual(call.source, .grammar, text)
            XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, text)
            for (key, value) in args { XCTAssertEqual(call.args[key], value, "\(text) \(key)") }
        }
        // « éclaircis le ciel » stays on the selectiveAdjust path the executor lowers.
        let sky = engine.parse("éclaircis le ciel", context: Self.context(.photo))
        XCTAssertEqual(sky.intents.first?.action, .selectiveAdjust)
    }

    /// Across the positive examples of grammar-owned operations that the grammar answers right,
    /// abstention changes the confidence in at most 1 % of cases.
    func testAbstentionKeepsTheGrammarsRightAnswers() {
        var right = 0
        var changed: [String] = []
        for spec in OperationCatalog.shared.specs where spec.grammar == .owned {
            for example in spec.examples where example.role == .positive {
                for domain in spec.domains {
                    let plan = engine.parse(example.say, context: Self.context(domain))
                    guard answered(plan).contains(spec.id.raw) else { continue }
                    right += 1
                    let capped = OperationAbstention.capped(plan, utterance: example.say, domain: domain)
                    if capped.confidence != plan.confidence { changed.append("\(spec.id) \(domain) « \(example.say) »") }
                }
            }
        }
        XCTAssertGreaterThan(right, 200)
        XCTAssertLessThanOrEqual(Double(changed.count) / Double(right), 0.01, "\(changed)")
    }

    /// The Live eval corpus: the grammar's right, confident answers keep their fast lane.
    func testLiveEvalCasesKeepTheirFastLane() {
        var right = 0
        var changed: [String] = []
        for evalCase in LiveEvalCases.all where !evalCase.expected.isEmpty {
            let plan = engine.parse(evalCase.text, context: evalCase.context)
            guard plan.confidence >= 0.85, !plan.isEmpty, plan.intents.allSatisfy({ evalCase.expected.contains($0.action) }) else { continue }
            right += 1
            let capped = OperationAbstention.capped(plan, utterance: evalCase.text, domain: evalCase.mode.opDomain)
            if capped.confidence != plan.confidence {
                changed.append("« \(evalCase.text) » \(String(describing: OperationAbstention.reason(for: plan, utterance: evalCase.text, domain: evalCase.mode.opDomain)))")
            }
        }
        XCTAssertGreaterThan(right, 100)
        XCTAssertLessThanOrEqual(Double(changed.count) / Double(right), 0.01, "\(changed)")
    }

    /// The abstention lexicon is generated: the unowned operations' triggers minus every phrase a
    /// grammar-owned operation shares.
    func testTheLexiconIsTheUnownedVocabulary() {
        let lexicon = OperationAbstention.lexicon(.photo, catalog: .shared)
        let ids = Set(lexicon.map(\.id.raw))
        XCTAssertEqual(ids, ["curves", "levels", "autoTone", "hsl", "colorGrade", "lutIntensity", "removeLUT", "perspective", "lensFocus",
                             "layerOpacity", "layerBlend", "layerVisibility", "layerOrder"])
        XCTAssertFalse(lexicon.contains { $0.stems == ["calqu"] }, "« calque » belongs to duplicateLayer and deleteLayer too")
        XCTAssertTrue(lexicon.contains { $0.stems == TextFolding.stems("mode produit") })
        XCTAssertTrue(OperationAbstention.lexicon(.pdf, catalog: .shared).isEmpty, "PDF has no unowned operation in W1")
    }
}
