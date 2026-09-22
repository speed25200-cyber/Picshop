import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class TextEditingTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    /// "Bonjour euh à tous. Je je pense que c'est bien." at a steady pace.
    private let words: [CaptionWord] = {
        let texts = ["Bonjour", "euh", "à", "tous.", "Je", "je", "pense", "que", "c'est", "bien."]
        return texts.enumerated().map { index, text in CaptionWord(text: text, start: Double(index) * 0.6, end: Double(index) * 0.6 + 0.4) }
    }()

    private func timeline(duration: Double = 8) -> VideoTimeline {
        let asset = MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: duration, frameRate: 30)
        return VideoTimeline(title: "t", clips: [VideoClip(asset: asset, sourceRange: TimeSpan(start: 0, duration: duration))], renderSize: PSSize(width: 1920, height: 1080))
    }

    private func parse(_ text: String) -> EditIntent? {
        engine.parse(text, context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 8)).intents.first
    }

    // MARK: - Core

    func testStrikingAWordTakesThePauseAfterIt() {
        let ranges = TranscriptEditor.ranges(removing: [1], from: words)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0.6 - TranscriptEditor.guardBand, accuracy: 0.001)
        XCTAssertEqual(ranges[0].end, 1.2 - TranscriptEditor.guardBand, accuracy: 0.001)
    }

    func testNeighbouringWordsBecomeOneCut() {
        XCTAssertEqual(TranscriptEditor.ranges(removing: [2, 3, 4], from: words).count, 1)
        XCTAssertEqual(TranscriptEditor.ranges(removing: [1, 3], from: words).count, 2)
    }

    func testLastWordCutStopsAtItsEnd() {
        let range = TranscriptEditor.ranges(removing: [9], from: words)[0]
        XCTAssertEqual(range.end, 5.4 + 0.4 + TranscriptEditor.guardBand, accuracy: 0.001)
    }

    func testFillersFindWrittenHesitationsAndStutters() {
        let fillers = TranscriptEditor.fillers(in: words)
        XCTAssertEqual(fillers.wordIndices, [1, 4])
        XCTAssertTrue(fillers.hesitations.isEmpty)
    }

    func testGrammaticalRepeatsAreKept() {
        let texts = ["Nous", "nous", "sommes", "vus"]
        let spoken = texts.enumerated().map { CaptionWord(text: $1, start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.3) }
        XCTAssertTrue(TranscriptEditor.fillers(in: spoken).isEmpty)
    }

    func testUnwrittenHesitationIsHeardBetweenWords() {
        // Two words with a one-second gap; the middle half-second is voiced (an "euh" the recogniser skipped).
        let spoken = [CaptionWord(text: "alors", start: 0, end: 0.5), CaptionWord(text: "voilà", start: 1.5, end: 2.0)]
        var decibels = [Float](repeating: -70, count: 250)
        for index in 0..<50 { decibels[index] = -20 }          // "alors"
        for index in 70..<130 { decibels[index] = -24 }        // the hesitation
        for index in 150..<200 { decibels[index] = -20 }       // "voilà"
        let fillers = TranscriptEditor.fillers(in: spoken, envelope: LoudnessEnvelope(hop: 0.01, decibels: decibels))
        XCTAssertEqual(fillers.hesitations.count, 1)
        XCTAssertEqual(fillers.hesitations.first?.start ?? 0, 0.67, accuracy: 0.05)
        XCTAssertEqual(fillers.hesitations.first?.end ?? 0, 1.33, accuracy: 0.05)
    }

    func testPhraseSearchIgnoresCasePunctuationAndTokenisation() {
        XCTAssertEqual(TranscriptEditor.occurrences(of: "a tous", in: words), [2...3])
        XCTAssertEqual(TranscriptEditor.occurrences(of: "c est bien", in: words), [8...9])
        XCTAssertEqual(TranscriptEditor.occurrences(of: "je", in: words), [4...4, 5...5])
        XCTAssertTrue(TranscriptEditor.occurrences(of: "bon", in: words).isEmpty)
        XCTAssertEqual(TranscriptEditor.sentence(containing: 6, in: words), 4...9)
    }

    // MARK: - Grammar

    func testGrammar() {
        XCTAssertEqual(parse("enlève les euh")?.action, .removeFillers)
        XCTAssertEqual(parse("remove the ums")?.action, .removeFillers)
        XCTAssertEqual(parse("supprime les hésitations")?.action, .removeFillers)
        XCTAssertEqual(parse("enlève les blancs")?.action, .removeSilences)

        let cut = parse("coupe le passage où je dis bonjour à tous")
        XCTAssertEqual(cut?.action, .cutWords)
        XCTAssertEqual(cut?.text, "bonjour a tous")
        XCTAssertNotEqual(cut?.scope, .all)

        let every = parse("supprime le mot genre à chaque fois")
        XCTAssertEqual(every?.action, .cutWords)
        XCTAssertEqual(every?.text, "genre")
        XCTAssertEqual(every?.scope, .all)

        let sentence = parse("cut the sentence where I say sorry")
        XCTAssertEqual(sentence?.action, .cutWords)
        XCTAssertEqual(sentence?.text, "sorry")
        XCTAssertEqual(sentence?.target?.label, "sentence")
    }

    // MARK: - Executor

    func testRemoveFillersTranscribesAndCuts() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(words: words), language: .french)
        let input = timeline()
        let (output, result) = await executor.execute(EditIntent(action: .removeFillers), on: input, context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 8))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertLessThan(output.duration, input.duration - 1)
        let remaining = output.captions?.cues.flatMap(\.words).map(\.text) ?? []
        XCTAssertEqual(remaining, ["Bonjour", "à", "tous.", "je", "pense", "que", "c'est", "bien."])
        XCTAssertEqual(output.captions?.isVisible, false)
    }

    func testCutWordsNearestThePlayhead() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(words: words), language: .english)
        var intent = EditIntent(action: .cutWords)
        intent.text = "je"
        let (output, result) = await executor.execute(intent, on: timeline(), context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 3.5, timelineDuration: 8))
        XCTAssertTrue(result.outcome.isSuccess)
        let remaining = output.captions?.cues.flatMap(\.words).map(\.text) ?? []
        XCTAssertEqual(remaining, ["Bonjour", "euh", "à", "tous.", "Je", "pense", "que", "c'est", "bien."])
    }

    func testCutWholeSentence() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(words: words), language: .english)
        var intent = EditIntent(action: .cutWords)
        intent.text = "pense"
        intent.target = ObjectTarget(label: "sentence", originalPhrase: "pense")
        let (output, _) = await executor.execute(intent, on: timeline(), context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 8))
        XCTAssertEqual(output.captions?.cues.flatMap(\.words).map(\.text), ["Bonjour", "euh", "à", "tous."])
    }

    func testMissingPhraseFails() async {
        let executor = VideoCommandExecutor(services: FakeMagicVideoServices(words: words), language: .english)
        var intent = EditIntent(action: .cutWords)
        intent.text = "banana"
        let (output, result) = await executor.execute(intent, on: timeline(), context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 8))
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(output.duration, 8, accuracy: 0.001)
    }
}
