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

        /// Sound tracks a command addresses: "the second track", "the last one",
        /// otherwise every track. `clipIndex` doubles as the track number here.
        func targetTrackIndices() -> [Int] {
            let count = timeline.audioTracks.count
            guard count > 0 else { return [] }
            if let number = intent.clipIndex {
                let index = number == -1 ? count - 1 : number - 1
                return index >= 0 && index < count ? [index] : []
            }
            return Array(timeline.audioTracks.indices)
        }

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
            if intent.scope == .selection {
                guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Pas de piste son." : "There's no sound track.")) }
                for index in targetTrackIndices() { timeline.audioTracks[index].isMuted = true }
                return (timeline, .applied("Mute Sound"))
            }
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.isMuted = true } }
            return (timeline, .applied("Mute"))

        case .unmute:
            if intent.scope == .selection {
                for index in targetTrackIndices() { timeline.audioTracks[index].isMuted = false }
                return (timeline, .applied("Unmute Sound"))
            }
            for id in targetClipIDs() { timeline.update(clipID: id) { $0.isMuted = false } }
            return (timeline, .applied("Unmute"))

        case .setVolume:
            if intent.scope == .selection, !timeline.audioTracks.isEmpty {
                for index in targetTrackIndices() {
                    let current = timeline.audioTracks[index].volume
                    timeline.audioTracks[index].volume = (intent.amount ?? .relative(0.25)).resolve(current: current, range: 0...1)
                    if timeline.audioTracks[index].volume > 0 { timeline.audioTracks[index].isMuted = false }
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
            // A second (third…) track is the default, like laying a sound effect or a
            // voice-over under the music in a real NLE; "replace the music" swaps.
            return (timeline, .effect(.pickMusic(query: intent.text, at: intent.time, replace: intent.scope == .selection), label: ""))

        case .removeMusic:
            guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Pas de piste son." : "There's no sound track.")) }
            if intent.clipIndex != nil {
                let indices = targetTrackIndices()
                guard !indices.isEmpty else { return (timeline, .failed(fr ? "Cette piste n'existe pas." : "There's no such track.")) }
                for index in indices.sorted(by: >) { timeline.audioTracks.remove(at: index) }
                return (timeline, .applied("Remove Sound Track"))
            }
            timeline.audioTracks.removeAll()
            return (timeline, .applied("Remove Music"))

        case .moveAudio:
            guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Pas de piste son." : "There's no sound track.")) }
            let destination = max(0, min(timeline.duration, intent.time ?? playhead))
            for index in targetTrackIndices() { timeline.audioTracks[index].timelineStart = destination }
            return (timeline, .applied("Move Sound"))

        case .fadeAudio:
            guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Pas de piste son." : "There's no sound track.")) }
            let seconds = max(0, intent.amount?.value ?? 1.5)
            let which = intent.text?.lowercased() ?? ""
            for index in targetTrackIndices() {
                if which != "out" { timeline.audioTracks[index].fadeIn = seconds }
                if which != "in" { timeline.audioTracks[index].fadeOut = seconds }
            }
            return (timeline, .applied("Fade Sound"))

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
            var title = TimelineOverlay(content: .text(element), span: span)
            // Titles arrive with a move, as a motion designer would set them.
            title.animation = .rise
            timeline.addOverlay(title)
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

        case .animateText:
            let index: Int?
            if let id = intent.target.flatMap({ UUID(uuidString: $0.originalPhrase) }) {
                index = timeline.overlays.firstIndex { $0.id == id }
            } else {
                index = timeline.overlays.lastIndex { $0.textElement != nil && $0.span.contains(playhead) } ?? timeline.overlays.lastIndex { $0.textElement != nil }
            }
            guard let index else { return (timeline, .failed(fr ? "Ajoute d'abord un texte." : "Add a title first.")) }
            let animation = intent.text.flatMap(TextAnimation.init(rawValue:))
            timeline.overlays[index].animation = animation
            timeline.touch()
            guard let animation else { return (timeline, .applied(fr ? "Sans animation" : "No animation")) }
            return (timeline, .applied(fr ? "Animation : \(animation.frenchName)" : "Animation: \(animation.displayName)"))

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

        case .autoCaptions:
            let style = intent.text.flatMap(CaptionStyle.init(rawValue:)) ?? intent.text.flatMap(CaptionStyle.matching)
            if var existing = timeline.captions, !existing.isEmpty {
                // Captions already exist: the request changes their look, or shows them again.
                existing.isVisible = true
                if let style { existing.restyle(style) }
                timeline.captions = existing
                timeline.touch()
                return (timeline, .applied(style.map { "Captions: \($0.displayName)" } ?? "Show Captions"))
            }
            do {
                let (words, language) = try await services.transcribe(timeline: timeline, progress: progress)
                guard !words.isEmpty else { return (timeline, .failed(fr ? "Je n'entends aucune parole dans cette vidéo." : "I can't hear any speech in this video.")) }
                let chosen = style ?? .karaoke
                timeline.captions = CaptionTrack(cues: CaptionBuilder.cues(from: words, style: chosen), style: chosen, language: language)
                timeline.touch()
                return (timeline, .applied("Captions"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .removeCaptions:
            guard timeline.captions != nil else { return (timeline, .failed(fr ? "Il n'y a pas de sous-titres." : "There are no captions.")) }
            timeline.captions = nil
            timeline.touch()
            return (timeline, .applied("Remove Captions"))

        case .removeSilences:
            do {
                let signal = try await services.dialogueSignal(timeline: timeline)
                let sensitivity = intent.amount?.value ?? 0.3
                let ranges = SilenceDetector(minimumSilence: sensitivity > 0.4 ? 0.35 : 0.5, sensitivity: sensitivity).silentRanges(in: signal)
                    .map { $0.clamped(to: TimeSpan(start: 0, end: timeline.duration)) }
                    .filter { $0.duration > 0.1 }
                guard !ranges.isEmpty else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Aucun blanc à couper." : "No pauses to cut."))) }
                let removed = ranges.reduce(0) { $0 + $1.duration }
                guard removed < timeline.duration - 0.5 else { return (timeline, .failed(fr ? "Je n'entends presque pas de voix." : "I can barely hear any voice.")) }
                timeline.removeRanges(ranges)
                let seconds = Replies.formatted((removed * 10).rounded() / 10)
                return (timeline, .applied(fr ? "\(ranges.count) blancs coupés (−\(seconds) s)" : "\(ranges.count) pauses cut (−\(seconds) s)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .removeFillers:
            do {
                let words = try await spokenWords(in: &timeline)
                guard !words.isEmpty else { return (timeline, .failed(fr ? "Je n'entends aucune parole dans cette vidéo." : "I can't hear any speech in this video.")) }
                // The sound between words finds the "euh"s the recogniser chose not to write.
                let signal = try? await services.dialogueSignal(timeline: timeline)
                let fillers = TranscriptEditor.fillers(in: words, envelope: signal.map { LoudnessEnvelope.measure($0) })
                let ranges = TranscriptEditor.ranges(removing: fillers, from: words)
                    .map { $0.clamped(to: TimeSpan(start: 0, end: timeline.duration)) }
                    .filter { $0.duration > 0.02 }
                guard !ranges.isEmpty else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Aucune hésitation à couper." : "No filler words to cut."))) }
                let removed = ranges.reduce(0) { $0 + $1.duration }
                timeline.removeRanges(ranges)
                let seconds = Replies.formatted((removed * 10).rounded() / 10)
                return (timeline, .applied(fr ? "\(fillers.count) hésitations coupées (−\(seconds) s)" : "\(fillers.count) fillers cut (−\(seconds) s)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .speedRamp:
            let center = (intent.time ?? playhead).clamped(to: 0...max(0, timeline.duration))
            guard let clip = timeline.clip(at: center), let span = timeline.span(of: clip.id) else { return (timeline, .failed(fr ? "Il n'y a pas de clip ici." : "There is no clip here.")) }
            let slowest = (intent.amount?.value ?? 0.3).clamped(to: 0.1...0.9)
            // Three steps — ease in, the slow heart, ease out — kept inside the clip.
            let reach = min(0.8, (center - span.start) - 0.1, (span.end - center) - 0.1)
            guard reach >= 0.3 else { return (timeline, .failed(fr ? "Place la tête de lecture plus loin des bords du clip." : "Move the playhead further from the clip's ends.")) }
            let bounds = [center - reach, center - reach / 2, center + reach / 2, center + reach]
            let factors = [(slowest + 1) / 2, slowest, (slowest + 1) / 2]
            for time in bounds.reversed() { timeline.split(at: time) }
            // The pieces are found before any is slowed: slowing one moves the ones after it.
            let pieces = (0..<factors.count).compactMap { timeline.clip(at: (bounds[$0] + bounds[$0 + 1]) / 2)?.id }
            for (id, factor) in zip(pieces, factors) {
                timeline.update(clipID: id) { $0.speed = ($0.speed * factor).clamped(to: 0.1...8) }
            }
            return (timeline, .applied(fr ? "Ralenti progressif (×\(Replies.formatted(slowest)))" : "Speed ramp (×\(Replies.formatted(slowest)))"))

        case .highlights:
            let target = (intent.amount?.value ?? 30).clamped(to: 5...600)
            guard timeline.duration > target + 2 else {
                return (timeline, ExecutionResult(outcome: .info(message: fr ? "La vidéo dure déjà moins de \(Int(target)) s." : "The video is already under \(Int(target)) s.")))
            }
            do {
                var clips: [HighlightPlanner.Clip] = []
                let count = Double(timeline.clips.count)
                for (number, clip) in timeline.clips.enumerated() {
                    let scores = try await services.momentScores(for: clip, timeline: timeline) { fraction in
                        progress((Double(number) + fraction * 0.8) / count)
                    }
                    let cuts = (try? await services.sceneCuts(for: clip, timeline: timeline, sensitivity: 0.5) { _ in }) ?? []
                    clips.append(HighlightPlanner.Clip(duration: clip.timelineDuration, moments: scores, cuts: cuts))
                }
                let picks = HighlightPlanner.pick(clips: clips, target: target)
                guard !picks.isEmpty else { return (timeline, .failed(fr ? "Je ne trouve pas de moment fort." : "I can't find any highlight.")) }
                // Each pick becomes a shot taken from its clip, joined by short dissolves.
                let shots: [VideoClip] = picks.map { pick in
                    var shot = timeline.clips[pick.clipIndex]
                    let a = shot.sourceTime(forClipOffset: pick.span.start), b = shot.sourceTime(forClipOffset: pick.span.end)
                    shot.id = UUID()
                    shot.sourceRange = TimeSpan(start: min(a, b), end: max(a, b))
                    shot.transitionOut = Transition(kind: .crossDissolve, duration: 0.3)
                    shot.motion = nil
                    return shot
                }
                var recap = shots
                recap[recap.count - 1].transitionOut = nil
                timeline.clips = recap
                timeline.captions = nil
                timeline.touch()
                let seconds = Int(timeline.duration.rounded())
                return (timeline, .applied(fr ? "Résumé de \(seconds) s : \(shots.count) moments forts" : "\(seconds) s recap: \(shots.count) highlights"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .splitScenes:
            let ids = intent.scope == .all || context.selectedIndex == nil ? timeline.clips.map(\.id) : targetClipIDs()
            guard !ids.isEmpty else { return (timeline, .failed(fr ? "Il n'y a pas de clip." : "There is no clip.")) }
            do {
                var cutTimes: [Double] = []
                for (number, id) in ids.enumerated() {
                    guard let clip = timeline.clips.first(where: { $0.id == id }), let span = timeline.span(of: id) else { continue }
                    let offsets = try await services.sceneCuts(for: clip, timeline: timeline, sensitivity: intent.amount?.value ?? 0.5) { fraction in
                        progress((Double(number) + fraction) / Double(ids.count))
                    }
                    cutTimes += offsets.filter { $0 > 0.2 && $0 < span.duration - 0.2 }.map { span.start + $0 }
                }
                guard !cutTimes.isEmpty else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Un seul plan : rien à découper." : "One continuous shot: nothing to split."))) }
                var made = 0
                for time in cutTimes.sorted(by: >) where timeline.split(at: time) != nil { made += 1 }
                return (timeline, .applied(fr ? "\(made + 1) plans détectés" : "\(made + 1) shots found"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .trackSubject:
            // The overlay: named by id (from the panel), else the kind asked for under the playhead, else the latest.
            var chosen: TimelineOverlay?
            if let text = intent.text, let id = UUID(uuidString: text) { chosen = timeline.overlays.first { $0.id == id } }
            if chosen == nil {
                let pool = timeline.overlays.filter { overlay in
                    switch (intent.target?.label, overlay.content) {
                    case ("text", .text), ("shape", .shape), ("image", .image), ("image", .video), ("video", .video), (nil, _): return true
                    default: return false
                    }
                }
                chosen = pool.last { $0.span.contains(playhead) } ?? pool.last
            }
            guard let overlay = chosen, let index = timeline.overlays.firstIndex(where: { $0.id == overlay.id }) else {
                return (timeline, .failed(fr ? "Ajoute d'abord un texte ou une image à faire suivre." : "Add a text or a picture to follow first."))
            }
            if let amount = intent.amount?.value, amount <= 0.01 {
                guard overlay.tracking != nil else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "Ce calque ne suit rien." : "That overlay isn't following anything."))) }
                timeline.overlays[index].tracking = nil
                return (timeline, .applied(fr ? "Ne suit plus le sujet" : "Stopped following"))
            }
            let anchor = overlay.span.contains(playhead) ? playhead : overlay.span.start
            do {
                let samples = try await services.track(point: overlay.anchorPoint, at: anchor, within: overlay.span, timeline: timeline, progress: progress)
                guard samples.count >= 2, let first = samples.first, let last = samples.last else {
                    return (timeline, .failed(fr ? "Je ne trouve rien à suivre sous ce calque." : "I can't find anything to follow under that overlay."))
                }
                timeline.overlays[index].tracking = TrackingPath(samples: TrackingPath.smoothed(samples), anchorTime: anchor)
                let seconds = Replies.formatted(((last.time - first.time) * 10).rounded() / 10)
                return (timeline, .applied(fr ? "Le calque suit le sujet (\(seconds) s)" : "The overlay follows the subject (\(seconds) s)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .autoDuck:
            guard !timeline.audioTracks.isEmpty else { return (timeline, .failed(fr ? "Ajoute d'abord une musique." : "Add some music first.")) }
            if let amount = intent.amount?.value, amount <= 0.01 {
                timeline.setSpeech(nil)
                return (timeline, .applied(fr ? "Ducking désactivé" : "Ducking off"))
            }
            do {
                // The words say exactly where someone speaks; without them, the sound does.
                let speech: [TimeSpan]
                if let captions = timeline.captions, !captions.isEmpty {
                    speech = captions.cues.flatMap(\.words).map { TimeSpan(start: $0.start, end: $0.end) }
                } else {
                    let signal = try await services.dialogueSignal(timeline: timeline)
                    guard let found = Ducking.speech(in: LoudnessEnvelope.measure(signal), duration: timeline.duration) else {
                        return (timeline, .failed(fr ? "Je n'entends pas de voix sous la musique." : "I can't hear any voice to duck under."))
                    }
                    speech = found
                }
                let depth = (intent.amount?.value ?? 0.7).clamped(to: 0.2...0.95)
                timeline.setSpeech(speech)
                for index in timeline.audioTracks.indices { timeline.audioTracks[index].ducking = depth }
                let passages = Ducking.regions(from: speech).count
                return (timeline, .applied(fr ? "La musique s'efface sous la voix (\(passages) passages)" : "Music ducks under the voice (\(passages) passages)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .cutWords:
            let phrase = (intent.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !phrase.isEmpty else { return (timeline, .failed(fr ? "Quels mots dois-je couper ?" : "Which words should I cut?")) }
            do {
                let words = try await spokenWords(in: &timeline)
                guard !words.isEmpty else { return (timeline, .failed(fr ? "Je n'entends aucune parole dans cette vidéo." : "I can't hear any speech in this video.")) }
                var found = TranscriptEditor.occurrences(of: phrase, in: words)
                guard !found.isEmpty else { return (timeline, .failed(fr ? "Je n'entends pas « \(phrase) » dans la vidéo." : "I don't hear “\(phrase)” in the video.")) }
                if intent.scope != .all {
                    // The one nearest the playhead: scrub to it, then say what to cut.
                    let nearest = found.min { abs(words[$0.lowerBound].start - playhead) < abs(words[$1.lowerBound].start - playhead) }!
                    found = [nearest]
                }
                if intent.target?.label == "sentence" {
                    found = found.map { TranscriptEditor.sentence(containing: $0.lowerBound, in: words).lowerBound...TranscriptEditor.sentence(containing: $0.upperBound, in: words).upperBound }
                }
                let indices = Set(found.flatMap { Array($0) })
                let ranges = TranscriptEditor.ranges(removing: indices, from: words)
                    .map { $0.clamped(to: TimeSpan(start: 0, end: timeline.duration)) }
                    .filter { $0.duration > 0.02 }
                guard !ranges.isEmpty else { return (timeline, .failed(fr ? "Rien à couper." : "Nothing to cut.")) }
                timeline.removeRanges(ranges)
                // Quoted as they were said (capitals, accents), not as they were typed.
                let said = found[0].map { words[$0].text }.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                let quoted = fr ? "« \(said) »" : "“\(said)”"
                if found.count > 1 { return (timeline, .applied(fr ? "\(quoted) coupé \(found.count) fois" : "Cut \(quoted) \(found.count) times")) }
                return (timeline, .applied(fr ? "\(quoted) coupé" : "Cut \(quoted)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .syncToBeat:
            guard timeline.clips.count > 1 || timeline.audioTracks.isEmpty == false else {
                return (timeline, .failed(fr ? "Ajoute d'abord une musique." : "Add some music first."))
            }
            guard let track = timeline.audioTracks.first(where: { !$0.isMuted }) else {
                return (timeline, .failed(fr ? "Ajoute d'abord une musique." : "Add some music first."))
            }
            do {
                let grid: BeatGrid
                if let cached = timeline.beatGrid { grid = cached } else {
                    let signal = try await services.musicSignal(track: track)
                    guard let analysed = BeatTracker().analyze(signal) else { return (timeline, .failed(fr ? "Je ne trouve pas le rythme de cette musique." : "I can't find the beat in this music.")) }
                    grid = analysed
                }
                timeline.beatGrid = grid
                if timeline.clips.count < 2 {
                    // A single clip: cut it on every bar so the rhythm shows.
                    let bars = stride(from: grid.downbeatOffset + 4, to: grid.beats.count, by: 4).map { track.timelineStart + grid.beats[$0] - track.sourceRange.start }
                    for time in bars.reversed() where time > 0.3 && time < timeline.duration - 0.3 { timeline.split(at: time) }
                }
                let beats = BeatSync.timelineBeats(grid, track: track)
                let (snapped, moved) = BeatSync.snap(timeline, to: beats)
                timeline = snapped
                return (timeline, .applied(fr ? "Coupes sur le rythme (\(Int(grid.bpm.rounded())) BPM, \(moved))" : "Cuts on the beat (\(Int(grid.bpm.rounded())) BPM, \(moved))"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .smartReframe:
            let aspect = intent.aspect ?? .ratio9x16
            guard let outputAspect = aspect.value else { return (timeline, .failed(fr ? "Choisis un format." : "Pick an aspect ratio.")) }
            let ids = intent.scope == .current && context.hasSelection ? targetClipIDs() : timeline.clips.map(\.id)
            do {
                timeline.setAspect(aspect)
                for id in ids {
                    guard let clip = timeline.clip(id: id) else { continue }
                    let size = clip.renderAsset.pixelSize
                    let rotated = Int(clip.rotation.rounded()) % 180 != 0
                    let sourceAspect = size.isEmpty ? 16.0 / 9.0 : (rotated ? size.height / size.width : size.aspectRatio)
                    let samples = try await services.focusSamples(for: clip, timeline: timeline, progress: progress)
                    let path = SmartReframe().path(samples: samples, duration: clip.timelineDuration, sourceAspect: sourceAspect, outputAspect: outputAspect)
                    timeline.update(clipID: id) { $0.motion = path }
                }
                return (timeline, .applied("Smart Reframe \(aspect.displayName)"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .kenBurns:
            let ids = intent.scope == .all ? timeline.clips.map(\.id) : targetClipIDs()
            let off = intent.amount?.value == 0
            for (offset, id) in ids.enumerated() {
                let variant = timeline.index(of: id) ?? offset
                timeline.update(clipID: id) { clip in
                    clip.motion = off ? nil : ClipMotion.kenBurns(duration: clip.timelineDuration, variant: variant)
                }
            }
            return (timeline, .applied(off ? "Remove Camera Move" : "Ken Burns"))

        case .enhanceVoice:
            let ids = intent.scope == .all ? timeline.clips.map(\.id) : targetClipIDs()
            do {
                var cleaned = 0
                for id in ids {
                    guard let clip = timeline.clip(id: id), !clip.isMuted, clip.enhancedAudio == nil else { continue }
                    let audio = try await services.isolateVoice(clip: clip, timeline: timeline, progress: progress)
                    timeline.update(clipID: id) { $0.enhancedAudio = audio }
                    cleaned += 1
                }
                guard cleaned > 0 else { return (timeline, ExecutionResult(outcome: .info(message: fr ? "La voix est déjà nettoyée." : "The voice is already clean."))) }
                return (timeline, .applied("Enhance Voice"))
            } catch {
                return (timeline, .failed(errorMessage(error)))
            }

        case .matchColor:
            guard timeline.clips.count > 1 else { return (timeline, .failed(fr ? "Il faut au moins deux clips." : "You need at least two clips.")) }
            let referenceIndex: Int = {
                if let number = intent.clipIndex { return number == -1 ? timeline.clips.count - 1 : min(max(number - 1, 0), timeline.clips.count - 1) }
                if let selected = context.selectedIndex, context.hasSelection { return selected }
                return timeline.clipIndex(at: playhead) ?? 0
            }()
            do {
                let referenceClip = timeline.clips[referenceIndex]
                let reference = try await services.colorStatistics(clip: referenceClip, timeline: timeline)
                for (index, clip) in timeline.clips.enumerated() where index != referenceIndex {
                    let stats = try await services.colorStatistics(clip: clip, timeline: timeline)
                    timeline.update(clipID: clip.id) { $0.colorMatch = ColorMatch(source: stats, reference: reference, strength: 0.75) }
                }
                return (timeline, .applied(fr ? "Couleurs du clip \(referenceIndex + 1)" : "Colours of clip \(referenceIndex + 1)"))
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

    /// The words of the timeline: the captions' when there are some, else a
    /// fresh transcription kept as hidden captions so later edits by text line up.
    func spokenWords(in timeline: inout VideoTimeline) async throws -> [CaptionWord] {
        if let captions = timeline.captions, !captions.isEmpty { return captions.cues.flatMap(\.words) }
        let (words, language) = try await services.transcribe(timeline: timeline, progress: progress)
        guard !words.isEmpty else { return [] }
        timeline.captions = CaptionTrack(cues: CaptionBuilder.cues(from: words, style: .karaoke), style: .karaoke, isVisible: false, language: language)
        return timeline.captions?.cues.flatMap(\.words) ?? []
    }

    func errorMessage(_ error: Error) -> String {
        if let known = error as? PicshopError { return known.message }
        return error.localizedDescription
    }
}

public extension VideoTimeline {
    func clip(id: UUID) -> VideoClip? { clips.first { $0.id == id } }
}
