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
