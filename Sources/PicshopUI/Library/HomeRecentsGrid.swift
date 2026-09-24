#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// 'Récents': every project as a square picture, three to a row, newest
/// first. A filter appears only once the library is large.
struct HomeRecentsGrid: View {
    let summaries: [ProjectSummary]
    let library: ProjectLibrary
    let namespace: Namespace.ID
    let actions: HomeProjectActions
    @State private var filter: LibraryFilter = .all

    /// The filter menu appears above this many projects.
    static let filterThreshold = 12
    private static let spacing: CGFloat = 8

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

    var body: some View {
        let filterable = summaries.count > Self.filterThreshold
        let active = filterable ? filter : .all
        let shown = active == .all ? summaries : summaries.filter(active.matches)
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            HStack(alignment: .center, spacing: PSSpacing.small) {
                SectionTitle(title: active == .all ? L("Recent") : active.title, count: shown.count)
                if filterable { filterMenu }
            }
            .padding(.horizontal, PSSpacing.page)
            if shown.isEmpty {
                filterEmptyState
            } else {
                grid(shown)
            }
        }
    }

    private func grid(_ shown: [ProjectSummary]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 3), spacing: Self.spacing) {
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
        .animation(PSMotion.standard, value: shown.map(\.id))
    }

    /// Shown once the library is large enough to need it.
    private var filterMenu: some View {
        Menu {
            Picker(L("Recent"), selection: $filter.animation(PSMotion.standard)) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(filter == .all ? PSTheme.textPrimary : PSTheme.onPrimary)
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
            Image(systemName: filter == .videos ? "film" : (filter == .pdfs ? "doc.text" : "photo.on.rectangle"))
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(PSTheme.textTertiary)
            Text(L("Nothing here yet.")).font(PSFont.control(selected: true)).foregroundStyle(PSTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PSSpacing.xxLarge)
        .padding(.horizontal, PSSpacing.page)
        .transition(.opacity)
    }
}

/// One square cell: the picture, and a flat badge for a video's length or a PDF.
struct HomeProjectCell: View {
    let summary: ProjectSummary
    let slot: ThumbnailSlot
    let library: ProjectLibrary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.projectCell, style: .continuous)
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
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(6)
        case .pdf:
            Image(systemName: "doc.text.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.45)))
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
                Text(summary.title).font(PSFont.control(selected: true)).foregroundStyle(PSTheme.textPrimary)
                Text(summary.modifiedAt, format: .relative(presentation: .named)).font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
            }
            .lineLimit(1)
        }
        .frame(width: 280)
        .padding(PSSpacing.medium)
        .background(PSTheme.ink)
        .preferredColorScheme(.dark)
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
            content.background(Circle().fill(isSelected ? PSTheme.primary : PSTheme.surfaceFlat))
        } else {
            content.glassEffect(isSelected ? Glass.regular.tint(PSTheme.primary).interactive() : Glass.regular.interactive(), in: .circle)
        }
    }
}
#endif
