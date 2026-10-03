#if canImport(AVFoundation) && canImport(Vision)
import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreMedia
import PicshopCore
import PicshopIntent
import PicshopImaging

/// AVFoundation + Vision implementation of the video AI services used by the
/// command executor: object removal across a clip, stabilisation, reversal,
/// portrait effects, freeze frames and frame extraction.
public final class AVVideoServices: VideoAIServices, @unchecked Sendable {
    let store: ProjectStore
    let projectID: UUID
    private let inpainting: InpaintingPipeline
    /// Language the captions are transcribed in (the editor's language).
    public var captionLocale: Locale = .current

    public init(store: ProjectStore, projectID: UUID, inpainting: InpaintingPipeline) {
        self.store = store
        self.projectID = projectID
        self.inpainting = inpainting
    }

    private var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    func asset(for clip: VideoClip) -> AVURLAsset {
        AVURLAsset(url: store.url(for: clip.renderAsset.relativePath, in: projectID), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    private func outputURL(prefix: String) throws -> URL {
        try store.createPackage(for: projectID)
        return store.mediaURL(for: projectID).appendingPathComponent("\(prefix)-\(UUID().uuidString).mov")
    }

    private func relative(_ asset: MediaAsset) -> MediaAsset {
        var copy = asset
        copy.relativePath = "\(Project.mediaDirectory)/\(asset.relativePath)"
        return copy
    }

    // MARK: - Grounding

    public func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate] {
        let span = timeline.span(of: clip.id) ?? TimeSpan(start: 0, duration: clip.timelineDuration)
        let sourceTime = clip.sourceTime(forClipOffset: time - span.start)
        let frame = try await VideoTranscoder.frame(of: asset(for: clip), at: sourceTime)
        let analysis = ImageSupport.resized(frame, to: PSSize(width: Double(frame.width), height: Double(frame.height)).limited(toLongestSide: 1280).cgSize) ?? frame
        return try VisionGrounding.candidates(in: analysis, for: target, maskStore: maskStore)
    }

    // MARK: - Object removal

    public func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let timer = PSTimer("video.removeObject")
        defer { timer.log(category: .video) }
        let asset = asset(for: clip)
        let range = clip.sourceRange
        let info = try await VideoTranscoder.sourceInfo(for: asset, range: range)

        // Seed: track each candidate's box through the clip (forward from the seed frame,
        // then backwards using random access for the frames before it).
        let seedTime = timeline.span(of: clip.id).map { max(0, min(clip.timelineDuration, $0.duration / 2)) } ?? 0
        let seedSource = clip.sourceTime(forClipOffset: seedTime)
        let tracks = try await trackBoxes(asset: asset, info: info, range: range, seedSourceTime: seedSource, seeds: candidates.map(\.boundingBox)) { fraction in
            progress(fraction * 0.35)
        }

        let output = try outputURL(prefix: "erase")
        let pipeline = inpainting
        let maskStore = self.maskStore
        var previousFill: (image: CIImage, box: PSRect)?
        let frameCount = max(1, tracks.count)
        let result = try await VideoTranscoder.process(asset: asset, configuration: .init(outputURL: output, sourceRange: range), progress: { fraction in
            progress(0.35 + fraction * 0.65)
        }) { frame in
            let boxes = tracks[min(frame.index, frameCount - 1)]
            guard !boxes.isEmpty else { return frame.image }
            let extent = frame.image.extent
            let width = Int(extent.width), height = Int(extent.height)
            // Build the hole: instance masks overlapping the tracked boxes when available, else the boxes themselves.
            let analysisSize = PSSize(width: Double(width), height: Double(height)).limited(toLongestSide: 960)
            var maskBytes: [UInt8]
            let aw = Int(analysisSize.width), ah = Int(analysisSize.height)
            if let cg = ImageSupport.cgImage(from: frame.image), let small = ImageSupport.resized(cg, to: analysisSize.cgSize) {
                var union: [[UInt8]] = []
                for box in boxes {
                    if let instance = try? VisionGrounding.instanceMaskBytes(in: small, overlapping: box, maskStore: maskStore) {
                        union.append(instance)
                    } else {
                        union.append(MaskStore.rectangleMask(box.insetBy(dx: -0.01, dy: -0.01).clampedToUnit(), width: aw, height: ah))
                    }
                }
                maskBytes = MaskStore.union(union)
            } else {
                maskBytes = MaskStore.union(boxes.map { MaskStore.rectangleMask($0, width: aw, height: ah) })
            }
            maskBytes = MaskStore.dilated(maskBytes, width: aw, height: ah, radius: max(2, aw / 150))
            guard let maskCG = ImageSupport.grayImage(width: aw, height: ah, bytes: maskBytes) else { return frame.image }
            var mask = CIImage(cgImage: maskCG)
            mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            let box = boxes.reduce(PSRect.zero) { $0.union($1) }
            var filled = try await pipeline.fill(image: frame.image, mask: mask, boundingBox: box, feather: 0.01)
            // Temporal smoothing: blend with the previous frame's fill inside the hole to reduce flicker.
            if let previous = previousFill, previous.box.iou(box) > 0.5 {
                let blended = AdjustmentPipeline.blend(previous.image, over: filled, alpha: 0.45)
                filled = AdjustmentPipeline.blendWithMask(foreground: blended, background: filled, mask: mask)
            }
            // Materialise so the carried-over image doesn't retain the whole frame chain.
            if let cg = ImageSupport.cgImage(from: filled, context: RenderContext.export) {
                previousFill = (CIImage(cgImage: cg), box)
            }
            return filled
        }
        return relative(result)
    }

    /// Returns, for every frame in the range, the tracked boxes (normalised, top-left origin).
    private func trackBoxes(asset: AVURLAsset, info: VideoTranscoder.SourceInfo, range: TimeSpan, seedSourceTime: Double, seeds: [PSRect],
                            progress: @escaping @Sendable (Double) -> Void) async throws -> [[PSRect]] {
        let frameCount = max(1, info.frameCount)
        var boxes = [[PSRect]](repeating: seeds, count: frameCount)
        guard !seeds.isEmpty else { return boxes }
        let seedIndex = min(frameCount - 1, max(0, Int(((seedSourceTime - range.start) * info.frameRate).rounded())))

        // Forward pass with a sequential reader.
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return boxes }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = VideoTime.range(TimeSpan(start: range.start + Double(seedIndex) / info.frameRate, end: range.end))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { return boxes }
        var requests = seeds.map { seed -> VNTrackObjectRequest in
            let observation = VNDetectedObjectObservation(boundingBox: visionRect(seed))
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            return request
        }
        let sequence = VNSequenceRequestHandler()
        var index = seedIndex
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let oriented = orientation(for: info.transform)
            try? sequence.perform(requests, on: buffer, orientation: oriented)
            var current: [PSRect] = []
            for (i, request) in requests.enumerated() {
                if let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence > 0.15 {
                    request.inputObservation = observation
                    current.append(PSRect.fromVision(observation.boundingBox))
                } else {
                    current.append(boxes[max(0, index - 1)].indices.contains(i) ? boxes[max(0, index - 1)][i] : seeds[i])
                }
            }
            if index < frameCount { boxes[index] = current }
            index += 1
            progress(Double(index - seedIndex) / Double(max(1, frameCount - seedIndex)) * 0.6)
        }
        reader.cancelReading()

        // Backward pass via random access (short: only the frames before the seed).
        if seedIndex > 0 {
            requests = seeds.map { seed in
                let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect(seed)))
                request.trackingLevel = .accurate
                return request
            }
            let backward = VNSequenceRequestHandler()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
            for frameIndex in stride(from: seedIndex - 1, through: 0, by: -1) {
                try Task.checkCancellation()
                let time = range.start + Double(frameIndex) / info.frameRate
                let generated = try? await generator.image(at: VideoTime.cm(time))
                guard let image = generated?.image else { continue }
                try? backward.perform(requests, on: image)
                var current: [PSRect] = []
                for (i, request) in requests.enumerated() {
                    if let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence > 0.15 {
                        request.inputObservation = observation
                        current.append(PSRect.fromVision(observation.boundingBox))
                    } else {
                        current.append(boxes[frameIndex + 1].indices.contains(i) ? boxes[frameIndex + 1][i] : seeds[i])
                    }
                }
                boxes[frameIndex] = current
                progress(0.6 + Double(seedIndex - frameIndex) / Double(seedIndex) * 0.4)
            }
        }
        return boxes
    }

    private func visionRect(_ rect: PSRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    private func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0, transform.b == 1, transform.c == -1, transform.d == 0 { return .right }
        if transform.a == 0, transform.b == -1, transform.c == 1, transform.d == 0 { return .left }
        if transform.a == -1, transform.d == -1 { return .down }
        return .up
    }

    // MARK: - Stabilisation

    public func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let asset = asset(for: clip)
        let range = clip.sourceRange
        let info = try await VideoTranscoder.sourceInfo(for: asset, range: range)

        // Pass 1: estimate inter-frame translation with Vision registration.
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PicshopError.mediaUnavailable(clip.name) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = VideoTime.range(range)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw PicshopError.renderFailed("stabilize reader") }
        var previous: CVPixelBuffer?
        var motion: [CGPoint] = [.zero]
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
                let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
                try? handler.perform([request])
                let transform = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform ?? .identity
                motion.append(CGPoint(x: transform.tx, y: transform.ty))
            }
            previous = buffer
            progress(Double(motion.count) / Double(max(1, info.frameCount)) * 0.4)
        }
        reader.cancelReading()

        // Cumulative trajectory and a smoothed version of it.
        var trajectory: [CGPoint] = []
        var acc = CGPoint.zero
        for step in motion {
            acc = CGPoint(x: acc.x + step.x, y: acc.y + step.y)
            trajectory.append(acc)
        }
        let window = Int(info.frameRate.rounded())
        var smoothed: [CGPoint] = []
        for i in trajectory.indices {
            let lo = max(0, i - window), hi = min(trajectory.count - 1, i + window)
            var sum = CGPoint.zero
            for j in lo...hi { sum.x += trajectory[j].x; sum.y += trajectory[j].y }
            let n = CGFloat(hi - lo + 1)
            smoothed.append(CGPoint(x: sum.x / n, y: sum.y / n))
        }
        // Pass 2: apply corrections with a 6% zoom so borders never show.
        let zoom: CGFloat = 1.06
        let outputURL = try outputURL(prefix: "stabilized")
        let result = try await VideoTranscoder.process(asset: asset, configuration: .init(outputURL: outputURL, sourceRange: range), progress: { fraction in
            progress(0.4 + fraction * 0.6)
        }) { frame in
            let i = min(frame.index, trajectory.count - 1)
            guard i >= 0 else { return frame.image }
            let correction = CGPoint(x: smoothed[i].x - trajectory[i].x, y: smoothed[i].y - trajectory[i].y)
            let extent = frame.image.extent
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let transform = CGAffineTransform(translationX: center.x + correction.x, y: center.y - correction.y).scaledBy(x: zoom, y: zoom).translatedBy(x: -center.x, y: -center.y)
            return frame.image.transformed(by: transform).cropped(to: extent)
        }
        return relative(result)
    }

    // MARK: - Reverse

    /// Sample rate of a reversed clip's sound.
    static let reversedSampleRate: Double = 48_000
    /// Longest sound reversed in memory (16-bit stereo: 2.3 MB a minute); longer clips reverse silent.
    static let reversedAudioLimit: Double = 600

    public func reverse(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let asset = asset(for: clip)
        let range = clip.sourceRange
        let info = try await VideoTranscoder.sourceInfo(for: asset, range: range)
        let rate = FrameRate.exact(info.frameRate)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        let outputURL = try outputURL(prefix: "reversed")
        let width = Int(info.size.width.rounded(.down)) / 2 * 2
        let height = Int(info.size.height.rounded(.down)) / 2 * 2
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        // The sound played backwards too, so a reversed clip is never silent.
        let sound: ReversedSound? = range.duration <= Self.reversedAudioLimit
            ? try await ReversedSound.read(from: asset, range: range, sampleRate: Self.reversedSampleRate) : nil
        if let sound { writer.add(sound.input) }
        guard writer.startWriting() else { throw PicshopError.renderFailed("reverse writer") }
        writer.startSession(atSourceTime: .zero)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let count = max(1, Int((range.duration * rate).rounded()))
        var written = 0
        for i in 0..<count {
            try Task.checkCancellation()
            let sourceTime = range.end - Double(i + 1) / rate
            let generated = try? await generator.image(at: VideoTime.cm(max(range.start, sourceTime)))
            guard let cg = generated?.image else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            guard let pool = adaptor.pixelBufferPool else { throw PicshopError.renderFailed("pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let buffer else { continue }
            var image = CIImage(cgImage: cg)
            let scale = min(canvas.width / image.extent.width, canvas.height / image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            RenderContext.export.render(image.cropped(to: canvas), to: buffer, bounds: canvas, colorSpace: RenderContext.colorSpace)
            adaptor.append(buffer, withPresentationTime: VideoTime.frameTime(i, fps: info.frameRate))
            written = i + 1
            // Sound is written just ahead of the pictures: the writer interleaves the two.
            try await sound?.feed(until: Double(i + 1) / rate + 0.5)
            progress(Double(i + 1) / Double(count))
        }
        input.markAsFinished()
        try await sound?.feed(until: .infinity)
        sound?.input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw PicshopError.renderFailed(writer.error?.localizedDescription ?? "reverse") }
        return relative(MediaAsset(kind: .video, relativePath: outputURL.lastPathComponent, pixelSize: PSSize(width: Double(width), height: Double(height)),
                                   duration: Double(max(1, written)) / rate, origin: .generated, frameRate: info.frameRate))
    }

    // MARK: - Horizon

    /// How tilted the horizon is in the clip's frame at a timeline second (Vision's
    /// angle in degrees, counter-clockwise positive); nil when none is found.
    public func horizonAngle(at time: Double, timeline: VideoTimeline) async throws -> Double? {
        guard let clip = timeline.clip(at: time), let span = timeline.span(of: clip.id) else { return nil }
        let frame = try await VideoTranscoder.frame(of: asset(for: clip), at: clip.sourceTime(forClipOffset: time - span.start))
        let request = VNDetectHorizonRequest()
        try VNImageRequestHandler(cgImage: frame, orientation: .up, options: [:]).perform([request])
        guard let observation = request.results?.first else { return nil }
        return Double(observation.angle) * 180 / .pi
    }

    // MARK: - Frames

    public func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        guard let clip = timeline.clip(at: time), let span = timeline.span(of: clip.id) else { throw PicshopError.renderFailed("no clip") }
        let sourceTime = clip.sourceTime(forClipOffset: time - span.start)
        let frame = try await VideoTranscoder.frame(of: asset(for: clip), at: sourceTime)
        var image = CIImage(cgImage: frame)
        let look: (preset: FilterPreset, intensity: Double)? = clip.look == .original ? nil : (clip.look, clip.lookIntensity)
        let adjustments = AdjustmentPipeline.effectiveAdjustments(manual: clip.adjustments, look: look)
        if !adjustments.isNeutral { image = AdjustmentPipeline.apply(adjustments, toneCurve: clip.look.toneCurve, to: image) }
        try store.createPackage(for: projectID)
        let url = store.mediaURL(for: projectID).appendingPathComponent("frame-\(UUID().uuidString).jpg")
        try ImageSupport.write(image, to: url, type: .jpeg, quality: 0.95)
        try await PhotoLibrary.save(imageAt: url)
        return MediaAsset(kind: .image, relativePath: "\(Project.mediaDirectory)/\(url.lastPathComponent)", pixelSize: PSSize(width: Double(frame.width), height: Double(frame.height)), origin: .generated)
    }

    public func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        guard let clip = timeline.clip(at: time), let span = timeline.span(of: clip.id) else { throw PicshopError.renderFailed("no clip") }
        let sourceTime = clip.sourceTime(forClipOffset: time - span.start)
        let frame = try await VideoTranscoder.frame(of: asset(for: clip), at: sourceTime)
        let url = try outputURL(prefix: "freeze")
        let asset = try await VideoTranscoder.writeStill(CIImage(cgImage: frame), duration: max(0.5, duration), frameRate: timeline.frameRate, to: url)
        return relative(asset)
    }

    // MARK: - Portrait / matte

    public func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let asset = asset(for: clip)
        let outputURL = try outputURL(prefix: "portrait")
        let maskStore = self.maskStore
        var previousMask: CIImage?
        let result = try await VideoTranscoder.process(asset: asset, configuration: .init(outputURL: outputURL, sourceRange: clip.sourceRange), progress: progress) { frame in
            let extent = frame.image.extent
            let analysisSize = PSSize(width: extent.width, height: extent.height).limited(toLongestSide: 720)
            guard let cg = ImageSupport.cgImage(from: frame.image), let small = ImageSupport.resized(cg, to: analysisSize.cgSize),
                  let bytes = try? VisionGrounding.subjectMaskBytes(in: small, maskStore: maskStore),
                  let maskCG = ImageSupport.grayImage(width: Int(analysisSize.width), height: Int(analysisSize.height), bytes: bytes) else {
                return frame.image
            }
            var mask = CIImage(cgImage: maskCG)
            mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            if let previousMask {
                mask = AdjustmentPipeline.blend(previousMask, over: mask, alpha: 0.3)
            }
            if let cg = ImageSupport.cgImage(from: mask, context: RenderContext.export) {
                previousMask = CIImage(cgImage: cg)
            }
            return BackgroundEffects.portraitBlur(frame.image, subjectMask: mask, amount: 0.7, scale: extent.width / 1920)
        }
        return relative(result)
    }
}

extension AVVideoServices: VideoHorizonDetecting {}

/// A clip's sound, played backwards: read once as 16-bit stereo PCM, reversed
/// frame by frame (channels stay in place), then handed to the writer in step
/// with the reversed pictures.
final class ReversedSound {
    let input: AVAssetWriterInput
    /// One element per stereo frame (two 16-bit samples).
    private var frames: [UInt32]
    private let format: CMAudioFormatDescription
    private let sampleRate: Double
    private var cursor = 0

    private init(frames: [UInt32], format: CMAudioFormatDescription, sampleRate: Double) {
        self.frames = frames
        self.format = format
        self.sampleRate = sampleRate
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                                                                      AVSampleRateKey: sampleRate, AVEncoderBitRateKey: 192_000])
        input.expectsMediaDataInRealTime = false
    }

    /// The sound of `range`, reversed; nil when the file has no sound.
    static func read(from asset: AVURLAsset, range: TimeSpan, sampleRate: Double) async throws -> ReversedSound? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = VideoTime.range(range)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        guard reader.startReading() else { throw PicshopError.renderFailed(reader.error?.localizedDescription ?? "sound reader") }
        var frames: [UInt32] = []
        frames.reserveCapacity(Int(range.duration * sampleRate) + 4096)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4
            guard count > 0 else { continue }
            var chunk = [UInt32](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { frames.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw PicshopError.renderFailed(reader.error?.localizedDescription ?? "sound reader") }
        guard !frames.isEmpty else { return nil }
        frames.reverse()
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                                      mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        let created = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                                     magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard created == noErr, let format else { throw PicshopError.renderFailed("sound format") }
        return ReversedSound(frames: frames, format: format, sampleRate: sampleRate)
    }

    /// Writes the reversed sound up to `seconds` into the output.
    func feed(until seconds: Double) async throws {
        while cursor < frames.count, Double(cursor) / sampleRate < seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            let count = min(4096, frames.count - cursor)
            guard let buffer = sampleBuffer(start: cursor, count: count), input.append(buffer) else {
                throw PicshopError.renderFailed("reversed sound")
            }
            cursor += count
        }
    }

    /// `count` frames from `start`, stamped at their place in the output.
    private func sampleBuffer(start: Int, count: Int) -> CMSampleBuffer? {
        let bytes = count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = frames.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + start * 4, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                                          sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                                                          packetDescriptions: nil, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
#endif
