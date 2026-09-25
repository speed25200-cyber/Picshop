import Foundation
import PicshopCore

/// The words Live's on-device brains share: the per-turn editor state, the
/// media text block, and Apple Foundation Models' instructions and prompt.
/// The local model's system prompt and messages are built by LocalLivePrompt
/// from the same pieces. Everything here is deterministic (no dates, ids or
/// device facts), so the same state always reads the same way.
public enum LivePrompt {
    /// The AmountUnit table, as the model should read it.
    static func unitsProse(mode: EditorMode) -> String {
        var lines = [
            "Amounts",
            "- adjust and selectiveAdjust: percent from -100 to 100. relative for more or less (a touch 10, a bit 20, a lot 40), absolute for \"set to\". Keep amounts modest unless the user says a lot.",
            "- applyLook, blurBackground, autoEnhance, denoise and sharpen: percent from 0 to 100.",
        ]
        if mode == .photo {
            lines.append("- moveObject: a fraction of the frame from 0.05 to 0.5. recolor: strength from 0 to 1. upscale: a multiplier, 2 to 4.")
        } else {
            lines.append("- setVolume: percent from 0 to 200. removeSilences: 0.2 gentle to 0.45 tight. autoDuck: depth 0 to 0.9. splitScenes: sensitivity 0 to 1.")
            lines.append("- fadeAudio: seconds, 0 to 10. highlights: seconds, 5 to 300. speed: a multiplier, 0.1 to 8. punchIns: zoom 1 to 1.5, 0 removes them. speedRamp: the slowest speed, 0.1 to 1.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Per-turn context

    /// `<editor_state v=N>…</editor_state>`: deterministic, at most 1,200 characters; lists
    /// lose their oldest entries first. Facts only, never orders, and never media text.
    public static func editorState(_ state: LiveEditorState, sinceLastReply: [String] = [], interruptedAfter: String? = nil, imageVersion: Int? = nil,
                                   lastImageVersion: Int? = nil, ideasOnScreen: [String] = []) -> String {
        var applied = Array(state.appliedEdits.suffix(12))
        var since = sinceLastReply
        var candidates = state.candidates
        var ideas = ideasOnScreen
        var labels = state.scene?.labels ?? []

        func render() -> String {
            var lines = ["<editor_state v=\(state.version)>"]
            var modeLine = "mode: \(state.mode.rawValue)"
            if let size = state.canvasPixels, size.width > 0, size.height > 0 {
                modeLine += ", \(Int(size.width.rounded()))x\(Int(size.height.rounded())) (\(aspectName(size)))"
            }
            lines.append(modeLine)
            lines.append("applied: " + (applied.isEmpty ? "nothing yet" : applied.joined(separator: "; ")))
            let values = AdjustmentParameter.allCases.compactMap { parameter -> String? in
                let value = state.adjustments[parameter]
                guard abs(value) >= 0.005 else { return nil }
                let percent = Int((value * 100).rounded())
                return "\(parameter.rawValue) \(percent > 0 ? "+" : "")\(percent)"
            }
            if !values.isEmpty { lines.append("values: " + values.joined(separator: ", ")) }
            lines.append("selection: " + (state.selection.map(clean) ?? "none"))
            lines.append("question: " + (state.pendingQuestion.map(clean) ?? "none"))
            if !candidates.isEmpty { lines.append("candidates: " + candidates.map(clean).joined(separator: " | ")) }
            let kind = LiveSceneLines.kind(state)
            if let scene = state.scene {
                lines.append("scene: " + ([kind].compactMap { $0 } + [sceneLine(scene, labels: labels)]).joined(separator: "; "))
            } else if let kind {
                lines.append("scene: " + kind)
            }
            if let table = state.table { lines += LiveSceneLines.table(table) }
            if let map = state.sceneMap { lines += LiveSceneLines.scene(map, budget: state.table == nil ? LocalLivePrompt.Budgets.sceneLines : LocalLivePrompt.Budgets.sceneLinesWithTable) }
            if let video = state.video { lines.append(timelineLine(video)) }
            if let busy = state.busyTitle { lines.append("running: " + clean(busy)) }
            if !since.isEmpty { lines.append("since your reply: " + since.map(clean).joined(separator: "; ")) }
            if !ideas.isEmpty { lines.append("ideas on screen: " + ideas.enumerated().map { "\($0.offset + 1) \(clean($0.element))" }.joined(separator: " | ")) }
            if let interruptedAfter, !interruptedAfter.isEmpty { lines.append("interrupted after: '\(clean(interruptedAfter))'") }
            if let imageVersion {
                lines.append("image: attached (v\(imageVersion))")
            } else if let lastImageVersion {
                lines.append("image: not attached (last seen v\(lastImageVersion))")
            } else {
                lines.append("image: not attached")
            }
            lines.append("</editor_state>")
            return lines.joined(separator: "\n")
        }

        // The table and scene lines have budgets of their own (D15).
        let limit = state.table != nil || state.sceneMap != nil ? 1_800 : 1_200
        var text = render()
        while text.count > limit {
            // Cut the longest list from its oldest end.
            let lists = [applied.count, since.count, candidates.count, ideas.count, labels.count]
            guard let longest = lists.indices.max(by: { lists[$0] < lists[$1] }), lists[longest] > 0 else { break }
            switch longest {
            case 0: applied.removeFirst()
            case 1: since.removeFirst()
            case 2: candidates.removeLast()
            case 3: ideas.removeLast()
            default: labels.removeLast()
            }
            text = render()
        }
        if text.count > limit {
            let body = String(text.dropLast("\n</editor_state>".count).prefix(limit - "\n</editor_state>".count - 1))
            text = body + "…\n</editor_state>"
        }
        return text
    }

    /// The context lines of one turn: the state, then facts about the turn itself.
    public static func turnContext(_ turn: LiveUserTurn, imageVersion: Int?, lastImageVersion: Int?) -> String {
        var text = editorState(turn.editorState, sinceLastReply: turn.sinceLastReply, interruptedAfter: turn.interruptedAfter, imageVersion: imageVersion,
                               lastImageVersion: lastImageVersion, ideasOnScreen: turn.ideasOnScreen)
        switch turn.kind {
        case .sessionStart:
            text += "\nThe Live session just started; a greeting of at most 12 words and propose_ideas fit here."
        case .typed:
            text += "\nThe user typed this turn instead of speaking."
        case .speech:
            break
        }
        return text
    }

    /// Text from the user's media (text layers, words near the playhead), as a separate
    /// user text block of at most 600 characters. Never sent as role:system.
    public static func mediaText(_ texts: [String]) -> String? {
        let parts = texts.map { $0.replacingOccurrences(of: "<", with: "‹") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let open = "<media_text>\n", close = "\n</media_text>"
        var body = parts.joined(separator: "\n")
        let room = 600 - open.count - close.count
        if body.count > room { body = String(body.prefix(room - 1)) + "…" }
        return open + body + close
    }

    // MARK: On-device model

    /// The same persona in at most 1,600 characters, plus a compact action list.
    public static func onDeviceInstructions(mode: EditorMode) -> String {
        let medium = mode == .video ? "video" : "photo"
        let persona = """
        You are Picshop Live, a warm, expert creative director inside a \(medium) editor on iPhone, talking out loud with the user. \
        Reply in the user's language; in French use tu. One or two short spoken sentences: no lists, markdown or emojis. At most one question. \
        You cannot see the \(medium): use the editor state and the Scene line. Change it only with tools: apply_edits for a change or an accepted idea, \
        undo for "annule" or "c'est trop", compare to show the before. Say one short sentence before a tool call. \
        Amounts are percent from -100 to 100: a touch 10, a bit 20, a lot 40. Never identify real people.
        """
        let actions = LiveToolSchema.allowedActions(for: mode).map(\.rawValue)
        var list = "Actions: "
        for action in actions {
            let next = (list == "Actions: " ? "" : ", ") + action
            guard persona.count + 1 + list.count + next.count <= 1_600 else { break }
            list += next
        }
        return persona + "\n" + list
    }

    /// The compact state (at most 600 characters), then the scene facts, then the words.
    public static func onDevicePrompt(_ turn: LiveUserTurn) -> String {
        let state = turn.editorState
        var parts: [String] = ["\(state.mode.rawValue) v\(state.version)"]
        if !state.appliedEdits.isEmpty { parts.append("applied: " + state.appliedEdits.suffix(6).joined(separator: "; ")) }
        let values = AdjustmentParameter.allCases.compactMap { parameter -> String? in
            let value = state.adjustments[parameter]
            guard abs(value) >= 0.005 else { return nil }
            let percent = Int((value * 100).rounded())
            return "\(parameter.rawValue) \(percent > 0 ? "+" : "")\(percent)"
        }
        if !values.isEmpty { parts.append("values: " + values.joined(separator: ", ")) }
        if let question = state.pendingQuestion { parts.append("question: " + question) }
        if !state.candidates.isEmpty { parts.append("candidates: " + state.candidates.joined(separator: " | ")) }
        if let video = state.video { parts.append(timelineLine(video)) }
        if !turn.sinceLastReply.isEmpty { parts.append("since your reply: " + turn.sinceLastReply.joined(separator: "; ")) }
        var compact = "Editor: " + parts.joined(separator: "; ")
        if compact.count > 600 { compact = String(compact.prefix(599)) + "…" }
        var lines = [compact]
        let kind = LiveSceneLines.kind(state)
        if let scene = state.scene {
            lines.append("Scene: " + ([kind].compactMap { $0 } + [sceneLine(scene, labels: scene.labels)]).joined(separator: "; "))
        } else if let kind {
            lines.append("Scene: " + kind)
        }
        if let table = state.table {
            lines += LiveSceneLines.table(table)
            if let focus = LiveSceneLines.tableFocus(table, words: turn.text) { lines.append(focus) }
        }
        if let map = state.sceneMap { lines += LiveSceneLines.scene(map, budget: LocalLivePrompt.Budgets.sceneLinesWithTable) }
        if let last = turn.recentActions.last { lines.append(LiveSceneLines.last(last, scene: state.sceneMap)) }
        let words = turn.kind == .sessionStart ? "(the Live session just started: greet in a few words)" : turn.text
        lines.append("User: " + words)
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    static func sceneLine(_ scene: SceneDescription, labels: [String]) -> String {
        var facts: [String] = []
        if scene.people > 0 { facts.append("\(scene.people) \(scene.people == 1 ? "person" : "people")") }
        if scene.faces > 0 { facts.append("\(scene.faces) \(scene.faces == 1 ? "face" : "faces")") }
        facts += scene.animals
        if scene.hasText { facts.append("text") }
        var line = facts.isEmpty ? "no people" : facts.joined(separator: ", ")
        if !labels.isEmpty { line += "; " + labels.prefix(6).joined(separator: ", ") }
        line += "; brightness \(twoDecimals(scene.brightness)), colourful \(twoDecimals(scene.colourfulness))"
        return line
    }

    static func timelineLine(_ video: VideoFacts) -> String {
        var clips = video.clipDurations.map { oneDecimal($0) + " s" }
        if clips.count > 8 { clips = Array(clips.prefix(8)) + ["…"] }
        var line = "timeline: \(video.clipDurations.count) \(video.clipDurations.count == 1 ? "clip" : "clips") (\(clips.joined(separator: ", "))), "
        line += "\(oneDecimal(video.duration)) s, playhead \(oneDecimal(video.playhead)) s"
        if let clip = video.currentClip { line += " in clip \(clip)" }
        line += ", \(video.musicTracks) music \(video.musicTracks == 1 ? "track" : "tracks"), captions \(video.hasCaptions ? "on" : "off")"
        line += video.isVertical ? ", vertical" : ", horizontal"
        return line
    }

    /// 4032x3024 -> 4:3; shapes without a common name read as 1.85:1.
    static func aspectName(_ size: PSSize) -> String {
        let ratio = size.width / size.height
        let named: [(Double, Double)] = [(1, 1), (4, 3), (3, 4), (3, 2), (2, 3), (16, 9), (9, 16), (4, 5), (5, 4), (21, 9), (2, 1), (1, 2)]
        for (w, h) in named where abs(ratio - w / h) / (w / h) < 0.01 { return "\(Int(w)):\(Int(h))" }
        return twoDecimals(ratio) + ":1"
    }

    static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        let magnitude = abs(tenths)
        return "\(tenths < 0 ? "-" : "")\(magnitude / 10).\(magnitude % 10)"
    }

    static func twoDecimals(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = abs(hundredths)
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// State lines hold one line each and no tags (a tag cannot open without "<").
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<", with: "‹")
    }
}
