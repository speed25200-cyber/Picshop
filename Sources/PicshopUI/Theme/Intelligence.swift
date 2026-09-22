#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopSpeech

/// The glow that runs around the edge of the screen while PicShop listens or
/// works — the one place the whole interface says "the AI has it".
///
/// Three blurred strokes of a slowly turning spectrum, drawn in one Metal
/// pass. It follows the voice level while listening, holds still for Reduce
/// Motion, and is never hit-testable.
public struct IntelligenceGlow: View {
    var isActive: Bool
    /// 0…1 input level; the glow swells with the voice.
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
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion)) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    let angle = Angle.degrees(reducedMotion ? 0 : (seconds * 50).truncatingRemainder(dividingBy: 360))
                    let swell = CGFloat(min(1, max(0, level)))
                    glow(angle: angle, swell: swell)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.45)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(angle: Angle, swell: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.display, style: .continuous)
        let gradient = AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center, angle: angle)
        return ZStack {
            shape.strokeBorder(gradient, lineWidth: 26 + swell * 18).blur(radius: 34).opacity(0.55)
            shape.strokeBorder(gradient, lineWidth: 10 + swell * 6).blur(radius: 12).opacity(0.85)
            shape.strokeBorder(gradient, lineWidth: 2.5).opacity(0.95)
        }
        .drawingGroup()
    }
}

/// The glow for an editor: reads the microphone in a leaf view so the level
/// never re-evaluates the canvas.
struct EditorIntelligenceGlow: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool

    var body: some View {
        IntelligenceGlow(isActive: voice.isListening || isBusy, level: voice.isListening ? voice.level : 0.25)
            .animation(.easeInOut(duration: 0.45), value: voice.isListening || isBusy)
    }
}

/// Text that shimmers with the intelligence spectrum while something is
/// being worked out ("Listening…", "Removing the dog…").
public struct ShimmerText: View {
    let text: String
    var font: Font = PSFont.body(14)
    @Environment(\.psReducedMotion) private var reducedMotion

    public init(_ text: String, font: Font = PSFont.body(14)) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(PSTheme.textPrimary.opacity(0.55))
            .overlay {
                if !reducedMotion {
                    SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        LinearGradient(stops: [
                            .init(color: .clear, location: max(0, phase - 0.35)),
                            .init(color: PSTheme.intelligence[0], location: max(0, phase - 0.18)),
                            .init(color: .white, location: phase),
                            .init(color: PSTheme.intelligence[2], location: min(1, phase + 0.18)),
                            .init(color: .clear, location: min(1, phase + 0.35)),
                        ], startPoint: .leading, endPoint: .trailing)
                        .mask(Text(text).font(font))
                    }
                } else {
                    Text(text).font(font).psIntelligenceForeground()
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
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .psIntelligenceForeground()
    }
}

/// A slowly drifting iridescent field for hero surfaces (Magic cards, the
/// onboarding). Static unless `animated`, so idle screens stay idle.
public struct IntelligenceField: View {
    var animated = false
    @Environment(\.psReducedMotion) private var reducedMotion
    @Environment(\.psEffects) private var effects

    public init(animated: Bool = false) { self.animated = animated }

    public var body: some View {
        // The drift is slow, so 15 frames a second is plenty; a warm phone gets a still field.
        if animated && !reducedMotion && effects == .rich {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
                mesh(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            mesh(time: 0)
        }
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
