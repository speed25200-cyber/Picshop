#if canImport(PDFKit) && canImport(Vision) && canImport(UIKit)
import Foundation
import PDFKit
import Vision
import UIKit
import PicshopCore
import PicshopImaging

/// Reads the words of scanned pages with Vision so search, replace, highlight and
/// tap-to-edit work on PDFs that have no text layer (photos, WhatsApp scans, faxes).
/// Results are cached per composed page and page image.
final class PDFTextRecognizer: @unchecked Sendable {
    /// One recognised word, positioned in both the displayed and the base page space.
    struct Word: Sendable {
        let text: String
        /// Normalised, top-left origin, as displayed (after rotation).
        let displayedRect: PSRect
        /// Normalised, top-left origin, in the page's unrotated base space (markup space).
        let baseRect: PSRect
        /// Colour of the paper right around the word.
        let background: PSColor
        let lineIndex: Int
        let indexInLine: Int
        /// Punctuation glued to the end of the word on the page ("Monsieur," → ","), kept when the word is replaced.
        var suffix: String = ""
    }

    struct PageText: Sendable {
        let words: [Word]
        var lines: [[Word]] {
            Dictionary(grouping: words, by: \.lineIndex).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.indexInLine < $1.indexInLine } }
        }
    }

    private let lock = NSLock()
    private var cache: [String: PageText] = [:]
    /// Grey render of the most recently estimated page, for ink-density measurements.
    private var grayRender: (key: String, gray: [UInt8], width: Int, height: Int)?
    static let renderSide: CGFloat = 2200

    /// Installed face that best matches a run of recognised words (see `PDFTypography`).
    func fontEstimate(for words: [Word], page: PDFPage, key: String) -> String {
        guard !words.isEmpty else { return PDFTypography.fallbackName }
        let render: (key: String, gray: [UInt8], width: Int, height: Int)
        if let cached = lock.withLock({ grayRender }), cached.key == key {
            render = cached
        } else {
            guard let cg = PDFTextRecognizer.render(page: page, longestSide: PDFTextRecognizer.renderSide).cgImage else { return PDFTypography.fallbackName }
            render = (key, ImageSupport.grayBytes(from: cg), cg.width, cg.height)
            lock.withLock { grayRender = render }
        }
        let samples = words.map { word -> PDFTypography.InkSample in
            let stroke = PDFTypography.strokeStats(of: word.displayedRect, gray: render.gray, width: render.width, height: render.height)
            return PDFTypography.InkSample(text: word.text,
                                           widthPx: CGFloat(word.displayedRect.width * Double(render.width)),
                                           heightPx: CGFloat(word.displayedRect.height * Double(render.height)),
                                           inkCoverage: PDFTypography.inkCoverage(of: word.displayedRect, gray: render.gray, width: render.width, height: render.height),
                                           strokeRatio: stroke.ratio, strokeVariation: stroke.variation)
        }
        return PDFTypography.estimateFace(words: samples)
    }

    /// Recognises the text on a page (cached). `key` must change whenever the page content changes.
    func text(for page: PDFPage, key: String, languages: [String] = ["fr-FR", "en-US"]) -> PageText {
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let image = PDFTextRecognizer.render(page: page, longestSide: PDFTextRecognizer.renderSide)
        let result = recognise(image: image, rotation: page.rotation, languages: languages)
        lock.withLock {
            if cache.count > 12 { cache.removeAll() }
            cache[key] = result
        }
        return result
    }

    static func render(page: PDFPage, longestSide: CGFloat) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = longestSide / max(1, max(rotated.width, rotated.height))
        return page.thumbnail(of: CGSize(width: rotated.width * scale, height: rotated.height * scale), for: .mediaBox)
    }

    private func recognise(image: UIImage, rotation: Int, languages: [String]) -> PageText {
        guard let cg = image.cgImage else { return PageText(words: []) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            PSLog.error("OCR failed: \(error)", category: .imaging)
            return PageText(words: [])
        }
        let sampler = BackgroundSampler(image: cg)
        var words: [Word] = []
        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        for (lineIndex, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            var indexInLine = 0
            var searchStart = string.startIndex
            for piece in string.split(separator: " ", omittingEmptySubsequences: true) {
                guard let range = string.range(of: piece, range: searchStart..<string.endIndex) else { continue }
                searchStart = range.upperBound
                let box: CGRect
                if let rect = try? candidate.boundingBox(for: range)?.boundingBox { box = rect } else { box = observation.boundingBox }
                // Vision: normalised, bottom-left origin → displayed, top-left origin.
                let displayed = PSRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height).clampedToUnit()
                let base = PDFGeometry.baseRect(fromDisplayed: displayed, rotation: rotation)
                let background = sampler.color(around: displayed)
                let cleaned = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?()[]«»\"“”'"))
                guard !cleaned.isEmpty else { continue }
                let suffix = String(piece.reversed().prefix { ",.;:!?".contains($0) }.reversed())
                words.append(Word(text: cleaned, displayedRect: displayed, baseRect: base, background: background, lineIndex: lineIndex, indexInLine: indexInLine, suffix: suffix))
                indexInLine += 1
            }
        }
        return PageText(words: words)
    }

    // MARK: Matching

    /// Sequences of consecutive words on one line matching `query` (accent- and case-insensitive).
    func matches(for query: String, in text: PageText) -> [[Word]] {
        let target = PDFTextRecognizer.fold(query).split(separator: " ").map(String.init)
        guard !target.isEmpty else { return [] }
        var result: [[Word]] = []
        for line in text.lines {
            let folded = line.map { PDFTextRecognizer.fold($0.text) }
            guard folded.count >= target.count else { continue }
            for start in 0...(folded.count - target.count) {
                var ok = true
                for offset in 0..<target.count where !PDFTextRecognizer.wordMatches(folded[start + offset], target[offset], last: offset == target.count - 1, first: offset == 0) {
                    ok = false
                    break
                }
                if ok { result.append(Array(line[start..<(start + target.count)])) }
            }
        }
        return result
    }

    /// The word under a displayed point, with a small touch slop.
    func word(at point: PSPoint, in text: PageText) -> Word? {
        if let exact = text.words.first(where: { $0.displayedRect.contains(point) }) { return exact }
        return text.words
            .filter { $0.displayedRect.insetBy(dx: -0.012, dy: -0.008).contains(point) }
            .min { distance($0.displayedRect.center, point) < distance($1.displayedRect.center, point) }
    }

    private func distance(_ a: PSPoint, _ b: PSPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    private static func wordMatches(_ word: String, _ target: String, last: Bool, first: Bool) -> Bool {
        if word == target { return true }
        // Tolerate a trailing apostrophe/plural or an OCR-glued punctuation on the edges of the phrase.
        if (first || last), word.hasPrefix(target), word.count - target.count <= 1 { return true }
        return false
    }
}

/// Estimates the paper colour around a word so covers blend into scans.
private struct BackgroundSampler {
    let image: CGImage
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int

    init(image: CGImage) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.image = image
        width = w
        height = h
        bytes = data
    }

    /// Average of the lighter half of the pixels in a band around the rect (the ink is darker than the paper).
    func color(around rect: PSRect) -> PSColor {
        let outer = rect.insetBy(dx: -rect.height * 0.6, dy: -rect.height * 0.35).clampedToUnit()
        let x0 = Int(outer.minX * Double(width)), x1 = min(width - 1, Int(outer.maxX * Double(width)))
        let y0 = Int(outer.minY * Double(height)), y1 = min(height - 1, Int(outer.maxY * Double(height)))
        guard x1 > x0, y1 > y0 else { return .white }
        let stepX = max(1, (x1 - x0) / 40), stepY = max(1, (y1 - y0) / 12)
        var samples: [(Double, Double, Double, Double)] = []
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let index = (y * width + x) * 4
                let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
                samples.append((r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b))
                x += stepX
            }
            y += stepY
        }
        guard !samples.isEmpty else { return .white }
        let sorted = samples.sorted { $0.3 > $1.3 }
        let lighter = sorted.prefix(max(1, sorted.count / 2))
        let count = Double(lighter.count)
        let r = lighter.reduce(0) { $0 + $1.0 } / count
        let g = lighter.reduce(0) { $0 + $1.1 } / count
        let b = lighter.reduce(0) { $0 + $1.2 } / count
        return PSColor(red: r, green: g, blue: b)
    }
}
#endif
