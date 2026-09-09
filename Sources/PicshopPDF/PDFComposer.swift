#if canImport(PDFKit) && canImport(UIKit)
import Foundation
import PDFKit
import UIKit
import PicshopCore
import PicshopImaging

/// Builds a PDFKit document from a `PDFDocumentModel`: page order, rotation
/// and every markup as a real PDF annotation, so exports are standard PDFs.
public enum PDFComposer {
    /// Source documents keyed by asset relative path.
    public typealias SourceProvider = (MediaAsset) -> PDFDocument?

    public static func compose(_ model: PDFDocumentModel, original: PDFDocument, sources: SourceProvider, resolveImage: (MediaAsset) -> UIImage?) -> PDFDocument {
        let output = PDFDocument()
        for (position, pageModel) in model.pages.enumerated() {
            guard let page = makePage(pageModel, original: original, sources: sources, resolveImage: resolveImage) else { continue }
            page.rotation = ((page.rotation + pageModel.rotation) % 360 + 360) % 360
            let size = PSSize(page.bounds(for: .mediaBox).size)
            let paper = PaperPatcher(page: page)
            for markup in pageModel.markups {
                for annotation in annotations(for: markup, pageSize: size, resolveImage: resolveImage, paper: paper) {
                    page.addAnnotation(annotation)
                }
            }
            output.insert(page, at: position)
        }
        return output
    }

    static func makePage(_ model: PDFPageModel, original: PDFDocument, sources: SourceProvider, resolveImage: (MediaAsset) -> UIImage?) -> PDFPage? {
        switch model.source {
        case .original(let index):
            return (original.page(at: index)?.copy() as? PDFPage)
        case .imported(let asset, let index):
            return (sources(asset)?.page(at: index)?.copy() as? PDFPage)
        case .image(let asset):
            guard let image = resolveImage(asset) else { return nil }
            return PDFPage(image: image)
        case .blank(let size):
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: size.width, height: size.height), for: .mediaBox)
            return page
        }
    }

    // MARK: Annotations

    static func annotations(for markup: PDFMarkup, pageSize: PSSize, resolveImage: (MediaAsset) -> UIImage?, paper: PaperPatcher? = nil) -> [PDFAnnotation] {
        switch markup.kind {
        case .ink(let strokes, let color, let width):
            let paths: [UIBezierPath] = strokes.map { stroke in
                let path = UIBezierPath()
                let points = stroke.points.map { CGPoint(x: $0.x * pageSize.width, y: (1 - $0.y) * pageSize.height) }
                if let first = points.first { path.move(to: first) }
                for point in points.dropFirst() { path.addLine(to: point) }
                return path
            }
            var bounds = paths.reduce(CGRect.null) { $0.union($1.bounds) }.insetBy(dx: -width * pageSize.width, dy: -width * pageSize.width)
            if bounds.isNull || bounds.isEmpty { bounds = CGRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height) }
            let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            annotation.color = UIColor(cgColor: color.cgColor)
            let border = PDFBorder()
            border.lineWidth = max(0.5, width * pageSize.width)
            annotation.border = border
            for path in paths { annotation.add(path) }
            return [annotation]

        case .highlight(let rects, let color):
            return [quadAnnotation(rects: rects, pageSize: pageSize, type: .highlight, color: color)]
        case .underline(let rects, let color):
            return [quadAnnotation(rects: rects, pageSize: pageSize, type: .underline, color: color)]
        case .strikeout(let rects, let color):
            return [quadAnnotation(rects: rects, pageSize: pageSize, type: .strikeOut, color: color)]
        case .redaction(let rects):
            return rects.map { rect in
                let bounds = PDFGeometry.pagePoints(fromBase: rect.insetBy(dx: -0.002, dy: -0.003), size: pageSize).cgRect
                let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                annotation.color = .black
                annotation.interiorColor = .black
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                return annotation
            }
        case .replacement(let rects, let element, let background):
            guard let first = rects.min(by: { $0.minY < $1.minY || ($0.minY == $1.minY && $0.minX < $1.minX) }) else { return [] }
            let paperColor = UIColor(cgColor: (background ?? .white).cgColor)
            var annotations: [PDFAnnotation] = rects.map { rect in
                let bounds = PDFGeometry.pagePoints(fromBase: rect.insetBy(dx: -0.002, dy: -0.002), size: pageSize).cgRect
                // Scans: rebuild the paper under the word from the page itself, so the
                // patch carries the grain and tone of its surroundings instead of a flat block.
                if let patch = paper?.patch(for: bounds) {
                    return ImageStampAnnotation(image: UIImage(cgImage: patch), bounds: bounds)
                }
                let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                cover.color = paperColor
                cover.interiorColor = paperColor
                let border = PDFBorder()
                border.lineWidth = 0
                cover.border = border
                return cover
            }
            guard !element.text.isEmpty else { return annotations }
            let box = PDFGeometry.pagePoints(fromBase: first, size: pageSize).cgRect
            let font: UIFont
            let baselineFromTop: CGFloat
            if element.relativeSize > 0 {
                // Text layer: the size is known and the box is a full line box (ascender to descender).
                font = PDFTypography.font(named: element.fontName, size: element.relativeSize * pageSize.height)
                baselineFromTop = box.height + font.descender
            } else {
                // Scan: the box is glyph-tight; size the face so its glyphs span the same height.
                let probe = PDFTypography.font(named: element.fontName, size: 100)
                font = probe.withSize(PDFTypography.fontSize(fittingGlyphs: element.text, height: box.height, font: probe))
                baselineFromTop = PDFTypography.baselineFromGlyphTop(of: element.text, font: font)
            }
            let measured = (element.text as NSString).size(withAttributes: [.font: font])
            let padding = font.pointSize * 0.4
            let lineHeight = font.ascender - font.descender
            let bounds = CGRect(x: box.minX - padding, y: box.maxY - baselineFromTop + font.descender - padding,
                                width: max(box.width, ceil(measured.width)) + padding * 2, height: lineHeight + padding * 2)
            annotations.append(TextStampAnnotation(text: element.text, font: font, color: UIColor(cgColor: element.color.cgColor), bounds: bounds,
                                                   glyphOrigin: CGPoint(x: box.minX, y: box.maxY), baselineFromTop: baselineFromTop))
            return annotations

        case .text(let element), .pageNumber(let element):
            let fontSize = element.relativeSize * pageSize.height
            let font = UIFont.systemFont(ofSize: fontSize, weight: element.fontName.contains("Bold") || element.fontName.contains("Semibold") ? .semibold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let maxWidth = element.maxRelativeWidth * pageSize.width
            let measured = (element.text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            let width = ceil(measured.width) + fontSize * 0.6
            let height = ceil(measured.height) + fontSize * 0.4
            let center = CGPoint(x: element.center.x * pageSize.width, y: (1 - element.center.y) * pageSize.height)
            let bounds = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = element.text
            annotation.font = font
            annotation.fontColor = UIColor(cgColor: element.color.cgColor)
            annotation.color = .clear
            annotation.alignment = element.alignment == .leading ? .left : (element.alignment == .trailing ? .right : .center)
            return [annotation]

        case .image(let asset, let frame), .signature(let asset, let frame):
            guard let image = resolveImage(asset) else { return [] }
            let bounds = PDFGeometry.pagePoints(fromBase: frame, size: pageSize).cgRect
            return [ImageStampAnnotation(image: image, bounds: bounds)]

        case .rectangle(let rect, let color, let width):
            let bounds = PDFGeometry.pagePoints(fromBase: rect, size: pageSize).cgRect
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.color = UIColor(cgColor: color.cgColor)
            let border = PDFBorder()
            border.lineWidth = max(0.5, width * pageSize.width)
            annotation.border = border
            return [annotation]
        }
    }

    static func quadAnnotation(rects: [PSRect], pageSize: PSSize, type: PDFAnnotationSubtype, color: PSColor) -> PDFAnnotation {
        let pageRects = rects.map { PDFGeometry.pagePoints(fromBase: $0, size: pageSize).cgRect }
        let union = pageRects.reduce(CGRect.null) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: union.isNull ? .zero : union, forType: type, withProperties: nil)
        annotation.color = UIColor(cgColor: color.cgColor)
        // Quad points are relative to the annotation bounds origin.
        annotation.quadrilateralPoints = pageRects.flatMap { rect -> [NSValue] in
            let x0 = rect.minX - union.minX, x1 = rect.maxX - union.minX
            let y0 = rect.minY - union.minY, y1 = rect.maxY - union.minY
            return [NSValue(cgPoint: CGPoint(x: x0, y: y1)), NSValue(cgPoint: CGPoint(x: x1, y: y1)), NSValue(cgPoint: CGPoint(x: x0, y: y0)), NSValue(cgPoint: CGPoint(x: x1, y: y0))]
        }
        return annotation
    }
}

/// Reconstructs the paper under a word of a scanned page: the region is
/// rendered from the page, ink pixels are replaced by the nearest paper along
/// their row, and the result is stamped back exactly over the word. Text-layer
/// pages (vector text on a plain fill) are left to the flat cover.
final class PaperPatcher {
    private let page: PDFPage
    private var render: (bytes: [UInt8], width: Int, height: Int, scale: CGFloat)?
    private var isScan: Bool?
    static let renderSide: CGFloat = 2200

    init(page: PDFPage) { self.page = page }

    /// The page rendered once, unrotated, in media-box space.
    private func pageRender() -> (bytes: [UInt8], width: Int, height: Int, scale: CGFloat)? {
        if let render { return render }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = PaperPatcher.renderSide / max(box.width, box.height)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard ok else { return nil }
        render = (bytes, width, height, scale)
        return render
    }

    /// A page with a text layer draws vector text on a flat fill: a flat cover is exact there.
    private func pageIsScan() -> Bool {
        if let isScan { return isScan }
        let scan = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20
        isScan = scan
        return scan
    }

    /// Paper patch for a cover rectangle in page points (bottom-left origin), or nil to use a flat cover.
    func patch(for bounds: CGRect) -> CGImage? {
        guard pageIsScan(), let render = pageRender() else { return nil }
        let box = page.bounds(for: .mediaBox)
        let x0 = max(0, Int(((bounds.minX - box.minX) * render.scale).rounded(.down)))
        let x1 = min(render.width, Int(((bounds.maxX - box.minX) * render.scale).rounded(.up)))
        let y0 = max(0, Int(((bounds.minY - box.minY) * render.scale).rounded(.down)))
        let y1 = min(render.height, Int(((bounds.maxY - box.minY) * render.scale).rounded(.up)))
        let width = x1 - x0, height = y1 - y0
        guard width > 2, height > 2 else { return nil }
        // The bitmap context draws with a bottom-left origin but stores rows top-down,
        // so patch row 0 (top) is render row (renderHeight − y1).
        let rowBase = render.height - y1
        let sourceIndex = { (x: Int, y: Int) -> Int in ((rowBase + y) * render.width + (x0 + x)) * 4 }
        // Luminance and paper level of the patch.
        var luminance = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = sourceIndex(x, y)
                luminance[y * width + x] = 0.2126 * Double(render.bytes[index]) + 0.7152 * Double(render.bytes[index + 1]) + 0.0722 * Double(render.bytes[index + 2])
            }
        }
        let sorted = luminance.sorted()
        let paper = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
        let threshold = paper - max(40, paper * 0.35)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        // Fallback tone: the mean of the paper pixels of the whole patch.
        var sum = (0.0, 0.0, 0.0), paperCount = 0.0
        for y in 0..<height {
            for x in 0..<width where luminance[y * width + x] >= threshold {
                let index = sourceIndex(x, y)
                sum.0 += Double(render.bytes[index]); sum.1 += Double(render.bytes[index + 1]); sum.2 += Double(render.bytes[index + 2])
                paperCount += 1
            }
        }
        let mean: (UInt8, UInt8, UInt8) = paperCount > 0
            ? (UInt8(sum.0 / paperCount), UInt8(sum.1 / paperCount), UInt8(sum.2 / paperCount))
            : (UInt8(min(255, paper)), UInt8(min(255, paper)), UInt8(min(255, paper)))
        for y in 0..<height {
            // Paper columns of this row, so ink is filled with its nearest paper neighbours.
            var paperColumns: [Int] = []
            for x in 0..<width where luminance[y * width + x] >= threshold { paperColumns.append(x) }
            for x in 0..<width {
                let source = sourceIndex(x, y)
                let target = (y * width + x) * 4
                if luminance[y * width + x] >= threshold {
                    out[target] = render.bytes[source]; out[target + 1] = render.bytes[source + 1]; out[target + 2] = render.bytes[source + 2]
                } else if let left = paperColumns.last(where: { $0 < x }), let right = paperColumns.first(where: { $0 > x }) {
                    let l = sourceIndex(left, y), r = sourceIndex(right, y)
                    let t = Double(x - left) / Double(right - left)
                    for c in 0..<3 { out[target + c] = UInt8((Double(render.bytes[l + c]) * (1 - t) + Double(render.bytes[r + c]) * t).rounded()) }
                } else if let near = paperColumns.min(by: { abs($0 - x) < abs($1 - x) }) {
                    let n = sourceIndex(near, y)
                    out[target] = render.bytes[n]; out[target + 1] = render.bytes[n + 1]; out[target + 2] = render.bytes[n + 2]
                } else {
                    out[target] = mean.0; out[target + 1] = mean.1; out[target + 2] = mean.2
                }
                out[target + 3] = 255
            }
        }
        // Soften the row fill so no horizontal streak remains: a 3-tap vertical blur on the filled columns only.
        var smoothed = out
        for y in 1..<(height - 1) {
            for x in 0..<width where luminance[y * width + x] < threshold {
                let target = (y * width + x) * 4
                for c in 0..<3 {
                    let above = out[((y - 1) * width + x) * 4 + c], below = out[((y + 1) * width + x) * 4 + c]
                    smoothed[target + c] = UInt8((Int(above) + 2 * Int(out[target + c]) + Int(below)) / 4)
                }
            }
        }
        let data = Data(smoothed)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Stamp annotation that draws a bitmap (signatures, inserted photos).
final class ImageStampAnnotation: PDFAnnotation {
    let image: UIImage

    init(image: UIImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage else { return }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}
#endif
