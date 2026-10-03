#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

/// The histogram of a picture, off the main thread: a ≤256 px proxy rendered on the
/// background context, read back as gamma-encoded Display P3 bytes and counted by
/// `Histogram.compute` (the same counting the Linux tests pin). The proxy samples the
/// picture's pixels (nearest, no averaging), so clipped highlights and crushed shadows
/// stay as they are instead of being smoothed into their neighbours.
public actor HistogramComputer {
    private let context: CIContext

    public init(context: CIContext = RenderContext.background) {
        self.context = context
    }

    public func histogram(of image: CIImage, maxSide: Int = 256) async -> Histogram? {
        Self.compute(image, maxSide: maxSide, context: context)
    }

    /// The histogram Auto Levels and the Curves and Levels graphs read: the active image layer
    /// before its Levels and curves (its tone table), on a small render that starts no heavy work.
    public func toneInputHistogram(of document: PhotoDocument, renderer: PhotoRenderer, maxSide: Int = 256) async -> Histogram? {
        let input = Self.toneInput(of: document)
        let options = PhotoRenderer.Options(targetLongestSide: Double(maxSide * 2), allowExpensiveWork: false)
        let image: CIImage
        do {
            image = document.activeImageLayerID == document.baseLayerID
                ? try await renderer.renderBase(input, options: options)
                : try await renderer.render(input, options: options)
        } catch {
            return nil
        }
        return Self.compute(image, maxSide: maxSide, context: context)
    }

    /// The document with the active image layer's tone table taken out (and its date fixed), so
    /// two inputs compare equal whenever only Levels or curves changed.
    public static func toneInput(of document: PhotoDocument) -> PhotoDocument {
        var input = document
        if let layerID = document.activeImageLayerID {
            input.update(layerID: layerID) { $0.edits = $0.edits.removingToneTable() }
        }
        input.modifiedAt = Date(timeIntervalSince1970: 0)
        return input
    }

    /// The work itself, synchronous: for callers already off the main thread (the services, tests).
    public static func compute(_ image: CIImage, maxSide: Int = 256, context: CIContext = RenderContext.background) -> Histogram? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width.isFinite, extent.height.isFinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, CGFloat(max(1, maxSide)) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        let proxy = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        guard let bytes = ImageSupport.rgbaBytes(of: proxy, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                 colorSpace: RenderContext.colorSpace, context: context) else { return nil }
        let histogram = Histogram.compute(premultipliedRGBA: bytes, width: width, height: height)
        return histogram.total > 0 ? histogram : nil
    }
}
#endif
