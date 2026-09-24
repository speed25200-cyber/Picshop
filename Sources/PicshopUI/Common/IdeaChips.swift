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
    /// Claude proposed it: a spectrum border.
    var fromClaude: Bool
    /// Shown on a long press.
    var why: String?

    init(id: String, title: String, symbol: String, fromClaude: Bool = false, why: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.fromClaude = fromClaude
        self.why = why
    }

    init(_ idea: LiveIdea) {
        self.init(id: idea.id, title: idea.title, symbol: idea.symbol, fromClaude: idea.source == .claude,
                  why: idea.why.isEmpty ? nil : idea.why)
    }
}

/// The row of up to three idea chips above the Ask field. `items == nil`
/// draws the loading skeleton.
///
/// Phase 0: plain glass chips and the skeleton. The long press (why), the
/// swipe to dismiss, the spectrum border and the ViewThatFits fallback follow.
struct IdeaChipsRow: View {
    let items: [IdeaChipModel]?
    var isEnabled: Bool
    let onChoose: (String) -> Void
    var onDismiss: ((String) -> Void)?

    private static let skeletonWidths: [CGFloat] = [112, 96, 128]

    init(items: [IdeaChipModel]?, isEnabled: Bool = true, onChoose: @escaping (String) -> Void, onDismiss: ((String) -> Void)? = nil) {
        self.items = items
        self.isEnabled = isEnabled
        self.onChoose = onChoose
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 8) {
            if let items {
                ForEach(items) { item in
                    chip(item)
                }
            } else {
                ForEach(Self.skeletonWidths.indices, id: \.self) { index in
                    Capsule()
                        .fill(PSTheme.fill)
                        .frame(width: Self.skeletonWidths[index], height: PSMetrics.ideaChip)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: PSMetrics.ideaChip)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(PSMotion.ideas, value: items)
    }

    private func chip(_ item: IdeaChipModel) -> some View {
        Button {
            Haptics.tap()
            onChoose(item.id)
        } label: {
            HStack(spacing: 6) {
                MagicGlyph(size: 14, symbol: item.symbol)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PSTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: PSMetrics.ideaChip)
            .frame(maxWidth: 220)
            .contentShape(Capsule())
            .psGlassField()
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityHint(item.why ?? "")
    }
}

/// The numbered choices that replace the idea row while Live (or a command)
/// asks which one. Candidate ids are 1-based, as spoken.
///
/// Phase 0: numbered chips and Tous. Thumbnails follow.
struct ChoiceChipsRow: View {
    let request: LiveChoiceRequest
    var thumbnail: ((Int) async -> UIImage?)?
    let onChoose: (LiveCandidateChoice) -> Void

    init(request: LiveChoiceRequest, thumbnail: ((Int) async -> UIImage?)? = nil, onChoose: @escaping (LiveCandidateChoice) -> Void) {
        self.request = request
        self.thumbnail = thumbnail
        self.onChoose = onChoose
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(request.candidates) { candidate in
                    Button {
                        Haptics.confirm()
                        onChoose(.index(candidate.id))
                    } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(candidate.id)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PSTheme.onPrimary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(PSTheme.primary))
                            Text(candidate.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PSTheme.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 9)
                        .padding(.trailing, 14)
                        .frame(minHeight: PSMetrics.ideaChip)
                        .contentShape(Capsule())
                        .psGlassField()
                    }
                    .buttonStyle(PSPressStyle(scale: 0.96))
                }
                if request.allowsAll {
                    Button {
                        Haptics.confirm()
                        onChoose(.all)
                    } label: {
                        Text(L("All"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PSTheme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: PSMetrics.ideaChip)
                            .contentShape(Capsule())
                            .psGlassField()
                    }
                    .buttonStyle(PSPressStyle(scale: 0.96))
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityLabel(request.question)
    }
}

#if DEBUG
private struct IdeaChipsPreview: View {
    var body: some View {
        VStack(spacing: 20) {
            IdeaChipsRow(items: nil, onChoose: { _ in })
            IdeaChipsRow(items: [
                IdeaChipModel(id: "a", title: "Ciel plus vif", symbol: "cloud.sun"),
                IdeaChipModel(id: "b", title: "Portrait doux", symbol: "person.crop.circle", fromClaude: true),
                IdeaChipModel(id: "c", title: "Recadrage 4:5", symbol: "crop"),
            ], onChoose: { _ in })
            IdeaChipsRow(items: [IdeaChipModel(id: "a", title: "Noir et blanc", symbol: "circle.lefthalf.filled")], isEnabled: false, onChoose: { _ in })
            ChoiceChipsRow(request: LiveChoiceRequest(question: "Lequel ?", candidates: [
                LiveChoiceRequest.Candidate(id: 1, label: "chien (gauche)"),
                LiveChoiceRequest.Candidate(id: 2, label: "chien (droite)"),
            ], allowsAll: true), onChoose: { _ in })
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
    }
}

#Preview("Idea and choice chips") {
    IdeaChipsPreview()
}
#endif
#endif
