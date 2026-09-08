#if canImport(UIKit)
import Foundation
import UIKit
import CoreImage
import PicshopCore

/// Draws text and shape elements into CGImages at a given canvas size.
/// Results are resolution independent: fonts, shadows and paddings scale with
/// the canvas so previews match exports exactly.
public enum TextRasterizer {
    /// Rendered size of a text element (including its padding), in canvas pixels.
    public static func boundingSize(for element: TextElement, canvasSize: CGSize) -> CGSize? {
        let layout = layout(for: element, canvasSize: canvasSize)
        guard layout.size.width > 0, layout.size.height > 0 else { return nil }
        return layout.size
    }

    private struct Layout {
        var fontSize: CGFloat
        var attributes: [NSAttributedString.Key: Any]
        var attributed: NSAttributedString
        var bounds: CGRect
        var padding: CGFloat
        var size: CGSize
    }

    private static func layout(for element: TextElement, canvasSize: CGSize) -> Layout {
        let fontSize = max(4, element.relativeSize * canvasSize.height)
        let font = resolvedFont(named: element.fontName, size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = element.alignment == .leading ? .left : (element.alignment == .trailing ? .right : .center)
        paragraph.lineHeightMultiple = element.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(cgColor: element.color.cgColor),
            .paragraphStyle: paragraph,
            .kern: element.letterSpacing * fontSize,
        ]
        let shadow = NSShadow()
        switch element.style {
        case .shadowed:
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = fontSize * 0.12
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.06)
            attributes[.shadow] = shadow
        case .outlined:
            attributes[.strokeColor] = UIColor(cgColor: element.color.luminance > 0.5 ? PSColor.black.cgColor : PSColor.white.cgColor)
            attributes[.strokeWidth] = -fontSize * 0.09 / max(1, fontSize * 0.02)
        case .neon:
            shadow.shadowColor = UIColor(cgColor: element.color.cgColor)
            shadow.shadowBlurRadius = fontSize * 0.35
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        default:
            break
        }

        let attributed = NSAttributedString(string: element.text, attributes: attributes)
        let maxWidth = element.maxRelativeWidth * canvasSize.width
        let bounds = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let padding = fontSize * (element.style == .pill || element.style == .banner ? 0.55 : 0.4)
        let size = CGSize(width: ceil(bounds.width + padding * 2), height: ceil(bounds.height + padding * 2))
        return Layout(fontSize: fontSize, attributes: attributes, attributed: attributed, bounds: bounds, padding: padding, size: size)
    }

    public static func image(for element: TextElement, canvasSize: CGSize) -> CGImage? {
        let layout = layout(for: element, canvasSize: canvasSize)
        let attributes = layout.attributes
        let attributed = layout.attributed
        let bounds = layout.bounds
        let padding = layout.padding
        let size = layout.size
        guard size.width > 0, size.height > 0, size.width < 16384, size.height < 16384 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            switch element.style {
            case .pill:
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
                cg.addPath(path.cgPath)
                cg.fillPath()
            case .banner:
                cg.setFillColor(UIColor(cgColor: element.color.cgColor).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                let inverted = element.color.luminance > 0.5 ? UIColor.black : UIColor.white
                let bannerAttributes = attributes.merging([.foregroundColor: inverted]) { $1 }
                NSAttributedString(string: element.text, attributes: bannerAttributes).draw(with: CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                return
            default:
                break
            }
            attributed.draw(with: CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return image.cgImage
    }

    public static func image(for shape: ShapeElement, canvasSize: CGSize) -> CGImage? {
        let size = CGSize(width: max(2, shape.relativeSize.width * canvasSize.width), height: max(2, shape.relativeSize.height * canvasSize.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let lineWidth = shape.strokeWidth * min(canvasSize.width, canvasSize.height)
        let inset = lineWidth / 2
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let image = renderer.image { context in
            let cg = context.cgContext
            let path: UIBezierPath
            switch shape.kind {
            case .rectangle: path = UIBezierPath(rect: rect)
            case .roundedRectangle: path = UIBezierPath(roundedRect: rect, cornerRadius: shape.cornerRadius * min(canvasSize.width, canvasSize.height))
            case .ellipse: path = UIBezierPath(ovalIn: rect)
            case .line:
                path = UIBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            case .arrow:
                path = UIBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                let head = min(rect.height, rect.width * 0.25)
                path.move(to: CGPoint(x: rect.maxX - head, y: rect.midY - head / 2))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY + head / 2))
            }
            if shape.kind != .line, shape.kind != .arrow {
                cg.setFillColor(shape.fill.cgColor)
                cg.addPath(path.cgPath)
                cg.fillPath()
            }
            if let stroke = shape.stroke ?? (shape.kind == .line || shape.kind == .arrow ? shape.fill : nil) {
                cg.setStrokeColor(stroke.cgColor)
                cg.setLineWidth(max(1, lineWidth))
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.addPath(path.cgPath)
                cg.strokePath()
            }
        }
        return image.cgImage
    }

    static func resolvedFont(named name: String, size: CGFloat) -> UIFont {
        if name.hasPrefix("SFProRounded") {
            let weight: UIFont.Weight = name.hasSuffix("Bold") ? .bold : (name.hasSuffix("Black") ? .black : .semibold)
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: descriptor, size: size) }
            return base
        }
        if name.hasPrefix("SFProSerif") || name.hasPrefix("NewYork") {
            let base = UIFont.systemFont(ofSize: size, weight: .semibold)
            if let descriptor = base.fontDescriptor.withDesign(.serif) { return UIFont(descriptor: descriptor, size: size) }
            return base
        }
        if name.hasPrefix("SFMono") {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }
        return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: .bold)
    }

    /// Fonts offered in the text tool.
    public static let fontChoices: [(name: String, display: String)] = [
        ("SFProRounded-Bold", "Rounded"), ("SFPro-Bold", "Classic"), ("SFProSerif-Semibold", "Serif"), ("SFMono-Semibold", "Mono"),
        ("AvenirNext-Heavy", "Avenir"), ("Georgia-Bold", "Georgia"), ("Futura-Bold", "Futura"), ("Didot-Bold", "Didot"),
        ("MarkerFelt-Wide", "Marker"), ("Chalkduster", "Chalk"), ("SnellRoundhand-Bold", "Script"), ("Copperplate-Bold", "Copperplate"),
    ]
}
#endif
