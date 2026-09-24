#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// Picshop Live's one presence on screen: a living sphere whose colours,
/// motion and scale say what Live is doing.
///
/// Layers, bottom to top: a blurred halo, then in one `drawingGroup` the mesh
/// body (its centre drifting on a Lissajous path, turning while it thinks or
/// acts), the specular highlight, the rim, the thinking comet, the speaking
/// ripples and the acting ring. The muted and problem marks sit on top.
///
/// Only the orb (and its halo) reads `meter`, so the 30 Hz audio levels never
/// re-evaluate anything else. `meter` is nil where there is no audio (Settings,
/// Home's empty state). It holds still with Reduce Motion, when the scene is
/// inactive or the orb is off screen, and is a flat radial gradient at `.minimal`.
struct LiveOrb: View {
    let size: CGFloat
    let state: LiveState
    let meter: LiveMeter?
    var isMuted: Bool
    /// While acting: the job's fraction for the ring; nil draws a spectrum comet.
    var progress: Double?

    @Environment(\.psEffects) private var effects
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.psReducedMotion) private var psReducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = OrbMotion()
    @State private var isOnScreen = true
    @State private var pulse = false

    init(size: CGFloat, state: LiveState, meter: LiveMeter?, isMuted: Bool = false) {
        self.size = size
        self.state = state
        self.meter = meter
        self.isMuted = isMuted
    }

    /// The acting ring's fraction (nil: the spectrum comet).
    func actingProgress(_ progress: Double?) -> LiveOrb {
        var copy = self
        copy.progress = progress
        return copy
    }

    private var paletteKey: String { OrbPalette.paletteKey(for: state, isMuted: isMuted) }
    private var holdsStill: Bool { reduceMotion || psReducedMotion }

    var body: some View {
        content
            .frame(width: size, height: size)
            .onAppear {
                isOnScreen = true
                motion.setPalette(OrbPalette.meshRGB(for: state, isMuted: isMuted), at: OrbMotion.now, duration: 0)
                startPulse()
            }
            .onDisappear { isOnScreen = false }
            .onChange(of: paletteKey) { _, _ in
                motion.setPalette(OrbPalette.meshRGB(for: state, isMuted: isMuted), at: OrbMotion.now, duration: 0.6)
            }
            .onChange(of: state) { old, new in
                motion.noteTransition(from: old, to: new, at: OrbMotion.now)
                startPulse()
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if effects == .minimal {
            flatOrb
        } else if holdsStill {
            stillOrb
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: frameInterval, paused: scenePhase != .active || !isOnScreen)) { context in
                livingOrb(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// 60 fps at rich effects, 30 when reduced; the slow resting drift needs no more than 30.
    private var frameInterval: Double {
        effects == .rich && state != .off ? 1.0 / 60.0 : 1.0 / 30.0
    }

    // MARK: Living

    private func livingOrb(time t: Double) -> some View {
        let input = meter?.input ?? 0
        let output = meter?.output ?? 0
        let dynamics = OrbDynamics(state: state, input: input, output: output, isMuted: isMuted)
        let m = motion
        let dt = m.advance(to: t)
        m.phase += dynamics.omega * dt
        switch state {
        case .thinking: m.rotation += 90 * dt
        case .acting: m.rotation += 60 * dt
        default: break
        }
        m.cometTurns += dt / 1.1
        m.scale += (dynamics.targetScale(at: t) - m.scale) * min(1, dt * 12)
        m.updateRipples(speaking: state == .speaking, output: output, at: t)
        let colors = m.paletteColors(at: t, fallback: OrbPalette.meshRGB(for: state, isMuted: isMuted))
        return orbStack(points: dynamics.points(phase: m.phase), colors: colors.map(\.color),
                        rotation: m.rotation, scale: m.scale * m.popScale(at: t),
                        cometTurns: m.cometTurns, ripples: m.rippleStates(at: t),
                        haloOpacity: dynamics.haloOpacity, haloColor: colors[4].color)
    }

    // MARK: Still (Reduce Motion, or no timeline)

    private var stillOrb: some View {
        let input = meter?.input ?? 0
        let output = meter?.output ?? 0
        let colors = OrbPalette.meshRGB(for: state, isMuted: isMuted)
        // The halo follows the voice level and nothing else moves.
        let level: Double
        switch state {
        case .hearing, .dictating: level = input
        case .speaking: level = output
        default: level = 0
        }
        return orbStack(points: OrbDynamics.restPoints, colors: colors.map(\.color), rotation: 0, scale: 1,
                        cometTurns: nil, ripples: [], haloOpacity: level * (isMuted ? 0.4 : 1), haloColor: colors[4].color)
            .opacity(state == .thinking && pulse ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.4), value: paletteKey)
    }

    /// Thinking under Reduce Motion: an opacity pulse, the one change allowed.
    private func startPulse() {
        guard holdsStill else { return }
        if state == .thinking {
            pulse = false
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        } else if pulse {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pulse = false }
        }
    }

    // MARK: Flat (.minimal)

    private var flatOrb: some View {
        let k = OrbPalette.meshRGB(for: state, isMuted: isMuted)
        return Circle()
            .fill(RadialGradient(colors: [k[4].color, k[1].color, k[6].color], center: UnitPoint(x: 0.4, y: 0.35),
                                 startRadius: 0, endRadius: size * 0.62))
            .overlay { rim }
            .overlay { marks }
            .opacity(isMuted ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.3), value: paletteKey)
    }

    // MARK: Layers

    private func orbStack(points: [SIMD2<Float>], colors: [Color], rotation: Double, scale: Double, cometTurns: Double?,
                          ripples: [OrbMotion.RippleState], haloOpacity: Double, haloColor: Color) -> some View {
        let canvas = size * 1.9
        return ZStack {
            ZStack {
                MeshGradient(width: 3, height: 3, points: points, colors: colors)
                    .rotationEffect(.degrees(rotation))
                // Specular highlight: light from the top left.
                Ellipse()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: size * 0.46, height: size * 0.30)
                    .blur(radius: size * 0.08)
                    .offset(x: -size * 0.16, y: -size * 0.22)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .opacity(isMuted ? 0.75 : 1)
            rim.frame(width: size, height: size)
            ForEach(Array(ripples.enumerated()), id: \.offset) { _, ripple in
                Circle()
                    .stroke(Color.white.opacity(ripple.opacity), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(ripple.scale)
            }
            if let cometTurns {
                ring(cometTurns: cometTurns)
            } else if state == .acting, let progress {
                progressRing(progress)
            }
        }
        .scaleEffect(scale)
        .frame(width: canvas, height: canvas)
        .drawingGroup()
        .frame(width: size, height: size)
        .background {
            if effects != .minimal {
                Circle()
                    .fill(RadialGradient(colors: [haloColor.opacity(0.55), haloColor.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: size * 1.1))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .blur(radius: min(26, size * 0.22))
                    .opacity(haloOpacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay { marks }
    }

    /// Thinking: a white comet; acting: the progress ring, or a spectrum comet.
    @ViewBuilder
    private func ring(cometTurns: Double) -> some View {
        switch state {
        case .thinking:
            comet(colors: [Color.white.opacity(0), Color.white], turns: cometTurns)
        case .acting:
            if let progress {
                progressRing(progress)
            } else {
                comet(colors: [PSTheme.intelligence[0].opacity(0)] + PSTheme.intelligence, turns: cometTurns)
            }
        default:
            EmptyView()
        }
    }

    private func comet(colors: [Color], turns: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(0.22 * 360)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: size + 8, height: size + 8)
            .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size + 8, height: size + 8)
    }

    private var rim: some View {
        Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }

    /// Muted: a mic.slash badge; a problem: an exclamation mark (mic.slash without a microphone).
    @ViewBuilder
    private var marks: some View {
        if case .problem(let problem) = state {
            Image(systemName: problem == .noMicrophone ? "mic.slash" : "exclamationmark")
                .font(.system(size: max(10, size * 0.3), weight: .semibold))
                .foregroundStyle(Color.white)
        } else if isMuted {
            let side = max(14, min(20, size * 0.38))
            Image(systemName: "mic.slash.fill")
                .font(.system(size: side * 0.55, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: side, height: side)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: side * 0.15, y: side * 0.15)
        }
    }

    /// What VoiceOver says the orb is doing.
    static func accessibilityValue(state: LiveState, isMuted: Bool, activity: String?) -> String {
        if isMuted, state != .off, state != .dictating { return L("muted") }
        switch state {
        case .off: return L("off")
        case .connecting, .listening: return L("listening")
        case .hearing, .dictating: return L("hearing you")
        case .thinking: return L("thinking")
        case .speaking: return L("speaking")
        case .acting:
            guard let activity, !activity.isEmpty else { return L("applying") }
            return String(format: L("applying: %@"), activity)
        case .problem(let problem):
            return String(format: L("problem: %@"), LiveLines.problem(problem, psPrefersFrench ? .french : .english))
        }
    }
}

// MARK: - Motion

/// How the orb moves in one state, from the levels (0…1).
struct OrbDynamics {
    var state: LiveState
    var input: Double
    var output: Double
    var isMuted: Bool

    /// The level that widens the drift.
    var level: Double {
        switch state {
        case .listening, .connecting, .hearing, .dictating: return isMuted ? 0 : input
        case .speaking: return output
        default: return 0
        }
    }

    /// Angular speed of the centre's drift, radians per second.
    var omega: Double {
        switch state {
        case .off: return 0.35
        case .connecting, .listening: return 0.8
        case .hearing, .dictating: return 1.2 + 2 * input
        case .thinking: return 2.2
        case .speaking: return 1.0 + 1.5 * output
        case .acting: return 1.6
        case .problem: return 0.5
        }
    }

    var haloOpacity: Double {
        let base: Double
        switch state {
        case .off: base = 0
        case .connecting, .listening: base = 0.30
        case .hearing, .dictating: base = 0.30 + 0.45 * input
        case .thinking: base = 0.35
        case .speaking: base = 0.30 + 0.35 * output
        case .acting: base = 0.40
        case .problem: base = 0.35
        }
        return base * (isMuted ? 0.4 : 1)
    }

    /// The scale the orb eases towards; breathing is a slow sine.
    func targetScale(at time: Double) -> Double {
        func breathe(_ amount: Double, period: Double) -> Double { amount * sin(2 * .pi * time / period) }
        switch state {
        case .off: return 1 + breathe(0.02, period: 4)
        case .connecting, .listening: return 1 + breathe(0.03, period: 2.4)
        case .hearing, .dictating: return 1 + 0.16 * input
        case .thinking: return 0.95 + breathe(0.015, period: 2.4)
        case .speaking: return 1 + 0.10 * output
        case .acting: return 0.92
        case .problem: return 1
        }
    }

    /// The 3 × 3 mesh: fixed corners, edge midpoints drifting ±0.04, the centre on
    /// x = 0.5 + A sin(φ), y = 0.5 + A cos(0.83 φ + 1.1), with A = 0.06 + 0.10 × level.
    func points(phase: Double) -> [SIMD2<Float>] {
        let amplitude = 0.06 + 0.10 * min(1, max(0, level))
        let cx = Float(0.5 + amplitude * sin(phase))
        let cy = Float(0.5 + amplitude * cos(0.83 * phase + 1.1))
        func drift(_ k: Double, _ shift: Double) -> Float { Float(0.5 + 0.04 * sin(phase * k + shift)) }
        return [
            [0, 0], [drift(0.7, 0), 0], [1, 0],
            [0, drift(0.6, 1.3)], [cx, cy], [1, drift(0.9, 0.8)],
            [0, 1], [drift(0.8, 2.1), 1], [1, 1],
        ]
    }

    static let restPoints: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    /// A spring from `from` to `to` with zero initial velocity, SwiftUI's
    /// `.spring(duration:bounce:)` parameters, `elapsed` seconds in.
    static func spring(from: Double, to: Double, elapsed: Double, duration: Double, bounce: Double) -> Double {
        let t = max(0, elapsed)
        let omega = 2 * Double.pi / duration
        let zeta = min(0.999, max(0.05, 1 - bounce))
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let envelope = exp(-zeta * omega * t)
        return to + (from - to) * envelope * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
    }
}

/// Frame-to-frame state of a living orb: phases are integrated, so a change of
/// speed never makes the drift jump. A plain reference kept in `@State`; not observed.
final class OrbMotion {
    struct RippleState: Equatable {
        var scale: Double
        var opacity: Double
    }

    static var now: Double { Date().timeIntervalSinceReferenceDate }

    private(set) var lastTime: Double?
    var phase: Double = 0
    var rotation: Double = 0
    var cometTurns: Double = 0
    var scale: Double = 1
    private(set) var ripples: [Double] = []
    private var rippleArmed = true
    private var lastRipple = -Double.infinity
    private var shownColors: [OrbRGB] = []
    private var fromColors: [OrbRGB] = []
    private var toColors: [OrbRGB] = []
    private var paletteStart = -Double.infinity
    private var paletteDuration = 0.6
    private var bloomStart: Double?
    private var dipStart: Double?

    /// Seconds since the previous frame, at most 1/15 s, so a resumed timeline never jumps.
    func advance(to time: Double) -> Double {
        defer { self.lastTime = time }
        guard let lastTime else { return 0 }
        return min(1.0 / 15.0, max(0, time - lastTime))
    }

    /// Cross-fades from what is on screen to `target` over `duration` seconds.
    func setPalette(_ target: [OrbRGB], at time: Double, duration: Double) {
        guard target != toColors || duration == 0 else { return }
        fromColors = shownColors.count == target.count ? shownColors : target
        toColors = target
        paletteStart = time
        paletteDuration = duration
        if duration == 0 { shownColors = target }
    }

    /// The mesh colours for this frame; `fallback` until a palette is set.
    func paletteColors(at time: Double, fallback: [OrbRGB]) -> [OrbRGB] {
        guard !toColors.isEmpty else {
            setPalette(fallback, at: time, duration: 0)
            return fallback
        }
        let progress = paletteDuration > 0 ? min(1, max(0, (time - paletteStart) / paletteDuration)) : 1
        // Smoothstep, close to `.smooth`.
        let eased = progress * progress * (3 - 2 * progress)
        shownColors = zip(fromColors, toColors).map { $0.mixed(with: $1, eased) }
        if shownColors.count != toColors.count { shownColors = toColors }
        return shownColors
    }

    /// Leaving `.off` blooms 0.6 → 1; a barge-in dips to 0.88 and springs back.
    func noteTransition(from old: LiveState, to new: LiveState, at time: Double) {
        if old == .off, new != .off { bloomStart = time }
        switch (old, new) {
        case (.speaking, .hearing), (.thinking, .hearing), (.acting, .hearing): dipStart = time
        default: break
        }
        if new != .speaking { ripples = [] }
    }

    /// Bloom and barge-in dip, multiplied.
    func popScale(at time: Double) -> Double {
        var value = 1.0
        if let start = bloomStart {
            let elapsed = time - start
            if elapsed < 1 {
                value *= OrbDynamics.spring(from: 0.6, to: 1, elapsed: elapsed, duration: 0.55, bounce: 0.22)
            } else {
                bloomStart = nil
            }
        }
        if let start = dipStart {
            let elapsed = max(0, time - start)
            if elapsed < 0.06 {
                value *= 1 - 0.12 * (elapsed / 0.06)
            } else if elapsed < 0.6 {
                value *= OrbDynamics.spring(from: 0.88, to: 1, elapsed: elapsed - 0.06, duration: 0.22, bounce: 0.35)
            } else {
                dipStart = nil
            }
        }
        return value
    }

    /// A ripple starts when the voice rises above 0.45 after being below 0.30,
    /// at least 250 ms after the last one; at most 3 at once, 0.9 s each.
    func updateRipples(speaking: Bool, output: Double, at time: Double) {
        ripples.removeAll { time - $0 >= 0.9 }
        guard speaking else {
            rippleArmed = true
            return
        }
        if output < 0.30 { rippleArmed = true }
        if rippleArmed, output > 0.45, time - lastRipple >= 0.25, ripples.count < 3 {
            ripples.append(time)
            lastRipple = time
            rippleArmed = false
        }
    }

    /// Each ripple grows 1 → 1.55 while fading 0.45 → 0 (ease-out).
    func rippleStates(at time: Double) -> [RippleState] {
        ripples.map { start in
            let progress = min(1, max(0, (time - start) / 0.9))
            let eased = 1 - (1 - progress) * (1 - progress)
            return RippleState(scale: 1 + 0.55 * eased, opacity: 0.45 * (1 - eased))
        }
    }
}

// MARK: - Button

/// VoiceOver's custom actions on the orb while Live runs.
struct LiveOrbActions {
    var setMuted: (Bool) -> Void
    var interrupt: () -> Void
    var end: () -> Void
}

/// The tappable orb: a tap, and a 0.25 s hold for push-to-talk. The owner
/// decides what a tap means for the current state (D5); the button only
/// reports it. Without `onHoldStart`, a long press does nothing.
struct LiveOrbButton: View {
    let size: CGFloat
    let state: LiveState
    let meter: LiveMeter?
    var isMuted: Bool
    let onTap: () -> Void
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    private var progress: Double?
    private var activity: String?
    private var actions: LiveOrbActions?

    @GestureState private var isTouching = false
    @State private var pressBegan: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false
    @State private var didHold = false

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

    /// The acting ring's fraction.
    func actingProgress(_ progress: Double?) -> LiveOrbButton {
        var copy = self
        copy.progress = progress
        return copy
    }

    /// The running activity for VoiceOver's value, and the custom actions (Live only).
    func liveAccessibility(activity: String?, actions: LiveOrbActions?) -> LiveOrbButton {
        var copy = self
        copy.activity = activity
        copy.actions = actions
        return copy
    }

    var body: some View {
        LiveOrb(size: size, state: state, meter: meter, isMuted: isMuted)
            .actingProgress(progress)
            .scaleEffect(isTouching ? 0.94 : 1)
            .animation(PSMotion.quick, value: isTouching)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
            .gesture(press)
            .onChange(of: isTouching) { _, touching in
                if !touching { finishCancelledPress() }
            }
            .onAppear { Haptics.prepare() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim: "PicShop Live"))
            .accessibilityValue(LiveOrb.accessibilityValue(state: state, isMuted: isMuted, activity: activity))
            .accessibilityHint(state == .off ? L("Double-tap to talk live. Double-tap and hold to dictate one request.") : "")
            .accessibilityAction { activate() }
            .modifier(LiveOrbCustomActions(actions: actions, isMuted: isMuted))
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { _ in
                guard pressBegan == nil else { return }
                pressBegan = Date()
                didHold = false
                guard onHoldStart != nil else { return }
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, pressBegan != nil else { return }
                    isHolding = true
                    didHold = true
                    Haptics.soft(0.5)
                    onHoldStart?()
                }
            }
            .onEnded { value in
                let began = pressBegan
                pressBegan = nil
                holdTask?.cancel()
                holdTask = nil
                if isHolding {
                    isHolding = false
                    onHoldEnd?()
                    return
                }
                guard !didHold else { return }
                let duration = began.map { Date().timeIntervalSince($0) } ?? 0
                let moved = (value.translation.width * value.translation.width + value.translation.height * value.translation.height).squareRoot()
                // A long press with no hold behaviour (the console's orb) does nothing.
                guard moved < 30, onHoldStart != nil || duration < 0.5 else { return }
                activate()
            }
    }

    /// The system cancelled the touch (no onEnded): release a hold that started.
    private func finishCancelledPress() {
        DispatchQueue.main.async {
            guard pressBegan != nil else { return }
            pressBegan = nil
            holdTask?.cancel()
            holdTask = nil
            if isHolding {
                isHolding = false
                onHoldEnd?()
            }
        }
    }

    private func activate() {
        // No vibration while the microphone listens: it can reach it.
        if state != .hearing, state != .dictating { Haptics.tap() }
        onTap()
    }
}

private struct LiveOrbCustomActions: ViewModifier {
    let actions: LiveOrbActions?
    let isMuted: Bool

    func body(content: Content) -> some View {
        if let actions {
            content
                .accessibilityAction(named: Text(isMuted ? L("Unmute microphone") : L("Mute microphone"))) { actions.setMuted(!isMuted) }
                .accessibilityAction(named: Text(L("Interrupt"))) { actions.interrupt() }
                .accessibilityAction(named: Text(L("End Live"))) { actions.end() }
        } else {
            content
        }
    }
}

#if DEBUG
private struct LiveOrbGallery: View {
    private let states: [LiveState] = [.off, .connecting, .listening, .hearing, .thinking, .speaking, .acting, .dictating, .problem(.offline), .problem(.noMicrophone)]
    @State private var live: LiveSession?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 24) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        VStack(spacing: 8) {
                            LiveOrb(size: PSMetrics.orbConsole, state: state, meter: live?.meter)
                                .actingProgress(state == .acting ? 0.4 : nil)
                            Text(LiveOrb.accessibilityValue(state: state, isMuted: false, activity: "Ciel"))
                                .font(.caption2).foregroundStyle(PSTheme.textSecondary)
                        }
                        .frame(height: 120)
                    }
                    LiveOrb(size: PSMetrics.orbConsole, state: .listening, meter: nil, isMuted: true)
                        .frame(height: 120)
                }
                if let live {
                    LiveOrbButton(size: PSMetrics.orbHero, state: live.state, meter: live.meter, isMuted: live.isMuted, onTap: {})
                    LiveOrb(size: PSMetrics.orbMini, state: live.state, meter: live.meter)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .onAppear { if live == nil { live = LiveSession.preview(.cycle) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("LiveOrb states") {
    LiveOrbGallery()
}

#Preview("LiveOrb minimal") {
    LiveOrbGallery().environment(\.psEffects, .minimal)
}
#endif
#endif
