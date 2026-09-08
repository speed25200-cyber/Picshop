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
            for markup in pageModel.markups {
                for annotation in annotations(for: markup, pageSize: size, resolveImage: resolveImage) {
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

    static func annotations(for markup: PDFMarkup, pageSize: PSSize, resolveImage: (MediaAsset) -> UIImage?) -> [PDFAnnotation] {
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
            let paper = UIColor(cgColor: (background ?? .white).cgColor)
            var annotations: [PDFAnnotation] = rects.map { rect in
                let bounds = PDFGeometry.pagePoints(fromBase: rect.insetBy(dx: -0.002, dy: -0.002), size: pageSize).cgRect
                let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                cover.color = paper
                cover.interiorColor = paper
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
