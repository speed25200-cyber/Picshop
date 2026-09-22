#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopVideo

/// Edit by text: the words of the video, in the order they are said. Tap
/// words to strike them and the struck words leave the video, with the
/// pause after them, so the sentence closes up. The word being spoken
/// lights up while the video plays, and the list follows it.
struct TranscriptPanel: View {
    @Bindable var session: VideoEditorSession
    @State private var selection: Set<Int> = []
    @State private var activeWord: Int?
    /// Hesitations found in the words, worked out once per transcript rather than on every redraw.
    @State private var fillers: Set<Int> = []

    var body: some View {
        if let captions = session.timeline.captions, !captions.isEmpty {
            editor(captions)
        } else {
            emptyState
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        HStack(spacing: 14) {
            MagicGlyph(size: 26, symbol: "text.quote")
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Edit by text")).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                Text(L("PicShop writes down what is said. Strike words and they leave the video."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                Haptics.magic()
                Task { await session.transcribeForEditing() }
            } label: {
                Text(L("Transcribe")).font(PSFont.headline(14)).foregroundStyle(PSTheme.onAccent)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(PSTheme.accent))
            }
            .buttonStyle(PSPressStyle(scale: 0.94))
            .disabled(session.isProcessing)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Editor

    private func editor(_ captions: CaptionTrack) -> some View {
        let cues = captions.cues
        let words = cues.flatMap(\.words)
        var offsets: [Int] = []
        var running = 0
        for cue in cues {
            offsets.append(running)
            running += cue.words.count
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Edit by text")).font(PSFont.headline(14)).foregroundStyle(PSTheme.textPrimary)
                    Text(String(format: L("%d words · tap to strike"), words.count))
                        .font(PSFont.caption(11)).foregroundStyle(PSTheme.textTertiary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    Haptics.tap()
                    session.update(captions.isVisible ? L("Hide Captions") : L("Show Captions")) { $0.captions?.isVisible.toggle() }
                } label: {
                    Image(systemName: captions.isVisible ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(captions.isVisible ? PSTheme.accent : PSTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(captions.isVisible ? L("Hide captions") : L("Show captions"))
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            TranscriptCueRow(cue: cue, base: offsets[index], selection: selection, fillers: fillers, activeWord: activeWord,
                                             onTap: { toggle($0, word: words[$0]) },
                                             onSeek: { Task { await session.player.seek(to: cue.span.start) } })
                                .id(cue.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 176)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .background(TranscriptFollower(player: session.player, starts: words.map(\.start), activeWord: $activeWord))
                .onChange(of: activeWord) { _, word in
                    guard let word, session.player.isPlaying, let cueIndex = offsets.lastIndex(where: { $0 <= word }) else { return }
                    withAnimation(PSMotion.standard) { proxy.scrollTo(cues[cueIndex].id, anchor: .center) }
                }
            }

            actionBar(fillers: fillers.count)
        }
        .onChange(of: words.count) { selection = [] }
        .task(id: "\(words.count)-\(words.last?.end ?? 0)") { fillers = TranscriptEditor.fillers(in: words).wordIndices }
        .animation(PSMotion.quick, value: selection.isEmpty)
    }

    private func actionBar(fillers: Int) -> some View {
        HStack(spacing: 8) {
            if selection.isEmpty {
                PanelChip(title: fillers > 0 ? String(format: L("Remove fillers (%d)"), fillers) : L("Remove fillers"), symbol: "waveform.badge.minus", tint: PSTheme.voice, isEnabled: !session.isProcessing) {
                    Task { await session.run(EditIntent(action: .removeFillers)) }
                }
                PanelChip(title: L("Jump cuts"), symbol: "scissors", tint: PSTheme.voice, isEnabled: !session.isProcessing) {
                    Task { await session.run(EditIntent(action: .removeSilences)) }
                }
                Spacer(minLength: 0)
            } else {
                PanelChip(title: L("Clear"), symbol: "xmark") { selection = [] }
                Spacer(minLength: 0)
                Button {
                    let struck = selection
                    selection = []
                    session.cutWords(at: struck)
                } label: {
                    Label(selection.count == 1 ? L("Cut 1 word") : String(format: L("Cut %d words"), selection.count), systemImage: "scissors")
                        .font(PSFont.headline(14)).foregroundStyle(PSTheme.onAccent)
                        .padding(.horizontal, 16).frame(height: 38)
                        .background(Capsule().fill(PSTheme.accent))
                        .contentTransition(.numericText())
                }
                .buttonStyle(PSPressStyle(scale: 0.95))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    private func toggle(_ index: Int, word: CaptionWord) {
        Haptics.tick()
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        session.player.pause()
        Task { await session.player.seek(to: word.start) }
    }
}

/// One caption line: its time (tap to go there), then its words.
private struct TranscriptCueRow: View {
    let cue: CaptionCue
    let base: Int
    let selection: Set<Int>
    let fillers: Set<Int>
    let activeWord: Int?
    let onTap: (Int) -> Void
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(timeLabel(cue.span.start)).font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary)
                    .frame(width: 38, alignment: .leading).padding(.top, 4)
            }
            .buttonStyle(.plain)
            FlowLayout(spacing: 2) {
                ForEach(Array(cue.words.enumerated()), id: \.offset) { offset, word in
                    let index = base + offset
                    TranscriptWord(text: word.text, isStruck: selection.contains(index), isFiller: fillers.contains(index), isActive: activeWord == index)
                        .onTapGesture { onTap(index) }
                }
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TranscriptWord: View {
    let text: String
    let isStruck: Bool
    let isFiller: Bool
    let isActive: Bool

    var body: some View {
        Text(text)
            .font(PSFont.body(16).weight(isActive ? .semibold : .regular))
            .strikethrough(isStruck, color: PSTheme.accent)
            .underline(isFiller && !isStruck, pattern: .dot, color: PSTheme.intelligence[1])
            .foregroundStyle(isStruck ? PSTheme.textTertiary : (isFiller ? PSTheme.textSecondary : PSTheme.textPrimary))
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isStruck ? PSTheme.accentSoft : (isActive ? Color.white.opacity(0.14) : .clear))
            )
            .contentShape(Rectangle())
            .animation(PSMotion.quick, value: isStruck)
            .animation(PSMotion.quick, value: isActive)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isStruck ? L("Will be cut") : "")
    }
}

/// Watches the playhead on its own, so only the spoken word's change — not
/// every frame — reaches the transcript.
private struct TranscriptFollower: View {
    let player: TimelinePlayer
    let starts: [Double]
    @Binding var activeWord: Int?

    var body: some View {
        Color.clear
            .onChange(of: player.currentTime, initial: true) { _, time in
                let index = Self.lastIndex(in: starts, atOrBefore: time + 0.02)
                if index != activeWord { activeWord = index }
            }
    }

    /// Binary search: the last start at or before `time`.
    static func lastIndex(in starts: [Double], atOrBefore time: Double) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
#endif
