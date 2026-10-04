import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The R lane's held-out set: utterances written by the wiring lane (E2), apart from the catalog,
/// its triggers and its examples, so the catalog author never writes the test set. Spoken the way
/// people talk to an editor: colloquial French, anglicisms (« mets un lut », « split toning »,
/// « blend mode »), clipped orders, and the speech recogniser's slips (« mais » for « mets »,
/// « lhorizon », « sous titre », missing plurals, « suprime »).
///
/// Each line is `language | utterance | gold`, where gold lists the catalog ids that are a right
/// answer (any one of them on the cards counts). The table is text so the compiler never has to
/// type-check a 300-element literal.
enum HeldOutUtterances {
    struct Utterance: Sendable, Hashable {
        var domain: OpDomain
        var language: OpLanguage
        var text: String
        var gold: Set<String>
    }

    static let photo = """
    fr | mets une petite courbe en S pour le peps | curves
    fr | la courbe en esse un peu plus marquée | curves
    fr | courbe des bleus remonte le milieu | curves
    fr | écrase les noirs avec la courbe | curves levels
    fr | fais une courbe inversée stp | curves
    fr | sur la courbe rouge monte les tons moyens | curves
    fr | delave les noirs façon film avec la courbe | curves
    en | give it a gentle s-curve | curves
    en | pull up the midtones on the red curve | curves
    en | fade the blacks with the tone curve | curves
    en | steeper curve for more punch | curves
    fr | monte le point noir à quinze | levels
    fr | les niveaux blanc à 245 | levels
    fr | règle les niveaux toi-même | levels autoTone
    fr | le point blanc est trop bas corrige | levels
    fr | point noir 8 point blanc 250 | levels
    en | clip the whites a bit with levels | levels
    en | set levels black 12 white 240 | levels
    fr | tonalité auto | autoTone levels autoEnhance
    fr | fais un auto ton | autoTone levels
    fr | équilibre automatiquement les tons | autoTone autoEnhance levels
    en | auto tone please | autoTone levels autoEnhance
    en | let it fix the tones automatically | autoTone autoEnhance levels
    fr | les orange un peu moins saturé | hsl
    fr | rend le ciel plus cyan sans toucher le reste | hsl selectiveAdjust maskAdjust
    fr | baisse la luminance des bleus | hsl
    fr | la teinte des verts vers le jaune | hsl
    fr | les rouges sont trop flashy calme les | hsl
    fr | désature juste les magentas | hsl
    fr | mélangeur de couleurs verts plus sombres | hsl
    fr | TSL sur les jaunes moins de saturation | hsl
    fr | les bleu moins pétant | hsl adjust
    fr | les tons chair plus naturels | hsl
    en | tone down the oranges | hsl
    en | shift the greens toward yellow | hsl
    en | darken the blues in the HSL panel | hsl
    en | desaturate only the purples | hsl
    en | the reds are way too hot | hsl
    fr | étalonne en teal and orange | colorGrade applyLook
    fr | mets du bleu dans les ombres | colorGrade
    fr | des hautes lumières un peu chaudes | colorGrade adjust
    fr | un split toning violet et jaune | colorGrade
    fr | colore les tons moyens en vert | colorGrade
    fr | un étalonnage froid dans les ombres | colorGrade
    fr | mais du orange dans les hautes lumières | colorGrade
    fr | les ombres vers le turquoise | colorGrade
    en | teal shadows please | colorGrade
    en | warm up the highlights with a color grade | colorGrade
    en | split tone it magenta and green | colorGrade
    en | color wheels push the midtones to blue | colorGrade
    fr | mais un lut | lutIntensity applyLook
    fr | le lut à moitié | lutIntensity
    fr | baisse l'intensité de la lut | lutIntensity
    fr | la lut est trop forte | lutIntensity
    fr | lut à 70 pour cent | lutIntensity
    en | LUT at 40 percent | lutIntensity
    en | the LUT is too strong | lutIntensity
    fr | vire la lut | removeLUT
    fr | enlève le lut que j'ai importé | removeLUT
    fr | plus de LUT du tout | removeLUT
    en | get rid of the LUT | removeLUT
    en | drop the lut | removeLUT
    fr | les murs penchent redresse les | perspective
    fr | corrige la déformation verticale | perspective
    fr | les lignes de fuite sont tordues | perspective
    fr | remets l'immeuble droit | perspective
    fr | correction de perspective horizontale | perspective
    fr | la façade a l'air de tomber en arrière | perspective
    en | the building is leaning back fix it | perspective
    en | keystone correction | perspective
    en | make the verticals parallel | perspective
    fr | flou d'objectif derrière avec le chien net | lensFocus blurBackground
    fr | fais la map sur le visage | lensFocus
    fr | ouverture plus grande genre f1.4 | lensFocus
    fr | net sur la fille le reste flou | lensFocus blurBackground
    fr | mise au point au premier plan | lensFocus
    fr | moins de profondeur de champ | lensFocus blurBackground
    en | shallow depth of field on the cup | lensFocus blurBackground
    en | focus on the man in front | lensFocus
    en | more bokeh aperture wide open | lensFocus blurBackground
    fr | le logo à moitié transparent | layerOpacity
    fr | rends le texte plus transparent | layerOpacity
    fr | opacité 30 sur le calque | layerOpacity
    fr | l'opa du titre à 80 | layerOpacity
    en | make that layer see-through | layerOpacity
    en | layer opacity 25 | layerOpacity
    fr | mode de fusion incrustation | layerBlend
    fr | passe le calque en superposition | layerBlend
    fr | le blend mode en screen | layerBlend
    fr | fusion en lumière douce | layerBlend
    fr | mets le calque en éclaircir | layerBlend
    en | blend it as soft light | layerBlend
    en | change the blending to screen | layerBlend
    fr | fais disparaître le calque du texte | layerVisibility
    fr | réaffiche le logo | layerVisibility
    fr | rends le calque invisible | layerVisibility
    en | unhide the title layer | layerVisibility
    en | turn that layer off | layerVisibility
    fr | passe le texte au premier plan | layerOrder
    fr | mets le logo derrière tout | layerOrder
    fr | descends le calque d'un niveau | layerOrder
    fr | le calque tout en haut de la pile | layerOrder
    en | send the shape to the back | layerOrder
    en | bring the logo forward one step | layerOrder
    fr | prends le calque du titre | selectLayer
    fr | duplique ce calque | duplicateLayer
    fr | supprime le calque du logo | deleteLayer
    en | pick the text layer | selectLayer
    en | make a copy of this layer | duplicateLayer
    en | delete the shape layer | deleteLayer
    fr | un peu plus lumineux stp | adjust
    fr | c'est trop sombre là | adjust autoEnhance
    fr | augmente le contrast un chouïa | adjust
    fr | moins de saturation | adjust
    fr | un peu plus chaud stp | adjust
    fr | baisse les hautes lumières | adjust
    fr | débouche les ombres | adjust
    fr | mets la vibrance à fond | adjust
    fr | plus de clarté | adjust
    en | brighter please | adjust
    en | crank the contrast | adjust
    en | a touch cooler | adjust
    en | lift the shadows | adjust
    fr | le ciel plus bleu stp | selectiveAdjust hsl maskAdjust
    fr | éclaircis juste le visage | selectiveAdjust relight maskAdjust
    fr | la mer plus saturée | selectiveAdjust hsl maskAdjust
    en | brighten only the sky | selectiveAdjust maskAdjust
    en | make the grass greener | selectiveAdjust hsl maskAdjust
    fr | améliore la photo toute seule | autoEnhance
    fr | rends la jolie | autoEnhance applyLook
    fr | baguette magique | autoEnhance select
    en | just make it look better | autoEnhance applyLook
    en | auto fix | autoEnhance autoTone
    fr | ajoute de la lumière sur son visage | relight selectiveAdjust maskAdjust
    fr | éclaire le sujet par la gauche | relight
    en | relight the subject from the right | relight
    fr | un look vintage | applyLook
    fr | met le en noir est blanc | applyLook adjust
    fr | style film argentique | applyLook
    fr | un rendu cinéma | applyLook colorGrade
    en | give it a moody film look | applyLook
    en | black and white please | applyLook adjust
    fr | harmonise les couleurs avec l'autre photo | matchColor
    en | match the colours to my reference | matchColor
    fr | change la couleur de la voiture en rouge | recolor
    fr | repeins le mur en bleu | recolor
    en | make the shirt green | recolor
    fr | recadre sur le chien | crop
    fr | coupe les bords | crop autoCrop
    fr | rogne un peu à droite | crop
    en | crop tighter on her face | crop
    fr | format carré pour insta | setAspect crop
    fr | mets en 9/16 pour une story | setAspect crop
    en | make it 4 by 5 | setAspect crop
    fr | cadre la au mieux toi-même | autoCrop crop
    en | auto crop it | autoCrop
    fr | tourne d'un quart de tour | rotate
    fr | pivote à gauche | rotate
    en | rotate it ninety degrees | rotate
    fr | lhorizon est de travers | straighten
    fr | la mer penche un peu | straighten
    en | the horizon is not level | straighten
    fr | retourne la photo comme dans un miroir | flip
    fr | inverse la gauche et la droite | flip
    en | mirror it | flip
    fr | annule la rotation | resetOrientation rotate
    en | reset the rotation and flip | resetOrientation
    fr | enlève la poubelle à gauche | removeObject cleanUp
    fr | efface le mec en arrière plan | removeObject cleanUp
    fr | vire les fils électriques | removeObject cleanUp
    en | remove the car | removeObject
    en | get rid of that sign | removeObject eraseRegion
    fr | nettoie les petites taches | cleanUp removeObject
    fr | enlève les touristes | cleanUp removeObject
    en | clean up the distractions | cleanUp
    fr | efface ce coin en bas à droite | eraseRegion removeObject
    en | erase that patch | eraseRegion
    fr | floute la plaque d'immatriculation | blurObject
    fr | pixellise son visage | blurObject
    en | blur the license plate | blurObject
    fr | déplace le ballon vers la droite | moveObject
    en | move the dog to the left | moveObject
    fr | détoure la personne | removeBackground
    fr | mets la sur fond transparent | removeBackground
    en | cut out the subject | removeBackground
    fr | mets un fond de plage | replaceBackground
    fr | remplace le fond par du blanc | replaceBackground
    en | swap the background for a sunset | replaceBackground
    fr | flou le fond | blurBackground lensFocus
    fr | effet portrait | blurBackground lensFocus
    en | blur behind her | blurBackground lensFocus
    fr | ajoute des nuages dans le ciel | generativeFill
    fr | rajoute un oiseau en haut | generativeFill
    en | put a hot air balloon in the sky | generativeFill
    fr | rajoute du décor sur les côtés | expandCanvas
    fr | étire le cadre et invente le reste | expandCanvas
    en | extend the frame to the right | expandCanvas
    fr | meilleure définition | upscale
    fr | la photo est pixelisée améliore la résolution | upscale
    en | make it 4K | upscale
    fr | enlève le bruit numérique | denoise
    fr | y a du grain réduis le | denoise
    en | too much noise clean it | denoise
    fr | rends ça plus net | sharpen
    fr | accentue un peu la netteté | sharpen
    en | sharpen the details | sharpen
    fr | remplis la colonne total avec 0 | fillCells
    fr | remplis les cases vide avec zéro | fillCells
    fr | vide la ligne 3 | clearCells
    fr | surligne la case du milieu en jaune | highlightCells
    en | fill the empty cells with N/A | fillCells
    fr | écris joyeux anniversaire en haut | addText
    fr | ajoute un gros titre | addText
    en | write summer at the bottom | addText
    fr | mets le texte en rouge | editText
    fr | change le mot soldes par promo | editText
    en | make the title bigger | editText
    fr | supprime le texte que j'ai mis | removeText
    en | delete the caption | removeText
    fr | descends un peu le titre | moveText
    en | move the text to the top | moveText
    fr | mets le texte derrière la personne | textBehind layerOrder
    en | text behind the subject | textBehind
    """

    static let video = """
    fr | raccourcis le début | trim deleteRange
    fr | enlève les 3 premières secondes | trim deleteRange
    en | trim the end of clip 2 | trim
    fr | sépare le clip à cet endroit | split
    fr | fais une coupe à 10 secondes | split
    en | cut it at the playhead | split
    fr | supprime le deuxième plan | deleteClip
    fr | vire le dernier clip | deleteClip
    en | delete clip 3 | deleteClip
    fr | coupe de 5 à 8 secondes | deleteRange
    fr | enlève le passage entre 10 et 12 | deleteRange
    en | remove from 0:20 to 0:25 | deleteRange
    fr | accélère le clip 2 | setSpeed
    fr | mets en x2 | setSpeed
    fr | ralenti à 50 pour cent | setSpeed speedRamp
    en | speed it up a bit | setSpeed
    en | slow mo | setSpeed speedRamp
    fr | passe le clip à l'envers | reverse
    en | make it play backwards | reverse
    fr | arrête l'image 2 secondes | freezeFrame
    en | hold this frame | freezeFrame
    fr | copie ce plan | duplicateClip
    en | duplicate the first clip | duplicateClip
    fr | mets le clip 3 au début | moveClip
    en | move the last clip to the start | moveClip
    fr | sauve cette image en photo | extractFrame
    en | grab a still from here | extractFrame
    fr | un fondu enchaîné entre les deux | addTransition
    fr | mets une transition glissée | addTransition
    en | fade between the clips | addTransition
    fr | enlève les transitions | removeTransition
    en | no transitions | removeTransition
    fr | sa tremble trop | stabilize
    fr | stabilise l'image | stabilize
    en | it's shaky fix it | stabilize
    fr | mets les sous titre automatiquement | autoCaptions
    fr | transcris ce que je dis à l'écran | autoCaptions
    en | subtitle it | autoCaptions
    fr | enlève les sous titres du bas | removeCaptions
    en | remove the subtitles | removeCaptions
    fr | mets les sous titres en anglais | translateCaptions autoCaptions
    en | translate the subtitles to french | translateCaptions
    fr | supprime les blancs quand je parle pas | removeSilences
    fr | fais des jump cuts | removeSilences
    en | jump cut the pauses | removeSilences
    fr | enlève tous les euh | removeFillers
    fr | coupe les heu et les ben | removeFillers
    en | remove the ums and uhs | removeFillers
    fr | coupe la phrase où je dis bonjour | cutWords
    en | cut the word basically | cutWords
    fr | suis le chien avec le cadre | trackSubject smartReframe
    en | track the skateboarder | trackSubject
    fr | découpe en plans automatiquement | splitScenes
    en | detect the scene changes | splitScenes
    fr | fais apparaître le titre en fondu | animateText
    en | make the title animate in | animateText
    fr | garde que les meilleurs moments | highlights
    fr | fais un résumé de 30 secondes | highlights
    en | make a highlight reel | highlights
    fr | rampe de vitesse au milieu | speedRamp
    en | speed ramp into the jump | speedRamp
    fr | zoome sur moi quand je parle | punchIns
    en | add some punch-in zooms | punchIns
    fr | floute les visages des passants | blurFaces
    en | blur everyone's face | blurFaces
    fr | mets en vertical pour tiktok | smartReframe setAspect crop
    en | reframe for reels | smartReframe setAspect
    fr | un zoom lent sur la photo | kenBurns
    en | slow pan and zoom on the stills | kenBurns
    fr | coupe le son du clip 1 | mute
    fr | remets le son du clip | unmute
    fr | le son plus fort | setVolume
    fr | baisse le volume de la musique | setVolume
    en | mute it | mute
    en | turn the volume up | setVolume
    fr | rajoute un son de fond | addMusic
    fr | mets une chanson | addMusic
    fr | vire la musique | removeMusic
    fr | décale la musique à 5 secondes | moveAudio
    fr | fondu sur la musique à la fin | fadeAudio
    fr | la musique couvre ma voix | autoDuck setVolume
    fr | cale les coupes sur le rythme | syncToBeat
    fr | ajuste la musique à la durée de la vidéo | fitMusic
    fr | améliore ma voix | enhanceVoice
    fr | on entend mal la voix y a du bruit | enhanceVoice denoise
    en | put some music under it | addMusic
    en | fade the music out | fadeAudio
    en | lower the music by itself when I talk | autoDuck
    en | cut on the beat | syncToBeat
    en | make the song fit the video | fitMusic
    en | clean up my voice | enhanceVoice
    fr | va à la seconde 10 | seek
    en | jump to the end | seek
    fr | la vidéo plus lumineuse | adjust
    fr | étalonnage chaud pour toute la vidéo | applyLook adjust
    fr | recadre la vidéo en carré | setAspect crop
    fr | tourne la vidéo | rotate
    fr | l'horizon penche dans la vidéo | straighten rotate
    fr | enlève la personne derrière | removeObject
    fr | floute le fond de la vidéo | blurBackground
    fr | écris un titre au début | addText
    fr | change le texte du titre | editText
    en | warmer colors | adjust
    en | add a title card | addText
    en | mirror the video | flip
    """

    static let pdf = """
    fr | montre moi la page 3 | goToPage
    fr | passe à la page suivante | goToPage
    fr | retourne au début du document | goToPage
    fr | va page dix | goToPage
    fr | supprime la dernière page | deletePage
    fr | vire la page blanche | deletePage
    fr | suprime la page 4 | deletePage
    fr | la page 2 est à l'envers | rotatePage
    fr | pivote la page de 90 degrés | rotatePage
    fr | mets la page 5 en premier | movePage
    fr | déplace cette page à la fin | movePage
    fr | inverse les pages 2 et 3 | movePage
    fr | fais un double de la page 1 | duplicatePage
    fr | insère une page blanche après la 2 | insertBlankPage
    fr | rajoute une page vierge | insertBlankPage
    fr | exporte juste la page 3 | extractPage
    fr | fais un pdf avec seulement cette page | extractPage
    fr | surligne le montant en jaune | highlightText
    fr | stabilo sur le nom du client | highlightText
    fr | souligne l'adresse | underlineText
    fr | trace un trait sous la date | underlineText
    fr | caviarde l'IBAN | redactText
    fr | masque mon adresse en noir | redactText
    fr | cache le numéro de téléphone définitivement | redactText
    fr | trouve le mot contrat | findText
    fr | où est écrit le total | findText
    fr | cherche facture | findText
    fr | remplace Dupont par Martin | replaceText
    fr | corrige l'année 2023 en 2024 | replaceText
    fr | signe en bas de la page | addSignature
    fr | appose ma signature à côté de la date | addSignature
    fr | mets des numéros de page en bas | addPageNumbers
    fr | pagine le document | addPageNumbers
    fr | fusionne le avec un autre pdf | mergeDocument
    fr | ajoute un autre fichier à la fin | mergeDocument
    fr | écris approuvé en haut de la page | addText
    fr | enlève la note que j'ai écrite | removeText
    en | go to page 7 | goToPage
    en | show the last page | goToPage
    en | delete this page | deletePage
    en | rotate page 1 clockwise | rotatePage
    en | move page 4 to the front | movePage
    en | duplicate the cover page | duplicatePage
    en | insert an empty page before page 3 | insertBlankPage
    en | save page 2 as its own pdf | extractPage
    en | highlight the due date | highlightText
    en | underline the title | underlineText
    en | black out the account number | redactText
    en | where does it say invoice | findText
    en | change draft to final | replaceText
    en | sign it at the bottom | addSignature
    en | add page numbers in the footer | addPageNumbers
    en | combine it with another PDF | mergeDocument
    en | add a note saying approved | addText
    """

    /// W2 (masks and AI selection, §8.10): written before the six operations' examples, by the lane that wires
    /// them, the way people say it to the editor, with the recogniser's slips (« selectionne la tace bleu »,
    /// « assombri le ba »). maskAdjust is on the photo cards; the selection operations must be retrieved.
    static let photoW2 = """
    fr | selectionne la tace bleu | select
    fr | assombri le ba | maskAdjust
    fr | fonce un peu le haut de la photo | maskAdjust
    fr | éclaircis seulement son visage | maskAdjust selectiveAdjust
    fr | rends le ciel plus bleu et plus dense | maskAdjust selectiveAdjust
    fr | un peu plus de peps sur le sujet | maskAdjust
    fr | baisse l'expo du ciel | maskAdjust selectiveAdjust
    fr | réchauffe uniquement la peau | maskAdjust selectiveAdjust
    fr | refroidis l'arrière plan | maskAdjust
    fr | assombris les coins de la photo | maskAdjust adjust
    fr | remonte les ombres du premier plan | maskAdjust
    fr | plus de clarté sur les montagnes | maskAdjust
    fr | éclaire la personne de gauche | maskAdjust
    fr | désature le fond | maskAdjust
    fr | mets un dégradé sombre en haut | maskAdjust
    fr | fais un filtre radial sur le visage | maskAdjust
    fr | réduis la saturation des verts dans le fond | maskAdjust hsl
    fr | ajoute du contraste au premier plan | maskAdjust
    fr | assombri le ciel un peu | maskAdjust selectiveAdjust
    fr | inverse le masque du ciel | maskEdit
    fr | adoucis les bords du masque | maskEdit
    fr | agrandis un peu le masque | maskEdit
    fr | ajoute le chien au masque | maskEdit
    fr | retire le visage du masque | maskEdit
    fr | le masque déborde rétrécis le | maskEdit
    fr | cache le masque 2 | maskEdit
    fr | renomme le masque en ciel du soir | maskEdit
    fr | baisse l'opacité du masque à 50 | maskEdit
    fr | montre moi le masque | maskEdit
    fr | supprime le masque du ciel | maskDelete
    fr | vire tous les masques | maskDelete
    fr | efface le dernier masque | maskDelete
    fr | sélectionne la personne au milieu | select
    fr | prends juste le ciel | select maskAdjust
    fr | prends tout ce qui est rouge | select
    fr | selectionne larriere plan stp | select
    fr | sélectionne les gens | select
    fr | sélectionne le chat | select
    fr | ajoute le chien à la sélection | select
    fr | enlève le ciel de la sélection | select
    fr | baguette magique sur le mur | select
    fr | choisis la zone claire | select
    fr | sélectionne la tasse à café | select
    fr | agrandis la sélection de 20 pixels | selectionModify
    fr | contracte la sélection | selectionModify
    fr | adoucis le contour de la sélection | selectionModify
    fr | désélectionne tout | selectionModify
    fr | affine le contour des cheveux | selectionModify
    fr | inverse ma sélection | selectionModify
    fr | lisse un peu la sélection | selectionModify
    fr | supprime ce qui est sélectionné | selectionApply
    fr | floute la zone sélectionnée | selectionApply
    fr | remplis la sélection en noir | selectionApply
    fr | change la couleur de la sélection en rouge | selectionApply
    fr | détoure ce que j'ai sélectionné | selectionApply
    fr | éclaircis un peu la sélection | selectionApply maskAdjust
    fr | remplace la sélection par des fleurs | selectionApply
    fr | fais un masque avec la sélection | selectionApply
    en | darken the top of the picture | maskAdjust
    en | brighten just her face | maskAdjust selectiveAdjust
    en | make the sky a deeper blue | maskAdjust selectiveAdjust
    en | warm up the foreground | maskAdjust
    en | cool down the background only | maskAdjust
    en | add a graduated filter at the bottom | maskAdjust
    en | radial filter on the subject | maskAdjust
    en | more clarity on the mountains | maskAdjust
    en | invert the sky mask | maskEdit
    en | feather the mask more | maskEdit
    en | add the dog to the mask | maskEdit
    en | hide mask 2 | maskEdit
    en | delete that mask | maskDelete
    en | get rid of all the masks | maskDelete
    en | select the blue mug | select
    en | select everything that's green | select
    en | pick the person on the left | select
    en | add the sky to my selection | select
    en | grow the selection by 10 pixels | selectionModify
    en | soften the selection edge | selectionModify
    en | deselect everything | selectionModify
    en | refine the hair edge | selectionModify
    en | fill the selection with white | selectionApply
    en | blur what I selected | selectionApply
    en | erase what's selected | selectionApply
    en | cut out what's selected | selectionApply
    """

    static let all: [Utterance] = parse(photo, .photo) + parse(photoW2, .photo) + parse(video, .video) + parse(pdf, .pdf)

    static func parse(_ table: String, _ domain: OpDomain) -> [Utterance] {
        table.split(separator: "\n").compactMap { line -> Utterance? in
            let fields = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, let language = OpLanguage(rawValue: fields[0]) else { return nil }
            return Utterance(domain: domain, language: language, text: fields[1], gold: Set(fields[2].split(separator: " ").map(String.init)))
        }
    }

    /// The set as the R lane reads it.
    static var retrievalCases: [RetrievalLaneTests.RetrievalCase] {
        all.map { RetrievalLaneTests.RetrievalCase(text: $0.text, domain: $0.domain, language: $0.language, gold: $0.gold) }
    }
}

/// The fixture's own contract: its size and mix, gold ids the catalog has in that domain, and no
/// utterance copied from a catalog trigger or example.
final class HeldOutUtterancesTests: XCTestCase {
    func testTheSetHasThePlannedSizeAndMix() {
        let all = HeldOutUtterances.all
        XCTAssertGreaterThanOrEqual(all.count, 300)
        XCTAssertGreaterThanOrEqual(all.filter { $0.domain == .photo }.count, 160)
        XCTAssertGreaterThanOrEqual(all.filter { $0.domain == .video }.count, 90)
        XCTAssertGreaterThanOrEqual(all.filter { $0.domain == .pdf }.count, 50)
        XCTAssertGreaterThanOrEqual(all.filter { $0.language == .fr }.count, 200)
        XCTAssertGreaterThanOrEqual(all.filter { $0.language == .en }.count, 100)
        XCTAssertEqual(Set(all.map { $0.text.lowercased() }).count, all.count, "no duplicates")
    }

    /// W2 (§8.10): at least 80 mask and selection utterances, 55 French and 25 English, the slips included.
    func testTheW2BlockHasItsSizeAndMix() {
        let w2 = HeldOutUtterances.parse(HeldOutUtterances.photoW2, .photo)
        XCTAssertGreaterThanOrEqual(w2.count, 80)
        XCTAssertGreaterThanOrEqual(w2.filter { $0.language == .fr }.count, 55)
        XCTAssertGreaterThanOrEqual(w2.filter { $0.language == .en }.count, 25)
        for slip in ["selectionne la tace bleu", "assombri le ba"] { XCTAssertTrue(w2.contains { $0.text == slip }, slip) }
        let ops: Set<String> = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"]
        XCTAssertEqual(Set(w2.flatMap(\.gold)).intersection(ops), ops, "every W2 operation is asked for")
    }

    func testEveryGoldIsACatalogOperationOfItsDomain() throws {
        let catalog = OperationCatalog.shared
        try XCTSkipIf(catalog.specs.isEmpty, "the catalog has no entries yet")
        for utterance in HeldOutUtterances.all {
            XCTAssertFalse(utterance.gold.isEmpty, utterance.text)
            for id in utterance.gold {
                XCTAssertTrue(catalog.spec(OpID(id))?.domains.contains(utterance.domain) ?? false, "\(id) for « \(utterance.text) »")
            }
        }
    }

    func testNothingIsCopiedFromTheCatalog() {
        func folded(_ text: String) -> String { TextFolding.tokens(text).joined(separator: " ") }
        var seen = Set<String>()
        for spec in OperationCatalog.shared.specs {
            for example in spec.examples { seen.insert(folded(example.say)) }
            for phrases in spec.triggers.values { for phrase in phrases { seen.insert(folded(phrase)) } }
        }
        let copied = HeldOutUtterances.all.filter { seen.contains(folded($0.text)) }.map(\.text)
        XCTAssertEqual(copied, [])
    }
}

extension HeldOutUtterancesTests {
    /// The R lane's numbers on this set (core + 8 for the 4B, core + 5 for the 2B), printed for the
    /// report. The plan's targets (98/98/99 % and 95/95/97 %) are the R lane's gate, enforced by
    /// RetrievalLaneTests.testHeldOutRecallMeetsTheTargets.
    func testRecallIsPrintedForTheReport() {
        let recall = RetrievalLaneTests.recall(HeldOutUtterances.retrievalCases)
        for domain in OpDomain.allCases {
            let lane = recall[domain] ?? RetrievalLaneTests.Recall()
            print("HELDOUT \(domain) n=\(lane.total) @8=\(lane.at8) @5=\(lane.at5) misses=\(lane.misses)")
        }
    }
}
