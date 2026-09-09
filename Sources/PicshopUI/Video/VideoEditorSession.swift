#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import Observation
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopVideo
import PicshopSpeech

/// State and behaviour of the video editor screen.
@MainActor
@Observable
public final class VideoEditorSession {
    public enum Tool: String, CaseIterable, Identifiable {
        case cut, speed, audio, looks, adjust, text, transitions, frame
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .cut: return L("Cut")
            case .speed: return L("Speed")
            case .audio: return L("Audio")
            case .looks: return L("Looks")
            case .adjust: return L("Adjust")
            case .text: return L("Text")
            case .transitions: return L("Transitions")
            case .frame: return L("Frame")
            }
        }
        var symbol: String {
            switch self {
            case .cut: return "scissors"
            case .speed: return "gauge.with.dots.needle.67percent"
            case .audio: return "speaker.wave.2"
            case .looks: return "camera.filters"
            case .adjust: return "slider.horizontal.3"
            case .text: return "textformat"
            case .transitions: return "square.stack.3d.down.right"
            case .frame: return "aspectratio"
            }
        }
    }

    public let projectID: UUID
    public let app: AppEnvironment
    public private(set) var history: EditHistory<VideoTimeline>
    public var timeline: VideoTimeline { history.present }
    public let player: TimelinePlayer
    public let thumbnailer: VideoThumbnailer

    private var services: AVVideoServices?
    private var executor: VideoCommandExecutor?

    public var activeTool: Tool?
    public var selectedClipID: UUID?
    public var selectedParameter: AdjustmentParameter = .exposure
    public var isProcessing = false
    public var processingTitle = ""
    public var processingProgress: Double?
    public var toast: PhotoEditorSession.Toast?
    public var transcript = ""
    public var lastPlan: EditPlan?
    public var pendingClarification: ClarificationRequest?
    public var candidateOverlays: [ObjectCandidate] = []
    public var lastTapPoint: PSPoint?
    public var showsExport = false
    public var showsHelp = false
    public var showsMusicPicker = false
    public var exportedURL: URL?
    public var exportProgress: Double?
    /// Look thumbnails rendered from one frame of a clip, kept per clip.
    public var lookThumbnails: (clipID: UUID, images: [FilterPreset: UIImage])?
    public var showsOriginal = false

    private var toastTask: Task<Void, Never>?
    private var isConfigured = false

    public init(timeline: VideoTimeline, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: timeline)
        player = TimelinePlayer(store: app.store, projectID: projectID)
        thumbnailer = VideoThumbnailer(store: app.store, projectID: projectID)
        selectedClipID = timeline.clips.first?.id
    }

    public func configure() async {
        guard !isConfigured else { return }
        isConfigured = true
        // Same rule as the photo editor: the first frame never waits for Core ML.
        let pipeline = InpaintingPipeline()
        let services = AVVideoServices(store: app.store, projectID: projectID, inpainting: pipeline)
        self.services = services
        executor = VideoCommandExecutor(services: services, language: language) { [weak self] progress in
            Task { @MainActor [weak self] in self?.processingProgress = progress }
        }
        app.voice.onFinalTranscript = { [weak self] text in
            Task { await self?.handleTranscript(text) }
        }
        player.load(timeline)
        let load = Task { [weak self] in
            guard let self else { return }
            await app.attachEngines(to: pipeline)
        }
        pipeline.setLoading(load)
    }

    public func teardown() {
        player.pause()
        app.voice.cancel()
        app.voice.onFinalTranscript = nil
        save()
    }

    public func save() {
        let project = Project(id: projectID, content: .video(timeline), createdAt: timeline.createdAt, modifiedAt: Date())
        app.library.save(project)
    }

    var language: NormalizedUtterance.Language {
        if let hint = app.settings.languageHint { return hint == "fr" ? .french : .english }
        return Locale.current.language.languageCode?.identifier == "fr" ? .french : .english
    }

    public var selectedClip: VideoClip? {
        guard let id = selectedClipID else { return timeline.clip(at: player.currentTime) }
        return timeline.clips.first { $0.id == id } ?? timeline.clip(at: player.currentTime)
    }

    public var selectedClipIndex: Int? {
        selectedClip.flatMap { timeline.index(of: $0.id) }
    }

    var intentContext: IntentContext {
        IntentContext(mode: .video, currentAdjustments: selectedClip?.adjustments ?? .neutral, hasSelection: selectedClipID != nil, selectedIndex: selectedClipIndex,
                      clipCount: timeline.clips.count, textLayerCount: timeline.overlays.filter { $0.textElement != nil }.count, playheadSeconds: player.currentTime,
                      timelineDuration: timeline.duration, frameRate: timeline.frameRate, pendingClarification: pendingClarification, lastTapPoint: lastTapPoint,
                      canUndo: history.canUndo, canRedo: history.canRedo, preferredLanguage: app.settings.languageHint)
    }

    // MARK: - History

    private func commit(_ timeline: VideoTimeline, label: String) {
        var updated = timeline
        updated.touch()
        history.commit(updated, label: label)
        if let selected = selectedClipID, !updated.clips.contains(where: { $0.id == selected }) {
            selectedClipID = updated.clip(at: player.currentTime)?.id
        }
        if !history.isInTransaction { player.load(updated) }
    }

    public func undo() {
        guard history.canUndo else { return }
        let label = history.undo()
        Haptics.tick()
        showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo"))
        player.load(timeline)
    }

    // MARK: - Named versions

    /// Snapshots the user named by voice ("enregistre cette version sous brouillon").
    public private(set) var versions: [(name: String, state: VideoTimeline)] = []

    func handleVersionEffect(_ message: String) {
        let parts = message.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let requested = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        if parts[1] == "save" {
            let name = requested.isEmpty ? "v\(versions.count + 1)" : requested
            versions.removeAll { $0.name.lowercased() == name.lowercased() }
            versions.append((name, timeline))
            showToast(String(format: L("Version “%@” saved"), name))
            Haptics.success()
        } else if parts[1] == "restore" {
            let match = requested.isEmpty ? versions.last : versions.last { $0.name.lowercased() == requested.lowercased() } ?? versions.last { $0.name.lowercased().contains(requested.lowercased()) }
            guard let match else {
                showToast(versions.isEmpty ? L("No saved version yet. Say “save this version as …”.") : String(format: L("No version named “%@”"), requested), isError: true)
                return
            }
            restoreVersion(match.state, label: String(format: L("Version “%@”"), match.name))
        }
    }

    private func restoreVersion(_ state: VideoTimeline, label: String) {
        history.commit(state, label: label)
        player.load(timeline)
        showToast(label)
        Haptics.success()
    }

    public func redo() {
        guard history.canRedo else { return }
        let label = history.redo()
        Haptics.tick()
        showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo"))
        player.load(timeline)
    }

    public func revert() {
        history.revertToOriginal()
        player.load(timeline)
    }

    // MARK: - Direct edits

    public func update(_ label: String, _ body: (inout VideoTimeline) -> Void) {
        var timeline = self.timeline
        body(&timeline)
        commit(timeline, label: label)
    }

    public func updateSelectedClip(_ label: String, _ body: (inout VideoClip) -> Void) {
        guard let id = selectedClip?.id else { return }
        update(label) { $0.update(clipID: id, body) }
    }

    public func beginSliderInteraction(_ label: String) { history.beginTransaction(label: label) }
    public func endSliderInteraction() { history.endTransaction(); player.load(timeline) }

    public func setAdjustment(_ parameter: AdjustmentParameter, value: Double) {
        guard let id = selectedClip?.id else { return }
        var timeline = self.timeline
        timeline.update(clipID: id) { $0.adjustments[parameter] = value }
        history.commit(timeline, label: parameter.englishName)
        // Rebuild lazily: the player refreshes when the interaction ends.
    }

    public func splitAtPlayhead() {
        Task { await run(EditIntent(action: .split, time: player.currentTime)) }
    }

    public func deleteSelectedClip() {
        guard let index = selectedClipIndex else { return }
        Task { await run(EditIntent(action: .deleteClip, clipIndex: index + 1)) }
    }

    public func trimSelectedClip(startOffset: Double?, endOffset: Double?) {
        guard let id = selectedClip?.id else { return }
        update(L("Trim")) { $0.trim(clipID: id, startOffset: startOffset, endOffset: endOffset) }
    }

    public func setClipSourceRange(_ id: UUID, _ range: TimeSpan) {
        update(L("Trim")) { timeline in
            timeline.update(clipID: id) { $0.sourceRange = range }
        }
    }

    public func addMusic(from url: URL) async {
        do {
            try app.store.createPackage(for: projectID)
            let relative = "\(Project.mediaDirectory)/music-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
            let destination = app.store.url(for: relative, in: projectID)
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                try FileManager.default.copyItem(at: url, to: destination)
            } else {
                try FileManager.default.copyItem(at: url, to: destination)
            }
            let asset = AVURLAsset(url: destination)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let media = MediaAsset(kind: .audio, relativePath: relative, pixelSize: .zero, duration: duration, origin: .file)
            update(L("Add Music")) { timeline in
                timeline.audioTracks = [AudioTrack(asset: media, name: url.deletingPathExtension().lastPathComponent)]
            }
            Haptics.success()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Voice pipeline

    public func handleTranscript(_ text: String) async {
        transcript = text
        let plan = await app.router.plan(text, context: intentContext)
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            showToast(reply + "\n" + Replies.suggestions(for: .video, language: language), isError: true)
            VoiceFeedback.shared.speak(reply, language: plan.language)
            return
        }
        VoiceFeedback.shared.speak(plan.reply ?? "", language: plan.language)
        for intent in plan.intents where intent.action != .unknown {
            let outcome = await run(intent)
            if case .needsClarification = outcome { break }
            if case .failed = outcome { break }
        }
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        guard var executor else { return .failed(message: "not ready") }
        executor.language = language
        let heavy: Set<IntentAction> = [.removeObject, .chooseCandidate, .stabilize, .reverse, .blurBackground, .removeBackground, .replaceBackground, .freezeFrame, .extractFrame]
        if heavy.contains(intent.action) {
            isProcessing = true
            processingProgress = 0
            processingTitle = processingLabel(for: intent)
            player.pause()
        }
        defer { isProcessing = false; processingProgress = nil }
        let (updated, result) = await executor.execute(intent, on: timeline, context: intentContext)
        handle(result, updated: updated, intent: intent)
        return result.outcome
    }

    private func processingLabel(for intent: EditIntent) -> String {
        switch intent.action {
        case .removeObject: return String(format: L("Erasing %@ across the clip…"), intent.target?.originalPhrase ?? L("object"))
        case .chooseCandidate: return L("Erasing across the clip…")
        case .stabilize: return L("Stabilizing…")
        case .reverse: return L("Reversing…")
        case .blurBackground, .removeBackground, .replaceBackground: return L("Rendering portrait effect…")
        case .freezeFrame: return L("Creating freeze frame…")
        case .extractFrame: return L("Saving frame…")
        default: return L("Working…")
        }
    }

    private func handle(_ result: ExecutionResult, updated: VideoTimeline, intent: EditIntent) {
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            candidateOverlays = []
            if updated != timeline { commit(updated, label: label) }
            if !label.isEmpty { showToast(label, undoable: history.canUndo) }
            Haptics.success()
        case .needsClarification(let request):
            pendingClarification = request
            candidateOverlays = request.candidates
            showToast(request.question)
            VoiceFeedback.shared.speak(request.question, language: language.rawValue)
            Haptics.warning()
            if app.settings.voiceMode != .pushToTalk {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    if app.voice.state == .idle { app.voice.start() }
                }
            }
        case .info(let message):
            showToast(message)
        case .failed(let message):
            showToast(message, isError: true)
            Haptics.error()
        case .ignored:
            break
        }
        for effect in result.effects {
            switch effect {
            case .message(let message) where message.hasPrefix("version:"): handleVersionEffect(message)
            case .undo: undo()
            case .redo: redo()
            case .revert: revert()
            case .play: player.play()
            case .pause: player.pause()
            case .seek(let time): Task { await player.seek(to: time) }
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .pickMusic: showsMusicPicker = true
            case .selectClip(let id): selectedClipID = id
            case .compare:
                showsOriginal = true
                Task { try? await Task.sleep(for: .seconds(1.5)); showsOriginal = false }
            case .cancel:
                pendingClarification = nil
                candidateOverlays = []
            default: break
            }
        }
    }

    public func choose(candidateIndex: Int) { Task { await run(EditIntent(action: .chooseCandidate, index: candidateIndex + 1)) } }
    public func chooseAllCandidates() { Task { await run(EditIntent(action: .chooseCandidate, scope: .all)) } }
    public func cancelClarification() { pendingClarification = nil; candidateOverlays = [] }

    public func tapPreview(at point: PSPoint) {
        lastTapPoint = point
        if let pending = pendingClarification,
           let hit = pending.candidates.filter({ $0.boundingBox.insetBy(dx: -0.02, dy: -0.02).contains(point) }).min(by: { $0.boundingBox.area < $1.boundingBox.area }),
           let index = pending.candidates.firstIndex(where: { $0.id == hit.id }) {
            choose(candidateIndex: index)
        }
    }

    // MARK: - Export

    public func export(options: VideoExportOptions) async {
        exportProgress = 0
        defer { exportProgress = nil }
        player.pause()
        do {
            let url = try await VideoExporter.export(timeline, store: app.store, projectID: projectID, options: options) { [weak self] progress in
                Task { @MainActor [weak self] in self?.exportProgress = progress }
            }
            exportedURL = url
            Haptics.success()
            showToast(options.saveToPhotos ? L("Saved to Photos") : L("Exported"))
        } catch {
            Haptics.error()
            showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    public func showToast(_ text: String, isError: Bool = false, undoable: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = PhotoEditorSession.Toast(text: text, isError: isError, undoable: undoable) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 3.5 : (undoable ? 4 : 2.2)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}
#endif
