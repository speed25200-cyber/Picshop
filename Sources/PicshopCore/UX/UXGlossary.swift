import Foundation

/// One word of the UX 2.0 glossary (ux-spec §5.2): its French and English labels, and the pro names and synonyms
/// that help and search know it by (never shown as a label).
public struct UXTerm: Sendable, Hashable, Identifiable {
    /// "light", "removeBackground", "historyMenu".
    public var id: String
    /// The French label (UI copy is French-first).
    public var fr: String
    public var en: String
    /// Pro names and synonyms, for help and search only (« Fluidité » for Remodeler).
    public var synonyms: [String]

    public init(_ id: String, fr: String, en: String, synonyms: [String] = []) {
        self.id = id
        self.fr = fr
        self.en = en
        self.synonyms = synonyms
    }

    /// The label in the interface's language.
    public func text(french: Bool) -> String { french ? fr : en }
}

/// The glossary: one meaning per word (§5.1 rule 3). Bars, strips, panel titles, context bars and the document
/// menu take their labels from here through term ids (ToolLayout), so a word never means two things.
/// UXGlossaryTests checks that no French word maps to two English ones, that ids are unique, and the length rule.
/// U1 owns this file; lanes ask for new terms.
public enum UXGlossary {
    /// The term with this id, nil when there is none.
    public static func term(_ id: String) -> UXTerm? { index[id] }

    /// The label of a term in the interface's language; the id itself when the term is missing (a test fails first).
    public static func text(_ id: String, french: Bool) -> String {
        index[id]?.text(french: french) ?? id
    }

    /// Terms whose label or synonym contains the query, accents and case ignored (« lumi » finds Lumière and
    /// Luminosité; « liquify » finds Remodeler). Labels first, then synonyms; glossary order within each.
    public static func matches(_ query: String) -> [UXTerm] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        let byLabel = terms.filter { fold($0.fr).contains(needle) || fold($0.en).contains(needle) }
        let labelIDs = Set(byLabel.map(\.id))
        let bySynonym = terms.filter { term in !labelIDs.contains(term.id) && term.synonyms.contains { fold($0).contains(needle) } }
        return byLabel + bySynonym
    }

    /// Lowercased, without accents, for search.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words banned as labels on user surfaces (§5.3), checked by UXGlossaryTests against every label and by
    /// Scripts/lint-copy.py (U5) against the catalog. Scoped bans (« Hautes lumières » in video Magie, « Seuil » in
    /// the colour pack) live in the lint, not here.
    public static let banned: [String] = [
        "Précis", "Gomme", "Densité", "Fluidité", "Réglages avancés", "Réglages d'export", "Couper ici", "Couper le son",
        "Curseur", "Ripple", "Roll", "Slip", "Slide", "Sonie", "Accélération", "Retiming", "Isohélie", "Masquage",
        "Contour progressif", "Écrêtage", "Calque par copier", "Tampon des calques visibles", "Roues", "Cadre", "Caviarder",
        "Terminé", "Pression du doigt", "Cerveau", "cerveau local", "Qwen", "tok/s", "KV", "Commandes intégrées", "orbe",
    ]

    private static let index: [String: UXTerm] = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: - The terms

    public static let terms: [UXTerm] = general + navigation + photoCategories + magic + adjust + filters + crop + retouch + text
        + selection + layers + contextItems

    /// General words (§5.2 « General and navigation »).
    static let general: [UXTerm] = [
        UXTerm("projects", fr: "Projets", en: "Projects", synonyms: ["bibliothèque", "library"]),
        UXTerm("create", fr: "Créer", en: "Create", synonyms: ["nouveau", "new"]),
        UXTerm("photo", fr: "Photo", en: "Photo"),
        UXTerm("video", fr: "Vidéo", en: "Video"),
        UXTerm("pdf", fr: "PDF", en: "PDF"),
        UXTerm("scan", fr: "Scanner", en: "Scan", synonyms: ["appareil photo de documents", "document camera"]),
        UXTerm("magicMovie", fr: "Film magique", en: "Magic Movie", synonyms: ["montage automatique"]),
        UXTerm("batch", fr: "Lot", en: "Batch", synonyms: ["traitement par lot", "batch processing"]),
        UXTerm("search", fr: "Rechercher", en: "Search"),
        UXTerm("selectMode", fr: "Sélectionner", en: "Select"),
        UXTerm("share", fr: "Partager", en: "Share"),
        UXTerm("export", fr: "Exporter", en: "Export"),
        UXTerm("saveToPhotos", fr: "Enregistrer dans Photos", en: "Save to Photos"),
        UXTerm("saveToFiles", fr: "Enregistrer dans Fichiers", en: "Save to Files"),
        UXTerm("rename", fr: "Renommer", en: "Rename"),
        UXTerm("duplicate", fr: "Dupliquer", en: "Duplicate"),
        UXTerm("info", fr: "Infos", en: "Info"),
        UXTerm("delete", fr: "Supprimer", en: "Delete"),
        UXTerm("recentlyDeleted", fr: "Supprimés récemment", en: "Recently Deleted", synonyms: ["corbeille", "trash"]),
        UXTerm("recover", fr: "Récupérer", en: "Recover", synonyms: ["restaurer", "restore"]),
        UXTerm("savedInPicShop", fr: "Enregistré dans PicShop", en: "Saved in PicShop", synonyms: ["sauvegarde automatique"]),
        UXTerm("saved", fr: "Enregistré", en: "Saved"),
        UXTerm("saving", fr: "Enregistrement…", en: "Saving…"),
        UXTerm("edited", fr: "Modifié", en: "Edited"),
        UXTerm("notExported", fr: "Non exporté", en: "Not exported"),
        UXTerm("cancel", fr: "Annuler", en: "Cancel"),
        UXTerm("discardChanges", fr: "Abandonner les modifications", en: "Discard Changes"),
        UXTerm("keepEditing", fr: "Continuer", en: "Keep Editing"),
        UXTerm("dismiss", fr: "Ignorer", en: "Dismiss"),
        UXTerm("ok", fr: "OK", en: "Done", synonyms: ["terminé"]),
        UXTerm("undo", fr: "Annuler la modification", en: "Undo", synonyms: ["défaire"]),
        UXTerm("redo", fr: "Rétablir", en: "Redo"),
        UXTerm("history", fr: "Historique", en: "History"),
        UXTerm("revert", fr: "Revenir à l'original", en: "Revert to Original"),
        UXTerm("before", fr: "Avant", en: "Before", synonyms: ["comparer", "original", "avant/après", "before/after", "compare"]),
        UXTerm("exportOptions", fr: "Options d'export", en: "Export Options"),
        UXTerm("reset", fr: "Réinitialiser", en: "Reset"),
        UXTerm("helpAndTips", fr: "Aide et astuces", en: "Help & Tips"),
        UXTerm("help", fr: "Aide", en: "Help"),
        UXTerm("settings", fr: "Réglages", en: "Settings", synonyms: ["préférences", "preferences"]),
        UXTerm("aiFeatures", fr: "Fonctions IA", en: "AI Features", synonyms: ["modèles", "models"]),
        UXTerm("activity", fr: "Activité", en: "Activity"),
        UXTerm("close", fr: "Fermer", en: "Close"),
        UXTerm("retry", fr: "Réessayer", en: "Retry"),
        UXTerm("later", fr: "Plus tard", en: "Later"),
        UXTerm("options", fr: "Options", en: "Options"),
        UXTerm("more", fr: "Plus", en: "More"),
        UXTerm("deselect", fr: "Désélectionner", en: "Deselect"),
        UXTerm("apply", fr: "Appliquer", en: "Apply"),
        UXTerm("suggestedBadge", fr: "Suggéré", en: "Suggested"),
        UXTerm("auto", fr: "Auto", en: "Auto"),
        UXTerm("document", fr: "Document", en: "Document"),
    ]

    /// The editor frame: top bar, document menu, Affichage.
    static let navigation: [UXTerm] = [
        UXTerm("historyMenu", fr: "Historique…", en: "History…"),
        UXTerm("allTools", fr: "Tous les outils…", en: "All Tools…", synonyms: ["outils", "tools"]),
        UXTerm("editorHelp", fr: "Aide de l'éditeur", en: "Editor Help"),
        UXTerm("voiceSettings", fr: "Réglages de la voix…", en: "Voice Settings…"),
        UXTerm("view", fr: "Affichage", en: "View"),
        UXTerm("fit", fr: "Tout voir", en: "Fit", synonyms: ["ajuster à l'écran"]),
        UXTerm("zoom100", fr: "100\u{00A0}%", en: "100%", synonyms: ["pixels réels", "actual pixels"]),
        UXTerm("zoom200", fr: "200\u{00A0}%", en: "200%"),
        UXTerm("sideBySide", fr: "Avant/après côte à côte", en: "Before and After Side by Side", synonyms: ["split"]),
        UXTerm("histogram", fr: "Histogramme", en: "Histogram"),
        UXTerm("grid", fr: "Grille", en: "Grid", synonyms: ["tiers", "nombre d'or", "overlays"]),
        UXTerm("transparency", fr: "Transparence", en: "Transparency", synonyms: ["damier", "checkerboard"]),
        UXTerm("imageSizeMenu", fr: "Taille de l'image…", en: "Image Size…", synonyms: ["taille et résolution", "rééchantillonner", "resample"]),
        UXTerm("copyEdits", fr: "Copier les retouches", en: "Copy Edits"),
        UXTerm("pasteEdits", fr: "Coller les retouches", en: "Paste Edits"),
        UXTerm("savePreset", fr: "Enregistrer comme préréglage", en: "Save as Preset"),
        UXTerm("actionsMenu", fr: "Actions…", en: "Actions…", synonyms: ["macros", "scripts"]),
    ]

    /// The photo categories (§3.5.1) and the « Calques » pill.
    static let photoCategories: [UXTerm] = [
        UXTerm("magic", fr: "Magie", en: "Magic", synonyms: ["IA", "AI", "actions en un geste"]),
        UXTerm("adjust", fr: "Ajuster", en: "Adjust", synonyms: ["réglages photos", "develop", "développement"]),
        UXTerm("filters", fr: "Filtres", en: "Filters", synonyms: ["looks", "presets", "préréglages"]),
        UXTerm("crop", fr: "Recadrer", en: "Crop", synonyms: ["cadrer", "rogner"]),
        UXTerm("retouch", fr: "Retoucher", en: "Retouch"),
        UXTerm("text", fr: "Texte", en: "Text", synonyms: ["légende", "titre", "caption"]),
        UXTerm("selection", fr: "Sélection", en: "Select", synonyms: ["sélection et masques", "masques", "masks"]),
        UXTerm("layers", fr: "Calques", en: "Layers"),
    ]

    /// Magie's actions (§3.5.3).
    static let magic: [UXTerm] = [
        UXTerm("enhance", fr: "Améliorer", en: "Enhance", synonyms: ["auto", "amélioration automatique"]),
        UXTerm("removePeople", fr: "Effacer les passants", en: "Remove People", synonyms: ["nettoyer", "clean up"]),
        UXTerm("removeBackground", fr: "Supprimer l'arrière-plan", en: "Remove Background", synonyms: ["détourer le sujet", "select subject", "fond"]),
        UXTerm("backgroundBlur", fr: "Flou d'arrière-plan", en: "Background Blur", synonyms: ["mode portrait", "bokeh"]),
        UXTerm("autoPortrait", fr: "Portrait auto", en: "Auto Portrait", synonyms: ["retouche portrait"]),
        UXTerm("sunsetSky", fr: "Ciel couchant", en: "Sunset Sky", synonyms: ["remplacer le ciel", "sky replacement"]),
        UXTerm("relight", fr: "Rééclairer", en: "Relight"),
        UXTerm("matchColors", fr: "Assortir les couleurs", en: "Match Colors", synonyms: ["match color"]),
        UXTerm("expand", fr: "Élargir", en: "Expand", synonyms: ["generative expand", "outpainting", "agrandir la scène"]),
        UXTerm("upscale2x", fr: "Agrandir ×2", en: "Upscale ×2", synonyms: ["super resolution", "agrandissement"]),
        UXTerm("textBehind", fr: "Texte derrière", en: "Text Behind"),
        UXTerm("recipes", fr: "Recettes", en: "Recipes", synonyms: ["post instagram", "photo produit"]),
    ]

    /// Ajuster's tools and their rings (§3.5.4).
    static let adjust: [UXTerm] = [
        UXTerm("light", fr: "Lumière", en: "Light", synonyms: ["basic", "tons", "exposition"]),
        UXTerm("brightness", fr: "Luminosité", en: "Brightness", synonyms: ["plus lumineux", "éclaircir"]),
        UXTerm("exposure", fr: "Exposition", en: "Exposure"),
        UXTerm("contrast", fr: "Contraste", en: "Contrast"),
        UXTerm("highlights", fr: "Hautes lumières", en: "Highlights"),
        UXTerm("shadows", fr: "Ombres", en: "Shadows"),
        UXTerm("whites", fr: "Blancs", en: "Whites"),
        UXTerm("blacks", fr: "Noirs", en: "Blacks"),
        UXTerm("color", fr: "Couleur", en: "Color"),
        UXTerm("whiteBalance", fr: "Balance des blancs", en: "White Balance", synonyms: ["WB"]),
        UXTerm("temperature", fr: "Température", en: "Temperature", synonyms: ["chaleur", "warmth"]),
        UXTerm("tint", fr: "Nuance", en: "Tint", synonyms: ["teinte (Lightroom)"]),
        UXTerm("eyedropper", fr: "Pipette", en: "Eyedropper"),
        UXTerm("saturation", fr: "Saturation", en: "Saturation"),
        UXTerm("vibrance", fr: "Vibrance", en: "Vibrance"),
        UXTerm("skinTone", fr: "Teint de peau", en: "Skin Tone"),
        UXTerm("hueShift", fr: "Décalage de teinte", en: "Hue Shift"),
        UXTerm("hsl", fr: "TSL", en: "HSL", synonyms: ["mélangeur", "teinte saturation luminance"]),
        UXTerm("colorGrading", fr: "Étalonnage", en: "Color Grading", synonyms: ["roues chromatiques", "color wheels"]),
        UXTerm("effects", fr: "Effets", en: "Effects"),
        UXTerm("clarity", fr: "Clarté", en: "Clarity"),
        UXTerm("texture", fr: "Texture", en: "Texture"),
        UXTerm("dehaze", fr: "Correction du voile", en: "Dehaze", synonyms: ["voile"]),
        UXTerm("vignette", fr: "Vignette", en: "Vignette"),
        UXTerm("grain", fr: "Grain", en: "Grain"),
        UXTerm("fade", fr: "Fondu", en: "Fade"),
        UXTerm("detail", fr: "Détail", en: "Detail"),
        UXTerm("sharpening", fr: "Netteté", en: "Sharpening", synonyms: ["accentuation", "sharpen"]),
        UXTerm("noise", fr: "Bruit", en: "Noise", synonyms: ["réduction du bruit", "noise reduction"]),
        UXTerm("colorNoise", fr: "Bruit de couleur", en: "Color Noise"),
        UXTerm("curves", fr: "Courbes", en: "Curves"),
        UXTerm("levels", fr: "Niveaux", en: "Levels"),
        UXTerm("showClipping", fr: "Montrer les tons perdus", en: "Show Clipping", synonyms: ["écrêtage", "clipping"]),
        UXTerm("targetedAdjustment", fr: "Ajustement ciblé", en: "Targeted Adjustment", synonyms: ["TAT"]),
        UXTerm("blur", fr: "Flou", en: "Blur", synonyms: ["flou d'objectif", "lens blur", "profondeur de champ"]),
        UXTerm("aperture", fr: "Ouverture", en: "Aperture"),
    ]

    /// Filtres (§3.5.5).
    static let filters: [UXTerm] = [
        UXTerm("suggested", fr: "Suggérés", en: "For You"),
        UXTerm("allFilters", fr: "Tous", en: "All Filters"),
        UXTerm("portrait", fr: "Portrait", en: "Portrait"),
        UXTerm("landscape", fr: "Paysage", en: "Landscape"),
        UXTerm("blackAndWhite", fr: "Noir et blanc", en: "Black & White", synonyms: ["N&B", "monochrome"]),
        UXTerm("myPresets", fr: "Mes préréglages", en: "My Presets", synonyms: ["presets"]),
        UXTerm("lut", fr: "LUT", en: "LUT", synonyms: [".cube"]),
        UXTerm("intensity", fr: "Intensité", en: "Intensity"),
        UXTerm("none", fr: "Aucun", en: "None"),
    ]

    /// Recadrer (§3.5.6).
    static let crop: [UXTerm] = [
        UXTerm("format", fr: "Format", en: "Aspect", synonyms: ["instagram", "story", "post", "réseaux", "youtube", "ratio"]),
        UXTerm("straighten", fr: "Redresser", en: "Straighten", synonyms: ["horizon", "niveau"]),
        UXTerm("perspective", fr: "Perspective", en: "Perspective", synonyms: ["upright", "géométrie"]),
        UXTerm("original", fr: "Original", en: "Original"),
        UXTerm("square", fr: "Carré", en: "Square"),
        UXTerm("post", fr: "Post", en: "Post"),
        UXTerm("portraitPost", fr: "Post portrait", en: "Portrait post"),
        UXTerm("story", fr: "Story", en: "Story", synonyms: ["tiktok", "reels"]),
        UXTerm("youtube", fr: "YouTube", en: "YouTube"),
        UXTerm("free", fr: "Libre", en: "Free"),
        UXTerm("rotate", fr: "Pivoter", en: "Rotate"),
        UXTerm("flip", fr: "Retourner", en: "Flip", synonyms: ["miroir", "mirror"]),
        UXTerm("bestCrop", fr: "Cadrage idéal", en: "Best Crop"),
        UXTerm("fillEdges", fr: "Remplir les bords (IA)", en: "Fill Edges (AI)"),
    ]

    /// Retoucher (§3.5.7).
    static let retouch: [UXTerm] = [
        UXTerm("remove", fr: "Retirer", en: "Remove", synonyms: ["gomme", "correcteur", "tampon", "clean up", "effacer un objet"]),
        UXTerm("heal", fr: "Corriger", en: "Heal", synonyms: ["correcteur localisé", "healing"]),
        UXTerm("clone", fr: "Cloner", en: "Clone", synonyms: ["tampon de duplication", "clone stamp"]),
        UXTerm("source", fr: "Source", en: "Source", synonyms: ["alt-clic"]),
        UXTerm("brushes", fr: "Pinceaux", en: "Brushes", synonyms: ["densité", "dodge", "burn", "éponge"]),
        UXTerm("paint", fr: "Peindre", en: "Paint"),
        UXTerm("eraseMode", fr: "Gommer", en: "Erase Paint"),
        UXTerm("reshape", fr: "Remodeler", en: "Reshape", synonyms: ["fluidité", "liquify"]),
        UXTerm("cutout", fr: "Détourer", en: "Cut Out", synonyms: ["détourage"]),
        UXTerm("size", fr: "Taille", en: "Size"),
    ]

    /// Texte et Formes (§3.5.8).
    static let text: [UXTerm] = [
        UXTerm("shapes", fr: "Formes", en: "Shapes"),
        UXTerm("addText", fr: "Ajouter un texte", en: "Add Text"),
        UXTerm("font", fr: "Police", en: "Font"),
        UXTerm("style", fr: "Style", en: "Style"),
        UXTerm("alignment", fr: "Alignement", en: "Alignment"),
        UXTerm("edit", fr: "Modifier", en: "Edit"),
    ]

    /// Sélection (§3.5.9).
    static let selection: [UXTerm] = [
        UXTerm("subject", fr: "Sujet", en: "Subject"),
        UXTerm("sky", fr: "Ciel", en: "Sky"),
        UXTerm("background", fr: "Arrière-plan", en: "Background"),
        UXTerm("person", fr: "Personne", en: "Person"),
        UXTerm("object", fr: "Objet", en: "Object"),
        UXTerm("brush", fr: "Pinceau", en: "Brush", synonyms: ["sélection rapide", "quick selection"]),
        UXTerm("linear", fr: "Dégradé", en: "Linear", synonyms: ["filtre gradué"]),
        UXTerm("radial", fr: "Radial", en: "Radial"),
        UXTerm("byColor", fr: "Par couleur", en: "By Color", synonyms: ["plage de couleurs", "color range"]),
        UXTerm("byLight", fr: "Par lumière", en: "By Light", synonyms: ["plage de luminance"]),
        UXTerm("depth", fr: "Profondeur", en: "Depth"),
        UXTerm("wand", fr: "Baguette", en: "Wand", synonyms: ["baguette magique", "magic wand"]),
        UXTerm("lasso", fr: "Lasso", en: "Lasso"),
        UXTerm("all", fr: "Tout", en: "All"),
        UXTerm("adjustedAreas", fr: "Zones réglées", en: "Adjusted Areas", synonyms: ["masques", "masks", "réglages locaux"]),
        UXTerm("refineEdges", fr: "Affiner les bords", en: "Refine Edges", synonyms: ["sélectionner et masquer", "select and mask"]),
    ]

    /// Calques (§3.5.10).
    static let layers: [UXTerm] = [
        UXTerm("fill", fr: "Remplissage", en: "Fill"),
        UXTerm("adjustment", fr: "Réglage", en: "Adjustment", synonyms: ["calque de réglage", "adjustment layer"]),
        UXTerm("group", fr: "Groupe", en: "Group"),
        UXTerm("transform", fr: "Transformer", en: "Transform"),
        UXTerm("blend", fr: "Fusion", en: "Blend", synonyms: ["mode de fusion", "blend mode"]),
        UXTerm("opacity", fr: "Opacité", en: "Opacity"),
        UXTerm("mask", fr: "Masque", en: "Mask", synonyms: ["masque de fusion", "layer mask"]),
    ]

    /// Context-bar items (§4.8) not named above.
    static let contextItems: [UXTerm] = [
        UXTerm("erase", fr: "Effacer", en: "Erase", synonyms: ["remplissage d'après le contenu", "content-aware fill"]),
        UXTerm("fillAction", fr: "Remplir", en: "Fill In", synonyms: ["remplissage génératif", "generative fill"]),
        UXTerm("blurAction", fr: "Flouter", en: "Blur Area"),
        UXTerm("invert", fr: "Inverser", en: "Invert"),
        UXTerm("editArea", fr: "Modifier la zone", en: "Edit Area"),
        UXTerm("outline", fr: "Contour", en: "Outline"),
        UXTerm("thickness", fr: "Épaisseur", en: "Thickness"),
        UXTerm("zoomToItem", fr: "Zoomer sur l'élément", en: "Zoom to Item"),
    ]
}
