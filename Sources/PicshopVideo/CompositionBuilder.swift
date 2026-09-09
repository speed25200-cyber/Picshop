#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import PicshopCore

/// Everything the compositor needs to draw one clip's frame.
public struct ClipRenderParameters: @unchecked Sendable {
    public var clipID: UUID
    public var trackID: CMPersistentTrackID
    public var naturalSize: CGSize
    public var preferredTransform: CGAffineTransform
    public var adjustments: Adjustments
    public var look: FilterPreset
    public var lookIntensity: Double
    public var crop: PSRect?
    public var rotation: Double
    public var flipHorizontal: Bool
    public var fill: Bool
}

public struct TransitionSegment: Sendable {
    public var kind: TransitionKind
    public var fromTrackID: CMPersistentTrackID
    public var toTrackID: CMPersistentTrackID
}

/// Custom instruction carrying the clip parameters for a time range.
public final class PicshopCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = false
    public let containsTweening: Bool = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let primary: ClipRenderParameters
    public let secondary: ClipRenderParameters?
    public let transition: TransitionSegment?
    public let overlays: [TimelineOverlay]
    public let backgroundColor: PSColor
    public let renderSize: CGSize

    init(timeRange: CMTimeRange, primary: ClipRenderParameters, secondary: ClipRenderParameters?, transition: TransitionSegment?, overlays: [TimelineOverlay], backgroundColor: PSColor, renderSize: CGSize) {
        self.timeRange = timeRange
        self.primary = primary
        self.secondary = secondary
        self.transition = transition
        self.overlays = overlays
        self.backgroundColor = backgroundColor
        self.renderSize = renderSize
        var ids: [NSValue] = [NSNumber(value: primary.trackID)]
        if let secondary { ids.append(NSNumber(value: secondary.trackID)) }
        requiredSourceTrackIDs = ids
        super.init()
    }
}

/// Result of building an AVFoundation composition for a timeline.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let duration: CMTime

    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum VideoTime {
    public static let timescale: CMTimeScale = 600

    public static func cm(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    public static func range(_ span: TimeSpan) -> CMTimeRange {
        CMTimeRange(start: cm(span.start), duration: cm(span.duration))
    }
}

/// Builds `AVMutableComposition` + `AVMutableVideoComposition` + `AVMutableAudioMix`
/// from a `VideoTimeline`. Clips alternate between two video tracks (A/B roll)
/// so transitions can overlap; the custom compositor draws each frame.
public struct CompositionBuilder: Sendable {
    public let store: ProjectStore
    public let projectID: UUID

    public init(store: ProjectStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    public func build(_ timeline: VideoTimeline) async throws -> BuiltComposition {
        let timer = PSTimer("composition.build")
        defer { timer.log(category: .video) }
        let composition = AVMutableComposition()
        guard !timeline.clips.isEmpty else { throw PicshopError.renderFailed("empty timeline") }

        let videoTracks = [
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
        ].compactMap { $0 }
        let audioTracks = [
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
        ].compactMap { $0 }
        guard videoTracks.count == 2, audioTracks.count == 2 else { throw PicshopError.renderFailed("composition tracks") }

        let renderSize = timeline.renderSize.cgSize
        let starts = timeline.clipStartTimes
        var parameters: [ClipRenderParameters] = []
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        // One parameters object per composition audio track (AVFoundation keys them by track id).
        var clipMixes: [AVMutableAudioMixInputParameters?] = [nil, nil]

        for (index, clip) in timeline.clips.enumerated() {
            let asset = AVURLAsset(url: store.url(for: clip.renderAsset.relativePath, in: projectID), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideo = sourceVideoTracks.first else { throw PicshopError.mediaUnavailable(clip.name) }
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let assetDuration = try await asset.load(.duration)

            let track = videoTracks[index % 2]
            let start = VideoTime.cm(starts[index])
            var sourceRange = VideoTime.range(clip.sourceRange)
            if CMTimeCompare(CMTimeAdd(sourceRange.start, sourceRange.duration), assetDuration) > 0 {
                sourceRange = CMTimeRange(start: sourceRange.start, duration: CMTimeSubtract(assetDuration, sourceRange.start))
            }
            try track.insertTimeRange(sourceRange, of: sourceVideo, at: start)
            if clip.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: start, duration: sourceRange.duration), toDuration: VideoTime.cm(clip.timelineDuration))
            }

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first, !clip.isMuted, clip.volume > 0 {
                let audioTrack = audioTracks[index % 2]
                try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: start)
                if clip.speed != 1 {
                    audioTrack.scaleTimeRange(CMTimeRange(start: start, duration: sourceRange.duration), toDuration: VideoTime.cm(clip.timelineDuration))
                }
                let mix = clipMixes[index % 2] ?? AVMutableAudioMixInputParameters(track: audioTrack)
                clipMixes[index % 2] = mix
                mix.setVolume(Float(clip.volume), at: start)
                let clipRange = CMTimeRange(start: start, duration: VideoTime.cm(clip.timelineDuration))
                if let transition = clip.transitionOut, transition.kind != .none, index < timeline.clips.count - 1 {
                    let fade = VideoTime.cm(min(transition.duration, clip.timelineDuration / 2))
                    mix.setVolumeRamp(fromStartVolume: Float(clip.volume), toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(clipRange.end, fade), duration: fade))
                }
                if index > 0, let transition = timeline.clips[index - 1].transitionOut, transition.kind != .none {
                    let fade = VideoTime.cm(min(transition.duration, clip.timelineDuration / 2))
                    mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.volume), timeRange: CMTimeRange(start: start, duration: fade))
                }
            }

            parameters.append(ClipRenderParameters(clipID: clip.id, trackID: track.trackID, naturalSize: naturalSize, preferredTransform: preferredTransform,
                                                   adjustments: clip.adjustments, look: clip.look, lookIntensity: clip.lookIntensity, crop: clip.crop,
                                                   rotation: clip.rotation, flipHorizontal: clip.flipHorizontal, fill: timeline.aspect != .original))
        }

        audioParameters.append(contentsOf: clipMixes.compactMap { $0 })

        // Music tracks.
        for music in timeline.audioTracks where !music.isMuted {
            let asset = AVURLAsset(url: store.url(for: music.asset.relativePath, in: projectID))
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let available = timeline.duration - music.timelineStart
            guard available > 0.1 else { continue }
            let range = VideoTime.range(TimeSpan(start: music.sourceRange.start, duration: min(music.sourceRange.duration, available)))
            try track.insertTimeRange(range, of: sourceAudio, at: VideoTime.cm(music.timelineStart))
            let mix = AVMutableAudioMixInputParameters(track: track)
            let start = VideoTime.cm(music.timelineStart)
            let duration = range.duration
            let hasClipAudio = timeline.clips.contains { !$0.isMuted && $0.volume > 0 }
            let level = Float(music.volume * (hasClipAudio ? (1 - music.ducking) : 1))
            mix.setVolume(0, at: start)
            if music.fadeIn > 0 {
                mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(start: start, duration: VideoTime.cm(music.fadeIn)))
            } else {
                mix.setVolume(level, at: start)
            }
            if music.fadeOut > 0 {
                let fadeStart = CMTimeSubtract(CMTimeAdd(start, duration), VideoTime.cm(music.fadeOut))
                mix.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart, duration: VideoTime.cm(music.fadeOut)))
            }
            audioParameters.append(mix)
        }

        // Instructions.
        var instructions: [PicshopCompositionInstruction] = []
        var cursor = 0.0
        for (index, clip) in timeline.clips.enumerated() {
            let start = starts[index]
            let end = start + clip.timelineDuration
            let nextTransition: (Transition, Double)? = {
                guard index < timeline.clips.count - 1, let transition = clip.transitionOut, transition.kind != .none else { return nil }
                let overlap = min(transition.duration, clip.timelineDuration / 2, timeline.clips[index + 1].timelineDuration / 2)
                return (transition, overlap)
            }()
            let soloEnd = nextTransition.map { end - $0.1 } ?? end
            if soloEnd > cursor + 0.0001 {
                instructions.append(PicshopCompositionInstruction(timeRange: VideoTime.range(TimeSpan(start: cursor, end: soloEnd)), primary: parameters[index], secondary: nil,
                                                                  transition: nil, overlays: timeline.overlays, backgroundColor: timeline.backgroundColor, renderSize: renderSize))
                cursor = soloEnd
            }
            if let (transition, overlap) = nextTransition {
                let segment = TransitionSegment(kind: transition.kind, fromTrackID: parameters[index].trackID, toTrackID: parameters[index + 1].trackID)
                instructions.append(PicshopCompositionInstruction(timeRange: VideoTime.range(TimeSpan(start: cursor, duration: overlap)), primary: parameters[index], secondary: parameters[index + 1],
                                                                  transition: segment, overlays: timeline.overlays, backgroundColor: timeline.backgroundColor, renderSize: renderSize))
                cursor += overlap
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = PicshopCompositor.self
        videoComposition.renderSize = renderSize
        let fps = timeline.frameRate > 0 ? timeline.frameRate : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        videoComposition.instructions = instructions
        if #available(iOS 17.0, *) {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        var audioMix: AVMutableAudioMix?
        if !audioParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParameters
            audioMix = mix
        }
        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix, duration: VideoTime.cm(timeline.duration))
    }
}
#endif
