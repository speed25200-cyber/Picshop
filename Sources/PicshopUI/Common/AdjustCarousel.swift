#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One ring of a carousel (ux-spec §3.5.4): a parameter (« Luminosité ») or an action ring (« ✦ Auto »,
/// « Pipette »).
struct CarouselRing: Identifiable, Equatable {
    /// The parameter id ("brightness"); the carousel remembers the last-used one.
    var id: String
    /// The caption2 label under the ring, always shown (AC-02).
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var neutral: Double
    /// Drawn inside the ring instead of the value arc (« ✦ » for Auto, the drop for Pipette).
    var systemImage: String?
    /// A tap runs it (`onAction`) instead of selecting it.
    var isAction: Bool

    init(id: String, title: String, value: Double = 0, range: ClosedRange<Double> = -1...1, neutral: Double = 0,
         systemImage: String? = nil, isAction: Bool = false) {
        self.id = id
        self.title = title
        self.value = value
        self.range = range
        self.neutral = neutral
        self.systemImage = systemImage
        self.isAction = isAction
    }

    /// An action ring (« ✦ Auto »).
    static func action(id: String, title: String, systemImage: String) -> CarouselRing {
        CarouselRing(id: id, title: title, systemImage: systemImage, isAction: true)
    }

    var isOffNeutral: Bool { !isAction && abs(value - neutral) > (range.upperBound - range.lowerBound) / 400 }

    /// −1…1: how far off neutral, signed, for the ring's arc.
    var deflection: Double {
        guard !isAction else { return 0 }
        let up = range.upperBound - neutral
        let down = neutral - range.lowerBound
        if value >= neutral { return up > 0 ? (value - neutral) / up : 0 }
        return down > 0 ? -(neutral - value) / down : 0
    }
}

/// The Photos-style carousel (§3.5.4, §4.6) of Lumière, Couleur, Effets, Flou and the video Ajuster strip: labelled
/// rings 64 points apart, the selected ring's name large over its value, and the dial under them, which edits the
/// same value as the medium list's PSSlider. The first time, `defaultRing` is centred (Lumière: « Luminosité »);
/// after that, the last-used ring (remembered per `carouselID`).
struct AdjustCarousel: View {
    /// "photo.light": keys the remembered ring.
    let carouselID: String
    let rings: [CarouselRing]
    /// The selected ring's id.
    @Binding var selection: String
    /// The selected ring's value, driven by the dial: bind it to a leaf's state.
    @Binding var value: Double
    var format: (Double) -> String
    var onAction: (String) -> Void
    var onEditingChanged: ((Bool) -> Void)?

    init(carouselID: String, rings: [CarouselRing], selection: Binding<String>, value: Binding<Double>,
         format: @escaping (Double) -> String = PSSlider.signed, onAction: @escaping (String) -> Void = { _ in },
         onEditingChanged: ((Bool) -> Void)? = nil) {
        self.carouselID = carouselID
        self.rings = rings
        _selection = selection
        _value = value
        self.format = format
        self.onAction = onAction
        self.onEditingChanged = onEditingChanged
    }

    /// The ring to select when the carousel opens: the last-used one, else `defaultRing`.
    static func rememberedRing(for carouselID: String, default defaultRing: String) -> String {
        UserDefaults.standard.string(forKey: key(carouselID)) ?? defaultRing
    }

    /// Remembers the last-used ring.
    static func remember(_ ring: String, for carouselID: String) {
        UserDefaults.standard.set(ring, forKey: key(carouselID))
    }

    private static func key(_ carouselID: String) -> String { "ux2.carousel.\(carouselID)" }

    private var selected: CarouselRing? { rings.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: PSSpacing.xSmall) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PSMetrics.carouselRingSpacing - PSMetrics.carouselRing) {
                        ForEach(rings) { ring in
                            CarouselRingButton(ring: ring, isSelected: ring.id == selection) { tap(ring) }
                                .id(ring.id)
                        }
                    }
                    .padding(.horizontal, PSSpacing.large)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, id in
                    withAnimation(PSSpring.standard) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if let ring = selected, !ring.isAction {
                DialSlider(value: $value, range: ring.range, neutral: ring.neutral, label: ring.title, format: format,
                           onEditingChanged: onEditingChanged)
                    .uxProbe(id: "adjust.dial")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tap(_ ring: CarouselRing) {
        if ring.isAction {
            onAction(ring.id)
            return
        }
        guard ring.id != selection else { return }
        selection = ring.id
        Self.remember(ring.id, for: carouselID)
    }
}

/// A ring: a 44-point circle with the value's arc (yellow off neutral) or the action's glyph, its label under it.
private struct CarouselRingButton: View {
    let ring: CarouselRing
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PSSpacing.xSmall) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.psTextPrimary : Color.psStrokeStrong, lineWidth: isSelected ? 2 : 1.5)
                    if let symbol = ring.systemImage {
                        Image(systemName: symbol)
                            .font(PSFont.glyph(.chip, weight: .semibold))
                            .foregroundStyle(Color.psTextPrimary)
                    } else if ring.isOffNeutral {
                        Circle()
                            .trim(from: 0, to: CGFloat(min(1, abs(ring.deflection))))
                            .stroke(Color.psValueAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .scaleEffect(x: ring.deflection < 0 ? -1 : 1, y: 1)
                    }
                }
                .frame(width: PSMetrics.carouselRing, height: PSMetrics.carouselRing)
                Text(ring.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.psTextPrimary : Color.psTextSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: PSMetrics.carouselRing)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(ring.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .uxProbe(id: "ring.\(ring.id)", role: .tool)
    }
}
#endif
