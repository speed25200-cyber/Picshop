#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// Settings › Live › Diagnostic Live: what the audio stack, the turn-taking
/// and the brain's last answer did, the device checklist, and the redacted log
/// to share. Everything here is read from `LiveServices.shared.debug`.
struct LiveDebugView: View {
    @Environment(\.picshop) private var app
    @State private var logURL: URL?
    private let debug = LiveServices.shared.debug

    var body: some View {
        List {
            Section(L("Audio")) {
                value(L("Brain"), debug.brain)
                value(L("Voice path"), debug.voicePath)
                value(L("Echo cancellation"), debug.echoCancellation ? L("On") : L("Off"))
                value(L("Output route"), debug.outputRoute)
                value(L("Echo risk"), debug.echoRisk)
                value(L("Barge-in"), debug.bargeInMode)
                value(L("Noise floor"), String(format: "%.1f dB", debug.noiseFloorDB))
                value(L("Voice"), debug.voiceDescription)
            }

            Section {
                LiveLevelSparkline(debug: debug)
                    .frame(height: 64)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            } header: {
                Text(L("Level above the noise floor, last 3 s"))
            }

            latencySection

            Section(L("Last answer")) {
                value(L("Model"), debug.lastStats?.model ?? "")
                value(L("First token"), debug.lastStats.map { "\($0.firstTokenMs) ms" } ?? "")
                value(L("Speed"), debug.lastStats.map { String(format: "%.1f tok/s", $0.tokensPerSecond) } ?? "")
                value(L("Prompt / cached tokens"), debug.lastStats.map { "\($0.promptTokens) / \($0.cachedTokens)" } ?? "")
            }

            Section(L("Decisions")) {
                if debug.decisions.isEmpty {
                    Text(L("None yet: start Live in an editor.")).foregroundStyle(PSTheme.textSecondary)
                } else {
                    ForEach(Array(debug.decisions.enumerated()), id: \.offset) { _, decision in
                        Text(verbatim: decision).font(PSFont.mono(12)).foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }

            Section {
                if let settings = app?.settings {
                    Toggle(L("System voice (test)"), isOn: Binding(get: { settings.liveSpeakerUsesSystem }, set: { settings.liveSpeakerUsesSystem = $0 }))
                }
            } header: {
                Text(L("Tests"))
            } footer: {
                Text(L("The system voice speaks through AVSpeechSynthesizer instead of the audio engine, to compare them."))
            }

            Section {
                ForEach(Array(LiveDebugModel.deviceChecklist.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(index + 1)").font(PSFont.rounded(12)).foregroundStyle(PSTheme.textTertiary)
                        Text(step).font(PSFont.footnote()).foregroundStyle(PSTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(L("Device checklist"))
            }

            Section {
                if let logURL {
                    ShareLink(item: logURL, subject: Text(verbatim: "PicShop Live log")) {
                        Label(L("Export the Live log"), systemImage: "square.and.arrow.up")
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("Preparing the log…")).foregroundStyle(PSTheme.textSecondary)
                    }
                }
            } footer: {
                Text(L("Redacted JSON: timings, sizes and decisions. No transcript, no key."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackground().ignoresSafeArea())
        .navigationTitle(L("Live diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .task { logURL = await LiveServices.shared.exportLog() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var latencySection: some View {
        let marks = LatencyTracker.Mark.allCases.map(\.rawValue)
        Section {
            if debug.lastLatencyMs.isEmpty && debug.percentilesMs.isEmpty {
                Text(L("No turn measured yet.")).foregroundStyle(PSTheme.textSecondary)
            } else {
                ForEach(marks, id: \.self) { mark in
                    if debug.lastLatencyMs[mark] != nil || debug.percentilesMs[mark] != nil {
                        HStack {
                            Text(verbatim: mark).font(PSFont.mono(13))
                            Spacer()
                            Text(verbatim: Self.milliseconds(debug.lastLatencyMs[mark]))
                                .foregroundStyle(PSTheme.textPrimary)
                            Text(verbatim: Self.percentiles(debug.percentilesMs[mark]))
                                .foregroundStyle(PSTheme.textTertiary)
                                .frame(minWidth: 96, alignment: .trailing)
                        }
                        .font(PSFont.mono(13))
                    }
                }
            }
        } header: {
            Text(L("Latency from the end of speech"))
        } footer: {
            Text(L("Last turn, then p50 / p90, in milliseconds."))
        }
    }

    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(verbatim: value.isEmpty ? "—" : value)
                .font(PSFont.mono(13))
                .foregroundStyle(PSTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? "—"
    }

    static func percentiles(_ values: [Double]?) -> String {
        guard let values, values.count >= 2 else { return "" }
        return "\(Int(values[0].rounded())) / \(Int(values[1].rounded()))"
    }
}

/// The 10 Hz level history as a line: a leaf, so only it redraws with the level.
private struct LiveLevelSparkline: View {
    let debug: LiveDebugModel

    var body: some View {
        let history = debug.levelHistory
        Canvas { context, size in
            // 0 to 30 dB above the floor, 3 s across.
            let capacity = 30
            guard history.count > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let start = CGFloat(capacity - history.count) * step
            var path = Path()
            for (index, level) in history.enumerated() {
                let x = start + CGFloat(index) * step
                let y = size.height * (1 - CGFloat(min(max(level, 0), 30) / 30))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(PSTheme.textPrimary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(PSTheme.hairline), lineWidth: 1)
        }
        .accessibilityLabel(L("Level above the noise floor, last 3 s"))
        .accessibilityValue(history.last.map { String(format: "%.0f dB", $0) } ?? "")
    }
}
#endif
