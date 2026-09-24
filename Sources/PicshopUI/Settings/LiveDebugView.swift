#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// Settings › Live › Diagnostic Live: the voice self-test, what the audio stack,
/// the turn-taking and the brain's last answers did, the device checklist, and the
/// redacted log to share. Everything here is read from `LiveServices.shared`
/// (`debug`, `selfTest`) and, in a leaf, `LocalBrainHub.shared.status`.
struct LiveDebugView: View {
    @Environment(\.picshop) private var app
    @State private var logURL: URL?
    private let debug = LiveServices.shared.debug

    var body: some View {
        List {
            LiveSelfTestSection(app: app)

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

            LiveBrainDebugSection()

            Section(L("Last answer")) {
                value(L("Model"), debug.lastStats?.model ?? "")
                value(L("First token"), debug.lastStats.map { "\($0.firstTokenMs) ms" } ?? "")
                value(L("First token p50 / p90"), debug.firstTokenPercentilesMs.map { "\($0.p50) / \($0.p90) ms" } ?? "")
                value(L("Speed"), debug.lastStats.map { String(format: "%.1f tok/s", $0.tokensPerSecond) } ?? "")
                value(L("Median speed"), debug.medianTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "")
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
        LiveDebugValue(title: title, value: value)
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? "—"
    }

    static func percentiles(_ values: [Double]?) -> String {
        guard let values, values.count >= 2 else { return "" }
        return "\(Int(values[0].rounded())) / \(Int(values[1].rounded()))"
    }
}

/// One diagnostic row: a title and a monospaced value (a dash when empty).
private struct LiveDebugValue: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(verbatim: value.isEmpty ? "—" : value)
                .font(PSFont.mono(13))
                .foregroundStyle(PSTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Tester le vocal: the six steps with ✓/✗ and their reasons, Oui / Non while the
/// voice step waits, and the last summary. A leaf: only it redraws while the test runs.
private struct LiveSelfTestSection: View {
    let app: AppEnvironment?
    private let services = LiveServices.shared

    var body: some View {
        let test = services.selfTest
        Section {
            ForEach(test.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    symbol(step.status)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(PSFont.body()).foregroundStyle(PSTheme.textPrimary)
                        if let reason = step.status.reason {
                            Text(verbatim: reason).font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let instruction = test.instruction {
                Text(verbatim: instruction).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
            }
            if test.asksHeard {
                HStack(spacing: 12) {
                    Button(L("Yes")) { test.answerHeard(true) }
                        .buttonStyle(.borderedProminent)
                    Button(L("No")) { test.answerHeard(false) }
                        .buttonStyle(.bordered)
                }
            }
            if let refusal = test.refusal {
                Text(verbatim: refusal).font(PSFont.footnote()).foregroundStyle(PSTheme.warning)
            }
            Button {
                guard let app else { return }
                Task { await test.run(app: app) }
            } label: {
                HStack(spacing: 10) {
                    if test.isRunning { ProgressView() }
                    Text(test.isRunning ? L("Testing…") : L("Test the voice"))
                }
            }
            .disabled(test.isRunning || app == nil)
        } header: {
            Text(L("Test the voice"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Six checks, about a minute: permissions, speech model, voice, listening, duplex with headphones, brain. Everything stays on the iPhone."))
                if let summary = services.selfTestSummary {
                    Text(verbatim: summary).font(PSFont.mono(12))
                }
            }
        }
    }

    @ViewBuilder
    private func symbol(_ status: LiveSelfTest.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(PSTheme.textTertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(PSTheme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(PSTheme.danger)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(PSTheme.textTertiary)
        }
    }
}

/// The brain side: the local model, its tier and state, and the thermal state.
/// A leaf, so the hub's status (download progress) redraws only these rows.
private struct LiveBrainDebugSection: View {
    var body: some View {
        let status = LocalBrainHub.shared.status
        Section(L("Brain")) {
            LiveDebugValue(title: L("On-device model"), value: status.model?.displayName ?? "")
            LiveDebugValue(title: L("Model tier"), value: "\(status.decision.tier.rawValue) · \(status.decision.reason.rawValue)")
            LiveDebugValue(title: L("Model state"), value: Self.phase(status.phase))
            if let speed = status.speed {
                LiveDebugValue(title: L("Speed test result"), value: String(format: "%.1f tok/s", speed.tokensPerSecond) + " · \(speed.firstTokenMs) ms")
            }
            SwiftUI.TimelineView(.periodic(from: .now, by: 2)) { _ in
                LiveDebugValue(title: L("Thermal state"), value: LiveDebugModel.thermalDescription(ProcessInfo.processInfo.thermalState))
            }
        }
    }

    static func phase(_ phase: LocalBrainStatus.Phase) -> String {
        switch phase {
        case .notInThisBuild: return "not in this build"
        case .unsupported: return "unsupported"
        case .notInstalled: return "not installed"
        case .waitingForWiFi: return "waiting for Wi-Fi"
        case .downloading(let progress): return "downloading \(Int((progress * 100).rounded())) %"
        case .verifying: return "verifying"
        case .installed: return "installed"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed(let message): return "failed: \(message.prefix(60))"
        }
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
