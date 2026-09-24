#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Converts microphone buffers to the format a recognizer reads, for the
/// push-to-talk sessions and for Live. A buffer in a new format (a route change,
/// voice processing turned on) gets a new converter; several input channels are
/// mixed down rather than dropped. Thread-safe: `convert` runs on the tap's thread.
final class AnalyzerInputConverter: @unchecked Sendable {
    /// Nil: buffers pass through unchanged.
    let outputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat?) {
        self.outputFormat = outputFormat
    }

    /// Builds the converter ahead of the first buffer, from the format read right before the tap.
    func prepare(inputFormat: AVAudioFormat) {
        let converter = Self.makeConverter(from: inputFormat, to: outputFormat)
        lock.withLock { self.converter = converter }
    }

    /// The buffer in `outputFormat`; the same buffer when no conversion is needed; nil when it cannot be used.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        guard buffer.frameLength > 0, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        guard let outputFormat, outputFormat != inputFormat else { return buffer }
        let converter: AVAudioConverter? = lock.withLock {
            if let current = self.converter, current.inputFormat == inputFormat { return current }
            let fresh = Self.makeConverter(from: inputFormat, to: outputFormat)
            self.converter = fresh
            return fresh
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        guard ratio.isFinite, ratio > 0 else { return nil }
        let capacity = AVAudioFrameCount(min(Double(UInt32.max / 2), (Double(buffer.frameLength) * ratio).rounded(.up))) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }

    private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat?) -> AVAudioConverter? {
        guard let output, input.sampleRate > 0, input.channelCount > 0, input != output else { return nil }
        let converter = AVAudioConverter(from: input, to: output)
        // Voice processing can deliver several channels: mix them into the recognizer's mono.
        converter?.downmix = true
        return converter
    }
}
#endif
