import Foundation
import PicshopCore

/// Applies intents to a `VideoTimeline`.
public struct VideoCommandExecutor: Sendable {
    public let services: VideoAIServices
    public var language: NormalizedUtterance.Language
    /// Reports progress of long AI renders (0…1).
    public var progress: @Sendable (Double) -> Void

    public init(services: VideoAIServices, language: NormalizedUtterance.Language = .english, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.services = services
        self.language = language
        self.progress = progress
    }

    public func execute(_ intent: EditIntent, on input: VideoTimeline, context: IntentContext) async -> (VideoTimeline, ExecutionResult) {
        var timeline = input
        let playhead = context.playheadSeconds
        let fr = language == .french

        func targetClipIDs() -> [UUID] {
            if intent.scope == .all { return timeline.clips.map(\.id) }
            if let number = intent.clipIndex {
                let index = number == -1 ? timeline.clips.count - 1 : number - 1
                return index >= 0 && index < timeline.clips.count ? [timeline.clips[index].id] : []
            }
            if let selected = context.selectedIndex, selected >= 0, selected < timeline.clips.count, context.hasSelection {
                return [timeline.clips[selected].id]
            }
            if let clip = timeline.clip(at: playhead) { return [clip.id] }
            return timeline.clips.first.map { [$0.id] } ?? []
        }

        switch intent.action {
        case .split:
            let time = intent.time ?? playhead
            guard timeline.split(at: time) != nil else {
                return (timeline, .failed(fr ? "Impossible de couper ici." : "Can't split at this point."))
            }
            return (timeline, .applied("Split"))

        case .trim:
            guard let range = intent.timeRange else { return (timeline, .failed(fr ? "Indique une durée." : "Tell me the range to keep.")) }
            let duration = timeline.duration
            let keep = range.clamped(to: TimeSpan(start: 0, end: duration))
            guard keep.duration >= 0.1 else { return (timeline, .failed(fr ? "Durée trop courte." : "That range is too short.")) }
            if keep.end < duration { timeline.removeRange(TimeSpan(start: keep.end, end: duration)) }
            if keep.start > 0 { timeline.removeRange(TimeSpan(start: 0, end: keep.start)) }
            return (timeline, .applied("Trim"))

        case .deleteRange:
            guard let range = intent.timeRange else { return (timeline, .failed(fr ? "Indique le passage à supprimer." : "Tell me which part to delete.")) }
            let clamped = range.clamped(to: TimeSpan(start: 0, end: timeline.duration))
            guard clamped.duration > 0.05 else { return (timeline, .failed(fr ? "Passage introuvable." : "Nothing to delete there.")) }
            guard clamped.duration < timeline.duration - 0.05 else { return (timeline, .failed(fr ? "Cela supprimerait toute la vidéo." : "That would delete the whole video.")) }
            timeline.removeRange(clamped)
            return (timeline, .applied("Delete Section"))

        case .deleteClip:
            let ids = targetClipIDs()
            guard !ids.isEmpty else { return (timeline, .failed(fr ? "Clip introuvable." : "Clip not found.")) }
            guard ids.count < timeline.clips.count else { return (timeline, .failed(fr ? "Impossible de supprimer tous les clips." : "Can't delete every clip.")) }
            for id in ids { timeline.removeClip(id: id) }
            return (timeline, .applied(ids.count > 1 ? "Delete Clips" : "Delete Clip"))

        case .setSpeed:
            let speed = (intent.amount?.value ?? 2).clamped(to: 0.1...8)
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.speed = speed } }
            return (timeline, .applied("Speed ×\(Replies.formatted(speed))"))

        case .reverse:
            let ids = targetClipIDs()
            do {
                for id in ids {
                    guard let clip = timeline.clip(id: id) else { continue }
                    let rendered = try await services.reverse(clip: clip, timeline: timeline, progress: progress)
                    timeline.update(clipID: id) { clip in
                        clip.isReversed.toggle()
                        clip.processedAsset = rendered
                        clip.processedLabel = clip.isReversed ? "Reversed" : nil
                        clip.sourceRange = TimeSpan(start: 0, duration: rendered.duration)
                    }
                }
                return (timeline, .applied("Reverse"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .mute:
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.isMuted = true } }
            return (timeline, .applied("Mute"))

        case .unmute:
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.isMuted = false } }
            return (timeline, .applied("Unmute"))

        case .setVolume:
            if intent.scope == .selection, !timeline.audioTracks.isEmpty {
                for index in timeline.audioTracks.indices {
                    let current = timeline.audioTracks[index].volume
                    timeline.audioTracks[index].volume = (intent.amount ?? .relative(0.25)).resolve(current: current, range: 0...1)
                }
                return (timeline, .applied("Music Volume"))
            }
            for id in targetClipIDs() {
                timeline.update(clipID: id) { clip in
                    clip.volume = (intent.amount ?? .relative(0.25)).resolve(current: clip.volume, range: 0...2)
                    if clip.volume > 0 { clip.isMuted = false }
                }
            }
            return (timeline, .applied("Volume"))

        case .addTransition:
            let kind = intent.transition ?? .crossDissolve
            let duration = intent.time ?? 0.5
            let ids: [UUID]
            if intent.scope == .all {
                ids = timeline.clips.dropLast().map(\.id)
            } else if let clip = timeline.clip(at: playhead), let index = timeline.index(of: clip.id) {
                // Attach to the cut nearest the playhead.
                let starts = timeline.clipStartTimes
                let distanceToStart = abs(playhead - starts[index])
                let distanceToEnd = abs(starts[index] + clip.timelineDuration - playhead)
                if index > 0, distanceToStart < distanceToEnd { ids = [timeline.clips[index - 1].id] }
                else if index < timeline.clips.count - 1 { ids = [clip.id] }
                else if index > 0 { ids = [timeline.clips[index - 1].id] }
                else { ids = [] }
            } else {
                ids = []
            }
            guard !ids.isEmpty else { return (timeline, .failed(fr ? "Il faut au moins deux clips pour une transition. Dis « coupe ici » d'abord." : "You need two clips for a transition. Say “split here” first.")) }
            for id in ids { timeline.setTransition(Transition(kind: kind, duration: duration), afterClipID: id) }
            return (timeline, .applied("Transition: \(kind.displayName)"))

        case .removeTransition:
            let ids = intent.scope == .all ? timeline.clips.map(\.id) : targetClipIDs()
            for id in ids { timeline.setTransition(nil, afterClipID: id) }
            return (timeline, .applied("Remove Transition"))

        case .addMusic:
            return (timeline, .effect(.pickMusic(query: intent.text), label: ""))

        case .removeMusic:
            guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Pas de musique." : "There's no music track.")) }
            timeline.audioTracks.removeAll()
            return (timeline, .applied("Remove Music"))

        case .extractFrame:
            do {
                _ = try await services.extractFrame(at: intent.time ?? playhead, timeline: timeline)
                return (timeline, ExecutionResult(outcome: .info(message: fr ? "Image enregistrée dans Photos." : "Frame saved to Photos.")))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .freezeFrame:
            let time = intent.time ?? playhead
            let holdDuration = intent.amount?.value ?? 2
            do {
                let still = try await services.freezeFrame(at: time, duration: holdDuration, timeline: timeline)
                timeline.split(at: time)
                guard let index = timeline.clipIndex(at: time) else { return (timeline, .failed("No clip")) }
                let insertAt = abs(timeline.clipStartTimes[index] - time) < 0.01 ? index : index + 1
                let clip = VideoClip(asset: still, name: "Freeze")
                timeline.clips.insert(clip, at: min(insertAt, timeline.clips.count))
                timeline.touch()
                return (timeline, .applied("Freeze Frame"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .seek:
            return (timeline, .effect(.seek(intent.time ?? 0), label: ""))
        case .play: return (timeline, .effect(.play, label: ""))
        case .pause: return (timeline, .effect(.pause, label: ""))

        case .duplicateClip:
            guard let id = targetClipIDs().first else { return (timeline, .failed("No clip")) }
            timeline.duplicateClip(id: id)
            return (timeline, .applied("Duplicate Clip"))

        case .moveClip:
            guard let id = targetClipIDs().first else { return (timeline, .failed("No clip")) }
            let destination = intent.index ?? 1
            let resolved = destination == -1 ? timeline.clips.count - 1 : destination - 1
            timeline.moveClip(id: id, to: min(max(resolved, 0), timeline.clips.count - 1))
            return (timeline, .applied("Move Clip"))

        case .stabilize:
            let ids = targetClipIDs()
            do {
                for id in ids {
                    guard let clip = timeline.clip(id: id) else { continue }
                    let rendered = try await services.stabilize(clip: clip, timeline: timeline, progress: progress)
                    timeline.update(clipID: id) { $0.processedAsset = rendered; $0.processedLabel = "Stabilized"; $0.sourceRange = TimeSpan(start: 0, duration: rendered.duration) }
                }
                return (timeline, .applied("Stabilize"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .selectLayer:
            guard let index = intent.index else { return (timeline, .failed("No clip")) }
            let resolved = index == -1 ? timeline.clips.count - 1 : index - 1
            guard resolved >= 0, resolved < timeline.clips.count else { return (timeline, .failed(fr ? "Clip introuvable." : "Clip not found.")) }
            return (timeline, .effect(.selectClip(timeline.clips[resolved].id), label: "Select Clip"))

        case .removeObject:
            guard let target = intent.target else { return (timeline, .failed("No target")) }
            guard let clipID = targetClipIDs().first, let clip = timeline.clip(id: clipID) else { return (timeline, .failed("No clip")) }
            return await removeObject(target: target, intent: intent, clip: clip, timeline: timeline, playhead: playhead)

        case .chooseCandidate:
            guard let pending = context.pendingClarification, let target = pending.pendingIntent.target else { return (timeline, ExecutionResult(outcome: .ignored)) }
            let chosen: [ObjectCandidate]
            if intent.scope == .all { chosen = pending.candidates }
            else if let index = intent.index, index >= 1, index <= pending.candidates.count { chosen = [pending.candidates[index - 1]] }
            else if let refined = intent.target {
                switch CandidateSelector.select(from: pending.candidates, for: refined) {
                case .single(let c): chosen = [c]
                case .multiple(let list): chosen = list
                default: return (timeline, .clarify(pending))
                }
            } else { return (timeline, ExecutionResult(outcome: .ignored)) }
            guard let clipID = targetClipIDs().first, let clip = timeline.clip(id: clipID) else { return (timeline, .failed("No clip")) }
            return await render(candidates: chosen, target: target, clip: clip, timeline: timeline)

        case .adjust:
            guard let parameter = intent.parameter else { return (timeline, .failed("Unknown adjustment")) }
            for id in targetClipIDs() {
                timeline.update(clipID: id) { clip in
                    let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: clip.adjustments[parameter], range: parameter.range)
                    clip.adjustments[parameter] = value
                }
            }
            return (timeline, .applied(parameter.englishName))

        case .applyLook:
            guard let look = intent.look else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Quel filtre ?" : "Which look?"))) }
            let ids = intent.scope == .all ? timeline.clips.map(\.id) : targetClipIDs()
            for id in ids { timeline.update(clipID: id) { $0.look = look; $0.lookIntensity = (intent.amount?.value ?? 1).clamped(to: 0...1) } }
            return (timeline, .applied(look.englishName))

        case .autoEnhance:
            let strength = (intent.amount ?? .absolute(0.8)).value.clamped(to: 0...1)
            let boost = Adjustments([.exposure: 0.06, .contrast: 0.1, .vibrance: 0.18, .shadows: 0.1, .highlights: -0.08]).scaled(by: strength)
            for id in timeline.clips.map(\.id) { timeline.update(clipID: id) { $0.adjustments = $0.adjustments.combined(with: boost) } }
            return (timeline, .applied("Auto Enhance"))

        case .crop, .setAspect:
            let aspect = intent.aspect ?? .free
            if aspect == .free { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Choisis un format." : "Pick an aspect ratio."))) }
            timeline.setAspect(aspect)
            return (timeline, .applied("Aspect \(aspect.displayName)"))

        case .rotate:
            let degrees = intent.degrees ?? 90
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.rotation = ($0.rotation + degrees).truncatingRemainder(dividingBy: 360) } }
            return (timeline, .applied("Rotate \(Int(degrees))°"))

        case .flip:
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.flipHorizontal.toggle() } }
            return (timeline, .applied("Flip"))

        case .addText:
            guard let text = intent.text, !text.isEmpty else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Quel texte ?" : "What should it say?"))) }
            var element = TextElement(text: text)
            element.center = (intent.placement ?? .bottom).center
            if let color = intent.color { element.color = color }
            if let amount = intent.amount, amount.mode == .absolute { element.relativeSize = amount.value }
            let span = intent.timeRange ?? TimeSpan(start: playhead, duration: min(3, max(0.5, timeline.duration - playhead)))
            timeline.addOverlay(TimelineOverlay(content: .text(element), span: span))
            return (timeline, .applied("Add Text"))

        case .editText:
            guard let index = timeline.overlays.lastIndex(where: { $0.textElement != nil }) else { return (timeline, .failed(fr ? "Aucun texte." : "No text to edit.")) }
            if case .text(var element) = timeline.overlays[index].content {
                if let text = intent.text { element.text = text }
                if let placement = intent.placement { element.center = placement.center }
                if let color = intent.color { element.color = color }
                if let amount = intent.amount, amount.mode == .multiplier { element.relativeSize = (element.relativeSize * amount.value).clamped(to: 0.02...0.3) }
                timeline.overlays[index].content = .text(element)
                timeline.touch()
            }
            return (timeline, .applied("Edit Text"))

        case .removeText:
            guard let overlay = timeline.overlays.last(where: { $0.textElement != nil }) else { return (timeline, .failed(fr ? "Aucun texte." : "No text to remove.")) }
            timeline.removeOverlay(id: overlay.id)
            return (timeline, .applied("Remove Text"))

        case .blurBackground, .removeBackground, .replaceBackground:
            guard let clipID = targetClipIDs().first, let clip = timeline.clip(id: clipID) else { return (timeline, .failed("No clip")) }
            do {
                let matte = try await services.subjectMatte(for: clip, timeline: timeline, progress: progress)
                timeline.update(clipID: clipID) { $0.processedAsset = matte; $0.processedLabel = intent.action == .blurBackground ? "Portrait" : "Cutout"; $0.sourceRange = TimeSpan(start: 0, duration: matte.duration) }
                return (timeline, .applied(intent.action == .blurBackground ? "Blur Background" : "Background"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .undo: return (timeline, .effect(.undo, label: ""))
        case .redo: return (timeline, .effect(.redo, label: ""))
        case .revert: return (timeline, .effect(.revert, label: ""))
        case .compare: return (timeline, .effect(.compare, label: ""))
        case .zoom: return (timeline, .effect(.zoom(intent.amount, intent.target), label: ""))
        case .export: return (timeline, .effect(.export, label: ""))
        case .share: return (timeline, .effect(.share, label: ""))
        case .help: return (timeline, .effect(.help, label: ""))
        case .confirm: return (timeline, .effect(.confirm, label: ""))
        case .cancel: return (timeline, .effect(.cancel, label: ""))
        case .saveVersion: return (timeline, .effect(.message("version:save:" + (intent.text ?? "")), label: ""))
        case .summarizeEdits: return (timeline, .effect(.message("summary"), label: ""))
        case .restoreVersion: return (timeline, .effect(.message("version:restore:" + (intent.text ?? "")), label: ""))
        case .unknown: return (timeline, ExecutionResult(outcome: .info(message: Replies.reply(for: intent, language: language))))
        default: return (timeline, .failed(PicshopError.unsupportedOperation(intent.summary).message))
        }
    }

    func removeObject(target: ObjectTarget, intent: EditIntent, clip: VideoClip, timeline: VideoTimeline, playhead: Double) async -> (VideoTimeline, ExecutionResult) {
        do {
            let span = timeline.span(of: clip.id) ?? TimeSpan(start: 0, duration: 0)
            let time = span.contains(playhead) ? playhead : span.start
            let candidates = try await services.candidates(for: target, in: clip, timeline: timeline, at: time)
            switch CandidateSelector.select(from: candidates, for: target) {
            case .single(let candidate): return await render(candidates: [candidate], target: target, clip: clip, timeline: timeline)
            case .multiple(let list): return await render(candidates: list, target: target, clip: clip, timeline: timeline)
            case .ambiguous(let options):
                return (timeline, .clarify(ClarificationRequest(question: CandidateSelector.question(for: target, options: options, language: language), candidates: options, pendingIntent: intent)))
            case .none:
                return (timeline, .failed(PicshopError.objectNotFound(target.originalPhrase).message))
            }
        } catch {
            return (timeline, .failed(errorMessage(error)))
        }
    }

    func render(candidates: [ObjectCandidate], target: ObjectTarget, clip: VideoClip, timeline input: VideoTimeline) async -> (VideoTimeline, ExecutionResult) {
        var timeline = input
        do {
            let rendered = try await services.removeObject(candidates: candidates, target: target, from: clip, timeline: timeline, progress: progress)
            timeline.update(clipID: clip.id) { $0.processedAsset = rendered; $0.processedLabel = "Removed \(target.originalPhrase)"; $0.sourceRange = TimeSpan(start: 0, duration: rendered.duration) }
            return (timeline, .applied("Remove \(target.originalPhrase)"))
        } catch {
            return (timeline, .failed(errorMessage(error)))
        }
    }

    func errorMessage(_ error: Error) -> String {
        if let known = error as? PicshopError { return known.message }
        return error.localizedDescription
    }
}

public extension VideoTimeline {
    func clip(id: UUID) -> VideoClip? { clips.first { $0.id == id } }
}
