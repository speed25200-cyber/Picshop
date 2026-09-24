#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Shared editor shell. By default the top bar and the bottom controls are
/// safe-area insets, so the canvas gets exactly the room between them.
///
/// `edgeToEdge` runs the canvas under the bars, full screen, the way Photos
/// does: the black ground and anything behind the picture reach the display
/// edges, and the glass has something to refract. The canvas then reads
/// `editorChromeEdges` and fits its picture between the bars itself.
struct EditorChrome<Canvas: View, Top: View, Bottom: View>: View {
    var edgeToEdge: Bool
    let canvas: () -> Canvas
    let top: () -> Top
    let bottom: () -> Bottom

    @State private var edges = EditorChromeEdges()

    init(edgeToEdge: Bool = false, @ViewBuilder canvas: @escaping () -> Canvas, @ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom) {
        self.edgeToEdge = edgeToEdge
        self.canvas = canvas
        self.top = top
        self.bottom = bottom
    }

    var body: some View {
        GeometryReader { proxy in
            // Presented editors occasionally receive zero safe-area insets from SwiftUI; the
            // window always knows the real status bar / home indicator geometry.
            let window = WindowInsets.current
            let extraTop = max(0, window.top - proxy.safeAreaInsets.top)
            let extraBottom = max(0, window.bottom - proxy.safeAreaInsets.bottom)
            if edgeToEdge {
                ZStack {
                    canvas()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.editorChromeEdges, edges)
                        .ignoresSafeArea()
                    // Empty space in the stack is not hit-testable: the canvas
                    // keeps every touch between the bars.
                    VStack(spacing: 0) {
                        top()
                            .padding(.top, extraTop)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { edges.top = $0 }
                        Spacer(minLength: 0)
                        bottom()
                            .padding(.bottom, extraBottom)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { edges.bottom = $0 }
                    }
                }
            } else {
                canvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) { top().padding(.top, extraTop) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottom().padding(.bottom, extraBottom) }
            }
        }
        .background(PSTheme.canvas.ignoresSafeArea())
    }
}

/// Where an edge-to-edge editor's bars sit, in global coordinates.
struct EditorChromeEdges: Equatable {
    /// Bottom of the top bar.
    var top: CGFloat = 0
    /// Top of the bottom controls.
    var bottom: CGFloat = .greatestFiniteMagnitude

    /// How far the bars reach into a view occupying `frame` (global coordinates).
    func insets(over frame: CGRect) -> EdgeInsets {
        EdgeInsets(top: max(0, min(frame.height / 2, top - frame.minY)), leading: 0,
                   bottom: max(0, min(frame.height / 2, frame.maxY - bottom)), trailing: 0)
    }
}

private struct EditorChromeEdgesKey: EnvironmentKey {
    static let defaultValue: EditorChromeEdges? = nil
}

extension EnvironmentValues {
    /// Set by an edge-to-edge `EditorChrome` for its canvas; nil otherwise.
    var editorChromeEdges: EditorChromeEdges? {
        get { self[EditorChromeEdgesKey.self] }
        set { self[EditorChromeEdgesKey.self] = newValue }
    }
}

/// A soft fall-off behind the dock so it reads on any picture. Only the
/// dock's height: an open panel is glass and needs none, and a taller band
/// would paint a dark slab over the photo.
struct DockBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(alignment: .bottom) {
            LinearGradient(stops: [
                .init(color: PSTheme.canvas.opacity(0), location: 0),
                .init(color: PSTheme.canvas.opacity(0.4), location: 0.5),
                .init(color: PSTheme.canvas.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 112)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func psDockBackground() -> some View { modifier(DockBackground()) }
}

// MARK: - Top bar

/// One row of glass over the picture: close on the left, the document's
/// name in the middle, then undo and redo joined in one capsule, a menu for
/// help, history and revert, and Export — the single yellow action.
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
    /// Labels of the steps that can be undone, oldest first; a long press on
    /// Undo lists them, as Photoshop's History does.
    var history: [String] = []
    /// Undoes this many steps at once.
    var onUndoSteps: ((Int) -> Void)? = nil
    /// Back to the document as imported. Without it, "Back to the original"
    /// undoes every step of this session.
    var onRevert: (() -> Void)? = nil

    @Environment(\.psEffects) private var effects

    var body: some View {
        // Container spacing under the gaps: the pieces share one glass
        // sampling but never bridge into each other.
        PSGlassContainer(spacing: 4) {
            HStack(spacing: 8) {
                GlassIconButton("xmark", label: L("Close"), size: 44, action: onClose)
                Spacer(minLength: 4)
                VStack(spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                            .contentTransition(.numericText())
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(PSMotion.standard, value: subtitle == nil)
                Spacer(minLength: 4)
                historyCapsule
                moreMenu
                exportButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Undo and redo read as one control.
    private var historyCapsule: some View {
        HStack(spacing: 0) {
            if let onUndoSteps, history.count > 1 {
                Menu {
                    historySection(onUndoSteps)
                } label: {
                    barGlyph("arrow.uturn.backward")
                } primaryAction: {
                    Haptics.tap()
                    onUndo()
                }
                .opacity(canUndo ? 1 : 0.3)
                .accessibilityLabel(L("Undo"))
                .accessibilityHint(L("Hold for the history"))
            } else {
                barButton("arrow.uturn.backward", label: L("Undo"), enabled: canUndo, action: onUndo)
            }
            barButton("arrow.uturn.forward", label: L("Redo"), enabled: canRedo, action: onRedo)
        }
        .foregroundStyle(PSTheme.textPrimary)
        .psGlass(interactive: true)
        .animation(PSMotion.quick, value: canUndo)
        .animation(PSMotion.quick, value: canRedo)
    }

    private var moreMenu: some View {
        Menu {
            Button { onHelp() } label: { Label(L("Help"), systemImage: "questionmark.circle") }
            if let onUndoSteps, !history.isEmpty {
                Menu {
                    historySection(onUndoSteps)
                } label: {
                    Label(L("History"), systemImage: "clock.arrow.circlepath")
                }
            }
            if onRevert != nil || (onUndoSteps != nil && !history.isEmpty) {
                Divider()
                Button(role: .destructive) {
                    if let onRevert { onRevert() } else { onUndoSteps?(history.count) }
                } label: {
                    Label(L("Back to the original"), systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            barGlyph("ellipsis")
                .foregroundStyle(PSTheme.textPrimary)
                .psGlass(interactive: true, shape: AnyShape(Circle()))
        }
        .accessibilityLabel(L("More"))
    }

    @ViewBuilder
    private func historySection(_ undoSteps: @escaping (Int) -> Void) -> some View {
        Section(L("History")) {
            ForEach(Array(history.enumerated().reversed()), id: \.offset) { index, label in
                // Going back to before this step undoes it and everything after it.
                Button(String(format: L("Before “%@”"), LD(label))) { Haptics.tick(); undoSteps(history.count - index) }
            }
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        let glyph = Image(systemName: "square.and.arrow.up")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(PSTheme.onAccent)
        Group {
            if effects == .minimal {
                Button(action: export) {
                    glyph.frame(width: 44, height: 44).background(Circle().fill(PSTheme.accent))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
            } else {
                Button(action: export) {
                    glyph.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Circle())
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(PSTheme.accent)
                .frame(width: 44, height: 44)
            }
        }
        .accessibilityLabel(L("Export"))
    }

    private func export() {
        Haptics.confirm()
        onExport()
    }

    private func barGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            barGlyph(symbol)
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

// MARK: - Tool dock

/// The tool bar at the bottom: one glass capsule of tools. The chosen tool
/// turns white over a lit thumb; a small yellow dot marks the tools whose
/// edits are in the picture, as in Photos. The row scrolls only when it has to.
struct ToolDock<Tool: Identifiable & Hashable>: View {
    let tools: [Tool]
    @Binding var selection: Tool?
    var title: (Tool) -> String
    var symbol: (Tool) -> String
    /// Tools drawn with the intelligence spectrum (the Magic entry).
    var isMagic: (Tool) -> Bool = { _ in false }
    var onSelect: ((Tool?) -> Void)? = nil
    /// Tools whose edits differ from the defaults.
    var isModified: (Tool) -> Bool = { _ in false }

    @Namespace private var indicator

    private let preferredItemWidth: CGFloat = 64
    private let minimumItemWidth: CGFloat = 46

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
        .frame(height: 64)
        .psGlass(shape: AnyShape(Capsule()))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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
            VStack(spacing: 2) {
                Group {
                    if magic {
                        Image(systemName: symbol(tool)).psIntelligenceForeground()
                    } else {
                        Image(systemName: symbol(tool)).foregroundStyle(isActive ? Color.white : PSTheme.textPrimary)
                    }
                }
                .font(.system(size: 20, weight: isActive ? .medium : .regular))
                .frame(height: 24)
                Text(title(tool)).font(.caption2.weight(.medium))
                    .foregroundStyle(isActive ? PSTheme.textPrimary : PSTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Circle().fill(PSTheme.accent).frame(width: 4, height: 4)
                    .opacity(isModified(tool) ? 1 : 0)
            }
            .frame(width: width - 4, height: 56)
            .background {
                if isActive {
                    Capsule().fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "active", in: indicator)
                }
            }
            .contentShape(Capsule())
            .padding(.horizontal, 2)
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(title(tool))
        .accessibilityValue(isModified(tool) ? L("Edited") : "")
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
    /// Groups whose edits differ from the defaults (a yellow dot).
    var isModified: (ToolGroup<Tool>) -> Bool = { _ in false }
    @State private var lastTool: [String: Tool] = [:]

    var body: some View {
        ToolDock(tools: groups, selection: groupSelection, title: { $0.title }, symbol: { $0.symbol }, isMagic: { $0.isMagic }, isModified: isModified)
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

/// Glass panel that hosts the active tool's controls. No title: the dock
/// already says which tool is open, and tapping it again closes the panel.
/// The sub-mode segments and the tool's own action (Done, Erase…) share the
/// first row; a swipe down on that row closes the panel, as on a sheet.
struct ToolPanelContainer<Content: View>: View {
    /// Kept for existing call sites and accessibility; not drawn.
    var title: String
    var symbol: String
    var onClose: () -> Void
    var trailing: AnyView? = nil
    /// Sub-mode segments (see `ModeSegments`) in the first row.
    var modes: AnyView? = nil
    @ViewBuilder var content: () -> Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 12) {
            if modes != nil || trailing != nil {
                HStack(spacing: 8) {
                    if let modes {
                        modes.frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let trailing { trailing }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.height) > abs(value.translation.width) else { return }
                            dragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            let vertical = abs(value.translation.height) > abs(value.translation.width)
                            let shouldClose = vertical && (value.translation.height > 48 || value.predictedEndTranslation.height > 140)
                            withAnimation(PSMotion.standard) { dragOffset = 0 }
                            if shouldClose {
                                Haptics.tap()
                                onClose()
                            }
                        }
                )
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .psCard(cornerRadius: PSRadius.panel)
        .offset(y: dragOffset * 0.5)
        .opacity(1 - Double(min(dragOffset, 120)) / 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAction(.escape) { onClose() }
    }
}

// MARK: - Voice

/// Slim status line above the dock. It only appears when there is something to
/// say — listening, working, a reply, a question — so an open tool panel sits
/// directly on the dock the rest of the time. A reply stays four seconds, a
/// problem seven.
struct VoiceStrip: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool
    var busyTitle: String = ""
    var transcript: String
    var plan: EditPlan?
    /// The reply says the command could not be done as said (nothing found, not possible here).
    var replyIsProblem = false
    /// The command failed: the reply is an error, not a hand-over to the finger.
    var replyIsError = false
    /// Changes with every reply to show: the same words said again, or an outcome that
    /// arrives after the words, show the reply afresh.
    var replyID: UUID? = nil
    var clarification: ClarificationRequest?
    /// The "tap the mic" hint may show (typically when no tool is open). It
    /// shows only in the first few editor sessions, and fades after a moment.
    var showsHint: Bool
    /// Optional picture of each candidate for the clarification chips.
    var candidateThumbnail: ((ObjectCandidate) async -> UIImage?)? = nil
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    @State private var replyVisible = false
    @State private var idleHintVisible = false
    /// Editor sessions that have shown the mic hint.
    @AppStorage("hint.mic.count") private var micHintCount = 0
    @Environment(\.psReducedMotion) private var reducedMotion

    var body: some View {
        VStack(spacing: 8) {
            if let clarification {
                ClarificationCard(request: clarification, thumbnail: candidateThumbnail, onChoose: onChoose, onChooseAll: onChooseAll, onCancel: onCancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isIdleHint, let text = statusText {
                HStack(spacing: 8) {
                    MagicGlyph(size: 13, symbol: "waveform")
                    Text(text).font(.footnote).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .psGlass()
                .transition(.opacity)
            } else if let text = statusText {
                HStack(spacing: 12) {
                    statusIcon
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        if voice.isListening || isBusy {
                            ShimmerText(text, font: .subheadline)
                        } else {
                            Text(text)
                                .font(.subheadline)
                                .foregroundStyle(PSTheme.textPrimary)
                                .lineLimit(2)
                                .contentTransition(.interpolate)
                        }
                        if replyVisible, !voice.isListening, !isBusy, !transcript.isEmpty {
                            Text("“\(transcript)”").font(.footnote).foregroundStyle(PSTheme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    #if DEBUG
                    if replyVisible, !voice.isListening, !isBusy, let plan, !transcript.isEmpty {
                        Text(plan.engine.displayName)
                            .font(.caption2.weight(.medium)).foregroundStyle(PSTheme.textTertiary)
                    }
                    #endif
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(minHeight: 44)
                .psCard(cornerRadius: 22, shadow: false)
                .overlay(
                    // The spectrum rim is the voice's, and only while it listens.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(PSTheme.intelligenceAngular, lineWidth: 1)
                        .opacity(voice.isListening ? 0.4 + rimLevel * 0.6 : 0)
                        .animation(PSMotion.interactive, value: rimLevel)
                        .allowsHitTesting(false)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(PSMotion.standard, value: voice.isListening)
        .animation(PSMotion.standard, value: clarification?.id)
        .animation(PSMotion.standard, value: isBusy)
        .animation(PSMotion.standard, value: replyVisible)
        .animation(PSMotion.standard, value: idleHintVisible)
        .task(id: ReplyKey(transcript: transcript, replyID: replyID)) {
            guard !transcript.isEmpty else { replyVisible = false; return }
            replyVisible = true
            try? await Task.sleep(for: .seconds(replyIsProblem || replyIsError ? 7 : 4))
            guard !Task.isCancelled else { return }
            replyVisible = false
        }
        .task {
            guard micHintCount < 3 else { return }
            micHintCount += 1
            idleHintVisible = true
            try? await Task.sleep(for: .seconds(4))
            idleHintVisible = false
        }
    }

    private struct ReplyKey: Equatable {
        let transcript: String
        let replyID: UUID?
    }

    /// The rim follows the voice, unless the user asked the system to stop
    /// things moving on their own.
    private var rimLevel: Double { reducedMotion ? 0.5 : voice.level }

    @ViewBuilder
    private var statusIcon: some View {
        if voice.isListening {
            // The mic itself shows the level; here the voice's glyph is enough.
            MagicGlyph(size: 17, symbol: "waveform")
        } else if isBusy {
            MagicGlyph(size: 17).symbolEffect(.pulse, isActive: !reducedMotion)
        } else if isUnavailable {
            Image(systemName: "mic.slash").foregroundStyle(PSTheme.danger)
        } else if replyVisible, plan != nil, replyIsError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PSTheme.danger)
        } else if replyVisible, plan != nil, replyIsProblem {
            Image(systemName: "hand.point.up.left").foregroundStyle(PSTheme.textSecondary)
        } else if replyVisible, plan != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.success)
        } else {
            MagicGlyph(size: 17, symbol: "waveform")
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = voice.state { return true }
        return false
    }

    /// True when the strip only shows the "tap the mic" hint.
    private var isIdleHint: Bool {
        showsHint && idleHintVisible && !voice.isListening && !isBusy && !isUnavailable && !(replyVisible && !transcript.isEmpty)
    }

    private var statusText: String? {
        if voice.isListening { return voice.partialTranscript.isEmpty ? L("Listening…") : voice.partialTranscript }
        if isBusy { return busyTitle.isEmpty ? L("Working…") : busyTitle }
        if isUnavailable { return L("Voice unavailable — check microphone access in Settings.") }
        if replyVisible, !transcript.isEmpty { return plan?.reply?.isEmpty == false ? plan?.reply : L("Done.") }
        if showsHint, idleHintVisible { return voice.mode == .pushToTalk ? L("Hold the mic and say what to change") : L("Tap the mic and say what to change") }
        return nil
    }
}

/// Five white bars that follow the microphone level, each with its own
/// weight so the meter reads as a voice rather than a single gauge.
struct LevelBars: View {
    let level: Double
    private let weights: [Double] = [0.55, 0.85, 1, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 4 + CGFloat(min(1, max(0, level)) * weights[index]) * 14)
            }
        }
        .frame(height: 18)
        .animation(PSMotion.interactive, value: level)
        .accessibilityHidden(true)
    }
}

/// The voice button at the end of the dock: a glass disc with the mic. When
/// it listens it widens into a violet-tinted capsule with the voice's level
/// and a stop glyph; the glass morphs rather than cross-fades. The screen's
/// edge glow is the only spectrum.
struct MicButton: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool

    @State private var pressing = false
    @Environment(\.psEffects) private var effects
    @Environment(\.psReducedMotion) private var reducedMotion

    private var isListening: Bool { voice.isListening }

    var body: some View {
        HStack(spacing: 10) {
            if isListening {
                LevelBars(level: effects == .minimal || reducedMotion ? 0.5 : voice.level)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .medium))
                    .transition(.opacity)
            } else if isBusy {
                MagicGlyph(size: 20)
                    .symbolEffect(.pulse, isActive: !reducedMotion)
                    .transition(.opacity)
            } else {
                Image(systemName: micSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Color.white)
        .frame(width: isListening ? 116 : 56, height: 56)
        .contentShape(Capsule())
        .psGlass(tint: isListening ? PSTheme.voice.opacity(0.35) : nil, interactive: true, shape: AnyShape(Capsule()))
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(PSMotion.quick, value: pressing)
        .animation(PSMotion.emphasized, value: isListening)
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

#endif
