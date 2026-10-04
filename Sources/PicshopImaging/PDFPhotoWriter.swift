#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicshopCore

/// D16: a one-page PDF of the photo. The page is the picture's pixel size at 300 ppi in points (px × 72 / 300); the
/// picture is embedded as JPEG (quality 0.92), encoded in memory from the 8-bit strip renderer and drawn through
/// `CGImage(jpegDataProviderSource:…)`, so the PDF carries the JPEG stream as it is; title and creator « PicShop » in
/// the document info. Flattened on white before it gets here. PDFs go to Files or the share sheet, never Photos.
public enum PDFPhotoWriter {
    public static let pixelsPerInch = 300.0
    public static let jpegQuality = 0.92

    /// The page for a picture of width × height pixels, in points.
    public static func mediaBox(width: Int, height: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: Double(width) * 72 / pixelsPerInch, height: Double(height) * 72 / pixelsPerInch)
    }

    static func write(_ renderer: StripRenderer, to url: URL, title: String, progress: ((Double) -> Void)? = nil) throws {
        // The JPEG stream, in memory, from the strips.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PicshopError.exportFailed("PDF image")
        }
        let encoding: ((Double) -> Void)? = progress.map { report -> (Double) -> Void in { value in report(value * 0.9) } }
        try ExportWriters.addStreamed(renderer, to: destination, type: .jpeg, quality: jpegQuality, resolution: pixelsPerInch, properties: [:],
                                      progress: encoding)
        guard CGImageDestinationFinalize(destination) else {
            if Task.isCancelled { throw CancellationError() }
            throw PicshopError.exportFailed("PDF image")
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw PicshopError.exportFailed("PDF image")
        }
        var box = mediaBox(width: renderer.width, height: renderer.height)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "PicShop"]
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            throw PicshopError.exportFailed("cannot create \(url.lastPathComponent)")
        }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(jpeg, in: box)
        context.endPDFPage()
        context.closePDF()
        progress?(1)
    }
}
#endif
