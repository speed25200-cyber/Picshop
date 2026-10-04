import Foundation

// W3 export (D14, D15, D16): the file formats, the presets the LLM's exportPhoto encodes and the sheet decodes, and
// the memory estimate the model broker releases against. Core, so Intent (which cannot see Imaging's
// ExportOptions) and the Linux tests share them.

public enum ExportFileFormat: String, Codable, Sendable, CaseIterable {
    case jpeg, heic, png, tiff, pdf, psd

    /// D16: false for pdf and psd (Photos rejects them).
    public var canSaveToPhotos: Bool {
        switch self {
        case .jpeg, .heic, .png, .tiff: return true
        case .pdf, .psd: return false
        }
    }
}

/// D16 presets: the size rule of an export.
public enum ExportSizeRule: Hashable, Codable, Sendable {
    case full
    case longSide(Int)
    /// Instagram: 1080 px wide whatever the aspect.
    case width(Int)
}

/// The Core value the LLM's exportPhoto encodes (`.message("exportPreset:<json>")`), the sheet decodes and
/// ExportOptions.init(preset:) maps (Intent cannot see ExportOptions, which is Imaging and Apple-only). Codable keys
/// are the property names; every field but `format` decodes with its default.
public struct ExportPreset: Hashable, Codable, Sendable {
    public var format: ExportFileFormat
    public var bitDepth: Int
    /// "displayP3" | "sRGB".
    public var colorSpace: String
    public var size: ExportSizeRule
    public var quality: Double
    /// psd: layers kept.
    public var layered: Bool
    /// Instagram: false.
    public var keepsLocation: Bool
    /// ppi; print 300.
    public var resolution: Double?
    /// "instagram", "print", "web".
    public var name: String?

    public init(format: ExportFileFormat, bitDepth: Int = 8, colorSpace: String = "displayP3", size: ExportSizeRule = .full,
                quality: Double = 0.92, layered: Bool = true, keepsLocation: Bool = true, resolution: Double? = nil,
                name: String? = nil) {
        self.format = format
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.size = size
        self.quality = quality
        self.layered = layered
        self.keepsLocation = keepsLocation
        self.resolution = resolution
        self.name = name
    }

    /// JPEG q 0.9, sRGB, 1080 px wide, location removed.
    public static let instagram = ExportPreset(format: .jpeg, colorSpace: "sRGB", size: .width(1080), quality: 0.9, keepsLocation: false, name: "instagram")
    /// TIFF 8-bit (LZW), sRGB, full size, 300 ppi.
    public static let print = ExportPreset(format: .tiff, colorSpace: "sRGB", size: .full, resolution: 300, name: "print")
    /// JPEG q 0.85, sRGB, 2048 px on the long side.
    public static let web = ExportPreset(format: .jpeg, colorSpace: "sRGB", size: .longSide(2048), quality: 0.85, name: "web")

    /// The output pixel size for a canvas (instagram 4:5 → 1080 × 1350, 1:1 → 1080 × 1080, 9:16 → 1080 × 1920; web
    /// 2048 on the long side). The aspect is kept, sides are whole pixels (at least 1), and a rule never enlarges: a
    /// canvas already under the target comes out at its own size, because upscaling on export only adds blur.
    public func outputSize(canvas: PSSize) -> PSSize {
        guard canvas.width > 0, canvas.height > 0, canvas.width.isFinite, canvas.height.isFinite else { return canvas }
        let scale: Double
        switch size {
        case .full:
            scale = 1
        case .longSide(let side):
            scale = side > 0 ? min(1, Double(side) / max(canvas.width, canvas.height)) : 1
        case .width(let width):
            scale = width > 0 ? min(1, Double(width) / canvas.width) : 1
        }
        return PSSize(width: max(1, (canvas.width * scale).rounded()), height: max(1, (canvas.height * scale).rounded()))
    }

    private enum CodingKeys: String, CodingKey { case format, bitDepth, colorSpace, size, quality, layered, keepsLocation, resolution, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(ExportFileFormat.self, forKey: .format)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 8
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? "displayP3"
        size = try c.decodeIfPresent(ExportSizeRule.self, forKey: .size) ?? .full
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.92
        layered = try c.decodeIfPresent(Bool.self, forKey: .layered) ?? true
        keepsLocation = try c.decodeIfPresent(Bool.self, forKey: .keepsLocation) ?? true
        resolution = try c.decodeIfPresent(Double.self, forKey: .resolution)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

public enum ExportBudget {
    public static let stripRows = 512
    public static let streamingThresholdMegapixels = 24.0

    private static let mebibyte = 1_048_576
    /// The encoder's own working set beside the pixel rows: ImageIO's destination, the PNG/TIFF/JPEG codec state,
    /// the metadata and ICC copies, the PDF context. Measured W0 exports stay well under it.
    public static let encoderOverheadBytes = 8 * mebibyte

    /// Bytes per pixel of the rendered surface: RGBA8 up to 8 bits, RGBA16 (or half float, the same size) above.
    public static func bytesPerPixel(bitDepth: Int) -> Int { bitDepth > 8 ? 8 : 4 }

    /// Whether an export renders in strips (D14): 24 MP and up, any 16-bit export, any layered PSD. The caller adds
    /// its own conditions (the `tiledRendering` flag, a writer that cannot stream) and passes the result as
    /// `streaming` to `peakBytes`.
    public static func streams(width: Int, height: Int, bitDepth: Int, layered: Bool) -> Bool {
        let megapixels = Double(max(0, width)) * Double(max(0, height)) / 1_000_000
        return megapixels >= streamingThresholdMegapixels || bitDepth > 8 || layered
    }

    /// D15: peak bytes of one export (strip, encoder, full surface for 10-bit HEIC, the non-streaming fallback, plus
    /// `pinnedBytes`: the export's pinned expensive results and decoded sources, D14).
    ///
    /// - Streaming (JPEG, PNG, TIFF, PDF through `CGDataProvider(sequentialCallbacks:)`, and the PSD's strips): two
    ///   strips of `stripRows` rows (the one Core Image renders and the one the encoder pulls), plus the encoder.
    ///   48 MP 16-bit: 2 × 8000 × 512 × 8 B ≈ 66 MB + 8 MB.
    /// - Not streaming: one full bitmap at the export's depth plus the encoder (48 MP 16-bit ≈ 390 MB).
    /// - HEIC renders inside Core Image whatever `streaming` says: the full RGBA surface (8 bytes a pixel for 10-bit,
    ///   `writeHEIF10Representation`) plus the encoder's 4:2:0 frame (1.5 samples a pixel, 2 bytes each at 10-bit):
    ///   48 MP 10-bit ≈ 530 MB, which is what makes the broker release the LLM on a short phone (no format clause).
    /// - A layered PSD adds its row-count tables (2 bytes per row per channel per layer, kept until assembly) and,
    ///   without strips, one layer surface beside the composite.
    /// The estimate grows with every size, the depth and the layer count, and is an upper bound, not a measure.
    public static func peakBytes(format: ExportFileFormat, bitDepth: Int, width: Int, height: Int, layers: Int, streaming: Bool,
                                 pinnedBytes: Int = 0) -> Int {
        let w = Double(max(0, width))
        let h = Double(max(0, height))
        let depth = max(1, bitDepth)
        let bpp = Double(bytesPerPixel(bitDepth: depth))
        let fullSurface = w * h * bpp
        let strip = w * min(h, Double(stripRows)) * bpp
        var total: Double
        switch format {
        case .heic:
            let yuvBytesPerSample = depth > 8 ? 2.0 : 1.0
            total = fullSurface + w * h * 1.5 * yuvBytesPerSample
        case .jpeg, .png, .tiff, .pdf:
            total = streaming ? 2 * strip : fullSurface
        case .psd:
            let layerCount = Double(max(0, layers))
            let rowTables = h * 2 * 5 * (layerCount + 1)
            total = (streaming ? 2 * strip : 2 * fullSurface) + rowTables
        }
        total += Double(encoderOverheadBytes) + Double(max(0, pinnedBytes))
        return total >= Double(Int.max) ? Int.max : Int(total.rounded(.up))
    }

    /// D16a: an upper bound of a PSD's size: (composite + every layer's bounds) × channels × bytes × 1.02. The 2 %
    /// covers PackBits' worst case (one header byte per 128 literal bytes), the row-count tables and the headers.
    /// `layerPixels` is the sum of the layers' bounds areas in pixels.
    public static func psdBytesEstimate(width: Int, height: Int, depth: Int, layerPixels: Int) -> Int {
        let bytesPerSample = Double(max(1, depth / 8))
        let composite = Double(max(0, width)) * Double(max(0, height)) * 4 * bytesPerSample * 1.02
        let layers = Double(max(0, layerPixels)) * 4 * bytesPerSample * 1.02
        let total = composite + layers
        return total >= Double(Int.max) ? Int.max : Int(total.rounded(.up))
    }
}
