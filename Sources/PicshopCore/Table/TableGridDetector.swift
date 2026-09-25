import Foundation

// The detection behind `TableGridBuilder.build`: pure geometry on OCR words, ruling lines and bands.
// It works in pixels of the analysed image, so gaps and text heights compare whatever the aspect ratio.
//
// One pass tries every text row as the lowest header line and keeps the hypothesis with the most body
// rows. Body rows come from the ruling lines when there are some, else from the values, else from the
// row labels alone (a table whose values were all erased); columns come from the values when there
// are some, else from the header phrases. So "rules + anchors", "anchors only" and "values" are three
// outcomes of one search rather than three code paths.

extension TableGridBuilder {
    struct Detector {
        struct PixelWord {
            var text: String
            var box: PSRect
            /// Visual text row (see `rows`).
            var row: Int = 0
        }

        /// Words of one visual row close enough to read as one run ("Gemini 3.5 Pro").
        struct Phrase {
            var words: [Int]
            var text: String
            var box: PSRect
            var row: Int
        }

        struct TextRow {
            var phrases: [Int]
            var box: PSRect
        }

        struct Rule {
            var position: Double
            var start: Double
            var end: Double
        }

        /// One body row: the label lines and the value phrases it holds.
        struct Block {
            var labels: [Int]
            var minY: Double
            var maxY: Double
            var midY: Double { (minY + maxY) / 2 }
        }

        /// A data column: where its content is, and its header phrases.
        struct ColumnSpan {
            var minX: Double
            var maxX: Double
            /// Where a value goes: the values' median centre, else the header's centre.
            var contentMidX: Double
            var headerPhrases: [Int]
            var hasValues: Bool
        }

        let size: PSSize
        var words: [PixelWord]
        var phrases: [Phrase] = []
        var rows: [TextRow] = []
        let lineHeight: Double
        let horizontal: [Rule]
        let vertical: [Rule]
        let bandEdges: [Double]
        /// Phrases left-aligned on one edge, top to bottom: the row labels (and whatever else sits on that edge).
        var labelStack: [Int] = []
        var labelMinX: Double?
        let tolerance: Double

        init?(_ input: Input) {
            let size = PSSize(width: max(1, input.imageSize.width), height: max(1, input.imageSize.height))
            self.size = size
            var words: [PixelWord] = input.words.compactMap { word in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, word.box.width > 0, word.box.height > 0, word.confidence >= 0.2 else { return nil }
                return PixelWord(text: text, box: word.box.clampedToUnit().denormalized(in: size))
            }
            guard words.count >= 4 else { return nil }

            // Visual rows: words sorted by centre, joined when they overlap vertically by half the smaller height.
            var wordRows: [(members: [Int], minY: Double, maxY: Double)] = []
            for index in words.indices.sorted(by: { words[$0].box.midY < words[$1].box.midY }) {
                let box = words[index].box
                var placed = false
                for candidate in stride(from: wordRows.count - 1, through: max(0, wordRows.count - 3), by: -1) {
                    let row = wordRows[candidate]
                    let overlap = min(row.maxY, box.maxY) - max(row.minY, box.minY)
                    if overlap >= 0.5 * min(row.maxY - row.minY, box.height) {
                        let count = Double(row.members.count)
                        wordRows[candidate] = (row.members + [index], (row.minY * count + box.minY) / (count + 1), (row.maxY * count + box.maxY) / (count + 1))
                        placed = true
                        break
                    }
                }
                if !placed { wordRows.append(([index], box.minY, box.maxY)) }
            }
            wordRows.sort { ($0.minY + $0.maxY) < ($1.minY + $1.maxY) }

            // Phrases: a row cut wherever the gap between two words is wider than about one text height.
            var phrases: [Phrase] = []
            var rows: [TextRow] = []
            for (rowIndex, row) in wordRows.enumerated() {
                let members = row.members.sorted { words[$0].box.minX < words[$1].box.minX }
                var current: [Int] = []
                var rowPhrases: [Int] = []
                func flush() {
                    guard let first = current.first else { return }
                    let box = current.dropFirst().reduce(words[first].box) { $0.union(words[$1].box) }
                    phrases.append(Phrase(words: current, text: current.map { words[$0].text }.joined(separator: " "), box: box, row: rowIndex))
                    rowPhrases.append(phrases.count - 1)
                    current = []
                }
                for index in members {
                    words[index].row = rowIndex
                    if let last = current.last {
                        let a = words[last].box, b = words[index].box
                        if b.minX - a.maxX > 0.9 * (a.height + b.height) / 2 { flush() }
                    }
                    current.append(index)
                }
                flush()
                let box = rowPhrases.dropFirst().reduce(phrases[rowPhrases[0]].box) { $0.union(phrases[$1].box) }
                rows.append(TextRow(phrases: rowPhrases, box: box))
            }
            self.words = words
            self.phrases = phrases
            self.rows = rows
            let heights = phrases.map(\.box.height).sorted()
            let lineHeight = max(1, heights[heights.count / 2])
            self.lineHeight = lineHeight
            tolerance = max(0.6 * lineHeight, 0.004 * size.width)

            // Rules in pixels; lines closer than a third of a text height are one rule (double or thick rules).
            func merged(_ lines: [RulingLine], along: Double, across: Double) -> [Rule] {
                var rules: [Rule] = []
                for line in lines.sorted(by: { $0.position < $1.position }) {
                    let rule = Rule(position: line.position * across, start: min(line.start, line.end) * along, end: max(line.start, line.end) * along)
                    if let last = rules.last, rule.position - last.position <= max(3, 0.35 * lineHeight) {
                        rules[rules.count - 1] = Rule(position: (last.position + rule.position) / 2, start: min(last.start, rule.start), end: max(last.end, rule.end))
                    } else {
                        rules.append(rule)
                    }
                }
                return rules
            }
            horizontal = merged(input.lines.filter { $0.axis == .horizontal }, along: size.width, across: size.height)
            vertical = merged(input.lines.filter { $0.axis == .vertical }, along: size.height, across: size.width)
            bandEdges = input.bands.filter { $0.axis == .horizontal }.flatMap { [$0.start * size.height, $0.end * size.height] }.sorted()

            // The label stack: the largest group of phrases sharing a left edge; among near ties, the leftmost.
            var clusters: [[Int]] = []
            for index in phrases.indices.sorted(by: { phrases[$0].box.minX < phrases[$1].box.minX }) {
                if let anchor = clusters.last?.first, phrases[index].box.minX - phrases[anchor].box.minX <= tolerance {
                    clusters[clusters.count - 1].append(index)
                } else {
                    clusters.append([index])
                }
            }
            let counted = clusters.map { cluster in (cluster, Set(cluster.map { phrases[$0].row }).count) }.filter { $0.1 >= 2 }
            if let most = counted.map(\.1).max(),
               let chosen = counted.first(where: { Double($0.1) >= 0.8 * Double(most) })?.0 {
                let valueLike = chosen.filter { Self.isValueLike(phrases[$0].text) }.count
                // A stack of numbers is a left-aligned data column, not the row labels.
                if Double(valueLike) < 0.6 * Double(chosen.count) {
                    labelStack = chosen.sorted { phrases[$0].box.minY < phrases[$1].box.minY }
                    labelMinX = chosen.map { phrases[$0].box.minX }.min()
                }
            }
        }

        // MARK: Search

        func grid() -> TableGrid? {
            var best: (grid: TableGrid, headerY: Double)?
            for row in rows.indices {
                guard let candidate = hypothesis(headerRow: row), candidate.confidence >= 0.5 else { continue }
                if let current = best {
                    let a = candidate.dataRows.count, b = current.grid.dataRows.count
                    if a < b { continue }
                    if a == b {
                        let cellsA = candidate.dataCells.count, cellsB = current.grid.dataCells.count
                        if cellsA < cellsB { continue }
                        if cellsA == cellsB, candidate.confidence < current.grid.confidence - 0.02 { continue }
                        if cellsA == cellsB, abs(candidate.confidence - current.grid.confidence) <= 0.02, rows[row].box.minY < current.headerY { continue }
                    }
                }
                best = (candidate, rows[row].box.minY)
            }
            return best?.grid
        }

        /// The table whose lowest header line is `rows[b]`, or nil when that reading does not hold.
        func hypothesis(headerRow b: Int) -> TableGrid? {
            let h = lineHeight
            let header = rows[b]
            guard header.box.height <= 1.8 * h else { return nil }
            let labelSet = Set(labelStack)
            // A row label right above this line means the line cuts through a row: it is a line of values.
            if labelStack.contains(where: { phrases[$0].row < b && phrases[$0].box.maxY > header.box.minY - 1.5 * h }) { return nil }
            let labelsBelow = labelStack.filter { phrases[$0].row > b && phrases[$0].box.minY >= header.box.maxY - 0.25 * h }
            let labelEdge: Double? = labelsBelow.isEmpty ? nil : Self.percentile(labelsBelow.map { phrases[$0].box.maxX }, 0.8)
            let seeds = header.phrases.filter { index in
                let phrase = phrases[index]
                if labelSet.contains(index) { return false }
                if let labelMinX, !labelsBelow.isEmpty, phrase.box.minX <= labelMinX + tolerance { return false }
                if let labelEdge, phrase.box.midX <= labelEdge { return false }
                return true
            }.sorted { phrases[$0].box.minX < phrases[$1].box.minX }
            guard let firstSeed = seeds.first else { return nil }
            let spanLeft = labelsBelow.isEmpty ? phrases[firstSeed].box.minX : (labelMinX ?? phrases[firstSeed].box.minX)
            let spanRight = seeds.map { phrases[$0].box.maxX }.max() ?? phrases[firstSeed].box.maxX
            guard spanRight > spanLeft else { return nil }
            let rules = horizontal.filter { rule in
                rule.position > header.box.midY
                    && (min(rule.end, spanRight) - max(rule.start, spanLeft)) >= 0.6 * (spanRight - spanLeft)
            }

            // Body rows.
            var blocks: [Block]
            let labelled = labelsBelow.count >= 2
            if labelled {
                blocks = labelBlocks(labelsBelow, rules: rules, header: b, left: labelEdge ?? spanLeft, right: spanRight)
            } else {
                blocks = valueBlocks(below: b, left: spanLeft - h, right: spanRight + h)
            }
            // The table stops at a label running across the columns (a footnote, a paragraph) and at a
            // gap much wider than the usual row pitch.
            let seedMid = phrases[firstSeed].box.midX
            if labelled, let cut = blocks.firstIndex(where: { block in block.labels.contains { phrases[$0].box.maxX > seedMid } }) {
                blocks.removeSubrange(cut...)
            }
            let pitches: [Double] = Self.pitches(blocks)
            if let pitch = Self.median(pitches) {
                let limit = max(2.5 * pitch, 3 * h)
                var cut: Int?
                for index in blocks.indices.dropFirst() where blocks[index].minY - blocks[index - 1].maxY > limit {
                    cut = index
                    break
                }
                if let cut { blocks.removeSubrange(cut...) }
            }
            guard blocks.count >= 2, let firstBlock = blocks.first, let lastBlock = blocks.last else { return nil }
            let pitch = Self.median(Self.pitches(blocks)) ?? 2 * h
            guard firstBlock.minY - header.box.maxY <= max(3 * pitch, 4 * h) else { return nil }

            // Row edges: a rule between two rows when there is one, else the middle of the gap.
            let gaps = zip(blocks, blocks.dropFirst()).map { max(0, $1.minY - $0.maxY) }
            let usualGap = Self.median(gaps) ?? h
            var ruleEdges = 0
            func edge(between top: Double, and bottom: Double, prefer: Double) -> Double {
                let lo = top - 0.25 * h, hi = bottom + 0.25 * h
                if let rule = rules.filter({ $0.position >= lo && $0.position <= hi }).min(by: { abs($0.position - prefer) < abs($1.position - prefer) }) {
                    ruleEdges += 1
                    return rule.position
                }
                if rules.isEmpty, let band = bandEdges.filter({ $0 >= lo && $0 <= hi }).min(by: { abs($0 - prefer) < abs($1 - prefer) }) { return band }
                return (top + bottom) / 2
            }
            var edges: [Double] = [edge(between: header.box.maxY, and: firstBlock.minY, prefer: firstBlock.minY)]
            for (upper, lower) in zip(blocks, blocks.dropFirst()) {
                edges.append(edge(between: upper.maxY, and: lower.minY, prefer: (upper.maxY + lower.minY) / 2))
            }
            let below = rules.filter { $0.position >= lastBlock.maxY - 0.25 * h && $0.position <= lastBlock.maxY + max(pitch, 2 * h) }
                .min { $0.position < $1.position }
            if below != nil { ruleEdges += 1 }
            edges.append(below?.position ?? lastBlock.maxY + max(usualGap / 2, 0.4 * h))
            let bodyTop = edges[0], bodyBottom = edges[edges.count - 1]

            // Values: what sits in the body right of the labels.
            let blockLabels = Set(blocks.flatMap(\.labels))
            let values = phrases.indices.filter { index in
                let phrase = phrases[index]
                guard !blockLabels.contains(index), phrase.row > b, phrase.box.midY > bodyTop, phrase.box.midY < bodyBottom else { return false }
                if let labelEdge, labelled { return phrase.box.midX > labelEdge }
                return phrase.box.midX > spanLeft - h && phrase.box.midX < spanRight + 3 * h
            }
            guard var spans = columnSpans(seeds: seeds, values: values, blocks: blocks, edges: edges) else { return nil }
            spans.sort { $0.minX < $1.minX }

            // Header lines stacked above: close, no taller, every phrase within one column or in the corner.
            var headerRows = [b]
            var headerTop = header.box.minY
            var above = b - 1
            while above >= 0 {
                let line = rows[above]
                guard headerTop - line.box.maxY <= 1.2 * h, line.box.height <= 1.45 * max(h, header.box.height) else { break }
                let fits = line.phrases.allSatisfy { index in
                    let box = phrases[index].box
                    if box.maxX <= spans[0].minX - 0.25 * h, labelled || box.maxX < spans[0].minX { return true }
                    return spans.filter { span in
                        let overlap = min(box.maxX, span.maxX + 0.5 * h) - max(box.minX, span.minX - 0.5 * h)
                        return overlap >= 0.3 * box.width
                    }.count == 1
                }
                guard fits else { break }
                headerRows.insert(above, at: 0)
                headerTop = line.box.minY
                above -= 1
            }

            // Column edges.
            let gutters = zip(spans, spans.dropFirst()).map { $1.minX - $0.maxX }.filter { $0 > 0 }
            let gutter = max(h, Self.median(gutters) ?? 2 * h)
            let labelRight = blocks.flatMap(\.labels).map { phrases[$0].box.maxX }.max()
            var columnEdges: [Double] = []
            // The first data column is as wide as its neighbour's pitch, centred on its values, so values
            // centred in their cells read as centred and a fill lands in the middle; the labels only move
            // the edge when they would reach into that cell.
            let symmetricLeft = spans.count >= 2 ? spans[0].contentMidX - (spans[1].contentMidX - spans[0].contentMidX) / 2 : nil
            if labelled, let labelRight {
                if let symmetricLeft, symmetricLeft > labelRight, symmetricLeft <= spans[0].minX {
                    columnEdges.append(symmetricLeft)
                } else {
                    columnEdges.append(labelRight < spans[0].minX ? (labelRight + spans[0].minX) / 2 : spans[0].minX - 0.25 * gutter)
                }
            } else if spans.count >= 2 {
                columnEdges.append(min(spans[0].minX - 0.25 * gutter, spans[0].contentMidX - (spans[1].contentMidX - spans[0].contentMidX) / 2))
            } else {
                columnEdges.append(spans[0].minX - gutter / 2)
            }
            for (left, right) in zip(spans, spans.dropFirst()) {
                columnEdges.append(left.maxX < right.minX ? (left.maxX + right.minX) / 2 : (left.contentMidX + right.contentMidX) / 2)
            }
            if spans.count >= 2 {
                let last = spans[spans.count - 1], previous = spans[spans.count - 2]
                columnEdges.append(max(last.maxX + 0.25 * gutter, last.contentMidX + (last.contentMidX - previous.contentMidX) / 2))
            } else {
                columnEdges.append(spans[0].maxX + gutter / 2)
            }
            var tableLeft = labelled ? (labelMinX ?? spanLeft) - 0.5 * h : columnEdges[0]
            // Rules and vertical lines are the true edges when they are close.
            let usedRules = rules.filter { $0.position >= bodyTop - 0.5 * h && $0.position <= bodyBottom + 0.5 * h }
            if usedRules.count >= 2, let start = Self.median(usedRules.map(\.start)), let end = Self.median(usedRules.map(\.end)) {
                if start < tableLeft, tableLeft - start < 4 * h { tableLeft = start }
                let lastEdge = columnEdges[columnEdges.count - 1]
                let lastWidth = lastEdge - columnEdges[columnEdges.count - 2]
                if abs(end - lastEdge) < 0.5 * lastWidth { columnEdges[columnEdges.count - 1] = end }
            }
            let bodyHeight = bodyBottom - bodyTop
            let crossing = vertical.filter { rule in min(rule.end, bodyBottom) - max(rule.start, bodyTop) >= 0.5 * bodyHeight }
            if crossing.count >= 2 {
                for position in crossing.map(\.position) {
                    let all = (labelled ? [tableLeft] : []) + columnEdges
                    guard let nearest = all.indices.min(by: { abs(all[$0] - position) < abs(all[$1] - position) }) else { continue }
                    let neighbour = nearest + 1 < all.count ? all[nearest + 1] - all[nearest] : all[nearest] - all[max(0, nearest - 1)]
                    guard abs(all[nearest] - position) <= 0.35 * abs(neighbour) else { continue }
                    if labelled, nearest == 0 { tableLeft = position } else { columnEdges[nearest - (labelled ? 1 : 0)] = position }
                }
            }
            guard zip(columnEdges, columnEdges.dropFirst()).allSatisfy({ $1 > $0 }), !labelled || columnEdges[0] > tableLeft else { return nil }
            let tableRight = columnEdges[columnEdges.count - 1]

            // Header row: from the top header line (or the rule right above it) down to the body.
            var headerEdge = headerTop - 0.5 * h
            if let rule = horizontal.filter({ $0.position < headerTop && $0.position >= headerTop - 1.5 * h }).max(by: { $0.position < $1.position }) {
                headerEdge = rule.position
            }
            headerEdge = max(0, headerEdge)
            guard bodyTop > headerEdge else { return nil }

            // Title: the line right above the header, when it is near and over the table.
            var title: String?
            if above >= 0 {
                let line = rows[above]
                let overlap = min(line.box.maxX, tableRight) - max(line.box.minX, tableLeft)
                if headerTop - line.box.maxY <= 6 * h, overlap > 0 {
                    title = line.phrases.map { phrases[$0].text }.joined(separator: " ")
                }
            }

            return assemble(labelled: labelled, tableLeft: tableLeft, columnEdges: columnEdges, spans: spans, headerEdge: headerEdge,
                            edges: edges, blocks: blocks, headerRows: headerRows, values: values, title: title,
                            ruleEdges: ruleEdges, verticalRules: crossing.count)
        }

        // MARK: Rows

        /// Body rows from the row labels: grouped by the rules, else by the value bands, else by the gaps
        /// between label lines (a label on two lines is one row).
        func labelBlocks(_ labels: [Int], rules: [Rule], header: Int, left: Double, right: Double) -> [Block] {
            let h = lineHeight
            let ordered = labels.sorted { phrases[$0].box.minY < phrases[$1].box.minY }
            func block(_ members: [Int]) -> Block {
                Block(labels: members, minY: members.map { phrases[$0].box.minY }.min() ?? 0, maxY: members.map { phrases[$0].box.maxY }.max() ?? 0)
            }
            let bodyRules = rules.filter { $0.position > phrases[ordered[0]].box.minY - 2 * h }
            if bodyRules.count >= 2 {
                var groups: [Int: [Int]] = [:]
                for label in ordered {
                    let interval = bodyRules.filter { $0.position < phrases[label].box.midY }.count
                    groups[interval, default: []].append(label)
                }
                let blocks = groups.keys.sorted().map { block(groups[$0]!) }
                // Rules between rows: no rule interval holds two labels a whole row apart.
                let perRow = blocks.allSatisfy { block in
                    zip(block.labels, block.labels.dropFirst()).allSatisfy { phrases[$1].box.minY - phrases[$0].box.maxY < 1.4 * h }
                }
                if perRow, blocks.count >= 2 { return blocks }
            }
            // Value bands: text rows right of the labels, below the header.
            let labelSet = Set(labels)
            var bands: [(minY: Double, maxY: Double)] = []
            for (index, row) in rows.enumerated() where index > header {
                let inside = row.phrases.filter { !labelSet.contains($0) && phrases[$0].box.midX > left && phrases[$0].box.minX < right + 2 * h }
                guard let first = inside.first else { continue }
                let box = inside.dropFirst().reduce(phrases[first].box) { $0.union(phrases[$1].box) }
                bands.append((box.minY, box.maxY))
            }
            if bands.count >= 2 {
                var blocks: [Block] = []
                var bandOf: [Int: Int] = [:]
                for label in ordered {
                    let box = phrases[label].box
                    if let band = bands.indices.first(where: { bands[$0].minY < box.maxY + 0.3 * h && bands[$0].maxY > box.minY - 0.3 * h }) {
                        if let existing = bandOf[band] {
                            blocks[existing].labels.append(label)
                            blocks[existing].maxY = max(blocks[existing].maxY, box.maxY)
                            blocks[existing].minY = min(blocks[existing].minY, box.minY)
                        } else {
                            bandOf[band] = blocks.count
                            blocks.append(block([label]))
                        }
                    } else if let last = blocks.last, box.minY - last.maxY < 1.3 * h,
                              box.height <= 1.05 * (last.labels.last.map { phrases[$0].box.height } ?? box.height) {
                        // A sub-line under a label ("SWE-bench Verified").
                        blocks[blocks.count - 1].labels.append(label)
                        blocks[blocks.count - 1].maxY = max(last.maxY, box.maxY)
                    } else {
                        blocks.append(block([label]))
                    }
                }
                return blocks
            }
            // Label lines only: gaps that fall in two clear groups mean labels on several lines.
            let gaps = zip(ordered, ordered.dropFirst()).map { max(0, phrases[$1].box.minY - phrases[$0].box.maxY) }
            let threshold = Self.splitThreshold(gaps, lineHeight: h)
            var blocks: [Block] = []
            for (offset, label) in ordered.enumerated() {
                if offset > 0, let threshold, gaps[offset - 1] < threshold {
                    blocks[blocks.count - 1].labels.append(label)
                    blocks[blocks.count - 1].maxY = max(blocks[blocks.count - 1].maxY, phrases[label].box.maxY)
                } else {
                    blocks.append(block([label]))
                }
            }
            return blocks
        }

        /// Body rows with no label column: every text row under the header with something in the columns.
        func valueBlocks(below header: Int, left: Double, right: Double) -> [Block] {
            var blocks: [Block] = []
            for (index, row) in rows.enumerated() where index > header {
                let inside = row.phrases.filter { phrases[$0].box.midX >= left && phrases[$0].box.midX <= right }
                guard let first = inside.first else { continue }
                let box = inside.dropFirst().reduce(phrases[first].box) { $0.union(phrases[$1].box) }
                blocks.append(Block(labels: [], minY: box.minY, maxY: box.maxY))
            }
            return blocks
        }

        // MARK: Columns

        /// Data columns from the values when at least two columns of them exist (header phrases attach to
        /// the column under them; a header over several value columns is split word by word), else from
        /// the header phrases.
        func columnSpans(seeds: [Int], values: [Int], blocks: [Block], edges: [Double]) -> [ColumnSpan]? {
            let h = lineHeight
            func block(of phrase: Int) -> Int? {
                let y = phrases[phrase].box.midY
                for index in edges.indices.dropFirst() where y >= edges[index - 1] && y < edges[index] { return index - 1 }
                return nil
            }
            var clusters: [(minX: Double, maxX: Double, members: [Int])] = []
            for index in values.sorted(by: { phrases[$0].box.minX < phrases[$1].box.minX }) {
                let box = phrases[index].box
                if let last = clusters.last, box.minX <= last.maxX + 0.25 * h {
                    clusters[clusters.count - 1] = (last.minX, max(last.maxX, box.maxX), last.members + [index])
                } else {
                    clusters.append((box.minX, box.maxX, [index]))
                }
            }
            let needed = blocks.count <= 2 ? 1 : 2
            let valueColumns = clusters.filter { Set($0.members.compactMap(block(of:))).count >= needed }
            var spans: [ColumnSpan]
            if valueColumns.count >= 2 {
                spans = valueColumns.map { cluster in
                    ColumnSpan(minX: cluster.minX, maxX: cluster.maxX, contentMidX: Self.median(cluster.members.map { phrases[$0].box.midX }) ?? (cluster.minX + cluster.maxX) / 2,
                               headerPhrases: [], hasValues: true)
                }
                for seed in seeds {
                    let box = phrases[seed].box
                    let overlapping = spans.indices.filter { min(box.maxX, spans[$0].maxX + 0.5 * h) - max(box.minX, spans[$0].minX - 0.5 * h) > 0 }
                    if overlapping.count == 1 {
                        let index = overlapping[0]
                        spans[index].headerPhrases.append(seed)
                        spans[index].minX = min(spans[index].minX, box.minX)
                        spans[index].maxX = max(spans[index].maxX, box.maxX)
                    } else if overlapping.isEmpty {
                        spans.append(ColumnSpan(minX: box.minX, maxX: box.maxX, contentMidX: box.midX, headerPhrases: [seed], hasValues: false))
                    } else {
                        // One run over several value columns: each column keeps the header words above it.
                        for index in overlapping { spans[index].headerPhrases.append(seed) }
                    }
                }
            } else {
                spans = seeds.map { seed in
                    let box = phrases[seed].box
                    return ColumnSpan(minX: box.minX, maxX: box.maxX, contentMidX: box.midX, headerPhrases: [seed], hasValues: false)
                }
                // Values under a header make its content centre.
                for index in spans.indices {
                    let under = values.filter { phrases[$0].box.midX >= spans[index].minX - 0.5 * h && phrases[$0].box.midX <= spans[index].maxX + 0.5 * h }
                    if !under.isEmpty {
                        spans[index].hasValues = true
                        spans[index].contentMidX = Self.median(under.map { phrases[$0].box.midX }) ?? spans[index].contentMidX
                    }
                }
            }
            spans.sort { $0.minX < $1.minX }
            // Spans that overlap are one column.
            var merged: [ColumnSpan] = []
            for span in spans {
                if let last = merged.last, span.minX < last.maxX - 0.25 * h {
                    merged[merged.count - 1].maxX = max(last.maxX, span.maxX)
                    merged[merged.count - 1].headerPhrases += span.headerPhrases
                    merged[merged.count - 1].hasValues = last.hasValues || span.hasValues
                } else {
                    merged.append(span)
                }
            }
            return merged.isEmpty ? nil : merged
        }

        // MARK: Assembly

        func assemble(labelled: Bool, tableLeft: Double, columnEdges: [Double], spans: [ColumnSpan], headerEdge: Double, edges: [Double],
                      blocks: [Block], headerRows: [Int], values: [Int], title: String?, ruleEdges: Int, verticalRules: Int) -> TableGrid? {
            func normalized(_ rect: PSRect) -> PSRect { rect.normalized(in: size).clampedToUnit() }
            let top = headerEdge, bottom = edges[edges.count - 1]
            let right = columnEdges[columnEdges.count - 1]
            let left = labelled ? tableLeft : columnEdges[0]

            var columnRects: [PSRect] = []
            if labelled { columnRects.append(PSRect(x: tableLeft, y: top, width: columnEdges[0] - tableLeft, height: bottom - top)) }
            for (x0, x1) in zip(columnEdges, columnEdges.dropFirst()) { columnRects.append(PSRect(x: x0, y: top, width: x1 - x0, height: bottom - top)) }
            var rowRects = [PSRect(x: left, y: top, width: right - left, height: edges[0] - top)]
            for (y0, y1) in zip(edges, edges.dropFirst()) { rowRects.append(PSRect(x: left, y: y0, width: right - left, height: y1 - y0)) }
            guard rowRects.allSatisfy({ $0.height > 0 }), columnRects.allSatisfy({ $0.width > 0 }) else { return nil }

            // Words to cells by their centre.
            let labelColumns = labelled ? 1 : 0
            var members: [[Int]] = Array(repeating: [], count: rowRects.count * columnRects.count)
            for (index, word) in words.enumerated() {
                let center = word.box.center
                guard center.x >= left, center.x < right, center.y >= top, center.y < bottom else { continue }
                guard let r = rowRects.firstIndex(where: { center.y >= $0.minY && center.y < $0.maxY }),
                      let c = columnRects.firstIndex(where: { center.x >= $0.minX && center.x < $0.maxX }) else { continue }
                // Nothing above the header lines (a title close over it) belongs to the header cells.
                if r == 0, word.row < (headerRows.first ?? 0) { continue }
                members[r * columnRects.count + c].append(index)
            }
            func text(_ list: [Int], lineBreaks: Bool) -> String {
                let ordered = list.sorted { words[$0].row == words[$1].row ? words[$0].box.minX < words[$1].box.minX : words[$0].row < words[$1].row }
                var lines: [[String]] = []
                var lastRow: Int?
                for index in ordered {
                    if lastRow == words[index].row { lines[lines.count - 1].append(words[index].text) } else { lines.append([words[index].text]) }
                    lastRow = words[index].row
                }
                return lines.map { $0.joined(separator: " ") }.joined(separator: lineBreaks ? "\n" : " ")
            }

            var rowsOut: [TableGrid.Row] = []
            var columnsOut: [TableGrid.Column] = []
            for (c, rect) in columnRects.enumerated() {
                let isLabel = c < labelColumns
                columnsOut.append(TableGrid.Column(index: c, rect: normalized(rect), header: text(members[c], lineBreaks: false), isLabel: isLabel))
            }
            for (r, rect) in rowRects.enumerated() {
                let label = r == 0 || !labelled ? "" : text(members[r * columnRects.count], lineBreaks: true)
                rowsOut.append(TableGrid.Row(index: r, rect: normalized(rect), label: label, isHeader: r == 0))
            }
            var cells: [TableGrid.Cell] = []
            var printedData = 0
            for (r, rowRect) in rowRects.enumerated() {
                for (c, columnRect) in columnRects.enumerated() {
                    let rect = PSRect(x: columnRect.minX, y: rowRect.minY, width: columnRect.width, height: rowRect.height)
                    let kind: TableGrid.CellKind
                    switch (r == 0, c < labelColumns) {
                    case (true, true): kind = .corner
                    case (true, false): kind = .header
                    case (false, true): kind = .label
                    case (false, false): kind = .data
                    }
                    var content = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.12)
                    if kind == .data {
                        // A value goes where the column's values (or its header) are centred, mid-row.
                        let span = spans[c - labelColumns]
                        let width = rect.width * 0.84, height = rect.height * 0.76
                        let x = (span.contentMidX - width / 2).clamped(to: rect.minX...max(rect.minX, rect.maxX - width))
                        content = PSRect(x: x, y: rect.midY - height / 2, width: width, height: height)
                    }
                    let list = members[r * columnRects.count + c]
                    let written = text(list, lineBreaks: kind == .label)
                    var state: TableGrid.CellState = written.isEmpty ? .empty : .printed
                    if kind == .data, !written.isEmpty {
                        if TableGridBuilder.isPlaceholder(written) { state = .placeholder } else { printedData += 1 }
                    }
                    cells.append(TableGrid.Cell(row: r, column: c, rect: normalized(rect), contentRect: normalized(content), text: written,
                                                wordBoxes: list.map { normalized(words[$0].box) }, kind: kind, state: state))
                }
            }
            // Number formats per data column.
            for index in columnsOut.indices where !columnsOut[index].isLabel {
                let texts = cells.filter { $0.column == index && $0.kind == .data && $0.state == .printed }.map(\.text)
                columnsOut[index].format = texts.isEmpty ? nil : TableGrid.NumberFormat.infer(from: texts)
            }

            // Validity (D8) and confidence.
            let dataRows = rowRects.count - 1, dataColumns = columnRects.count - labelColumns
            guard dataRows >= 2, dataColumns >= 2 || (dataColumns == 1 && verticalRules >= 2) else { return nil }
            let headers = columnsOut.filter { !$0.isLabel }.map(\.header)
            guard headers.contains(where: { !$0.isEmpty }) else { return nil }
            let data = cells.filter { $0.kind == .data }
            // A first row of words over rows of numbers (or of nothing) is the real header: this reading is off by one.
            let hasLetters: (TableGrid.Cell) -> Bool = { cell in cell.text.contains { $0.isLetter } && !Self.isValueLike(cell.text) }
            let firstRow = data.filter { $0.row == 1 }
            let laterRows = data.filter { $0.row > 1 }
            if firstRow.filter(hasLetters).count >= 2, !laterRows.contains(where: hasLetters) { return nil }
            // Values running across two columns are not table values.
            var crossing = 0
            for index in values {
                let box = phrases[index].box
                let hits = columnRects.filter { rect in min(box.maxX, rect.maxX) - max(box.minX, rect.minX) >= 0.25 * box.width }.count
                if hits >= 2 { crossing += 1 }
            }
            let crossingShare = values.isEmpty ? 0 : Double(crossing) / Double(values.count)
            guard crossingShare <= 0.25 else { return nil }

            var confidence = 0.55
            if dataRows >= 3 { confidence += 0.1 }
            if dataRows >= 5 { confidence += 0.05 }
            if dataColumns >= 3 { confidence += 0.1 }
            if ruleEdges * 2 >= edges.count || verticalRules >= 2 { confidence += 0.1 }
            if printedData * 2 >= data.count { confidence += 0.1 }
            let pitches = Self.pitches(blocks)
            if let mean = pitches.isEmpty ? nil : pitches.reduce(0, +) / Double(pitches.count), mean > 0 {
                let spread = sqrt(pitches.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(pitches.count)) / mean
                if spread < 0.25 { confidence += 0.05 } else if spread > 0.6 { confidence -= 0.1 }
            }
            confidence -= 0.8 * crossingShare
            confidence = min(0.99, max(0, confidence))

            let ruling: TableGrid.Ruling
            switch (ruleEdges >= 2, verticalRules >= 2) {
            case (true, true): ruling = .full
            case (true, false): ruling = .horizontal
            case (false, true): ruling = .vertical
            case (false, false): ruling = .none
            }
            let bounds = normalized(PSRect(x: left, y: top, width: right - left, height: bottom - top))
            let anyValues = spans.contains(where: \.hasValues)
            return TableGrid(id: TableGrid.makeID(bounds: bounds, rows: rowsOut, columns: columnsOut), bounds: bounds, title: title,
                             rows: rowsOut, columns: columnsOut, cells: cells, headerRowCount: 1, labelColumnCount: labelColumns,
                             ruling: ruling, bodyStyle: nil, confidence: confidence, source: !labelled && anyValues ? .values : .detected)
        }

        // MARK: Helpers

        /// "80.9%", "-3", "1,234.5", "$12", "—": a value, not a word.
        static func isValueLike(_ text: String) -> Bool {
            if TableGridBuilder.isPlaceholder(text) { return true }
            var digits = 0
            for character in text {
                if character.isNumber { digits += 1; continue }
                if "%.,+-−–$€£¥×x ".contains(character) { continue }
                return false
            }
            return digits > 0
        }

        /// Distances between the centres of consecutive rows.
        static func pitches(_ blocks: [Block]) -> [Double] {
            blocks.indices.dropFirst().map { blocks[$0].midY - blocks[$0 - 1].midY }
        }

        static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }

        static func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))]
        }

        /// The gap between "inside a row" and "between rows" when the gaps fall in two clear groups
        /// (the larger at least twice the smaller); nil when they are all alike.
        static func splitThreshold(_ gaps: [Double], lineHeight: Double) -> Double? {
            let sorted = gaps.sorted()
            guard sorted.count >= 2 else { return nil }
            var bestRatio = 1.0
            var split: (small: Double, large: Double)?
            for (small, large) in zip(sorted, sorted.dropFirst()) {
                let ratio = large / max(small, 0.05 * lineHeight)
                if ratio > bestRatio {
                    bestRatio = ratio
                    split = (small, large)
                }
            }
            // Lines of one label sit at most about a line apart.
            guard bestRatio >= 2, let split, split.small <= 1.3 * lineHeight else { return nil }
            return (split.small + split.large) / 2
        }
    }
}
