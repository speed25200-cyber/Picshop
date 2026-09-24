import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Drives a LiveTurnMachine with 20 ms audio frames, transcripts and ticks.
struct TurnScript {
    var machine: LiveTurnMachine
    var log: [[LiveEffect]] = []

    init(bargeIn: BargeInMode = .safe, turnTaking: Bool = false) {
        machine = LiveTurnMachine(options: .init(bargeInOnSpeaker: bargeIn, turnTaking: turnTaking))
    }

    var state: LiveTurnState { machine.state }

    @discardableResult
    mutating func send(_ event: LiveEvent) -> [LiveEffect] {
        let effects = machine.handle(event)
        log.append(effects)
        return effects
    }

    /// Frames every 20 ms in [from, to), all effects together.
    @discardableResult
    mutating func audio(from: Double, to: Double, db: Float) -> [LiveEffect] {
        var effects: [LiveEffect] = []
        var time = from
        while time < to - 1e-9 {
            effects += send(.audio(AudioFrameFeatures(rmsDB: db, time: time)))
            time += 0.02
        }
        return effects
    }

    @discardableResult
    mutating func say(_ text: String, at time: Double, final: Bool = false, grammar: EditPlan? = nil) -> [LiveEffect] {
        send(.transcript(final ? TranscriptSnapshot(finalized: text) : TranscriptSnapshot(volatile: text), grammar: grammar, at: time))
    }

    /// Starts Live at 0 and settles the noise floor with 1 s of room tone.
    static func listening(bargeIn: BargeInMode = .safe, turnTaking: Bool = false) -> TurnScript {
        var script = TurnScript(bargeIn: bargeIn, turnTaking: turnTaking)
        script.send(.start(at: 0))
        script.audio(from: 0, to: 1, db: -62)
        return script
    }

    /// A committed turn: speech from 1 to 2 s, "plus lumineux", committed at 2.6 s.
    static func thinking(bargeIn: BargeInMode = .safe, turnTaking: Bool = false) -> TurnScript {
        var script = listening(bargeIn: bargeIn, turnTaking: turnTaking)
        script.audio(from: 1, to: 2, db: -20)
        script.say("plus lumineux", at: 1.9, final: true, grammar: confident)
        script.audio(from: 2, to: 2.6, db: -62)
        script.send(.tick(2.6))
        return script
    }

    static let confident = RuleBasedIntentEngine().parse("plus lumineux", context: .photo)
}

final class LiveTurnMachineTests: XCTestCase {
    func testStartListens() {
        var script = TurnScript()
        XCTAssertEqual(script.send(.start(at: 0)), [.openMic, .beginUserTurn(at: 0), .earcon(.open), .haptic(.liveStart)])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertEqual(script.send(.start(at: 1)), [], "already live")
    }

    func testSpeechStartHearsAndPausesPlayback() {
        var script = TurnScript.listening()
        let effects = script.audio(from: 1, to: 1.2, db: -20)
        XCTAssertEqual(effects, [.showCaption(TranscriptSnapshot(), paused: false), .pausePlayback])
        XCTAssertEqual(script.state.phase, .userSpeaking)
        XCTAssertEqual(script.state.speechStartedAt ?? 0, 1, accuracy: 1e-9, "speech starts at the first voiced frame")
    }

    func testTranscriptAloneHears() {
        var script = TurnScript.listening()
        let snapshot = TranscriptSnapshot(volatile: "plus")
        XCTAssertEqual(script.send(.transcript(snapshot, grammar: nil, at: 1.1)), [.showCaption(snapshot, paused: false), .pausePlayback])
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    func testMutedIgnoresSpeech() {
        var script = TurnScript.listening()
        XCTAssertEqual(script.send(.mute(true)), [.setInputMuted(true)])
        XCTAssertEqual(script.audio(from: 1, to: 1.5, db: -20), [])
        XCTAssertEqual(script.say("plus", at: 1.2), [])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertEqual(script.send(.mute(false)), [.setInputMuted(false)])
    }

    /// Commit thresholds: 0.55 s complete, 0.80 s likely, 1.60 s incomplete, after the last voiced frame.
    func testEndOfTurnThresholds() {
        let cases: [(String, EditPlan?, Double, Double)] = [
            ("plus lumineux", TurnScript.confident, 0.52, 0.57),
            ("et si on essayait autre chose", nil, 0.77, 0.82),
            ("mets le ciel un peu plus", nil, 1.57, 1.62),
            ("tu peux m'aider ?", nil, 0.52, 0.57),
        ]
        for (text, grammar, before, after) in cases {
            var script = TurnScript.listening()
            script.audio(from: 1, to: 2, db: -20)
            script.say(text, at: 1.95, final: true, grammar: grammar)
            script.audio(from: 2, to: 2 + after + 0.02, db: -62)
            let lastVoice = 1.98
            XCTAssertFalse(script.send(.tick(lastVoice + before)).contains { if case .commitTurn = $0 { return true } else { return false } }, text)
            let effects = script.send(.tick(lastVoice + after))
            XCTAssertEqual(effects.first { if case .commitTurn = $0 { return true } else { return false } }, .commitTurn(1, text: text), text)
            XCTAssertTrue(effects.contains(.earcon(.commit)))
            XCTAssertTrue(effects.contains(.beginUserTurn(at: lastVoice + after)))
            XCTAssertEqual(script.state.phase, .thinking)
        }
    }

    func testPausedCaptionAfterAShortSilence() {
        var script = TurnScript.listening()
        script.audio(from: 1, to: 2, db: -20)
        script.say("et puis", at: 1.5)
        script.audio(from: 2, to: 2.4, db: -62)
        let effects = script.send(.tick(2.4))
        XCTAssertTrue(effects.contains(.showCaption(TranscriptSnapshot(volatile: "et puis"), paused: true)))
        XCTAssertTrue(script.state.captionPaused)
    }

    func testNoiseIsDropped() {
        var script = TurnScript.listening()
        script.audio(from: 1, to: 1.3, db: -20)
        script.audio(from: 1.3, to: 4, db: -62)
        XCTAssertEqual(script.send(.tick(3.7)), [.showCaption(TranscriptSnapshot(), paused: true)], "silent, still waiting")
        XCTAssertEqual(script.send(.tick(3.8)), [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: 3.8)])
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testHardCapCommitsAVolatileTail() {
        var script = TurnScript.listening()
        script.audio(from: 1, to: 2, db: -20)
        script.say("ajoute un titre", at: 1.8)
        script.audio(from: 2, to: 4.6, db: -62)
        // The recognizer keeps revising the tail: incomplete, but 2.5 s of silence always commits.
        script.say("ajoute un titre été", at: 3.9)
        XCTAssertTrue(script.send(.tick(4.5)).contains(.commitTurn(1, text: "ajoute un titre été")))
    }

    func testResponseSignalsAndReturnToListening() {
        var script = TurnScript.thinking()
        XCTAssertEqual(script.state.phase, .thinking)
        XCTAssertEqual(script.send(.turn(1, .firstOutput, at: 3)), [])
        XCTAssertTrue(script.state.brainOpen)
        XCTAssertEqual(script.send(.turn(1, .toolStarted, at: 3.1)), [.haptic(.actionStarted)])
        XCTAssertEqual(script.state.phase, .acting)
        script.send(.speaker(1, .chunkQueued, at: 3.1))
        XCTAssertEqual(script.send(.speaker(1, .chunkStarted("J'éclaircis."), at: 3.2)), [])
        XCTAssertEqual(script.state.phase, .speaking)
        XCTAssertEqual(script.state.spokenText, "J'éclaircis.")
        XCTAssertEqual(script.send(.turn(1, .toolFinished(changedDocument: true), at: 3.4)), [.earcon(.applied), .haptic(.actionApplied)])
        XCTAssertEqual(script.state.phase, .speaking)
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3.5))
        XCTAssertEqual(script.state.phase, .speaking, "still talking")
        script.send(.speaker(1, .chunkFinished, at: 4))
        XCTAssertEqual(script.send(.speaker(1, .drained, at: 4)), [.beginUserTurn(at: 4)])
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testSpeechWhileThinkingAlwaysInterruptsAndCarriesOver() {
        var script = TurnScript.thinking()
        let effects = script.audio(from: 2.8, to: 3.1, db: -20)
        XCTAssertEqual(effects.first, .cancelTurn(1, spokenText: ""))
        XCTAssertTrue(effects.contains(.beginUserTurn(at: 2.8 - 0.3)))
        XCTAssertTrue(effects.contains(.haptic(.bargeIn)))
        XCTAssertFalse(effects.contains { if case .stopSpeaking = $0 { return true } else { return false } }, "nothing was playing")
        XCTAssertEqual(script.state.phase, .userSpeaking)
        XCTAssertEqual(script.state.turn, 2)
        XCTAssertEqual(script.state.carryOver, "plus lumineux")
        script.say("et plus chaud", at: 3.0, final: true, grammar: RuleBasedIntentEngine().parse("et plus chaud", context: .photo))
        script.audio(from: 3.1, to: 4.2, db: -62)
        XCTAssertTrue(script.send(.tick(4.2)).contains(.commitTurn(3, text: "plus lumineux et plus chaud")))
    }

    func testWordsWhileThinkingInterrupt() {
        var script = TurnScript.thinking()
        let effects = script.say("attends", at: 2.9)
        XCTAssertTrue(effects.contains(.cancelTurn(1, spokenText: "")))
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    private func speaking(bargeIn: BargeInMode = .safe, turnTaking: Bool = false) -> TurnScript {
        var script = TurnScript.thinking(bargeIn: bargeIn, turnTaking: turnTaking)
        script.send(.turn(1, .firstOutput, at: 3))
        script.send(.speaker(1, .chunkQueued, at: 3))
        script.send(.speaker(1, .chunkStarted("Je réchauffe un peu la photo."), at: 3.1))
        return script
    }

    func testSafeModeOnlyStopsOnAStopWord() {
        var script = speaking()
        XCTAssertEqual(script.state.effectiveBargeIn, .safe)
        XCTAssertEqual(script.audio(from: 3.5, to: 4, db: -20), [], "speech over the voice is not an interruption on the loudspeaker")
        XCTAssertEqual(script.say("non je voulais le ciel", at: 3.9), [])
        XCTAssertEqual(script.state.phase, .speaking)
        let effects = script.say("stop", at: 4.1)
        XCTAssertEqual(effects.first, .stopSpeaking(fadeMs: 80))
        XCTAssertTrue(effects.contains(.cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")))
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    func testFullModeWithHeadphones() {
        var script = speaking()
        script.send(.routeChanged(.low))
        XCTAssertEqual(script.state.effectiveBargeIn, .full)
        script.audio(from: 3.5, to: 3.75, db: -20)
        XCTAssertEqual(script.state.phase, .speaking, "no words yet, not loud for long enough")
        let effects = script.say("non plutôt le ciel", at: 3.8)
        XCTAssertEqual(effects.first, .stopSpeaking(fadeMs: 80))
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    func testFullModeIgnoresItsOwnEcho() {
        var script = speaking(bargeIn: .full)
        script.audio(from: 3.5, to: 3.8, db: -20)
        XCTAssertEqual(script.say("réchauffe un peu la photo", at: 3.8), [])
        XCTAssertEqual(script.state.phase, .speaking)
    }

    func testBackchannelAnswersAQuestion() {
        var script = speaking(bargeIn: .full)
        script.audio(from: 3.5, to: 3.9, db: -20)
        XCTAssertEqual(script.say("oui", at: 3.8), [])
        XCTAssertEqual(script.state.pendingBackchannel, "oui")
        script.send(.turn(1, .ended(endsWithQuestion: true), at: 4))
        let effects = script.send(.speaker(1, .drained, at: 4.5))
        XCTAssertTrue(effects.contains(.commitTurn(2, text: "oui")))
        XCTAssertEqual(script.state.phase, .thinking)
    }

    func testBackchannelIsDroppedWithoutAQuestion() {
        var script = speaking(bargeIn: .full)
        script.audio(from: 3.5, to: 3.9, db: -20)
        script.say("ok", at: 3.8)
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 4))
        let effects = script.send(.speaker(1, .drained, at: 4.5))
        XCTAssertFalse(effects.contains { if case .commitTurn = $0 { return true } else { return false } })
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertNil(script.state.pendingBackchannel)
    }

    func testOrbTaps() {
        var speaking = speaking()
        let effects = speaking.send(.orbTapped(at: 4))
        XCTAssertEqual(effects.prefix(2), [.stopSpeaking(fadeMs: 60), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")])
        XCTAssertEqual(speaking.state.phase, .listening)
        XCTAssertNil(speaking.state.carryOver)

        var hearing = TurnScript.listening()
        hearing.audio(from: 1, to: 1.5, db: -20)
        hearing.say("plus chaud", at: 1.4)
        XCTAssertTrue(hearing.send(.orbTapped(at: 1.5)).contains(.commitTurn(1, text: "plus chaud")), "tap while hearing sends now")

        var listening = TurnScript.listening()
        XCTAssertEqual(listening.send(.orbTapped(at: 2)), [])
    }

    func testTypingCancelsAndCommits() {
        var script = speaking()
        let effects = script.send(.typed("en noir et blanc", at: 4))
        XCTAssertEqual(effects, [.stopSpeaking(fadeMs: 60), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo."), .commitTurn(2, text: "en noir et blanc"), .beginUserTurn(at: 4)])
        XCTAssertEqual(script.state.phase, .thinking)
    }

    func testIdeaTapWhileSpeaking() {
        var script = speaking()
        let effects = script.send(.ideaTapped(at: 4))
        XCTAssertEqual(effects.prefix(2), [.stopSpeaking(fadeMs: 60), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")])
        script.send(.turn(2, .toolStarted, at: 4.1))
        XCTAssertEqual(script.state.phase, .acting)
        script.send(.turn(2, .toolFinished(changedDocument: true), at: 4.3))
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testTurnTakingMutesWhileTheAssistantSpeaks() {
        var script = TurnScript.thinking(turnTaking: true)
        script.send(.turn(1, .firstOutput, at: 3))
        XCTAssertEqual(script.send(.speaker(1, .chunkStarted("Voilà."), at: 3.1)), [.setInputMuted(true)])
        XCTAssertEqual(script.say("stop", at: 3.3), [], "the mic is off while it talks")
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3.4))
        XCTAssertEqual(script.send(.speaker(1, .drained, at: 3.8)), [.setInputMuted(false), .beginUserTurn(at: 3.8)])
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testResignAndBecomeActive() {
        var within = speaking()
        let paused = within.send(.appWillResignActive(at: 5))
        XCTAssertTrue(paused.contains(.stopSpeaking(fadeMs: 0)))
        XCTAssertTrue(paused.contains(.closeMic))
        XCTAssertTrue(paused.contains(.cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")))
        XCTAssertTrue(within.state.paused)
        XCTAssertEqual(within.state.phase, .idle)
        XCTAssertEqual(within.send(.appDidBecomeActive(at: 60)), [.openMic, .beginUserTurn(at: 60)])
        XCTAssertEqual(within.state.phase, .listening)

        var past = TurnScript.listening()
        past.send(.appWillResignActive(at: 5))
        XCTAssertEqual(past.send(.appDidBecomeActive(at: 70)), [.autoPaused])
        XCTAssertEqual(past.state.phase, .idle)
        XCTAssertFalse(past.state.paused)
    }

    func testAudioInterruptions() {
        var script = TurnScript.listening()
        XCTAssertEqual(script.send(.audioInterruption(began: true, shouldResume: false, at: 3)), [.stopSpeaking(fadeMs: 0), .closeMic])
        XCTAssertTrue(script.state.paused)
        XCTAssertEqual(script.send(.audioInterruption(began: false, shouldResume: false, at: 20)), [])
        XCTAssertEqual(script.send(.audioInterruption(began: false, shouldResume: true, at: 21)), [.openMic, .beginUserTurn(at: 21)])
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testAutoPauseAfter90Seconds() {
        var script = TurnScript.listening()
        XCTAssertEqual(script.send(.tick(89)), [])
        XCTAssertEqual(script.send(.tick(90.1)), [.closeMic, .autoPaused])
        XCTAssertEqual(script.state.phase, .idle)
    }

    func testStaleTurnsAreIgnoredButToolsCounted() {
        var script = TurnScript.thinking()
        script.send(.turn(1, .toolStarted, at: 3))
        script.say("attends", at: 3.1)
        XCTAssertEqual(script.state.turn, 2)
        XCTAssertEqual(script.send(.turn(1, .firstOutput, at: 3.2)), [])
        XCTAssertEqual(script.send(.speaker(1, .chunkStarted("Old"), at: 3.2)), [])
        XCTAssertEqual(script.state.toolsRunning, 1)
        script.send(.turn(1, .toolFinished(changedDocument: true), at: 3.3))
        XCTAssertEqual(script.state.toolsRunning, 0, "a stale tool still finished")
    }

    func testStopAndBackground() {
        var script = speaking()
        let effects = script.send(.stop)
        XCTAssertEqual(effects, [.stopSpeaking(fadeMs: 0), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo."), .closeMic, .earcon(.close), .haptic(.liveEnd)])
        XCTAssertEqual(script.state.phase, .idle)
        XCTAssertEqual(script.send(.stop), [])
        var background = TurnScript.listening()
        XCTAssertEqual(background.send(.appDidEnterBackground), [.closeMic, .earcon(.close), .haptic(.liveEnd)])
    }

    func testToolsRunningResetsOnStopAndStart() {
        var script = TurnScript.thinking()
        script.send(.turn(1, .toolStarted, at: 3))
        XCTAssertEqual(script.state.toolsRunning, 1)
        script.send(.stop)
        XCTAssertEqual(script.state.toolsRunning, 0, "a tool that never reported its end does not outlive the conversation")
        script.send(.start(at: 10))
        XCTAssertEqual(script.state.phase, .listening)
        script.send(.turn(1, .toolFinished(changedDocument: true), at: 11))
        XCTAssertEqual(script.state.toolsRunning, 0)
        XCTAssertEqual(script.state.phase, .listening)

        var paused = TurnScript.thinking()
        paused.send(.turn(1, .toolStarted, at: 3))
        paused.send(.orbTapped(at: 3.2))
        paused.send(.tick(95))
        XCTAssertEqual(paused.state.phase, .idle, "auto-paused")
        paused.send(.stop)
        XCTAssertEqual(paused.state.toolsRunning, 0)
    }

    func testCuttingTheVoiceAfterTheStreamEndedCancelsTheTurn() {
        var script = speaking()
        script.send(.turn(1, .ended(endsWithQuestion: true), at: 3.3))
        XCTAssertFalse(script.state.turnInFlight)
        XCTAssertFalse(script.state.brainOpen)
        let effects = script.send(.orbTapped(at: 4))
        XCTAssertEqual(effects.prefix(2), [.stopSpeaking(fadeMs: 60), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")])

        var typed = speaking()
        typed.send(.turn(1, .ended(endsWithQuestion: false), at: 3.3))
        XCTAssertTrue(typed.send(.typed("plus chaud", at: 4)).contains(.cancelTurn(1, spokenText: "Je réchauffe un peu la photo.")))
    }

    func testAFullyHeardReplyIsNotCancelled() {
        var script = speaking()
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3.3))
        script.send(.speaker(1, .chunkFinished, at: 4))
        script.send(.speaker(1, .drained, at: 4))
        XCTAssertEqual(script.state.phase, .listening)
        let effects = script.send(.typed("en noir et blanc", at: 5))
        XCTAssertFalse(effects.contains { if case .cancelTurn = $0 { return true } else { return false } })
        XCTAssertFalse(effects.contains(.stopSpeaking(fadeMs: 60)))
    }

    func testCommitStopsAVoiceThatTalkedOverTheUser() {
        var script = TurnScript.listening()
        script.audio(from: 1, to: 1.6, db: -20)
        XCTAssertEqual(script.state.phase, .userSpeaking)
        // The greeting (turn 0) arrives while the user speaks.
        script.send(.turn(0, .firstOutput, at: 1.5))
        script.send(.speaker(0, .chunkQueued, at: 1.5))
        script.send(.speaker(0, .chunkStarted("Bonjour !"), at: 1.55))
        script.say("plus lumineux", at: 1.55, final: true, grammar: TurnScript.confident)
        script.audio(from: 1.6, to: 2.3, db: -62)
        let effects = script.send(.tick(2.3))
        let stop = effects.firstIndex(of: .stopSpeaking(fadeMs: 60))
        let commit = effects.firstIndex(of: .commitTurn(1, text: "plus lumineux"))
        XCTAssertNotNil(stop)
        XCTAssertNotNil(commit)
        XCTAssertLessThan(stop ?? .max, commit ?? .min, "the stale voice stops before the new turn starts")
        XCTAssertNil(script.state.speakingSince)
        XCTAssertEqual(script.state.chunksQueued, 0)
        XCTAssertEqual(script.state.phase, .thinking, "thinking, not speaking over a stale greeting")
        script.send(.speaker(0, .drained, at: 2.4))
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3))
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testFailedTurnReturnsToListening() {
        var script = TurnScript.thinking()
        XCTAssertEqual(script.send(.turn(1, .failed, at: 4)), [.earcon(.error)])
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testOptionsAndRoute() {
        var script = TurnScript.listening()
        XCTAssertEqual(script.state.effectiveBargeIn, .safe)
        script.machine.setOptions(.init(bargeInOnSpeaker: .full, turnTaking: false))
        XCTAssertEqual(script.state.effectiveBargeIn, .full)
        script.machine.setOptions(.init(bargeInOnSpeaker: .safe, turnTaking: false))
        script.send(.routeChanged(.low))
        XCTAssertEqual(script.state.effectiveBargeIn, .full, "headphones: full barge-in")
        script.send(.routeChanged(.high))
        XCTAssertEqual(script.state.effectiveBargeIn, .safe)
    }
}

final class AudioPolicyTests: XCTestCase {
    func testVADOnsetHangoverAndFloor() {
        var vad = VoiceActivityDetector()
        var time = 0.0
        for _ in 0..<100 {
            XCTAssertNil(vad.process(AudioFrameFeatures(rmsDB: -70, time: time), assistantSpeaking: false))
            time += 0.02
        }
        XCTAssertLessThan(vad.noiseFloorDB, -65, "the floor falls fast")
        var events: [VoiceActivityDetector.Event] = []
        for index in 0..<6 {
            if let event = vad.process(AudioFrameFeatures(rmsDB: -30, time: time), assistantSpeaking: false) { events.append(event) }
            if index < 5 { XCTAssertTrue(events.isEmpty, "onset needs 6 frames") }
            time += 0.02
        }
        guard case .speechStart(let start)? = events.first, events.count == 1 else { return XCTFail("\(events)") }
        XCTAssertEqual(start, 2.0, accuracy: 1e-9)
        for index in 0..<10 {
            let event = vad.process(AudioFrameFeatures(rmsDB: -70, time: time), assistantSpeaking: false)
            if index < 9 {
                XCTAssertNil(event)
            } else if case .speechEnd(let end)? = event {
                XCTAssertEqual(end, 2.1, accuracy: 1e-9)
            } else {
                XCTFail("speech ends after 10 quiet frames")
            }
            time += 0.02
        }
    }

    func testVADMarginAndAbsoluteFloor() {
        var quiet = VoiceActivityDetector()
        for index in 0..<10 { _ = quiet.process(AudioFrameFeatures(rmsDB: -58, time: Double(index) * 0.02), assistantSpeaking: false) }
        XCTAssertFalse(quiet.isSpeech, "below -55 dBFS is never speech")
        var speaking = VoiceActivityDetector()
        for index in 0..<50 { _ = speaking.process(AudioFrameFeatures(rmsDB: -60, time: Double(index) * 0.02), assistantSpeaking: false) }
        let floor = speaking.noiseFloorDB
        for index in 50..<60 { _ = speaking.process(AudioFrameFeatures(rmsDB: floor + 13, time: Double(index) * 0.02), assistantSpeaking: true) }
        XCTAssertFalse(speaking.isSpeech, "15 dB margin while the assistant speaks")
        for index in 60..<70 { _ = speaking.process(AudioFrameFeatures(rmsDB: floor + 13, time: Double(index) * 0.02), assistantSpeaking: false) }
        XCTAssertTrue(speaking.isSpeech, "12 dB otherwise")
        var clamped = VoiceActivityDetector()
        for index in 0..<2000 { _ = clamped.process(AudioFrameFeatures(rmsDB: -120, time: Double(index) * 0.02), assistantSpeaking: false) }
        XCTAssertEqual(clamped.noiseFloorDB, -80)
    }

    func testEndOfTurnCompleteness() {
        let detector = EndOfTurnDetector()
        func check(_ text: String, _ expected: EndOfTurnDetector.Completeness, grammar: EditPlan? = nil, since: Double = 1) {
            XCTAssertEqual(detector.completeness(TranscriptSnapshot(finalized: text), grammar: grammar, sinceTextChange: since), expected, text)
        }
        for trailing in ["mets le ciel plus", "enlève le chien et", "fais-le avec", "make it more", "remove the", "euh", "je voulais,", "un truc -"] {
            check(trailing, .incomplete)
        }
        check("plus lumineux", .complete, grammar: TurnScript.confident)
        check("c'est quoi ce truc ?", .complete)
        check("vas-y !", .complete)
        check("recadre en carré s'il te plaît", .complete)
        check("that's it", .complete)
        check("je sais pas trop", .likely)
        XCTAssertEqual(detector.completeness(TranscriptSnapshot(finalized: "plus", volatile: "lumineux"), grammar: TurnScript.confident, sinceTextChange: 0.1), .incomplete,
                       "the tail is still moving")
        XCTAssertEqual(detector.threshold(.complete), 0.55)
        XCTAssertEqual(detector.threshold(.likely), 0.80)
        XCTAssertEqual(detector.threshold(.incomplete), 1.60)
        XCTAssertTrue(detector.shouldCommit(silence: 2.5, speechDuration: 1, completeness: .incomplete))
        XCTAssertFalse(detector.shouldCommit(silence: 3, speechDuration: 0.1, completeness: .complete), "too little speech")
        XCTAssertTrue(detector.shouldCommit(silence: 0.25, speechDuration: 31, completeness: .incomplete), "30 s turns commit at a short pause")
    }

    func testBargeInPolicy() {
        var policy = BargeInPolicy()
        policy.noteSpoken("Je réchauffe un peu la photo.", at: 10)
        XCTAssertEqual(policy.evaluate(speechDuration: 0.5, dBAboveFloor: 25, words: "réchauffe la photo", now: 11, speakingSince: 10), .ignore, "echo")
        XCTAssertEqual(policy.evaluate(speechDuration: 0.5, dBAboveFloor: 25, words: "non le ciel plutôt", now: 11, speakingSince: 10), .interrupt)
        XCTAssertEqual(policy.evaluate(speechDuration: 0.1, dBAboveFloor: 25, words: "arrête", now: 10.05, speakingSince: 10), .hardStop, "stop words skip grace and duration")
        XCTAssertEqual(policy.evaluate(speechDuration: 0.1, dBAboveFloor: 25, words: "hold on", now: 11, speakingSince: 10), .hardStop)
        XCTAssertEqual(policy.evaluate(speechDuration: 0.5, dBAboveFloor: 25, words: "non le ciel", now: 10.1, speakingSince: 10), .ignore, "grace after the voice starts")
        XCTAssertEqual(policy.evaluate(speechDuration: 0.3, dBAboveFloor: 25, words: "ouais", now: 11, speakingSince: 10), .backchannel("ouais"))
        XCTAssertEqual(policy.evaluate(speechDuration: 0.3, dBAboveFloor: 25, words: "got it", now: 11, speakingSince: 10), .backchannel("got it"))
        XCTAssertEqual(policy.evaluate(speechDuration: 0.5, dBAboveFloor: 25, words: "", now: 11, speakingSince: 10), .interrupt, "loud speech before words")
        XCTAssertEqual(policy.evaluate(speechDuration: 0.5, dBAboveFloor: 10, words: "", now: 11, speakingSince: 10), .ignore)
        XCTAssertEqual(policy.evaluate(speechDuration: 0.3, dBAboveFloor: 25, words: "non le ciel", now: 20, speakingSince: 10), .interrupt, "old speech is not echo")
        // Echo risk moves the minimum speech.
        policy.echoRisk = .high
        XCTAssertEqual(policy.evaluate(speechDuration: 0.3, dBAboveFloor: 25, words: "non le ciel", now: 11, speakingSince: 10), .ignore)
        policy.echoRisk = .low
        XCTAssertEqual(policy.evaluate(speechDuration: 0.2, dBAboveFloor: 25, words: "non le ciel", now: 11, speakingSince: 10), .interrupt)
        // The assistant saying "stop" itself is echo.
        var echo = BargeInPolicy()
        echo.noteSpoken("On peut faire un stop motion.", at: 10)
        XCTAssertNotEqual(echo.evaluate(speechDuration: 0.4, dBAboveFloor: 25, words: "stop motion", now: 11, speakingSince: 10), .hardStop)
        for phrase in ["tais-toi", "chut", "pause", "non non", "wait", "hang on", "cancel", "stop"] {
            XCTAssertTrue(BargeInPolicy.containsStopPhrase(phrase), phrase)
        }
        for phrase in ["oui", "d'accord", "c'est ça", "vas-y", "mhm", "uh-huh", "okay", "sure"] {
            XCTAssertTrue(BargeInPolicy.isBackchannel(phrase), phrase)
        }
        XCTAssertFalse(BargeInPolicy.isBackchannel("oui mais plus chaud"))
    }

    func testTranscriptAccumulator() {
        var accumulator = TranscriptAccumulator()
        accumulator.beginTurn(at: 0)
        XCTAssertEqual(accumulator.apply(TranscriptSegment(text: "plus", start: 0.2, end: 0.5, isFinal: false)), TranscriptSnapshot(volatile: "plus"))
        XCTAssertEqual(accumulator.apply(TranscriptSegment(text: "plus lumi", start: 0.2, end: 0.8, isFinal: false)), TranscriptSnapshot(volatile: "plus lumi"))
        XCTAssertEqual(accumulator.apply(TranscriptSegment(text: "plus lumineux", start: 0.2, end: 1.0, isFinal: true)), TranscriptSnapshot(finalized: "plus lumineux"))
        XCTAssertEqual(accumulator.apply(TranscriptSegment(text: "et chaud", start: 1.2, end: 1.6, isFinal: false)), TranscriptSnapshot(finalized: "plus lumineux", volatile: "et chaud"))
        XCTAssertEqual(accumulator.snapshot.text, "plus lumineux et chaud")
        XCTAssertEqual(accumulator.snapshot.wordCount, 4)
        // Commit: the next turn starts empty; a late final for the old words stays out.
        accumulator.beginTurn(at: 2)
        XCTAssertEqual(accumulator.snapshot, TranscriptSnapshot())
        XCTAssertEqual(accumulator.apply(TranscriptSegment(text: "et chaud", start: 1.2, end: 1.7, isFinal: true)), TranscriptSnapshot())
        // A barge-in begins the turn in the past: words already heard come back.
        accumulator.beginTurn(at: 1.5)
        XCTAssertEqual(accumulator.snapshot, TranscriptSnapshot(finalized: "et chaud"))
    }
}
