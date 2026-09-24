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
///
/// Views never read `history`: `timeline`, `canUndo`, `canRedo`, `undoLabels`
/// and `revision` are stored mirrors, brought up to date by didChangeHistory()
/// after every history write.
@MainActor
@Observable
public final class VideoEditorSession {
    public enum Tool: String, CaseIterable, Identifiable {
        case magic, transcript, cut, speed, motion, audio, looks, adjust, color, text, overlay, transitions, frame
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .magic: return L("Magic")
            case .transcript: return L("Transcript")
            case .overlay: return L("Overlays")
            case .motion: return L("Pan & Zoom")
            case .color: return L("Colour")
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
            case .magic: return "sparkles"
            case .transcript: return "text.quote"
            case .overlay: return "rectangle.on.rectangle"
            case .motion: return "arrow.up.left.and.down.right.magnifyingglass"
            case .color: return "paintpalette"
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
    @ObservationIgnored public private(set) var history: EditHistory<VideoTimeline> {
        didSet { didChangeHistory() }
    }
    /// Stored mirror of `history.present`, updated by didChangeHistory() only.
    public private(set) var timeline: VideoTimeline
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// Past labels, oldest first.
    public private(set) var undoLabels: [String] = []
    /// Bumped whenever the timeline changes (undo and redo included); Live's document version.
    public private(set) var revision = 0
    public let player: TimelinePlayer
    public let thumbnailer: VideoThumbnailer
    /// Picshop Live in this editor, attached at the end of init.
    public let live: LiveSession
    /// True for the whole of a Live session: no toast for Live steps, no spoken reply, no recogniser start.
    @ObservationIgnored public var liveSpeechSuppressed = false
    @ObservationIgnored private var isTornDown = false
    /// > 0 while Live runs a step (liveRun, a chip, a choice, an undo): no toast, no speech.
    @ObservationIgnored var liveRunDepth = 0
    /// The effects the last executed step reported.
    @ObservationIgnored var lastEffects: [EditorEffect] = []
    /// The heavy step running now; cancelProcessing() drops its result.
    @ObservationIgnored private var processingTask: Task<(VideoTimeline, ExecutionResult), Never>?
    @ObservationIgnored private var processingGeneration = 0
    @ObservationIgnored private var droppedGenerations: Set<Int> = []
    @ObservationIgnored private var isStepping = false
    /// Live's frame: one per clip and revision.
    @ObservationIgnored var snapshotCache: (key: String, image: LiveImage)?
    /// The clip under the playhead as Live last heard of it (checked once a second).
    @ObservationIgnored private var playheadClip: Int?
    @ObservationIgnored private var playheadWatch: Task<Void, Never>?
    @ObservationIgnored private var compareTask: Task<Void, Never>?
    /// Revision at the last thumbnail handed to the library.
    @ObservationIgnored private var thumbnailRevision = 0
    @ObservationIgnored private var lastSavedTimeline: VideoTimeline?

    private var services: AVVideoServices?
    private var executor: VideoCommandExecutor?

    public var activeTool: Tool?
    public var selectedClipID: UUID? {
        didSet { if selectedClipID != oldValue { live.noteContextChanged() } }
    }
    public var selectedParameter: AdjustmentParameter = .exposure
    public var isProcessing = false
    public var processingTitle = ""
    public var processingProgress: Double?
    public var toast: PhotoEditorSession.Toast?
    public var transcript = ""
    public var lastPlan: EditPlan?
    /// The last reply says the command could not be done as said (or failed).
    public private(set) var lastReplyIsProblem = false
    public private(set) var lastReplyIsError = false
    public var pendingClarification: ClarificationRequest? {
        didSet { if pendingClarification != oldValue { live.noteContextChanged() } }
    }
    public var candidateOverlays: [ObjectCandidate] = []
    @ObservationIgnored public var lastTapPoint: PSPoint?
    public var showsExport = false
    /// A command to run as soon as the editor is ready (Magic shortcuts on Home).
    public var pendingCommand: String?
    /// The picture or video overlay being arranged.
    public var selectedOverlayID: UUID?
    public var showsHelp = false
    public var showsMusicPicker = false
    /// Where the next imported sound goes: a timeline second (nil = the playhead)
    /// and whether it replaces the existing tracks or joins them.
    public var pendingSoundPlacement: (time: Double?, replace: Bool) = (nil, false)
    public var exportedURL: URL?
    public var exportProgress: Double?
    /// Look thumbnails rendered from one frame of a clip, kept per clip.
    public var lookThumbnails: (clipID: UUID, images: [FilterPreset: UIImage])?
    public var showsOriginal = false

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var isConfigured = false

    public init(timeline: VideoTimeline, projectID: UUID, app: AppEnvironment) {
        self.projectID = projectID
        self.app = app
        history = EditHistory(initial: timeline)
        self.timeline = timeline
        player = TimelinePlayer(store: app.store, projectID: projectID)
        thumbnailer = VideoThumbnailer(store: app.store, projectID: projectID)
        selectedClipID = timeline.clips.first?.id
        live = LiveSession(app: app, mode: .video, canGoLive: true)
        live.attach(self)
    }

    public func configure() async {
        guard !isConfigured else { return }
        isConfigured = true
        // Same rule as the photo editor: the first frame never waits for Core ML.
        let pipeline = InpaintingPipeline()
        let services = AVVideoServices(store: app.store, projectID: projectID, inpainting: pipeline)
        services.captionLocale = Locale(identifier: language == .french ? "fr-FR" : "en-US")
        self.services = services
        executor = VideoCommandExecutor(services: services, language: language) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isProcessing, self.processingProgress != progress else { return }
                self.processingProgress = progress
            }
        }
        lastSavedTimeline = timeline
        player.load(timeline)
        watchPlayhead()
        let load = Task { [weak self] in
            guard let self else { return }
            await app.attachEngines(to: pipeline)
        }
        pipeline.setLoading(load)
        if let command = pendingCommand {
            pendingCommand = nil
            Task { [weak self] in await self?.handleTranscript(command) }
        }
    }

    /// Ends the session: Live, playback and the voice stop, and the video is saved. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        Diagnostics.shared.note("video editor teardown")
        live.teardown()
        playheadWatch?.cancel()
        player.pause()
        app.voice.cancel()
        save()
    }

    /// Saves off the main thread (the library orders the writes) and hands the
    /// library a thumbnail from the first frame, decoded off the main thread.
    public func save() {
        let modifiedAt = Date()
        let library = app.library
        if timeline != lastSavedTimeline {
            let project = Project(id: projectID, content: .video(timeline), createdAt: timeline.createdAt, modifiedAt: modifiedAt)
            lastSavedTimeline = timeline
            Task { await library.persist(project) }
        }
        guard revision != thumbnailRevision else { return }
        thumbnailRevision = revision
        let saved = timeline
        let thumbnailer = self.thumbnailer
        let id = projectID
        Task {
            guard let poster = await thumbnailer.poster(for: saved) else { return }
            library.setThumbnail(UIImage(cgImage: poster), for: id, modifiedAt: modifiedAt)
        }
    }

    /// Live hears of a new clip under the playhead, at most once a second.
    private func watchPlayhead() {
        playheadWatch?.cancel()
        playheadWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let clip = self.clipIndex(at: self.player.currentTime)
                if clip != self.playheadClip {
                    self.playheadClip = clip
                    self.live.noteContextChanged()
                }
            }
        }
    }

    /// 1-based index of the clip at a timeline second, as spoken ("clip 2").
    func clipIndex(at seconds: Double) -> Int? {
        guard let clip = timeline.clip(at: seconds), let index = timeline.index(of: clip.id) else { return nil }
        return index + 1
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

    /// Brings the stored mirrors up to date after any change to `history`, each
    /// assigned only when its value changes, then tells Live.
    private func didChangeHistory() {
        let present = history.present
        let timelineChanged = present != timeline
        let labels = history.past.map(\.label)
        // A new step (not an undo or a redo): the list grew, or at the limit its oldest entry went.
        let isNewStep = !isStepping && !history.canRedo && labels != undoLabels
            && (labels.count > undoLabels.count || labels.count == history.limit)
        var changed = timelineChanged
        if timelineChanged {
            timeline = present
            revision += 1
        }
        if canUndo != history.canUndo { canUndo = history.canUndo; changed = true }
        if canRedo != history.canRedo { canRedo = history.canRedo; changed = true }
        if labels != undoLabels { undoLabels = labels; changed = true }
        // A dial drag is one change, told when it ends.
        guard changed, !history.isInTransaction else { return }
        live.noteDocumentChanged(label: isNewStep ? history.undoLabel : nil)
    }

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
        isStepping = true
        let label = history.undo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        player.load(timeline)
    }

    /// Goes back several steps at once (the History list): one refresh, one toast.
    /// Returns the labels undone, newest first.
    @discardableResult
    public func undo(steps: Int) -> [String] {
        guard steps > 0, history.canUndo else { return [] }
        var labels: [String] = []
        isStepping = true
        for _ in 0..<steps where history.canUndo {
            if let label = history.undo() { labels.append(label) }
        }
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(labels.last.map { "\(L("Undo")) · \($0)" } ?? L("Undo")) }
        player.load(timeline)
        return labels
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


    /// Spoken and shown recap of the edits made so far.
    func summarizeEdits(labels: [String]) {
        let french = language == .french
        let meaningful = labels.filter { !$0.isEmpty && $0 != "Select" }
        guard !meaningful.isEmpty else {
            let text = french ? "Tu n'as encore rien modifié." : "You haven't changed anything yet."
            showToast(text)
            speak(text, language: french ? "fr" : "en", force: true)
            return
        }
        var counts: [(String, Int)] = []
        for label in meaningful {
            if let index = counts.firstIndex(where: { $0.0 == label }) { counts[index].1 += 1 } else { counts.append((label, 1)) }
        }
        let parts = counts.suffix(8).map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }
        let list = parts.joined(separator: ", ")
        let text = french ? "\(meaningful.count) modification\(meaningful.count > 1 ? "s" : "") : \(list)." : "\(meaningful.count) edit\(meaningful.count > 1 ? "s" : ""): \(list)."
        showToast(text)
        speak(text, language: french ? "fr" : "en", force: true)
    }

    private func restoreVersion(_ state: VideoTimeline, label: String) {
        history.commit(state, label: label)
        player.load(timeline)
        showToast(label)
        Haptics.success()
    }

    /// Returns the label redone, nil when there was nothing to redo.
    @discardableResult
    public func redo() -> String? {
        guard history.canRedo else { return nil }
        isStepping = true
        let label = history.redo()
        isStepping = false
        Haptics.tick()
        if liveRunDepth == 0 { showToast(label.map { "\(L("Redo")) · \($0)" } ?? L("Redo")) }
        player.load(timeline)
        return label
    }

    /// Back to the timeline as this session opened it, as one undoable step. False when there was nothing to revert.
    @discardableResult
    public func revert() -> Bool {
        guard let original = history.past.first?.state, original != timeline else { return false }
        history.revertToOriginal()
        player.load(timeline)
        return true
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

    /// Imports a `.cube` look onto the selected clip.
    public func importLUT(from url: URL) {
        do {
            let reference = try LUTImporter.save(url, store: app.store, projectID: projectID)
            updateSelectedClip("LUT") { $0.lut = reference }
            Haptics.success()
            showToast(String(format: L("Look “%@” applied"), reference.title), undoable: true)
        } catch {
            showToast(L("That file is not a 3D .cube LUT."), isError: true)
        }
    }

    /// The selected clip's look on every clip, for a consistent grade.
    public func applyLUTToAllClips() {
        guard let reference = selectedClip?.lut else { return }
        update("LUT on every clip") { timeline in
            for index in timeline.clips.indices { timeline.clips[index].lut = reference }
        }
        Haptics.success()
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
            let placement = pendingSoundPlacement
            pendingSoundPlacement = (nil, false)
            let start = max(0, min(timeline.duration, placement.time ?? player.currentTime))
            let name = url.deletingPathExtension().lastPathComponent
            update(placement.replace ? L("Replace Music") : L("Add Sound Track")) { timeline in
                // Several tracks side by side, like lanes in an NLE: a voice-over or a
                // sound effect joins the music unless the user asked to replace it.
                let track = AudioTrack(asset: media, timelineStart: start, name: name)
                if placement.replace { timeline.audioTracks = [track] } else { timeline.audioTracks.append(track) }
            }
            Haptics.success()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Voice pipeline

    /// Runs a spoken or typed command, one step after another; the reply says what really happened.
    public func handleTranscript(_ text: String) async {
        transcript = text
        lastReplyIsProblem = false
        lastReplyIsError = false
        let plan = await app.router.plan(text, context: intentContext)
        lastPlan = plan
        if plan.isEmpty {
            Haptics.warning()
            let reply = plan.reply ?? L("I didn't catch that.")
            lastPlan?.reply = reply
            lastReplyIsProblem = true
            if !isQuiet {
                let suggestions = Replies.suggestions(for: .video, language: language)
                showToast(repliesInCapsule ? suggestions : reply + "\n" + suggestions, isError: true)
            }
            speak(reply, language: plan.language)
            return
        }
        speak(plan.reply ?? "", language: plan.language)
        isRunningVoiceCommand = true
        defer { isRunningVoiceCommand = false }
        var told: String?
        steps: for intent in plan.intents where intent.action != .unknown {
            switch await run(intent) {
            case .needsClarification(let request):
                lastPlan?.reply = request.question
                return
            case .failed(let message):
                told = message
                lastReplyIsProblem = true
                lastReplyIsError = true
                break steps
            case .info(let message):
                told = message
            case .applied, .ignored:
                continue
            }
        }
        if let told { lastPlan?.reply = told }
    }

    /// A command typed or dictated through Live's composer: its reply shows in Live's capsule.
    @ObservationIgnored var repliesInCapsule = false
    @ObservationIgnored private var isRunningVoiceCommand = false

    /// Live runs this step, or a Live conversation is on: Live says what happened, the editor stays quiet.
    var isQuiet: Bool { liveRunDepth > 0 || liveSpeechSuppressed }

    /// Spoken replies outside Live only.
    private func speak(_ text: String, language: String?, force: Bool = false) {
        guard !isQuiet, !text.isEmpty else { return }
        VoiceFeedback.shared.speak(text, language: language, force: force)
    }

    /// Drops the heavy step that is running, if any: its result is discarded when it
    /// arrives (the service may finish in the background), and the editor is free
    /// at once. True when something was running.
    @discardableResult
    public func cancelProcessing() -> Bool {
        guard isProcessing, processingTask != nil else { return false }
        droppedGenerations.insert(processingGeneration)
        processingTask = nil
        isProcessing = false
        processingProgress = nil
        Diagnostics.shared.note("processing cancelled")
        return true
    }

    @discardableResult
    public func run(_ intent: EditIntent) async -> CommandOutcome {
        lastEffects = []
        guard var executor else { return .failed(message: L("Still getting ready — try again in a moment.")) }
        executor.language = language
        let heavy: Set<IntentAction> = [.removeObject, .chooseCandidate, .stabilize, .reverse, .blurBackground, .removeBackground, .replaceBackground, .freezeFrame, .extractFrame,
                                        .autoCaptions, .translateCaptions, .removeSilences, .removeFillers, .cutWords, .autoDuck, .trackSubject, .splitScenes, .highlights, .punchIns, .syncToBeat, .fitMusic, .blurFaces, .smartReframe, .enhanceVoice, .matchColor, .kenBurns]
        // Analyses that finish without reporting a fraction show the pulsing glyph instead of 0 %.
        let indeterminate: Set<IntentAction> = [.removeSilences, .autoDuck, .syncToBeat, .fitMusic, .matchColor, .kenBurns]
        var generation: Int?
        if heavy.contains(intent.action) {
            // One long step at a time.
            guard !isProcessing else {
                let message = L("One moment…")
                if !isRunningVoiceCommand, !isQuiet { showToast(message) }
                return .info(message: message)
            }
            isProcessing = true
            processingProgress = indeterminate.contains(intent.action) ? nil : 0
            processingTitle = processingLabel(for: intent)
            processingGeneration += 1
            generation = processingGeneration
            player.pause()
        }
        // Only the step that raised the flag lowers it, unless it was dropped and another began.
        defer {
            if let generation, generation == processingGeneration, isProcessing {
                isProcessing = false
                processingProgress = nil
            }
        }
        let base = timeline
        let context = intentContext
        let updated: VideoTimeline
        let result: ExecutionResult
        if let generation {
            // Held in a task so cancelProcessing() can let go of it.
            let running = executor
            let task = Task { await running.execute(intent, on: base, context: context) }
            processingTask = task
            (updated, result) = await task.value
            if processingTask == task { processingTask = nil }
            if droppedGenerations.remove(generation) != nil {
                Diagnostics.shared.note("dropped result: \(intent.action)")
                return .failed(message: L("Cancelled."))
            }
        } else {
            (updated, result) = await executor.execute(intent, on: base, context: context)
        }
        return handle(result, updated: updated, intent: intent, base: base)
    }

    // MARK: - Edit by text

    /// Writes down what is said without showing captions, so the video can be edited by its words.
    public func transcribeForEditing() async {
        guard let services, !isProcessing else { return }
        player.pause()
        isProcessing = true
        processingTitle = L("Listening…")
        processingProgress = 0
        defer { isProcessing = false; processingProgress = nil }
        do {
            let (words, language) = try await services.transcribe(timeline: timeline) { [weak self] value in
                Task { @MainActor [weak self] in self?.processingProgress = value }
            }
            guard !words.isEmpty else {
                showToast(L("I can't hear any speech in this video."), isError: true)
                return
            }
            update(L("Transcript")) { timeline in
                timeline.captions = CaptionTrack(cues: CaptionBuilder.cues(from: words, style: .karaoke), style: .karaoke, isVisible: false, language: language)
            }
            Haptics.success()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    /// Cuts the transcript's words at these indices out of the video, with the pause after each.
    public func cutWords(at indices: Set<Int>) {
        guard let words = timeline.captions?.cues.flatMap(\.words), !indices.isEmpty else { return }
        let duration = timeline.duration
        let ranges = TranscriptEditor.ranges(removing: indices, from: words)
            .map { $0.clamped(to: TimeSpan(start: 0, end: duration)) }
            .filter { $0.duration > 0.02 }
        guard !ranges.isEmpty else { return }
        let removed = ranges.reduce(0) { $0 + $1.duration }
        let label = indices.count == 1 ? L("Cut 1 word") : String(format: L("Cut %d words"), indices.count)
        update(label) { $0.removeRanges(ranges) }
        showToast(String(format: L("%@ · −%.1f s"), label, removed), undoable: true)
        Haptics.success()
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
        case .autoCaptions: return L("Listening and writing captions…")
        case .translateCaptions: return L("Translating the captions…")
        case .removeSilences: return L("Finding the pauses…")
        case .removeFillers: return L("Listening for hesitations…")
        case .autoDuck: return L("Listening for the voice…")
        case .trackSubject: return L("Following the subject…")
        case .splitScenes: return L("Finding the shot changes…")
        case .highlights: return L("Watching for the best moments…")
        case .punchIns: return L("Framing the speaker…")
        case .cutWords: return L("Finding the words…")
        case .syncToBeat, .fitMusic: return L("Finding the beat…")
        case .blurFaces: return L("Finding the faces…")
        case .smartReframe: return L("Following the subject…")
        case .enhanceVoice: return L("Isolating the voice…")
        case .matchColor: return L("Matching colours…")
        default: return L("Working…")
        }
    }

    /// Lands an executor's result and returns what really happened: a long step whose
    /// timeline was changed meanwhile (an undo, a trim) is dropped rather than undoing that change.
    /// - Parameter base: the timeline the command started from.
    @discardableResult
    private func handle(_ result: ExecutionResult, updated: VideoTimeline, intent: EditIntent, base: VideoTimeline) -> CommandOutcome {
        lastEffects = result.effects
        switch result.outcome {
        case .applied(let label):
            pendingClarification = nil
            candidateOverlays = []
            if base != timeline, updated != base {
                Diagnostics.shared.note("stale result dropped: \(label)")
                let message = L("The video changed in the meantime. Try again.")
                if !isRunningVoiceCommand, !isQuiet { showToast(message, isError: true) }
                Haptics.warning()
                lastEffects = []
                return .failed(message: message)
            }
            if updated != timeline { commit(updated, label: label) }
            if !label.isEmpty, !isQuiet { showToast(LD(label), undoable: history.canUndo) }
            if !isQuiet { Haptics.success() }
        case .needsClarification(let request):
            pendingClarification = request
            candidateOverlays = request.candidates
            // Live asks the question itself (and shows the numbered choices).
            if !isQuiet {
                if !isRunningVoiceCommand { showToast(request.question) }
                speak(request.question, language: language.rawValue)
                Haptics.warning()
            }
        case .info(let message):
            if !isRunningVoiceCommand, !isQuiet { showToast(message) }
        case .failed(let message):
            if !isRunningVoiceCommand, !isQuiet { showToast(message, isError: true) }
            if !isQuiet { Haptics.error() }
        case .ignored:
            break
        }
        for effect in result.effects {
            switch effect {
            case .message(let message) where message.hasPrefix("version:"): handleVersionEffect(message)
            case .message("summary"): summarizeEdits(labels: history.past.map(\.label))
            case .undo: undo()
            case .redo: redo()
            case .revert: revert()
            case .play: player.play()
            case .pause: player.pause()
            case .seek(let time): Task { await player.seek(to: time) }
            case .export, .share: showsExport = true
            case .help: showsHelp = true
            case .pickMusic(_, let time, let replace):
                pendingSoundPlacement = (time, replace)
                showsMusicPicker = true
            case .selectClip(let id): selectedClipID = id
            case .compare:
                compareBeforeAfter(seconds: 1.5)
            case .cancel:
                pendingClarification = nil
                candidateOverlays = []
            default: break
            }
        }
        return result.outcome
    }

    /// Shows the untouched video for a moment, then the edit again.
    func compareBeforeAfter(seconds: Double) {
        compareTask?.cancel()
        showsOriginal = true
        compareTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.3, min(seconds, 10))))
            guard !Task.isCancelled else { return }
            self?.showsOriginal = false
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

    // MARK: - Sound tracks

    /// Opens the picker for a new track starting at the playhead.
    public func addSoundTrack(at time: Double? = nil) {
        pendingSoundPlacement = (time ?? player.currentTime, false)
        showsMusicPicker = true
    }

    public func setTrackVolume(_ id: UUID, _ volume: Double) {
        updateTrack(id, label: L("Track Volume")) { $0.volume = volume; if volume > 0 { $0.isMuted = false } }
    }

    public func toggleTrackMute(_ id: UUID) {
        updateTrack(id, label: L("Mute Track")) { $0.isMuted.toggle() }
    }

    public func removeTrack(_ id: UUID) {
        update(L("Remove Sound Track")) { $0.audioTracks.removeAll { $0.id == id } }
    }

    public func moveTrack(_ id: UUID, to time: Double) {
        updateTrack(id, label: L("Move Sound")) { $0.timelineStart = max(0, min(self.timeline.duration, time)) }
    }

    private func updateTrack(_ id: UUID, label: String, _ change: (inout AudioTrack) -> Void) {
        update(label) { timeline in
            guard let index = timeline.audioTracks.firstIndex(where: { $0.id == id }) else { return }
            change(&timeline.audioTracks[index])
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
extension VideoEditorSession: EditorStatus {
    /// Live says what is running while it converses: no blocking HUD then.
    var showsProcessingHUD: Bool { !live.isLive }
}
#endif
