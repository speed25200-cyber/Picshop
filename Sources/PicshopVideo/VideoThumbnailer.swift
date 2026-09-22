#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreGraphics
import PicshopCore
import PicshopImaging

/// Generates filmstrip thumbnails for clips on the timeline.
public actor VideoThumbnailer {
    private var cache: [String: CGImage] = [:]
    private let store: ProjectStore
    private let projectID: UUID

    public init(store: ProjectStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    /// Thumbnails at `count` evenly spaced source times within the clip range.
    public func thumbnails(for clip: VideoClip, count: Int, height: Int = 96) async -> [CGImage] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: store.url(for: clip.renderAsset.relativePath, in: projectID))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        var images: [CGImage] = []
        for index in 0..<count {
            let fraction = (Double(index) + 0.5) / Double(count)
            let time = clip.sourceRange.start + clip.sourceRange.duration * fraction
            let key = "\(clip.renderAsset.relativePath)@\(Int(time * 10))@\(height)"
            if let cached = cache[key] {
                images.append(cached)
                continue
            }
            let result = try? await generator.image(at: VideoTime.cm(time))
            if let image = result?.image {
                if cache.count > 400 { cache.removeAll() }
                cache[key] = image
                images.append(image)
            }
        }
        return images
    }

    private var envelopes: [String: [Float]] = [:]

    /// Peak level (0…1) of a media file's sound in `points` buckets across
    /// `range` (source seconds), for the waveforms drawn on the timeline.
    /// Decoded once per file at a low rate, then sliced.
    public func waveform(for media: MediaAsset, range: TimeSpan, points: Int) async -> [Float] {
        guard points > 0, range.duration > 0 else { return [] }
        let rate = 1_000.0
        let envelope: [Float]
        if let cached = envelopes[media.relativePath] {
            envelope = cached
        } else {
            let asset = AVURLAsset(url: store.url(for: media.relativePath, in: projectID))
            let length = (try? await asset.load(.duration).seconds) ?? media.duration
            guard let signal = try? await AudioDecoder.decode(asset: asset, range: TimeSpan(start: 0, duration: min(length, 1_800)), sampleRate: 8_000) else { return [] }
            // Peak per millisecond bucket.
            let step = max(1, Int(signal.sampleRate / rate))
            var peaks = [Float](repeating: 0, count: signal.samples.count / step + 1)
            signal.samples.withUnsafeBufferPointer { samples in
                for index in 0..<samples.count {
                    let bucket = index / step
                    let value = abs(samples[index])
                    if value > peaks[bucket] { peaks[bucket] = value }
                }
            }
            if envelopes.count > 24 { envelopes.removeAll() }
            envelopes[media.relativePath] = peaks
            envelope = peaks
        }
        guard !envelope.isEmpty else { return [] }
        let startIndex = Int(range.start * rate)
        let endIndex = min(envelope.count, Int(range.end * rate))
        guard endIndex > startIndex else { return [Float](repeating: 0, count: points) }
        let span = Double(endIndex - startIndex) / Double(points)
        var result = [Float](repeating: 0, count: points)
        var loudest: Float = 0.001
        for point in 0..<points {
            let from = startIndex + Int(Double(point) * span)
            let to = min(endIndex, max(from + 1, startIndex + Int(Double(point + 1) * span)))
            var peak: Float = 0
            for index in from..<to where envelope[index] > peak { peak = envelope[index] }
            result[point] = peak
            loudest = max(loudest, peak)
        }
        // Perceptual scale so quiet speech still shows.
        return result.map { sqrt(min(1, $0 / loudest)) }
    }

    /// Poster frame for the project library.
    public func poster(for timeline: VideoTimeline) async -> CGImage? {
        guard let clip = timeline.clips.first else { return nil }
        let asset = AVURLAsset(url: store.url(for: clip.renderAsset.relativePath, in: projectID))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        let result = try? await generator.image(at: VideoTime.cm(clip.sourceRange.start + min(1, clip.sourceRange.duration / 2)))
        return result?.image
    }

    /// Basic metadata for an imported video file.
    public static func metadata(for url: URL) async throws -> (size: PSSize, duration: Double, frameRate: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PicshopError.mediaUnavailable(url.lastPathComponent) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let oriented = natural.applying(transform)
        return (PSSize(width: abs(oriented.width), height: abs(oriented.height)), CMTimeGetSeconds(duration), Double(fps))
    }
}
#endif
