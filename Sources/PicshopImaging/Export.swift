#if canImport(CoreImage) && canImport(Photos)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import ImageIO
import Photos
import UniformTypeIdentifiers
import PicshopCore

public struct ExportOptions: Sendable, Hashable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case jpeg, heic, png
        /// W3 (D16): TIFF 8/16-bit, a one-page PDF of the photo, a layered PSD.
        case tiff, pdf, psd
        public var id: String { rawValue }
        public var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .png: return .png
            case .tiff: return .tiff
            case .pdf: return .pdf
            case .psd: return UTType(filenameExtension: "psd") ?? .data
            }
        }
        public var displayName: String { rawValue.uppercased() }
    }

    /// The colour space written in the file: Display P3 (the iPhone's, wider) or
    /// sRGB (what the web and most other screens expect).
    public enum ColorSpaceChoice: String, CaseIterable, Sendable, Identifiable {
        case displayP3, sRGB
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .displayP3: return "Display P3"
            case .sRGB: return "sRGB"
            }
        }
        public var cgColorSpace: CGColorSpace {
            switch self {
            case .displayP3: return RenderContext.colorSpace
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            }
        }
    }

    public var format: Format
    public var quality: Double
    /// Longest side in pixels; nil keeps full resolution.
    public var maxLongestSide: Double?
    public var saveToPhotos: Bool
    public var colorSpace: ColorSpaceChoice
    /// Keeps where the photo was taken, in the file and in Photos ('Retirer la position' turns it off).
    public var keepsLocation: Bool
    /// A HEIC export of an HDR photo keeps its gain map, so it is as bright as the original.
    public var keepsHDR: Bool
    /// W3 (D16): 8, or 16 (PNG, TIFF, PSD) / 10 (HEIC); `Format.supportedBitDepths`.
    public var bitDepth: Int
    /// W3: a PSD keeps its layers (false: one flattened layer).
    public var layered: Bool
    /// W3: "instagram", "print", "web" when a preset made these options.
    public var presetName: String?
    /// W3: the preset's size rule; overrides `maxLongestSide` when set.
    public var size: ExportSizeRule?
    /// W3: ppi written in the file (print 300); nil keeps the default.
    public var resolution: Double?

    public init(format: Format = .heic, quality: Double = 0.92, maxLongestSide: Double? = nil, saveToPhotos: Bool = true,
                colorSpace: ColorSpaceChoice = .displayP3, keepsLocation: Bool = true, keepsHDR: Bool = true,
                bitDepth: Int = 8, layered: Bool = true, presetName: String? = nil, size: ExportSizeRule? = nil, resolution: Double? = nil) {
        self.format = format
        self.quality = quality
        self.maxLongestSide = maxLongestSide
        self.saveToPhotos = saveToPhotos
        self.colorSpace = colorSpace
        self.keepsLocation = keepsLocation
        self.keepsHDR = keepsHDR
        self.bitDepth = bitDepth
        self.layered = layered
        self.presetName = presetName
        self.size = size
        self.resolution = resolution
    }
}

extension ExportOptions.Format {
    /// Settings' default-format choices (the formats Photos takes).
    public static let defaultChoices: [ExportOptions.Format] = [.heic, .jpeg, .png, .tiff]

    /// jpeg [8], heic [8, 10], png [8, 16], tiff [8, 16], pdf [8], psd [8, 16].
    public var supportedBitDepths: [Int] {
        switch self {
        case .jpeg, .pdf: return [8]
        case .heic: return [8, 10]
        case .png, .tiff, .psd: return [8, 16]
        }
    }

    /// The Core value (ExportPreset, the broker estimate).
    public var fileFormat: ExportFileFormat {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        case .tiff: return .tiff
        case .pdf: return .pdf
        case .psd: return .psd
        }
    }

    /// "jpg", "heic", "png", "tif", "pdf", "psd".
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .png: return "png"
        case .tiff: return "tif"
        case .pdf: return "pdf"
        case .psd: return "psd"
        }
    }

    /// D16: false for pdf and psd (Photos rejects them); they go to Files or the share sheet.
    public var canSaveToPhotos: Bool { fileFormat.canSaveToPhotos }
}

extension ExportOptions {
    /// The options a Core preset asks for (the LLM's exportPhoto, the sheet's presets): format, depth (one the format
    /// writes, else 8), colour space, quality, size rule, layers, location, resolution and the preset's name.
    public init(preset: ExportPreset) {
        let format: Format
        switch preset.format {
        case .jpeg: format = .jpeg
        case .heic: format = .heic
        case .png: format = .png
        case .tiff: format = .tiff
        case .pdf: format = .pdf
        case .psd: format = .psd
        }
        let depth = format.supportedBitDepths.contains(preset.bitDepth) ? preset.bitDepth : 8
        self.init(format: format, quality: preset.quality, colorSpace: preset.colorSpace == "sRGB" ? .sRGB : .displayP3,
                  keepsLocation: preset.keepsLocation, bitDepth: depth, layered: preset.layered, presetName: preset.name,
                  size: preset.size, resolution: preset.resolution)
    }

    /// The bit depth actually written: the asked one when the format writes it, else 8.
    public var effectiveBitDepth: Int {
        format.supportedBitDepths.contains(bitDepth) ? bitDepth : 8
    }

    /// The output's pixel size for a canvas: the size rule when set (`full`, `longSide(n)` capping the long side,
    /// `width(n)` making it n wide whatever the aspect, D16), else `maxLongestSide` capping the long side, else the canvas.
    public func outputSize(canvas: PSSize) -> PSSize {
        guard canvas.width > 0, canvas.height > 0 else { return canvas }
        switch size {
        case .full?:
            return canvas
        case .longSide(let side)?:
            let longest = max(canvas.width, canvas.height)
            guard side > 0, Double(side) < longest else { return canvas }
            let factor = Double(side) / longest
            return PSSize(width: (canvas.width * factor).rounded(), height: (canvas.height * factor).rounded())
        case .width(let width)?:
            guard width > 0 else { return canvas }
            return PSSize(width: Double(width), height: (canvas.height * Double(width) / canvas.width).rounded())
        case nil:
            guard let cap = maxLongestSide, cap < max(canvas.width, canvas.height) else { return canvas }
            let factor = cap / max(canvas.width, canvas.height)
            return PSSize(width: (canvas.width * factor).rounded(), height: (canvas.height * factor).rounded())
        }
    }
}

/// Renders documents at full resolution and writes them to disk / Photos, with the
/// original's camera data, capture date and place, its HDR gain map when the
/// geometry allows, and an IPTC mark when on-device AI made part of the picture.
///
/// W3 (D14, D16): JPEG, HEIC 8 or 10 bits, PNG and TIFF 8 or 16 bits, a one-page PDF and a layered PSD. Outputs of
/// 24 MP or more, 16-bit and layered exports render in strips of 512 rows (the expensive results the export uses are
/// pinned and every source decoded once), so the bitmap is never whole in memory; the model broker is asked for room
/// first with the export's estimate. Only JPEG, HEIC and PDF are flattened on white; PNG, TIFF and PSD keep alpha.
/// PDF and PSD never go to Photos, whatever `saveToPhotos` says.
public enum PhotoExporter {
    /// - Parameter source: the original photo's file, whose metadata and gain map the export keeps.
    /// - Parameter progress: 0…1 as strips and layers are written; nil reports nothing.
    public static func export(_ document: PhotoDocument, renderer: PhotoRenderer, options: ExportOptions, source: URL? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let timer = PSTimer("export")
        defer { timer.log(category: .imaging) }
        let format = options.format
        let depth = options.effectiveBitDepth
        let canvas = canvasSize(of: document)
        let output = options.outputSize(canvas: canvas)
        let width = max(1, Int(output.width.rounded())), height = max(1, Int(output.height.rounded()))
        let megapixels = Double(width) * Double(height) / 1_000_000
        let layered = format == .psd && options.layered
        let streaming = megapixels >= ExportBudget.streamingThresholdMegapixels || depth > 8 || layered
        let fullResolution = fullResolutionMegapixels(document, options: options) != nil

        // D16a: a PSD too large or too heavy is refused before anything renders; so is one the disk cannot hold.
        if format == .psd {
            try PSDExport.checkBudget(document, width: width, height: height, depth: depth, layered: layered)
        }
        if fullResolution || streaming {
            // The model broker (W2 D12, W3 D15) unloads SAM and Depth, and the LLM when the estimate needs its memory,
            // before the full-size render needs it. Without a broker this does nothing.
            let pinned = pinnedEstimate(document, scale: renderScale(output: output, canvas: canvas))
            let peak = ExportBudget.peakBytes(format: format.fileFormat, bitDepth: depth, width: width, height: height,
                                              layers: document.layers.count, streaming: streaming, pinnedBytes: pinned)
            await ModelResidency.prepareForExport(megapixels: megapixels, peakBytes: peak)
        }
        try Task.checkCancellation()

        var renderOptions = PhotoRenderer.Options.full
        renderOptions.targetLongestSide = renderLongestSide(document, output: output, canvas: canvas)
        renderOptions.isExportPass = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = document.title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)")
        let metadata = source.map { PhotoMetadata.read(from: $0) } ?? PhotoMetadata()
        let colorSpace = options.colorSpace.cgColorSpace

        do {
            switch format {
            case .psd:
                try await PSDExport.write(document, renderer: renderer, options: options, renderOptions: renderOptions,
                                          size: (width, height), to: url, progress: progress)
            case .jpeg, .heic, .png, .tiff, .pdf:
                var image = try await renderer.render(document, options: renderOptions)
                image = fitted(image, width: width, height: height)
                // JPEG, HEIC and PDF flatten onto white; PNG, TIFF and PSD keep alpha (D14, D16).
                if format == .jpeg || format == .heic || format == .pdf {
                    let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
                    image = image.composited(over: background)
                }
                let generated = madeWithGenerativeAI(document)
                switch format {
                case .heic:
                    if depth == 10 {
                        let properties = metadata.properties(keepingLocation: options.keepsLocation, generated: generated, withGainMap: false)
                        try ExportWriters.writeHEIC10(image, to: url, quality: options.quality, colorSpace: colorSpace, properties: properties)
                    } else {
                        let gainMap: CIImage? = options.keepsHDR ? source.flatMap { GainMap.mapped(from: $0, through: document, onto: image.extent) } : nil
                        let properties = metadata.properties(keepingLocation: options.keepsLocation, generated: generated, withGainMap: gainMap != nil)
                        if let gainMap {
                            try ImageSupport.writeHEIC(image, gainMap: gainMap, to: url, quality: options.quality, colorSpace: colorSpace, properties: properties)
                        } else {
                            try ImageSupport.write(image, to: url, type: .heic, quality: options.quality, colorSpace: colorSpace, properties: properties)
                        }
                    }
                    progress?(1)
                case .pdf:
                    let strips = StripRenderer(image: image, bitsPerComponent: 8, colorSpace: colorSpace)
                    try PDFPhotoWriter.write(strips, to: url, title: document.title, progress: progress)
                case .jpeg, .png, .tiff:
                    let properties = metadata.properties(keepingLocation: options.keepsLocation, generated: generated, withGainMap: false)
                    let strips = StripRenderer(image: image, bitsPerComponent: depth, colorSpace: colorSpace)
                    try ExportWriters.writeStreamed(strips, to: url, type: format.utType, quality: format == .jpeg ? options.quality : nil,
                                                    resolution: options.resolution, properties: properties, progress: progress)
                case .psd:
                    break
                }
            }
        } catch {
            await renderer.endExportPass()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        await renderer.endExportPass()
        // Photos rejects PDF and PSD (D16): they go to Files or the share sheet, whatever saveToPhotos says.
        if options.saveToPhotos, format.canSaveToPhotos {
            try await PhotoLibrary.save(imageAt: url, creationDate: metadata.captureDate, location: options.keepsLocation ? metadata.location : nil)
        }
        return url
    }

    /// The document's canvas (the base's size when the canvas is not set).
    static func canvasSize(of document: PhotoDocument) -> PSSize {
        if document.canvasSize.width > 0, document.canvasSize.height > 0 { return document.canvasSize }
        return document.baseLayer?.imageAsset?.pixelSize ?? PSSize(width: 1, height: 1)
    }

    /// The output's scale to the canvas, at most 1 (larger outputs render full size and are resampled).
    static func renderScale(output: PSSize, canvas: PSSize) -> Double {
        guard canvas.width > 0 else { return 1 }
        return min(1, output.width / canvas.width)
    }

    /// The render's longest side for an output size: the renderer's scale is relative to the base's source.
    static func renderLongestSide(_ document: PhotoDocument, output: PSSize, canvas: PSSize) -> Double? {
        let scale = renderScale(output: output, canvas: canvas)
        guard scale < 0.999, let asset = document.baseLayer?.imageAsset else { return nil }
        return scale * max(asset.pixelSize.width, asset.pixelSize.height)
    }

    /// `image` at the origin, resampled to width × height when a size rule asks for another size (1080 px wide); a
    /// render within a pixel and a half of it is kept as drawn (rounding of the base's output), never resampled.
    static func fitted(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent.integral
        var placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if abs(extent.width - CGFloat(width)) <= 1.5, abs(extent.height - CGFloat(height)) <= 1.5 {
            return placed.cropped(to: CGRect(origin: .zero, size: extent.size))
        }
        if extent.width > 0, extent.height > 0 {
            let sx = CGFloat(width) / extent.width, sy = CGFloat(height) / extent.height
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = placed
            lanczos.scale = Float(sy)
            lanczos.aspectRatio = Float(sx / sy)
            placed = lanczos.outputImage ?? placed.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        return placed.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// D14 `pinnedBytes`, estimated before rendering: each image layer decoded once at the output's density, and one
    /// full result per expensive step it holds.
    static func pinnedEstimate(_ document: PhotoDocument, scale: Double) -> Int {
        document.layers.reduce(0) { total, layer in
            guard let asset = layer.imageAsset else { return total }
            let pixels = asset.pixelSize.width * asset.pixelSize.height * scale * scale
            let expensive = layer.edits.operations.filter { operation in
                switch operation.kind {
                case .removeObject, .generativeFill, .expand, .moveObject, .heal, .upscale: return true
                default: return false
                }
            }.count
            return total + Int(pixels) * 4 * (1 + expensive)
        }
    }

    /// The canvas in megapixels when this export renders at full size (no cap, or a cap above the canvas);
    /// nil for a capped export, which needs no room made for it.
    static func fullResolutionMegapixels(_ document: PhotoDocument, options: ExportOptions) -> Double? {
        let canvas = canvasSize(of: document)
        let output = options.outputSize(canvas: canvas)
        guard output.width >= canvas.width - 0.5 else { return nil }
        return Double(canvas.width) * Double(canvas.height) / 1_000_000
    }

    /// True when an on-device model drew part of the picture (fill, erase, move,
    /// extend, a generated background or layer): the export says so in IPTC.
    public static func madeWithGenerativeAI(_ document: PhotoDocument) -> Bool {
        document.layers.contains { layer in
            if layer.imageAsset?.origin == .generated { return true }
            return layer.edits.operations.contains { operation in
                switch operation.kind {
                case .generativeFill, .removeObject, .moveObject, .expand: return true
                case .replaceBackground(let background, _):
                    if case .image(let asset) = background { return asset.origin == .generated }
                    return false
                default: return false
                }
            }
        }
    }
}

/// What the original file says about itself: camera data, capture date and place.
public struct PhotoMetadata {
    public var exif: [CFString: Any] = [:]
    public var tiff: [CFString: Any] = [:]
    public var gps: [CFString: Any] = [:]
    public var iptc: [CFString: Any] = [:]
    /// Apple's maker note: it carries the HDR headroom an Apple gain map is read with.
    public var makerApple: [CFString: Any]?

    /// IPTC DigitalSourceType for a picture made partly by a trained model.
    public static let compositeWithTrainedAlgorithmicMedia = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"

    public init() {}

    public static func read(from url: URL) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return metadata }
        func block(_ key: CFString) -> [CFString: Any]? { properties[key] as? [CFString: Any] }
        metadata.exif = block(kCGImagePropertyExifDictionary) ?? [:]
        metadata.tiff = block(kCGImagePropertyTIFFDictionary) ?? [:]
        metadata.gps = block(kCGImagePropertyGPSDictionary) ?? [:]
        metadata.iptc = block(kCGImagePropertyIPTCDictionary) ?? [:]
        metadata.makerApple = block(kCGImagePropertyMakerAppleDictionary)
        return metadata
    }

    /// When the photo was taken: EXIF's original date in its own time zone when it says one.
    public var captureDate: Date? {
        let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String
        let saved = tiff[kCGImagePropertyTIFFDateTime] as? String
        guard let text = original ?? digitized ?? saved else { return nil }
        let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) ?? (exif[kCGImagePropertyExifOffsetTime] as? String)
        return Self.date(exif: text, offset: offset)
    }

    /// '2024:06:01 14:22:10' with an optional '+02:00'.
    public static func date(exif text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(offset:)) ?? .current
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func timeZone(offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard let hours = parts.first else { return nil }
        let seconds = (hours * 3600 + (parts.count > 1 ? parts[1] * 60 : 0)) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Where the photo was taken, from its GPS block.
    public var location: CLLocation? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        let coordinate = CLLocationCoordinate2D(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let altitude = gps[kCGImagePropertyGPSAltitude] as? Double
        let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
        let height = altitude.map { below ? -$0 : $0 } ?? 0
        let accuracy = (gps[kCGImagePropertyGPSHPositioningError] as? Double) ?? 0
        return CLLocation(coordinate: coordinate, altitude: height, horizontalAccuracy: accuracy,
                          verticalAccuracy: altitude == nil ? -1 : 0, timestamp: captureDate ?? Date())
    }

    /// The properties to write: the original's camera data upright (the pixels are
    /// written upright), its place unless removed, and the AI mark when it applies.
    public func properties(keepingLocation: Bool, generated: Bool, withGainMap: Bool) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        var tiff = self.tiff
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if !exif.isEmpty {
            var exif = self.exif
            // The edited picture has its own size; the original's would be wrong.
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if keepingLocation, !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        var iptc = self.iptc
        if generated { iptc[kCGImagePropertyIPTCExtDigitalSourceType] = Self.compositeWithTrainedAlgorithmicMedia }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        // The maker note goes with the gain map it describes, and only then.
        if withGainMap, let makerApple { properties[kCGImagePropertyMakerAppleDictionary] = makerApple }
        return properties
    }
}

/// The original's HDR gain map, carried onto the edited picture. Edits that keep the
/// geometry, crops, quarter turns and flips are followed; anything else (straighten,
/// perspective, extend) exports SDR, as before.
enum GainMap {
    static func mapped(from source: URL, through document: PhotoDocument, onto extent: CGRect) -> CIImage? {
        guard document.layers.filter(\.isImage).count == 1, let base = document.baseLayer,
              var map = CIImage(contentsOf: source, options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: true]) else { return nil }
        map = map.transformed(by: CGAffineTransform(translationX: -map.extent.minX, y: -map.extent.minY))
        for operation in base.edits.operations where operation.kind.isGeometric {
            switch operation.kind {
            case .crop(let rect):
                let cropRect = rect.ciRect(in: map.extent).integral.intersection(map.extent)
                guard !cropRect.isEmpty else { return nil }
                map = map.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            case .rotate(let degrees):
                let turns = degrees / 90
                guard abs(turns - turns.rounded()) < 0.001 else { return nil }
                let radians = -turns.rounded() * .pi / 2
                map = map.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
                map = map.transformed(by: CGAffineTransform(translationX: -map.extent.minX, y: -map.extent.minY))
            case .flip(let axis):
                let flipped = map.transformed(by: axis == .horizontal ? CGAffineTransform(scaleX: -1, y: 1) : CGAffineTransform(scaleX: 1, y: -1))
                map = flipped.transformed(by: CGAffineTransform(translationX: -flipped.extent.minX, y: -flipped.extent.minY))
            case .upscale:
                continue
            default:
                return nil
            }
        }
        guard map.extent.width > 0, map.extent.height > 0, extent.width > 0, extent.height > 0 else { return nil }
        // Same shape as the picture (within a pixel of rounding), at half its size like the camera's.
        let mapAspect = map.extent.width / map.extent.height, imageAspect = extent.width / extent.height
        guard abs(mapAspect - imageAspect) / imageAspect < 0.02 else { return nil }
        let scale = max(1, extent.width / 2) / map.extent.width
        let scaled = map.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: (extent.width / 2).rounded(), height: (extent.height / 2).rounded()))
    }
}

/// Thin wrapper over PhotoKit for saving results.
public enum PhotoLibrary {
    public static func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private final class Hook: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URL) -> Void)?
    }

    private static let hook = Hook()

    /// Tests: every save goes to `handler` instead of Photos (a counting fake); nil restores Photos.
    static func setSaveHandlerForTesting(_ handler: (@Sendable (URL) -> Void)?) {
        hook.lock.withLock { hook.handler = handler }
    }

    /// Saves a picture; it sorts in Photos by `creationDate` (the capture's, not today's)
    /// and shows on the map at `location` when given.
    public static func save(imageAt url: URL, creationDate: Date? = nil, location: CLLocation? = nil) async throws {
        if let handler = hook.lock.withLock({ hook.handler }) {
            handler(url)
            return
        }
        guard await requestAddAccess() else { throw PicshopError.permissionDenied("Photos") }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
            if let creationDate { request.creationDate = creationDate }
            if let location { request.location = location }
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
