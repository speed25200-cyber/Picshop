import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The reducer invariants that keep Live from going silent or deaf (contract §10 P0):
/// only words cancel, every state has a deadline, the echo tail is not the user,
/// and the recognizer path reopens its ear.
final class ReducerInvariantTests: XCTestCase {
    private func speaking(bargeIn: BargeInMode = .safe, turnTaking: Bool = false, words: String = "Je réchauffe un peu la photo.") -> TurnScript {
        var script = TurnScript.thinking(bargeIn: bargeIn, turnTaking: turnTaking)
        script.send(.turn(1, .firstOutput, at: 3))
        script.send(.speaker(1, .chunkQueued, at: 3))
        script.send(.speaker(1, .chunkStarted(words), at: 3.1))
        return script
    }

    private func simplePath() -> TurnScript {
        var script = TurnScript.listening()
        script.machine.setOptions(.init(bargeInOnSpeaker: .safe, turnTaking: true, externalEndpointing: true))
        return script
    }

    private func commits(_ effects: [LiveEffect]) -> Bool {
        effects.contains { if case .commitTurn = $0 { return true } else { return false } }
    }

    // MARK: Voice activity

    func testLatchedDetectorRelearnsTheRoomAfterEightSeconds() {
        var vad = VoiceActivityDetector()
        var time = 0.0
        for _ in 0..<50 {
            _ = vad.process(AudioFrameFeatures(rmsDB: -62, time: time), assistantSpeaking: false)
            time += 0.02
        }
        var events: [VoiceActivityDetector.Event] = []
        var latchedAtFive = false
        // A TV at -40 dBFS: "speech" at once, then never a pause.
        while time < 12 {
            if let event = vad.process(AudioFrameFeatures(rmsDB: -40, time: time), assistantSpeaking: false) { events.append(event) }
            if abs(time - 5) < 0.01 { latchedAtFive = vad.isSpeech }
            time += 0.02
        }
        XCTAssertTrue(latchedAtFive, "latched before the relearn")
        guard events.count == 2, case .speechStart(let start) = events[0], case .speechEnd = events[1] else { return XCTFail("\(events)") }
        XCTAssertEqual(start, 1, accuracy: 1e-6)
        XCTAssertFalse(vad.isSpeech, "released after maxSpeechRun")
        XCTAssertEqual(vad.noiseFloorDB, -43, accuracy: 1.5, "the room's level became the floor")
        // Someone really talks over the TV: speech again.
        for _ in 0..<10 {
            _ = vad.process(AudioFrameFeatures(rmsDB: -20, time: time), assistantSpeaking: false)
            time += 0.02
        }
        XCTAssertTrue(vad.isSpeech)
        XCTAssertEqual(VoiceActivityDetector.Parameters().maxSpeechRun, 8)
    }

    func testEmptyHearingEndsAfterFourSecondsWhateverTheDetectorSays() {
        var script = TurnScript.listening()
        script.audio(from: 1, to: 5.2, db: -35)
        XCTAssertEqual(script.state.phase, .userSpeaking)
        XCTAssertEqual(script.send(.tick(4.9)), [], "still within the cap, the detector says speech")
        XCTAssertEqual(script.send(.tick(5.0)), [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: 5)])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertTrue(script.state.lastDecision?.hasPrefix("dropped") ?? false)
        // The TV goes on: the latched detector no longer pins "hearing", and relearns the room.
        XCTAssertEqual(script.audio(from: 5.2, to: 12, db: -35), [])
        XCTAssertEqual(script.state.phase, .listening)
    }

    // MARK: Only words cancel

    func testEnergyNeverCancelsTheGreetingOrAnAction() {
        var greeting = TurnScript.listening()
        greeting.send(.turn(0, .firstOutput, at: 1))
        greeting.send(.speaker(0, .chunkQueued, at: 1))
        XCTAssertEqual(greeting.state.phase, .thinking, "the greeting waits for its first buffer")
        XCTAssertEqual(greeting.audio(from: 1, to: 2, db: -20), [], "noise does not kill the greeting")
        XCTAssertEqual(greeting.state.phase, .thinking)

        var acting = TurnScript.thinking()
        acting.send(.turn(1, .toolStarted, at: 3))
        XCTAssertEqual(acting.state.phase, .acting)
        XCTAssertEqual(acting.audio(from: 3, to: 4, db: -20), [])
        XCTAssertEqual(acting.say("chaud", at: 3.9), [], "one word is not enough")
        XCTAssertTrue(acting.say("non plutôt le ciel", at: 4).contains(.cancelTurn(1, spokenText: "")))
        XCTAssertEqual(acting.state.phase, .userSpeaking)
    }

    func testFullBargeInNeedsTwoNewWords() {
        var script = speaking(bargeIn: .full)
        script.audio(from: 3.5, to: 3.9, db: -20)
        XCTAssertEqual(script.say("non", at: 3.8), [], "one word over the voice")
        XCTAssertEqual(script.state.phase, .speaking)
        XCTAssertEqual(script.audio(from: 3.9, to: 4.4, db: -20), [], "loud speech with one word still waits for words")
        let effects = script.say("non le ciel", at: 4.4)
        XCTAssertEqual(effects.first, .stopSpeaking(fadeMs: 80))
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    // MARK: Deadlines

    func testThinkingDeadline() {
        var script = TurnScript.thinking()
        XCTAssertEqual(script.state.committedAt ?? 0, 2.6, accuracy: 1e-9)
        XCTAssertEqual(script.send(.tick(17.5)), [])
        XCTAssertEqual(script.send(.tick(17.7)), [.cancelTurn(1, spokenText: ""), .turnTimedOut(1)])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertFalse(script.state.turnInFlight)
        // The session says so on the same turn: its signals still count.
        script.send(.speaker(1, .chunkQueued, at: 17.8))
        script.send(.speaker(1, .chunkStarted("Je n'ai pas trouvé."), at: 17.9))
        XCTAssertEqual(script.state.phase, .speaking)
        script.send(.speaker(1, .drained, at: 19))
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testThinkingDeadlineCountsFromTheLastSignOfLife() {
        var script = TurnScript.thinking()
        script.send(.turn(1, .firstOutput, at: 10))
        XCTAssertEqual(script.send(.tick(24.9)), [])
        XCTAssertTrue(script.send(.tick(25.1)).contains(.turnTimedOut(1)))

        var acting = TurnScript.thinking()
        acting.send(.turn(1, .toolStarted, at: 3))
        XCTAssertEqual(acting.send(.tick(60)), [], "a running tool is acting, not thinking: no deadline")
        acting.send(.turn(1, .toolFinished(changedDocument: true), at: 61))
        XCTAssertEqual(acting.state.phase, .thinking)
        XCTAssertEqual(acting.send(.tick(75.9)), [])
        XCTAssertTrue(acting.send(.tick(76.1)).contains(.turnTimedOut(1)))

        var answered = TurnScript.thinking()
        answered.send(.turn(1, .ended(endsWithQuestion: false), at: 3))
        XCTAssertEqual(answered.state.phase, .listening)
        XCTAssertEqual(answered.send(.tick(30)), [], "nothing in flight, nothing to time out")
    }

    func testQueuedLineWatchdog() {
        var script = TurnScript.thinking()
        script.send(.turn(1, .firstOutput, at: 3))
        script.send(.speaker(1, .chunkQueued, at: 3))
        XCTAssertEqual(script.state.queuedAt, 3)
        XCTAssertEqual(script.send(.tick(6.9)), [])
        XCTAssertEqual(script.send(.tick(7.1)), [.stopSpeaking(fadeMs: 0), .speakerStuck])
        XCTAssertEqual(script.state.chunksQueued, 0)
        XCTAssertNil(script.state.queuedAt)
        XCTAssertEqual(script.state.phase, .thinking, "the brain is still answering")
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 7.2))
        XCTAssertEqual(script.state.phase, .listening)
    }

    func testALineWaitingBehindAPlayingChunkIsNotStuck() {
        var script = speaking(words: "Je réchauffe un peu.")
        script.send(.speaker(1, .chunkQueued, at: 3.2))
        XCTAssertNil(script.state.queuedAt, "it waits behind the chunk that plays")
        XCTAssertEqual(script.send(.tick(7.5)), [])
        script.send(.speaker(1, .chunkFinished, at: 5))
        XCTAssertEqual(script.state.queuedAt, 5, "now it waits on nothing")
        XCTAssertEqual(script.send(.tick(8.9)), [])
        XCTAssertEqual(script.send(.tick(9.1)).prefix(2), [.stopSpeaking(fadeMs: 0), .speakerStuck])
    }

    func testDrainWatchdog() {
        let words = "Je réchauffe un peu la photo pour toi, voilà."
        XCTAssertEqual(words.split(separator: " ").count, 9)
        var script = speaking(turnTaking: true, words: words)
        XCTAssertEqual(script.state.lastChunkWords, 9)
        XCTAssertEqual(script.state.lastChunkStartedAt, 3.1)
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3.5))
        XCTAssertEqual(script.send(.tick(11.0)), [])
        let effects = script.send(.tick(11.2))
        XCTAssertEqual(effects, [.stopSpeaking(fadeMs: 0), .speakerStuck, .setInputMuted(false), .beginUserTurn(at: 11.2)])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertNil(script.state.lastChunkStartedAt)
        XCTAssertEqual(LiveTurnMachine.drainDeadline(words: 9), 8, accuracy: 1e-9)
    }

    func testAChunkThatFinishesIsNotWatched() {
        var script = speaking()
        script.send(.speaker(1, .chunkFinished, at: 4))
        XCTAssertNil(script.state.lastChunkStartedAt)
        XCTAssertEqual(script.send(.tick(18.9)), [])
        XCTAssertEqual(script.send(.tick(19.1)), [.stopSpeaking(fadeMs: 0), .cancelTurn(1, spokenText: "Je réchauffe un peu la photo."), .turnTimedOut(1)],
                       "nothing plays and the brain never ended: the thinking deadline, from the last chunk")
        XCTAssertEqual(script.state.phase, .listening)
    }

    // MARK: Echo gate

    func testEchoGateAfterTheVoiceOnTheLoudspeaker() {
        var script = speaking()
        script.send(.turn(1, .ended(endsWithQuestion: false), at: 3.5))
        XCTAssertEqual(script.send(.speaker(1, .drained, at: 4)), [.beginUserTurn(at: 4.6)])
        XCTAssertEqual(script.state.echoGateUntil, 4.6)
        XCTAssertEqual(script.audio(from: 4, to: 4.5, db: -20), [], "the voice's tail")
        XCTAssertEqual(script.say("la photo", at: 4.3), [])
        XCTAssertEqual(script.send(.utterance("réchauffe un peu la photo", at: 4.4)), [])
        XCTAssertEqual(script.state.phase, .listening)
        XCTAssertFalse(script.say("plus chaud", at: 4.7).isEmpty, "after the tail, the user")
        XCTAssertEqual(script.state.phase, .userSpeaking)
    }

    func testNoEchoGateOnHeadphonesOrWhileTheUserTalks() {
        var headphones = speaking()
        headphones.send(.routeChanged(.low))
        headphones.send(.turn(1, .ended(endsWithQuestion: false), at: 3.5))
        XCTAssertEqual(headphones.send(.speaker(1, .drained, at: 4)), [.beginUserTurn(at: 4)])
        XCTAssertNil(headphones.state.echoGateUntil)
        XCTAssertFalse(headphones.say("plus chaud", at: 4.1).isEmpty)

        var talking = speaking(bargeIn: .full)
        talking.audio(from: 3.5, to: 3.9, db: -20)
        talking.say("non plutôt le ciel", at: 3.9)
        XCTAssertEqual(talking.state.phase, .userSpeaking)
        talking.send(.speaker(2, .drained, at: 4))
        XCTAssertNil(talking.state.echoGateUntil, "the user's words are never gated")
    }

    // MARK: External endpointing (the simple path)

    func testExternalEndpointingNeverCommitsOnSilence() {
        var script = simplePath()
        script.say("plus chaud", at: 2)
        XCTAssertEqual(script.state.phase, .userSpeaking)
        for time in stride(from: 2.1, through: 10, by: 0.1) {
            XCTAssertFalse(commits(script.send(.tick(time))), "the recognizer decides, t=\(time)")
        }
        XCTAssertTrue(commits(script.send(.utterance("plus chaud", at: 10.1))))
    }

    func testExternalEndpointingCaps() {
        var words = simplePath()
        words.say("je voudrais que", at: 2)
        XCTAssertEqual(words.send(.tick(26.9)), [])
        XCTAssertEqual(words.send(.tick(27.1)), [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: 27.1), .openMic])
        XCTAssertEqual(words.state.phase, .listening)

        var noise = simplePath()
        noise.audio(from: 1, to: 5.2, db: -35)
        XCTAssertEqual(noise.state.phase, .userSpeaking)
        XCTAssertEqual(noise.send(.tick(4.9)), [])
        XCTAssertEqual(noise.send(.tick(5.0)), [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: 5), .openMic])
    }

    func testReturningToListeningReopensTheEar() {
        var edit = simplePath()
        XCTAssertTrue(commits(edit.send(.utterance("plus chaud", at: 2))))
        edit.send(.turn(1, .toolStarted, at: 2.5))
        edit.send(.turn(1, .toolFinished(changedDocument: true), at: 2.8))
        XCTAssertEqual(edit.send(.turn(1, .ended(endsWithQuestion: false), at: 2.9)), [.openMic], "an edit that said nothing")
        XCTAssertEqual(edit.state.phase, .listening)

        var reply = simplePath()
        reply.send(.utterance("tu en penses quoi", at: 2))
        reply.send(.turn(1, .firstOutput, at: 3))
        reply.send(.speaker(1, .chunkQueued, at: 3))
        XCTAssertEqual(reply.send(.speaker(1, .chunkStarted("Elle est belle."), at: 3.1)), [.setInputMuted(true)], "half duplex on the loudspeaker")
        reply.send(.turn(1, .ended(endsWithQuestion: false), at: 3.2))
        XCTAssertEqual(reply.send(.speaker(1, .drained, at: 4)), [.setInputMuted(false), .beginUserTurn(at: 4.6), .openMic])

        var failed = simplePath()
        failed.send(.utterance("plus chaud", at: 2))
        XCTAssertEqual(failed.send(.turn(1, .failed, at: 3)), [.earcon(.error), .openMic])

        var duplex = TurnScript.thinking()
        XCTAssertEqual(duplex.send(.turn(1, .ended(endsWithQuestion: false), at: 3)), [], "the duplex path never closed its ear")
    }
}
