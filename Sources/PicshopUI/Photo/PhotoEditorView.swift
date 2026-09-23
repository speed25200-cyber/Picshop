#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The photo editing screen.
public struct PhotoEditorView: View {
    @State var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    /// Height of the voice strip floating above the dock (0 when it is empty).
    @State private var stripHeight: CGFloat = 0

    public init(session: PhotoEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        EditorChrome(edgeToEdge: true) {
            PhotoCanvasView(session: session, floatingBottomInset: stripHeight > 0 ? stripHeight + 8 : 0)
                // No blocking HUD while work runs: the picture itself is held still.
                .allowsHitTesting(!session.isProcessing)
        } top: {
            EditorTopBar(
                title: session.document.title.isEmpty ? L("Photo") : session.document.title,
                // Pixel dimensions only mean something while framing.
                subtitle: session.isCropping ? "\(Int(session.document.canvasSize.width)) × \(Int(session.document.canvasSize.height))" : nil,
                // A step undone under a running erase would only make it drop its result.
                canUndo: session.history.canUndo && !session.isProcessing, canRedo: session.history.canRedo && !session.isProcessing,
                onClose: { session.teardown(); dismiss() },
                onUndo: { session.undo() }, onRedo: { session.redo() },
                onHelp: { session.showsHelp = true }, onExport: { session.showsExport = true },
                history: session.isProcessing ? [] : session.history.past.map(\.label), onUndoSteps: { session.undo(steps: $0) },
                onRevert: session.isProcessing ? nil : { _ = session.revert() })
        } bottom: {
            bottomArea
        }
        // Progress and toasts live in their own view, so a progress tick never
        // re-evaluates the canvas and the dock.
        .overlay {
            // Only while listening: running work already shimmers over the picture.
            if let app { EditorIntelligenceGlow(voice: app.voice, isBusy: false) }
        }
        .overlay { EditorStatusOverlay(session: session) }

        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { ExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .photo) { text in Task { await session.handleTranscript(text) } } }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Bottom

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let tool = session.activeTool {
                PhotoToolPanel(session: session, tool: tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // One glass group: the mic widens into its listening capsule and
            // the dock gives way, as one material.
            PSGlassContainer(spacing: 8) {
                HStack(spacing: 10) {
                    GroupedToolDock(groups: PhotoEditorSession.Tool.groups, selection: $session.activeTool, isModified: { isModified($0) })
                    if let app {
                        // A new command would only get "One moment…"; stopping a session still works.
                        let holds = session.isProcessing && !app.voice.isListening
                        MicButton(voice: app.voice, isBusy: session.isProcessing)
                            .disabled(holds)
                            .allowsHitTesting(!holds)
                    }
                }
            }
        }
        // The strip floats above the panel instead of pushing it: a reply
        // coming and going never moves the photo.
        .overlay(alignment: .top) {
            if let app {
                VoiceStrip(voice: app.voice, isBusy: session.isProcessing, busyTitle: session.processingTitle,
                           transcript: session.transcript, plan: session.lastPlan, replyIsProblem: session.lastReplyIsProblem, replyIsError: session.lastReplyIsError,
                           replyID: session.replyID, clarification: session.pendingClarification,
                           showsHint: session.activeTool == nil,
                           candidateThumbnail: { await session.candidateThumbnail($0) },
                           onChoose: { session.choose(candidateIndex: $0) }, onChooseAll: { session.chooseAllCandidates() }, onCancel: { session.cancelClarification() })
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .psDockBackground()
        .animation(PSMotion.standard, value: session.activeTool)
    }

    /// Whether a dock group's edits are in the picture (Photos' yellow dot).
    private func isModified(_ group: ToolGroup<PhotoEditorSession.Tool>) -> Bool {
        let document = session.document
        let operations = document.baseLayer?.edits.operations ?? []
        switch group.id {
        case "magic":
            return document.baseLayer?.edits.resolvedLensBlur != nil
        case "adjust":
            return !document.activeAdjustments.isNeutral || document.baseLayer?.edits.resolvedLook != nil
                || !session.colorMixer.isNeutral || !session.colorGrade.isNeutral || session.lut != nil
        case "retouch":
            return operations.contains { operation in
                switch operation.kind {
                case .removeObject, .heal, .removeBackground, .replaceBackground, .blurBackground, .generativeFill,
                     .recolor, .cloneStamp, .pixelPaint, .blurRegion, .moveObject:
                    return true
                default:
                    return false
                }
            }
        case "crop":
            return document.baseLayer?.edits.hasGeometry ?? false
        case "layers":
            return document.layers.count > 1
        default:
            return false
        }
    }
}

/// Press-and-hold "before" button floating over the canvas, like Photos.
/// Live zoom factor in the corner of the canvas; tapping it snaps back to fit.
struct ZoomBadge: View {
    let zoom: CGFloat
    let onReset: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            onReset()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .medium))
                Text("\(Int((zoom * 100).rounded())) %").font(.footnote.monospacedDigit().weight(.medium)).contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .psGlass(interactive: true, variant: .clear)
            .animation(PSMotion.numeric, value: zoom)
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(L("Reset zoom"))
    }
}

struct CompareButton: View {
    var isShowingOriginal: Bool
    var onChange: (Bool) -> Void
    @State private var holding = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isShowingOriginal ? "eye.fill" : "eye").font(.system(size: 15, weight: .medium))
            Text(isShowingOriginal ? L("Original") : L("Before")).font(.footnote.weight(.medium))
        }
        .foregroundStyle(isShowingOriginal ? Color.black : PSTheme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Capsule().fill(Color.white).opacity(isShowingOriginal ? 1 : 0))
        .psGlass(interactive: true, variant: .clear)
        .scaleEffect(holding ? 0.95 : 1)
        .animation(PSMotion.quick, value: holding)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    Haptics.soft()
                    onChange(true)
                }
                .onEnded { _ in
                    holding = false
                    onChange(false)
                }
        )
        .accessibilityLabel(L("Compare with original"))
        .accessibilityHint(L("Hold to see the original photo."))
    }
}
#endif
