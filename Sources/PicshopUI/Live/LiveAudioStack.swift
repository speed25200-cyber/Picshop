#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Everything Live hears and says, behind one small surface for LiveSession:
/// the audio session, the full-duplex engine, the recognizer and the voice.
@MainActor
final class LiveAudioStack {
    let engine = LiveAudioEngine()
    let speaker: LiveSpeaker
    private(set) var transcriber: (any LiveTranscribing)?
    private(set) var isMicOpen = false
    var onSegment: ((TranscriptSegment) -> Void)?
    var onEngineEvent: ((LiveAudioEngine.Event) -> Void)?
    private var segmentsTask: Task<Void, Never>?
    private var hdBluetooth = false
    private var isStopped = false

    init() {
        speaker = LiveSpeaker(engine: engine)
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Session, engine and recognizer, the engine and the recognizer's setup in parallel.
    /// Returns false when no recognizer is available (Live then works by typing).
    func start(hdBluetooth: Bool, locale: Locale, installing: @escaping @Sendable () -> Void) async throws -> Bool {
        self.hdBluetooth = hdBluetooth
        try await AudioSessionArbiter.shared.acquire(.live, hdBluetooth: hdBluetooth)
        async let recognizer = LiveTranscriberFactory.make(locale: locale, installing: installing)
        do {
            try await engine.start()
        } catch {
            _ = await recognizer
            throw error
        }
        let transcriber = await recognizer
        guard !isStopped else { return false }
        guard let transcriber else { return false }
        do {
            try await transcriber.start()
        } catch {
            PSLog.error("live: recognizer did not start: \(error)", category: .speech)
            return false
        }
        guard !isStopped else {
            Task.detached { await transcriber.stop() }
            return false
        }
        self.transcriber = transcriber
        engine.setMicrophoneSink { buffer, uptime in transcriber.append(buffer, uptime: uptime) }
        segmentsTask = Task { @MainActor [weak self] in
            for await segment in transcriber.segments {
                guard let self, !Task.isCancelled else { return }
                self.onSegment?(segment)
            }
        }
        return true
    }

    /// Everything off: the voice, the engine (the microphone indicator goes out), the recognizer, the session.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        isMicOpen = false
        segmentsTask?.cancel()
        segmentsTask = nil
        engine.setMicrophoneSink(nil)
        engine.setMicrophoneOpen(false)
        speaker.stop(fadeMs: 0)
        engine.stop()
        if let transcriber {
            Task.detached { await transcriber.stop() }
        }
        transcriber = nil
        AudioSessionArbiter.shared.release(.live)
    }

    /// The engine already runs: the flow opens (or stays closed when `listens` is false) at once.
    func openMicNow(_ listens: Bool) -> Bool {
        guard !isStopped, engine.isRunning, engine.isEngineRunning else { return false }
        isMicOpen = listens
        engine.setMicrophoneOpen(listens)
        return true
    }

    /// Features and recognition flow; the engine is restarted when a pause or an interruption stopped it.
    func openMic(_ listens: Bool) async {
        guard !isStopped else { return }
        isMicOpen = listens
        do {
            if !engine.isRunning {
                try await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: hdBluetooth)
                try await engine.start()
            } else if !engine.isEngineRunning {
                // After a pause or an interruption: the session again, then a fresh engine.
                try? await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: hdBluetooth)
                await engine.resume()
            }
        } catch {
            PSLog.error("live: microphone did not reopen: \(error)", category: .speech)
            onEngineEvent?(.failed(String(describing: error)))
        }
        guard isMicOpen, !isStopped else { return }
        engine.setMicrophoneOpen(listens)
    }

    /// A pause: no features, no recognition, and the engine stops so the microphone indicator goes out.
    func closeMic() {
        isMicOpen = false
        engine.setMicrophoneOpen(false)
        speaker.stop(fadeMs: 0)
        engine.pause()
    }

    func setInputMuted(_ muted: Bool) {
        engine.setInputMuted(muted)
    }

    func playEarcon(_ earcon: Earcon) {
        speaker.playEarcon(earcon)
    }

    private func handle(_ event: LiveAudioEngine.Event) {
        switch event {
        case .rebuilt:
            speaker.engineDidRebuild()
        case .mediaServicesReset:
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                try? await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: self.hdBluetooth)
                await self.engine.resume()
            }
        case .interrupted, .routeChanged, .failed:
            break
        }
        onEngineEvent?(event)
    }
}
#endif
