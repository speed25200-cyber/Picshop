#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
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
        canvas()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { top() }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom() }
            .background(PSTheme.canvas.ignoresSafeArea())
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
                Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .padding(.leading, 2)
            Spacer(minLength: 4)
            PSGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassIconButton("arrow.uturn.backward", label: L("Undo"), size: 40, action: onUndo)
                        .disabled(!canUndo).opacity(canUndo ? 1 : 0.35)
                    GlassIconButton("arrow.uturn.forward", label: L("Redo"), size: 40, action: onRedo)
                        .disabled(!canRedo).opacity(canRedo ? 1 : 0.35)
                }
            }
            GlassIconButton("questionmark", label: L("Help"), size: 40, action: onHelp)
            GlassIconButton("square.and.arrow.up", label: L("Export"), tint: PSTheme.accent, isActive: true, size: 40, action: onExport)
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
                            .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
                            .frame(width: 64, height: 54)
                            .background(isActive ? PSTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        }
        .frame(height: 62)
        .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
    }
}

/// Glass panel that hosts the active tool's controls, with a small header.
struct ToolPanelContainer<Content: View>: View {
    var title: String
    var symbol: String
    var onClose: () -> Void
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(PSTheme.accent)
                Text(title).font(PSFont.headline(14)).foregroundStyle(PSTheme.textPrimary)
                Spacer()
                if let trailing { trailing }
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(PSTheme.textSecondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close"))
            }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .psGlassPanel(cornerRadius: 24)
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
struct VoiceBar: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool
    var busyTitle: String = ""
    var transcript: String
    var plan: EditPlan?
    var clarification: ClarificationRequest?
    var showsTranscript: Bool
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    @State private var pressing = false

    var body: some View {
        VStack(spacing: 8) {
            if let clarification {
                ClarificationCard(request: clarification, onChoose: onChoose, onChooseAll: onChooseAll, onCancel: onCancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 12) {
                micButton
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(PSFont.body(14))
                        .foregroundStyle(voice.isListening ? PSTheme.textPrimary : (isBusy ? PSTheme.accent : PSTheme.textPrimary))
                        .lineLimit(2)
                        .contentTransition(.interpolate)
                    if let secondary = secondaryText {
                        Text(secondary).font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if voice.isListening {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(PSTheme.voice)
                } else if isBusy {
                    ProgressView().tint(PSTheme.accent).controlSize(.small)
                } else if let plan, showsTranscript, !transcript.isEmpty {
                    Text(plan.engine.displayName)
                        .font(PSFont.caption(10)).foregroundStyle(PSTheme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(PSTheme.hairline, in: Capsule())
                }
            }
            .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
            .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture {
                guard voice.mode != .pushToTalk else { return }
                Haptics.confirm()
                voice.toggle()
            }
        }
        .animation(.spring(duration: 0.3), value: voice.isListening)
        .animation(.spring(duration: 0.3), value: clarification?.id)
        .animation(.spring(duration: 0.3), value: isBusy)
    }

    private var primaryText: String {
        if voice.isListening { return voice.partialTranscript.isEmpty ? L("Listening…") : voice.partialTranscript }
        if isBusy { return busyTitle.isEmpty ? L("Working…") : busyTitle }
        if case .unavailable = voice.state { return L("Voice unavailable — check microphone access in Settings.") }
        if showsTranscript, !transcript.isEmpty, let reply = plan?.reply, !reply.isEmpty { return reply }
        return voice.mode == .pushToTalk ? L("Hold the mic and say what to change") : L("Tap the mic and say what to change")
    }

    private var secondaryText: String? {
        if voice.isListening || isBusy { return nil }
        if showsTranscript, !transcript.isEmpty { return "“\(transcript)”" }
        return nil
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .stroke(PSTheme.voice.opacity(0.35), lineWidth: 2)
                .frame(width: 44, height: 44)
                .scaleEffect(voice.isListening ? 1.25 + CGFloat(voice.level) * 0.6 : 1)
                .opacity(voice.isListening ? 1 : 0)
                .animation(.spring(duration: 0.2), value: voice.level)
            Circle()
                .fill(PSTheme.voiceGradient)
                .frame(width: 44, height: 44)
                .shadow(color: PSTheme.voice.opacity(voice.isListening ? 0.7 : 0.3), radius: voice.isListening ? 14 : 6)
                .overlay {
                    Image(systemName: micSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .scaleEffect(pressing ? 0.9 : 1)
                .animation(.spring(duration: 0.2), value: pressing)
        }
        .frame(width: 48, height: 48)
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
                                Text("\(index + 1)").font(PSFont.headline(12)).foregroundStyle(.black)
                                    .frame(width: 20, height: 20).background(PSTheme.accent, in: Circle())
                                Text(candidate.spokenDescription).font(PSFont.caption(13)).foregroundStyle(PSTheme.textPrimary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psGlass(interactive: true)
                    }
                    if request.candidates.count > 1 {
                        Button { Haptics.confirm(); onChooseAll() } label: {
                            Label(L("All"), systemImage: "checkmark.circle").font(PSFont.caption(13)).foregroundStyle(.black).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psGlass(tint: PSTheme.accent, interactive: true)
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
        .foregroundStyle(isActive || tint != nil ? Color.black : PSTheme.textPrimary)
        .psGlass(tint: isActive ? PSTheme.accent : tint, interactive: true)
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
            .foregroundStyle(isActive ? Color.black : (tint ?? PSTheme.textPrimary))
            .frame(width: 66, height: 48)
            .background(isActive ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
