#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore

/// D16a: the pixel feed for Core's `PSDWriter`. The structure comes from the document (bottom → top, groups as section
/// dividers, D16c), the pixels from the renderer at the export's resolution:
/// - image, text, shape, fill and gradient layers are raster layers, placed and drawn at canvas resolution over their
///   bounds, without their mask, fill or opacity (those are the record's); a table bundle is one raster layer named
///   after it (« Tableau »);
/// - an adjustment layer is a raster layer « <nom> (aplati) » holding the stamp of everything below with the
///   adjustment applied, in normal mode with the layer's mask and opacity, so the composite matches in Photoshop as
///   long as nothing below changes;
/// - layer masks are user masks (−2) over the layer's bounds (the canvas for groups and adjustment layers), 0 outside;
/// - local adjustments are baked into their layer; clipping, fill, locks, visibility and names are the record's.
/// Rows are pulled strip by strip (512 rows) and turned straight on the CPU (c × max ÷ α, 0 where α = 0), 16-bit
/// samples big-endian (D14): Core Image's output colour matching never sees unpremultiplied values.
public enum PSDExport {
    /// D16b's names for bundles.
    static func bundleName(_ kind: LayerGroup.Kind) -> String {
        switch kind {
        case .tableCells: return "Tableau"
        case .tableHighlight: return "Surlignage"
        }
    }

    /// What the sheet and the toasts say for a refused PSD (D16a).
    public static func message(for error: PSDError, french: Bool) -> String {
        switch error {
        case .tooLarge: return french ? "Trop grand pour un PSD" : "Too large for a PSD"
        case .tooHeavy: return french ? "Trop lourd pour un PSD : réduis la taille ou passe en 8 bits" : "Too heavy for a PSD: lower the size or use 8 bits"
        case .io(let detail) where detail == "space":
            return french ? "Pas assez d'espace libre pour ce PSD" : "Not enough free space for this PSD"
        case .unsupportedDepth: return french ? "Cette profondeur n'est pas possible en PSD" : "This bit depth isn't available in PSD"
        case .badRow, .io: return french ? "L'export PSD a échoué" : "PSD export failed"
        }
    }

    /// D16a before anything renders: larger than 30,000 px (`.tooLarge`), an estimate above 2 GB (`.tooHeavy`), or a
    /// disk without 2.2 × the estimate free (`.io("space")`).
    static func checkBudget(_ document: PhotoDocument, width: Int, height: Int, depth: Int, layered: Bool) throws {
        guard max(width, height) <= PSDWriter.maxSide else { throw PSDError.tooLarge }
        let estimate = ExportBudget.psdBytesEstimate(width: width, height: height, depth: depth,
                                                     layerPixels: layered ? layerPixels(document, width: width, height: height) : width * height)
        guard estimate <= PSDWriter.maxBytes else { throw PSDError.tooHeavy }
        let temporary = FileManager.default.temporaryDirectory
        if let values = try? temporary.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, Double(available) < 2.2 * Double(estimate) {
            throw PSDError.io("space")
        }
    }

    /// An upper bound of the pixels the layers' records hold: each layer's placed bounds on the canvas (the whole
    /// canvas for fills, adjustment stamps and text, whose size is known only once drawn).
    static func layerPixels(_ document: PhotoDocument, width: Int, height: Int) -> Int {
        let canvas = PhotoExporter.canvasSize(of: document)
        let full = width * height
        var total = 0
        for layer in document.layers {
            switch layer.content {
            case .image(let asset):
                if layer.id == document.baseLayerID { total += full; continue }
                let content = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
                let box = LayerPlacement.bounds(for: layer, contentSize: content, canvasSize: canvas, isBase: false).intersection(.unit)
                total += Int((box.width * Double(width)).rounded(.up) * (box.height * Double(height)).rounded(.up))
            case .shape(let shape):
                let content = PSSize(width: shape.relativeSize.width * canvas.width, height: shape.relativeSize.height * canvas.height)
                let box = LayerPlacement.bounds(for: layer, contentSize: content, canvasSize: canvas, isBase: false).intersection(.unit)
                total += Int((box.width * Double(width)).rounded(.up) * (box.height * Double(height)).rounded(.up))
            case .text, .fill, .gradientFill, .adjustment:
                total += full
            case .group, .unsupported:
                break
            }
        }
        return total
    }

    /// The layered PSD at `url`: the renderer prepares every record's pixels at the export's resolution, Core's
    /// writer streams them into the file through `psd-<uuid>/` temporaries.
    static func write(_ document: PhotoDocument, renderer: PhotoRenderer, options: ExportOptions, renderOptions: PhotoRenderer.Options,
                      size: (width: Int, height: Int), to url: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let depth = options.effectiveBitDepth
        let colorSpace = options.colorSpace.cgColorSpace
        let plan = try await renderer.psdPlan(document, options: renderOptions, layered: options.layered)
        let canvas = plan.canvas
        let width = Int(canvas.width), height = Int(canvas.height)
        guard max(width, height) <= PSDWriter.maxSide else { throw PSDError.tooLarge }
        try Task.checkCancellation()
        var records: [PSDLayer] = []
        for (index, entry) in plan.layers.enumerated() {
            let rect = Self.psdRect(entry.rect, canvasHeight: canvas.height)
            let pixels: (any PSDRowSource)? = entry.image.flatMap { image in
                rect.width > 0 && rect.height > 0 ? CIRowSource(image: image, rect: entry.rect, channels: 4, depth: depth, colorSpace: colorSpace) : nil
            }
            var mask: PSDLayerMask?
            if let maskImage = entry.mask, !entry.maskRect.isEmpty {
                mask = PSDLayerMask(rect: Self.psdRect(entry.maskRect, canvasHeight: canvas.height), defaultColor: 0, disabled: entry.maskDisabled,
                                    rows: CIRowSource(image: maskImage, rect: entry.maskRect, channels: 1, depth: depth, colorSpace: RenderContext.maskColorSpace))
            }
            records.append(PSDLayer(kind: entry.kind, name: entry.name, rect: pixels == nil ? .empty : rect, blendKey: entry.blendKey,
                                    opacity: Self.byte(entry.opacity), fillOpacity: Self.byte(entry.fillOpacity), clipped: entry.clipped,
                                    visible: entry.visible, lockFlags: entry.lockFlags, layerID: UInt32(index + 1), pixels: pixels, mask: mask))
        }
        let composite = CIRowSource(image: plan.composite, rect: canvas, channels: 4, depth: depth, colorSpace: colorSpace)
        let spec = PSDDocumentSpec(width: width, height: height, depth: depth, resolution: options.resolution ?? 300,
                                   iccProfile: colorSpace.copyICCData() as Data?, layers: records, composite: composite)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("psd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PSDWriter.write(spec, to: url, temporaryDirectory: temporary, progress: { progress?($0) })
    }

    /// A Core Image rect (y up) as PSD's (top-down rows).
    static func psdRect(_ rect: CGRect, canvasHeight: CGFloat) -> PSDRect {
        guard !rect.isEmpty, !rect.isNull else { return .empty }
        return PSDRect(top: Int32((canvasHeight - rect.maxY).rounded()), left: Int32(rect.minX.rounded()),
                       bottom: Int32((canvasHeight - rect.minY).rounded()), right: Int32(rect.maxX.rounded()))
    }

    static func byte(_ value: Double) -> UInt8 {
        UInt8(clamping: Int((value.clamped(to: 0...1) * 255).rounded()))
    }

    /// PSD's lock flags (`lspf`): bit 0 transparency, bit 1 pixels, bit 2 position, bit 31 all.
    static func lockFlags(_ lock: LayerLockOptions) -> UInt32 {
        var flags: UInt32 = 0
        if lock.contains(.transparency) { flags |= 1 }
        if lock.contains(.pixels) { flags |= 2 }
        if lock.contains(.position) { flags |= 4 }
        if lock.contains(.all) { flags |= 0x8000_0000 }
        return flags
    }
}

/// One record the renderer prepared: its structure and its pixels on the canvas (Core Image coordinates).
struct PSDLayerSource {
    var kind: PSDLayer.Kind
    var name: String
    var rect: CGRect
    var blendKey: String
    var opacity: Double
    var fillOpacity: Double
    var clipped: Bool
    var visible: Bool
    var lockFlags: UInt32
    /// Linear, premultiplied, on the canvas; nil for markers and empty layers.
    var image: CIImage?
    /// Gray, raw values, on the canvas.
    var mask: CIImage?
    var maskRect: CGRect
    var maskDisabled: Bool
}

/// Rows of a Core Image picture over a rect for the PSD writer, rendered strip by strip on the export context: RGBA
/// (straight colour, D14) or one gray channel (masks, raw values), 8 bits, or 16 bits big-endian.
final class CIRowSource: PSDRowSource {
    let channels: Int
    let image: CIImage
    let rect: CGRect
    let width: Int
    let height: Int
    let depth: Int
    let colorSpace: CGColorSpace
    let context: CIContext
    let rowsPerStrip: Int
    private var strip: [UInt8] = []
    private var stripTop = -1
    private var stripRows = 0

    init(image: CIImage, rect: CGRect, channels: Int, depth: Int, colorSpace: CGColorSpace, rowsPerStrip: Int = ExportBudget.stripRows,
         context: CIContext = RenderContext.export) {
        let bounds = rect.integral
        self.image = image
        self.rect = bounds
        width = max(0, Int(bounds.width))
        height = max(0, Int(bounds.height))
        self.channels = channels == 1 ? 1 : 4
        self.depth = depth == 16 ? 16 : 8
        self.colorSpace = colorSpace
        self.context = context
        self.rowsPerStrip = max(1, rowsPerStrip)
    }

    var rowBytes: Int { width * channels * (depth / 8) }

    func row(_ y: Int) throws -> [UInt8] {
        guard y >= 0, y < height else { throw PSDError.badRow("row \(y) of \(height)") }
        if stripTop < 0 || y < stripTop || y >= stripTop + stripRows {
            try load(top: y - y % rowsPerStrip)
        }
        let start = (y - stripTop) * rowBytes
        return Array(strip[start..<(start + rowBytes)])
    }

    private func load(top: Int) throws {
        if Task.isCancelled { throw CancellationError() }
        let count = min(rowsPerStrip, height - top)
        let signpost = PSSignpost.begin("export.strip", "psd rows \(top)…\(top + count - 1)")
        defer { PSSignpost.end(signpost) }
        let bounds = CGRect(x: rect.minX, y: rect.maxY - CGFloat(top + count), width: CGFloat(width), height: CGFloat(count))
        let format: CIFormat = channels == 4 ? (depth == 16 ? .RGBA16 : .RGBA8) : (depth == 16 ? .L16 : .L8)
        guard let cg = context.createCGImage(image, from: bounds, format: format, colorSpace: colorSpace, deferred: false),
              let data = cg.dataProvider?.data as Data?, cg.width == width, cg.height == count else {
            throw PSDError.io("render")
        }
        let sourceRow = cg.bytesPerRow, tight = rowBytes
        guard data.count >= (count - 1) * sourceRow + tight else { throw PSDError.io("render layout") }
        let bigEndian = cg.bitmapInfo.contains(.byteOrder16Big)
        var rows = [UInt8](repeating: 0, count: tight * count)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for y in 0..<count {
                let input = y * sourceRow, output = y * tight
                if depth == 8 {
                    for x in 0..<(width * channels) { rows[output + x] = source[input + x] }
                    if channels == 4 { Self.unpremultiply8(&rows, from: output, pixels: width) }
                } else {
                    for x in 0..<(width * channels) {
                        let a = UInt16(source[input + x * 2]), b = UInt16(source[input + x * 2 + 1])
                        let value = bigEndian ? (a << 8 | b) : (b << 8 | a)
                        Self.store16(value, into: &rows, at: output + x * 2)
                    }
                    if channels == 4 { Self.unpremultiply16(&rows, from: output, pixels: width) }
                }
            }
        }
        strip = rows
        stripTop = top
        stripRows = count
    }

    /// Straight colour from premultiplied 8-bit RGBA: c × 255 ÷ α, rounded; 0 where α = 0.
    static func unpremultiply8(_ rows: inout [UInt8], from offset: Int, pixels: Int) {
        for pixel in 0..<pixels {
            let i = offset + pixel * 4
            let alpha = Int(rows[i + 3])
            if alpha == 255 { continue }
            if alpha == 0 {
                rows[i] = 0; rows[i + 1] = 0; rows[i + 2] = 0
                continue
            }
            for c in 0..<3 { rows[i + c] = UInt8(min(255, (Int(rows[i + c]) * 255 + alpha / 2) / alpha)) }
        }
    }

    /// Straight colour from premultiplied 16-bit RGBA held big-endian: c × 65535 ÷ α, rounded; 0 where α = 0.
    static func unpremultiply16(_ rows: inout [UInt8], from offset: Int, pixels: Int) {
        for pixel in 0..<pixels {
            let i = offset + pixel * 8
            let alpha = Int(load16(rows, at: i + 6))
            if alpha == 65535 { continue }
            for c in 0..<3 {
                let value = alpha == 0 ? 0 : min(65535, (Int(load16(rows, at: i + c * 2)) * 65535 + alpha / 2) / alpha)
                store16(UInt16(value), into: &rows, at: i + c * 2)
            }
        }
    }

    static func load16(_ rows: [UInt8], at index: Int) -> UInt16 {
        UInt16(rows[index]) << 8 | UInt16(rows[index + 1])
    }

    static func store16(_ value: UInt16, into rows: inout [UInt8], at index: Int) {
        rows[index] = UInt8(value >> 8)
        rows[index + 1] = UInt8(value & 0xFF)
    }
}

// MARK: - The renderer's side

extension PhotoRenderer {
    /// What a PSD export draws: the canvas, the records bottom → top, and the merged composite.
    struct PSDPlan {
        var canvas: CGRect
        var layers: [PSDLayerSource]
        var composite: CIImage
    }

    /// The PSD's records with their pixels at `options`' resolution (an export pass), D16a. `layered: false` gives
    /// one raster layer holding the composite.
    func psdPlan(_ document: PhotoDocument, options: Options, layered: Bool) async throws -> PSDPlan {
        let composite = try await render(document, options: options)
        let canvas = CGRect(origin: .zero, size: composite.extent.integral.size)
        let merged = composite.transformed(by: CGAffineTransform(translationX: -composite.extent.minX, y: -composite.extent.minY)).cropped(to: canvas)
        guard layered else {
            let only = PSDLayerSource(kind: .pixels, name: document.title, rect: canvas, blendKey: PSDBlendKey.key(for: .normal), opacity: 1, fillOpacity: 1,
                                      clipped: false, visible: true, lockFlags: 0, image: merged, mask: nil, maskRect: .null, maskDisabled: false)
            return PSDPlan(canvas: canvas, layers: [only], composite: merged)
        }
        // Every layer's pixels without its masks, all drawn (hidden layers are written hidden).
        var bare = document
        bare.layers = document.layers.map { layer in
            var drawn = layer
            drawn.isVisible = true
            drawn.mask = nil
            drawn.maskStack = nil
            return drawn
        }
        let frame = try await prepareFrame(bare, options: options, log: nil, capture: nil)
        let mode: MaskRasterizer.Mode = .settled(target: nil)
        var records: [PSDLayerSource] = []
        // Groups whose closing divider is written and whose own record is not yet (outermost first).
        var openGroups: [UUID] = []
        var writtenBundles: Set<UUID> = []
        let bundleTops: [UUID: UUID] = Dictionary(document.bundles.compactMap { bundle in bundle.memberIDs.last.map { (bundle.id, $0) } },
                                                  uniquingKeysWith: { first, _ in first })

        for (index, layer) in document.layers.enumerated() {
            // A group's children start: its closing divider goes below them (D16c), outer groups' first.
            for group in ancestors(of: layer.id, in: document) where !openGroups.contains(group) {
                records.append(divider())
                openGroups.append(group)
            }
            switch layer.content {
            case .group(let folder):
                // An empty group gets its divider just below its record.
                if !openGroups.contains(layer.id) { records.append(divider()) }
                openGroups.removeAll { $0 == layer.id }
                let mask = psdMask(layer, contentExtent: nil, map: groupOwnMap(layer, canvasSize: frame.canvasSize), canvas: canvas, mode: mode)
                records.append(PSDLayerSource(kind: .groupOpen(collapsed: folder.isCollapsed), name: layer.name, rect: .null,
                                              blendKey: folder.passThrough ? PSDBlendKey.passThrough : PSDBlendKey.key(for: layer.blendMode),
                                              opacity: layer.opacity, fillOpacity: 1, clipped: false, visible: layer.isVisible,
                                              lockFlags: PSDExport.lockFlags(layer.ownLock), image: nil, mask: mask,
                                              maskRect: mask == nil ? .null : canvas, maskDisabled: !layer.isMaskEnabled))
            case .adjustment:
                let stamp = try await adjustmentStamp(document, index: index, options: options, canvas: canvas)
                let mask = psdMask(layer, contentExtent: nil, map: .identity, canvas: canvas, mode: mode)
                records.append(PSDLayerSource(kind: .pixels, name: "\(layer.name) (aplati)", rect: canvas, blendKey: PSDBlendKey.key(for: .normal),
                                              opacity: layer.opacity, fillOpacity: layer.fillOpacity, clipped: false, visible: layer.isVisible,
                                              lockFlags: PSDExport.lockFlags(layer.ownLock), image: stamp, mask: mask,
                                              maskRect: mask == nil ? .null : canvas, maskDisabled: !layer.isMaskEnabled))
            case .unsupported:
                continue
            case .image, .text, .shape, .fill, .gradientFill:
                if let bundle = layer.group {
                    // A table bundle is one raster layer, at its topmost member's place.
                    guard bundleTops[bundle.id] == layer.id, !writtenBundles.contains(bundle.id) else { continue }
                    writtenBundles.insert(bundle.id)
                    let members = Set(document.layers.filter { $0.group?.id == bundle.id }.map(\.id))
                    let image = try await isolatedRender(document, members: members, options: options, canvas: canvas)
                    let rect = members.compactMap { frame.pieces[$0].map { ContentPlacement.bounds($0.map, canvas: canvas) } }
                        .reduce(CGRect.null) { $0.union($1) }.intersection(canvas)
                    records.append(PSDLayerSource(kind: .pixels, name: PSDExport.bundleName(bundle.kind), rect: rect.isNull ? .null : rect,
                                                  blendKey: PSDBlendKey.key(for: layer.blendMode), opacity: layer.opacity, fillOpacity: layer.fillOpacity,
                                                  clipped: false, visible: layer.isVisible, lockFlags: PSDExport.lockFlags(layer.ownLock), image: image,
                                                  mask: nil, maskRect: .null, maskDisabled: false))
                    continue
                }
                let pieces = frame.pieces[layer.id]
                let image = pieces.flatMap { $0.placed(on: canvas) }
                var rect = CGRect.null
                if let pieces {
                    rect = layer.isFill || layer.id == document.baseLayerID ? canvas : ContentPlacement.bounds(pieces.map, canvas: canvas)
                }
                let mask = psdMask(layer, contentExtent: pieces?.content?.extent, map: pieces?.map ?? .identity, canvas: canvas, mode: mode)
                let clipped = layer.isClipped && document.clippingBase(of: layer.id) != nil
                records.append(PSDLayerSource(kind: .pixels, name: layer.name, rect: rect.isNull || rect.isEmpty ? .null : rect,
                                              blendKey: PSDBlendKey.key(for: layer.blendMode), opacity: layer.opacity, fillOpacity: layer.fillOpacity,
                                              clipped: clipped, visible: layer.isVisible, lockFlags: PSDExport.lockFlags(layer.ownLock),
                                              image: rect.isNull || rect.isEmpty ? nil : image, mask: mask,
                                              maskRect: mask == nil || rect.isNull ? .null : rect, maskDisabled: !layer.isMaskEnabled))
            }
        }
        return PSDPlan(canvas: canvas, layers: records, composite: merged)
    }

    /// The groups holding `id`, outermost first.
    private func ancestors(of id: UUID, in document: PhotoDocument) -> [UUID] {
        var chain: [UUID] = []
        var current = document.parent(of: id)
        while let group = current, !chain.contains(group.id), chain.count < document.layers.count {
            chain.insert(group.id, at: 0)
            current = document.parent(of: group.id)
        }
        return chain
    }

    private func divider() -> PSDLayerSource {
        PSDLayerSource(kind: .groupEnd, name: "</Layer group>", rect: .null, blendKey: PSDBlendKey.key(for: .normal), opacity: 1, fillOpacity: 1,
                       clipped: false, visible: true, lockFlags: 0, image: nil, mask: nil, maskRect: .null, maskDisabled: false)
    }

    private func groupOwnMap(_ group: Layer, canvasSize: PSSize) -> PSHomography {
        guard group.transform != .identity, group.isMaskLinked else { return .identity }
        return LayerPlacement.map(for: group, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
    }

    /// A layer's mask (legacy × stack, enabled or not) on the canvas: drawn in its content space and placed when linked
    /// (`contentExtent` nil: the canvas is its content space), in canvas space when not; nil without one.
    func psdMask(_ layer: Layer, contentExtent: CGRect?, map: PSHomography, canvas: CGRect, mode: MaskRasterizer.Mode) -> CIImage? {
        let hasStack = layer.maskStack.map { !$0.isEmpty } ?? false
        guard layer.mask != nil || hasStack else { return nil }
        let space = contentExtent ?? canvas
        var content: CIImage?
        if let legacy = layer.mask { content = loadMask(legacy, fitting: space) }
        var onCanvas: CIImage?
        if let stack = layer.maskStack, !stack.isEmpty {
            if layer.isMaskLinked || layer.isFill || contentExtent == nil {
                let drawn = rasterizer.mask(stack, extent: space, preLocal: nil, mode: mode, owner: layer.id)
                content = content.map { Self.multiply($0, drawn) } ?? drawn
            } else {
                onCanvas = rasterizer.mask(stack, extent: canvas, preLocal: nil, mode: mode, owner: layer.id)
            }
        }
        let placed = content.map { space == canvas && map == .identity ? $0.cropped(to: canvas) : ContentPlacement.placeMask($0, map: map, canvas: canvas) }
        switch (placed, onCanvas) {
        case let (a?, b?): return Self.multiply(a, b).cropped(to: canvas)
        case let (a?, nil): return a
        case let (nil, b?): return b.cropped(to: canvas)
        case (nil, nil): return nil
        }
    }

    /// Everything below the adjustment layer with it applied at full strength, without its mask (D16a's stamp).
    private func adjustmentStamp(_ document: PhotoDocument, index: Int, options: Options, canvas: CGRect) async throws -> CIImage {
        let adjustment = document.layers[index]
        let ancestors = Set([adjustment.parentID].compactMap { $0 })
        var stamp = document
        stamp.layers = document.layers.enumerated().map { position, layer in
            var drawn = layer
            if position == index {
                drawn.isVisible = true
                drawn.opacity = 1
                drawn.fillOpacity = 1
                drawn.blendMode = .normal
                drawn.mask = nil
                drawn.maskStack = nil
            } else if position > index, !ancestors.contains(layer.id) {
                drawn.isVisible = false
            }
            return drawn
        }
        let image = try await render(stamp, options: options)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).cropped(to: canvas)
    }

    /// `members` drawn together onto transparent (a table bundle), the base hidden unless it is one of them.
    private func isolatedRender(_ document: PhotoDocument, members: Set<UUID>, options: Options, canvas: CGRect) async throws -> CIImage {
        var alone = document
        alone.backgroundColor = .clear
        alone.layers = document.layers.compactMap { layer in
            if members.contains(layer.id) { return layer }
            guard layer.id == document.baseLayerID else { return nil }
            var hidden = layer
            hidden.isVisible = false
            return hidden
        }
        let image = try await render(alone, options: options)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).cropped(to: canvas)
    }
}
#endif
