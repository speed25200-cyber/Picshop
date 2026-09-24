#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import Foundation
import CoreGraphics
import PicshopCore
import PicshopIntent
import PicshopImaging
import PicshopVideo

/// What Picshop Live reaches in the video editor, and the only way it reaches it.
/// Every step goes through the editor's own executor and history.
extension VideoEditorSession: LiveEditingHost {
    public var liveMode: EditorMode { .video }

    public var liveVersion: Int { revision }

    public var liveIsBusy: Bool { isProcessing }

    public var liveProcessingProgress: Double? { isProcessing ? processingProgress : nil }

    /// The pending question and its numbered candidates, as Live shows and speaks them.
    public var livePendingChoice: LiveChoiceRequest? {
        guard let request = pendingClarification, !request.candidates.isEmpty else { return nil }
        let candidates = request.candidates.enumerated().map { LiveChoiceRequest.Candidate(id: $0.offset + 1, label: $0.element.spokenDescription) }
        return LiveChoiceRequest(question: request.question, candidates: candidates, allowsAll: candidates.count > 1)
    }

    public func liveIntentContext() -> IntentContext { intentContext }

    public func liveContextSummary() -> LiveEditorState {
        var state = LiveEditorState(mode: .video, version: revision)
        let timeline = self.timeline
        state.canvasPixels = timeline.renderSize
        state.appliedEdits = Array(undoLabels.filter { $0 != "Select" }.suffix(12))
        if let clip = selectedClip { state.adjustments = clip.adjustments }
        let playhead = player.currentTime
        if let index = selectedClipIndex { state.selection = "clip \(index + 1)" }
        if let request = pendingClarification {
            state.pendingQuestion = request.question
            state.candidates = request.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" }
        }
        state.video = VideoFacts(duration: timeline.duration, playhead: playhead, clipDurations: timeline.clips.map(\.timelineDuration),
                                 currentClip: clipIndex(at: playhead), musicTracks: timeline.audioTracks.count,
                                 hasCaptions: timeline.captions?.isEmpty == false, isVertical: timeline.renderSize.height > timeline.renderSize.width)
        state.mediaText = Self.mediaText(in: timeline, around: playhead)
        state.canUndo = canUndo
        state.busyTitle = isProcessing && !processingTitle.isEmpty ? processingTitle : nil
        return state
    }

    /// What is said within 10 s of the playhead (captions or the transcript, 400
    /// characters at most), then the text overlays.
    static func mediaText(in timeline: VideoTimeline, around playhead: Double) -> [String] {
        var texts: [String] = []
        if let captions = timeline.captions {
            let window = TimeSpan(start: max(0, playhead - 10), end: playhead + 10)
            let near = captions.cues.filter { $0.span.end >= window.start && $0.span.start <= window.end }
            var spoken = near.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.count > 400 { spoken = String(spoken.prefix(399)) + "…" }
            if !spoken.isEmpty { texts.append(spoken) }
        }
        texts += timeline.overlays.compactMap { $0.textElement?.text }.filter { !$0.isEmpty }
        return texts
    }

    /// The editor's own run(_:), once a step already running has finished (100 ms
    /// polls, 20 s at most), with no toast and no speech: Live tells it.
    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        var waited = 0.0
        while isProcessing, waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        liveRunDepth += 1
        defer { liveRunDepth -= 1 }
        let outcome = await run(intent)
        return LiveRunResult(outcome: outcome, effects: lastEffects)
    }

    public func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        liveRunDepth += 1
        defer { liveRunDepth -= 1 }
        if toOriginal {
            return revert() ? [undoLabels.last ?? "Revert to Original"] : []
        }
        if redo {
            var labels: [String] = []
            for _ in 0..<max(1, count) {
                guard let label = self.redo() else { break }
                labels.append(label)
            }
            return labels
        }
        return undo(steps: max(1, count))
    }

    public func liveCompareBeforeAfter(seconds: Double) {
        compareBeforeAfter(seconds: seconds)
    }

    /// The frame at the playhead, as the timeline plays it, encoded off the main
    /// thread; one per clip and revision (clip<n>@<revision>).
    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? {
        let playhead = player.currentTime
        let version = revision
        let key = "clip\(clipIndex(at: playhead) ?? 0)@\(version)"
        if let cached = snapshotCache, cached.key == key,
           max(cached.image.pixelWidth, cached.image.pixelHeight) <= maxPixel { return cached.image }
        guard let frame = await player.frame(at: playhead, maxPixel: maxPixel) else { return nil }
        let encoded = await Task.detached(priority: .userInitiated) { LiveMediaEncoder.jpeg(from: frame, maxPixel: maxPixel) }.value
        guard let encoded else { return nil }
        let snapshot = LiveImage(jpeg: encoded.data, pixelWidth: encoded.width, pixelHeight: encoded.height, version: version, frameKey: key)
        snapshotCache = (key, snapshot)
        return snapshot
    }

    /// The local pipeline (outside Live): its reply goes to Live's capsule.
    public func liveHandleCommand(_ text: String) async -> LiveCommandReply {
        if isProcessing {
            return LiveCommandReply(text: L("One moment…"), isProblem: true, isError: false, language: language.rawValue)
        }
        repliesInCapsule = true
        defer { repliesInCapsule = false }
        await handleTranscript(text)
        return LiveCommandReply(text: lastPlan?.reply ?? "", isProblem: lastReplyIsProblem, isError: lastReplyIsError,
                                language: lastPlan?.language ?? language.rawValue)
    }

    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult {
        switch choice {
        case .index(let number): return await liveRun(EditIntent(action: .chooseCandidate, index: number))
        case .all: return await liveRun(EditIntent(action: .chooseCandidate, scope: .all))
        }
    }

    @discardableResult
    public func liveCancelProcessing() -> Bool {
        cancelProcessing()
    }

    public func livePausePlayback() {
        player.pause()
    }

    public var liveIsPlaying: Bool { player.isPlaying }
}
#endif
