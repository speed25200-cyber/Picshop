import Foundation
import PicshopCore

/// Idea chips built on the device from what the editor knows, and the merge
/// with the ideas a brain proposes. Deterministic; every step is valid for the mode.
public enum IdeaEngine {
    struct Template {
        let key: String
        let french: String
        let english: String
        let whyFrench: String
        let whyEnglish: String
        let symbol: String
        let steps: [RawIntentStep]
        /// Lower-cased pieces of the history label the idea leaves once applied.
        let markers: [String]
        var generative = false

        func idea(_ language: NormalizedUtterance.Language) -> LiveIdea {
            let fr = language == .french
            return LiveIdea(title: fr ? french : english, why: fr ? whyFrench : whyEnglish, symbol: symbol, steps: steps, source: .heuristic)
        }
    }

    public static func heuristic(_ state: LiveEditorState, dismissed: Set<String>, language: NormalizedUtterance.Language) -> [LiveIdea] {
        let candidates: [Template]
        switch state.mode {
        case .photo: candidates = photoCandidates(state)
        case .video: candidates = videoCandidates(state)
        case .pdf: return []
        }
        let applied = state.appliedEdits.map { $0.lowercased() }
        var ideas: [LiveIdea] = []
        for template in candidates {
            guard ideas.count < 3 else { break }
            if template.generative, !state.hasGenerativeEngine { continue }
            if template.markers.contains(where: { marker in applied.contains { $0.contains(marker) } }) { continue }
            let idea = template.idea(language)
            guard !dismissed.contains(idea.id), !ideas.contains(where: { $0.id == idea.id }) else { continue }
            ideas.append(idea)
        }
        return ideas
    }

    /// The chips to show: the incoming ideas (or the brain's current ones when nothing
    /// came in), then the fill, without dismissed ids or duplicates, at most 3.
    public static func merge(current: [LiveIdea], incoming: [LiveIdea], dismissed: Set<String>, fill: [LiveIdea]) -> [LiveIdea] {
        let primary = incoming.isEmpty ? current.filter { $0.source != .heuristic } : incoming
        var result: [LiveIdea] = []
        for idea in primary + fill where result.count < 3 && !idea.steps.isEmpty && !dismissed.contains(idea.id) && !result.contains(where: { $0.id == idea.id }) {
            result.append(idea)
        }
        return result
    }

    /// The set shown before anything is known about the picture.
    public static func generic(mode: EditorMode, language: NormalizedUtterance.Language) -> [LiveIdea] {
        heuristic(LiveEditorState(mode: mode, version: 0), dismissed: [], language: language)
    }

    // MARK: Photo

    static func photoCandidates(_ state: LiveEditorState) -> [Template] {
        guard let scene = state.scene else { return [enhance, autoCrop, vivid] }
        var list: [Template] = []
        if scene.brightness < 0.3 { list.append(dark) } else if scene.brightness > 0.8 { list.append(bright) }
        if scene.colourfulness < 0.15 { list.append(dull) }
        let persons = max(scene.people, scene.faces)
        let outdoor: Set<String> = ["sky", "outdoor", "beach", "mountain", "landscape", "sea", "ocean", "field", "desert", "sunset", "sunrise", "cityscape", "skyline", "snow"]
        for id in MagicSuggestions.ranked(for: scene) {
            switch id {
            case "retouch" where scene.faces >= 1 || scene.people == 1: list.append(retouch)
            case "portrait" where persons >= 1 || !scene.animals.isEmpty: list.append(portrait)
            case "sky" where !Set(scene.labels).isDisjoint(with: outdoor): list.append(sky)
            case "enhance": list.append(enhance)
            case "cleanup" where scene.people >= 2: list.append(cleanup)
            case "cutout" where persons == 0: list.append(cutout)
            case "expand": list.append(expand)
            case "relight" where persons >= 1: list.append(relight)
            case "mono": list.append(mono)
            default: break
            }
        }
        return list + [enhance, autoCrop, vivid]
    }

    static let retouch = Template(key: "retouch", french: "Portrait doux", english: "Soft portrait",
                                  whyFrench: "Adoucit la peau et éclaire le regard.", whyEnglish: "Smooths the skin and brightens the eyes.",
                                  symbol: "person.crop.circle",
                                  steps: [RawIntentStep(action: "selectiveAdjust", target: "face", parameter: "noiseReduction", amountMode: "relative", amount: 30),
                                          RawIntentStep(action: "selectiveAdjust", target: "eyes", parameter: "brightness", amountMode: "relative", amount: 15)],
                                  markers: ["selective"])
    static let portrait = Template(key: "portrait", french: "Flouter le fond", english: "Blur the background",
                                   whyFrench: "Détache le sujet d'un fond plus doux.", whyEnglish: "Sets the subject apart from a softer background.",
                                   symbol: "camera.aperture", steps: [RawIntentStep(action: "blurBackground", amountMode: "absolute", amount: 60)],
                                   markers: ["blur background"])
    static let sky = Template(key: "sky", french: "Raviver le ciel", english: "Brighten the sky",
                              whyFrench: "Un ciel de coucher de soleil plus spectaculaire.", whyEnglish: "A more dramatic sunset sky.",
                              symbol: "cloud.sun", steps: [RawIntentStep(action: "generativeFill", target: "sky", text: "dramatic sunset clouds")],
                              markers: ["generate"], generative: true)
    static let enhance = Template(key: "enhance", french: "Améliorer", english: "Enhance",
                                  whyFrench: "Lumière et couleurs équilibrées en un geste.", whyEnglish: "Balanced light and colour in one go.",
                                  symbol: "wand.and.stars", steps: [RawIntentStep(action: "autoEnhance", amountMode: "absolute", amount: 70)],
                                  markers: ["auto enhance"])
    static let cleanup = Template(key: "cleanup", french: "Enlever les passants", english: "Remove passers-by",
                                  whyFrench: "Retire ceux qui distraient du sujet.", whyEnglish: "Removes the people who distract from the subject.",
                                  symbol: "eraser", steps: [RawIntentStep(action: "cleanUp")], markers: ["passers-by", "passants"])
    static let cutout = Template(key: "cutout", french: "Fond blanc", english: "White background",
                                 whyFrench: "Un fond blanc net, prêt pour une annonce.", whyEnglish: "A clean white background, ready for a listing.",
                                 symbol: "sparkles", steps: [RawIntentStep(action: "replaceBackground", background: "white")], markers: ["replace background"])
    static let expand = Template(key: "expand", french: "Étendre l'image", english: "Expand the image",
                                 whyFrench: "Plus d'air autour du sujet, au format 4:5.", whyEnglish: "More room around the subject, in 4:5.",
                                 symbol: "arrow.up.left.and.arrow.down.right", steps: [RawIntentStep(action: "expandCanvas", aspect: "ratio4x5")],
                                 markers: ["expand"], generative: true)
    static let relight = Template(key: "relight", french: "Rééclairer", english: "Relight",
                                  whyFrench: "Une lumière plus flatteuse sur le sujet.", whyEnglish: "More flattering light on the subject.",
                                  symbol: "sun.max", steps: [RawIntentStep(action: "relight")], markers: ["relight"])
    static let mono = Template(key: "mono", french: "Noir et blanc", english: "Black and white",
                               whyFrench: "Un noir et blanc qui fait ressortir les formes.", whyEnglish: "Black and white that brings out the shapes.",
                               symbol: "circle.lefthalf.filled", steps: [RawIntentStep(action: "applyLook", look: "mono")],
                               markers: [FilterPreset.mono.englishName.lowercased()])
    static let dark = Template(key: "dark", french: "Déboucher les ombres", english: "Lift the shadows",
                               whyFrench: "La photo est sombre : on retrouve les détails.", whyEnglish: "The photo is dark: bring the detail back.",
                               symbol: "sun.max",
                               steps: [RawIntentStep(action: "adjust", parameter: "brightness", amountMode: "relative", amount: 20),
                                       RawIntentStep(action: "adjust", parameter: "shadows", amountMode: "relative", amount: 25)],
                               markers: ["shadows"])
    static let bright = Template(key: "bright", french: "Calmer les hautes lumières", english: "Tame the highlights",
                                 whyFrench: "Les zones claires sont un peu brûlées.", whyEnglish: "The bright areas are a little blown.",
                                 symbol: "sun.max", steps: [RawIntentStep(action: "adjust", parameter: "highlights", amountMode: "relative", amount: -30)],
                                 markers: ["highlights"])
    static let dull = Template(key: "dull", french: "Raviver les couleurs", english: "Bring colours back",
                               whyFrench: "Les couleurs sont ternes : un peu plus de vie.", whyEnglish: "The colours are flat: a little more life.",
                               symbol: "paintpalette", steps: [RawIntentStep(action: "adjust", parameter: "vibrance", amountMode: "relative", amount: 25)],
                               markers: ["vibrance"])
    static let autoCrop = Template(key: "autoCrop", french: "Recadrer", english: "Better framing",
                                   whyFrench: "Un cadrage plus fort, choisi pour cette photo.", whyEnglish: "A stronger framing, chosen for this photo.",
                                   symbol: "crop", steps: [RawIntentStep(action: "autoCrop")], markers: ["best crop"])
    static let vivid = Template(key: "vivid", french: "Look éclatant", english: "Vivid look",
                                whyFrench: "Des couleurs plus éclatantes.", whyEnglish: "Brighter, punchier colours.",
                                symbol: "camera.filters", steps: [RawIntentStep(action: "applyLook", look: "vivid")],
                                markers: [FilterPreset.vivid.englishName.lowercased()])

    // MARK: Video

    static func videoCandidates(_ state: LiveEditorState) -> [Template] {
        guard let video = state.video else { return [captions, silences, voice] }
        var list: [Template] = []
        let ranked = VideoMagicSuggestions.ranked(duration: video.duration, clipCount: video.clipDurations.count, hasMusic: video.musicTracks > 0,
                                                  hasCaptions: video.hasCaptions, isVertical: video.isVertical)
        for id in ranked {
            switch id {
            case "captions" where !video.hasCaptions: list.append(captions)
            case "silences": list.append(silences)
            case "fillers": list.append(fillers)
            case "beat" where video.musicTracks > 0: list.append(beat)
            case "vertical" where !video.isVertical: list.append(vertical)
            case "highlights" where video.duration > 32: list.append(highlights)
            case "punchins": list.append(punchIns)
            case "voice": list.append(voice)
            default: break
            }
        }
        return list
    }

    static let captions = Template(key: "captions", french: "Sous-titrer", english: "Add captions",
                                   whyFrench: "Des sous-titres animés, lisibles sans le son.", whyEnglish: "Animated captions, readable without sound.",
                                   symbol: "captions.bubble", steps: [RawIntentStep(action: "autoCaptions", text: "karaoke")], markers: ["caption", "sous-titres"])
    static let silences = Template(key: "silences", french: "Couper les blancs", english: "Cut the pauses",
                                   whyFrench: "Un rythme plus serré, sans les silences.", whyEnglish: "A tighter pace without the silences.",
                                   symbol: "scissors", steps: [RawIntentStep(action: "removeSilences", amount: 0.3)], markers: ["pauses cut", "blancs"])
    static let fillers = Template(key: "fillers", french: "Sans « euh »", english: "Cut the ums",
                                  whyFrench: "Retire les hésitations de la voix.", whyEnglish: "Removes the hesitations from the voice.",
                                  symbol: "scissors", steps: [RawIntentStep(action: "removeFillers")], markers: ["filler", "hésitations"])
    static let beat = Template(key: "beat", french: "Caler sur le rythme", english: "Cut to the beat",
                               whyFrench: "Les coupes tombent sur la musique.", whyEnglish: "The cuts land on the music.",
                               symbol: "music.note", steps: [RawIntentStep(action: "syncToBeat")], markers: ["beat", "rythme"])
    static let vertical = Template(key: "vertical", french: "Passer en vertical", english: "Go vertical",
                                   whyFrench: "Au format 9:16, en suivant le sujet.", whyEnglish: "9:16, following the subject.",
                                   symbol: "rectangle.portrait", steps: [RawIntentStep(action: "smartReframe", aspect: "ratio9x16")], markers: ["reframe"])
    static let highlights = Template(key: "highlights", french: "Résumé de 30 s", english: "30-second recap",
                                     whyFrench: "Les meilleurs moments en 30 secondes.", whyEnglish: "The best moments in 30 seconds.",
                                     symbol: "film.stack", steps: [RawIntentStep(action: "highlights", seconds: 30)], markers: ["recap", "résumé"])
    static let punchIns = Template(key: "punchins", french: "Zooms de coupe", english: "Zoom cuts",
                                   whyFrench: "Des zooms qui relancent l'attention.", whyEnglish: "Zooms that keep attention up.",
                                   symbol: "arrow.up.left.and.arrow.down.right", steps: [RawIntentStep(action: "punchIns", amount: 1.2)], markers: ["zoom"])
    static let voice = Template(key: "voice", french: "Voix nette", english: "Clear voice",
                                whyFrench: "Une voix sans bruit de fond.", whyEnglish: "A voice without background noise.",
                                symbol: "sparkles", steps: [RawIntentStep(action: "enhanceVoice", scope: "all")], markers: ["enhance voice"])
}
