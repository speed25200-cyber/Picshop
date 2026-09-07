#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia
import PicshopCore
import PicshopImaging

/// Sequential frame processing: decodes a range of a source asset, hands each
/// frame to a transform, encodes the result (HEVC) and carries the audio over.
/// Used by object removal, stabilisation, portrait effects and reversal.
public enum VideoTranscoder {
    public struct Frame: @unchecked Sendable {
        public let index: Int
        public let time: CMTime
        public let image: CIImage
        public let pixelBuffer: CVPixelBuffer
    }

    public struct Configuration: Sendable {
        public var outputURL: URL
        public var sourceRange: TimeSpan
        public var includeAudio: Bool
        public var codec: AVVideoCodecType

        public init(outputURL: URL, sourceRange: TimeSpan, includeAudio: Bool = true, codec: AVVideoCodecType = .hevc) {
            self.outputURL = outputURL
            self.sourceRange = sourceRange
            self.includeAudio = includeAudio
            self.codec = codec
        }
    }

    public struct SourceInfo: Sendable {
        public let size: CGSize
        public let transform: CGAffineTransform
        public let frameRate: Double
        public let frameCount: Int
    }

    /// Loads geometry for a source, applying the preferred transform to the size.
    public static func sourceInfo(for asset: AVURLAsset, range: TimeSpan) async throws -> SourceInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PicshopError.mediaUnavailable(asset.url.lastPathComponent) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let oriented = natural.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let rate = fps > 0 ? fps : 30
        return SourceInfo(size: size, transform: transform, frameRate: rate, frameCount: Int((range.duration * rate).rounded()))
    }

    /// Processes frames in order. `transform` receives each oriented frame and returns the
    /// frame to write (same size). Returns the written asset descriptor.
    public static func process(asset: AVURLAsset, configuration: Configuration, progress: @escaping @Sendable (Double) -> Void,
                               transform: @escaping (Frame) async throws -> CIImage) async throws -> MediaAsset {
        let info = try await sourceInfo(for: asset, range: configuration.sourceRange)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw PicshopError.mediaUnavailable("video") }
        let audioTrack = configuration.includeAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        let range = VideoTime.range(configuration.sourceRange)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                        kCVPixelBufferMetalCompatibilityKey as String: true])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mov)
        let width = Int(info.size.width.rounded(.down)) / 2 * 2
        let height = Int(info.size.height.rounded(.down)) / 2 * 2
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: configuration.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, width * height * 8), AVVideoExpectedSourceFrameRateKey: Int(info.frameRate.rounded())],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44100, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw PicshopError.renderFailed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw PicshopError.renderFailed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let context = RenderContext.export
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var index = 0
        let total = max(1, info.frameCount)
        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentation = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), range.start)
            var image = CIImage(cvPixelBuffer: buffer).transformed(by: info.transform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let frame = Frame(index: index, time: presentation, image: image, pixelBuffer: buffer)
            var result = try await transform(frame)
            if result.extent.size != canvas.size {
                let scale = min(canvas.width / max(1, result.extent.width), canvas.height / max(1, result.extent.height))
                result = result.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                result = result.transformed(by: CGAffineTransform(translationX: canvas.midX - result.extent.midX, y: canvas.midY - result.extent.midY))
                result = result.composited(over: CIImage(color: .black).cropped(to: canvas))
            }
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let pool = adaptor.pixelBufferPool else { throw PicshopError.renderFailed("pixel buffer pool") }
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
            guard let output else { throw PicshopError.renderFailed("output buffer") }
            context.render(result.cropped(to: canvas), to: output, bounds: canvas, colorSpace: RenderContext.colorSpace)
            if !adaptor.append(output, withPresentationTime: presentation) {
                throw PicshopError.renderFailed(writer.error?.localizedDescription ?? "append frame")
            }
            index += 1
            progress(min(0.98, Double(index) / Double(total)))
        }
        videoInput.markAsFinished()

        if let audioOutput, let audioInput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(4))
                }
                let shifted = try retimed(sample, by: range.start)
                if !audioInput.append(shifted) { break }
            }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw PicshopError.renderFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        progress(1)
        let duration = Double(index) / info.frameRate
        return MediaAsset(kind: .video, relativePath: configuration.outputURL.lastPathComponent, pixelSize: PSSize(width: Double(width), height: Double(height)),
                          duration: duration, origin: .generated, frameRate: info.frameRate)
    }

    /// Shifts a sample buffer's timing so the written file starts at zero.
    static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset) }
        }
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &output)
        guard status == noErr, let output else { throw PicshopError.renderFailed("audio retime") }
        return output
    }

    /// Writes a video made of a single still image.
    public static func writeStill(_ image: CIImage, duration: Double, frameRate: Double, to url: URL) async throws -> MediaAsset {
        let width = Int(image.extent.width.rounded(.down)) / 2 * 2
        let height = Int(image.extent.height.rounded(.down)) / 2 * 2
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw PicshopError.renderFailed("still writer") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw PicshopError.renderFailed("pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { throw PicshopError.renderFailed("still buffer") }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        RenderContext.export.render(image.cropped(to: canvas), to: buffer, bounds: canvas, colorSpace: RenderContext.colorSpace)
        let frames = max(2, Int((duration * frameRate).rounded()))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(i)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return MediaAsset(kind: .video, relativePath: url.lastPathComponent, pixelSize: PSSize(width: Double(width), height: Double(height)), duration: duration, origin: .generated, frameRate: frameRate)
    }

    /// Random-access frame at a time (oriented).
    public static func frame(of asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let result = try await generator.image(at: VideoTime.cm(seconds))
        return result.image
    }
}
#endif
