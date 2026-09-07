#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore
import PicshopImaging

public struct VideoExportOptions: Sendable, Hashable {
    public enum Quality: String, CaseIterable, Sendable, Identifiable {
        case high, medium, low
        public var id: String { rawValue }
        public var preset: String {
            switch self {
            case .high: return AVAssetExportPresetHEVCHighestQuality
            case .medium: return AVAssetExportPreset1920x1080
            case .low: return AVAssetExportPreset1280x720
            }
        }
        public var displayName: String {
            switch self {
            case .high: return "Highest (HEVC)"
            case .medium: return "1080p"
            case .low: return "720p"
            }
        }
    }

    public var quality: Quality
    public var saveToPhotos: Bool

    public init(quality: Quality = .high, saveToPhotos: Bool = true) {
        self.quality = quality
        self.saveToPhotos = saveToPhotos
    }
}

/// Exports a timeline through `AVAssetExportSession`, reporting progress.
public enum VideoExporter {
    public static func export(_ timeline: VideoTimeline, store: ProjectStore, projectID: UUID, options: VideoExportOptions,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let timer = PSTimer("video.export")
        defer { timer.log(category: .video) }
        let built = try await CompositionBuilder(store: store, projectID: projectID).build(timeline)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: options.quality.preset) else {
            throw PicshopError.exportFailed("export session")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = timeline.title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mov)
        progress(1)
        if options.saveToPhotos {
            try await PhotoLibrary.save(videoAt: url)
        }
        return url
    }
}
#endif
