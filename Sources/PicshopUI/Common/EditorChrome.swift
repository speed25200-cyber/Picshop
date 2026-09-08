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

/// Compact top bar: close · undo/redo · help · export.
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
        HStack(spacing: 8) {
            GlassIconButton("xmark", label: L("Close"), size: 40, action: onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PSFont.headline(16)).foregroundStyle(PSTheme.textPrimary).lineLimit(1).tracking(-0.2)
                if let subtitle {
                    Text(subtitle).font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Button { Haptics.tap(); onUndo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain).disabled(!canUndo).foregroundStyle(canUndo ? PSTheme.textPrimary : PSTheme.textTertiary)
                .accessibilityLabel(L("Undo"))
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)
                Button { Haptics.tap(); onRedo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain).disabled(!canRedo).foregroundStyle(canRedo ? PSTheme.textPrimary : PSTheme.textTertiary)
                .accessibilityLabel(L("Redo"))
            }
            .psCard(cornerRadius: 20, shadow: false)
            GlassIconButton("questionmark", label: L("Help"), size: 40, action: onHelp)
            Button { Haptics.confirm(); onExport() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(PSTheme.accentGradient).overlay(Circle().fill(LinearGradient(colors: [Color.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))))
            .shadow(color: PSTheme.accent.opacity(0.45), radius: 10, y: 4)
            .accessibilityLabel(L("Export"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [PSTheme.canvas.opacity(0.9), PSTheme.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
}

/// Bottom dock of tools. Items are equally sized; the row scrolls when it
/// does not fit and centres itself when it does.
struct ToolDock<Tool: Identifiable & Hashable>: View {
    let tools: [Tool]
    @Binding var selection: Tool?
    var title: (Tool) -> String
    var symbol: (Tool) -> String
    var onSelect: ((Tool?) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tools) { tool in
                        let isActive = selection == tool
                        Button {
                            Haptics.tap()
                            let next: Tool? = isActive ? nil : tool
                            withAnimation(.spring(duration: 0.32, bounce: 0.15)) { selection = next }
                            onSelect?(next)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: symbol(tool))
                                    .font(.system(size: 19, weight: .semibold))
                                    .symbolVariant(isActive ? .fill : .none)
                                    .frame(height: 22)
                                Text(title(tool)).font(PSFont.caption(10.5)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                            .frame(width: 64, height: 54)
                            .psActivePill(RoundedRectangle(cornerRadius: 16, style: .continuous), isActive: isActive)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title(tool))
                        .accessibilityAddTraits(isActive ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: proxy.size.width)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                // Fade the edges when the dock scrolls so the hidden tools are discoverable.
                let scrolls = CGFloat(tools.count) * 66 + 12 > proxy.size.width
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: scrolls ? 18 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: scrolls ? 18 : 0)
                }
            }
        }
        .frame(height: 62)
        .psCard(cornerRadius: 26)
    }
}

/// Glass panel that hosts the active tool's controls, with a small header.
/// A dock entry that opens one panel with several sub-modes (segments in the
/// panel header). Tools are grouped by purpose so the dock stays short.
struct ToolGroup<Tool: Hashable & Identifiable>: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let tools: [Tool]

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
        ToolDock(tools: groups, selection: groupSelection, title: { $0.title }, symbol: { $0.symbol })
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

/// Segmented sub-mode picker shown in a panel header.
struct ModeSegments<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    @Binding var selection: Mode?
    var title: (Mode) -> String
    var symbol: (Mode) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                let isActive = selection == mode
                Button {
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.28, bounce: 0.1)) { selection = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(mode)).font(.system(size: 11, weight: .bold))
                        Text(title(mode)).font(PSFont.caption(12)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .psActivePill(Capsule(), isActive: isActive, glow: false)
                    .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct ToolPanelContainer<Content: View>: View {
    var title: String
    var symbol: String
    var onClose: () -> Void
    var trailing: AnyView? = nil
    /// Sub-mode segments (see `ModeSegments`) rendered under the title.
    var modes: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PSTheme.accentGradient))
                    .shadow(color: PSTheme.accent.opacity(0.35), radius: 6, y: 2)
                Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).tracking(-0.2)
                Spacer()
                if let trailing { trailing }
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(PSTheme.textSecondary).frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close"))
            }
            if let modes { modes }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .psCard(cornerRadius: 26)
    }
}

/// Apple-Photos-style ruler dial. Drag to change the value with haptic ticks;
/// double tap to reset to neutral. The value is shown above the centre mark.
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

    private var pointsPerUnit: CGFloat { 7 }
    private var unitValue: Double { (range.upperBound - range.lowerBound) / units }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if let label { Text(label).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary) }
                Spacer()
                Text(format(value))
                    .font(PSFont.mono(13))
                    .foregroundStyle(abs(value - neutral) < 0.0001 ? PSTheme.textSecondary : PSTheme.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: value)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let centerX = width / 2
                Canvas { context, size in
                    let offset = CGFloat((value - range.lowerBound) / unitValue) * pointsPerUnit
                    let count = Int(units)
                    for index in 0...count {
                        let x = centerX - offset + CGFloat(index) * pointsPerUnit
                        guard x >= -2, x <= size.width + 2 else { continue }
                        let isMajor = index % 10 == 0
                        let distance = abs(x - centerX) / (size.width / 2)
                        let alpha = max(0.08, 1 - distance * distance)
                        let height: CGFloat = isMajor ? 18 : 10
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height / 2 - height / 2))
                        path.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2))
                        let neutralIndex = Int(((neutral - range.lowerBound) / unitValue).rounded())
                        let isNeutral = index == neutralIndex
                        context.stroke(path, with: .color(isNeutral ? PSTheme.accent.opacity(alpha) : Color.white.opacity(alpha * 0.9)), lineWidth: isMajor || isNeutral ? 2 : 1)
                    }
                    // Centre marker.
                    var marker = Path()
                    marker.move(to: CGPoint(x: centerX, y: 0))
                    marker.addLine(to: CGPoint(x: centerX, y: size.height))
                    context.addFilter(.shadow(color: PSTheme.accent.opacity(0.8), radius: 4))
                    context.stroke(marker, with: .color(PSTheme.accent), lineWidth: 2.5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            if dragStartValue == nil {
                                dragStartValue = value
                                lastTick = Int((value / unitValue).rounded())
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
                            onEditingChanged?(false)
                        }
                )
                .onTapGesture(count: 2) {
                    Haptics.confirm()
                    onEditingChanged?(true)
                    withAnimation(.snappy) { value = neutral }
                    onEditingChanged?(false)
                }
            }
            .frame(height: 36)
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

/// The voice control: a microphone button, the live transcript / last reply,
/// and the clarification choices when the assistant needs an answer.
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
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    @State private var replyVisible = false

    var body: some View {
        VStack(spacing: 8) {
            if let clarification {
                ClarificationCard(request: clarification, onChoose: onChoose, onChooseAll: onChooseAll, onCancel: onCancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let text = statusText {
                HStack(spacing: 10) {
                    if voice.isListening {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .foregroundStyle(PSTheme.voice)
                    } else if isBusy {
                        ProgressView().tint(PSTheme.accent).controlSize(.small)
                    } else if isUnavailable {
                        Image(systemName: "mic.slash").foregroundStyle(PSTheme.danger)
                    } else if replyVisible, plan != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.success)
                    } else {
                        Image(systemName: "mic.fill").foregroundStyle(PSTheme.voice)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text)
                            .font(PSFont.body(14))
                            .foregroundStyle(isBusy ? PSTheme.accent : PSTheme.textPrimary)
                            .lineLimit(2)
                            .contentTransition(.interpolate)
                        if replyVisible, !voice.isListening, !isBusy, !transcript.isEmpty {
                            Text("“\(transcript)”").font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if replyVisible, !voice.isListening, !isBusy, let plan, !transcript.isEmpty {
                        Text(plan.engine.displayName)
                            .font(PSFont.caption(10)).foregroundStyle(PSTheme.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(PSTheme.hairline, in: Capsule())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .psCard(cornerRadius: 20, shadow: false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: voice.isListening)
        .animation(.spring(duration: 0.3), value: clarification?.id)
        .animation(.spring(duration: 0.3), value: isBusy)
        .animation(.spring(duration: 0.3), value: replyVisible)
        .task(id: transcript) {
            guard !transcript.isEmpty else { replyVisible = false; return }
            replyVisible = true
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            replyVisible = false
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = voice.state { return true }
        return false
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

/// The voice button that lives at the trailing end of the dock.
struct MicButton: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool

    @State private var pressing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(PSTheme.voice.opacity(0.35), lineWidth: 2)
                .frame(width: 52, height: 52)
                .scaleEffect(voice.isListening ? 1.2 + CGFloat(voice.level) * 0.5 : 1)
                .opacity(voice.isListening ? 1 : 0)
                .animation(.spring(duration: 0.2), value: voice.level)
            Circle()
                .fill(PSTheme.voiceGradient)
                .frame(width: 52, height: 52)
                .shadow(color: PSTheme.voice.opacity(voice.isListening ? 0.7 : 0.35), radius: voice.isListening ? 16 : 8)
                .overlay {
                    Image(systemName: micSymbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .scaleEffect(pressing ? 0.9 : 1)
                .animation(.spring(duration: 0.2), value: pressing)
        }
        .frame(width: 62, height: 62)
        .background(Circle().fill(Color.black.opacity(0.35)).overlay(Circle().strokeBorder(PSTheme.strokeGradient, lineWidth: 1)))
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
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(request.question)
                    .font(PSFont.body(14))
                    .foregroundStyle(PSTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { Haptics.tap(); onCancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PSTheme.textSecondary).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .psGlass(interactive: true, shape: AnyShape(Circle()))
                .accessibilityLabel(L("Cancel"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(request.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            Haptics.confirm()
                            onChoose(index)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1)").font(PSFont.headline(12)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(Circle().fill(PSTheme.accentGradient))
                                Text(candidate.spokenDescription).font(PSFont.caption(13)).foregroundStyle(PSTheme.textPrimary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psGlass(interactive: true)
                    }
                    if request.candidates.count > 1 {
                        Button { Haptics.confirm(); onChooseAll() } label: {
                            Label(L("All"), systemImage: "checkmark.circle").font(PSFont.caption(13)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psAccentFill(Capsule(), glow: false)
                    }
                }
            }
        }
        .padding(12)
        .psGlassPanel(cornerRadius: 22)
    }
}

/// Small chip button used inside panels.
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
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive || tint != nil ? Color.white : PSTheme.textPrimary)
        .psGlass(tint: nil, interactive: true)
        .psActivePill(Capsule(), isActive: isActive || tint != nil, glow: tint != nil)
        .overlay(Capsule().strokeBorder(Color.white.opacity(isActive || tint != nil ? 0 : 0.1), lineWidth: 1))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
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
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(height: 20)
                Text(title).font(PSFont.caption(10)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.white : (tint ?? PSTheme.textPrimary))
            .frame(width: 66, height: 48)
            .background(Color.white.opacity(isActive ? 0 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(isActive ? 0 : 0.08), lineWidth: 1))
            .psActivePill(RoundedRectangle(cornerRadius: 14, style: .continuous), isActive: isActive, glow: false)
        }
        .buttonStyle(.plain)
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
                .overlay(Circle().stroke(isSelected ? PSTheme.accent : Color.white.opacity(0.25), lineWidth: isSelected ? 2.5 : 1))
                .scaleEffect(isSelected ? 1.1 : 1)
                .animation(.spring(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.hexString)
    }
}
#endif
