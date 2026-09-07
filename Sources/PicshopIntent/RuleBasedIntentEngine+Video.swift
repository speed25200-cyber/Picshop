import Foundation
import PicshopCore

extension RuleBasedIntentEngine {
    static let clipWords: [String] = ["clip", "clips", "segment", "segments", "partie", "part", "passage", "scene", "sequence", "morceau", "bout", "plan", "shot", "section", "extrait"]

    /// Video-only grammar. Returns nil to fall through to the shared photo/video matchers.
    func parseVideo(_ u: NormalizedUtterance, context: IntentContext) -> [EditIntent]? {
        let times = TimeExpressions.allTimes(in: u.tokens, frameRate: context.frameRate)
        let duration = context.timelineDuration
        let playhead = context.playheadSeconds

        // Playback control.
        if u.tokens.count <= 4, u.contains(["play", "lecture", "lance la lecture", "lance la video", "lis la video", "joue", "joue la video", "play the video", "play it", "resume", "reprends", "continue"]) {
            return [EditIntent(action: .play)]
        }
        if u.tokens.count <= 4, u.contains(["pause", "stop", "arrete", "arrete la lecture", "stop the video", "pause the video", "mets en pause", "mets pause"]) {
            return [EditIntent(action: .pause)]
        }

        // Seek.
        if u.contains(["go to", "goto", "jump to", "skip to", "va a", "vas a", "aller a", "saute a", "avance a", "place toi a", "positionne toi a", "mets toi a", "seek to", "at the beginning", "at the start", "to the beginning", "to the start", "au debut", "to the end", "at the end", "a la fin", "beginning of the video", "start of the video", "debut de la video", "fin de la video", "rewind to", "reviens au debut", "retourne au debut", "back to the start", "back to the beginning", "avance de", "recule de", "skip forward", "skip back", "go forward", "go back by", "forward", "backward", "rewind"]) && !u.contains(["transition", "text", "texte", "musique", "music", "clip", "cut", "coupe", "split", "trim", "delete", "supprime", "efface", "enleve", "remove", "rotate", "tourne", "crop", "recadre"]) {
            if u.contains(["beginning", "start", "debut", "commencement"]) { return [EditIntent(action: .seek, time: 0)] }
            if u.contains(["end", "fin", "bout"]) { return [EditIntent(action: .seek, time: duration)] }
            if u.contains(["avance de", "skip forward", "go forward", "forward", "fast forward", "saute"]), let delta = times.first {
                return [EditIntent(action: .seek, time: min(duration, playhead + delta))]
            }
            if u.contains(["recule de", "skip back", "go back by", "back", "backward", "rewind"]), let delta = times.first {
                return [EditIntent(action: .seek, time: max(0, playhead - delta))]
            }
            if let time = times.first { return [EditIntent(action: .seek, time: min(max(0, time), duration))] }
            if let number = NumberWords.firstNumber(in: u.tokens) { return [EditIntent(action: .seek, time: min(max(0, number.value), duration))] }
        }

        // Audio.
        if u.contains(["mute", "coupe le son", "coupe l audio", "enleve le son", "enleve l audio", "supprime le son", "supprime l audio", "retire le son", "sans son", "sans le son", "silence", "silencieux", "no sound", "no audio", "remove the sound", "remove the audio", "remove audio", "kill the audio", "kill the sound", "turn off the sound", "turn off the audio", "desactive le son"]) && !u.contains(["unmute", "remets le son", "reactive le son"]) {
            return [EditIntent(action: .mute, scope: u.contains(["all", "tous", "toute", "partout", "everywhere", "whole", "entire", "toute la video", "the whole video"]) ? .all : .current)]
        }
        if u.contains(["unmute", "remets le son", "remet le son", "reactive le son", "active le son", "with sound", "avec le son", "turn on the sound", "turn the sound on", "turn the sound back on", "restore the sound", "restore the audio", "sound on", "son on"]) {
            return [EditIntent(action: .unmute, scope: .all)]
        }
        if u.contains(["volume", "le son", "the sound", "the audio", "l audio", "louder", "plus fort", "quieter", "moins fort", "softer audio", "monte le son", "baisse le son", "turn it up", "turn it down", "sound level", "niveau sonore"]) && !u.contains(["music", "musique"]) {
            var intent = EditIntent(action: .setVolume)
            let magnitude = AmountParser.magnitude(in: u)
            let sign = AmountParser.sign(in: u) != 0 ? AmountParser.sign(in: u) : (u.contains(["louder", "plus fort", "monte", "up"]) ? 1 : (u.contains(["quieter", "moins fort", "baisse", "down", "lower"]) ? -1 : 1))
            if let number = magnitude.explicitNumber {
                intent.amount = magnitude.isAbsolute || u.contains(["a", "to", "at", "sur"]) ? .absolute(abs(number)) : .relative(abs(number) * Double(sign))
            } else if u.contains(AmountParser.maxWords) {
                intent.amount = .absolute(1)
            } else {
                intent.amount = .relative((magnitude.qualifier == .slight ? 0.1 : magnitude.qualifier == .strong ? 0.4 : 0.25) * Double(sign))
            }
            return [intent]
        }

        // Music.
        if u.contains(["music", "musique", "soundtrack", "bande son", "song", "chanson", "track", "morceau de musique", "background music", "musique de fond", "audio track", "piste audio"]) {
            if u.contains(Self.removeVerbs) || u.contains(["without music", "sans musique", "no music", "pas de musique", "mute the music", "coupe la musique"]) {
                return [EditIntent(action: .removeMusic)]
            }
            var intent = EditIntent(action: .addMusic)
            if let rest = remainder(of: u, after: ["music", "musique", "soundtrack", "bande son", "song", "chanson", "track"]) {
                let cleaned = rest.split(separator: " ").filter { !ObjectVocabulary.fillerWords.contains(String($0)) && !["genre", "type", "style", "kind", "of", "de", "d"].contains(String($0)) }.joined(separator: " ")
                intent.text = cleaned.isEmpty ? nil : cleaned
            }
            if u.contains(["volume", "louder", "quieter", "plus fort", "moins fort"]) {
                intent.action = .setVolume
                intent.scope = .selection
                intent.amount = .relative(u.contains(["louder", "plus fort", "up", "monte"]) ? 0.25 : -0.25)
            }
            return [intent]
        }

        // Transitions.
        if u.contains(["transition", "transitions", "fondu", "fade", "dissolve", "crossfade", "cross fade", "enchainement", "enchainements", "wipe", "volet", "fade in", "fade out", "fondu enchaine", "fade to black", "fondu au noir"]) {
            if u.contains(Self.removeVerbs) || u.contains(["no transition", "sans transition", "without transitions", "sans transitions"]) {
                return [EditIntent(action: .removeTransition, scope: u.contains(["all", "tous", "toutes", "everywhere", "partout"]) ? .all : .current)]
            }
            var intent = EditIntent(action: .addTransition)
            intent.transition = TransitionKind.matching(u.text) ?? .crossDissolve
            if u.contains(["fade in", "fade out", "fondu au noir", "fade to black"]) { intent.transition = .fadeToBlack }
            if u.contains(["all", "tous", "toutes", "everywhere", "partout", "between all", "entre tous", "entre chaque", "between every", "each"]) { intent.scope = .all }
            if let seconds = times.first, seconds <= 5 { intent.time = seconds }
            else if let number = NumberWords.firstNumber(in: u.tokens), number.value <= 5, u.contains(["secondes", "seconde", "seconds", "second", "s", "sec"]) { intent.time = number.value }
            return [intent]
        }

        // Frame extraction.
        if u.contains(["extract the frame", "extract frame", "extract this frame", "save this frame", "save the frame", "screenshot", "capture d ecran", "capture", "capture l image", "extrais l image", "extrais cette image", "enregistre cette image", "enregistre l image", "photo de cette image", "prends une photo", "take a photo", "take a picture", "grab this frame", "grab the frame", "freeze this as a photo", "export this frame", "exporte cette image", "exporte l image", "still", "still image", "image fixe"]) {
            return [EditIntent(action: .extractFrame, time: times.first ?? playhead)]
        }

        // Freeze frame.
        if u.contains(["freeze frame", "freeze", "arret sur image", "fige l image", "fige", "hold this frame", "pause on this frame"]) {
            return [EditIntent(action: .freezeFrame, amount: .absolute(times.first ?? 2), time: playhead)]
        }

        // Stabilisation.
        if u.contains(["stabilize", "stabilise", "stabiliser", "stabilization", "stabilisation", "shaky", "shake", "tremble", "ca tremble", "bouge trop", "trop de tremblement", "remove shake", "enleve les tremblements", "steady", "smooth the camera", "smooth the motion"]) {
            return [EditIntent(action: .stabilize, scope: u.contains(["all", "tous", "toute", "whole", "entire"]) ? .all : .current)]
        }

        // Reverse.
        if u.contains(["reverse", "inverse la video", "inverse le clip", "inverse", "a l envers", "backwards", "rewind effect", "en marche arriere", "marche arriere", "play it backwards", "joue a l envers", "lis a l envers", "boomerang"]) && !u.contains(["flip", "mirror", "miroir", "retourne l image", "transition"]) {
            return [EditIntent(action: .reverse)]
        }

        // Speed.
        if let speed = parseSpeed(u) {
            return [speed]
        }

        // Clip management.
        if u.contains(["duplicate", "duplique", "dupliquer", "copie le clip", "copy the clip", "copy this clip", "double le clip", "clone the clip", "clone this"]) {
            return [EditIntent(action: .duplicateClip, clipIndex: clipNumber(in: u))]
        }
        if u.contains(["move", "deplace", "deplacer", "bouge le clip", "move clip", "put clip", "mets le clip", "swap", "echange", "inverse l ordre", "reorder", "reordonne"]) && u.contains(Self.clipWords + ["debut", "beginning", "start", "fin", "end", "avant", "before", "apres", "after"]) {
            var intent = EditIntent(action: .moveClip, clipIndex: clipNumber(in: u))
            if u.contains(["beginning", "start", "debut", "first", "premier", "premiere", "en premier"]) { intent.index = 1 }
            if u.contains(["end", "fin", "last", "dernier", "derniere", "en dernier"]) { intent.index = -1 }
            if let rest = remainder(of: u, after: ["to position", "en position", "at position", "to slot", "en", "to"]), let number = NumberWords.firstNumber(in: rest.split(separator: " ").map(String.init)) {
                intent.index = Int(number.value)
            }
            return [intent]
        }
        if u.contains(["select clip", "select the clip", "selectionne le clip", "choisis le clip", "go to clip", "va au clip", "select the first clip", "select the last clip", "selectionne le premier clip", "selectionne le dernier clip", "clip suivant", "next clip", "clip precedent", "previous clip"]) {
            var intent = EditIntent(action: .selectLayer)
            intent.index = clipNumber(in: u)
            if u.contains(["next", "suivant"]) { intent.index = (context.selectedIndex ?? 0) + 2 }
            if u.contains(["previous", "precedent"]) { intent.index = max(1, (context.selectedIndex ?? 0)) }
            return [intent]
        }

        // Cutting: split / trim / delete range / delete clip.
        let hasRemoveVerb = u.contains(Self.removeVerbs) || u.contains(["cut", "coupe", "coupes", "couper", "trim", "raccourcis", "raccourcir", "shorten", "tronque", "crop the video to", "keep", "garde", "garder", "conserve", "ne garde que", "keep only", "only keep"])
        let mentionsClip = u.contains(Self.clipWords)
        let mentionsBeginning = u.contains(["beginning", "start", "debut", "intro", "the first", "les premieres", "la premiere", "premieres", "first"])
        let mentionsEnd = u.contains(["end", "ending", "fin", "outro", "the last", "les dernieres", "la derniere", "dernieres", "last", "derniere", "dernier"])

        if u.contains(["split", "split here", "split the clip", "split at", "divise", "diviser", "scinde", "scinder", "separe", "separer", "coupe ici", "cut here", "coupe en deux", "cut in two", "coupe le clip", "cut the clip", "coupe la video", "cut the video", "coupe a", "cut at", "coupe la", "coupe", "cut"]) && !mentionsBeginning && !mentionsEnd && !u.contains(["from", "de", "entre", "between", "to", "jusqu", "a partir"]) && !(mentionsClip && u.contains(Self.removeVerbs)) {
            if u.contains(["cut out", "cut the", "coupe le", "coupe la", "coupe les"]), let target = remainder(of: u, after: ["cut out", "cut the", "coupe le", "coupe la", "coupe les"]), let object = makeTarget(from: target, context: context), object.label != "object", !NormalizedUtterance(target).contains(Self.clipWords + ["video", "film"]) {
                return [EditIntent(action: .removeObject, target: object, confidence: 0.8)]
            }
            let time = times.first ?? (NumberWords.firstNumber(in: u.tokens).map { $0.value } ?? playhead)
            return [EditIntent(action: .split, time: min(max(0, time), duration))]
        }

        if hasRemoveVerb || mentionsBeginning || mentionsEnd || u.contains(["trim", "raccourcis", "shorten", "keep", "garde", "only"]) {
            let wantsKeep = u.contains(["keep", "garde", "garder", "conserve", "ne garde que", "keep only", "only keep", "only", "seulement", "juste", "just"])
            // "delete clip 2" / "supprime ce clip"
            if mentionsClip, u.contains(Self.removeVerbs) || u.contains(["cut", "coupe"]), times.isEmpty {
                let scope: TargetScope = u.contains(["all", "tous", "toutes", "every"]) ? .all : .current
                return [EditIntent(action: .deleteClip, clipIndex: clipNumber(in: u), scope: scope)]
            }
            // Ranges: "from 5 to 12 seconds" / "de 5 à 12 secondes" / "between 5 and 12"
            if times.count >= 2 {
                let range = TimeSpan(start: min(times[0], times[1]), end: max(times[0], times[1]))
                return [EditIntent(action: wantsKeep ? .trim : .deleteRange, timeRange: range)]
            }
            if let seconds = times.first {
                if mentionsBeginning || u.contains(["from the start", "from the beginning", "au debut", "du debut", "at the start", "at the beginning", "first"]) {
                    return [EditIntent(action: wantsKeep ? .trim : .deleteRange, timeRange: wantsKeep ? TimeSpan(start: 0, end: seconds) : TimeSpan(start: 0, end: seconds))]
                }
                if mentionsEnd {
                    return [EditIntent(action: wantsKeep ? .trim : .deleteRange, timeRange: wantsKeep ? TimeSpan(start: max(0, duration - seconds), end: duration) : TimeSpan(start: max(0, duration - seconds), end: duration))]
                }
                if u.contains(["shorten", "raccourcis", "raccourcir", "trim to", "coupe a", "cut to", "keep the first", "garde les", "limit", "limite", "max", "maximum", "make it", "fais une video de", "ramene a", "tronque"]) {
                    return [EditIntent(action: .trim, timeRange: TimeSpan(start: 0, end: seconds))]
                }
                if u.contains(["after", "apres", "a partir de", "from"]) {
                    return [EditIntent(action: .deleteRange, timeRange: TimeSpan(start: seconds, end: duration))]
                }
                if u.contains(["before", "avant", "up to", "jusqu a", "until"]) {
                    return [EditIntent(action: .deleteRange, timeRange: TimeSpan(start: 0, end: seconds))]
                }
                return [EditIntent(action: .deleteRange, timeRange: TimeSpan(start: 0, end: seconds), confidence: 0.6)]
            }
            // No explicit time: "delete the beginning" (up to playhead), "cut the end" (from playhead)
            if mentionsBeginning, hasRemoveVerb, !u.contains(Self.clipWords) {
                return [EditIntent(action: .deleteRange, timeRange: TimeSpan(start: 0, end: playhead > 0.1 ? playhead : min(duration, 1)))]
            }
            if mentionsEnd, hasRemoveVerb, !u.contains(Self.clipWords) {
                return [EditIntent(action: .deleteRange, timeRange: TimeSpan(start: playhead < duration - 0.1 ? playhead : max(0, duration - 1), end: duration))]
            }
            if u.contains(["delete the selection", "supprime la selection", "delete selected", "supprime la partie selectionnee", "remove the selection"]) {
                return [EditIntent(action: .deleteClip, scope: .selection)]
            }
        }

        return nil
    }

    func clipNumber(in u: NormalizedUtterance) -> Int? {
        for token in u.tokens {
            if let ordinal = NumberWords.ordinal(token) { return ordinal }
        }
        if let index = u.tokenIndex(of: "clip") ?? u.tokenIndex(of: "segment") ?? u.tokenIndex(of: "partie") ?? u.tokenIndex(of: "part") ?? u.tokenIndex(of: "scene"),
           index + 1 < u.tokens.count, let number = NumberWords.parse(u.tokens, at: index + 1), number.value >= 1, number.value <= 99 {
            return Int(number.value)
        }
        if u.contains(["this clip", "ce clip", "current clip", "le clip actuel", "selected clip", "le clip selectionne", "cette partie", "this part"]) { return nil }
        return nil
    }

    func parseSpeed(_ u: NormalizedUtterance) -> EditIntent? {
        let faster = u.contains(["speed up", "faster", "quicker", "accelere", "accelerer", "plus vite", "plus rapide", "en accelere", "fast forward", "timelapse", "time lapse", "hyperlapse", "speed it up", "make it faster", "rapide", "vite"])
        let slower = u.contains(["slow motion", "slow mo", "slowmo", "slow down", "slower", "ralenti", "ralentis", "ralentir", "au ralenti", "en ralenti", "plus lent", "plus lentement", "moins vite", "half speed", "make it slower", "slow it down", "lent"])
        let mentionsSpeed = u.contains(["speed", "vitesse", "x2", "x3", "x4", "2x", "3x", "4x", "0.5x", "x0.5", "times faster", "times slower", "fois plus vite", "fois plus lent", "fois moins vite", "twice as fast", "deux fois plus vite", "deux fois plus lent", "double speed", "vitesse normale", "normal speed", "regular speed", "vitesse x", "playback rate"])
        guard faster || slower || mentionsSpeed else { return nil }
        if u.contains(["normal speed", "vitesse normale", "regular speed", "reset speed", "remets la vitesse", "speed to normal", "1x", "x1"]) {
            return EditIntent(action: .setSpeed, amount: .absolute(1))
        }
        var value: Double?
        if let number = NumberWords.firstNumber(in: u.tokens), number.value > 0, number.value <= 64 {
            value = number.value
        }
        if u.contains(["half", "moitie", "demi"]) && value == nil { value = 2 }
        if u.contains(["twice", "double", "deux fois"]) && value == nil { value = 2 }
        if u.contains(["triple", "trois fois"]) && value == nil { value = 3 }
        if let value {
            let isPercent = u.contains(["pourcent", "percent"])
            if isPercent {
                return EditIntent(action: .setSpeed, amount: .absolute(max(0.1, value / 100)))
            }
            if slower && value >= 1 {
                return EditIntent(action: .setSpeed, amount: .absolute(1 / value))
            }
            if value < 1 && faster {
                return EditIntent(action: .setSpeed, amount: .absolute(1 / value))
            }
            return EditIntent(action: .setSpeed, amount: .absolute(value))
        }
        let magnitude = AmountParser.magnitude(in: u)
        if slower {
            let factor = magnitude.qualifier == .slight ? 0.75 : magnitude.qualifier == .strong ? 0.25 : 0.5
            return EditIntent(action: .setSpeed, amount: .absolute(factor))
        }
        if faster {
            let factor = magnitude.qualifier == .slight ? 1.5 : magnitude.qualifier == .strong ? 4 : 2
            return EditIntent(action: .setSpeed, amount: .absolute(factor))
        }
        return EditIntent(action: .setSpeed, amount: .absolute(1), confidence: 0.5)
    }
}
