#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// The command palette (W2, D16): up to three suggestions above the Ask field while it holds a few words
/// (≤ 4 words, ≤ 32 characters, never a question). A suggestion opens its tool or runs its operation through the
/// editor's `CommandPaletteHandler`, then clears the field. Suggestions only: Return still sends the sentence to
/// Live or the planner. No glass: the chips sit inside the dock's glass container. Nothing shows without a
/// handler (video and PDF in W2) or with the `commandPalette` flag off.
struct CommandPaletteRow: View {
    let text: String
    let live: LiveSession
    /// The field is cleared (a suggestion was taken).
    let onChosen: () -> Void

    @State private var matches: [PaletteMatch] = []

    var body: some View {
        HStack(spacing: PSSpacing.small) {
            ForEach(matches) { match in
                Button {
                    choose(match)
                } label: {
                    Label {
                        Text(verbatim: match.title).lineLimit(1)
                    } icon: {
                        Image(systemName: match.symbol ?? Self.defaultSymbol(match.target))
                    }
                    .font(PSFont.control(selected: true))
                    .foregroundStyle(Color.psTextPrimary)
                    .padding(.horizontal, PSSpacing.medium)
                    .frame(minHeight: PSMetrics.chip)
                    .background(Color.psFillControl, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityLabel(match))
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PSSpring.fade, value: matches.map(\.id))
        // Off the main thread and after a short pause in typing: the catalog's retrieval runs per change.
        .task(id: text) { await refresh() }
    }

    private func refresh() async {
        guard let domain = Self.domain(for: text, live: live) else {
            if !matches.isEmpty { matches = [] }
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        let query = text
        let language: OpLanguage = NormalizedUtterance(query).language == .english ? .en : .fr
        let found = await Task.detached(priority: .userInitiated) {
            CommandPalette.matches(query, domain: domain, language: language, limit: 3)
        }.value
        guard !Task.isCancelled else { return }
        if found != matches { matches = Array(found.prefix(3)) }
    }

    private func choose(_ match: PaletteMatch) {
        guard let handler = live.paletteHandler else { return }
        Haptics.tap()
        matches = []
        onChosen()
        switch match.target {
        case .tool(let id): handler.openTool(id)
        case .operation(let call): handler.run(call)
        }
    }

    /// The editor's domain when suggestions may show for `text`: the flag, a handler, and a short command.
    static func domain(for text: String, live: LiveSession) -> OpDomain? {
        guard FeatureFlags.isOn(.commandPalette), let handler = live.paletteHandler else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CommandPalette.shouldSuggest(trimmed) else { return nil }
        return handler.domain
    }

    static func defaultSymbol(_ target: PaletteMatch.Target) -> String {
        switch target {
        case .tool: return "slider.horizontal.3"
        case .operation: return "wand.and.stars"
        }
    }

    /// « Suggestion : Courbes, outil » / « Suggestion : Éclaircir, action ».
    static func accessibilityLabel(_ match: PaletteMatch) -> String {
        switch match.target {
        case .tool: return String(format: L("Suggestion: %@, tool"), match.title)
        case .operation: return String(format: L("Suggestion: %@, action"), match.title)
        }
    }
}
#endif
