#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// The glow that runs around the edge of the screen while PicShop listens or
/// works — the one place the whole interface says "the AI has it".
///
/// Three soft strokes of the spectrum. The strokes are blurred once into a
/// mask image (per screen size); what moves is a transform: the spectrum turns
/// behind that mask. No blur runs per frame. It holds still with Reduce Motion
/// or on a warm phone, is gone at `.minimal`, and is never hit-testable.
public struct IntelligenceGlow: View {
    var isActive: Bool
    /// 0…1 input level; the glow is thicker for a louder voice (set when it appears).
    var level: Double = 0
    @Environment(\.psReducedMotion) private var reducedMotion
    @Environment(\.psEffects) private var effects

    public init(isActive: Bool, level: Double = 0) {
        self.isActive = isActive
        self.level = level
    }

    public var body: some View {
        Group {
            if isActive && effects != .minimal {
                GlowRing(swell: CGFloat(min(1, max(0, level))), turns: !reducedMotion && effects == .rich)
                    .transition(.opacity.animation(.easeInOut(duration: 0.45)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The spectrum turning behind a pre-blurred mask of the screen's edge.
private struct GlowRing: View {
    let swell: CGFloat
    let turns: Bool
    @State private var mask: UIImage?
    @State private var maskSize: CGSize = .zero
    @State private var turned = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
            ZStack {
                if let mask {
                    AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center)
                        .frame(width: diagonal, height: diagonal)
                        .rotationEffect(.degrees(turned ? 360 : 0))
                        .frame(width: size.width, height: size.height)
                        .mask { Image(uiImage: mask).resizable() }
                }
            }
            .onAppear {
                renderMask(size)
                guard turns, !turned else { return }
                // 50° a second, as before, now a transform animation.
                withAnimation(.linear(duration: 7.2).repeatForever(autoreverses: false)) { turned = true }
            }
            .onChange(of: size) { _, newSize in renderMask(newSize) }
        }
    }

    /// The blurred strokes, rasterised once for this size.
    private func renderMask(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != maskSize else { return }
        maskSize = size
        let renderer = ImageRenderer(content: GlowMask(swell: swell).frame(width: size.width, height: size.height))
        renderer.scale = min(displayScale, 2)
        mask = renderer.uiImage
    }
}

/// The glow's shape in white: two blurred strokes and a crisp edge.
private struct GlowMask: View {
    let swell: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.display, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.white, lineWidth: 26 + swell * 18).blur(radius: 34).opacity(0.55)
            shape.strokeBorder(Color.white, lineWidth: 10 + swell * 6).blur(radius: 12).opacity(0.85)
            shape.strokeBorder(Color.white, lineWidth: 2.5).opacity(0.95)
        }
    }
}

/// Text that shimmers with the intelligence spectrum while something is
/// being worked out ("Listening…", "Removing the dog…"): a band of the
/// spectrum slides across the words (an offset animation, nothing redrawn).
public struct ShimmerText: View {
    let text: String
    var font: Font = PSFont.control()
    @Environment(\.psReducedMotion) private var reducedMotion
    @Environment(\.psEffects) private var effects
    @State private var swept = false

    public init(_ text: String, font: Font = PSFont.control()) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(PSTheme.textPrimary.opacity(0.55))
            .overlay {
                if !reducedMotion, effects == .rich {
                    GeometryReader { proxy in
                        let width = max(1, proxy.size.width)
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: PSTheme.intelligence[0], location: 0.3),
                            .init(color: .white, location: 0.5),
                            .init(color: PSTheme.intelligence[2], location: 0.7),
                            .init(color: .clear, location: 1),
                        ], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.7, height: proxy.size.height)
                        .offset(x: swept ? width : -width * 0.7)
                    }
                    .mask(Text(text).font(font).lineLimit(2))
                    .onAppear {
                        guard !swept else { return }
                        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { swept = true }
                    }
                } else {
                    Text(text).font(font).lineLimit(2).psIntelligenceForeground()
                }
            }
            .lineLimit(2)
    }
}

/// A sparkle glyph painted with the spectrum, for Magic entry points.
public struct MagicGlyph: View {
    var size: CGFloat = 16
    var symbol: String = "sparkles"

    public init(size: CGFloat = 16, symbol: String = "sparkles") {
        self.size = size
        self.symbol = symbol
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .psIntelligenceForeground()
    }
}

/// An iridescent field for hero surfaces (Magic cards, the onboarding). Static:
/// a screen nobody touches draws no frames. `animated` is kept for callers and ignored.
public struct IntelligenceField: View {
    var animated = false

    public init(animated: Bool = false) { self.animated = animated }

    public var body: some View {
        mesh(time: 0)
    }

    private func mesh(time: Double) -> some View {
        let dx = Float(sin(time * 0.35) * 0.12)
        let dy = Float(cos(time * 0.27) * 0.10)
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: PSTheme.heroMesh)
    }
}
#endif
