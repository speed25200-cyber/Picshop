#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Turns text into audio buffers as they are synthesized, so speech starts before
/// the sentence is complete. Behind a protocol, so a neural voice can replace the
/// system one without touching the chunker, the captions or the interruptions.
public protocol SpeechRenderer: AnyObject, Sendable {
    /// Buffers in the voice's own format, in order; the stream ends with the utterance.
    func render(text: String, language: String, voiceIdentifier: String?, rate: Float) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    /// Stops the utterance being rendered; its stream ends.
    func cancel()
}

/// The system voices through `AVSpeechSynthesizer.write(_:toBufferCallback:)`:
/// one synthesizer, one utterance at a time. After a cancel the next utterance
/// gets a fresh synthesizer, so a stopped one can never swallow it.
public final class SynthesizerSpeechRenderer: SpeechRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var synthesizer = AVSpeechSynthesizer()
    private var needsFreshSynthesizer = false
    private var active: (id: Int, continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation)?
    private var counter = 0

    public init() {}

    public func render(text: String, language: String, voiceIdentifier: String?, rate: Float) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let utterance = Self.utterance(text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate)
            let (synthesizer, id): (AVSpeechSynthesizer, Int) = lock.withLock {
                if needsFreshSynthesizer {
                    self.synthesizer = AVSpeechSynthesizer()
                    needsFreshSynthesizer = false
                }
                counter += 1
                active?.continuation.finish()
                active = (counter, continuation)
                return (self.synthesizer, counter)
            }
            continuation.onTermination = { [weak self] _ in self?.clear(id) }
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // The empty buffer ends the utterance.
                    continuation.finish()
                    self?.clear(id)
                } else {
                    continuation.yield(pcm)
                }
            }
        }
    }

    public func cancel() {
        let (synthesizer, continuation): (AVSpeechSynthesizer, AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?) = lock.withLock {
            let pending = active?.continuation
            active = nil
            needsFreshSynthesizer = true
            return (self.synthesizer, pending)
        }
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.finish()
    }

    private func clear(_ id: Int) {
        lock.withLock {
            if active?.id == id { active = nil }
        }
    }

    static func utterance(text: String, language: String, voiceIdentifier: String?, rate: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }
}
#endif
