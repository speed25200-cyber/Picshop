#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// What the compare button does in an editor.
struct CompareControl {
    /// The side-by-side split is showing.
    var isSplit: Bool
    /// The split is offered (the frame is still the original's).
    var canSplit: Bool
    var toggleSplit: () -> Void
    /// Shows the original while true.
    var showOriginal: (Bool) -> Void
    /// There is something to compare (an edit, or edits from an earlier session).
    var isEnabled: Bool = true
}

/// Before/after, always one tap away in the top bar, in one glass shape with
/// Undo and Redo. A tap shows the split (when the frame allows it; otherwise
/// the original for a moment); a hold shows the original until the finger
/// lifts. White disc and black glyph while the split shows.
struct CompareButton: View {
    let control: CompareControl

    @State private var isPressing = false
    @State private var isHolding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var flashTask: Task<Void, Never>?
    @Environment(\.colorSchemeContrast) private var contrast

    /// How long a press must last to become a hold.
    static let holdDelay: Duration = .milliseconds(250)
    /// A tap without the split shows the original this long.
    static let flashDuration: Duration = .milliseconds(1200)

    var body: some View {
        let selected = control.isSplit || isHolding
        Image(systemName: "square.split.2x1")
            .font(PSFont.glyph(.bar))
            .foregroundStyle(selected ? Color.psOnAction : Color.psTextPrimary)
            .frame(width: PSMetrics.barButton, height: PSMetrics.barButton)
            .background { if selected { Circle().fill(Color.psActionPrimary) } }
            .contentShape(Circle())
            .scaleEffect(isPressing ? 0.92 : 1)
            .psGlass(interactive: true, shape: AnyShape(Circle()))
            .opacity(control.isEnabled ? 1 : (contrast == .increased ? 0.5 : 0.35))
            .animation(PSSpring.press, value: isPressing)
            .animation(PSSpring.quick, value: selected)
            .gesture(press, including: control.isEnabled ? .all : .none)
            .onDisappear(perform: reset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Before/after"))
            .accessibilityValue(control.isSplit ? L("Side by side") : "")
            .accessibilityHint(L("Double-tap to split, hold for the original."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction { if control.isEnabled { tap() } }
            .accessibilityAction(named: Text(L("Show the original"))) {
                guard control.isEnabled else { return }
                flashOriginal()
            }
    }

    /// One touch: a hold after 250 ms shows the original until release; a shorter touch is a tap.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressing else { return }
                isPressing = true
                holdTask?.cancel()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.holdDelay)
                    guard !Task.isCancelled, isPressing else { return }
                    isHolding = true
                    Haptics.soft(0.6)
                    control.showOriginal(true)
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                isPressing = false
                if isHolding {
                    isHolding = false
                    control.showOriginal(false)
                } else {
                    tap()
                }
            }
    }

    private func tap() {
        if control.canSplit || control.isSplit {
            Haptics.tick()
            withAnimation(PSSpring.quick) { control.toggleSplit() }
        } else {
            flashOriginal()
        }
    }

    /// The original for a moment, where the split cannot line pixels up.
    private func flashOriginal() {
        Haptics.soft(0.6)
        flashTask?.cancel()
        control.showOriginal(true)
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled else { return }
            control.showOriginal(false)
        }
    }

    private func reset() {
        holdTask?.cancel()
        flashTask?.cancel()
        if isHolding || flashTask != nil { control.showOriginal(false) }
        isHolding = false
        isPressing = false
    }
}
// MARK: - UX 2.0: « ◐ Avant » (ux-spec §4.10)

/// What « ◐ Avant » shows and does in an editor.
struct BeforeAfterControl {
    /// The original is showing (the toggle is on, or a hold peeks).
    var showsOriginal: Bool
    /// There is something to compare: an edit, or edits from an earlier session. Disabled before the first edit.
    var isEnabled: Bool
    /// Shows or hides the original. Comparing is never a trap: the editor itself turns it off before any slider
    /// drag, brush stroke, editing gesture, tool or panel change, ↶ / ↷ or AI result (AC-19), with a soft haptic
    /// and the announcement « Retouches affichées ».
    var setShowsOriginal: (Bool) -> Void
}

/// « ◐ Avant », the same word in photo, video and PDF, in canvas zone B (top right). A tap toggles the original
/// (the button stays white while it shows); a hold peeks while the finger is down. There is no hold-to-compare on
/// the canvas any more: this button is the one way to compare (P11).
struct CompareAvantButton: View {
    let control: BeforeAfterControl

    @State private var isPressing = false
    @State private var isPeeking = false
    @State private var wasOn = false
    @State private var holdTask: Task<Void, Never>?
    @Environment(\.colorSchemeContrast) private var contrast

    /// How long a press must last to become a peek.
    static let holdDelay: Duration = .milliseconds(250)

    var body: some View {
        let isOn = control.showsOriginal
        HStack(spacing: PSSpacing.xSmall + 2) {
            Image(systemName: "circle.lefthalf.filled")
            Text(L("Before"))
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isOn ? Color.psOnAction : Color.psTextPrimary)
        .padding(.horizontal, PSSpacing.medium + 2)
        .frame(height: PSMetrics.barButton)
        .background { if isOn { Capsule().fill(Color.psActionPrimary) } }
        .contentShape(Capsule())
        .scaleEffect(isPressing ? 0.95 : 1)
        .psGlass(interactive: true, shape: AnyShape(Capsule()))
        .opacity(control.isEnabled ? 1 : (contrast == .increased ? 0.5 : 0.35))
        .animation(PSSpring.press, value: isPressing)
        .animation(PSSpring.quick, value: isOn)
        .gesture(press, including: control.isEnabled ? .all : .none)
        .onDisappear(perform: reset)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Before"))
        .accessibilityValue(isOn ? L("Showing the original") : "")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { if control.isEnabled { toggle() } }
        .accessibilityShowsLargeContentViewer {
            Label(L("Before"), systemImage: "circle.lefthalf.filled")
        }
        .uxProbe(id: "canvas.compare", role: .compare)
    }

    /// One touch: a hold of 250 ms peeks until release; a shorter touch toggles.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressing else { return }
                isPressing = true
                holdTask?.cancel()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.holdDelay)
                    guard !Task.isCancelled, isPressing else { return }
                    wasOn = control.showsOriginal
                    isPeeking = true
                    Haptics.soft(0.6)
                    control.setShowsOriginal(true)
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                isPressing = false
                if isPeeking {
                    isPeeking = false
                    control.setShowsOriginal(wasOn)
                } else {
                    toggle()
                }
            }
    }

    private func toggle() {
        Haptics.tick()
        control.setShowsOriginal(!control.showsOriginal)
    }

    private func reset() {
        holdTask?.cancel()
        holdTask = nil
        if isPeeking { control.setShowsOriginal(wasOn) }
        isPeeking = false
        isPressing = false
    }
}
#endif
