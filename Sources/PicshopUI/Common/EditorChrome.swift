#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Shared editor shell. The canvas fills the screen; the top bar and the
/// bottom controls are safe-area insets, so the canvas always knows exactly
/// how much room is visible and frames the picture inside it.
struct EditorChrome<Canvas: View, Top: View, Bottom: View>: View {
    @ViewBuilder var canvas: () -> Canvas
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        GeometryReader { proxy in
            // Presented editors occasionally receive zero safe-area insets from SwiftUI; the
            // window always knows the real status bar / home indicator geometry.
            let window = WindowInsets.current
            let extraTop = max(0, window.top - proxy.safeAreaInsets.top)
            let extraBottom = max(0, window.bottom - proxy.safeAreaInsets.bottom)
            canvas()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { top().padding(.top, extraTop) }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottom().padding(.bottom, extraBottom) }
        }
        .background(PSTheme.canvas.ignoresSafeArea())
    }
}

/// Safe-area insets of the key window (status bar, Dynamic Island, home indicator).
enum WindowInsets {
    @MainActor static var current: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? .zero
    }
}

/// A soft fall-off behind the bottom controls so they read on any picture,
/// without a visible band.
struct DockBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            LinearGradient(stops: [
                .init(color: PSTheme.canvas.opacity(0), location: 0),
                .init(color: PSTheme.canvas.opacity(0.55), location: 0.35),
                .init(color: PSTheme.canvas.opacity(0.92), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func psDockBackground() -> some View { modifier(DockBackground()) }
}

// MARK: - Top bar

/// Floating glass controls: close on the left, the document's name in the
/// middle, history and export on the right — nothing else on top of the picture.
struct EditorTopBar: View {
    var title: String
    var subtitle: String? = nil
    var canUndo: Bool
    var canRedo: Bool
    var onClose: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onHelp: () -> Void
    var onExport: () -> Void

    var body: some View {
        PSGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                GlassIconButton("xmark", label: L("Close"), size: 42, action: onClose)
                Spacer(minLength: 4)
                VStack(spacing: 1) {
                    Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
                .allowsHitTesting(false)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    barButton("arrow.uturn.backward", label: L("Undo"), enabled: canUndo, action: onUndo)
                    barButton("arrow.uturn.forward", label: L("Redo"), enabled: canRedo, action: onRedo)
                    barButton("questionmark", label: L("Help"), enabled: true, action: onHelp)
                }
                .padding(.horizontal, 2)
                .psGlass(interactive: true)
                .animation(PSMotion.quick, value: canUndo)
                .animation(PSMotion.quick, value: canRedo)
                Button { Haptics.confirm(); onExport() } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.black)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(L("Export"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [PSTheme.canvas.opacity(0.75), PSTheme.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        )
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 42).contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .disabled(!enabled)
        .foregroundStyle(enabled ? PSTheme.textPrimary : PSTheme.textQuaternary)
        .accessibilityLabel(label)
    }
}

// MARK: - Tool dock

/// The tool bar at the bottom: one glass capsule of tools. The chosen tool's
/// glyph turns edit-yellow and a lit thumb slides behind it; the row scrolls
/// only when it has to.
struct ToolDock<Tool: Identifiable & Hashable>: View {
    let tools: [Tool]
    @Binding var selection: Tool?
    var title: (Tool) -> String
    var symbol: (Tool) -> String
    /// Tools drawn with the intelligence spectrum (the Magic entry).
    var isMagic: (Tool) -> Bool = { _ in false }
    var onSelect: ((Tool?) -> Void)? = nil

    @Namespace private var indicator

    private let preferredItemWidth: CGFloat = 62
    private let minimumItemWidth: CGFloat = 52

    private func itemWidth(in available: CGFloat) -> CGFloat {
        let fitting = (available - 12) / CGFloat(max(1, tools.count))
        return min(preferredItemWidth, max(minimumItemWidth, fitting))
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = itemWidth(in: proxy.size.width)
            let scrolls = CGFloat(tools.count) * itemWidth + 12 > proxy.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tools) { tool in
                        item(tool, width: itemWidth)
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: proxy.size.width)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: scrolls ? 16 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: scrolls ? 16 : 0)
                }
            }
        }
        .frame(height: 60)
        .psGlass(shape: AnyShape(Capsule()))
    }

    private func item(_ tool: Tool, width: CGFloat) -> some View {
        let isActive = selection == tool
        let magic = isMagic(tool)
        return Button {
            Haptics.tap()
            let next: Tool? = isActive ? nil : tool
            withAnimation(PSMotion.standard) { selection = next }
            onSelect?(next)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if magic {
                        Image(systemName: symbol(tool)).psIntelligenceForeground()
                    } else {
                        Image(systemName: symbol(tool)).foregroundStyle(isActive ? PSTheme.accent : PSTheme.textPrimary)
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .symbolVariant(isActive ? .fill : .none)
                .symbolEffect(.bounce.down.byLayer, value: isActive)
                .frame(height: 22)
                Text(title(tool)).font(PSFont.label(10))
                    .foregroundStyle(isActive ? PSTheme.textPrimary : PSTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(width: width - 4, height: 52)
            .background {
                if isActive {
                    Capsule().fill(PSTheme.selection)
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.75))
                        .matchedGeometryEffect(id: "active", in: indicator)
                }
            }
            .contentShape(Capsule())
            .padding(.horizontal, 2)
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(title(tool))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// A dock entry that opens one panel with several sub-modes (segments in the
/// panel header). Tools are grouped by purpose so the dock stays short.
struct ToolGroup<Tool: Hashable & Identifiable>: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let tools: [Tool]
    var isMagic: Bool = false

    static func == (lhs: ToolGroup, rhs: ToolGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func contains(_ tool: Tool?) -> Bool { tool.map { tools.contains($0) } ?? false }
}

/// Dock showing tool groups; the selection stays a plain tool so the rest of
/// the editor is unaware of grouping. Each group remembers its last sub-mode.
struct GroupedToolDock<Tool: Hashable & Identifiable>: View {
    let groups: [ToolGroup<Tool>]
    @Binding var selection: Tool?
    @State private var lastTool: [String: Tool] = [:]

    var body: some View {
        ToolDock(tools: groups, selection: groupSelection, title: { $0.title }, symbol: { $0.symbol }, isMagic: { $0.isMagic })
            .onChange(of: selection) { _, tool in
                if let tool, let group = groups.first(where: { $0.contains(tool) }) { lastTool[group.id] = tool }
            }
    }

    private var groupSelection: Binding<ToolGroup<Tool>?> {
        Binding(
            get: { groups.first { $0.contains(selection) } },
            set: { group in
                guard let group else { selection = nil; return }
                selection = lastTool[group.id] ?? group.tools.first
            }
        )
    }
}

/// Segmented sub-mode picker shown in a panel header: a lit thumb sliding
/// behind the chosen one — the iOS segmented control, in glass.
struct ModeSegments<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    @Binding var selection: Mode?
    var title: (Mode) -> String
    var symbol: (Mode) -> String

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modes) { mode in
                let isActive = selection == mode
                Button {
                    Haptics.tick()
                    withAnimation(PSMotion.standard) { selection = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(mode)).font(.system(size: 11, weight: .semibold))
                        Text(title(mode)).font(PSFont.label(12)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isActive {
                            Capsule().fill(PSTheme.selection)
                                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.75))
                                .matchedGeometryEffect(id: "segment", in: indicator)
                        }
                    }
                    .foregroundStyle(isActive ? PSTheme.textPrimary : PSTheme.textSecondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

/// Glass panel that hosts the active tool's controls, with a small header.
/// A drag on the header (or a swipe down anywhere on the header row) closes it,
/// the way system sheets do.
struct ToolPanelContainer<Content: View>: View {
    var title: String
    var symbol: String
    var onClose: () -> Void
    var trailing: AnyView? = nil
    /// Sub-mode segments (see `ModeSegments`) rendered under the title.
    var modes: AnyView? = nil
    @ViewBuilder var content: () -> Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                    .contentTransition(.interpolate)
                Spacer()
                if let trailing { trailing }
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(PSTheme.textSecondary).frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(L("Close"))
            }
            .overlay(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 34, height: 4).offset(y: -9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        let shouldClose = value.translation.height > 48 || value.predictedEndTranslation.height > 140
                        withAnimation(PSMotion.standard) { dragOffset = 0 }
                        if shouldClose {
                            Haptics.tap()
                            onClose()
                        }
                    }
            )
            if let modes { modes }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .psCard(cornerRadius: PSRadius.panel)
        .offset(y: dragOffset * 0.5)
        .opacity(1 - Double(min(dragOffset, 120)) / 300)
    }
}

// MARK: - Dial

/// Photos' ruler dial. Drag to change the value with haptic ticks, double tap
/// to reset. The value reads above the centre mark and turns yellow as soon
/// as it leaves neutral.
struct DialSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var neutral: Double = 0
    var label: String? = nil
    /// Number of dial units across the full range (ticks are drawn per unit).
    var units: Double = 100
    var format: (Double) -> String = { value in
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var dragStartValue: Double?
    @State private var lastTick: Int = 0
    @State private var isDragging = false

    private var pointsPerUnit: CGFloat { 7 }
    private var unitValue: Double { (range.upperBound - range.lowerBound) / units }
    private var isNeutralValue: Bool { abs(value - neutral) < 0.0001 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let label { Text(label.uppercased()).font(PSFont.label(11)).tracking(0.6).foregroundStyle(PSTheme.textSecondary) }
                Spacer()
                Text(format(value))
                    .font(PSFont.mono(14).weight(.semibold))
                    .foregroundStyle(isNeutralValue ? PSTheme.textSecondary : PSTheme.accent)
                    .contentTransition(.numericText())
                    .animation(PSMotion.numeric, value: value)
                    .scaleEffect(isDragging ? 1.12 : 1, anchor: .trailing)
                    .animation(PSMotion.quick, value: isDragging)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let centerX = width / 2
                let markerColor = isNeutralValue ? Color.white : PSTheme.accent
                Canvas(rendersAsynchronously: true) { context, size in
                    let offset = CGFloat((value - range.lowerBound) / unitValue) * pointsPerUnit
                    let count = Int(units)
                    let neutralIndex = Int(((neutral - range.lowerBound) / unitValue).rounded())
                    var minor = Path()
                    var major = Path()
                    for index in 0...count {
                        let x = centerX - offset + CGFloat(index) * pointsPerUnit
                        guard x >= -2, x <= size.width + 2 else { continue }
                        let isMajor = index % 10 == 0
                        let height: CGFloat = isMajor ? 16 : 9
                        if index == neutralIndex {
                            // The neutral point: a dot above the ticks, like Photos.
                            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height / 2 - 14, width: 4, height: 4)), with: .color(.white.opacity(0.9)))
                        }
                        if isMajor {
                            major.move(to: CGPoint(x: x, y: size.height / 2 - height / 2 + 3))
                            major.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2 + 3))
                        } else {
                            minor.move(to: CGPoint(x: x, y: size.height / 2 - height / 2 + 3))
                            minor.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2 + 3))
                        }
                    }
                    let fade = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.7), Color.white.opacity(0.7), Color.white.opacity(0.0)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))
                    context.stroke(minor, with: fade, lineWidth: 1)
                    context.stroke(major, with: fade, lineWidth: 1.6)
                    var marker = Path()
                    marker.move(to: CGPoint(x: centerX, y: 2))
                    marker.addLine(to: CGPoint(x: centerX, y: size.height - 2))
                    context.stroke(marker, with: .color(markerColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            if dragStartValue == nil {
                                dragStartValue = value
                                lastTick = Int((value / unitValue).rounded())
                                isDragging = true
                                Haptics.prepare()
                                onEditingChanged?(true)
                            }
                            guard let start = dragStartValue else { return }
                            let delta = -Double(drag.translation.width / pointsPerUnit) * unitValue
                            let next = (start + delta).clamped(to: range)
                            value = next
                            let tick = Int((next / unitValue).rounded())
                            if tick != lastTick {
                                lastTick = tick
                                if abs(next - neutral) < unitValue / 2 { Haptics.confirm() } else { Haptics.tick() }
                            }
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            isDragging = false
                            onEditingChanged?(false)
                        }
                )
                .onTapGesture(count: 2) {
                    Haptics.confirm()
                    onEditingChanged?(true)
                    withAnimation(PSMotion.quick) { value = neutral }
                    onEditingChanged?(false)
                }
            }
            .frame(height: 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = unitValue * 5
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: break
            }
        }
    }
}

// MARK: - Voice

/// Slim status line above the dock. It only appears when there is something to
/// say — listening, working, a reply, a question — so an open tool panel sits
/// directly on the dock the rest of the time.
struct VoiceStrip: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool
    var busyTitle: String = ""
    var transcript: String
    var plan: EditPlan?
    var clarification: ClarificationRequest?
    /// Shown while nothing else is going on (typically when no tool is open).
    var showsHint: Bool
    /// Optional picture of each candidate for the clarification chips.
    var candidateThumbnail: ((ObjectCandidate) async -> UIImage?)? = nil
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    @State private var replyVisible = false
    @Environment(\.psEffects) private var effects
    @Environment(\.psReducedMotion) private var reducedMotion

    var body: some View {
        VStack(spacing: 8) {
            if let clarification {
                ClarificationCard(request: clarification, thumbnail: candidateThumbnail, onChoose: onChoose, onChooseAll: onChooseAll, onCancel: onCancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isIdleHint, let text = statusText {
                HStack(spacing: 7) {
                    MagicGlyph(size: 11, symbol: "waveform")
                    Text(text).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .psGlass()
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let text = statusText {
                HStack(spacing: 10) {
                    statusIcon
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        if voice.isListening || isBusy {
                            ShimmerText(text, font: PSFont.body(14))
                        } else {
                            Text(text)
                                .font(PSFont.body(14))
                                .foregroundStyle(PSTheme.textPrimary)
                                .lineLimit(2)
                                .contentTransition(.interpolate)
                        }
                        if replyVisible, !voice.isListening, !isBusy, !transcript.isEmpty {
                            Text("“\(transcript)”").font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if replyVisible, !voice.isListening, !isBusy, let plan, !transcript.isEmpty {
                        Text(plan.engine.displayName)
                            .font(PSFont.label(10)).foregroundStyle(PSTheme.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.white.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .psCard(cornerRadius: 22, shadow: false)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(PSTheme.intelligenceAngular, lineWidth: 1.2)
                        .opacity(voice.isListening || isBusy ? 0.5 + rimLevel * 0.5 : 0)
                        .animation(PSMotion.interactive, value: rimLevel)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PSMotion.standard, value: voice.isListening)
        .animation(PSMotion.standard, value: clarification?.id)
        .animation(PSMotion.standard, value: isBusy)
        .animation(PSMotion.standard, value: replyVisible)
        .task(id: transcript) {
            guard !transcript.isEmpty else { replyVisible = false; return }
            replyVisible = true
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            replyVisible = false
        }
    }

    /// The rim follows the voice, unless the user asked the system to stop
    /// things moving on their own.
    private var rimLevel: Double { reducedMotion ? 0.5 : voice.level }

    @ViewBuilder
    private var statusIcon: some View {
        if voice.isListening {
            LevelBars(level: effects == .minimal || reducedMotion ? 0.5 : voice.level)
        } else if isBusy {
            MagicGlyph(size: 15).symbolEffect(.pulse, isActive: !reducedMotion)
        } else if isUnavailable {
            Image(systemName: "mic.slash").foregroundStyle(PSTheme.danger)
        } else if replyVisible, plan != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.success).symbolEffect(.bounce, value: replyVisible)
        } else {
            MagicGlyph(size: 15, symbol: "waveform")
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = voice.state { return true }
        return false
    }

    /// True when the strip only shows the "tap the mic" hint.
    private var isIdleHint: Bool {
        showsHint && !voice.isListening && !isBusy && !isUnavailable && !(replyVisible && !transcript.isEmpty)
    }

    private var statusText: String? {
        if voice.isListening { return voice.partialTranscript.isEmpty ? L("Listening…") : voice.partialTranscript }
        if isBusy { return busyTitle.isEmpty ? L("Working…") : busyTitle }
        if isUnavailable { return L("Voice unavailable — check microphone access in Settings.") }
        if replyVisible, !transcript.isEmpty { return plan?.reply?.isEmpty == false ? plan?.reply : L("Done.") }
        if showsHint { return voice.mode == .pushToTalk ? L("Hold the mic and say what to change") : L("Tap the mic and say what to change") }
        return nil
    }
}

/// Five bars that follow the microphone level, each with its own weight so
/// the meter reads as a voice rather than a single gauge.
struct LevelBars: View {
    let level: Double
    private let weights: [Double] = [0.55, 0.85, 1, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(PSTheme.intelligence[index % PSTheme.intelligence.count])
                    .frame(width: 3, height: 4 + CGFloat(min(1, max(0, level)) * weights[index]) * 14)
            }
        }
        .frame(height: 18)
        .animation(PSMotion.interactive, value: level)
        .accessibilityHidden(true)
    }
}

/// The voice button at the end of the dock: a glass disc with a spectrum
/// ring. While listening the ring turns and breathes with the voice; idle,
/// nothing moves.
struct MicButton: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool

    @State private var pressing = false
    @Environment(\.psEffects) private var effects
    @Environment(\.psReducedMotion) private var reducedMotion

    var body: some View {
        ZStack {
            ring
            Image(systemName: micSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(voice.isListening ? Color.white : PSTheme.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .background {
                    if voice.isListening {
                        Circle().fill(LinearGradient(colors: PSTheme.intelligence, startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .psGlass(interactive: true, shape: AnyShape(Circle()))
                .scaleEffect(pressing ? 0.9 : 1)
                .animation(PSMotion.quick, value: pressing)
        }
        .frame(width: 62, height: 62)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    if voice.mode == .pushToTalk {
                        Haptics.confirm()
                        voice.start()
                    }
                }
                .onEnded { _ in
                    pressing = false
                    switch voice.mode {
                    case .pushToTalk: voice.stop()
                    case .tapToTalk, .handsFree:
                        Haptics.confirm()
                        voice.toggle()
                    }
                }
        )
        .accessibilityLabel(voice.isListening ? L("Stop listening") : L("Voice command"))
        .accessibilityHint(L("Say what you want to change, for example: remove the dog."))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var ring: some View {
        let active = voice.isListening || isBusy
        if active && !reducedMotion && effects != .minimal {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let angle = Angle.degrees((context.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360))
                Circle()
                    .strokeBorder(AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center, angle: angle), lineWidth: 2.5)
                    .frame(width: 62, height: 62)
                    .scaleEffect(1 + CGFloat(voice.isListening ? voice.level : 0.1) * 0.12)
                    .shadow(color: PSTheme.voice.opacity(0.6), radius: 8)
            }
        } else {
            Circle()
                .strokeBorder(PSTheme.intelligenceAngular, lineWidth: active ? 2.5 : 1.5)
                .opacity(active ? 1 : 0.55)
                .frame(width: 62, height: 62)
        }
    }

    private var micSymbol: String {
        if isBusy { return "sparkles" }
        switch voice.state {
        case .listening: return "waveform"
        case .preparing, .finishing: return "ellipsis"
        case .unavailable: return "mic.slash"
        case .idle: return "mic.fill"
        }
    }
}

/// Numbered candidate choices when a command was ambiguous.
struct ClarificationCard: View {
    let request: ClarificationRequest
    var thumbnail: ((ObjectCandidate) async -> UIImage?)? = nil
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void
    @State private var images: [UUID: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.question)
                        .font(PSFont.headline(14))
                        .foregroundStyle(PSTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("Tap one, or say its number."))
                        .font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
                }
                Spacer(minLength: 8)
                Button { Haptics.tap(); onCancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PSTheme.textSecondary).frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(L("Cancel"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(request.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            Haptics.confirm()
                            onChoose(index)
                        } label: {
                            HStack(spacing: 8) {
                                if let image = images[candidate.id] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 38, height: 38)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(alignment: .bottomTrailing) { numberBadge(index + 1, size: 16).offset(x: 4, y: 4) }
                                        .transition(.opacity)
                                } else {
                                    numberBadge(index + 1, size: 20)
                                }
                                Text(candidate.spokenDescription).font(PSFont.caption(13)).foregroundStyle(PSTheme.textPrimary)
                            }
                            .padding(.leading, images[candidate.id] == nil ? 10 : 6).padding(.trailing, 12).padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(PSPressStyle())
                    }
                    if request.candidates.count > 1 {
                        Button { Haptics.confirm(); onChooseAll() } label: {
                            Label(L("All"), systemImage: "checkmark.circle.fill").font(PSFont.headline(13)).foregroundStyle(PSTheme.onAccent)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .psAccentFill(Capsule(), glow: false)
                        }
                        .buttonStyle(PSPressStyle())
                    }
                }
                .animation(PSMotion.quick, value: images.count)
            }
        }
        .padding(14)
        .psCard(cornerRadius: 24)
        .task(id: request.id) {
            guard let thumbnail else { return }
            images = [:]
            for candidate in request.candidates {
                if let image = await thumbnail(candidate) { images[candidate.id] = image }
            }
        }
    }

    private func numberBadge(_ number: Int, size: CGFloat) -> some View {
        Text("\(number)").font(PSFont.headline(size * 0.6)).foregroundStyle(PSTheme.onAccent)
            .frame(width: size, height: size).background(Circle().fill(PSTheme.accentGradient))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Chips

/// Small chip button used inside panels. `tint` marks a recommended action:
/// its glyph takes the colour (the intelligence spectrum for `PSTheme.voice`).
struct PanelChip: View {
    let title: String
    var symbol: String? = nil
    var tint: Color? = nil
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 6) {
                if let symbol {
                    if tint == PSTheme.voice {
                        MagicGlyph(size: 12, symbol: symbol)
                    } else {
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint ?? (isActive ? PSTheme.accent : PSTheme.textPrimary))
                    }
                }
                Text(title).lineLimit(1)
            }
            .font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(PSTheme.textPrimary)
            .background(Capsule().fill(Color.white.opacity(isActive ? 0 : 0.08)))
            .psActivePill(Capsule(), isActive: isActive)
        }
        .buttonStyle(PSPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(PSMotion.quick, value: isActive)
    }
}

/// Icon-only chip with a caption underneath, for action rows.
struct IconChip: View {
    let title: String
    let symbol: String
    var isActive = false
    var isEnabled = true
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            VStack(spacing: 4) {
                Group {
                    if tint == PSTheme.voice {
                        MagicGlyph(size: 17, symbol: symbol)
                    } else {
                        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(isActive ? PSTheme.accent : (tint ?? PSTheme.textPrimary))
                    }
                }
                .frame(height: 21)
                Text(title).font(PSFont.label(10)).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(isActive ? PSTheme.textPrimary : PSTheme.textSecondary)
            }
            .frame(width: 68, height: 52)
            .background(Color.white.opacity(isActive ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .psActivePill(RoundedRectangle(cornerRadius: 16, style: .continuous), isActive: isActive)
        }
        .buttonStyle(PSPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

/// Round colour swatch.
struct ColorSwatch: View {
    let color: PSColor
    var isSelected: Bool
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            Circle().fill(Color(cgColor: color.cgColor))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
                .scaleEffect(isSelected ? 1.06 : 1)
                .animation(PSMotion.quick, value: isSelected)
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .accessibilityLabel(color.hexString)
    }
}
#endif
