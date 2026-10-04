import Foundation

/// Video magic: captions, speech-based cuts, highlights, reframing, camera moves, tracking.
enum CatalogVideoMagic {
    static var all: [OperationSpec] {
        [autoCaptions, removeCaptions, translateCaptions, removeSilences, removeFillers, cutWords, trackSubject, splitScenes, animateText,
         highlights, speedRamp, punchIns, blurFaces, smartReframe, kenBurns]
    }

    static var autoCaptions: OperationSpec {
        legacy(.autoCaptions, in: [.video], .captions, .text,
               title: t("Captions", "Sous-titres"), summary: t("Subtitles from the speech, or a new style", "Sous-titres tirés de la voix, ou un style")) { s in
            s.coreIn = [.video]
            s.params = [Step.textChoice(values(CaptionStyle.self), doc: "caption style")]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["sous-titres", "sous-titre", "transcris", "karaoké", "légendes automatiques", "sous-titres karaoké"],
                .en: ["captions", "subtitles", "transcribe", "karaoke captions", "auto captions"],
            ]
            s.examples = [
                fr("ajoute des sous-titres"),
                fr("ajoute des sous-titres karaoké", ["text": "karaoke"]),
                fr("passe les sous-titres en style encadré", ["text": "boxed"]),
                en("add captions"),
                para("sous titres", .fr),
                near("mets les sous-titres en haut", .fr, expected: nil),
                en("subtitle the video"),
            ]
            s.verify = [.structural(.captions, .changed)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static var removeCaptions: OperationSpec {
        legacy(.removeCaptions, in: [.video], .captions, .text,
               title: t("Remove captions", "Enlever les sous-titres"), summary: t("Takes the subtitles off", "Retire les sous-titres")) { s in
            s.requires = needs(captions: true)
            s.triggers = [
                .fr: ["enlève les sous-titres", "supprime les sous-titres", "sans sous-titres"],
                .en: ["remove the captions", "delete the subtitles", "no captions"],
            ]
            s.examples = [
                fr("enlève les sous-titres"),
                fr("supprime les sous-titres"),
                en("remove the captions"),
                fr("retire les sous-titres"),
                en("delete the subtitles"),
                near("traduis les sous-titres en anglais", .fr, expected: "translateCaptions"),
            ]
            s.verify = [.structural(.captions, .changed)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static let captionLanguages = ["en", "fr", "es", "de", "it", "pt", "ja", "zh", "ko"]

    static var translateCaptions: OperationSpec {
        legacy(.translateCaptions, in: [.video], .captions, .text,
               title: t("Translate captions", "Traduire les sous-titres"), summary: t("Subtitles in another language", "Sous-titres dans une autre langue")) { s in
            s.params = [Step.textChoice(captionLanguages, .required, doc: "language code")
                .aliases(["anglais": "en", "english": "en", "francais": "fr", "french": "fr", "espagnol": "es", "spanish": "es", "allemand": "de",
                          "german": "de", "italien": "it", "italian": "it", "portugais": "pt", "portuguese": "pt", "japonais": "ja",
                          "japanese": "ja", "chinois": "zh", "chinese": "zh", "coreen": "ko", "korean": "ko"])]
            s.requires = needs(captions: true, cost: .fast)
            s.triggers = [
                .fr: ["traduis les sous-titres", "sous-titres en anglais", "traduction", "en espagnol"],
                .en: ["translate the captions", "captions in English", "translate the subtitles"],
            ]
            s.examples = [
                fr("traduis les sous-titres en anglais", ["text": "en"]),
                fr("mets les sous-titres en espagnol", ["text": "es"]),
                en("translate the captions to French", ["text": "fr"]),
                fr("sous-titres en allemand", ["text": "de"]),
                en("translate the subtitles into Spanish", ["text": "es"]),
                near("enlève les sous-titres", .fr, expected: "removeCaptions"),
            ]
            s.verify = [.structural(.captions, .changed)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static var removeSilences: OperationSpec {
        legacy(.removeSilences, in: [.video], .cut, .geometry,
               title: t("Jump cuts", "Couper les blancs"), summary: t("Removes the pauses in speech", "Enlève les pauses de la voix")) { s in
            s.params = [Step.amount(0.2...0.45, .fraction, doc: "0.2 gentle … 0.45 tight")]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["enlève les blancs", "supprime les blancs", "coupe les blancs", "les blancs", "coupe les silences", "temps morts", "jump cut", "enlève les pauses",
                      "plus rythmé"],
                .en: ["remove the silences", "jump cuts", "cut the pauses", "snappier"],
            ]
            s.examples = [
                fr("enlève les blancs"),
                fr("coupe les silences, serré", ["amount": 0.45]),
                en("remove the silences"),
                fr("supprime les silences"),
                en("cut out the pauses"),
                near("enlève les euh", .fr, expected: "removeFillers"),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static var removeFillers: OperationSpec {
        legacy(.removeFillers, in: [.video], .cut, .geometry,
               title: t("Remove fillers", "Enlever les euh"), summary: t("Cuts the ums and stutters", "Coupe les euh et les hésitations")) { s in
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["enlève les euh", "les hésitations", "les euh", "les heu", "mots parasites"],
                .en: ["remove the ums", "filler words", "the ums", "hesitations"],
            ]
            s.examples = [
                fr("enlève les euh"),
                fr("coupe les hésitations"),
                en("remove the ums"),
                para("enlève les heu", .fr),
                en("cut the uhs and ums"),
                near("coupe les silences", .fr, expected: "removeSilences"),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static var cutWords: OperationSpec {
        legacy(.cutWords, in: [.video], .cut, .geometry,
               title: t("Cut words", "Couper des mots"), summary: t("Cuts where these words are said", "Coupe là où ces mots sont dits")) { s in
            s.params = [Step.text(.required, max: 120, doc: "the exact words"), Step.scope(["current", "all"], doc: "all = every time"),
                        Step.target(doc: "sentence = the whole sentence").offCard]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["coupe le moment où je dis", "enlève le mot", "coupe quand je dis", "supprime la phrase"],
                .en: ["cut where I say", "remove the word", "cut the sentence"],
            ]
            s.examples = [
                fr("coupe le moment où je dis bref", ["text": "bref"]),
                fr("enlève chaque fois que je dis genre", ["text": "genre", "scope": "all"]),
                en("cut where I say basically", ["text": "basically"]),
                fr("enlève le passage où je dis voilà", ["text": "voilà"]),
                en("remove every time I say like", ["text": "like", "scope": "all"]),
                near("enlève les hésitations", .fr, expected: "removeFillers"),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "transcript"
        }
    }

    static var trackSubject: OperationSpec {
        legacy(.trackSubject, in: [.video], .overlays, .composition,
               title: t("Follow subject", "Suivre le sujet"), summary: t("An overlay follows the moving subject", "Un élément suit le sujet qui bouge")) { s in
            s.params = [Step.textChoice(["text", "image", "video", "shape"], doc: "which overlay").keys("overlay"),
                        Step.amount(0...100, .percent, doc: "0 stops following").offCard]
            s.requires = needs(subject: true, cost: .heavy)
            s.triggers = [
                .fr: ["suit le visage", "fais suivre", "suivi", "suit la personne", "suis-le", "colle au sujet"],
                .en: ["follow the subject", "track", "track the subject", "track the person", "tracking", "follow the face", "pin to the person"],
            ]
            s.examples = [
                fr("fais suivre le titre au visage", ["text": "text"]),
                fr("le texte doit suivre la personne", ["text": "text"]),
                en("make the title follow the person", ["text": "text"]),
                para("track the cyclist", .en),
                fr("accroche le texte au visage", ["text": "text"]),
                near("passe en vertical en suivant le sujet", .fr, expected: "smartReframe"),
            ]
            s.verify = [.unverifiable("tracking is judged by eye")]
            s.grammar = .owned
            s.uiTool = "overlay"
        }
    }

    static var splitScenes: OperationSpec {
        legacy(.splitScenes, in: [.video], .cut, .geometry,
               title: t("Split scenes", "Couper aux changements de plan"), summary: t("Cuts wherever the shot changes", "Coupe à chaque changement de plan")) { s in
            s.params = [Step.scope(["current", "all"], doc: "all clips"), Step.amount(0...1, .fraction, doc: "sensitivity").offCard]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["coupe à chaque plan", "détecte les plans", "changements de plan", "découpe les scènes"],
                .en: ["split scenes", "detect the shots", "cut at every shot", "scene detection"],
            ]
            s.examples = [
                fr("coupe à chaque changement de plan", ["scope": "all"]),
                fr("détecte les plans"),
                en("split at every scene change", ["scope": "all"]),
                fr("découpe la vidéo par plans", ["scope": "all"]),
                en("detect the scenes"),
                near("coupe à 5 secondes", .fr, expected: "split"),
            ]
            s.verify = [.structural(.clipCount, .increased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var animateText: OperationSpec {
        legacy(.animateText, in: [.video], .text, .text,
               title: t("Animate title", "Animer le titre"), summary: t("How the title comes on screen", "Comment le titre apparaît")) { s in
            s.params = [Step.textChoice(values(TextAnimation.self) + ["none"], .required, doc: "the animation")]
            s.triggers = [
                .fr: ["anime le titre", "animation du texte", "fais apparaître le titre", "titre qui rebondit"],
                .en: ["animate the title", "text animation", "title pops in"],
            ]
            s.examples = [
                fr("anime le titre en pop", ["text": "pop"]),
                fr("fais monter le titre doucement", ["text": "rise"]),
                en("make the title pop in", ["text": "pop"]),
                fr("révèle le titre de gauche à droite", ["text": "wipe"]),
                en("animate the title with a wipe", ["text": "wipe"]),
                near("fais suivre le titre au visage", .fr, expected: "trackSubject"),
            ]
            s.verify = [.unverifiable("the motion is judged by eye")]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var highlights: OperationSpec {
        legacy(.highlights, in: [.video], .story, .geometry,
               title: t("Highlights", "Résumé"), summary: t("A recap of the best moments", "Un résumé des meilleurs moments")) { s in
            s.params = [Step.seconds(doc: "recap length, 5-300 s")]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["résumé", "fais un résumé", "meilleurs moments", "best of", "version courte"],
                .en: ["recap", "highlights", "best moments", "highlight reel", "short version"],
            ]
            s.examples = [
                fr("fais un résumé de 20 secondes", ["seconds": 20]),
                fr("garde les meilleurs moments"),
                en("make a 20 second recap", ["seconds": 20]),
                fr("garde le meilleur en 30 secondes", ["seconds": 30]),
                en("keep the best moments"),
                near("ne garde que les 10 premières secondes", .fr, expected: "trim"),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var speedRamp: OperationSpec {
        legacy(.speedRamp, in: [.video], .speed, .geometry,
               title: t("Speed ramp", "Rampe de vitesse"), summary: t("Eases into slow motion and back", "Glisse vers le ralenti puis revient")) { s in
            s.params = [Step.amount(0.1...1, .multiplier, doc: "slowest speed, 0.3"), Step.seconds(doc: "around; omit = playhead")]
            s.triggers = [
                .fr: ["rampe de vitesse", "ralenti progressif", "ralentis progressivement", "speed ramp"],
                .en: ["speed ramp", "ramp into slow motion", "slow-mo ramp"],
            ]
            s.examples = [
                fr("fais une rampe de vitesse"),
                fr("ralenti progressif à 6 secondes", ["seconds": 6, "amount": 0.3]),
                en("speed ramp into slow motion", ["amount": 0.3]),
                fr("passe progressivement au ralenti", ["amount": 0.3]),
                en("ramp the speed down at 6 seconds", ["seconds": 6, "amount": 0.3]),
                near("mets tout au ralenti", .fr, expected: "setSpeed"),
            ]
            s.verify = [.structural(.timelineDuration, .increased)]
            s.grammar = .owned
            s.uiTool = "speed"
        }
    }

    static var punchIns: OperationSpec {
        legacy(.punchIns, in: [.video], .motion, .effects,
               title: t("Zoom cuts", "Zooms de coupe"), summary: t("Every other segment framed tighter", "Un segment sur deux cadré plus serré")) { s in
            s.params = [Step.amount(1...1.5, .multiplier, doc: "zoom 1-1.5, 0 removes")]
            s.triggers = [
                .fr: ["zooms de coupe", "punch in", "zoom à chaque coupe", "recadre plus serré une fois sur deux"],
                .en: ["punch ins", "zoom cuts", "punch-in", "zoom on every cut"],
            ]
            s.examples = [
                fr("ajoute des zooms de coupe", ["amount": 1.2]),
                fr("zoom à chaque coupe"),
                en("add punch-ins", ["amount": 1.2]),
                fr("zoome un peu à chaque coupe", ["amount": 1.15]),
                en("zoom in on each cut"),
                near("ajoute un zoom lent", .fr, expected: "kenBurns"),
            ]
            s.verify = [.unverifiable("framing is judged by eye")]
            s.grammar = .owned
            s.uiTool = "motion"
        }
    }

    static var blurFaces: OperationSpec {
        legacy(.blurFaces, in: [.video], .effects, .effects,
               title: t("Blur faces", "Flouter les visages"), summary: t("Every face blurred through the clips", "Tous les visages floutés dans les clips")) { s in
            s.params = [Step.scope(["current", "all"], doc: "all clips"), Step.amount(0...100, .percent, doc: "0 shows them again").offCard]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["floute les visages", "anonymise", "cache les visages", "pixelise les visages"],
                .en: ["blur the faces", "anonymise", "hide the faces", "pixelate faces"],
            ]
            s.examples = [
                fr("floute les visages", ["scope": "all"]),
                fr("anonymise les gens"),
                en("blur all the faces", ["scope": "all"]),
                fr("cache les visages", ["scope": "all"]),
                en("anonymize the people"),
                near("stabilise la vidéo", .fr, expected: "stabilize"),
            ]
            s.verify = [.unverifiable("the blur is judged by eye")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var smartReframe: OperationSpec {
        legacy(.smartReframe, in: [.video], .motion, .geometry,
               title: t("Smart reframe", "Recadrage intelligent"), summary: t("New shape, following the subject", "Nouveau format qui suit le sujet")) { s in
            s.params = [Step.aspect(.required)]
            s.requires = needs(subject: true, cost: .heavy, geometryChange: true)
            s.triggers = [
                .fr: ["passe en vertical", "en vertical", "vertical", "en suivant le sujet", "suis le sujet", "suivre le sujet", "le cadre suit", "format TikTok",
                      "recadre en suivant", "pour les reels"],
                .en: ["make it vertical", "vertical", "follow the subject", "reframe", "for TikTok", "for reels"],
            ]
            s.examples = [
                fr("passe en vertical en suivant le sujet", ["aspect": "ratio9x16"]),
                fr("c'est pour TikTok", ["aspect": "ratio9x16"]),
                en("reframe for reels following the person", ["aspect": "ratio9x16"]),
                para("met la en vertical", .fr, ["aspect": "ratio9x16"]),
                en("make it vertical for TikTok", ["aspect": "ratio9x16"]),
                near("recadre en carré", .fr, expected: "crop"),
            ]
            s.verify = [.structural(.canvasAspect, .equalsParam("aspect"))]
            s.grammar = .owned
            s.uiTool = "frame"
        }
    }

    static var kenBurns: OperationSpec {
        legacy(.kenBurns, in: [.video], .motion, .effects,
               title: t("Ken Burns", "Zoom lent"), summary: t("A slow push-in or drift", "Un zoom ou travelling lent")) { s in
            s.params = [Step.scope(["current", "all"], doc: "all clips"), Step.amount(0...100, .percent, doc: "0 removes it").offCard]
            s.triggers = [
                .fr: ["zoom lent", "zoom avant progressif", "zoom progressif", "travelling lent", "effet Ken Burns", "mouvement de caméra"],
                .en: ["ken burns", "slow zoom", "slow push-in", "gentle zoom", "camera move"],
            ]
            s.examples = [
                fr("ajoute un zoom lent"),
                fr("ajoute un zoom avant progressif sur la personne"),
                fr("effet Ken Burns sur tous les clips", ["scope": "all"]),
                en("add a slow zoom"),
                en("add a Ken Burns effect"),
                near("ajoute des zooms de coupe", .fr, expected: "punchIns"),
            ]
            s.verify = [.unverifiable("the move is judged by eye")]
            s.grammar = .owned
            s.uiTool = "motion"
        }
    }
}
