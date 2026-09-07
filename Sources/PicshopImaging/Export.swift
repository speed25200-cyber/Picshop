#if canImport(CoreImage) && canImport(Photos)
import Foundation
import CoreImage
import Photos
import UniformTypeIdentifiers
import PicshopCore

public struct ExportOptions: Sendable, Hashable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case jpeg, heic, png
        public var id: String { rawValue }
        public var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .png: return .png
            }
        }
        public var displayName: String { rawValue.uppercased() }
    }

    public var format: Format
    public var quality: Double
    /// Longest side in pixels; nil keeps full resolution.
    public var maxLongestSide: Double?
    public var saveToPhotos: Bool

    public init(format: Format = .heic, quality: Double = 0.92, maxLongestSide: Double? = nil, saveToPhotos: Bool = true) {
        self.format = format
        self.quality = quality
        self.maxLongestSide = maxLongestSide
        self.saveToPhotos = saveToPhotos
    }
}

/// Renders documents at full resolution and writes them to disk / Photos.
public enum PhotoExporter {
    public static func export(_ document: PhotoDocument, renderer: PhotoRenderer, options: ExportOptions) async throws -> URL {
        let timer = PSTimer("export")
        defer { timer.log(category: .imaging) }
        var renderOptions = PhotoRenderer.Options.full
        renderOptions.targetLongestSide = options.maxLongestSide
        var image = try await renderer.render(document, options: renderOptions)
        // Transparent PNGs keep alpha; other formats flatten onto black/white.
        if options.format != .png {
            let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
            image = image.composited(over: background)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = document.title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).\(options.format.rawValue)")
        try ImageSupport.write(image, to: url, type: options.format.utType, quality: options.quality)
        if options.saveToPhotos {
            try await PhotoLibrary.save(imageAt: url)
        }
        return url
    }
}

/// Thin wrapper over PhotoKit for saving results.
public enum PhotoLibrary {
    public static func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    public static func save(imageAt url: URL) async throws {
        guard await requestAddAccess() else { throw PicshopError.permissionDenied("Photos") }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    public static func save(videoAt url: URL) async throws {
        guard await requestAddAccess() else { throw PicshopError.permissionDenied("Photos") }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

/// Small preview images for the project library.
public enum ThumbnailGenerator {
    public static func writeThumbnail(for document: PhotoDocument, renderer: PhotoRenderer, store: ProjectStore) async {
        guard let image = try? await renderer.render(document, options: .thumbnail) else { return }
        let background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: image.extent)
        try? ImageSupport.write(image.composited(over: background), to: store.thumbnailURL(for: document.id), type: .jpeg, quality: 0.8)
    }

    public static func writeThumbnail(image: CGImage, projectID: UUID, store: ProjectStore) {
        let size = PSSize(width: Double(image.width), height: Double(image.height)).limited(toLongestSide: 512)
        guard let resized = ImageSupport.resized(image, to: size.cgSize) else { return }
        try? store.createPackage(for: projectID)
        try? ImageSupport.write(resized, to: store.thumbnailURL(for: projectID), type: .jpeg, quality: 0.8)
    }
}
#endif
