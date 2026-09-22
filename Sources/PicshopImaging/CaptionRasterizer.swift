#if canImport(UIKit)
import Foundation
import UIKit
import CoreImage
import PicshopCore

/// Draws one caption cue for a frame. Sizes scale with the frame's shorter
/// side, so the preview, a 9:16 export and a 4K export all look the same.
public enum CaptionRasterizer {
    public static func fontSize(for track: CaptionTrack, canvasSize: CGSize) -> CGFloat {
        let short = min(canvasSize.width, canvasSize.height)
        let base: CGFloat
        switch track.style {
        case .karaoke, .reveal: base = 0.068
        case .classic, .boxed: base = 0.05
        case .minimal: base = 0.04
        }
        return max(10, short * base * CGFloat(track.scale))
    }

    static func font(for style: CaptionStyle, size: CGFloat) -> UIFont {
        switch style {
        case .karaoke:
            let heavy = UIFont.systemFont(ofSize: size, weight: .heavy)
            return heavy.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? heavy
        case .reveal: return UIFont.systemFont(ofSize: size, weight: .bold)
        case .classic, .boxed: return UIFont.systemFont(ofSize: size, weight: .semibold)
        case .minimal: return UIFont.systemFont(ofSize: size, weight: .medium)
        }
    }

    /// The cue as it should look at the moment `activeWord` is being spoken.
    public static func image(for cue: CaptionCue, activeWord: Int?, track: CaptionTrack, canvasSize: CGSize) -> CGImage? {
        guard !cue.words.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let style = track.style
        let size = fontSize(for: track, canvasSize: canvasSize)
        let font = font(for: style, size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = style == .karaoke ? 0.92 : 1.02

        let base = UIColor(cgColor: track.textColor.cgColor)
        let highlight = UIColor(cgColor: track.highlightColor.cgColor)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(style == .minimal ? 0.45 : 0.6)
        shadow.shadowBlurRadius = size * 0.18
        shadow.shadowOffset = CGSize(width: 0, height: size * 0.05)

        let text = NSMutableAttributedString()
        for (index, word) in cue.words.enumerated() {
            var string: String
            switch style {
            case .karaoke: string = word.text.uppercased()
            case .minimal: string = word.text.lowercased()
            default: string = word.text
            }
            if index > 0 { string = " " + string }
            var color = base
            if style == .karaoke, let activeWord, index == activeWord { color = highlight }
            if style == .reveal, index > (activeWord ?? -1) { color = .clear }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if style != .boxed { attributes[.shadow] = shadow }
            if style == .karaoke {
                // A dark outline keeps the words readable over any picture.
                attributes[.strokeColor] = UIColor.black.withAlphaComponent(color == .clear ? 0 : 0.85)
                attributes[.strokeWidth] = -5.0
            }
            if style == .karaoke || style == .reveal { attributes[.kern] = size * 0.01 }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        let maximumWidth = canvasSize.width * (style == .minimal ? 0.8 : 0.86)
        let bounds = text.boundingRect(with: CGSize(width: maximumWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let padding = style == .boxed ? CGSize(width: size * 0.6, height: size * 0.36) : CGSize(width: size * 0.4, height: size * 0.3)
        let imageSize = CGSize(width: bounds.width + padding.width * 2, height: bounds.height + padding.height * 2)
        guard imageSize.width >= 1, imageSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let image = renderer.image { _ in
            if style == .boxed {
                UIColor.black.withAlphaComponent(0.58).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize), cornerRadius: size * 0.42).fill()
            }
            text.draw(with: CGRect(x: padding.width, y: padding.height, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return image.cgImage
    }

    /// The cue placed on a frame of `canvasSize` (Core Image coordinates, origin bottom-left).
    public static func placedImage(for cue: CaptionCue, activeWord: Int?, track: CaptionTrack, canvasSize: CGSize) -> CIImage? {
        guard let cg = image(for: cue, activeWord: activeWord, track: track, canvasSize: canvasSize) else { return nil }
        let raster = CIImage(cgImage: cg)
        let x = (canvasSize.width - raster.extent.width) / 2
        var y = (1 - CGFloat(track.verticalPosition)) * canvasSize.height - raster.extent.height / 2
        y = min(max(y, canvasSize.height * 0.03), canvasSize.height * 0.97 - raster.extent.height)
        return raster.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }
}
#endif
