#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
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

            LiveKVLatencySection()

            LiveBrainDebugSection()

            LiveUnderstandingEvalSection()

            MLaneBenchSection()

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

/// « Latence » (W3, D23): the model's first token per path (warm, picture, prefix or cold) against the goals, the
/// barge-in restores, compactions per 10 turns, the measured prefill and decode rates, the engine and its self-test.
/// A leaf: it redraws once per answered turn, and reads the runtime's KV state off the main actor every 5 s.
private struct LiveKVLatencySection: View {
    @State private var diagnostics = LocalKVDiagnostics()

    var body: some View {
        let stats = LocalBrainHub.shared.firstTokenStats
        Section {
            LiveDebugValue(title: L("Engine"), value: diagnostics.engine == .kvEngine ? L("KV engine") : L("ChatSession (W2)"))
            LiveDebugValue(title: L("KV self-test"), value: Self.selfTest(diagnostics))
            LiveDebugValue(title: L("Prefix snapshot"), value: diagnostics.prefix)
            goal(L("Warm first token p50"), stats.percentile(50, path: "warm"), FirstTokenTargets.warmP50Ms)
            goal(L("Warm first token p95"), stats.percentile(95, path: "warm"), FirstTokenTargets.warmP95Ms)
            goal(L("Picture turn p50"), stats.percentile(50, path: "picture"), FirstTokenTargets.pictureP50Ms)
            goal(L("Restored turn p50"), stats.percentile(50, path: "restored"), FirstTokenTargets.warmWithCardsP50Ms)
            goal(L("New conversation p50"), stats.percentile(50, path: "prefix"), FirstTokenTargets.coldMs)
            goal(L("Cold p50"), stats.percentile(50, path: "cold"), FirstTokenTargets.coldMs)
            goal(String(format: L("Barge-in restores: %d, p95"), stats.restoreCount), stats.restorePercentile(95), FirstTokenTargets.restoreMs)
            compactions(stats)
            LiveDebugValue(title: L("Prefill"), value: Self.rates(stats))
            LiveDebugValue(title: L("Decode"), value: stats.decodeTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "")
        } header: {
            Text(L("Latency"))
        } footer: {
            Text(L("First token from the request to the model's first word, in milliseconds, against the goals: warm 0.7 s (1.0 s with new cards), 1.2 s at p95, a picture 1.2 s, a restore 50 ms, at most one compaction per 10 turns."))
        }
        .task {
            while !Task.isCancelled {
                diagnostics = await LocalBrainHub.shared.kvDiagnostics()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func goal(_ title: String, _ value: Int?, _ target: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(verbatim: value.map { "\($0) ms" } ?? "—")
                    .font(PSFont.mono(13))
                    .foregroundStyle(PSTheme.textSecondary)
                Image(systemName: Self.symbol(FirstTokenStats.meets(value, goal: target)))
                    .foregroundStyle(Self.tint(FirstTokenStats.meets(value, goal: target)))
                    .accessibilityLabel(Self.verdict(FirstTokenStats.meets(value, goal: target)))
            }
        }
    }

    private func compactions(_ stats: FirstTokenStats) -> some View {
        let rate = stats.compactionsPer10Turns
        let met: Bool? = stats.turns == 0 ? nil : rate <= FirstTokenTargets.compactionsPer10Turns
        return LabeledContent(L("Compactions per 10 turns")) {
            HStack(spacing: 6) {
                Text(verbatim: stats.turns == 0 ? "—" : String(format: "%.1f (%d / %d)", rate, stats.compactions, stats.turns))
                    .font(PSFont.mono(13))
                    .foregroundStyle(PSTheme.textSecondary)
                Image(systemName: Self.symbol(met)).foregroundStyle(Self.tint(met)).accessibilityLabel(Self.verdict(met))
            }
        }
    }

    static func symbol(_ met: Bool?) -> String {
        switch met {
        case true?: return "checkmark.circle.fill"
        case false?: return "xmark.circle.fill"
        case nil: return "circle.dotted"
        }
    }

    static func tint(_ met: Bool?) -> Color {
        switch met {
        case true?: return PSTheme.success
        case false?: return PSTheme.danger
        case nil: return PSTheme.textTertiary
        }
    }

    static func verdict(_ met: Bool?) -> String {
        switch met {
        case true?: return L("Goal met")
        case false?: return L("Goal missed")
        case nil: return L("Not measured yet")
        }
    }

    static func selfTest(_ diagnostics: LocalKVDiagnostics) -> String {
        switch diagnostics.selfTest {
        case "passed": return L("Passed, pictures included")
        case "mediaFailed": return L("Passed, pictures re-read")
        case "failed": return L("Failed: ChatSession kept")
        case "running": return L("Running")
        case "waiting": return L("Waits for a quiet moment")
        case "pending": return L("Not run yet")
        default: return L("Off")
        }
    }

    /// "warm 840 · picture 610 · cold 520 tok/s".
    static func rates(_ stats: FirstTokenStats) -> String {
        FirstTokenStats.paths.compactMap { path in
            stats.prefillTokensPerSecond(path: path).map { "\(path) \(Int($0.rounded()))" }
        }.joined(separator: " · ").appending(stats.count(path: nil) > 0 ? " tok/s" : "")
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

/// The understanding eval: the dialogue corpus of the unit tests (the same cases, pictures and scorer) through
/// the model loaded on this iPhone, a new conversation per case. The per-category lines are shown here and go to
/// the Live log as counts; the failed turns (which quote what was said) are shown, never logged.
private struct LiveUnderstandingEvalSection: View {
    @State private var task: Task<Void, Never>?
    @State private var step: (done: Int, total: Int)?
    @State private var lines: [String] = []
    @State private var failures: [String] = []
    @State private var refusal: String?

    var body: some View {
        Section {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !failures.isEmpty {
                DisclosureGroup(String(format: L("Failed turns: %d"), failures.count)) {
                    ForEach(Array(failures.prefix(60).enumerated()), id: \.offset) { _, failure in
                        Text(verbatim: failure).font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let refusal {
                Text(verbatim: refusal).font(PSFont.footnote()).foregroundStyle(PSTheme.warning)
            }
            if task != nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(verbatim: step.map { String(format: L("Case %d of %d…"), $0.done, $0.total) } ?? L("Loading the model…"))
                        .foregroundStyle(PSTheme.textSecondary)
                    Spacer()
                    Button(L("Stop")) { task?.cancel() }
                }
            } else {
                Button(L("Run the understanding eval")) { start() }
            }
        } header: {
            Text(L("Understanding eval"))
        } footer: {
            Text(L("About 200 spoken requests on a table screenshot and a poster, run through the on-device model: what it did to the picture and what it said. Keep the screen on; it takes several minutes."))
        }
    }

    private func start() {
        lines = []
        failures = []
        refusal = nil
        step = nil
        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                task = nil
            }
            guard let brain = await LocalBrainHub.shared.evalBrain(mode: .photo) else {
                refusal = L("The on-device model is not ready on this iPhone: install it in Settings › Intelligence, then try again.")
                return
            }
            let model = LocalBrainHub.shared.status.model?.displayName ?? "model"
            let report = await LiveDialogueEvalRunner.evaluate(LiveDialogueCases.all, label: model, makeBrain: { _ in
                // One conversation per case: the case starts from nothing the previous one said.
                await brain.reset()
                return brain
            }, progress: { done, total in
                step = (done, total)
            })
            await brain.reset()
            lines = report.lines
            failures = report.failures
            Self.log(report, model: model, stopped: Task.isCancelled)
        }
    }

    /// Counts only: the Live log never carries a transcript.
    private static func log(_ report: LiveDialogueEvalRunner.Report, model: String, stopped: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        for category in LiveDialogueCase.Category.allCases {
            guard let score = report.scores[category] else { continue }
            LiveServices.shared.record(LiveLogEntry(time: now, event: "eval.category", fields: [
                "category": category.rawValue, "cases": String(score.cases), "turns": String(score.turns), "passed": String(score.passed),
                "percent": String(score.percent), "local_turns": String(score.localTurns), "local_wrong": String(score.localWrong),
            ]))
        }
        let passed = report.scores.values.reduce(0) { $0 + $1.passed }
        let turns = report.scores.values.reduce(0) { $0 + $1.turns }
        LiveServices.shared.record(LiveLogEntry(time: now, event: "eval.done", fields: [
            "model": model, "turns": String(turns), "passed": String(passed), "stopped": stopped ? "1" : "0",
        ]))
    }
}

/// « Banc d'essai M » (W2): the M lane on the loaded 4B or 2B (`MLaneRunner`, single-turn photo requests with their
/// gold operation and arguments, and the W2 dialogues), its scores, its failures, and the JSON report to attach to
/// the device sign-off. Not on battery under 30 %: the run takes minutes of full GPU.
private struct MLaneBenchSection: View {
    @State private var task: Task<Void, Never>?
    @State private var report: MLaneRunner.Report?
    @State private var reportURL: URL?
    @State private var refusal: String?
    @State private var residents = ""

    var body: some View {
        Section {
            if let report {
                ForEach(Array(Self.lines(report).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.failures.isEmpty {
                    DisclosureGroup(String(format: L("Failed turns: %d"), report.failures.count)) {
                        ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                            Text(verbatim: failure).font(PSFont.mono(11)).foregroundStyle(PSTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let reportURL {
                    ShareLink(item: reportURL, subject: Text(verbatim: "PicShop M lane")) {
                        Label(L("Share the JSON report"), systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let refusal {
                Text(verbatim: refusal).font(PSFont.footnote()).foregroundStyle(PSTheme.warning)
            }
            if !residents.isEmpty {
                LabeledContent(L("Models in memory")) {
                    Text(verbatim: residents).font(PSFont.mono(11)).foregroundStyle(PSTheme.textSecondary)
                }
            }
            if task != nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("Running the M lane…")).foregroundStyle(PSTheme.textSecondary)
                    Spacer()
                    Button(L("Stop")) { task?.cancel() }
                }
            } else {
                Button(L("Run the M lane")) { start() }
            }
        } header: {
            Text(L("M test bench"))
        } footer: {
            Text(L("Photo requests with masks and selections, run through the on-device model: operation, arguments, applied and verified. Plug the iPhone in or keep it above 30 %; it takes several minutes."))
        }
        .task { residents = await LocalBrainHub.brokerResidentsLine() }
    }

    private func start() {
        refusal = nil
        guard let problem = Self.batteryProblem() else {
            run()
            return
        }
        refusal = problem
    }

    private func run() {
        report = nil
        reportURL = nil
        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                task = nil
            }
            guard let brain = await LocalBrainHub.shared.evalBrain(mode: .photo) else {
                refusal = L("The on-device model is not ready on this iPhone: install it in Settings › Intelligence, then try again.")
                return
            }
            let model = LocalBrainHub.shared.status.model?.displayName ?? "model"
            let result = await MLaneRunner.run(label: model, makeBrain: {
                // One conversation per case: nothing from the previous case carries over.
                await brain.reset()
                return brain
            })
            await brain.reset()
            report = result
            reportURL = Self.write(result)
            residents = await LocalBrainHub.brokerResidentsLine()
            LiveServices.shared.record(LiveLogEntry(time: ProcessInfo.processInfo.systemUptime, event: "mlane.done", fields: [
                "model": model, "cases": String(result.cases), "op_exact": String(format: "%.3f", result.opExactMatch),
                "applied_verified": String(format: "%.3f", result.appliedVerified), "stopped": Task.isCancelled ? "1" : "0",
            ]))
        }
    }

    /// On battery under 30 %: the reason not to run, in words; nil when it may run.
    static func batteryProblem() -> String? {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        guard device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.3 else { return nil }
        return L("Plug the iPhone in, or run it above 30 % battery.")
    }

    static func lines(_ report: MLaneRunner.Report) -> [String] {
        func percent(_ value: Double) -> String { String(format: "%.1f %%", value * 100) }
        return [
            "\(report.label) · \(report.cases) cases",
            "op exact \(percent(report.opExactMatch)) · args F1 \(percent(report.argumentF1))",
            "first-try valid \(percent(report.firstTryValid)) · applied+verified \(percent(report.appliedVerified))",
            "honest refusals \(percent(report.honestRefusals))",
            String(format: "latency p50 %.2f s · p95 %.2f s", report.latencyP50, report.latencyP95),
        ]
    }

    /// The report as JSON in the temporary folder, for ShareLink.
    static func write(_ report: MLaneRunner.Report) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "mlane-\(report.label.replacingOccurrences(of: " ", with: "-"))-\(stamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            PSLog.error("M lane report not written: \(error)", category: .ui)
            return nil
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
