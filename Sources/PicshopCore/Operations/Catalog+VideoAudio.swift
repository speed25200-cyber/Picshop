import Foundation

/// Video sound: clip sound, sound tracks (music, voice-over, effects), ducking, beat sync, voice.
/// A sound-track step names its track with clipNumber and scope "selection".
enum CatalogVideoAudio {
    static var all: [OperationSpec] { [mute, unmute, setVolume, addMusic, removeMusic, moveAudio, fadeAudio, autoDuck, syncToBeat, fitMusic, enhanceVoice] }

    static var mute: OperationSpec {
        legacy(.mute, in: [.video], .audio, .composition,
               title: t("Mute", "Couper le son"), summary: t("Silences a clip or a track", "Rend muet un clip ou une piste")) { s in
            s.params = [Step.clipNumber(doc: "clip, or track with scope selection"), Step.scope(doc: "selection = a sound track")]
            s.triggers = [
                .fr: ["coupe le son", "enlève le son", "muet", "sans le son", "silence"],
                .en: ["mute", "no sound", "silence the clip", "turn off the sound"],
            ]
            s.examples = [
                fr("coupe le son"),
                fr("enlève le son du clip 3", ["clipNumber": 3]),
                en("mute the music", ["clipNumber": 1, "scope": "selection"]),
                fr("mets le clip 2 en muet", ["clipNumber": 2]),
                en("mute clip 3", ["clipNumber": 3]),
                near("remets le son", .fr, expected: "unmute"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "audio"
        }
    }

    static var unmute: OperationSpec {
        legacy(.unmute, in: [.video], .audio, .composition,
               title: t("Unmute", "Remettre le son"), summary: t("Brings the sound back", "Remet le son")) { s in
            s.params = [Step.clipNumber(doc: "clip, or track with scope selection"), Step.scope(doc: "selection = a sound track")]
            s.triggers = [
                .fr: ["remets le son", "réactive le son", "avec le son"],
                .en: ["unmute", "sound back on", "turn the sound on"],
            ]
            s.examples = [
                fr("remets le son"),
                fr("réactive le son du clip 2", ["clipNumber": 2]),
                en("unmute it"),
                fr("rallume le son"),
                en("turn the sound back on"),
                near("coupe le son", .fr, expected: "mute"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "audio"
        }
    }

    static var setVolume: OperationSpec {
        legacy(.setVolume, in: [.video], .audio, .composition,
               title: t("Volume", "Volume"), summary: t("Louder or quieter, 0-200 %", "Plus fort ou moins fort, 0-200 %")) { s in
            s.coreIn = [.video]
            s.params = [Step.amount(0...200, .percent, .required, doc: "percent; relative ±"), Step.amountMode,
                        Step.clipNumber(doc: "clip, or track with scope selection"), Step.scope(doc: "selection = a sound track")]
            s.triggers = [
                .fr: ["volume", "baisse le son", "monte le son", "plus fort", "moins fort", "la musique à"],
                .en: ["volume", "louder", "quieter", "turn it down", "turn up the music"],
            ]
            s.examples = [
                fr("baisse le son de 20 %", ["amount": -20]),
                fr("monte le volume de la musique à 80 %", ["amountMode": "absolute", "amount": 80, "clipNumber": 1, "scope": "selection"]),
                fr("mets la musique à 30 %", ["amountMode": "absolute", "amount": 30, "clipNumber": 1, "scope": "selection"]),
                en("turn the music down to 30 percent", ["amountMode": "absolute", "amount": 30, "clipNumber": 1, "scope": "selection"]),
                en("lower the volume by 20 percent", ["amount": -20]),
                near("coupe le son du clip 2", .fr, expected: "mute"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "audio"
        }
    }

    static var addMusic: OperationSpec {
        legacy(.addMusic, in: [.video], .audio, .composition,
               title: t("Add sound", "Ajouter du son"), summary: t("Another sound track: music, voice-over", "Une autre piste : musique, voix off")) { s in
            s.coreIn = [.video]
            s.params = [Step.text(max: 60, doc: "what kind: upbeat music"), Step.seconds(doc: "where it starts"),
                        Step.scope(["current", "selection"], doc: "selection replaces the music")]
            s.requires = needs(referenceAsset: .audio)
            s.triggers = [
                .fr: ["ajoute de la musique", "mets une musique", "voix off", "ajoute un son", "bande son", "change la musique"],
                .en: ["add music", "add a song", "voice-over", "add a sound", "soundtrack", "change the music"],
            ]
            s.examples = [
                fr("ajoute de la musique entraînante", ["text": "upbeat"]),
                fr("ajoute une voix off"),
                fr("ajoute un deuxième son à 10 secondes", ["seconds": 10]),
                en("add some calm music", ["text": "calm"]),
                en("add a voice-over"),
                near("enlève la musique", .fr, expected: "removeMusic"),
            ]
            s.verify = [.unverifiable("the user picks the sound before a track is added")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var removeMusic: OperationSpec {
        legacy(.removeMusic, in: [.video], .audio, .composition,
               title: t("Remove sound track", "Enlever la musique"), summary: t("Removes a sound track", "Enlève une piste son")) { s in
            s.params = [Step.clipNumber(doc: "track 1.., -1 last; omit = all")]
            s.triggers = [
                .fr: ["enlève la musique", "supprime la musique", "sans musique", "supprime la piste"],
                .en: ["remove the music", "delete the soundtrack", "no music"],
            ]
            s.examples = [
                fr("enlève la musique"),
                fr("supprime la deuxième piste son", ["clipNumber": 2]),
                en("remove the music"),
                fr("retire la musique de fond"),
                en("delete the second audio track", ["clipNumber": 2]),
                near("baisse la musique", .fr, expected: "setVolume"),
            ]
            s.verify = [.structural(.audioTrackCount, .decreased)]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var moveAudio: OperationSpec {
        legacy(.moveAudio, in: [.video], .audio, .composition,
               title: t("Move sound", "Déplacer le son"), summary: t("Moves a track to a time", "Déplace une piste à un instant")) { s in
            s.params = [Step.clipNumber(doc: "track 1.."), Step.seconds(.required, doc: "new start")]
            s.triggers = [
                .fr: ["décale la musique", "fais commencer la musique", "déplace le son", "la musique commence à"],
                .en: ["move the music", "start the music at", "shift the sound"],
            ]
            s.examples = [
                fr("fais commencer la musique à 5 secondes", ["clipNumber": 1, "seconds": 5]),
                fr("décale la piste 2 à 12 secondes", ["clipNumber": 2, "seconds": 12]),
                en("start the music at 3 seconds", ["clipNumber": 1, "seconds": 3]),
                fr("démarre la musique à 2 secondes", ["clipNumber": 1, "seconds": 2]),
                en("move track 2 to 12 seconds", ["clipNumber": 2, "seconds": 12]),
                near("fais finir la musique avec la vidéo", .fr, expected: "fitMusic"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var fadeAudio: OperationSpec {
        legacy(.fadeAudio, in: [.video], .audio, .composition,
               title: t("Fade sound", "Fondu sonore"), summary: t("Fade-in or fade-out of a track", "Fondu d'entrée ou de sortie d'une piste")) { s in
            s.params = [Step.clipNumber(doc: "track 1.."), Step.amount(0...10, .seconds, doc: "fade length, s"),
                        Step.textChoice(["in", "out"], doc: "omit for both")]
            s.triggers = [
                .fr: ["fondu de la musique", "fondu sonore", "fais un fondu", "fade out", "fondu à la fin"],
                .en: ["fade the music", "fade out", "fade in", "audio fade"],
            ]
            s.examples = [
                fr("fais un fondu de la musique à la fin", ["clipNumber": 1, "text": "out"]),
                fr("fondu sonore de 3 secondes au début", ["clipNumber": 1, "amount": 3, "text": "in"]),
                en("fade out the music", ["clipNumber": 1, "text": "out"]),
                fr("fondu de sortie sur la musique", ["clipNumber": 1, "text": "out"]),
                en("fade in the music over 3 seconds", ["clipNumber": 1, "amount": 3, "text": "in"]),
                near("baisse la musique quand je parle", .fr, expected: "autoDuck"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var autoDuck: OperationSpec {
        legacy(.autoDuck, in: [.video], .audio, .composition,
               title: t("Auto duck", "Atténuation auto"), summary: t("Music dips under the voice", "La musique baisse sous la voix")) { s in
            s.params = [Step.amount(0...0.9, .fraction, doc: "depth 0.3-0.9, 0 off")]
            s.triggers = [
                .fr: ["baisse la musique quand je parle", "atténuation", "ducking", "musique sous la voix"],
                .en: ["duck the music", "ducking", "music under the voice", "lower the music when I talk"],
            ]
            s.examples = [
                fr("baisse la musique quand je parle"),
                fr("atténuation forte de la musique", ["amount": 0.8]),
                en("duck the music under the voice"),
                fr("mets la musique en retrait pendant la voix"),
                en("lower the music when I talk"),
                near("mets la musique à 30 %", .fr, expected: "setVolume"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var syncToBeat: OperationSpec {
        legacy(.syncToBeat, in: [.video], .audio, .geometry,
               title: t("Cut to the beat", "Couper au rythme"), summary: t("Moves cuts onto the music's beat", "Place les coupes sur le temps")) { s in
            s.requires = needs(referenceAsset: .audio, cost: .fast)
            s.triggers = [
                .fr: ["coupe au rythme", "sur le rythme", "sur le beat", "synchronise avec la musique"],
                .en: ["cut to the beat", "sync to the music", "on the beat", "beat sync"],
            ]
            s.examples = [
                fr("coupe au rythme de la musique"),
                fr("synchronise les coupes sur le beat"),
                en("cut to the beat"),
                fr("cale les coupes sur la musique"),
                en("sync the cuts to the music"),
                near("ajuste la musique à la durée", .fr, expected: "fitMusic"),
            ]
            s.verify = [.unverifiable("the beat match is judged by ear")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var fitMusic: OperationSpec {
        legacy(.fitMusic, in: [.video], .audio, .composition,
               title: t("Fit the music", "Ajuster la musique"), summary: t("The song ends with the video", "La musique finit avec la vidéo")) { s in
            s.requires = needs(referenceAsset: .audio, cost: .fast)
            s.triggers = [
                .fr: ["ajuste la musique", "la musique finit avec", "cale la musique", "fin de la musique"],
                .en: ["fit the music", "end the music with the video", "music ends"],
            ]
            s.examples = [
                fr("ajuste la musique à la durée"),
                fr("fais finir la musique avec la vidéo"),
                en("fit the music to the video"),
                fr("adapte la musique à la longueur de la vidéo"),
                en("make the music end with the video"),
                near("coupe au rythme de la musique", .fr, expected: "syncToBeat"),
            ]
            s.verify = [.unverifiable("sound is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }

    static var enhanceVoice: OperationSpec {
        legacy(.enhanceVoice, in: [.video], .audio, .cleanup,
               title: t("Enhance voice", "Voix claire"), summary: t("Removes background noise from speech", "Enlève le bruit autour de la voix")) { s in
            s.params = [Step.scope(["current", "all"], doc: "all clips")]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["isole la voix", "voix plus claire", "améliore la voix", "ma voix", "voix", "enlève le bruit de fond", "le son est pourri", "nettoie le son"],
                .en: ["enhance the voice", "isolate the voice", "my voice", "voice", "remove the background noise", "clean the audio"],
            ]
            s.examples = [
                fr("isole la voix"),
                fr("enlève le bruit de fond", ["scope": "all"]),
                en("clean up the audio"),
                fr("rends la voix plus claire"),
                en("isolate the voice"),
                near("baisse la musique quand je parle", .fr, expected: "autoDuck"),
            ]
            s.verify = [.unverifiable("voice clarity is judged by ear")]
            s.grammar = .owned
            s.uiTool = "audio"
        }
    }
}
