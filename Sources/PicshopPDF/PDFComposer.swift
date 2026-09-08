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
        case .replacement(let rects, let element):
            guard let first = rects.min(by: { $0.minY < $1.minY || ($0.minY == $1.minY && $0.minX < $1.minX) }) else { return [] }
            var annotations: [PDFAnnotation] = rects.map { rect in
                let bounds = PDFGeometry.pagePoints(fromBase: rect.insetBy(dx: -0.002, dy: -0.002), size: pageSize).cgRect
                let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                cover.color = .white
                cover.interiorColor = .white
                let border = PDFBorder()
                border.lineWidth = 0
                cover.border = border
                return cover
            }
            let box = PDFGeometry.pagePoints(fromBase: first, size: pageSize).cgRect
            // Fit the new text into the height of the original line; let it run to the right if longer.
            let fontSize = max(4, box.height * 0.78)
            let font = UIFont.systemFont(ofSize: fontSize, weight: element.fontName.contains("Bold") || element.fontName.contains("Semibold") ? .semibold : .regular)
            let measured = (element.text as NSString).size(withAttributes: [.font: font])
            let width = max(box.width, ceil(measured.width) + fontSize * 0.4)
            let bounds = CGRect(x: box.minX - fontSize * 0.1, y: box.minY - fontSize * 0.15, width: width + fontSize * 0.2, height: max(box.height, ceil(measured.height)) + fontSize * 0.3)
            let text = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            text.contents = element.text
            text.font = font
            text.fontColor = UIColor(cgColor: element.color.cgColor)
            text.color = .clear
            text.alignment = .left
            annotations.append(text)
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
