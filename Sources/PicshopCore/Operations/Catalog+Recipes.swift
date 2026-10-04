import Foundation

/// W3 recipes (D21): one `recipe` op, one plan step. The executors (PhotoCommandExecutor, VideoCommandExecutor) expand
/// it through `RecipeBook.expand`, run the steps in order on the evolving document and commit one history step
/// « Recette : <titre> ». A recipe asked in the wrong editor answers « Ça se fait dans une vidéo » / « … sur une photo ».
enum CatalogRecipes {
    static var all: [OperationSpec] { [recipe] }

    static var recipe: OperationSpec {
        op("recipe", .handler, in: [.photo, .video], .effects, .geometry,
           title: t("Recipe", "Recette"), summary: t("A ready-made sequence of edits", "Une suite de retouches toute prête")) { s in
            s.params = [
                enumParam("name", RecipeName.self, .required, doc: "the recipe").keys("recipe")
                    .aliases(["instagram": "instagramPost", "post instagram": "instagramPost", "produit": "productPhoto", "photo produit": "productPhoto",
                              "portrait": "portraitRetouch", "retouche portrait": "portraitRetouch", "vlog": "vlogCleanup", "nettoyage vlog": "vlogCleanup"]),
                enumParam("format", ["portrait4x5", "square", "story9x16"], doc: "instagramPost: 4:5, 1:1, 9:16")
                    .aliases(["4 5": "portrait4x5", "portrait": "portrait4x5", "carre": "square", "1 1": "square", "story": "story9x16",
                              "9 16": "story9x16", "reel": "story9x16", "reels": "story9x16"]),
                ParamSpec("background", .color, doc: "productPhoto: background colour").keys("color", "colour").offCard,
                percent("strength", doc: "portraitRetouch: 0 subtle, 100 strong").offCard,
                boolean("captions", doc: "vlogCleanup: add captions").offCard,
            ]
            s.triggers = [
                .fr: ["prépare pour Instagram", "post Instagram", "format story", "photo produit", "fond blanc pour la boutique", "retouche portrait",
                      "embellis le portrait", "nettoie mon vlog", "nettoyage vlog", "recette", "prête pour Instagram", "pour vendre", "leboncoin", "vinted",
                      "annonce de vente"],
                .en: ["make it Instagram ready", "product photo", "portrait retouch", "clean up my vlog", "Instagram post", "vlog cleanup", "recipe",
                      "listing photo", "for my shop", "to sell online"],
            ]
            s.avoid = [.fr: ["exporte pour Instagram", "recadre en 4:5"], .en: ["export for Instagram", "crop to 4:5"]]
            s.examples = [
                fr("prépare pour Instagram", ["name": "instagramPost"]),
                fr("post Instagram au format story", ["name": "instagramPost", "format": "story9x16"]),
                fr("photo produit sur fond blanc", ["name": "productPhoto", "background": "white"]),
                fr("retouche portrait légère", ["name": "portraitRetouch", "strength": 30]),
                fr("nettoie mon vlog", ["name": "vlogCleanup"]),
                fr("prépare un post Instagram carré", ["name": "instagramPost", "format": "square"]),
                en("make it Instagram ready", ["name": "instagramPost"]),
                en("product photo", ["name": "productPhoto"]),
                en("clean up my vlog with captions", ["name": "vlogCleanup", "captions": true]),
                en("portrait retouch, strong", ["name": "portraitRetouch", "strength": 80]),
                para("embellis le portrait", .fr, ["name": "portraitRetouch"]),
                near("exporte pour Instagram", .fr, expected: "exportPhoto"),
            ]
            s.verify = [.unverifiable("each step carries its own check")]
            s.grammar = .keywordsOnly
            s.uiTool = "magic"
        }
    }
}
