import Foundation
import PicshopCore

/// Builds the scene map (`SceneMap`) from what the imaging layer read on one base state: the OCR words,
/// the detected people, animals and objects, the table, and the pixels. Pure Swift, tested on Linux;
/// `VisionPhotoServices.sceneMap(in:)` feeds it once per `PhotoDocument.baseStateKey`, off the main actor.
///
/// What it gives the model (B renders it into editor_state):
/// - text blocks in reading order (`t1`, `t2`…): a title, a paragraph, a table header or cell, with their
///   box, word boxes, measured style (size and colour classes come from it) and role;
/// - objects largest first (`o1`…), one per thing, with a canonical English label;
/// - the main table (D2), as `tableGrid(in:remembered:)` found it;
/// - free areas (`f1`…): flat stretches with no text and no object, where new text reads well;
/// - the picture's kind and dominant colour.
public enum SceneMapBuilder {
    /// Caps that keep the map cheap to build and short to print.
    public static let maxTexts = 80
    public static let maxObjects = 8
    public static let maxFreeAreas = 4
    /// Word boxes measured per block, at most.
    static let maxMeasuredWords = 12

    /// RGBA pixels of the analysed picture: 4 bytes per pixel, row-major, top row first.
    public struct Bitmap: Sendable {
        public var rgba: [UInt8]
        public var width: Int
        public var height: Int

        public init(rgba: [UInt8], width: Int, height: Int) {
            self.rgba = rgba
            self.width = width
            self.height = height
        }

        public var isValid: Bool { width > 0 && height > 0 && rgba.count >= width * height * 4 }
    }

    /// A coarse grid over the picture: the mean colour and the luminance spread of each tile. Free areas,
    /// the dominant colour and the kind of picture are read from it.
    public struct Tiles: Hashable, Sendable {
        /// A tile whose luminance spread is under this is flat.
        public static let flatSpread = 0.04

        public var columns: Int
        public var rows: Int
        /// Mean colour per tile, row-major.
        public var means: [PSColor]
        /// Standard deviation of the luminance per tile (0…1), row-major.
        public var spreads: [Double]

        public init(columns: Int, rows: Int, means: [PSColor], spreads: [Double]) {
            self.columns = columns
            self.rows = rows
            self.means = means
            self.spreads = spreads
        }

        /// The tiles of a bitmap, sampled on at most 8 × 8 points per tile; nil for a malformed bitmap.
        public init?(bitmap: Bitmap, columns: Int = 24, rows: Int = 24) {
            guard bitmap.isValid else { return nil }
            let columns = max(1, min(columns, bitmap.width)), rows = max(1, min(rows, bitmap.height))
            var means: [PSColor] = []
            var spreads: [Double] = []
            means.reserveCapacity(columns * rows)
            spreads.reserveCapacity(columns * rows)
            for row in 0..<rows {
                let y0 = row * bitmap.height / rows, y1 = max(y0 + 1, (row + 1) * bitmap.height / rows)
                for column in 0..<columns {
                    let x0 = column * bitmap.width / columns, x1 = max(x0 + 1, (column + 1) * bitmap.width / columns)
                    let stepX = max(1, (x1 - x0) / 8), stepY = max(1, (y1 - y0) / 8)
                    var red = 0.0, green = 0.0, blue = 0.0, sum = 0.0, squares = 0.0, count = 0.0
                    for y in stride(from: y0, to: y1, by: stepY) {
                        for x in stride(from: x0, to: x1, by: stepX) {
                            let index = (y * bitmap.width + x) * 4
                            let r = Double(bitmap.rgba[index]) / 255, g = Double(bitmap.rgba[index + 1]) / 255, b = Double(bitmap.rgba[index + 2]) / 255
                            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                            red += r
                            green += g
                            blue += b
                            sum += luminance
                            squares += luminance * luminance
                            count += 1
                        }
                    }
                    let mean = sum / count
                    means.append(PSColor(red: red / count, green: green / count, blue: blue / count))
                    spreads.append(max(0, squares / count - mean * mean).squareRoot())
                }
            }
            self.init(columns: columns, rows: rows, means: means, spreads: spreads)
        }

        /// Normalised rect of one tile (top-left origin).
        public func rect(column: Int, row: Int) -> PSRect {
            let width = 1 / Double(max(1, columns)), height = 1 / Double(max(1, rows))
            return PSRect(x: Double(column) * width, y: Double(row) * height, width: width, height: height)
        }

        /// Share of flat tiles, 0…1.
        public var flatShare: Double {
            spreads.isEmpty ? 0 : Double(spreads.filter { $0 < Self.flatSpread }.count) / Double(spreads.count)
        }
    }

    /// Everything one base state gave.
    public struct Input: Sendable {
        /// `PhotoDocument.baseStateKey` of the analysed state.
        public var stateKey: String
        public var canvasSize: PSSize
        /// OCR of the base picture (normalised, top-left), top line first.
        public var words: [TableGridBuilder.Word]
        /// People, faces, animals and objects; their ids are ignored and given again.
        public var detections: [SceneMap.Object]
        public var table: TableGrid?
        /// The analysed picture, for styles, free areas and the dominant colour; nil leaves them out.
        public var bitmap: Bitmap?

        public init(stateKey: String, canvasSize: PSSize, words: [TableGridBuilder.Word] = [], detections: [SceneMap.Object] = [],
                    table: TableGrid? = nil, bitmap: Bitmap? = nil) {
            self.stateKey = stateKey
            self.canvasSize = canvasSize
            self.words = words
            self.detections = detections
            self.table = table
            self.bitmap = bitmap
        }
    }

    /// The map of one base state. Ids are this state's reading order; callers keep them stable across
    /// versions with `SceneMap.carryingIDs(from:)`.
    public static func build(_ input: Input) -> SceneMap {
        let tiles = input.bitmap.flatMap { Tiles(bitmap: $0) }
        var texts = blocks(from: input.words, table: input.table)
        if let bitmap = input.bitmap { texts = measured(texts, on: bitmap) }
        let found = objects(from: input.detections)
        let occupied = texts.map(\.box) + found.map(\.box) + (input.table.map { [$0.bounds] } ?? [])
        let areas = tiles.map { freeAreas(in: $0, avoiding: occupied) } ?? []
        return SceneMap(stateKey: input.stateKey, canvasSize: input.canvasSize, kind: kind(texts: texts, objects: found, table: input.table, tiles: tiles),
                        texts: texts, objects: found, table: input.table, freeAreas: areas, background: tiles.flatMap { background(of: $0) })
    }

    /// OCR lines grouped into blocks, numbered `t1`…: lines of one paragraph or one multi-line heading
    /// together, with a role (title, heading, body, caption). With a table: one block per column header
    /// (the header's lines together), per row label and per printed cell. Order: the text above the
    /// table in reading order, the table's headers left to right, its row labels top to bottom, the rest
    /// of the text in reading order, then the printed cells row by row, which go first when there are
    /// more than `maxTexts` blocks (the table lines already show them).
    public static func blocks(from words: [TableGridBuilder.Word], table: TableGrid?) -> [SceneMap.TextBlock] {
        let usable = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.box.width > 0 && $0.box.height > 0 }
        var free: [TableGridBuilder.Word] = []
        var headers: [SceneMap.TextBlock] = [], labels: [SceneMap.TextBlock] = [], cells: [SceneMap.TextBlock] = []
        if let table {
            var byCell: [Int: [TableGridBuilder.Word]] = [:]
            for word in usable {
                if let index = table.cells.firstIndex(where: { $0.rect.contains(word.box.center) }) {
                    byCell[index, default: []].append(word)
                } else {
                    free.append(word)
                }
            }
            // Headers: one block per column, every header row together (2-line headers are one name).
            for column in table.columns {
                let parts = table.cells.indices.filter { table.cells[$0].column == column.index && (table.cells[$0].kind == .header || table.cells[$0].kind == .corner) }
                let found = parts.flatMap { byCell[$0] ?? [] }
                guard !found.isEmpty else { continue }
                let text = column.header.isEmpty ? lineText(found) : column.header
                headers.append(block(found, text: text, role: .tableHeader))
            }
            for index in table.cells.indices where table.cells[index].kind == .label {
                guard let found = byCell[index], !found.isEmpty else { continue }
                let row = table.rows.first { $0.index == table.cells[index].row }
                let text = (row?.label.isEmpty == false ? row?.label : nil) ?? lineText(found)
                labels.append(block(found, text: text, role: .tableLabel))
            }
            for index in table.cells.indices where table.cells[index].kind == .data {
                guard let found = byCell[index], !found.isEmpty else { continue }
                let cell = table.cells[index]
                cells.append(block(found, text: cell.text.isEmpty ? lineText(found) : cell.text, role: .tableCell))
            }
        } else {
            free = usable
        }

        let reference = (headers + labels).map { $0.box.height / Double(max(1, $0.lineCount)) }
        var paragraphs = readingOrder(assignRoles(paragraphBlocks(free), tableTitle: table?.title, reference: reference))
        var ordered: [SceneMap.TextBlock]
        if let table {
            let above = paragraphs.filter { $0.box.midY < table.bounds.minY }
            paragraphs.removeAll { $0.box.midY < table.bounds.minY }
            ordered = above + headers + labels.sorted { $0.box.minY < $1.box.minY } + paragraphs
        } else {
            ordered = paragraphs
        }
        ordered = Array(ordered.prefix(maxTexts))
        ordered += cells.prefix(max(0, maxTexts - ordered.count))
        return ordered.enumerated().map { offset, block in
            var numbered = block
            numbered.id = "t\(offset + 1)"
            return numbered
        }
    }

    /// Words of one line, left to right, joined by spaces; lines top to bottom joined by "\n".
    static func lineText(_ words: [TableGridBuilder.Word]) -> String {
        let lines = Dictionary(grouping: words, by: \.line).sorted { $0.key < $1.key }
        return lines.map { $0.value.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    /// A printed block of these words (id given later).
    static func block(_ words: [TableGridBuilder.Word], text: String, role: SceneMap.TextBlock.Role) -> SceneMap.TextBlock {
        let ordered = words.sorted { ($0.line, $0.box.minX) < ($1.line, $1.box.minX) }
        let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
        let lineCount = max(1, Set(ordered.map(\.line)).count)
        let confidence = ordered.map(\.confidence).reduce(0, +) / Double(ordered.count)
        return SceneMap.TextBlock(id: "", text: text, box: box, lineCount: lineCount, wordBoxes: ordered.map(\.box), role: role,
                                  source: .printed, confidence: confidence)
    }

    /// A run of words on one OCR line with no wide gap (a gap over 1.5 word heights splits columns).
    struct Segment {
        var words: [TableGridBuilder.Word]
        var box: PSRect
        var height: Double
    }

    /// Lines split at wide gaps, then stacked into blocks: a segment joins the block above when the gap
    /// is under 0.8 of its height, the heights match within 30 % and the two overlap sideways (or share
    /// their left edge or their centre).
    static func paragraphBlocks(_ words: [TableGridBuilder.Word]) -> [SceneMap.TextBlock] {
        var segments: [Segment] = []
        for (_, lineWords) in Dictionary(grouping: words, by: \.line).sorted(by: { $0.key < $1.key }) {
            let ordered = lineWords.sorted { $0.box.minX < $1.box.minX }
            let height = median(ordered.map(\.box.height))
            var current: [TableGridBuilder.Word] = []
            for word in ordered {
                if let last = current.last, word.box.minX - last.box.maxX > 1.5 * height {
                    segments.append(segment(current))
                    current = []
                }
                current.append(word)
            }
            if !current.isEmpty { segments.append(segment(current)) }
        }
        var groups: [[Segment]] = []
        for candidate in segments.sorted(by: { $0.box.minY < $1.box.minY }) {
            let target = groups.indices.last { index in
                guard let last = groups[index].last else { return false }
                let gap = candidate.box.minY - last.box.maxY
                let ratio = candidate.height / max(1e-9, last.height)
                let sharedWidth = min(candidate.box.maxX, last.box.maxX) - max(candidate.box.minX, last.box.minX)
                let overlaps = sharedWidth > 0.3 * min(candidate.box.width, last.box.width)
                let aligned = abs(candidate.box.minX - last.box.minX) < last.height || abs(candidate.box.midX - last.box.midX) < last.height
                return gap > -0.5 * last.height && gap < 0.8 * candidate.height && ratio > 0.77 && ratio < 1.3 && (overlaps || aligned)
            }
            if let target { groups[target].append(candidate) } else { groups.append([candidate]) }
        }
        return groups.map { group in
            let words = group.flatMap(\.words)
            var made = block(words, text: group.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: "\n"), role: .body)
            made.lineCount = group.count
            return made
        }
    }

    static func segment(_ words: [TableGridBuilder.Word]) -> Segment {
        let box = words.dropFirst().reduce(words[0].box) { $0.union($1.box) }
        return Segment(words: words, box: box, height: median(words.map(\.box.height)))
    }

    /// Roles from the line heights: the tallest short block in the upper half, clearly above the median,
    /// is the title (else the one reading like the table's title); others clearly taller are headings,
    /// clearly smaller ones captions, the rest body. `reference` adds line heights of other text (the
    /// table's headers and labels) to the median, so a lone heading over a table still reads as one.
    static func assignRoles(_ blocks: [SceneMap.TextBlock], tableTitle: String?, reference: [Double] = []) -> [SceneMap.TextBlock] {
        guard !blocks.isEmpty else { return [] }
        func lineHeight(_ block: SceneMap.TextBlock) -> Double { block.box.height / Double(max(1, block.lineCount)) }
        let typical = median(blocks.flatMap { block in Array(repeating: lineHeight(block), count: max(1, block.text.split(separator: " ").count)) } + reference)
        var result = blocks
        for index in result.indices {
            let height = lineHeight(result[index])
            if height >= 1.2 * typical, result[index].lineCount <= 3 { result[index].role = .heading }
            else if height <= 0.8 * typical { result[index].role = .caption }
        }
        let candidates = result.indices.filter { result[$0].box.midY < 0.5 && result[$0].lineCount <= 3 && result[$0].text.split(separator: " ").count <= 12 }
        if let tallest = candidates.max(by: { lineHeight(result[$0]) < lineHeight(result[$1]) }),
           lineHeight(result[tallest]) >= 1.35 * typical || (blocks.count == 1 && lineHeight(result[tallest]) >= 0.04) {
            result[tallest].role = .title
        } else if let tableTitle, !SceneMap.folded(tableTitle).isEmpty,
                  let named = result.indices.first(where: { SceneMap.folded(result[$0].text) == SceneMap.folded(tableTitle) }) {
            result[named].role = .title
        }
        return result
    }

    /// Top to bottom, then left to right: blocks whose middles fall inside one band read left to right.
    static func readingOrder(_ blocks: [SceneMap.TextBlock]) -> [SceneMap.TextBlock] {
        var rest = blocks.sorted { $0.box.minY < $1.box.minY }
        var ordered: [SceneMap.TextBlock] = []
        while let first = rest.first {
            var band = [first]
            var bottom = first.box.maxY
            rest.removeFirst()
            while let next = rest.first, next.box.midY < bottom {
                band.append(next)
                bottom = max(bottom, min(next.box.maxY, bottom + next.box.height * 0.2))
                rest.removeFirst()
            }
            ordered += band.sorted { $0.box.minX < $1.box.minX }
        }
        return ordered
    }

    /// The blocks with their typography measured on the pixels (TableStyleEstimator per block, the
    /// alignment from the lines' edges); a block that cannot be measured keeps a nil style.
    public static func measured(_ blocks: [SceneMap.TextBlock], on bitmap: Bitmap) -> [SceneMap.TextBlock] {
        guard bitmap.isValid else { return blocks }
        return blocks.map { block in
            guard !block.isLayer, !block.wordBoxes.isEmpty else { return block }
            var words = block.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var boxes = block.wordBoxes
            if words.count != boxes.count { words = Array(repeating: block.text, count: boxes.count) }
            // A long paragraph: a dozen of its words, spread over it, tell its style as well as all of them.
            if boxes.count > maxMeasuredWords {
                let picked = (0..<maxMeasuredWords).map { $0 * boxes.count / maxMeasuredWords }
                boxes = picked.map { boxes[$0] }
                words = picked.map { words[$0] }
            }
            guard var style = TableStyleEstimator.style(of: boxes, texts: words, rgba: bitmap.rgba, width: bitmap.width, height: bitmap.height)
            else { return block }
            style.alignment = alignment(of: block)
            var measured = block
            measured.style = style
            return measured
        }
    }

    /// Alignment of a block: from its lines' edges when it has several (the steadiest of left edges,
    /// centres and right edges), else from where it sits on the picture.
    static func alignment(of block: SceneMap.TextBlock) -> TextElement.Alignment {
        var lines: [PSRect] = []
        for box in block.wordBoxes.sorted(by: { $0.minY < $1.minY }) {
            if let index = lines.firstIndex(where: { box.midY > $0.minY && box.midY < $0.maxY }) { lines[index] = lines[index].union(box) }
            else { lines.append(box) }
        }
        if lines.count >= 2 {
            func spread(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
            let left = spread(lines.map(\.minX)), centre = spread(lines.map(\.midX)), right = spread(lines.map(\.maxX))
            if centre < left * 0.7 && centre <= right { return .center }
            return right < left * 0.7 ? .trailing : .leading
        }
        if abs(block.box.midX - 0.5) < 0.03 { return .center }
        return block.box.minX > 0.5 && block.box.maxX > 0.9 ? .trailing : .leading
    }

    /// One object per thing, numbered `o1`… largest first: detections under 0.3 confidence or specks
    /// dropped, and a thing two detectors saw (IoU > 0.6, same label or kind) kept once, the surer one.
    public static func objects(from detections: [SceneMap.Object], limit: Int = maxObjects) -> [SceneMap.Object] {
        var kept: [SceneMap.Object] = []
        for detection in detections.filter({ $0.confidence >= 0.3 && $0.box.area > 0.0004 }).sorted(by: { $0.confidence > $1.confidence }) {
            let seen = kept.contains { $0.box.iou(detection.box) > 0.6 && ($0.label == detection.label || $0.kind == detection.kind) }
            if !seen { kept.append(detection) }
        }
        return kept.sorted { $0.box.area > $1.box.area }.prefix(max(0, limit)).enumerated().map { offset, object in
            var numbered = object
            numbered.id = "o\(offset + 1)"
            return numbered
        }
    }

    /// Flat stretches (unions of flat tiles of one colour) clear of every `occupied` rect, largest first
    /// then numbered `f1`… in reading order, each with the colour behind it. At most `limit`; each at
    /// least 2 × 2 tiles and 2 % of the picture.
    public static func freeAreas(in tiles: Tiles, avoiding occupied: [PSRect], limit: Int = maxFreeAreas) -> [SceneMap.FreeArea] {
        let count = tiles.columns * tiles.rows
        guard limit > 0, count > 0, tiles.means.count >= count, tiles.spreads.count >= count else { return [] }
        let blocked = occupied.map { $0.insetBy(dx: -0.01, dy: -0.01) }
        var free = (0..<count).map { index -> Bool in
            let rect = tiles.rect(column: index % tiles.columns, row: index / tiles.columns)
            return tiles.spreads[index] < Tiles.flatSpread && !blocked.contains { $0.intersection(rect).area > 0 }
        }
        // Colour families of the free tiles: a tile joins the first family whose seed is close.
        var seeds: [PSColor] = []
        var family = [Int](repeating: -1, count: count)
        for index in 0..<count where free[index] {
            let color = tiles.means[index]
            if let known = seeds.firstIndex(where: { distance($0, color) < 0.06 }) { family[index] = known }
            else { seeds.append(color); family[index] = seeds.count - 1 }
        }
        let tileArea = 1 / Double(count)
        var found: [(rect: (column: Int, row: Int, width: Int, height: Int), family: Int)] = []
        while found.count < limit {
            var best: (column: Int, row: Int, width: Int, height: Int, family: Int)?
            for seed in seeds.indices {
                let mask = (0..<count).map { free[$0] && family[$0] == seed }
                if let rect = largestRectangle(mask, columns: tiles.columns, rows: tiles.rows),
                   rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0) {
                    best = (rect.column, rect.row, rect.width, rect.height, seed)
                }
            }
            guard let best, best.width >= 2, best.height >= 2, Double(best.width * best.height) * tileArea >= 0.02 else { break }
            found.append((rect: (column: best.column, row: best.row, width: best.width, height: best.height), family: best.family))
            for row in best.row..<(best.row + best.height) {
                for column in best.column..<(best.column + best.width) { free[row * tiles.columns + column] = false }
            }
        }
        let areas = found.map { item -> SceneMap.FreeArea in
            let r = item.rect
            let first = tiles.rect(column: r.column, row: r.row), last = tiles.rect(column: r.column + r.width - 1, row: r.row + r.height - 1)
            var indices: [Int] = []
            for row in r.row..<(r.row + r.height) { for column in r.column..<(r.column + r.width) { indices.append(row * tiles.columns + column) } }
            let colors = indices.map { tiles.means[$0] }
            let n = Double(colors.count)
            let mean = PSColor(red: colors.map(\.red).reduce(0, +) / n, green: colors.map(\.green).reduce(0, +) / n, blue: colors.map(\.blue).reduce(0, +) / n)
            let uniform = indices.allSatisfy { tiles.spreads[$0] < Tiles.flatSpread / 2 } && colors.allSatisfy { distance($0, mean) < 0.04 }
            return SceneMap.FreeArea(id: "", box: first.union(last), background: mean, isUniform: uniform)
        }
        let ordered = areas.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        return ordered.enumerated().map { offset, area in
            var numbered = area
            numbered.id = "f\(offset + 1)"
            return numbered
        }
    }

    /// The largest all-true rectangle of a row-major mask (histogram method), in tiles.
    static func largestRectangle(_ mask: [Bool], columns: Int, rows: Int) -> (column: Int, row: Int, width: Int, height: Int)? {
        var heights = [Int](repeating: 0, count: columns)
        var best: (column: Int, row: Int, width: Int, height: Int)?
        for row in 0..<rows {
            for column in 0..<columns { heights[column] = mask[row * columns + column] ? heights[column] + 1 : 0 }
            var stack: [Int] = []
            for column in 0...columns {
                let height = column < columns ? heights[column] : 0
                while let top = stack.last, heights[top] >= height {
                    stack.removeLast()
                    let barHeight = heights[top]
                    let left = (stack.last ?? -1) + 1
                    let width = column - left
                    if barHeight > 0, barHeight * width > (best.map { $0.width * $0.height } ?? 0) {
                        best = (left, row - barHeight + 1, width, barHeight)
                    }
                }
                stack.append(column)
            }
        }
        return best
    }

    static func distance(_ a: PSColor, _ b: PSColor) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// What the picture is: a table screenshot when the table covers it (D2); a screenshot when a status
    /// bar shows (a clock in the top strip) or when flat tiles dominate around a little printed text; a
    /// document when a light flat page carries a lot of text; else a photo (people make it a photo).
    public static func kind(texts: [SceneMap.TextBlock], objects: [SceneMap.Object], table: TableGrid?, tiles: Tiles?) -> SceneMap.Kind {
        if table?.coversPicture == true { return .table }
        let printed = texts.filter { !$0.isLayer }
        let statusBar = printed.contains { block in
            block.box.maxY < 0.06 && block.text.split(separator: " ").contains { isClock(String($0)) }
        }
        if statusBar { return .screenshot }
        guard let tiles else { return .photo }
        let people = objects.contains { $0.kind == .person || $0.kind == .face }
        let flat = tiles.flatShare
        let textArea = printed.reduce(0) { $0 + $1.box.area }
        let words = printed.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
        let light = background(of: tiles).map { $0.luminance > 0.85 } ?? false
        if !people, flat >= 0.6, light, words >= 40 || textArea >= 0.15 { return .document }
        if table != nil || (!people && flat >= 0.55 && printed.count >= 3) { return .screenshot }
        return .photo
    }

    /// "9:41", "14h05", "09.30".
    static func isClock(_ token: String) -> Bool {
        let parts = token.split(whereSeparator: { $0 == ":" || $0 == "h" || $0 == "." }).map(String.init)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), parts[1].count == 2 else { return false }
        return (0...23).contains(hours) && (0...59).contains(minutes)
    }

    /// The dominant colour: the median of the flat tiles when at least a tenth of the picture is flat.
    public static func background(of tiles: Tiles) -> PSColor? {
        let flat = tiles.means.indices.filter { $0 < tiles.spreads.count && tiles.spreads[$0] < Tiles.flatSpread }.map { tiles.means[$0] }
        guard !flat.isEmpty, Double(flat.count) >= 0.1 * Double(tiles.means.count) else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return PSColor(red: median(flat.map(\.red)), green: median(flat.map(\.green)), blue: median(flat.map(\.blue)))
    }
}
