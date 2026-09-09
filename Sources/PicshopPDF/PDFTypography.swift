#if canImport(PDFKit) && canImport(UIKit)
import Foundation
import PDFKit
import UIKit
import CoreGraphics
import PicshopCore

/// Typeface matching for in-place text replacement. A replaced word should
/// look like its neighbours: same family, same weight, same size, same
/// baseline. Text-layer PDFs tell us their font; scans are estimated from the
/// glyph proportions and the ink density of the original word.
enum PDFTypography {
    /// Installed families we can draw with, regular and bold faces.
    static let candidateFamilies: [(regular: String, bold: String, serif: Bool)] = [
        ("Helvetica", "Helvetica-Bold", false),
        ("Verdana", "Verdana-Bold", false),
        ("ArialMT", "Arial-BoldMT", false),
        ("TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", true),
        ("Georgia", "Georgia-Bold", true),
    ]

    static let fallbackName = "Helvetica"

    /// A font we can actually render, from a stored name.
    static func font(named name: String, size: CGFloat) -> UIFont {
        if let font = UIFont(name: name, size: size) { return font }
        let lower = name.lowercased()
        let bold = lower.contains("bold") || lower.contains("semibold") || lower.contains("heavy")
        if lower.contains("times") || lower.contains("georgia") || (lower.contains("serif") && !lower.contains("sans")) {
            return UIFont(name: bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        if lower.contains("courier") || lower.contains("mono") {
            return UIFont(name: bold ? "Courier-Bold" : "Courier", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        return UIFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// The closest installed face to a font read from a PDF text layer.
    static func installedName(matching font: UIFont) -> String {
        if UIFont(name: font.fontName, size: 10) != nil, !font.fontName.hasPrefix(".") { return font.fontName }
        let traits = font.fontDescriptor.symbolicTraits
        let lower = (font.familyName + " " + font.fontName).lowercased()
        let bold = traits.contains(.traitBold) || lower.contains("bold") || lower.contains("black") || lower.contains("heavy") || lower.contains("semibold")
        let mono = traits.contains(.traitMonoSpace) || lower.contains("courier") || lower.contains("mono")
        if mono { return bold ? "Courier-Bold" : "Courier" }
        let serifClasses: [UIFontDescriptor.SymbolicTraits] = [.classOldStyleSerifs, .classTransitionalSerifs, .classModernSerifs, .classClarendonSerifs, .classSlabSerifs, .classFreeformSerifs]
        let classValue = traits.rawValue & UIFontDescriptor.SymbolicTraits.classMask.rawValue
        let serifByClass = serifClasses.contains { $0.rawValue == classValue }
        let serifByName = ["times", "georgia", "garamond", "cambria", "book", "minion", "palatino", "baskerville", "serif", "roman", "century"].contains { lower.contains($0) } && !lower.contains("sans")
        if serifByClass || serifByName { return bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT" }
        if lower.contains("verdana") || lower.contains("tahoma") { return bold ? "Verdana-Bold" : "Verdana" }
        return bold ? "Helvetica-Bold" : "Helvetica"
    }

    // MARK: Glyph extents

    static func hasAscender(_ text: String) -> Bool {
        text.contains { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) }
    }

    static func hasDescender(_ text: String) -> Bool {
        text.contains { "gjpqy,;ç".contains($0) }
    }

    /// Height of the glyphs of `text` at size 1, from the baseline reference.
    private static func extents(of text: String, font: UIFont) -> (top: CGFloat, bottom: CGFloat) {
        let probe = font.withSize(100)
        let top = (hasAscender(text) ? max(probe.capHeight, probe.ascender * 0.92) : probe.xHeight) / 100
        let bottom = (hasDescender(text) ? -probe.descender : 0) / 100
        return (max(0.3, top), max(0, bottom))
    }

    /// Font size at which the glyphs of `text` span `height` points (OCR boxes are glyph-tight).
    static func fontSize(fittingGlyphs text: String, height: CGFloat, font: UIFont) -> CGFloat {
        let extent = extents(of: text, font: font)
        return max(3, height / (extent.top + extent.bottom))
    }

    /// Distance from the top of the glyph box to the baseline, for a glyph-tight box.
    static func baselineFromGlyphTop(of text: String, font: UIFont) -> CGFloat {
        extents(of: text, font: font).top * font.pointSize
    }

    // MARK: Scan estimation

    /// Measured ink of a scanned word: how dense it is, how thick its strokes
    /// are relative to the glyph height, and how much the stroke width varies
    /// (serif faces alternate hairlines and stems; sans faces are even).
    struct InkSample {
        var text: String
        var widthPx: CGFloat
        var heightPx: CGFloat
        var inkCoverage: Double
        /// Mean horizontal stroke width ÷ glyph height (≈0.10–0.13 regular sans, ≥0.16 bold).
        var strokeRatio: Double = 0
        /// Coefficient of variation of stroke widths (≥0.55 reads as serif).
        var strokeVariation: Double = 0
    }

    /// Guesses the face of a run of words on a scan. Weight comes from the
    /// stroke thickness, serif-ness from the stroke variation, and the family
    /// from whichever candidate best reproduces the measured word widths.
    /// Business documents are overwhelmingly sans, so serif needs evidence.
    static func estimateFace(words: [InkSample]) -> String {
        let usable = words.filter { $0.widthPx > 2 && $0.heightPx > 2 && !$0.text.isEmpty }
        guard !usable.isEmpty else { return fallbackName }
        let count = Double(usable.count)
        let coverage = usable.map(\.inkCoverage).reduce(0, +) / count
        let strokeRatio = usable.map(\.strokeRatio).reduce(0, +) / count
        let variation = usable.map(\.strokeVariation).reduce(0, +) / count
        let isBold = strokeRatio > 0 ? (strokeRatio > 0.155 || (strokeRatio > 0.135 && coverage > 0.3)) : coverage > 0.27
        let looksSerif = variation > 0.55
        var best: (name: String, error: CGFloat) = (fallbackName, .greatestFiniteMagnitude)
        for family in candidateFamilies {
            let name = isBold ? family.bold : family.regular
            guard let probe = UIFont(name: name, size: 100) else { continue }
            var error: CGFloat = 0
            for word in usable {
                let size = fontSize(fittingGlyphs: word.text, height: word.heightPx, font: probe)
                let measured = (word.text as NSString).size(withAttributes: [.font: probe.withSize(size)]).width
                error += abs(measured - word.widthPx) / max(1, word.widthPx)
            }
            // Width alone cannot tell Times from Helvetica on a scan; the ink can.
            if family.serif != looksSerif { error += 0.12 * CGFloat(usable.count) }
            if error < best.error { best = (name, error) }
        }
        return best.name
    }

    /// Stroke statistics of the ink inside a normalised box of a grey page render:
    /// horizontal run lengths of dark pixels, which cross the vertical stems.
    static func strokeStats(of rect: PSRect, gray: [UInt8], width: Int, height: Int) -> (ratio: Double, variation: Double) {
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height))), y1 = min(height, Int(rect.maxY * Double(height)))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return (0, 0) }
        var samples: [UInt8] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 { samples.append(gray[y * width + x]) } }
        let sorted = samples.sorted()
        let paper = Double(sorted[min(sorted.count - 1, sorted.count * 3 / 4)])
        let threshold = paper - max(40, paper * 0.35)
        var runs: [Int] = []
        for y in y0..<y1 {
            var run = 0
            for x in x0...x1 {
                let ink = x < x1 && Double(gray[y * width + x]) < threshold
                if ink { run += 1 } else if run > 0 { runs.append(run); run = 0 }
            }
        }
        // Drop the longest runs (horizontal bars of E, T, underlines) and the 1-px noise.
        let cleaned = runs.filter { $0 > 1 }.sorted()
        guard cleaned.count >= 8 else { return (0, 0) }
        let kept = Array(cleaned.prefix(max(8, cleaned.count * 85 / 100)))
        let mean = Double(kept.reduce(0, +)) / Double(kept.count)
        let variance = kept.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(kept.count)
        let glyphHeight = Double(y1 - y0)
        return (mean / max(1, glyphHeight), variance.squareRoot() / max(0.001, mean))
    }

    /// Fraction of dark pixels inside a normalised box of a grey page render.
    static func inkCoverage(of rect: PSRect, gray: [UInt8], width: Int, height: Int) -> Double {
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height))), y1 = min(height, Int(rect.maxY * Double(height)))
        guard x1 > x0 + 1, y1 > y0 + 1 else { return 0 }
        // Paper level: the brightest quartile of the box.
        var samples: [UInt8] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 { samples.append(gray[y * width + x]) } }
        let sorted = samples.sorted()
        let paper = Double(sorted[min(sorted.count - 1, sorted.count * 3 / 4)])
        let threshold = paper - max(40, paper * 0.35)
        let ink = samples.reduce(0) { $0 + (Double($1) < threshold ? 1 : 0) }
        return Double(ink) / Double(samples.count)
    }
}

/// Vector text drawn in place of a covered word, with any installed font.
/// PDFKit's free-text annotations only honour the base-14 fonts and fall back
/// to Times otherwise; drawing the glyphs ourselves keeps the family, and the
/// export path flattens custom annotations into the page.
final class TextStampAnnotation: PDFAnnotation {
    let text: String
    let textFont: UIFont
    let textColor: UIColor
    /// Top-left of the original glyph box, in page space (bottom-left origin).
    let glyphOrigin: CGPoint
    /// Distance from `glyphOrigin.y` down to the baseline.
    let baselineFromTop: CGFloat

    init(text: String, font: UIFont, color: UIColor, bounds: CGRect, glyphOrigin: CGPoint, baselineFromTop: CGFloat) {
        self.text = text
        self.textFont = font
        self.textColor = color
        self.glyphOrigin = glyphOrigin
        self.baselineFromTop = baselineFromTop
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        context.saveGState()
        context.translateBy(x: glyphOrigin.x, y: glyphOrigin.y)
        context.scaleBy(x: 1, y: -1)
        // UIKit draws the line box from its top; place it so the baseline lands where the original was.
        let lineTop = baselineFromTop - textFont.ascender
        (text as NSString).draw(at: CGPoint(x: 0, y: lineTop), withAttributes: [.font: textFont, .foregroundColor: textColor])
        context.restoreGState()
        UIGraphicsPopContext()
    }
}
#endif
