import Foundation
import PicshopCore

/// Energy voice activity detection on 20 ms frames, with an adaptive noise floor.
///
/// A frame is voiced when it is `marginDB` above the floor (15 dB while the
/// assistant speaks) and above -55 dBFS. Six voiced frames in a row start
/// speech, ten unvoiced ones end it. The floor falls fast (attack) and rises
/// slowly (release), and only while nobody speaks.
public struct VoiceActivityDetector: Sendable {
    public struct Parameters: Sendable {
        public var onsetFrames = 6
        public var hangoverFrames = 10
        public var marginDB: Float = 12
        public var marginWhileAssistantSpeaksDB: Float = 15
        public var absoluteFloorDB: Float = -55
        public var floorAttack: Float = 0.05
        public var floorRelease: Float = 0.002
        public var floorClamp: ClosedRange<Float> = -80 ... -30
        public var initialFloorDB: Float = -60

        public init() {}
    }

    public enum Event: Sendable, Equatable { case speechStart(Double), speechEnd(Double) }

    public let parameters: Parameters
    public private(set) var noiseFloorDB: Float
    public private(set) var isSpeech = false
    /// Start of the current (or last) speech run.
    public private(set) var speechStartedAt: Double?
    /// Time of the latest voiced frame.
    public private(set) var lastVoicedAt: Double?
    /// Level of the latest frame above the floor, in dB.
    public private(set) var levelAboveFloorDB: Float = 0
    private var voicedRun = 0
    private var voicedRunStart: Double?
    private var unvoicedRun = 0

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
        noiseFloorDB = parameters.initialFloorDB
    }

    public mutating func process(_ frame: AudioFrameFeatures, assistantSpeaking: Bool) -> Event? {
        let level = frame.rmsDB.isFinite ? frame.rmsDB : -120
        let margin = assistantSpeaking ? parameters.marginWhileAssistantSpeaksDB : parameters.marginDB
        let voiced = level > max(noiseFloorDB + margin, parameters.absoluteFloorDB)
        levelAboveFloorDB = level - noiseFloorDB

        if level < noiseFloorDB {
            noiseFloorDB += parameters.floorAttack * (level - noiseFloorDB)
        } else if !voiced && !isSpeech {
            noiseFloorDB += parameters.floorRelease * (level - noiseFloorDB)
        }
        noiseFloorDB = min(max(noiseFloorDB, parameters.floorClamp.lowerBound), parameters.floorClamp.upperBound)

        if voiced {
            lastVoicedAt = frame.time
            unvoicedRun = 0
            if voicedRun == 0 { voicedRunStart = frame.time }
            voicedRun += 1
            if !isSpeech, voicedRun >= parameters.onsetFrames {
                isSpeech = true
                speechStartedAt = voicedRunStart ?? frame.time
                return .speechStart(speechStartedAt ?? frame.time)
            }
        } else {
            voicedRun = 0
            unvoicedRun += 1
            if isSpeech, unvoicedRun >= parameters.hangoverFrames {
                isSpeech = false
                return .speechEnd(lastVoicedAt ?? frame.time)
            }
        }
        return nil
    }

    /// Seconds of the current speech run, 0 outside speech.
    public func speechDuration(at time: Double) -> Double {
        guard isSpeech, let start = speechStartedAt else { return 0 }
        return max(0, time - start)
    }

    /// The current run, or the last one if it ended within `window` seconds: the
    /// recognizer's words often arrive just after the speech that carried them.
    public func recentSpeechDuration(at time: Double, within window: Double = 1) -> Double {
        if isSpeech { return speechDuration(at: time) }
        guard let start = speechStartedAt, let end = lastVoicedAt, end >= start, time - end <= window else { return 0 }
        return end - start
    }
}
