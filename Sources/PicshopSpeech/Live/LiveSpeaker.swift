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
///
/// Audio that was not played is never reported as played: a buffer no running
/// engine accepted, a chunk that retired far faster than its audio lasts (buffers
/// cleared by a configuration change), a render that produced nothing or never
/// ended — each moves the voice to `speak()`, which replays what was not heard.
@MainActor
public final class LiveSpeaker {
    public var onSignal: ((Int, SpeakerSignal) -> Void)?
    /// The engine voice failed (nothing rendered in time, a buffer no engine played,
    /// buffers cleared): speech moved to `speak()`, outside the echo canceller.
    public var onFallback: ((String) -> Void)?
    /// `speak()` itself stayed silent (it did not start within 2.5 s): the line was only
    /// captioned. The session shows it and may keep to captions.
    public var onVoiceFailure: ((String) -> Void)?
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
        /// Seconds of audio scheduled, and when the first buffer was: a chunk that
        /// retires in less than 40% of that time was not heard.
        var audioSeconds = 0.0
        var firstScheduledAt: Double?

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
        system.onSilent = { [weak self] reason in self?.onVoiceFailure?(reason) }
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

    /// Media services were reset: `speak()` gets a fresh synthesizer (the old one is no
    /// longer valid), and the line it held is said again.
    public func resetSystemVoice() {
        system.resetSynthesizer()
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

    /// Two limits per chunk: its first buffer (0.7 s once the voice is warm, 2 s before),
    /// and the end of its render, 3 s + words/1.5 (a write() stream that never sends its
    /// empty end buffer would otherwise hold the queue forever). Either moves the voice
    /// to `speak()` for the rest of the session.
    private func startWatchdog(for chunk: Chunk, epoch: Int) {
        watchdog?.cancel()
        let first = warmedUp ? 0.7 : 2.0
        let words = chunk.text.split(whereSeparator: { $0.isWhitespace }).count
        let complete = max(first, 3 + Double(words) / 1.5)
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(first * 1_000_000_000))
            guard let self, !Task.isCancelled, self.epochBox.value == epoch else { return }
            if !chunk.rendered, !chunk.synthesized {
                self.fallBackToSystemSpeech(reason: "no audio buffer after \(Int(first * 1000)) ms")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64((complete - first) * 1_000_000_000))
            guard !Task.isCancelled, self.epochBox.value == epoch, !chunk.synthesized else { return }
            self.fallBackToSystemSpeech(reason: "render stream never ended")
        }
    }

    /// Everything not heard yet (the chunk playing included) is said again with `speak()`.
    private func fallBackToSystemSpeech(reason: String) {
        guard !usesSystemSpeech else { return }
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

    /// On the audio queue. A buffer goes only to a valid player on a running engine; with
    /// none (stopped, rebuilding, never started) the chunk cannot play, and is never
    /// counted as played.
    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, handle: LivePlayerHandle?, chunkID: Int, epoch: Int, box: LiveSpeakerEpoch, speaker: LiveSpeaker?) {
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        LiveAudioQueue.queue.async {
            guard box.value == epoch else { return }
            guard let handle, handle.isValid, handle.engine.isRunning else {
                Self.post(speaker, epoch: epoch, box: box) { $0.cannotPlay(chunkID) }
                return
            }
            // Counted before scheduling: the played callback can never overtake it.
            Self.post(speaker, epoch: epoch, box: box) { $0.scheduled(chunkID, seconds: seconds) }
            let accepted = handle.scheduleVoice(buffer) {
                Self.post(speaker, epoch: epoch, box: box) { $0.played(chunkID) }
            }
            if !accepted { Self.post(speaker, epoch: epoch, box: box) { $0.cannotPlay(chunkID) } }
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

    private func scheduled(_ id: Int, seconds: Double) {
        guard let chunk = playing.first(where: { $0.id == id }) else { return }
        chunk.scheduled += 1
        chunk.audioSeconds += seconds
        if chunk.firstScheduledAt == nil { chunk.firstScheduledAt = ProcessInfo.processInfo.systemUptime }
        if chunk.id == playing.first?.id { announceStartIfNeeded(chunk) }
    }

    /// No running engine took the buffer: the voice moves to `speak()`, which says this chunk again.
    private func cannotPlay(_ id: Int) {
        guard playing.contains(where: { $0.id == id }) else { return }
        fallBackToSystemSpeech(reason: "engine could not play chunk \(id)")
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

    /// Retires the chunks that were fully heard; the next one becomes audible. A chunk
    /// whose render produced no audio, or whose buffers "played" in less than 40% of their
    /// length (a configuration change unscheduled them), was not heard: `speak()` says it.
    private func settle() {
        while let first = playing.first, first.synthesized, first.played >= first.scheduled {
            if first.scheduled == 0 {
                fallBackToSystemSpeech(reason: "the renderer produced no audio")
                return
            }
            if first.audioSeconds > 0.4, let start = first.firstScheduledAt,
               ProcessInfo.processInfo.systemUptime - start < first.audioSeconds * 0.4 {
                fallBackToSystemSpeech(reason: "voice buffers cleared by a configuration change")
                return
            }
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

/// The system voice: AVSpeechSynthesizer.speak(). Live's simple path talks with it,
/// and the engine voice falls back to it; its audio bypasses the echo canceller, so
/// barge-in then relies on stop words, taps and typing.
///
/// One utterance is handed to the synthesizer at a time, so each has its own limits:
/// it must start within 2.5 s and finish within 2.5 s + words/1.8 of starting. A line
/// that does not start is captioned at once and said again by a fresh synthesizer (a cold
/// voice, a Premium voice still loading, a synthesizer left invalid by a media reset); only
/// when that retry misses 2.5 s too is the line captioned for its reading time and
/// reported through `onSilent`. The reducer is never left waiting.
@MainActor
final class SystemSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    var onSignal: ((Int, SpeakerSignal) -> Void)?
    /// A line did not start in time: it was captioned, not heard.
    var onSilent: ((String) -> Void)?

    private final class Entry {
        /// Replaced by a fresh copy when the line is said again (an utterance is spoken once).
        var utterance: AVSpeechUtterance
        let turn: Int
        let text: String
        let language: String
        let voiceIdentifier: String?
        let rate: Float
        var started: Bool
        /// Utterances this line replaced, kept alive so a late callback's ObjectIdentifier never matches the new one.
        private var replaced: [AVSpeechUtterance] = []

        init(turn: Int, text: String, language: String, voiceIdentifier: String?, rate: Float, started: Bool) {
            self.turn = turn
            self.text = text
            self.language = language
            self.voiceIdentifier = voiceIdentifier
            self.rate = rate
            self.started = started
            utterance = Entry.makeUtterance(text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate)
        }

        /// A fresh utterance for the same line, for another synthesizer.
        func renew() {
            replaced.append(utterance)
            utterance = Entry.makeUtterance(text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate)
        }

        private static func makeUtterance(text: String, language: String, voiceIdentifier: String?, rate: Float) -> AVSpeechUtterance {
            let utterance = SynthesizerSpeechRenderer.utterance(text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate)
            utterance.volume = 1
            return utterance
        }
    }

    static let startLimit = 2.5

    private var synthesizer = AVSpeechSynthesizer()
    /// In speaking order; only the first one is with the synthesizer.
    private var queue: [Entry] = []
    private var watchdog: Task<Void, Never>?
    private var lastTurn = 0
    /// Lines in a row that did not start in time; reset by a line that starts and by `stop()`.
    private var consecutiveStartFailures = 0

    var isBusy: Bool { !queue.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(text: String, language: String, voiceIdentifier: String?, rate: Float, turn: Int, alreadyStarted: Bool = false) {
        queue.append(Entry(turn: turn, text: text, language: language, voiceIdentifier: voiceIdentifier, rate: rate, started: alreadyStarted))
        lastTurn = turn
        if queue.count == 1 { speakHead() }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        consecutiveStartFailures = 0
        let wasBusy = !queue.isEmpty
        queue.removeAll()
        if wasBusy { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Media services were reset: the synthesizer is no longer valid. A fresh one takes
    /// over, and the line it held (if any) is said again from its start.
    func resetSynthesizer() {
        replaceSynthesizer()
        guard let head = queue.first else { return }
        head.renew()
        speakHead()
    }

    private func replaceSynthesizer() {
        let old = synthesizer
        old.delegate = nil
        old.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    private func speakHead() {
        guard let head = queue.first else { return }
        synthesizer.speak(head.utterance)
        let id = ObjectIdentifier(head.utterance)
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startLimit * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.startTimedOut(id)
        }
    }

    private func isHead(_ id: ObjectIdentifier) -> Entry? {
        guard let head = queue.first, ObjectIdentifier(head.utterance) == id else { return nil }
        return head
    }

    private func started(_ id: ObjectIdentifier) {
        guard let head = isHead(id) else { return }
        consecutiveStartFailures = 0
        if !head.started {
            head.started = true
            onSignal?(head.turn, .chunkStarted(head.text))
        }
        // didFinish may never come: the line is retired anyway, well after its real length.
        let words = head.text.split(whereSeparator: { $0.isWhitespace }).count
        let limit = 2.5 + Double(words) / 1.8
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isHead(id) != nil else { return }
            PSLog.error("live: speak() never finished a line; retired after \(Int(limit)) s", category: .speech)
            self.complete(id)
        }
    }

    /// The head did not start: this synthesizer is stuck (or only slow: a cold voice). The
    /// line is captioned now, and a fresh synthesizer says it again; the reducer's drain
    /// deadline (3 s + words/1.8 from `chunkStarted`) leaves room for that retry. When the
    /// retry misses its 2.5 s too, the line stays captioned for its reading time and
    /// `onSilent` reports the voice.
    private func startTimedOut(_ id: ObjectIdentifier) {
        guard let head = isHead(id) else { return }
        replaceSynthesizer()
        if !head.started {
            head.started = true
            onSignal?(head.turn, .chunkStarted(head.text))
        }
        consecutiveStartFailures += 1
        if consecutiveStartFailures < 2 {
            PSLog.error("live: speak() did not start within \(Self.startLimit) s; said again by a fresh synthesizer", category: .speech)
            head.renew()
            speakHead()
            return
        }
        onSilent?("speak() did not start within \(Self.startLimit) s, twice")
        let words = head.text.split(whereSeparator: { $0.isWhitespace }).count
        let reading = max(1.5, Double(words) / 2.5)
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(reading * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.complete(id)
        }
    }

    /// The head is over (finished, cancelled by the system, or retired by a watchdog).
    private func complete(_ id: ObjectIdentifier) {
        guard let head = isHead(id) else { return }
        watchdog?.cancel()
        watchdog = nil
        queue.removeFirst()
        onSignal?(head.turn, .chunkFinished)
        if queue.isEmpty {
            onSignal?(lastTurn, .drained)
        } else {
            speakHead()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.started(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Only a cancel we did not ask for reaches the head: stop() empties the queue first.
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }
}
#endif
