#if os(iOS) && canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopIntent

/// Live's short tones, generated once in the player format. They play on the
/// Live engine, so the echo canceller removes them from the microphone.
enum Earcons {
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cache: [Earcon: AVAudioPCMBuffer] = [:]
    private static let lock = NSLock()

    static func buffer(for earcon: Earcon) -> AVAudioPCMBuffer? {
        if let cached = lock.withLock({ cache[earcon] }) { return cached }
        guard let made = make(earcon) else { return nil }
        lock.withLock { cache[earcon] = made }
        return made
    }

    /// (frequency Hz, start s, length s) notes; about 80 ms in total.
    private static func notes(for earcon: Earcon) -> [(Double, Double, Double)] {
        switch earcon {
        case .open: return [(660, 0, 0.04), (880, 0.04, 0.045)]
        case .close: return [(880, 0, 0.04), (587, 0.04, 0.045)]
        case .commit: return [(1_046, 0, 0.035)]
        case .applied: return [(784, 0, 0.04), (1_175, 0.035, 0.05)]
        case .error: return [(330, 0, 0.08)]
        }
    }

    private static func make(_ earcon: Earcon) -> AVAudioPCMBuffer? {
        let format = LiveAudioFormat.player
        let rate = format.sampleRate
        let notes = notes(for: earcon)
        let length = notes.map { $0.1 + $0.2 }.max() ?? 0.08
        let frames = AVAudioFrameCount((length + 0.01) * rate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { samples[index] = 0 }
        let amplitude = 0.14
        for (frequency, start, duration) in notes {
            let first = Int(start * rate)
            let count = Int(duration * rate)
            let fade = max(1, Int(0.006 * rate))
            for offset in 0..<count where first + offset < Int(frames) {
                // Short attack and release, so the tone never clicks.
                let envelope = min(1, Double(offset) / Double(fade), Double(count - offset) / Double(fade))
                let value = sin(2 * Double.pi * frequency * Double(offset) / rate) * amplitude * envelope
                samples[first + offset] += Float(value)
            }
        }
        return buffer
    }
}
#endif
