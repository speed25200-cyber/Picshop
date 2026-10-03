#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore

/// The ground of Home, Settings, sheets and onboarding: colour taken from the
/// user's latest picture, held still, with a little grain.
///
/// Bottom to top:
/// 1. `psBase`;
/// 2. a static 4 × 4 MeshGradient (perceptual) from `PSPalette`, darker towards
///    the bottom (not in the calm style);
/// 3. a top light (white 6 %, 5 % in the calm style), warmed by the palette's glow;
/// 4. a vignette;
/// 5. the grain tile (3 %, 2.5 % in the calm style).
///
/// Nothing animates at rest: no TimelineView, no drift, so Home costs no frames
/// when idle. The mesh moves with the scroll at a quarter of its speed (a
/// transform on a layer drawn once) and cross-fades over 1.2 s when the palette
/// changes. At thermal `.minimal`, and with Reduce Transparency, it is flat `psBase`.
struct PSBackdrop: View {
    enum Style {
        /// Home: the palette mesh, parallax, top light, vignette, grain.
        case home
        /// Settings, Help, sheets: top light and grain on the base, no mesh.
        case calm
        /// Onboarding: the mesh without parallax.
        case onboarding
    }

    let palette: PSPalette?
    var style: Style = .home
    var scrollOffset: CGFloat = 0

    @Environment(\.psEffects) private var effects
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(palette: PSPalette?, style: Style = .home, scrollOffset: CGFloat = 0) {
        self.palette = palette
        self.style = style
        self.scrollOffset = scrollOffset
    }

    /// The mesh follows the content at a quarter of its speed and eases to 60 % after 400 points.
    static func parallax(for offset: CGFloat) -> (offset: CGFloat, opacity: Double) {
        let travelled = max(0, offset)
        return (-0.25 * travelled, 1 - 0.4 * Double(min(1, travelled / 400)))
    }

    var body: some View {
        if effects == .minimal || reduceTransparency {
            Color.psBase
                .accessibilityHidden(true)
        } else {
            let shown = palette ?? .fallback
            let parallax = style == .home ? Self.parallax(for: scrollOffset) : (offset: 0, opacity: 1)
            ZStack {
                Color.psBase
                if style != .calm {
                    // A new palette is a new layer: the old one fades out under it.
                    PSBackdropMesh(palette: shown)
                        .id(shown)
                        .transition(.opacity)
                        .opacity(parallax.opacity)
                        .offset(y: parallax.offset)
                }
                PSTopLight(glow: Color(psColor: shown.glow), amount: style == .calm ? 0.05 : 0.06)
                    .id(shown.glow)
                    .transition(.opacity)
                    .offset(y: style == .home ? parallax.offset : 0)
                if style != .calm {
                    PSVignette()
                }
                GrainLayer(amount: style == .calm ? 0.025 : 0.03)
            }
            .animation(PSSpring.paletteFade, value: shown)
            .accessibilityHidden(true)
        }
    }
}

/// The palette as a 4 × 4 mesh: lightest at the top, the darkest stop along
/// the bottom row so the grid below reads on calm ground. Drawn once into its
/// own layer (`drawingGroup`): scrolling only moves that layer.
struct PSBackdropMesh: View {
    let palette: PSPalette

    /// Interior points nudged off the grid, fixed, so the mesh never looks ruled.
    static let points: [SIMD2<Float>] = [
        [0, 0], [0.33, 0], [0.67, 0], [1, 0],
        [0, 0.30], [0.36, 0.27], [0.70, 0.36], [1, 0.33],
        [0, 0.62], [0.30, 0.68], [0.64, 0.60], [1, 0.66],
        [0, 1], [0.33, 1], [0.67, 1], [1, 1],
    ]

    /// Sixteen colours from the four stops (0 darkest … 3 lightest).
    static func colors(_ palette: PSPalette) -> [Color] {
        let s = palette.stops.count == PSPalette.stopCount ? palette.stops : PSPalette.fallback.stops
        let base = PSColor(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
        let floor = s[0].blended(with: base, fraction: 0.5)
        let grid: [PSColor] = [
            s[3], s[2], s[3], s[2],
            s[2], s[3], s[1], s[2],
            s[1], s[2], s[0], s[1],
            floor, s[0], floor, floor,
        ]
        return grid.map { Color(psColor: $0) }
    }

    var body: some View {
        MeshGradient(width: 4, height: 4, points: Self.points, colors: Self.colors(palette),
                     background: Color.psBase, smoothsColors: true, colorSpace: .perceptual)
            .drawingGroup(opaque: true)
    }
}

/// White light from above, a little warmed by the palette's glow.
struct PSTopLight: View {
    let glow: Color
    var amount: Double = 0.06

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(.sRGB, white: 1, opacity: amount), .clear],
                           center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [glow.opacity(amount * 2), .clear],
                           center: UnitPoint(x: 0.5, y: -0.15), startRadius: 0, endRadius: 420)
        }
        .allowsHitTesting(false)
    }
}

/// Darkens the corners: black from 0 at 45 % of the radius to 55 % at the edge.
struct PSVignette: View {
    var body: some View {
        EllipticalGradient(stops: [
            .init(color: .clear, location: 0.45),
            .init(color: Color(.sRGB, white: 0, opacity: 0.55), location: 1),
        ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.75)
        .allowsHitTesting(false)
    }
}

// MARK: - Palette from a picture

/// Palettes derived from thumbnails, off the main thread, cached per picture
/// (project id and modification date), so returning to Home costs nothing.
@MainActor
enum PSPaletteCache {
    private static var cache: [String: PSPalette] = [:]
    private static var order: [String] = []
    private static let limit = 16

    static func cached(_ key: String) -> PSPalette? { cache[key] }

    /// The palette of `image`, derived on a utility thread from a 64-pixel copy.
    static func palette(for image: UIImage, key: String) async -> PSPalette? {
        if let hit = cache[key] { return hit }
        guard let cgImage = image.cgImage ?? ThumbnailIO.cgImage(from: image) else { return nil }
        let derived = await Task.detached(priority: .utility) { () -> PSPalette? in
            guard let pixels = Self.rgba(cgImage, longestSide: 64) else { return nil }
            return PSPalette.derive(rgba: pixels.bytes, width: pixels.width, height: pixels.height)
        }.value
        if let derived {
            cache[key] = derived
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > limit { cache[order.removeFirst()] = nil }
        }
        return derived
    }

    /// sRGB RGBA8 bytes of `image` scaled so its longest side is `longestSide` pixels.
    nonisolated static func rgba(_ image: CGImage, longestSide: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = Double(longestSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (bytes, width, height)
    }
}

#if DEBUG
#Preview("PSBackdrop") {
    PSBackdrop(palette: .fallback).ignoresSafeArea()
}

#Preview("PSBackdrop calm") {
    PSBackdrop(palette: nil, style: .calm).ignoresSafeArea()
}
#endif
#endif
