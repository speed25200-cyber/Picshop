#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
import PicshopCore

// UX 2.0 (ux-spec §4.7, §4.12, §4.19): the one place for status. Jobs, errors, receipts, undo receipts, replies and
// notices all go through an editor's Announcer, which shows one at a time in the FeedbackSlot (canvas zone C) and
// speaks it to VoiceOver. It replaces the top toasts (EditorStatusOverlay), the blocking ProgressHUD and the
// one-line LiveReplyCapsule once each editor moves to EditorShell. U1 owns this file.

/// One item of the feedback slot.
struct FeedbackItem: Identifiable, Equatable {
    /// A button in the capsule (« Annuler », « Réessayer », (↶)).
    struct Action: Identifiable, Equatable {
        var id: String
        /// The visible title, or the VoiceOver label of a glyph-only action.
        var title: String
        /// Drawn alone when `isGlyphOnly` ((↶), (↷)), else before the title.
        var systemImage: String?
        var isGlyphOnly = false
        /// Inactive (« Réessayer dans 30 s »).
        var isEnabled = true
        var run: () -> Void

        init(id: String, title: String, systemImage: String? = nil, isGlyphOnly: Bool = false, isEnabled: Bool = true,
             run: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.isGlyphOnly = isGlyphOnly
            self.isEnabled = isEnabled
            self.run = run
        }

        static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.systemImage == rhs.systemImage && lhs.isEnabled == rhs.isEnabled
        }
    }

    let id: UUID
    var kind: FeedbackKind
    var text: String
    var systemImage: String?
    /// A job's progress, 0…1; nil while indeterminate.
    var progress: Double?
    var actions: [Action]
    /// Spoken by VoiceOver when the item shows; defaults to `text`.
    var announcement: String?

    init(id: UUID = UUID(), kind: FeedbackKind, text: String, systemImage: String? = nil, progress: Double? = nil,
         actions: [Action] = [], announcement: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
        self.progress = progress
        self.actions = actions
        self.announcement = announcement
    }
}

/// An editor's feedback queue and VoiceOver announcer. Views read only `current`, so a progress tick re-evaluates
/// the slot alone. Every ↶ and ↷ posts its undo receipt (« Annulé : Lumière »), including the two-finger tap.
@MainActor
@Observable
final class Announcer {
    /// What the slot shows now.
    private(set) var current: FeedbackItem?
    /// Items that left the slot unanswered (stale errors, overflow), oldest first, for the Conversation (phase 2).
    private(set) var conversation: [FeedbackItem] = []

    @ObservationIgnored private var queue = FeedbackQueue<UUID>()
    @ObservationIgnored private var items: [UUID: FeedbackItem] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init() {}

    // MARK: Posting

    /// Shows an item now or queues it behind a higher-priority one (§4.7 priorities).
    @discardableResult
    func post(_ item: FeedbackItem) -> UUID {
        items[item.id] = item
        let moved = queue.post(item.id, kind: item.kind)
        moveToConversation(moved.map(\.id))
        refresh()
        return item.id
    }

    /// Updates a showing or queued item in place (a job's progress or title): the slot re-evaluates, nothing else.
    func update(_ id: UUID, text: String? = nil, progress: Double?) {
        guard var item = items[id] else { return }
        if let text { item.text = text }
        item.progress = progress
        items[id] = item
        if current?.id == id { current = item }
    }

    /// Removes an item (dismissed, answered, job done) and shows the next.
    func dismiss(_ id: UUID) {
        guard queue.dismiss(id) else { return }
        items[id] = nil
        refresh()
    }

    /// The person started an action or a job: a showing error, refusal or clarification moves to the Conversation,
    /// so a stale message never blocks (AC-11). Call it before posting a job.
    func userStartedAction() {
        let moved = queue.userStartedAction()
        moveToConversation(moved.map(\.id))
        refresh()
    }

    /// Empties the slot (the editor closes).
    func removeAll() {
        expiry?.cancel()
        queue.removeAll()
        items = [:]
        current = nil
    }

    // MARK: Conveniences (the copy of §4.7 and §4.12)

    /// « Annulé : Lumière · (↷) », 1,5 s.
    @discardableResult
    func undid(_ label: String, redo: (() -> Void)? = nil) -> UUID {
        let actions = redo.map { [FeedbackItem.Action(id: "redo", title: L("Redo"), systemImage: "arrow.uturn.forward", isGlyphOnly: true, run: $0)] } ?? []
        return post(FeedbackItem(kind: .undoReceipt, text: String(format: L("Undone: %@"), label), actions: actions))
    }

    /// « Rétabli : Lumière · (↶) », 1,5 s.
    @discardableResult
    func redid(_ label: String, undo: (() -> Void)? = nil) -> UUID {
        let actions = undo.map { [FeedbackItem.Action(id: "undo", title: L("Undo the change"), systemImage: "arrow.uturn.backward", isGlyphOnly: true, run: $0)] } ?? []
        return post(FeedbackItem(kind: .undoReceipt, text: String(format: L("Redone: %@"), label), actions: actions))
    }

    /// « ✦ Lumière auto · Exposition +0,3 · (↶) · [Ajuster] », 6 s (12 s with VoiceOver).
    @discardableResult
    func receipt(_ text: String, systemImage: String? = nil, undo: (() -> Void)? = nil, adjust: (() -> Void)? = nil) -> UUID {
        var actions: [FeedbackItem.Action] = []
        if let undo { actions.append(FeedbackItem.Action(id: "undo", title: L("Undo the change"), systemImage: "arrow.uturn.backward", isGlyphOnly: true, run: undo)) }
        if let adjust { actions.append(FeedbackItem.Action(id: "adjust", title: L("Adjust"), run: adjust)) }
        return post(FeedbackItem(kind: .receipt, text: text, systemImage: systemImage, actions: actions))
    }

    /// « Effacement… 42 % · [Annuler] », until `dismiss`. Moves a stale error away first.
    @discardableResult
    func startJob(_ title: String, progress: Double? = nil, cancel: (() -> Void)? = nil) -> UUID {
        userStartedAction()
        let actions = cancel.map { [FeedbackItem.Action(id: "cancel", title: L("Cancel"), run: $0)] } ?? []
        return post(FeedbackItem(kind: .job, text: title, progress: progress, actions: actions,
                                 announcement: title))
    }

    /// An error where it happened (AC-18), with its buttons: « Réessayer » when `retry` is given, then « Fermer ».
    @discardableResult
    func error(_ error: UserFacingError, retry: (() -> Void)? = nil) -> UUID? {
        guard !error.isSilent else { return nil }
        let french = psPrefersFrench
        let id = UUID()
        var actions: [FeedbackItem.Action] = []
        for action in error.actions {
            switch action {
            case .retry:
                guard let retry else { continue }
                actions.append(FeedbackItem.Action(id: "retry", title: error.retryTitle(secondsLeft: error.retryDelay, french: french),
                                                   isEnabled: error.retryDelay == 0, run: retry))
            case .close, .later:
                actions.append(FeedbackItem.Action(id: action.rawValue, title: action.title(french: french)) { [weak self] in self?.dismiss(id) })
            case .freeSpace, .openSettings, .saveToFiles, .openLastSaved, .download, .chooseAnother, .makeTextSelectable:
                // The host maps these through `post` with its own closures; the slot offers « Fermer » meanwhile.
                continue
            }
        }
        if !actions.contains(where: { $0.id == "close" || $0.id == "later" }) {
            actions.append(FeedbackItem.Action(id: "close", title: L("Close")) { [weak self] in self?.dismiss(id) })
        }
        return post(FeedbackItem(id: id, kind: .error, text: error.message(french: french), systemImage: "exclamationmark.triangle.fill",
                                 actions: actions))
    }

    // MARK: Showing

    private func refresh() {
        let next = queue.current.flatMap { items[$0.id] }
        guard next?.id != current?.id || next != current else { return }
        let changed = next?.id != current?.id
        current = next
        guard changed else { return }
        expiry?.cancel()
        guard let next else { return }
        announce(next)
        guard let seconds = next.kind.duration(voiceOver: UIAccessibility.isVoiceOverRunning) else { return }
        let id = next.id
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    private func moveToConversation(_ ids: [UUID]) {
        for id in ids {
            if let item = items[id] { conversation.append(item) }
            items[id] = nil
        }
    }

    private func announce(_ item: FeedbackItem) {
        let text = item.announcement ?? item.text
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// Canvas zone C (§4.7): the feedback capsule, bottom-centre over the canvas, never resizing it. At most 360 points
/// wide and 44–88 tall (two lines and actions), regular glass. Only the capsule is hit-testable.
struct FeedbackSlot: View {
    let announcer: Announcer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let item = announcer.current {
                FeedbackCapsule(item: item)
                    .id(item.id)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: PSMetrics.feedbackSlotMaxWidth)
        .animation(reduceMotion ? PSSpring.fade : PSSpring.quick, value: announcer.current?.id)
    }
}

/// One feedback item: glyph or progress, up to two lines, its actions.
private struct FeedbackCapsule: View {
    let item: FeedbackItem

    var body: some View {
        HStack(spacing: PSSpacing.small) {
            leading
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
            ForEach(item.actions) { action in
                FeedbackActionButton(action: action)
            }
        }
        .padding(.leading, PSSpacing.large)
        .padding(.trailing, item.actions.isEmpty ? PSSpacing.large : PSSpacing.xSmall)
        .frame(minHeight: PSMetrics.feedbackSlotMin)
        .frame(maxHeight: PSMetrics.feedbackSlotMax)
        .psGlass(shape: AnyShape(Capsule()))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .uxProbe(id: "feedback.slot", role: .slot)
    }

    /// The job's percentage after its title (« Effacement… 42 % »).
    private var text: String {
        guard item.kind == .job, let progress = item.progress else { return item.text }
        return item.text + " " + progress.formatted(.percent.precision(.fractionLength(0)))
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .job {
            if let progress = item.progress {
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.circular)
                    .tint(Color.psTextPrimary)
            } else {
                ProgressView()
                    .tint(Color.psTextPrimary)
            }
        } else if let symbol = item.systemImage {
            Image(systemName: symbol)
                .font(PSFont.glyph(.chip))
                .foregroundStyle(item.kind == .error ? Color.psDanger : Color.psTextPrimary)
                .accessibilityHidden(true)
        }
    }
}

private struct FeedbackActionButton: View {
    let action: FeedbackItem.Action

    var body: some View {
        Button {
            Haptics.tap()
            action.run()
        } label: {
            Group {
                if action.isGlyphOnly, let symbol = action.systemImage {
                    Image(systemName: symbol)
                        .font(PSFont.glyph(.chip, weight: .semibold))
                        .frame(width: PSMetrics.hitMinimum, height: PSMetrics.hitMinimum)
                } else {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, PSSpacing.medium)
                        .frame(minHeight: PSMetrics.hitMinimum)
                }
            }
            .foregroundStyle(Color.psTextPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.4)
        .accessibilityLabel(action.title)
        .uxProbe(id: "feedback.\(action.id)")
    }
}
#endif
