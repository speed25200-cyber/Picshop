#if os(iOS) && canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore
import PicshopIntent

/// The assistant's voice in Live: sentence chunks rendered by a `SpeechRenderer`,
/// converted to the player format and scheduled on the Live engine, so the echo
/// canceller hears exactly what the loudspeaker says.
///
/// Rendering and scheduling run off the main actor; only the signals come back:
/// `chunkQueued` at once, `chunkStarted` when a chunk becomes audible,
/// `chunkFinished` when its last buffer was played, `drained` when nothing is left.
/// The next chunk is synthesized as soon as the previous one is, so sentences follow
/// each other with no gap.
@MainActor
public final class LiveSpeaker {
    public var onSignal: ((Int, SpeakerSignal) -> Void)?
    /// The synthesizer produced nothing in time: speech moved to `speak()`, outside the echo canceller.
    public var onFallback: ((String) -> Void)?
    /// liveRate, 0.85...1.25, times the system default rate.
    public var rateMultiplier: Double = 1
    /// Language code ("fr", "en") -> voice identifier chosen in Settings.
    public var preferredVoices: [String: String] = [:]
    /// liveSpeakerUsesSystem, or the fallback: AVSpeechSynthesizer.speak() instead of the engine.
    public private(set) var usesSystemSpeech = false
    /// "Amélie (premium)", for Diagnostic Live.
    public private(set) var voiceDescription = ""
    /// Something is queued, rendering or playing.
    public var isSpeaking: Bool { !pending.isEmpty || !playing.isEmpty || system.isBusy }

    private final class Chunk {
        let id: Int
        let text: String
        let language: String
        let turn: Int
        var scheduled = 0
        var played = 0
        var synthesized = false
        var started = false
        /// The renderer produced audio (scheduled or not: the engine may be paused).
        var rendered = false

        init(id: Int, text: String, language: String, turn: Int) {
            self.id = id
            self.text = text
            self.language = language
            self.turn = turn
        }
    }

    private let engine: LiveAudioEngine
    private let renderer: any SpeechRenderer
    private let epochBox = LiveSpeakerEpoch()
    private var pending: [Chunk] = []
    /// Rendering or rendered chunks whose audio is not over, in playing order.
    private var playing: [Chunk] = []
    private var renderingID: Int?
    private var renderTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var nextID = 0
    private var lastTurn = 0
    private var warmedUp = false
    private var system: SystemSpeechPlayer

    public init(engine: LiveAudioEngine, renderer: any SpeechRenderer = SynthesizerSpeechRenderer()) {
        self.engine = engine
        self.renderer = renderer
        system = SystemSpeechPlayer()
        system.onSignal = { [weak self] turn, signal in self?.onSignal?(turn, signal) }
    }

    /// Debug A/B: the system speech path for the whole session.
    public func setUsesSystemSpeech(_ on: Bool) {
        usesSystemSpeech = on
        engine.bypassesEchoCanceller = on
    }

    /// Loads the voices by synthesizing a real word per language into a discarded buffer.
    public func warmUp(languages: [String]) {
        let voices = languages.map { (language: $0, voice: voiceIdentifier(for: $0)) }
        let rate = speechRate
        Task.detached(priority: .userInitiated) { [weak self] in
            let renderer = SynthesizerSpeechRenderer()
            for entry in voices {
                let word = entry.language.hasPrefix("fr") ? "Bonjour" : "Hello"
                let stream = renderer.render(text: word, language: Self.bcp47(entry.language), voiceIdentifier: entry.voice, rate: rate)
                _ = try? await Self.drain(stream, timeout: 3)
            }
            await self?.markWarmedUp()
        }
    }

    private func markWarmedUp() {
        warmedUp = true
    }

    // MARK: Queue

    public func enqueue(_ text: String, language: String, turn: Int) {
        let clean = SpeakableText.clean(text)
        guard !clean.isEmpty else { return }
        nextID += 1
        lastTurn = turn
        let chunk = Chunk(id: nextID, text: clean, language: language, turn: turn)
        onSignal?(turn, .chunkQueued)
        if usesSystemSpeech {
            system.enqueue(text: clean, language: Self.bcp47(language), voiceIdentifier: voiceIdentifier(for: language), rate: speechRate, turn: turn)
            return
        }
        pending.append(chunk)
        pump()
    }

    /// An 80 ms tone on the Live engine, heard by the echo canceller like the voice.
    public func playEarcon(_ earcon: Earcon) {
        guard let buffer = Earcons.buffer(for: earcon) else { return }
        engine.playEarcon(buffer)
    }

    /// Fades the voice out and forgets everything queued. Signals `drained` when something was cut.
    public func stop(fadeMs: Int) {
        let hadWork = !pending.isEmpty || !playing.isEmpty
        let systemWasBusy = system.isBusy
        epochBox.bump()
        pending.removeAll()
        playing.removeAll()
        renderingID = nil
        renderTask?.cancel()
        renderTask = nil
        watchdog?.cancel()
        watchdog = nil
        renderer.cancel()
        system.stop()
        engine.fadeOutVoice(milliseconds: fadeMs)
        if hadWork || systemWasBusy { onSignal?(lastTurn, .drained) }
    }

    /// The engine was rebuilt: what was queued on the old player is gone, so the
    /// chunk being heard and the ones after it are rendered again from their text.
    public func engineDidRebuild() {
        guard !usesSystemSpeech else { return }
        let remaining = playing + pending
        guard !remaining.isEmpty else { return }
        epochBox.bump()
        renderTask?.cancel()
        renderTask = nil
        watchdog?.cancel()
        renderer.cancel()
        renderingID = nil
        playing = []
        pending = remaining.map { old in
            let fresh = Chunk(id: old.id, text: old.text, language: old.language, turn: old.turn)
            // Already announced: heard again, but not signalled twice.
            fresh.started = old.started
            return fresh
        }
        pump()
    }

    // MARK: Rendering

    private var speechRate: Float {
        AVSpeechUtteranceDefaultSpeechRate * Float(min(max(rateMultiplier, 0.85), 1.25))
    }

    private func voiceIdentifier(for language: String) -> String? {
        let code = String(language.prefix(2)).lowercased()
        guard let voice = SystemVoices.best(for: Self.bcp47(code), preferredIdentifier: preferredVoices[code]) else {
            voiceDescription = "system default"
            return nil
        }
        let quality: String
        switch voice.quality {
        case .premium: quality = "premium"
        case .enhanced: quality = "enhanced"
        case .standard: quality = "standard"
        }
        voiceDescription = "\(voice.name) (\(voice.language), \(quality))"
        return voice.identifier
    }

    nonisolated static func bcp47(_ language: String) -> String {
        if language.contains("-") { return language }
        return language.lowercased().hasPrefix("fr") ? "fr-FR" : "en-US"
    }

    private func pump() {
        guard renderingID == nil, !pending.isEmpty else { return }
        let chunk = pending.removeFirst()
        playing.append(chunk)
        renderingID = chunk.id
        let epoch = epochBox.value
        let stream = renderer.render(text: chunk.text, language: Self.bcp47(chunk.language), voiceIdentifier: voiceIdentifier(for: chunk.language), rate: speechRate)
        let handle = engine.players
        let chunkID = chunk.id
        let box = epochBox
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            var converter: AVAudioConverter?
            var first = true
            let owner = self
            do {
                for try await buffer in stream {
                    guard box.value == epoch else { break }
                    if first {
                        first = false
                        Self.post(owner, epoch: epoch, box: box) { $0.rendered(chunkID) }
                    }
                    if converter == nil || converter?.inputFormat != buffer.format {
                        converter = AVAudioConverter(from: buffer.format, to: LiveAudioFormat.player)
                    }
                    guard let converter, let converted = Self.convert(buffer, with: converter, endOfStream: false) else { continue }
                    Self.schedule(converted, handle: handle, chunkID: chunkID, epoch: epoch, box: box, speaker: self)
                }
                if box.value == epoch, let converter, let tail = Self.convert(nil, with: converter, endOfStream: true) {
                    Self.schedule(tail, handle: handle, chunkID: chunkID, epoch: epoch, box: box, speaker: self)
                }
            } catch {
                PSLog.error("live speech render failed: \(error)", category: .speech)
            }
            // After every schedule call on the audio queue, so the count is complete.
            LiveAudioQueue.queue.async {
                Self.post(owner, epoch: epoch, box: box) { $0.synthesized(chunkID) }
            }
        }
        startWatchdog(for: chunk, epoch: epoch)
    }

    /// No buffer in time: the synthesizer is stuck for this voice. Speak() for the rest of the session.
    private func startWatchdog(for chunk: Chunk, epoch: Int) {
        watchdog?.cancel()
        let limit: UInt64 = warmedUp ? 700_000_000 : 2_000_000_000
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            guard let self, !Task.isCancelled, self.epochBox.value == epoch else { return }
            guard !chunk.rendered, !chunk.synthesized else { return }
            self.fallBackToSystemSpeech(reason: "no audio buffer after \(limit / 1_000_000) ms")
        }
    }

    private func fallBackToSystemSpeech(reason: String) {
        let remaining = playing + pending
        epochBox.bump()
        renderTask?.cancel()
        renderTask = nil
        renderer.cancel()
        renderingID = nil
        playing = []
        pending = []
        usesSystemSpeech = true
        engine.bypassesEchoCanceller = true
        onFallback?(reason)
        for chunk in remaining {
            system.enqueue(text: chunk.text, language: Self.bcp47(chunk.language), voiceIdentifier: voiceIdentifier(for: chunk.language),
                           rate: speechRate, turn: chunk.turn, alreadyStarted: chunk.started)
        }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer?, with converter: AVAudioConverter, endOfStream: Bool) -> AVAudioPCMBuffer? {
        let output = LiveAudioFormat.player
        let inputFrames = Double(buffer?.frameLength ?? 0)
        let ratio = output.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(64, (inputFrames * ratio).rounded(.up) + 256))
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if let buffer, !consumed {
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, handle: LivePlayerHandle?, chunkID: Int, epoch: Int, box: LiveSpeakerEpoch, speaker: LiveSpeaker?) {
        LiveAudioQueue.queue.async {
            guard box.value == epoch, let handle else { return }
            // Counted before scheduling: the played callback can never overtake it.
            Self.post(speaker, epoch: epoch, box: box) { $0.scheduled(chunkID) }
            let accepted = handle.scheduleVoice(buffer) {
                Self.post(speaker, epoch: epoch, box: box) { $0.played(chunkID) }
            }
            if !accepted { Self.post(speaker, epoch: epoch, box: box) { $0.played(chunkID) } }
        }
    }

    /// Hops to the main thread in submission order, dropping stale epochs.
    nonisolated private static func post(_ speaker: LiveSpeaker?, epoch: Int, box: LiveSpeakerEpoch, _ work: @escaping @MainActor @Sendable (LiveSpeaker) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard box.value == epoch, let speaker else { return }
                work(speaker)
            }
        }
    }

    nonisolated private static func drain(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>, timeout: Double) async throws -> Int {
        var count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for try await _ in stream {
            count += 1
            if ProcessInfo.processInfo.systemUptime > deadline { break }
        }
        return count
    }

    // MARK: Bookkeeping (main actor, in submission order)

    private func rendered(_ id: Int) {
        playing.first(where: { $0.id == id })?.rendered = true
    }

    private func scheduled(_ id: Int) {
        guard let chunk = playing.first(where: { $0.id == id }) else { return }
        chunk.scheduled += 1
        if chunk.id == playing.first?.id { announceStartIfNeeded(chunk) }
    }

    private func played(_ id: Int) {
        guard let chunk = playing.first(where: { $0.id == id }) else { return }
        chunk.played += 1
        settle()
    }

    private func synthesized(_ id: Int) {
        if let chunk = playing.first(where: { $0.id == id }) { chunk.synthesized = true }
        if renderingID == id {
            renderingID = nil
            watchdog?.cancel()
            watchdog = nil
        }
        settle()
        pump()
    }

    private func announceStartIfNeeded(_ chunk: Chunk) {
        guard !chunk.started, chunk.scheduled > 0 else { return }
        chunk.started = true
        onSignal?(chunk.turn, .chunkStarted(chunk.text))
    }

    /// Retires the chunks that were fully heard; the next one becomes audible.
    private func settle() {
        while let first = playing.first, first.synthesized, first.played >= first.scheduled {
            playing.removeFirst()
            onSignal?(first.turn, .chunkFinished)
        }
        if let next = playing.first { announceStartIfNeeded(next) }
        if playing.isEmpty, pending.isEmpty, renderingID == nil {
            onSignal?(lastTurn, .drained)
        }
    }
}

/// The render generation: bumped by every stop, read from any thread.
final class LiveSpeakerEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    var value: Int { lock.withLock { current } }

    func bump() {
        lock.withLock { current += 1 }
    }
}

/// The fallback voice: AVSpeechSynthesizer.speak(), whose audio bypasses the
/// echo canceller. Barge-in then relies on stop words, taps and typing.
@MainActor
final class SystemSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    var onSignal: ((Int, SpeakerSignal) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterances: [ObjectIdentifier: (turn: Int, text: String, started: Bool)] = [:]
    private var lastTurn = 0

    var isBusy: Bool { !utterances.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(text: String, language: String, voiceIdentifier: String?, rate: Float, turn: Int, alreadyStarted: Bool = false) {
        let utterance = SynthesizerSpeechRenderer.utterance(text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate)
        utterances[ObjectIdentifier(utterance)] = (turn, text, alreadyStarted)
        lastTurn = turn
        synthesizer.speak(utterance)
    }

    func stop() {
        utterances.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func started(_ id: ObjectIdentifier) {
        guard let entry = utterances[id], !entry.started else { return }
        utterances[id]?.started = true
        onSignal?(entry.turn, .chunkStarted(entry.text))
    }

    private func finished(_ id: ObjectIdentifier) {
        guard let entry = utterances.removeValue(forKey: id) else { return }
        onSignal?(entry.turn, .chunkFinished)
        if utterances.isEmpty { onSignal?(lastTurn, .drained) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.started(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
}
#endif
