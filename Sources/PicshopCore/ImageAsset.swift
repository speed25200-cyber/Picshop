import Foundation

/// A pixel source referenced by a layer or video clip.
public struct MediaAsset: Hashable, Codable, Sendable, Identifiable {
    public enum Origin: Hashable, Codable, Sendable {
        case photoLibrary(localIdentifier: String)
        case file
        case camera
        case generated
    }

    public enum Kind: String, Codable, Sendable {
        case image
        case video
        case audio
    }

    public var id: UUID
    public var kind: Kind
    /// Path relative to the project bundle (`media/<uuid>.<ext>`).
    public var relativePath: String
    public var pixelSize: PSSize
    /// Duration in seconds for time-based media, 0 for stills.
    public var duration: Double
    public var origin: Origin
    public var frameRate: Double

    public init(id: UUID = UUID(), kind: Kind, relativePath: String, pixelSize: PSSize, duration: Double = 0,
                origin: Origin = .file, frameRate: Double = 0) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.pixelSize = pixelSize
        self.duration = duration
        self.origin = origin
        self.frameRate = frameRate
    }

    public var fileExtension: String { (relativePath as NSString).pathExtension }
}
