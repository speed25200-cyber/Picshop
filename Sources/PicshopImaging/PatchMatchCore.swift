import Foundation

/// Pure-Swift PatchMatch inpainting core. Platform independent so it can be
/// unit-tested anywhere; the Core Image pipeline wraps it on Apple platforms.
public enum PatchMatchCore {
    struct Level {
        var width: Int
        var height: Int
        /// Planar RGB, 0…1.
        var r: [Float]
        var g: [Float]
        var b: [Float]
        /// true where content must be synthesised.
        var hole: [Bool]
    }

    public static func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int, patchRadius: Int = 3, iterationsPerLevel: [Int] = [6, 5, 4, 3, 3, 2]) -> [UInt8] {
        // Unpack.
        var base = Level(width: width, height: height, r: [Float](repeating: 0, count: width * height), g: [Float](repeating: 0, count: width * height),
                         b: [Float](repeating: 0, count: width * height), hole: [Bool](repeating: false, count: width * height))
        for index in 0..<(width * height) {
            base.r[index] = Float(rgba[index * 4]) / 255
            base.g[index] = Float(rgba[index * 4 + 1]) / 255
            base.b[index] = Float(rgba[index * 4 + 2]) / 255
            base.hole[index] = mask[index] > 127
        }
        guard base.hole.contains(true) else { return rgba }

        // Pyramid.
        var levels = [base]
        while let last = levels.last, min(last.width, last.height) > 48, levels.count < iterationsPerLevel.count {
            levels.append(downsample(last))
        }

        // Coarsest: diffusion initialisation (also kept as the smooth "structure" prior).
        var coarse = levels[levels.count - 1]
        diffuseFill(&coarse, iterations: 200)
        let prior = coarse
        var nnf: [Int32] = []
        solve(&coarse, nnf: &nnf, patchRadius: min(patchRadius, 2), iterations: iterationsPerLevel[min(levels.count - 1, iterationsPerLevel.count - 1)])
        var previous = coarse
        var previousNNF = nnf

        for levelIndex in stride(from: levels.count - 2, through: 0, by: -1) {
            var current = levels[levelIndex]
            upsampleFill(from: previous, into: &current)
            var currentNNF = upsampleNNF(previousNNF, from: previous, to: current)
            let iterations = iterationsPerLevel[min(levelIndex, iterationsPerLevel.count - 1)]
            solve(&current, nnf: &currentNNF, patchRadius: patchRadius, iterations: iterations)
            previous = current
            previousNNF = currentNNF
        }

        // Structure/texture fusion: where the surroundings are smooth (gradients, sky, skin),
        // patch copying alone drifts in colour, so we transfer the smooth prior's low frequencies.
        fuseWithPrior(&previous, prior: prior)

        var output = rgba
        for index in 0..<(width * height) where base.hole[index] {
            output[index * 4] = UInt8(max(0, min(255, (previous.r[index] * 255).rounded())))
            output[index * 4 + 1] = UInt8(max(0, min(255, (previous.g[index] * 255).rounded())))
            output[index * 4 + 2] = UInt8(max(0, min(255, (previous.b[index] * 255).rounded())))
            output[index * 4 + 3] = 255
        }
        return output
    }

    // MARK: Structure / texture fusion

    static func fuseWithPrior(_ level: inout Level, prior: Level) {
        let w = level.width, h = level.height
        let count = w * h
        // Ring of known pixels around the hole to measure local smoothness.
        let ringRadius = 6
        var ring = [Bool](repeating: false, count: count)
        var holeMinX = w, holeMaxX = 0, holeMinY = h, holeMaxY = 0
        for y in 0..<h {
            for x in 0..<w where level.hole[y * w + x] {
                holeMinX = min(holeMinX, x); holeMaxX = max(holeMaxX, x)
                holeMinY = min(holeMinY, y); holeMaxY = max(holeMaxY, y)
                for dy in -ringRadius...ringRadius {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -ringRadius...ringRadius {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let ni = ny * w + nx
                        if !level.hole[ni] { ring[ni] = true }
                    }
                }
            }
        }
        // Texture energy = mean |Laplacian| of luminance over the ring. A linear gradient
        // or a flat sky scores ≈ 0; grass, fabric or foliage score high.
        func luma(_ i: Int) -> Float { 0.299 * level.r[i] + 0.587 * level.g[i] + 0.114 * level.b[i] }
        var laplacianSum: Float = 0
        var ringCount: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard ring[i], !level.hole[i - 1], !level.hole[i + 1], !level.hole[i - w], !level.hole[i + w] else { continue }
                let lap = abs(luma(i - 1) + luma(i + 1) + luma(i - w) + luma(i + w) - 4 * luma(i))
                laplacianSum += lap
                ringCount += 1
            }
        }
        guard ringCount > 4 else { return }
        let energy = laplacianSum / ringCount
        // Smooth surroundings (energy ≈ 0.01) → strong fusion; textured (energy > 0.06) → none.
        let weight = max(0, min(1, (0.06 - energy) / 0.05))
        guard weight > 0.01 else { return }

        // Upsample the prior into the hole, then low-pass the patch result with a box filter
        // sized to the hole and swap its low frequencies for the prior's.
        var smooth = level
        upsampleFill(from: prior, into: &smooth)
        let radius = max(3, min(holeMaxX - holeMinX, holeMaxY - holeMinY) / 6)
        let lowR = boxBlur(level.r, width: w, height: h, radius: radius)
        let lowG = boxBlur(level.g, width: w, height: h, radius: radius)
        let lowB = boxBlur(level.b, width: w, height: h, radius: radius)
        for i in 0..<count where level.hole[i] {
            level.r[i] = max(0, min(1, level.r[i] + weight * (smooth.r[i] - lowR[i])))
            level.g[i] = max(0, min(1, level.g[i] + weight * (smooth.g[i] - lowG[i])))
            level.b[i] = max(0, min(1, level.b[i] + weight * (smooth.b[i] - lowB[i])))
        }
    }

    static func boxBlur(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return input }
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            var n = 0
            for x in 0...min(radius, width - 1) { sum += input[row + x]; n += 1 }
            for x in 0..<width {
                horizontal[row + x] = sum / Float(n)
                let add = x + radius + 1
                if add < width { sum += input[row + add]; n += 1 }
                let remove = x - radius
                if remove >= 0 { sum -= input[row + remove]; n -= 1 }
            }
        }
        var out = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            var n = 0
            for y in 0...min(radius, height - 1) { sum += horizontal[y * width + x]; n += 1 }
            for y in 0..<height {
                out[y * width + x] = sum / Float(n)
                let add = y + radius + 1
                if add < height { sum += horizontal[add * width + x]; n += 1 }
                let remove = y - radius
                if remove >= 0 { sum -= horizontal[remove * width + x]; n -= 1 }
            }
        }
        return out
    }

    // MARK: Pyramid

    static func downsample(_ level: Level) -> Level {
        let w = max(1, level.width / 2)
        let h = max(1, level.height / 2)
        var out = Level(width: w, height: h, r: [Float](repeating: 0, count: w * h), g: [Float](repeating: 0, count: w * h), b: [Float](repeating: 0, count: w * h), hole: [Bool](repeating: false, count: w * h))
        for y in 0..<h {
            for x in 0..<w {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0
                var known = 0
                var holes = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sx = min(level.width - 1, x * 2 + dx)
                        let sy = min(level.height - 1, y * 2 + dy)
                        let si = sy * level.width + sx
                        if level.hole[si] {
                            holes += 1
                        } else {
                            sr += level.r[si]; sg += level.g[si]; sb += level.b[si]
                            known += 1
                        }
                    }
                }
                let oi = y * w + x
                if known > 0 {
                    out.r[oi] = sr / Float(known); out.g[oi] = sg / Float(known); out.b[oi] = sb / Float(known)
                }
                out.hole[oi] = holes >= 2 || known == 0
            }
        }
        return out
    }

    /// Fills holes by repeatedly averaging known/estimated neighbours (smooth prior).
    static func diffuseFill(_ level: inout Level, iterations: Int) {
        let w = level.width, h = level.height
        // Seed with the mean of known pixels.
        var mr: Float = 0, mg: Float = 0, mb: Float = 0
        var count = 0
        for i in 0..<(w * h) where !level.hole[i] { mr += level.r[i]; mg += level.g[i]; mb += level.b[i]; count += 1 }
        if count > 0 { mr /= Float(count); mg /= Float(count); mb /= Float(count) }
        for i in 0..<(w * h) where level.hole[i] { level.r[i] = mr; level.g[i] = mg; level.b[i] = mb }
        for _ in 0..<iterations {
            var changed = false
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard level.hole[i] else { continue }
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0
                    var n: Float = 0
                    if x > 0 { sr += level.r[i - 1]; sg += level.g[i - 1]; sb += level.b[i - 1]; n += 1 }
                    if x < w - 1 { sr += level.r[i + 1]; sg += level.g[i + 1]; sb += level.b[i + 1]; n += 1 }
                    if y > 0 { sr += level.r[i - w]; sg += level.g[i - w]; sb += level.b[i - w]; n += 1 }
                    if y < h - 1 { sr += level.r[i + w]; sg += level.g[i + w]; sb += level.b[i + w]; n += 1 }
                    if n > 0 {
                        let nr = sr / n, ng = sg / n, nb = sb / n
                        if abs(nr - level.r[i]) > 0.0005 || abs(ng - level.g[i]) > 0.0005 || abs(nb - level.b[i]) > 0.0005 { changed = true }
                        level.r[i] = nr; level.g[i] = ng; level.b[i] = nb
                    }
                }
            }
            if !changed { break }
        }
    }

    static func upsampleFill(from coarse: Level, into fine: inout Level) {
        let fw = fine.width, fh = fine.height
        let cw = coarse.width, ch = coarse.height
        for y in 0..<fh {
            let sy = min(Float(ch - 1), Float(y) * Float(ch) / Float(fh))
            let y0 = Int(sy), y1 = min(ch - 1, y0 + 1)
            let ty = sy - Float(y0)
            for x in 0..<fw {
                let i = y * fw + x
                guard fine.hole[i] else { continue }
                let sx = min(Float(cw - 1), Float(x) * Float(cw) / Float(fw))
                let x0 = Int(sx), x1 = min(cw - 1, x0 + 1)
                let tx = sx - Float(x0)
                func lerp(_ a: [Float]) -> Float {
                    let top = a[y0 * cw + x0] * (1 - tx) + a[y0 * cw + x1] * tx
                    let bottom = a[y1 * cw + x0] * (1 - tx) + a[y1 * cw + x1] * tx
                    return top * (1 - ty) + bottom * ty
                }
                fine.r[i] = lerp(coarse.r)
                fine.g[i] = lerp(coarse.g)
                fine.b[i] = lerp(coarse.b)
            }
        }
    }

    static func upsampleNNF(_ coarseNNF: [Int32], from coarse: Level, to fine: Level) -> [Int32] {
        var out = [Int32](repeating: -1, count: fine.width * fine.height)
        guard coarseNNF.count == coarse.width * coarse.height else { return out }
        for y in 0..<fine.height {
            let cy = min(coarse.height - 1, y / 2)
            for x in 0..<fine.width {
                let cx = min(coarse.width - 1, x / 2)
                let source = coarseNNF[cy * coarse.width + cx]
                guard source >= 0 else { continue }
                let sx = Int(source) % coarse.width
                let sy = Int(source) / coarse.width
                let fx = min(fine.width - 1, sx * 2 + (x & 1))
                let fy = min(fine.height - 1, sy * 2 + (y & 1))
                out[y * fine.width + x] = Int32(fy * fine.width + fx)
            }
        }
        return out
    }

    // MARK: PatchMatch

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func nextInt(_ bound: Int) -> Int {
            bound <= 1 ? 0 : Int(next() % UInt64(bound))
        }
    }

    /// Runs PatchMatch on one level, updating hole pixels in place.
    static func solve(_ level: inout Level, nnf: inout [Int32], patchRadius: Int, iterations: Int) {
        let w = level.width, h = level.height
        let count = w * h
        let radius = patchRadius

        // Target pixels: hole dilated by the patch radius (patches straddling the hole boundary drive the reconstruction).
        var target = [Bool](repeating: false, count: count)
        for y in 0..<h {
            for x in 0..<w where level.hole[y * w + x] {
                for dy in -radius...radius {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -radius...radius {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        target[ny * w + nx] = true
                    }
                }
            }
        }
        // Valid source centres: full patch inside the image and free of hole pixels.
        var validSource = [Bool](repeating: false, count: count)
        var sourceList: [Int32] = []
        sourceList.reserveCapacity(count / 2)
        for y in radius..<(h - radius) {
            for x in radius..<(w - radius) {
                var ok = true
                outer: for dy in -radius...radius {
                    for dx in -radius...radius where level.hole[(y + dy) * w + (x + dx)] {
                        ok = false
                        break outer
                    }
                }
                if ok {
                    validSource[y * w + x] = true
                    sourceList.append(Int32(y * w + x))
                }
            }
        }
        guard !sourceList.isEmpty else { return }

        if nnf.count != count { nnf = [Int32](repeating: -1, count: count) }
        var distances = [Float](repeating: .greatestFiniteMagnitude, count: count)
        var rng = RNG(state: 0x9E3779B97F4A7C15)

        // Initialise invalid entries randomly.
        for i in 0..<count where target[i] {
            if nnf[i] < 0 || !validSource[Int(nnf[i])] {
                nnf[i] = sourceList[rng.nextInt(sourceList.count)]
            }
        }

        func patchDistance(_ level: Level, _ t: Int, _ s: Int, bound: Float) -> Float {
            let tx = t % w, ty = t / w
            let sx = s % w, sy = s / w
            var sum: Float = 0
            var samples: Float = 0
            for dy in -radius...radius {
                let tyy = ty + dy
                let syy = sy + dy
                guard tyy >= 0, tyy < h else { continue }
                let trow = tyy * w
                let srow = syy * w
                for dx in -radius...radius {
                    let txx = tx + dx
                    guard txx >= 0, txx < w else { continue }
                    let ti = trow + txx
                    let si = srow + sx + dx
                    let dr = level.r[ti] - level.r[si]
                    let dg = level.g[ti] - level.g[si]
                    let db = level.b[ti] - level.b[si]
                    // Known pixels weigh more than current estimates inside the hole.
                    let weight: Float = level.hole[ti] ? 0.6 : 1
                    sum += (dr * dr + dg * dg + db * db) * weight
                    samples += weight
                }
                if sum > bound * max(1, samples / Float((2 * radius + 1) * (2 * radius + 1))) * 1.5 { return .greatestFiniteMagnitude }
            }
            return samples > 0 ? sum / samples : .greatestFiniteMagnitude
        }

        for iteration in 0..<iterations {
            // Recompute distances against the current estimate.
            for i in 0..<count where target[i] {
                distances[i] = patchDistance(level, i, Int(nnf[i]), bound: .greatestFiniteMagnitude)
            }
            let forward = iteration % 2 == 0
            // Propagation (sequential scan) + random search.
            let ys = forward ? Array(0..<h) : Array((0..<h).reversed())
            let xs = forward ? Array(0..<w) : Array((0..<w).reversed())
            let step = forward ? -1 : 1
            for y in ys {
                for x in xs {
                    let i = y * w + x
                    guard target[i] else { continue }
                    var best = Int(nnf[i])
                    var bestDistance = distances[i]
                    // Propagate from the scan-order neighbours.
                    let nx = x + step
                    if nx >= 0, nx < w, target[i + step] {
                        let candidate = Int(nnf[i + step]) - step
                        if candidate >= 0, candidate < count, validSource[candidate] {
                            let d = patchDistance(level, i, candidate, bound: bestDistance)
                            if d < bestDistance { bestDistance = d; best = candidate }
                        }
                    }
                    let ny = y + step
                    if ny >= 0, ny < h, target[i + step * w] {
                        let candidate = Int(nnf[i + step * w]) - step * w
                        if candidate >= 0, candidate < count, validSource[candidate] {
                            let d = patchDistance(level, i, candidate, bound: bestDistance)
                            if d < bestDistance { bestDistance = d; best = candidate }
                        }
                    }
                    // Random search around the current best with exponentially shrinking radius.
                    var searchRadius = max(w, h)
                    let bx = best % w, by = best / w
                    while searchRadius >= 1 {
                        let cx = bx + rng.nextInt(2 * searchRadius + 1) - searchRadius
                        let cy = by + rng.nextInt(2 * searchRadius + 1) - searchRadius
                        if cx >= radius, cx < w - radius, cy >= radius, cy < h - radius {
                            let candidate = cy * w + cx
                            if validSource[candidate] {
                                let d = patchDistance(level, i, candidate, bound: bestDistance)
                                if d < bestDistance { bestDistance = d; best = candidate }
                            }
                        }
                        searchRadius /= 2
                    }
                    nnf[i] = Int32(best)
                    distances[i] = bestDistance
                }
            }
            // Vote: every target patch casts its source pixels onto the hole pixels it covers.
            var accR = [Float](repeating: 0, count: count)
            var accG = [Float](repeating: 0, count: count)
            var accB = [Float](repeating: 0, count: count)
            var accW = [Float](repeating: 0, count: count)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard target[i] else { continue }
                    let s = Int(nnf[i])
                    let sx = s % w, sy = s / w
                    let weight = 1 / (1 + distances[i] * 40)
                    for dy in -radius...radius {
                        let py = y + dy
                        guard py >= 0, py < h else { continue }
                        for dx in -radius...radius {
                            let px = x + dx
                            guard px >= 0, px < w else { continue }
                            let pi = py * w + px
                            guard level.hole[pi] else { continue }
                            let si = (sy + dy) * w + (sx + dx)
                            accR[pi] += level.r[si] * weight
                            accG[pi] += level.g[si] * weight
                            accB[pi] += level.b[si] * weight
                            accW[pi] += weight
                        }
                    }
                }
            }
            for i in 0..<count where level.hole[i] && accW[i] > 0 {
                level.r[i] = accR[i] / accW[i]
                level.g[i] = accG[i] / accW[i]
                level.b[i] = accB[i] / accW[i]
            }
        }
    }
}
