#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopVideo

/// The video editor's Outils: five categories, every tool of the old dock
/// among them, the yellow dots from the timeline.
///
/// - Magie: the twelve one-tap actions, in the order the timeline suggests,
///   the Transcription panel and, once there are captions, their style.
/// - Montage: Timeline & coupe, Vitesse, Transitions, Format, Panoramique.
/// - Couleur: Réglages, Couleur, Looks.
/// - Son: Audio.
/// - Ajouter: Texte, Incrustations.
/// Footer: 'Que puis-je dire ?' (and Historique, which StudioChrome adds).
@MainActor
enum VideoToolCatalog {
    typealias Tool = VideoEditorSession.Tool

    /// Category ids, symbols and the panels each one holds, in order.
    static let layout: [(id: String, symbol: String, panels: [Tool])] = [
        ("magic", "sparkles", [.transcript, .magic]),
        ("edit", "scissors", [.cut, .speed, .transitions, .frame, .motion]),
        ("color", "camera.filters", [.adjust, .color, .looks]),
        ("sound", "speaker.wave.2", [.audio]),
        ("add", "plus.square.on.square", [.text, .overlay]),
    ]

    static func make(session: VideoEditorSession) -> ToolCatalog {
        let modified = modifiedTools(in: session.timeline)
        let hasCaptions = session.timeline.captions?.isEmpty == false
        func panel(_ tool: Tool) -> ToolItem {
            .panel(id: tool.rawValue, title: title(for: tool), symbol: symbol(for: tool), isModified: modified.contains(tool),
                   open: { session.activeTool = tool })
        }
        var categories: [ToolCategory] = []
        for entry in layout {
            var items: [ToolItem] = []
            if entry.id == "magic" {
                items = VideoMagicPanel.actions(for: session.timeline).map { action -> ToolItem in
                    ToolItem.action(id: action.id, title: action.title, symbol: action.symbol, isMagic: true, run: {
                        Haptics.magic()
                        let intent = action.intent
                        Task { await session.run(intent) }
                    })
                }
                items.append(panel(.transcript))
                if hasCaptions { items.append(panel(.magic)) }
            } else {
                items = entry.panels.map(panel)
            }
            categories.append(ToolCategory(id: entry.id, title: categoryTitle(entry.id), symbol: entry.symbol, items: items))
        }
        let footer: [ToolFooterItem] = [
            .button(id: "help", title: L("What can I say?"), systemImage: "questionmark.bubble", action: { session.showsHelp = true }),
        ]
        return ToolCatalog(editorKind: "video", categories: categories, footer: footer)
    }

    /// Which tools' edits are in the video: the sheet's yellow dots.
    static func modifiedTools(in timeline: VideoTimeline) -> Set<Tool> {
        var tools: Set<Tool> = []
        let clips = timeline.clips
        if clips.contains(where: { !$0.adjustments.isNeutral }) { tools.insert(.adjust) }
        if clips.contains(where: { $0.colorMixer != nil || $0.colorGrade != nil || $0.lut != nil || $0.colorMatch != nil }) { tools.insert(.color) }
        if clips.contains(where: { $0.look != .original }) { tools.insert(.looks) }
        if clips.contains(where: { $0.speed != 1 }) { tools.insert(.speed) }
        if clips.contains(where: { $0.transitionOut != nil }) { tools.insert(.transitions) }
        if clips.contains(where: { $0.motion != nil }) { tools.insert(.motion) }
        if clips.count > 1 { tools.insert(.cut) }
        if timeline.aspect != .original { tools.insert(.frame) }
        if !timeline.audioTracks.isEmpty || clips.contains(where: { $0.isMuted }) { tools.insert(.audio) }
        if timeline.overlays.contains(where: { $0.textElement != nil }) { tools.insert(.text) }
        if timeline.overlays.contains(where: \.isMedia) { tools.insert(.overlay) }
        if let captions = timeline.captions, !captions.isEmpty {
            tools.insert(.transcript)
            if captions.isVisible { tools.insert(.magic) }
        }
        return tools
    }

    /// The category a panel belongs to.
    static func category(of tool: Tool) -> String {
        layout.first { $0.panels.contains(tool) }?.id ?? "magic"
    }

    /// The other panels of the tool's category (the panel's segments). The
    /// caption style is reached from its own tile only.
    static func siblings(of tool: Tool) -> [Tool] {
        guard tool != .magic, tool != .transcript else { return [tool] }
        return layout.first { $0.panels.contains(tool) }?.panels ?? [tool]
    }

    static func categoryTitle(of tool: Tool) -> String {
        categoryTitle(category(of: tool))
    }

    static func categoryTitle(_ id: String) -> String {
        switch id {
        case "magic": return L("Magic")
        case "edit": return L("Edit")
        case "color": return L("Colour")
        case "sound": return L("Sound")
        default: return L("Add")
        }
    }

    /// A panel's name in the sheet and the panel header.
    static func title(for tool: Tool) -> String {
        switch tool {
        case .cut: return L("Timeline & cut")
        case .magic: return L("Caption style")
        default: return tool.title
        }
    }

    static func symbol(for tool: Tool) -> String {
        switch tool {
        case .cut: return "timeline.selection"
        case .magic: return "captions.bubble"
        default: return tool.symbol
        }
    }
}

/// The open tool, inline at the bottom of the studio: the controls in a
/// ToolPanel with the category's other panels as segments. Timeline & coupe
/// adds the exact timecode and frame stepping to the header.
struct VideoToolCard: View {
    @Bindable var session: VideoEditorSession
    let tool: VideoEditorSession.Tool

    var body: some View {
        let siblings = VideoToolCatalog.siblings(of: tool)
        ToolPanel(title: siblings.count > 1 ? VideoToolCatalog.categoryTitle(of: tool) : VideoToolCatalog.title(for: tool),
                  live: session.live, onDone: { session.activeTool = nil }) {
            if tool == .cut {
                FrameStepAccessory(player: session.player, frameRate: session.timeline.frameRate)
            }
        } content: {
            VStack(spacing: 12) {
                if siblings.count > 1 {
                    ModeSegments(modes: siblings, selection: $session.activeTool,
                                 title: { VideoToolCatalog.title(for: $0) }, symbol: { VideoToolCatalog.symbol(for: $0) })
                }
                VideoToolPanel(session: session, tool: tool)
            }
        }
    }
}

/// The exact timecode and the frame-step buttons. A leaf: the playhead moves.
private struct FrameStepAccessory: View {
    let player: TimelinePlayer
    let frameRate: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: psTimecode(player.currentTime, frameRate: frameRate))
                .font(PSFont.timecode(12))
                .foregroundStyle(PSTheme.textSecondary)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel(L("Timecode"))
            GlassIconButton("backward.frame", label: L("Previous frame"), size: 34) {
                Task { await player.step(frames: -1, frameRate: frameRate) }
            }
            GlassIconButton("forward.frame", label: L("Next frame"), size: 34) {
                Task { await player.step(frames: 1, frameRate: frameRate) }
            }
        }
    }
}
#endif
