import Foundation
import PicshopCore
#if canImport(Vision) && canImport(CoreImage)
import CoreGraphics
#endif

// Table detection for the fill (contract §6). The pure part below (RulingLineDetector,
// TableStyleEstimator, TableGridRefiner, the Word bridge) builds and is tested on Linux; the Apple
// part at the end runs Vision's words and the picture's pixels through it and TableGridBuilder.

// MARK: - Ruling lines and bands (pure)

/// The thin straight rules of a table and its flat colour bands (zebra rows, a tinted column), from
/// luminance alone: no OCR, no Vision.
///
/// How (contract §6, behaviour 1): a picture whose median luminance is under 110 is inverted first
/// (dark mode), then the gray bytes are min-pooled 2× so 1-px rules survive; ink is a pixel darker than
/// its 31-px box mean by at least max(18, 0.1 × that mean); each row keeps its longest ink run (gaps of
/// at most 2 px bridged); a rule is a run of consecutive rows whose runs are at least 0.15 × the width
/// and overlap by 80 %, at most max(3 px, 0.006 × the height) thick; vertical rules are the transpose;
/// bands are stretches whose per-row (per-column) median luminance steps at least 6 levels away from
/// the page's, thicker than a rule.
public enum RulingLineDetector {
    public struct Output: Hashable, Sendable {
        public var lines: [TableGridBuilder.RulingLine]
        public var bands: [TableGridBuilder.Band]

        public init(lines: [TableGridBuilder.RulingLine] = [], bands: [TableGridBuilder.Band] = []) {
            self.lines = lines
            self.bands = bands
        }
    }

    /// Radius of the box mean ink is measured against (a 31-px box on the pooled picture).
    static let boxRadius = 15
    /// Ink is darker than its box mean by at least max(this, `relativeContrast` × the mean).
    static let minimumContrast = 18
    static let relativeContrast = 0.1
    /// Pictures with a darker median are dark mode: inverted before anything else.
    static let darkMedian = 110
    /// Gaps of at most this many pooled pixels do not break a run.
    static let maximumGap = 2
    /// A rule's run spans at least this share of the picture's width (height for vertical rules).
    static let minimumRunShare = 0.15
    /// Consecutive rows of one rule overlap by at least this share of the shorter run.
    static let minimumOverlap = 0.8
    /// A band's median luminance is at least this many levels away from the page's.
    static let bandStep = 6
    /// At most this many bands per axis (a photo has many; a table a few).
    static let maximumBands = 48

    /// gray: 8-bit luminance, row-major, width × height (~2048 px long side). Positions, extents and
    /// thicknesses come back normalised with a top-left origin; nothing for a malformed buffer.
    public static func detect(gray: [UInt8], width: Int, height: Int) -> Output {
        guard width > 1, height > 1, gray.count >= width * height else { return Output() }
        let inverted = median(gray, count: width * height) < darkMedian
        let (pooled, pooledWidth, pooledHeight) = minPooled(gray, width: width, height: height, inverted: inverted)
        let ink = inkMask(pooled, width: pooledWidth, height: pooledHeight)

        let horizontalLimit = max(3, Int((0.006 * Double(pooledHeight)).rounded()))
        let verticalLimit = max(3, Int((0.006 * Double(pooledWidth)).rounded()))
        var lines = rules(in: ink, lineLength: pooledWidth, lineCount: pooledHeight, maximumThickness: horizontalLimit, axis: .horizontal)
        let transposedInk = transposed(ink, width: pooledWidth, height: pooledHeight)
        lines += rules(in: transposedInk, lineLength: pooledHeight, lineCount: pooledWidth, maximumThickness: verticalLimit, axis: .vertical)

        var bands = self.bands(of: pooled, lineLength: pooledWidth, lineCount: pooledHeight, minimumThickness: horizontalLimit + 1, axis: .horizontal)
        let transposedGray = transposed(pooled, width: pooledWidth, height: pooledHeight)
        bands += self.bands(of: transposedGray, lineLength: pooledHeight, lineCount: pooledWidth, minimumThickness: verticalLimit + 1, axis: .vertical)
        return Output(lines: lines, bands: bands)
    }

    // MARK: Steps

    /// The median byte of the first `count` bytes (a 256-bin histogram of every 3rd byte).
    static func median(_ bytes: [UInt8], count: Int) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        var sampled = 0
        bytes.withUnsafeBufferPointer { buffer in
            for index in Swift.stride(from: 0, to: min(count, buffer.count), by: 3) {
                histogram[Int(buffer[index])] += 1
                sampled += 1
            }
        }
        var seen = 0
        let half = (sampled + 1) / 2
        for level in 0..<256 {
            seen += histogram[level]
            if seen >= half { return level }
        }
        return 255
    }

    /// 2 × 2 minimum (dark wins), after inverting a dark picture, so a 1-px dark rule stays whole.
    static func minPooled(_ gray: [UInt8], width: Int, height: Int, inverted: Bool) -> (bytes: [UInt8], width: Int, height: Int) {
        let pooledWidth = (width + 1) / 2, pooledHeight = (height + 1) / 2
        var pooled = [UInt8](repeating: 255, count: pooledWidth * pooledHeight)
        gray.withUnsafeBufferPointer { source in
            pooled.withUnsafeMutableBufferPointer { target in
                let flip: UInt8 = inverted ? 255 : 0
                for y in 0..<height {
                    let row = y * width, targetRow = (y / 2) * pooledWidth
                    for x in 0..<width {
                        // XOR with 255 is 255 − value.
                        let value = source[row + x] ^ flip
                        let index = targetRow + x >> 1
                        if value < target[index] { target[index] = value }
                    }
                }
            }
        }
        return (pooled, pooledWidth, pooledHeight)
    }

    /// Per pixel, how much darker than its box mean it is when that counts as ink (0 otherwise).
    static func inkMask(_ gray: [UInt8], width: Int, height: Int) -> [UInt8] {
        let stride = width + 1
        var integral = [Int](repeating: 0, count: stride * (height + 1))
        gray.withUnsafeBufferPointer { source in
            integral.withUnsafeMutableBufferPointer { sums in
                for y in 0..<height {
                    var rowSum = 0
                    for x in 0..<width {
                        rowSum += Int(source[y * width + x])
                        sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + rowSum
                    }
                }
            }
        }
        var ink = [UInt8](repeating: 0, count: width * height)
        let radius = boxRadius, inverse = Int((1 / relativeContrast).rounded())
        let lefts = (0..<width).map { max(0, $0 - radius) }, rights = (0..<width).map { min(width, $0 + radius + 1) }
        gray.withUnsafeBufferPointer { source in
            integral.withUnsafeBufferPointer { sums in
                ink.withUnsafeMutableBufferPointer { target in
                    for y in 0..<height {
                        let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
                        let top = y0 * stride, bottom = y1 * stride, rows = y1 - y0
                        for x in 0..<width {
                            let x0 = lefts[x], x1 = rights[x]
                            let total = sums[bottom + x1] - sums[top + x1] - sums[bottom + x0] + sums[top + x0]
                            let area = rows * (x1 - x0)
                            // mean − value ≥ max(minimumContrast, relativeContrast × mean), times the area.
                            let darker = total - Int(source[y * width + x]) * area
                            if darker >= minimumContrast * area, darker * inverse >= total {
                                target[y * width + x] = UInt8(min(255, darker / area))
                            }
                        }
                    }
                }
            }
        }
        return ink
    }

    static func transposed(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                for y in 0..<height {
                    for x in 0..<width { target[x * height + y] = source[y * width + x] }
                }
            }
        }
        return result
    }

    /// The longest ink run of one line (gaps of at most `maximumGap` bridged).
    struct Run: Hashable {
        var start: Int
        /// Inclusive.
        var end: Int
        var contrast: Int
        var inkCount: Int
        var length: Int { end - start + 1 }

        func overlap(with other: Run) -> Double {
            let shared = min(end, other.end) - max(start, other.start) + 1
            return shared <= 0 ? 0 : Double(shared) / Double(min(length, other.length))
        }
    }

    static func longestRuns(in ink: [UInt8], lineLength: Int, lineCount: Int) -> [Run?] {
        var runs = [Run?](repeating: nil, count: lineCount)
        ink.withUnsafeBufferPointer { buffer in
            for line in 0..<lineCount {
                let base = line * lineLength
                var best: Run?
                var current: Run?
                for position in 0..<lineLength {
                    let value = Int(buffer[base + position])
                    guard value > 0 else { continue }
                    if var run = current, position - run.end - 1 <= maximumGap {
                        run.end = position
                        run.contrast += value
                        run.inkCount += 1
                        current = run
                    } else {
                        if let run = current, run.length > (best?.length ?? 0) { best = run }
                        current = Run(start: position, end: position, contrast: value, inkCount: 1)
                    }
                }
                if let run = current, run.length > (best?.length ?? 0) { best = run }
                runs[line] = best
            }
        }
        return runs
    }

    static func rules(in ink: [UInt8], lineLength: Int, lineCount: Int, maximumThickness: Int, axis: TableGridBuilder.RulingLine.Axis) -> [TableGridBuilder.RulingLine] {
        let runs = longestRuns(in: ink, lineLength: lineLength, lineCount: lineCount)
        let minimumLength = max(2, Int((minimumRunShare * Double(lineLength)).rounded(.up)))
        func long(_ index: Int) -> Run? {
            guard let run = runs[index], run.length >= minimumLength else { return nil }
            return run
        }
        var found: [TableGridBuilder.RulingLine] = []
        var line = 0
        while line < lineCount {
            guard let first = long(line) else {
                line += 1
                continue
            }
            var group = [first]
            var next = line + 1
            while next < lineCount, let run = long(next), run.overlap(with: group[group.count - 1]) >= minimumOverlap {
                group.append(run)
                next += 1
            }
            if group.count <= maximumThickness {
                let starts = group.map(\.start).sorted(), ends = group.map(\.end).sorted()
                let contrast = Double(group.map(\.contrast).reduce(0, +)) / Double(max(1, group.map(\.inkCount).reduce(0, +))) / 255
                found.append(TableGridBuilder.RulingLine(axis: axis, position: (Double(line) + Double(group.count) / 2) / Double(lineCount),
                                                         start: Double(starts[starts.count / 2]) / Double(lineLength),
                                                         end: Double(ends[ends.count / 2] + 1) / Double(lineLength),
                                                         thickness: Double(group.count) / Double(lineCount), contrast: min(1, contrast)))
            }
            line = next
        }
        return found
    }

    /// Stretches of lines whose median luminance sits at least `bandStep` levels away from the page's
    /// (the most common line median), each at least `minimumThickness` lines thick.
    static func bands(of gray: [UInt8], lineLength: Int, lineCount: Int, minimumThickness: Int, axis: TableGridBuilder.RulingLine.Axis) -> [TableGridBuilder.Band] {
        guard lineCount > 0, lineLength > 0 else { return [] }
        var medians = [Int](repeating: 0, count: lineCount)
        var histogram = [Int](repeating: 0, count: 256)
        gray.withUnsafeBufferPointer { buffer in
            for line in 0..<lineCount {
                for level in 0..<256 { histogram[level] = 0 }
                let base = line * lineLength
                for position in 0..<lineLength { histogram[Int(buffer[base + position])] += 1 }
                var seen = 0
                let half = (lineLength + 1) / 2
                for level in 0..<256 {
                    seen += histogram[level]
                    if seen >= half {
                        medians[line] = level
                        break
                    }
                }
            }
        }
        // The page: the most common line median (coarse bins of 4 levels), refined to its bin's mean.
        var bins = [Int](repeating: 0, count: 64)
        for value in medians { bins[value / 4] += 1 }
        var pageBin = 0
        for bin in 0..<64 where bins[bin] > bins[pageBin] { pageBin = bin }
        let inBin = medians.filter { $0 / 4 == pageBin }
        let page = inBin.reduce(0, +) / max(1, inBin.count)

        var found: [TableGridBuilder.Band] = []
        var line = 0
        while line < lineCount, found.count < maximumBands {
            let level = medians[line]
            guard abs(level - page) >= bandStep else {
                line += 1
                continue
            }
            var end = line + 1
            while end < lineCount, abs(medians[end] - level) < bandStep, abs(medians[end] - page) >= bandStep { end += 1 }
            if end - line >= max(3, minimumThickness) {
                found.append(TableGridBuilder.Band(axis: axis, start: Double(line) / Double(lineCount), end: Double(end) / Double(lineCount)))
            }
            line = end
        }
        return found
    }
}

// MARK: - Typography (pure)

/// The typography of printed words: size, colour and weight, measured on the pixels so a fill writes
/// in the table's own style (D5, precedence 1 and 3).
public enum TableStyleEstimator {
    /// Typography of the words in `boxes` (normalised, top-left) on `rgba` (width × height, 4 bytes/px).
    /// relativeSize = font size / image height (the canvas height). Nil when no word can be measured.
    ///
    /// How, per word box (grown by 15 % of its height, since OCR boxes can clip the glyphs):
    /// - ink coverage from the luminance between the paper (a bright percentile) and the ink (a dark
    ///   one), so anti-aliased edges count for what they cover; dark tables are read the other way round;
    /// - the glyph height from the glyphs' ink blobs (tops and baseline to sub-pixel precision; dots,
    ///   commas and hyphens left out): the cap height when capitals, digits or ascenders dominate the
    ///   text, else the x-height. The font
    ///   size is that height × SF Pro's own ratio (`Calibration.capHeightToFontSize`,
    ///   `xHeightToFontSize`): a fill drawn in SF Pro at that size has glyphs exactly as tall as the
    ///   printed ones, whatever the table's font. A word whose ink cannot be read falls back to its box
    ///   height × `Calibration.boxHeightToFontSize`;
    /// - the stroke width as 2 × ink area / ink perimeter (the total variation of the coverage), over
    ///   the x-height, into `weight(strokeToXHeight:)`;
    /// - the colour: the mean of the darkest 25 % of the ink pixels (the brightest on a dark table).
    /// The medians over the words make the style. Alignment is left `.center`: TableGridRefiner sets a
    /// column's alignment from where its words sit in their cells.
    public static func style(of boxes: [PSRect], texts: [String], rgba: [UInt8], width: Int, height: Int) -> TableGrid.Style? {
        guard !boxes.isEmpty, width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let darkPaper = isDarkPaper(boxes: boxes, rgba: rgba, width: width, height: height)
        let joined = texts.joined(separator: " ")
        var sizes: [Double] = [], ratios: [Double] = []
        var samples: [InkSample] = []
        for (index, box) in boxes.enumerated() {
            let text = texts.count == boxes.count ? texts[index] : joined
            if let measure = measure(box, text: text, rgba: rgba, width: width, height: height, darkPaper: darkPaper) {
                if let size = measure.fontSize { sizes.append(size) }
                if let ratio = measure.strokeRatio { ratios.append(ratio) }
                samples += measure.samples
            } else if box.height > 0 {
                sizes.append(box.height * Double(height) * Calibration.boxHeightToFontSize)
            }
        }
        guard !sizes.isEmpty, !samples.isEmpty else { return nil }
        let relativeSize = (median(sizes) / Double(height)).clamped(to: 0.004...0.3)
        let weight = ratios.isEmpty ? TableGrid.FontWeight.regular : self.weight(strokeToXHeight: median(ratios))
        return TableGrid.Style(relativeSize: relativeSize, color: color(of: samples, darkPaper: darkPaper), weight: weight, design: .sans, alignment: .center)
    }

    /// The weight class of a stroke width over the x-height: under the first threshold regular, then
    /// medium, then semibold, bold above the last (`Calibration.weightThresholds`).
    public static func weight(strokeToXHeight ratio: Double) -> TableGrid.FontWeight {
        let classes: [TableGrid.FontWeight] = [.regular, .medium, .semibold, .bold]
        guard ratio.isFinite else { return .regular }
        let thresholds = Calibration.weightThresholds.prefix(classes.count - 1)
        return thresholds.firstIndex { ratio < $0 }.map { classes[$0] } ?? classes[thresholds.count]
    }

    /// Constants of the measure. The height ratios are SF Pro's own metrics (the font a fill is drawn
    /// in), not an assumption about the table's font; TableVisionTests checks them on macOS against
    /// CoreText renders read back through this estimator.
    public enum Calibration {
        /// Font size / OCR word-box height, for a word whose ink cannot be read.
        public static let boxHeightToFontSize: Double = 1.15
        /// Stroke width / x-height upper bounds of regular, medium and semibold; bold above the last.
        /// The width is 2 × ink area / ink perimeter less `strokeBlur`, which reads bars and curves as well
        /// as stems: renders of Inter (an open SF-like design) at 20 to 44 px read 0.106–0.112 regular,
        /// 0.128–0.134 medium, 0.148–0.155 semibold and 0.168–0.174 bold; the bounds sit in the gaps.
        public static let weightThresholds: [Double] = [0.12, 0.141, 0.1615]
        /// Pixels anti-aliasing adds to a measured stroke width.
        public static let strokeBlur: Double = 0.25
        /// SF Pro: font size / cap height (cap height 0.705 em; digits are as tall).
        public static let capHeightToFontSize: Double = 1 / 0.705
        /// SF Pro: font size / x-height (x-height 0.528 em).
        public static let xHeightToFontSize: Double = 1 / 0.528
    }

    // MARK: Measures

    struct InkSample {
        var luminance: Double
        var red: Double
        var green: Double
        var blue: Double
    }

    struct WordMeasure {
        /// Pixels; nil when the text has no glyph whose height is known.
        var fontSize: Double?
        var strokeRatio: Double?
        var samples: [InkSample]
    }

    /// Whether the words sit on a dark paper (light text): the median luminance of their boxes is dark.
    static func isDarkPaper(boxes: [PSRect], rgba: [UInt8], width: Int, height: Int) -> Bool {
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for box in boxes {
            let rect = pixelRect(box, width: width, height: height, grow: 0)
            guard rect.x1 > rect.x0, rect.y1 > rect.y0 else { continue }
            let step = max(1, (rect.x1 - rect.x0) * (rect.y1 - rect.y0) / 4000)
            var index = 0
            for y in rect.y0..<rect.y1 {
                for x in rect.x0..<rect.x1 {
                    index += 1
                    guard index % step == 0 else { continue }
                    histogram[Int(luminance(rgba, (y * width + x) * 4).rounded()).clamped(0, 255)] += 1
                    total += 1
                }
            }
        }
        guard total > 0 else { return false }
        var seen = 0
        for level in 0..<256 {
            seen += histogram[level]
            if seen * 2 >= total { return level < RulingLineDetector.darkMedian }
        }
        return false
    }

    /// The pixel rect of a normalised box, grown vertically by `grow` × its height.
    static func pixelRect(_ box: PSRect, width: Int, height: Int, grow: Double) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let padY = box.height * grow, padX = box.height * grow * 0.3 * Double(height) / Double(max(1, width))
        let x0 = max(0, Int(((box.minX - padX) * Double(width)).rounded(.down)))
        let x1 = min(width, Int(((box.maxX + padX) * Double(width)).rounded(.up)))
        let y0 = max(0, Int(((box.minY - padY) * Double(height)).rounded(.down)))
        let y1 = min(height, Int(((box.maxY + padY) * Double(height)).rounded(.up)))
        return (x0, y0, x1, y1)
    }

    @inline(__always)
    static func luminance(_ rgba: [UInt8], _ index: Int) -> Double {
        0.2126 * Double(rgba[index]) + 0.7152 * Double(rgba[index + 1]) + 0.0722 * Double(rgba[index + 2])
    }

    static func measure(_ box: PSRect, text: String, rgba: [UInt8], width: Int, height: Int, darkPaper: Bool) -> WordMeasure? {
        let rect = pixelRect(box, width: width, height: height, grow: 0.15)
        let w = rect.x1 - rect.x0, h = rect.y1 - rect.y0
        guard w >= 3, h >= 4 else { return nil }
        var levels = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { levels[y * w + x] = luminance(rgba, ((rect.y0 + y) * width + rect.x0 + x) * 4) }
        }
        // Ink reads as high values either way: light paper is flipped.
        if !darkPaper { for index in levels.indices { levels[index] = 255 - levels[index] } }
        let sorted = levels.sorted()
        let paper = sorted[sorted.count / 10], ink = sorted[sorted.count - 1 - sorted.count / 200]
        guard ink - paper >= 30 else { return nil }
        let coverage = levels.map { value -> Double in
            let share = (value - paper) / (ink - paper)
            return share < 0.08 ? 0 : min(1, share)
        }

        // Glyph heights: the connected ink blobs, each to sub-pixel precision; dots, commas, hyphens and
        // blobs cut by the box edge left out.
        let blobs = glyphs(in: coverage, width: w, height: h)
        let whole = blobs.filter { !$0.touchesEdge }
        let candidates = whole.isEmpty ? blobs : whole
        let tallest = candidates.map(\.height).max() ?? 0
        let bodies = candidates.filter { $0.height >= 0.35 * tallest }
        guard !bodies.isEmpty, tallest > 1 else { return nil }
        let baseline = median(bodies.map(\.bottom))
        let tops = bodies.map(\.top).sorted()
        func top(at share: Double) -> Double { tops[min(tops.count - 1, max(0, Int((share * Double(tops.count - 1)).rounded())))] }

        // The cap height when capitals, digits and ascenders dominate the text, else the x-height, each
        // read in the middle of its own glyphs.
        let classes = glyphClasses(of: text)
        var fontSize: Double?
        if classes.tall + classes.short > 0 {
            let tallShare = Double(classes.tall) / Double(classes.tall + classes.short)
            if classes.short > classes.tall {
                let xHeight = baseline - top(at: tallShare + (1 - tallShare) / 2)
                if xHeight > 1 { fontSize = xHeight * Calibration.xHeightToFontSize }
            } else {
                let capHeight = baseline - top(at: tallShare / 2)
                if capHeight > 1 { fontSize = capHeight * Calibration.capHeightToFontSize }
            }
        }

        // Stroke: 2 × area / perimeter, the perimeter being the total variation of the coverage.
        var area = 0.0, perimeter = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let value = coverage[y * w + x]
                area += value
                if x + 1 < w { perimeter += abs(coverage[y * w + x + 1] - value) }
                if y + 1 < h { perimeter += abs(coverage[(y + 1) * w + x] - value) }
            }
        }
        var strokeRatio: Double?
        if let fontSize, perimeter > 0 {
            let xHeight = fontSize / Calibration.xHeightToFontSize
            // Anti-aliasing widens every stroke by about a quarter pixel whatever the size.
            if xHeight >= 4 { strokeRatio = max(0, 2 * area / perimeter - Calibration.strokeBlur) / xHeight }
        }

        // Colour samples: the pixels mostly covered by ink.
        var samples: [InkSample] = []
        for y in 0..<h {
            for x in 0..<w where coverage[y * w + x] >= 0.5 {
                let index = ((rect.y0 + y) * width + rect.x0 + x) * 4
                samples.append(InkSample(luminance: luminance(rgba, index), red: Double(rgba[index]) / 255,
                                         green: Double(rgba[index + 1]) / 255, blue: Double(rgba[index + 2]) / 255))
            }
        }
        return WordMeasure(fontSize: fontSize, strokeRatio: strokeRatio, samples: samples)
    }

    /// Characters as tall as capitals (capitals, digits, ascenders, most symbols) and x-height letters.
    static func glyphClasses(of text: String) -> (tall: Int, short: Int) {
        var tall = 0, short = 0
        for character in text {
            if character.isNumber || character.isUppercase || "bdfhklt%$#&@?!/\\()[]{}".contains(character) {
                tall += 1
            } else if "acegmnopqrsuvwxyz".contains(character) {
                short += 1
            }
        }
        return (tall, short)
    }

    /// One connected ink blob (8-connected pixels covered at least halfway).
    struct Glyph {
        /// Sub-pixel edges, in pixels from the top of the measured rect.
        var top: Double
        var bottom: Double
        var touchesEdge: Bool
        var height: Double { bottom - top }
    }

    /// The blobs of a coverage map, with their top and bottom edges to sub-pixel precision: an edge in a
    /// partly covered pixel sits at the covered share of it.
    static func glyphs(in coverage: [Double], width: Int, height: Int) -> [Glyph] {
        var label = [Int32](repeating: 0, count: width * height)
        var found: [Glyph] = []
        var stack: [Int] = []
        var next: Int32 = 0
        for start in 0..<(width * height) where coverage[start] >= 0.5 && label[start] == 0 {
            next += 1
            label[start] = next
            stack.append(start)
            var minRow = height, maxRow = -1
            var pixels: [Int] = []
            while let index = stack.popLast() {
                pixels.append(index)
                let x = index % width, y = index / width
                minRow = min(minRow, y)
                maxRow = max(maxRow, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let neighbour = ny * width + nx
                        if label[neighbour] == 0, coverage[neighbour] >= 0.5 {
                            label[neighbour] = next
                            stack.append(neighbour)
                        }
                    }
                }
            }
            var top = Double(minRow), bottom = Double(maxRow + 1)
            var topEdge = Double.infinity, bottomEdge = -Double.infinity
            for index in pixels {
                let y = index / width
                if y == minRow {
                    let above = y > 0 ? coverage[index - width] : 0
                    topEdge = min(topEdge, Double(y) + (1 - coverage[index]) - (above < 0.5 ? above : 0))
                }
                if y == maxRow {
                    let below = y < height - 1 ? coverage[index + width] : 0
                    bottomEdge = max(bottomEdge, Double(y) + coverage[index] + (below < 0.5 ? below : 0))
                }
            }
            if topEdge.isFinite { top = topEdge }
            if bottomEdge.isFinite { bottom = bottomEdge }
            found.append(Glyph(top: top, bottom: bottom, touchesEdge: minRow == 0 || maxRow == height - 1))
        }
        return found
    }

    /// The mean of the darkest 25 % of the ink (the brightest 25 % on a dark paper).
    static func color(of samples: [InkSample], darkPaper: Bool) -> PSColor {
        let ordered = samples.sorted { darkPaper ? $0.luminance > $1.luminance : $0.luminance < $1.luminance }
        let kept = ordered.prefix(max(1, ordered.count / 4))
        let count = Double(kept.count)
        return PSColor(red: kept.map(\.red).reduce(0, +) / count, green: kept.map(\.green).reduce(0, +) / count,
                       blue: kept.map(\.blue).reduce(0, +) / count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

// MARK: - Grid refinement (pure)

/// What the imaging layer adds to `TableGridBuilder.build`: the ink check of the empty cells, the
/// styles and alignments, and a remembered grid's fresh occupancy (contract §6, behaviours 2 to 4).
public enum TableGridRefiner {
    /// An empty cell whose content rect, inset 15 %, has more ink than this share is printed.
    public static let inkThreshold = 0.003
    /// A remembered grid is kept when the fresh one's bounds overlap it at least this much (IoU).
    public static let rememberedOverlap = 0.9

    /// The grid a fill works on, from what `TableGridBuilder.build` found. A `remembered` grid that
    /// matches (the fresh bounds overlap it by `rememberedOverlap`, or nothing was found fresh) comes back
    /// with its geometry, styles and formats, occupancy read again from `words`
    /// (`TableGridBuilder.reoccupied`, which the builder already does when it is given the memory) and
    /// the ink, `source = .remembered`: never nil then. Otherwise the fresh grid, ink-checked and styled
    /// (measured values, else the remembered column styles, else the row labels' style centred).
    public static func refine(fresh: TableGrid?, words: [TableGridBuilder.Word], gray: [UInt8], rgba: [UInt8], width: Int, height: Int,
                              remembered: TableGrid?) -> TableGrid? {
        var found = fresh
        if let remembered, !remembered.dataCells.isEmpty, found?.source != .remembered,
           found.map({ $0.bounds.iou(remembered.bounds) >= rememberedOverlap }) ?? true {
            found = TableGridBuilder.reoccupied(remembered, words: words)
        }
        guard let grid = found else { return nil }
        let checked = inkChecked(grid, gray: gray, width: width, height: height)
        if checked.source == .remembered { return checked }
        return styled(checked, rgba: rgba, width: width, height: height, remembered: remembered)
    }

    /// Share of ink pixels in a normalised rect of a gray picture: pixels darker than the rect's paper
    /// (its 75th percentile) by max(18, 0.1 × the paper), lighter on a dark paper.
    public static func inkCoverage(in rect: PSRect, gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 0, height > 0, gray.count >= width * height else { return 0 }
        let x0 = max(0, Int((rect.minX * Double(width)).rounded())), x1 = min(width, Int((rect.maxX * Double(width)).rounded()))
        let y0 = max(0, Int((rect.minY * Double(height)).rounded())), y1 = min(height, Int((rect.maxY * Double(height)).rounded()))
        guard x1 > x0, y1 > y0 else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for y in y0..<y1 { for x in x0..<x1 { histogram[Int(gray[y * width + x])] += 1 } }
        let total = (x1 - x0) * (y1 - y0)
        func level(at share: Double) -> Int {
            var seen = 0
            for value in 0..<256 {
                seen += histogram[value]
                if Double(seen) >= share * Double(total) { return value }
            }
            return 255
        }
        let median = level(at: 0.5)
        let darkPaper = median < RulingLineDetector.darkMedian
        let paper = darkPaper ? level(at: 0.25) : level(at: 0.75)
        let step = max(RulingLineDetector.minimumContrast, Int(RulingLineDetector.relativeContrast * Double(darkPaper ? 255 - paper : paper)))
        var ink = 0
        for value in 0..<256 where darkPaper ? value - paper >= step : paper - value >= step { ink += histogram[value] }
        return Double(ink) / Double(total)
    }

    /// Each `.empty` data cell whose content rect, inset 15 %, carries ink becomes `.printed` with no text
    /// (OCR missed it); smudges an erase leaves stay under the threshold.
    public static func inkChecked(_ grid: TableGrid, gray: [UInt8], width: Int, height: Int) -> TableGrid {
        var result = grid
        for index in result.cells.indices where result.cells[index].kind == .data && result.cells[index].state == .empty {
            let content = result.cells[index].contentRect
            let inner = content.insetBy(dx: content.width * 0.15, dy: content.height * 0.15)
            if inkCoverage(in: inner, gray: gray, width: width, height: height) > inkThreshold {
                result.cells[index].state = .printed
                result.cells[index].text = ""
            }
        }
        return result
    }

    /// Styles per data column: measured on its printed values (alignment from where they sit in their
    /// cells); else the remembered column's; else the row labels' style, centred. `bodyStyle` is the
    /// median of the column styles. Formats are the builder's.
    public static func styled(_ grid: TableGrid, rgba: [UInt8], width: Int, height: Int, remembered: TableGrid?) -> TableGrid {
        var result = grid
        let dataRowIndices = Set(grid.dataRows.map(\.index))
        let rememberedColumns = remembered?.dataColumns ?? []
        let dataColumns = grid.dataColumns
        var labelStyle: TableGrid.Style??
        func labelsStyle() -> TableGrid.Style? {
            if let measured = labelStyle { return measured }
            let labels = grid.cells.filter { $0.kind == .label && dataRowIndices.contains($0.row) && !$0.wordBoxes.isEmpty }
            let measured = TableStyleEstimator.style(of: labels.flatMap(\.wordBoxes), texts: labels.flatMap { words(of: $0) },
                                                     rgba: rgba, width: width, height: height)
            labelStyle = .some(measured)
            return measured
        }
        var styles: [TableGrid.Style] = []
        for (offset, column) in dataColumns.enumerated() {
            guard let columnIndex = result.columns.firstIndex(where: { $0.index == column.index }) else { continue }
            let values = grid.cells.filter {
                $0.kind == .data && $0.column == column.index && $0.state == .printed && !$0.wordBoxes.isEmpty
                    && !$0.text.isEmpty && !TableGridBuilder.isPlaceholder($0.text)
            }
            var style: TableGrid.Style?
            if !values.isEmpty {
                style = TableStyleEstimator.style(of: values.flatMap(\.wordBoxes), texts: values.flatMap { words(of: $0) },
                                                  rgba: rgba, width: width, height: height)
                if style != nil { style?.alignment = alignment(of: values) }
            }
            if style == nil, rememberedColumns.count == dataColumns.count, offset < rememberedColumns.count {
                style = rememberedColumns[offset].style ?? remembered?.bodyStyle
            }
            if style == nil, var centred = labelsStyle() {
                centred.alignment = .center
                style = centred
            }
            result.columns[columnIndex].style = style
            if let style { styles.append(style) }
        }
        result.bodyStyle = medianStyle(styles) ?? remembered?.bodyStyle
        return result
    }

    /// One text per word box of a cell: its words when they match the boxes one to one, else its whole
    /// text for each box.
    static func words(of cell: TableGrid.Cell) -> [String] {
        let parts = cell.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.count == cell.wordBoxes.count ? parts : Array(repeating: cell.text, count: cell.wordBoxes.count)
    }

    /// Where values sit in their cells: flush left, flush right or centred, by majority.
    public static func alignment(of cells: [TableGrid.Cell]) -> TextElement.Alignment {
        var votes: [TextElement.Alignment: Int] = [:]
        for cell in cells {
            guard let first = cell.wordBoxes.first else { continue }
            let words = cell.wordBoxes.reduce(first) { $0.union($1) }
            let content = cell.contentRect.width > 0 ? cell.contentRect : cell.rect
            guard content.width > 0 else { continue }
            let left = (words.minX - content.minX) / content.width, right = (content.maxX - words.maxX) / content.width
            let vote: TextElement.Alignment = abs(left - right) < 0.15 ? .center : (left < right ? .leading : .trailing)
            votes[vote, default: 0] += 1
        }
        let order: [TextElement.Alignment] = [.center, .leading, .trailing]
        return order.max { votes[$0, default: 0] < votes[$1, default: 0] } ?? .center
    }

    /// The median style: median size and colour channels, the most common weight, design and alignment.
    public static func medianStyle(_ styles: [TableGrid.Style]) -> TableGrid.Style? {
        guard !styles.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double { TableStyleEstimator.median(values) }
        func mostCommon<T: Hashable>(_ values: [T]) -> T {
            var counts: [T: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            var best = values[0]
            for value in values where counts[value, default: 0] > counts[best, default: 0] { best = value }
            return best
        }
        let color = PSColor(red: median(styles.map(\.color.red)), green: median(styles.map(\.color.green)), blue: median(styles.map(\.color.blue)))
        return TableGrid.Style(relativeSize: median(styles.map(\.relativeSize)), color: color, weight: mostCommon(styles.map(\.weight)),
                               design: mostCommon(styles.map(\.design)), alignment: mostCommon(styles.map(\.alignment)))
    }
}

// MARK: - Word bridge (pure)

extension TableGridBuilder.Word {
    /// The builder's word for a Vision word: the same text, box (normalised, top-left), line and confidence.
    public init(_ word: VisionWord) {
        self.init(text: word.text, box: word.box, line: word.line, confidence: word.confidence)
    }
}

// MARK: - Apple part

#if canImport(Vision) && canImport(CoreImage)
/// Vision's words and the picture's pixels through RulingLineDetector, TableGridBuilder and
/// TableGridRefiner (the ink check of the empty cells, the styles, the remembered grid).
public enum TableDetection {
    /// Ruling lines + OCR words -> TableGridBuilder.build -> ink check of empty cells -> styles.
    /// `image` is the analysis image (renderBase at `VisionPhotoServices.textAnalysisLongestSide`) and
    /// `words` its OCR, so every rect is in canvas space (D1).
    ///
    /// - An `.empty` data cell whose content rect, inset 15 %, has more than 0.3 % ink becomes
    ///   `.printed` with text "" (calibrated so inpainting smudges stay empty).
    /// - Styles per column from its printed values, else the remembered style, else the label column's
    ///   words with centre alignment; `bodyStyle` is the median.
    /// - A `remembered` grid that matches (fresh bounds IoU ≥ 0.9, or no fresh grid at all) comes back
    ///   with its geometry, styles and formats and fresh occupancy, `source = .remembered`: never nil then.
    ///
    /// Nil for no table (never throws for that).
    public static func grid(in image: CGImage, words: [VisionWord], remembered: TableGrid?) -> TableGrid? {
        let pixels = Pixels(image)
        let input = self.input(words: words, pixels: pixels, remembered: remembered)
        return TableGridRefiner.refine(fresh: TableGridBuilder.build(input), words: input.words, gray: pixels.gray, rgba: pixels.rgba,
                                       width: pixels.width, height: pixels.height, remembered: remembered)
    }

    /// The gray and RGBA bytes of an analysis image, read once.
    struct Pixels {
        let gray: [UInt8]
        let rgba: [UInt8]
        let width: Int
        let height: Int

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            gray = ImageSupport.grayBytes(from: image)
            rgba = ImageSupport.rgbaBytes(from: image)
        }
    }

    /// What the builder reads for one picture: the words, the ruling lines and bands, the size.
    /// Codable: tests print it as JSON so real-OCR dumps become Linux fixtures (contract §3).
    static func input(words: [VisionWord], pixels: Pixels, remembered: TableGrid?) -> TableGridBuilder.Input {
        let rules = RulingLineDetector.detect(gray: pixels.gray, width: pixels.width, height: pixels.height)
        return TableGridBuilder.Input(words: words.map(TableGridBuilder.Word.init), lines: rules.lines, bands: rules.bands,
                                      imageSize: PSSize(width: Double(pixels.width), height: Double(pixels.height)), remembered: remembered)
    }
}
#endif
