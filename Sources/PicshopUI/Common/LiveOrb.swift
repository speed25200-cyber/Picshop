#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// Picshop Live's one presence on screen: a living sphere whose colours,
/// motion and scale say what Live is doing.
///
/// Only the orb (and its halo) reads `meter`, so the 30 Hz audio levels never
/// re-evaluate anything else. `meter` is nil where there is no audio (Settings,
/// Home's empty state).
///
/// Phase 0: a still mesh in the state's palette, the muted and problem marks.
/// The halo, the drifting centre, rotation, ripples and progress ring follow.
struct LiveOrb: View {
    let size: CGFloat
    let state: LiveState
    let meter: LiveMeter?
    var isMuted: Bool

    init(size: CGFloat, state: LiveState, meter: LiveMeter?, isMuted: Bool = false) {
        self.size = size
        self.state = state
        self.meter = meter
        self.isMuted = isMuted
    }

    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5, 0.5], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: OrbPalette.mesh(for: state, isMuted: isMuted))
        .clipShape(Circle())
        .overlay {
            // Specular highlight, then the rim.
            Ellipse()
                .fill(Color.white.opacity(0.32))
                .frame(width: size * 0.46, height: size * 0.30)
                .blur(radius: size * 0.06)
                .offset(y: -size * 0.22)
        }
        .overlay {
            Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) { badge }
        .frame(width: size, height: size)
        .animation(PSMotion.orbState, value: state)
        .animation(PSMotion.orbState, value: isMuted)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        if isMuted {
            mark("mic.slash.fill")
        } else if isProblem {
            mark("exclamationmark")
        }
    }

    private var isProblem: Bool {
        if case .problem = state { return true }
        return false
    }

    private func mark(_ symbol: String) -> some View {
        let side = max(14, size * 0.34)
        return Image(systemName: symbol)
            .font(.system(size: side * 0.5, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(width: side, height: side)
            .background(Circle().fill(Color.white))
            .offset(x: side * 0.1, y: side * 0.1)
    }
}

/// The tappable orb: tap, and hold for push-to-talk. The owner decides what a
/// tap means for the current state (D5); the button only reports it.
///
/// Phase 0: tap only. The 0.25 s hold (onHoldStart / onHoldEnd), the custom
/// accessibility actions and the per-state accessibility values follow.
struct LiveOrbButton: View {
    let size: CGFloat
    let state: LiveState
    let meter: LiveMeter?
    var isMuted: Bool
    let onTap: () -> Void
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    init(size: CGFloat, state: LiveState, meter: LiveMeter?, isMuted: Bool = false,
         onTap: @escaping () -> Void, onHoldStart: (() -> Void)? = nil, onHoldEnd: (() -> Void)? = nil) {
        self.size = size
        self.state = state
        self.meter = meter
        self.isMuted = isMuted
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
    }

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            LiveOrb(size: size, state: state, meter: meter, isMuted: isMuted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(Text(verbatim: "PicShop Live"))
    }
}

#if DEBUG
private struct LiveOrbGallery: View {
    private let states: [LiveState] = [.off, .connecting, .listening, .hearing, .thinking, .speaking, .acting, .dictating, .problem(.offline)]

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 16) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    LiveOrb(size: PSMetrics.orbConsole, state: state, meter: nil)
                }
                LiveOrb(size: PSMetrics.orbConsole, state: .listening, meter: nil, isMuted: true)
            }
            LiveOrb(size: PSMetrics.orbHero, state: .off, meter: nil)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
    }
}

#Preview("LiveOrb states") {
    LiveOrbGallery()
}
#endif
#endif
