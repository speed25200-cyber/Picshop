#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// 'Récents': every project as a square picture, newest first.
///
/// - `.studio` (W1): an adaptive grid (cells from 108 points, 4 apart, 14-point
///   corners) and, from 6 projects, a Tout / Photos / Vidéos / PDF filter that
///   sticks under the status bar while the grid scrolls (the section header of
///   Home's pinned LazyVStack).
/// - `.legacy` (W0): three columns 8 apart, a filter menu above 12 projects.
///
/// While Home searches, `searchQuery` titles the section and the summaries
/// arrive already filtered.
struct HomeRecentsGrid: View {
    enum Style { case legacy, studio }

    let summaries: [ProjectSummary]
    let library: ProjectLibrary
    let namespace: Namespace.ID
    let actions: HomeProjectActions
    var style: Style = .legacy
    var searchQuery: String?
    @State private var filter: LibraryFilter = .all

    /// The filter appears from this many projects.
    static func filterThreshold(_ style: Style) -> Int { style == .studio ? 6 : 13 }
    private static let legacySpacing: CGFloat = 8

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, photos, videos, pdfs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All")
            case .photos: return L("Photos")
            case .videos: return L("Videos")
            case .pdfs: return L("PDFs")
            }
        }
        func matches(_ summary: ProjectSummary) -> Bool {
            switch self {
            case .all: return true
            case .photos: return summary.kind == .photo
            case .videos: return summary.kind == .video
            case .pdfs: return summary.kind == .pdf
            }
        }
    }

    private var isFilterable: Bool { searchQuery == nil && summaries.count >= Self.filterThreshold(style) }

    var body: some View {
        let active = isFilterable ? filter : .all
        let shown = active == .all ? summaries : summaries.filter(active.matches)
        switch style {
        case .legacy:
            VStack(alignment: .leading, spacing: PSSpacing.medium) {
                HStack(alignment: .center, spacing: PSSpacing.small) {
                    SectionTitle(title: active == .all ? L("Recent") : active.title, count: shown.count)
                    if isFilterable { filterMenu }
                }
                .padding(.horizontal, PSSpacing.page)
                content(shown)
            }
        case .studio:
            // The title scrolls away; the filter (the section header) stays.
            SectionTitle(title: title(active), count: shown.count)
                .padding(.horizontal, PSSpacing.page)
                .padding(.bottom, -PSSpacing.medium)
            Section {
                content(shown)
            } header: {
                if isFilterable {
                    HomeFilterBar(selection: $filter)
                        .padding(.horizontal, PSSpacing.page)
                        .padding(.vertical, PSSpacing.small)
                }
            }
        }
    }

    private func title(_ active: LibraryFilter) -> String {
        if let searchQuery { return searchQuery.isEmpty ? L("All projects") : L("Results") }
        return active == .all ? L("Recent") : active.title
    }

    @ViewBuilder
    private func content(_ shown: [ProjectSummary]) -> some View {
        if shown.isEmpty {
            filterEmptyState
        } else {
            grid(shown)
        }
    }

    private var columns: [GridItem] {
        switch style {
        case .legacy: return Array(repeating: GridItem(.flexible(), spacing: Self.legacySpacing), count: 3)
        case .studio: return [GridItem(.adaptive(minimum: PSMetrics.gridCellMinimum), spacing: PSMetrics.gridSpacing)]
        }
    }

    private func grid(_ shown: [ProjectSummary]) -> some View {
        LazyVGrid(columns: columns, spacing: style == .studio ? PSMetrics.gridSpacing : Self.legacySpacing) {
            ForEach(shown) { summary in
                Button {
                    actions.open(summary)
                } label: {
                    // The editor grows out of the picture the user tapped.
                    HomeProjectCell(summary: summary, slot: library.slot(for: summary.id), library: library)
                        .matchedTransitionSource(id: summary.id.uuidString, in: namespace)
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .contextMenu {
                    HomeProjectMenu(summary: summary, actions: actions)
                } preview: {
                    HomeProjectPreview(summary: summary, slot: library.slot(for: summary.id))
                }
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .animation(PSSpring.standard, value: shown.map(\.id))
    }

    /// W0: shown once the library is large enough to need it.
    private var filterMenu: some View {
        Menu {
            Picker(L("Recent"), selection: $filter.animation(PSSpring.standard)) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(PSFont.glyph(.bar))
                .foregroundStyle(filter == .all ? Color.psTextPrimary : Color.psOnAction)
                .frame(width: PSMetrics.barButton, height: PSMetrics.barButton)
                .modifier(HomeCircleSurface(isSelected: filter != .all))
                .contentShape(Circle())
        }
        .accessibilityLabel(L("Filter"))
        .accessibilityValue(filter.title)
        .onChange(of: filter) { _, _ in Haptics.tick() }
    }

    private var filterEmptyState: some View {
        VStack(spacing: PSSpacing.small) {
            Image(systemName: searchQuery != nil ? "magnifyingglass" : (filter == .videos ? "film" : (filter == .pdfs ? "doc.text" : "photo.on.rectangle")))
                .font(.title.weight(.light))
                .foregroundStyle(Color.psTextTertiary)
            Text(searchQuery != nil ? L("No project has that name.") : L("Nothing here yet."))
                .font(PSFont.control(selected: true))
                .foregroundStyle(Color.psTextSecondary)
                .multilineTextAlignment(.center)
            if searchQuery == nil, filter != .all {
                Button(L("Show all")) {
                    Haptics.tick()
                    withAnimation(PSSpring.standard) { filter = .all }
                }
                .font(PSFont.control(selected: true))
                .foregroundStyle(Color.psTextPrimary)
                .frame(minHeight: PSMetrics.control)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PSSpacing.xxLarge)
        .padding(.horizontal, PSSpacing.page)
        .transition(.opacity)
    }
}

/// The sticky Tout / Photos / Vidéos / PDF filter: one regular-glass capsule,
/// the selected segment white with a black label (flat fills inside glass).
struct HomeFilterBar: View {
    @Binding var selection: HomeRecentsGrid.LibraryFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeRecentsGrid.LibraryFilter.allCases) { item in
                let isSelected = item == selection
                Button {
                    guard item != selection else { return }
                    withAnimation(PSSpring.quick) { selection = item }
                } label: {
                    Text(item.title)
                        .font(PSFont.control(selected: isSelected))
                        .foregroundStyle(isSelected ? Color.psOnAction : Color.psTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: PSMetrics.control - 8)
                        .background { if isSelected { Capsule().fill(Color.psActionPrimary) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .frame(maxWidth: 420)
        .psGlass()
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: selection)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Filter"))
    }
}

/// One square cell: the picture, and a flat badge for a video's length or a PDF.
struct HomeProjectCell: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot
    let library: ProjectLibrary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailImage(slot: slot, kind: summary.kind) }
            .overlay(alignment: .bottomTrailing) { badge }
            .clipShape(shape)
            .contentShape(shape)
            .task(id: summary.modifiedAt) { await library.loadThumbnail(for: summary) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.title)
            .accessibilityValue(accessibilityDetails)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var badge: some View {
        switch summary.kind {
        case .photo:
            EmptyView()
        case .video:
            Text(Self.duration(summary.duration ?? 0))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.psTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.psBadgeGround))
                .padding(6)
        case .pdf:
            Image(systemName: "doc.text.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.psTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.psBadgeGround))
                .padding(6)
        }
    }

    private var accessibilityDetails: String {
        let date = summary.modifiedAt.formatted(.relative(presentation: .named))
        switch summary.kind {
        case .photo: return L("Photo") + ", " + date
        case .video: return L("Video") + ", " + Self.duration(summary.duration ?? 0) + ", " + date
        case .pdf: return String(format: L("%d pages"), summary.pageCount ?? 0) + ", " + date
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The long-press preview: the whole picture in its own shape, then its title.
private struct HomeProjectPreview: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Color.clear
                .aspectRatio(CGFloat(min(max(summary.aspectRatio, 0.5), 2)), contentMode: .fit)
                .overlay { ThumbnailImage(slot: slot, kind: summary.kind, glyphSize: 34) }
                .clipShape(RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(PSFont.control(selected: true)).foregroundStyle(Color.psTextPrimary)
                Text(summary.modifiedAt, format: .relative(presentation: .named)).font(PSFont.footnote()).foregroundStyle(Color.psTextSecondary)
            }
            .lineLimit(1)
        }
        .frame(width: 280)
        .padding(PSSpacing.medium)
        .background(Color.psBase)
    }
}

/// The glass of a 44-point round control, flat at `.minimal` effects.
/// Selected is white, for black content.
struct HomeCircleSurface: ViewModifier {
    var isSelected = false
    @Environment(\.psEffects) private var effects

    @ViewBuilder
    func body(content: Content) -> some View {
        if effects == .minimal {
            content.background(Circle().fill(isSelected ? Color.psActionPrimary : Color.psElevated))
        } else {
            content.glassEffect(isSelected ? Glass.regular.tint(Color.psActionPrimary).interactive() : Glass.regular.interactive(), in: .circle)
        }
    }
}
#endif
