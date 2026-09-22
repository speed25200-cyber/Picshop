#if canImport(AVFoundation) && canImport(Vision)
import Foundation
import AVFoundation
import AudioToolbox
import Vision
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging
#if canImport(Speech)
import Speech
#endif

// The Apple half of the magic video tools: decoding sound for the analysers
// in PicshopCore, transcribing speech on device, finding the subject of a
// shot, isolating a voice and measuring a clip's colours.

extension AVVideoServices {
    // MARK: Sound

    public func dialogueSignal(timeline: VideoTimeline) async throws -> AudioSignal {
        var clipsOnly = timeline
        clipsOnly.audioTracks = []
        return try await AudioDecoder.timelineSound(clipsOnly, builder: CompositionBuilder(store: store, projectID: projectID), sampleRate: 16_000)
    }

    public func musicSignal(track: AudioTrack) async throws -> AudioSignal {
        let asset = AVURLAsset(url: store.url(for: track.asset.relativePath, in: projectID))
        // Ten minutes are plenty to find a tempo.
        return try await AudioDecoder.decode(asset: asset, range: TimeSpan(start: 0, duration: min(600, max(track.asset.duration, track.sourceRange.end))), sampleRate: 22_050)
    }

    // MARK: Captions

    public func transcribe(timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> (words: [CaptionWord], language: String?) {
        progress(0.05)
        let signal = try await dialogueSignal(timeline: timeline)
        guard signal.duration > 0.3 else { return ([], nil) }
        progress(0.2)
        let locale = captionLocale
        let words = try await SpeechCaptioner.words(in: signal, locale: locale) { fraction in progress(0.2 + fraction * 0.8) }
        progress(1)
        return (words, locale.identifier(.bcp47))
    }

    // MARK: Smart reframe

    public func focusSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FocusSample] {
        let asset = asset(for: clip)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        // Four looks a second, at most 240 for long clips.
        let duration = clip.timelineDuration
        let step = max(0.25, duration / 240)
        var offsets: [Double] = []
        var offset = 0.0
        while offset <= duration {
            offsets.append(offset)
            offset += step
        }
        var samples: [FocusSample] = []
        for (index, offset) in offsets.enumerated() {
            try Task.checkCancellation()
            let sourceTime = clip.sourceTime(forClipOffset: offset)
            let generated = try? await generator.image(at: VideoTime.cm(sourceTime))
            guard let image = generated?.image else { continue }
            if let focus = SubjectFinder.focus(in: image) {
                samples.append(FocusSample(time: offset, point: focus.point, confidence: focus.confidence))
            } else {
                samples.append(FocusSample(time: offset, point: PSPoint(x: 0.5, y: 0.5), confidence: 0))
            }
            progress(Double(index + 1) / Double(offsets.count))
        }
        // Flipped clips see their subject mirrored.
        if clip.flipHorizontal {
            samples = samples.map { FocusSample(time: $0.time, point: PSPoint(x: 1 - $0.point.x, y: $0.point.y), confidence: $0.confidence) }
        }
        return samples
    }

    // MARK: Voice

    public func isolateVoice(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let asset = asset(for: clip)
        try store.createPackage(for: projectID)
        let output = store.mediaURL(for: projectID).appendingPathComponent("voice-\(UUID().uuidString).caf")
        let duration = try await VoiceIsolator.process(asset: asset, to: output, progress: progress)
        return MediaAsset(kind: .audio, relativePath: "\(Project.mediaDirectory)/\(output.lastPathComponent)", pixelSize: .zero, duration: duration, origin: .generated)
    }

    // MARK: Colour

    public func colorStatistics(clip: VideoClip, timeline: VideoTimeline) async throws -> ColorStatistics {
        let asset = asset(for: clip)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        var bytes: [UInt8] = []
        for fraction in [0.2, 0.5, 0.8] {
            let time = clip.sourceRange.start + clip.sourceRange.duration * fraction
            let generated = try? await generator.image(at: VideoTime.cm(time))
            if let image = generated?.image {
                bytes += ImageSupport.rgbaBytes(from: image)
            }
        }
        guard !bytes.isEmpty else { throw PicshopError.mediaUnavailable(clip.name) }
        return ColorStatistics.measure(rgba: bytes)
    }

    // MARK: Highlights

    public func momentScores(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [MomentScore] {
        let asset = asset(for: clip)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let tolerance = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // One look a second (fewer on very long clips), along the clip's span.
        let duration = clip.timelineDuration
        let step = max(1, duration / 300)
        let offsets = Array(stride(from: min(0.5, duration / 2), to: duration, by: step))
        guard !offsets.isEmpty else { return [] }

        // The sound: loud moments (laughs, cheers, speech) count.
        let sound = try? await AudioDecoder.decode(asset: asset, range: clip.sourceRange, sampleRate: 8_000)
        let envelope = sound.map { LoudnessEnvelope.measure($0, hop: 0.1, window: 0.5) }
        let quiet = envelope?.percentile(0.1) ?? -60, loud = envelope?.percentile(0.95) ?? -10

        var images: [CGImage] = []
        var times: [Double] = []
        var faces: [Double] = []
        var motion: [Double] = []
        var previous: FrameSignature?
        for (index, offset) in offsets.enumerated() {
            try Task.checkCancellation()
            guard let image = try? await generator.image(at: VideoTime.cm(clip.sourceTime(forClipOffset: offset))).image else { continue }
            let signature = FrameSignature.measure(rgba: ImageSupport.rgbaBytes(from: image), width: image.width, height: image.height, time: offset)
            motion.append(previous.map { min(1, signature.distance(to: $0) * 4) } ?? 0)
            previous = signature
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            faces.append((request.results?.isEmpty == false) ? 1 : 0)
            images.append(image)
            times.append(offset)
            progress(Double(index + 1) / Double(offsets.count) * 0.6)
        }
        let aesthetics = await AestheticsRanker.scores(for: images)
        progress(1)

        return times.indices.map { index in
            // Vision's aesthetics score runs −1…1.
            let look = aesthetics[index].map { ($0 + 1) / 2 } ?? 0.5
            var level = 0.5
            if let envelope, loud > quiet {
                let sourceOffset = abs(clip.sourceTime(forClipOffset: times[index]) - clip.sourceRange.start)
                let frame = min(envelope.decibels.count - 1, max(0, Int(sourceOffset / envelope.hop)))
                level = envelope.decibels.isEmpty ? 0.5 : Double((envelope.decibels[frame] - quiet) / (loud - quiet)).clamped(to: 0...1)
            }
            // Some movement is life; a whip pan is not.
            let moving = motion[index] < 0.7 ? motion[index] : 1.4 - motion[index]
            let score = 0.45 * look + 0.25 * level + 0.15 * moving + 0.15 * faces[index]
            return MomentScore(time: times[index], score: score)
        }
    }

    // MARK: Scenes

    public func sceneCuts(for clip: VideoClip, timeline: VideoTimeline, sensitivity: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        let asset = asset(for: clip)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let tolerance = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        func signature(at sourceTime: Double) async -> FrameSignature? {
            guard let image = try? await generator.image(at: VideoTime.cm(sourceTime)).image else { return nil }
            return FrameSignature.measure(rgba: ImageSupport.rgbaBytes(from: image), width: image.width, height: image.height, time: sourceTime)
        }

        // A first pass at eight looks a second (fewer on very long clips), on the source clock.
        let source = clip.sourceRange
        let step = max(0.125, source.duration / 2400)
        var frames: [FrameSignature] = []
        var time = source.start
        let count = max(1.0, source.duration / step)
        while time <= source.end {
            try Task.checkCancellation()
            if let frame = await signature(at: time) { frames.append(frame) }
            progress(min(0.9, Double(frames.count) / count * 0.9))
            time += step
        }
        let rough = SceneDetector.cuts(in: frames, sensitivity: sensitivity)

        // Each cut pinned to the exact frame: the biggest jump between the two looks around it.
        let rate = clip.asset.frameRate > 0 ? clip.asset.frameRate : timeline.frameRate
        let frameDuration = 1 / max(12, rate)
        var exact: [Double] = []
        for cut in rough {
            var best = (time: cut, jump: -1.0)
            var previous = await signature(at: cut - step)
            var moment = cut - step + frameDuration
            while moment <= cut + 0.001 {
                let current = await signature(at: moment)
                if let a = previous, let b = current {
                    let jump = b.distance(to: a)
                    if jump > best.jump { best = (moment, jump) }
                }
                previous = current
                moment += frameDuration
            }
            exact.append(best.time)
        }
        progress(1)
        // Source seconds to seconds along the clip's span on the timeline.
        return exact.map { clip.isReversed ? (source.end - $0) / clip.speed : ($0 - source.start) / clip.speed }.sorted()
    }

    // MARK: Tracking

    public func track(point: PSPoint, at time: Double, within span: TimeSpan, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [TrackSample] {
        // The finished picture without the overlays and captions, which would otherwise be tracked themselves.
        var bare = timeline
        bare.overlays = []
        bare.captions = nil
        bare.audioTracks = []
        let built = try await CompositionBuilder(store: store, projectID: projectID).build(bare)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.maximumSize = CGSize(width: 720, height: 720)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let limit = TimeSpan(start: max(0, span.start), end: min(span.end, timeline.duration))
        let anchor = time.clamped(to: limit.start...max(limit.start, limit.end))
        let step = max(1.0 / 12, limit.duration / 480)
        let forward = Array(stride(from: anchor, through: limit.end, by: step))
        let backward = Array(stride(from: anchor, through: limit.start, by: -step))
        let total = Double(max(1, forward.count + backward.count))

        let first = try await generator.image(at: VideoTime.cm(anchor)).image
        let start = SubjectTracker.startBox(around: point, in: first)
        var samples: [TrackSample] = []
        var done = 0.0
        for times in [forward, backward] {
            var tracker = SubjectTracker(box: start)
            for moment in times {
                try Task.checkCancellation()
                let generated = try? await generator.image(at: VideoTime.cm(moment))
                done += 1
                progress(done / total)
                guard let image = generated?.image, let box = tracker.advance(on: image) else { break }
                // Where the subject is, expressed as the overlay's point moving with it.
                samples.append(TrackSample(time: moment, point: PSPoint(x: Double(box.midX) + start.pointOffset.x, y: Double(1 - box.midY) + start.pointOffset.y)))
            }
        }
        progress(1)
        var seen = Set<Double>()
        return samples.sorted { $0.time < $1.time }.filter { seen.insert(($0.time * 1000).rounded()).inserted }
    }
}

/// Vision's object tracker, one frame after the other.
struct SubjectTracker {
    struct Start {
        /// Vision box (normalised, bottom-left origin).
        var box: CGRect
        /// From the box centre to the overlay's point, top-left origin.
        var pointOffset: PSPoint
    }

    private let handler = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation

    init(box: Start) {
        observation = VNDetectedObjectObservation(boundingBox: box.box)
    }

    /// The box to follow for a point: the face, person or salient object
    /// nearest to it when there is one — they track far better than an
    /// arbitrary patch — else a patch of picture around the point.
    static func startBox(around point: PSPoint, in image: CGImage) -> Start {
        let request = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request, humans, saliency])
        var boxes: [CGRect] = (request.results ?? []).map(\.boundingBox)
        boxes += (humans.results ?? []).map(\.boundingBox)
        boxes += (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        let target = CGPoint(x: point.x, y: 1 - point.y)
        func distance(_ box: CGRect) -> CGFloat {
            let dx = max(box.minX - target.x, 0, target.x - box.maxX)
            let dy = max(box.minY - target.y, 0, target.y - box.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        // Inside a box beats near one; among those, the smallest is the most specific.
        let near = boxes.filter { distance($0) < 0.18 && $0.width < 0.9 && $0.height < 0.9 }
            .min { (distance($0), $0.width * $0.height) < (distance($1), $1.width * $1.height) }
        let side: CGFloat = 0.14
        let box = near ?? CGRect(x: target.x - side / 2, y: target.y - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return Start(box: box, pointOffset: PSPoint(x: point.x - Double(box.midX), y: point.y - Double(1 - box.midY)))
    }

    /// The tracked box in the next frame, nil once the subject is lost.
    mutating func advance(on image: CGImage) -> CGRect? {
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        do {
            try handler.perform([request], on: image)
        } catch {
            return nil
        }
        guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.3 else { return nil }
        observation = result
        return result.boundingBox
    }
}

// MARK: - Decoding

/// Decodes sound to mono Float PCM for the analysers.
public enum AudioDecoder {
    static func settings(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// The first audio track of an asset over a range.
    public static func decode(asset: AVAsset, range: TimeSpan, sampleRate: Double) async throws -> AudioSignal {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return AudioSignal(samples: [], sampleRate: sampleRate) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = VideoTime.range(range)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings(sampleRate: sampleRate))
        output.alwaysCopiesSampleData = false
        reader.add(output)
        return try read(reader: reader, output: output, sampleRate: sampleRate)
    }

    /// The timeline's mixed sound (with its volumes, fades and speed changes), on the timeline clock.
    public static func timelineSound(_ timeline: VideoTimeline, builder: CompositionBuilder, sampleRate: Double) async throws -> AudioSignal {
        let built = try await builder.build(timeline)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return AudioSignal(samples: [Float](repeating: 0, count: Int(timeline.duration * sampleRate)), sampleRate: sampleRate) }
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings(sampleRate: sampleRate))
        output.audioMix = built.audioMix
        output.alwaysCopiesSampleData = false
        reader.add(output)
        return try read(reader: reader, output: output, sampleRate: sampleRate)
    }

    static func read(reader: AVAssetReader, output: AVAssetReaderOutput, sampleRate: Double) throws -> AudioSignal {
        guard reader.startReading() else { throw reader.error ?? PicshopError.renderFailed("audio reader") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base.advanced(by: start * MemoryLayout<Float>.size))
            }
        }
        if reader.status == .failed { throw reader.error ?? PicshopError.renderFailed("audio reader") }
        return AudioSignal(samples: samples, sampleRate: sampleRate)
    }

    /// Mono Float PCM as an `AVAudioPCMBuffer`, for the speech recognisers.
    static func buffer(_ signal: AudioSignal, range: Range<Int>) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: signal.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        signal.samples.withUnsafeBufferPointer { source in
            for (offset, index) in range.enumerated() { channel[offset] = source[index] }
        }
        buffer.frameLength = AVAudioFrameCount(range.count)
        return buffer
    }
}

// MARK: - Speech

/// On-device speech to timed words.
enum SpeechCaptioner {
    static func words(in signal: AudioSignal, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionWord] {
        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *), await AnalyzerCaptioner.isSupported(locale: locale) {
            do {
                let words = try await AnalyzerCaptioner.words(in: signal, locale: locale, progress: progress)
                if !words.isEmpty { return words }
            } catch {
                PSLog.error("SpeechAnalyzer captions failed: \(error)", category: .video)
            }
        }
        return try await LegacyCaptioner.words(in: signal, locale: locale, progress: progress)
        #else
        throw PicshopError.unsupportedOperation("Captions")
        #endif
    }

    /// Joins recogniser tokens into words: a token that does not start with a
    /// space continues the previous word ("aujourd" + "'hui").
    static func merge(_ tokens: [(text: String, start: Double, end: Double)]) -> [CaptionWord] {
        var words: [CaptionWord] = []
        for token in tokens {
            let startsWord = token.text.first?.isWhitespace ?? true
            let pieces = token.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !pieces.isEmpty else { continue }
            if pieces.count == 1 {
                if !startsWord, let last = words.last, token.start - last.end < 0.15 {
                    words[words.count - 1] = CaptionWord(text: last.text + pieces[0], start: last.start, end: max(last.end, token.end))
                } else {
                    words.append(CaptionWord(text: pieces[0], start: token.start, end: token.end))
                }
            } else {
                words += CaptionBuilder.words(in: pieces.joined(separator: " "), span: TimeSpan(start: token.start, end: token.end))
            }
        }
        return words
    }
}

#if canImport(Speech)
@available(iOS 26.0, macOS 26.0, *)
enum AnalyzerCaptioner {
    static func isSupported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) || $0.language.languageCode == locale.language.languageCode }
    }

    static func words(in signal: AudioSignal, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionWord] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installation {
            try await installation.downloadAndInstall()
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () -> [(text: String, start: Double, end: Double)] in
            var tokens: [(text: String, start: Double, end: Double)] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    tokens.append((text, range.start.seconds, range.end.seconds))
                }
            }
            return tokens
        }
        try await analyzer.start(inputSequence: stream)
        // Feed the sound in one-second buffers in the analyser's own format.
        let chunk = Int(signal.sampleRate)
        var position = 0
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        while position < signal.samples.count {
            try Task.checkCancellation()
            let end = min(signal.samples.count, position + chunk)
            if let buffer = AudioDecoder.buffer(signal, range: position..<end) {
                continuation.yield(AnalyzerInput(buffer: convert(buffer, to: target) ?? buffer))
            }
            position = end
            progress(0.9 * Double(position) / Double(max(1, signal.samples.count)))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let tokens = try await collector.value
        return SpeechCaptioner.merge(tokens)
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format, format != buffer.format, let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }
}

/// `SFSpeechRecognizer` fallback: per-segment timings, on device when supported.
enum LegacyCaptioner {
    static func words(in signal: AudioSignal, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw PicshopError.speechUnavailable("no recogniser for \(locale.identifier)")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let words: [CaptionWord] = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let tokens = result.bestTranscription.segments.map { (text: " " + $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
                    if once.claim() { continuation.resume(returning: SpeechCaptioner.merge(tokens)) }
                } else if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            _ = task
            let chunk = Int(signal.sampleRate)
            var position = 0
            while position < signal.samples.count {
                let end = min(signal.samples.count, position + chunk)
                if let buffer = AudioDecoder.buffer(signal, range: position..<end) { request.append(buffer) }
                position = end
                progress(0.5 * Double(position) / Double(max(1, signal.samples.count)))
            }
            request.endAudio()
        }
        return words
    }
}

/// Resumes a continuation exactly once from callbacks that may fire twice.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif

// MARK: - Subject

/// Where the main subject of a frame is: faces first, then people, then
/// whatever draws the eye (attention saliency).
enum SubjectFinder {
    static func focus(in image: CGImage) -> (point: PSPoint, confidence: Double)? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, humans, saliency])

        func center(of rect: CGRect) -> PSPoint { PSPoint(x: Double(rect.midX), y: Double(1 - rect.midY)) }

        if let observations = faces.results, !observations.isEmpty {
            // Area-weighted centre of the faces: two people talking stay in frame together.
            let total = observations.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
            var x = 0.0, y = 0.0
            for face in observations {
                let weight = Double(face.boundingBox.width * face.boundingBox.height) / max(total, 1e-6)
                let c = center(of: face.boundingBox)
                x += c.x * weight
                y += c.y * weight
            }
            // Frame a little below the eyes, where a camera operator would.
            return (PSPoint(x: x, y: min(1, y + 0.06)), 1)
        }
        if let people = humans.results, let largest = people.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let box = largest.boundingBox
            // Upper third of the body: the head and shoulders.
            return (PSPoint(x: Double(box.midX), y: Double(1 - box.maxY + box.height * 0.3)), Double(largest.confidence))
        }
        if let salient = saliency.results?.first?.salientObjects, let main = salient.max(by: { $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height) < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height) }) {
            return (center(of: main.boundingBox), Double(main.confidence) * 0.7)
        }
        return nil
    }
}

// MARK: - Voice isolation

/// Offline voice isolation: Apple's sound-isolation audio unit when the
/// system has it (the "Voice Isolation" mic mode, as an effect), else a
/// dialogue chain — rumble filter, presence lift and a gentle expander.
enum VoiceIsolator {
    /// 'vois' — kAudioUnitSubType_AUSoundIsolation.
    static let soundIsolation = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766F_6973,
                                                          componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Returns the duration written.
    static func process(asset: AVAsset, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        // 1. The clip's sound as a file the engine can read.
        let duration = try await asset.load(.duration).seconds
        let signal = try await AudioDecoder.decode(asset: asset, range: TimeSpan(start: 0, duration: duration), sampleRate: 48_000)
        guard !signal.samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw PicshopError.mediaUnavailable("audio")
        }
        progress(0.1)

        // 2. The effect chain.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = []
        var isolationDescription = soundIsolation
        if AudioComponentFindNext(nil, &isolationDescription) != nil {
            let isolation = try await AVAudioUnit.instantiate(with: soundIsolation, options: [])
            engine.attach(isolation)
            chain.append(isolation)
        } else {
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            eq.bands[0].filterType = .highPass
            eq.bands[0].frequency = 90
            eq.bands[0].bypass = false
            eq.bands[1].filterType = .parametric
            eq.bands[1].frequency = 3_200
            eq.bands[1].bandwidth = 1.2
            eq.bands[1].gain = 3
            eq.bands[1].bypass = false
            eq.bands[2].filterType = .lowPass
            eq.bands[2].frequency = 12_000
            eq.bands[2].bypass = false
            engine.attach(eq)
            chain.append(eq)
            let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                                                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            engine.attach(dynamics)
            chain.append(dynamics)
        }
        var previous: AVAudioNode = player
        for node in chain {
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        guard let source = AudioDecoder.buffer(AudioSignal(samples: signal.samples, sampleRate: 48_000), range: 0..<signal.samples.count) else {
            throw PicshopError.renderFailed("voice buffer")
        }
        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        // 3. Render to a file, frame block by frame block.
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw PicshopError.renderFailed("render buffer")
        }
        let total = AVAudioFramePosition(signal.samples.count)
        while engine.manualRenderingSampleTime < total {
            try Task.checkCancellation()
            let remaining = total - engine.manualRenderingSampleTime
            let frames = min(AVAudioFrameCount(remaining), block.frameCapacity)
            let status = try engine.renderOffline(frames, to: block)
            switch status {
            case .success: try file.write(from: block)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext: continue
            case .error: throw PicshopError.renderFailed("voice render")
            @unknown default: throw PicshopError.renderFailed("voice render")
            }
            progress(0.1 + 0.9 * Double(engine.manualRenderingSampleTime) / Double(total))
        }
        player.stop()
        engine.stop()
        return Double(total) / 48_000
    }
}
#endif
