#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopSpeech

/// The floating microphone. Tap to talk (or hold, in push-to-talk mode).
/// Rings react to the input level; the icon reflects the recogniser state.
struct VoiceOrb: View {
    @Bindable var voice: VoiceController
    var isBusy: Bool
    var size: CGFloat = 68
    @State private var pulse = false
    @State private var pressing = false

    var body: some View {
        ZStack {
            ring(scale: 1.35, opacity: 0.18)
            ring(scale: 1.18, opacity: 0.32)
            Circle()
                .fill(PSTheme.voiceGradient)
                .frame(width: size, height: size)
                .shadow(color: PSTheme.voice.opacity(voice.isListening ? 0.7 : 0.35), radius: voice.isListening ? 24 : 12)
                .overlay {
                    icon
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .scaleEffect(pressing ? 0.92 : (voice.isListening ? 1 + CGFloat(voice.level) * 0.12 : 1))
                .animation(.spring(duration: 0.2), value: voice.level)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .contentShape(Circle())
        .gesture(orbGesture)
        .onAppear { pulse = true }
        .accessibilityLabel(voice.isListening ? L("Stop listening") : L("Voice command"))
        .accessibilityHint(L("Say what you want to change, for example: remove the dog."))
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        Group {
            if isBusy {
                Image(systemName: "sparkles")
            } else {
                switch voice.state {
                case .listening: Image(systemName: "waveform")
                case .preparing, .finishing: Image(systemName: "ellipsis")
                case .unavailable: Image(systemName: "mic.slash")
                case .idle: Image(systemName: "mic.fill")
                }
            }
        }
    }

    private func ring(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(PSTheme.voice.opacity(opacity), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(voice.isListening ? scale + CGFloat(voice.level) * 0.5 : (pulse ? 1.05 : 1))
            .opacity(voice.isListening ? 1 : 0.5)
            .animation(voice.isListening ? .spring(duration: 0.25) : .easeInOut(duration: 2).repeatForever(autoreverses: true), value: voice.isListening ? voice.level : (pulse ? 1 : 0))
    }

    private var orbGesture: some Gesture {
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
                case .pushToTalk:
                    voice.stop()
                case .tapToTalk, .handsFree:
                    Haptics.confirm()
                    voice.toggle()
                }
            }
    }
}
#endif
