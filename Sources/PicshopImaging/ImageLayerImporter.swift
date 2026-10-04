#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicshopCore

/// Image layers from Photos (D17): the picked photo decoded once and written into the project's media.
public enum ImageLayerImporter {
    /// HEIC and JPEG quality of an imported photo.
    static let quality = 0.95

    /// Decodes (orientation applied), downsizes beyond `maxPixels`, writes media/<uuid>.<heic|png> (png when it has
    /// alpha; JPEG q 0.95 when the HEIC destination fails, e.g. no HEVC encoder, with the extension actually written),
    /// returns the asset (origin .photoLibrary when `localIdentifier` is given, else .file).
    public static func importImage(_ data: Data, store: ProjectStore, projectID: UUID, localIdentifier: String? = nil,
                                   maxPixels: Int = 50_000_000) throws -> MediaAsset {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw PicshopError.mediaUnavailable("photo")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { throw PicshopError.mediaUnavailable("photo") }
        // The longest side kept: the whole photo, or the side that brings it under `maxPixels`.
        let pixels = Double(width) * Double(height)
        let longest = Double(max(width, height))
        let limit = Double(max(1, maxPixels))
        let side = pixels > limit ? max(1, Int((longest * (limit / pixels).squareRoot()).rounded(.down))) : max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PicshopError.mediaUnavailable("photo")
        }
        try store.createPackage(for: projectID)
        let name = UUID().uuidString
        let path: String
        if hasAlpha(image) {
            path = "media/\(name).png"
            try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        } else if ExportWriters.canEncodeHEIC, (try? ImageSupport.write(image, to: store.url(for: "media/\(name).heic", in: projectID), type: .heic, quality: quality)) != nil {
            path = "media/\(name).heic"
        } else {
            // No HEVC encoder (virtualised runners): JPEG, with the extension it was written with.
            path = "media/\(name).jpg"
            try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .jpeg, quality: quality)
        }
        let origin: MediaAsset.Origin = localIdentifier.map { .photoLibrary(localIdentifier: $0) } ?? .file
        return MediaAsset(kind: .image, relativePath: path, pixelSize: PSSize(width: Double(image.width), height: Double(image.height)), origin: origin)
    }

    /// Whether the decoded picture carries alpha (a PNG cut-out, a sticker).
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
#endif
