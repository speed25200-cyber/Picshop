#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopIntent

/// What one idea chip shows. Built from a `LiveIdea` in editors; Home builds
/// its own.
struct IdeaChipModel: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    /// The local model proposed it: a spectrum border.
    var fromModel: Bool
    /// Shown on a long press.
    var why: String?

    init(id: String, title: String, symbol: String, fromModel: Bool = false, why: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.fromModel = fromModel
        self.why = why
    }

    init(_ idea: LiveIdea) {
        self.init(id: idea.id, title: idea.title, symbol: idea.symbol, fromModel: idea.source == .model,
                  why: idea.why.isEmpty ? nil : idea.why)
    }
}

/// The row of up to three idea chips above the Ask field. `items == nil`
/// draws the loading skeleton.
///
/// Tap applies an idea; a long press shows why it is proposed; a swipe up
/// hides it. One row when it fits, a scrolling row when it does not, three
/// full-width chips at accessibility text sizes. Glass chips, or flat ones
/// (`flat(true)`) while the Live console keeps the glass budget.
struct IdeaChipsRow: View {
    let items: [IdeaChipModel]?
    var isEnabled: Bool
    let onChoose: (String) -> Void
    var onDismiss: ((String) -> Void)?
    private var isFlat = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let skeletonWidths: [CGFloat] = [112, 96, 128]

    init(items: [IdeaChipModel]?, isEnabled: Bool = true, onChoose: @escaping (String) -> Void, onDismiss: ((String) -> Void)? = nil) {
        self.items = items
        self.isEnabled = isEnabled
        self.onChoose = onChoose
        self.onDismiss = onDismiss
    }

    /// Flat chips (psChipFill) instead of glass.
    func flat(_ flat: Bool) -> IdeaChipsRow {
        var copy = self
        copy.isFlat = flat
        return copy
    }

    var body: some View {
        Group {
            if let items {
                let shown = Array(items.prefix(3))
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            chip(item, index: index, fullWidth: true)
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                chip(item, index: index, fullWidth: false)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                    chip(item, index: index, fullWidth: false)
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
            } else {
                IdeaSkeleton(widths: Self.skeletonWidths, animated: !reduceMotion)
            }
        }
        .frame(maxWidth: .infinity, minHeight: PSMetrics.ideaChip, alignment: .leading)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : PSMotion.ideas, value: items)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Ideas"))
    }

    private func chip(_ item: IdeaChipModel, index: Int, fullWidth: Bool) -> some View {
        IdeaChip(item: item, isFlat: isFlat, fullWidth: fullWidth,
                 onChoose: { onChoose(item.id) },
                 onDismiss: onDismiss.map { dismiss in { dismiss(item.id) } })
            // Arrivals are staggered by 60 ms; Reduce Motion cross-fades only.
            .transition(reduceMotion
                        ? AnyTransition.opacity
                        : AnyTransition.opacity.combined(with: .scale(scale: 0.92)).animation(PSMotion.ideas.delay(Double(index) * 0.06)))
    }
}

/// One idea: a MagicGlyph and a short title in a 40-point capsule.
private struct IdeaChip: View {
    let item: IdeaChipModel
    let isFlat: Bool
    let fullWidth: Bool
    let onChoose: () -> Void
    let onDismiss: (() -> Void)?

    @State private var lift: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            Haptics.tap()
            onChoose()
        } label: {
            HStack(spacing: 6) {
                MagicGlyph(size: 14, symbol: item.symbol)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PSTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: PSMetrics.ideaChip)
            .frame(maxWidth: fullWidth ? .infinity : 220, alignment: fullWidth ? .leading : .center)
            .fixedSize(horizontal: !fullWidth, vertical: false)
            .modifier(IdeaChipSurface(isFlat: isFlat, fromModel: item.fromModel, increasedContrast: contrast == .increased))
            .padding(.vertical, 2)
            .contentShape(Capsule())
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .offset(y: lift)
        .opacity(1 - Double(min(1, -lift / 60)))
        .simultaneousGesture(swipeUp, including: onDismiss == nil ? .none : .all)
        .contextMenu {
            Section(item.why ?? item.title) {
                Button { onChoose() } label: { Label(L("Apply"), systemImage: "sparkles") }
                if let onDismiss {
                    Button(role: .destructive) { onDismiss() } label: { Label(L("Hide this idea"), systemImage: "eye.slash") }
                }
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint(L("Applies this idea."))
        .modifier(IdeaDismissAction(onDismiss: onDismiss))
    }

    /// A swipe up sends the chip away.
    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard value.translation.height < 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                lift = max(-60, value.translation.height)
            }
            .onEnded { value in
                let dismisses = value.translation.height < -28 || value.predictedEndTranslation.height < -80
                if dismisses, let onDismiss {
                    Haptics.tap()
                    withAnimation(PSMotion.quick) { lift = -60 }
                    onDismiss()
                } else {
                    withAnimation(PSMotion.quick) { lift = 0 }
                }
            }
    }
}

private struct IdeaDismissAction: ViewModifier {
    let onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        if let onDismiss {
            content.accessibilityAction(named: Text(L("Hide this idea"))) { onDismiss() }
        } else {
            content
        }
    }
}

/// Glass (or a flat fill), a spectrum rim for the local model's ideas, a white rim with Increase Contrast.
private struct IdeaChipSurface: ViewModifier {
    let isFlat: Bool
    let fromModel: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        Group {
            if isFlat {
                content.psChipFill(Capsule())
            } else {
                content.psGlassField()
            }
        }
        .overlay {
            if fromModel {
                Capsule().strokeBorder(PSTheme.intelligenceAngular, lineWidth: 1).opacity(0.85)
            } else if increasedContrast {
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

/// Three quiet capsules while the first ideas are worked out.
private struct IdeaSkeleton: View {
    let widths: [CGFloat]
    let animated: Bool
    @State private var bright = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(widths.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(bright ? 0.13 : 0.08))
                    .frame(width: widths[index], height: PSMetrics.ideaChip)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

/// The numbered choices that replace the idea row while Live (or a command)
/// asks which one. Candidate ids are 1-based, as spoken. The question itself
/// is spoken and captioned, not printed here.
struct ChoiceChipsRow: View {
    let request: LiveChoiceRequest
    var thumbnail: ((Int) async -> UIImage?)?
    let onChoose: (LiveCandidateChoice) -> Void
    private var isFlat = false
    private var cancelAction: (() -> Void)?

    init(request: LiveChoiceRequest, thumbnail: ((Int) async -> UIImage?)? = nil, onChoose: @escaping (LiveCandidateChoice) -> Void) {
        self.request = request
        self.thumbnail = thumbnail
        self.onChoose = onChoose
    }

    /// Flat chips (psChipFill) instead of glass.
    func flat(_ flat: Bool) -> ChoiceChipsRow {
        var copy = self
        copy.isFlat = flat
        return copy
    }

    /// A trailing close chip that drops the question.
    func onCancel(_ action: @escaping () -> Void) -> ChoiceChipsRow {
        var copy = self
        copy.cancelAction = action
        return copy
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(request.candidates) { candidate in
                    ChoiceChip(candidate: candidate, thumbnail: thumbnail, isFlat: isFlat) {
                        Haptics.tap()
                        onChoose(.index(candidate.id))
                    }
                }
                if request.allowsAll, request.candidates.count > 1 {
                    Button {
                        Haptics.tap()
                        onChoose(.all)
                    } label: {
                        Text(L("All"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PSTheme.onPrimary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: PSMetrics.ideaChip)
                            .background(Capsule().fill(PSTheme.primary))
                            .padding(.vertical, 2)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.96))
                }
                if let cancelAction {
                    Button {
                        Haptics.tap()
                        cancelAction()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PSTheme.textSecondary)
                            .frame(width: PSMetrics.ideaChip, height: PSMetrics.ideaChip)
                            .modifier(IdeaChipSurface(isFlat: isFlat, fromModel: false, increasedContrast: false))
                            .padding(.vertical, 2)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.96))
                    .accessibilityLabel(L("Cancel"))
                }
            }
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: PSMetrics.ideaChip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.question)
    }
}

private struct ChoiceChip: View {
    let candidate: LiveChoiceRequest.Candidate
    let thumbnail: ((Int) async -> UIImage?)?
    let isFlat: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomTrailing) { number(size: 14) }
                } else {
                    number(size: 20)
                }
                Text(candidate.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PSTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, image == nil ? 10 : 6)
            .padding(.trailing, 14)
            .frame(minHeight: PSMetrics.ideaChip)
            .modifier(IdeaChipSurface(isFlat: isFlat, fromModel: false, increasedContrast: false))
            .padding(.vertical, 2)
            .contentShape(Capsule())
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .task(id: candidate.id) {
            guard let thumbnail else { return }
            image = await thumbnail(candidate.id)
        }
        .accessibilityLabel(String(format: L("Choice %d: %@"), candidate.id, candidate.label))
    }

    private func number(size: CGFloat) -> some View {
        Text(verbatim: "\(candidate.id)")
            .font(.system(size: size * 0.6, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(PSTheme.onPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(PSTheme.primary))
    }
}

#if DEBUG
private struct IdeaChipsPreview: View {
    var body: some View {
        VStack(spacing: 20) {
            IdeaChipsRow(items: nil, onChoose: { _ in })
            IdeaChipsRow(items: [
                IdeaChipModel(id: "a", title: "Ciel plus vif", symbol: "cloud.sun", why: "Le ciel manque de couleur."),
                IdeaChipModel(id: "b", title: "Portrait doux", symbol: "person.crop.circle", fromModel: true, why: "Un fond flou détacherait la personne."),
                IdeaChipModel(id: "c", title: "Recadrage 4:5", symbol: "crop"),
            ], onChoose: { _ in }, onDismiss: { _ in })
            IdeaChipsRow(items: [IdeaChipModel(id: "a", title: "Noir et blanc", symbol: "circle.lefthalf.filled")], onChoose: { _ in })
                .flat(true)
            IdeaChipsRow(items: [IdeaChipModel(id: "a", title: "Noir et blanc", symbol: "circle.lefthalf.filled")], isEnabled: false, onChoose: { _ in })
            ChoiceChipsRow(request: LiveChoiceRequest(question: "Lequel ?", candidates: [
                LiveChoiceRequest.Candidate(id: 1, label: "chien (gauche)"),
                LiveChoiceRequest.Candidate(id: 2, label: "chien (droite)"),
            ], allowsAll: true), onChoose: { _ in })
            .onCancel {}
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
    }
}

#Preview("Idea and choice chips") {
    IdeaChipsPreview()
}

#Preview("Idea chips, accessibility size") {
    IdeaChipsPreview().dynamicTypeSize(.accessibility2)
}
#endif
#endif
