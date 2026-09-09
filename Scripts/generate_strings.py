#!/usr/bin/env python3
"""Builds Sources/PicshopUI/Resources/Localizable.xcstrings from L("…") keys.

English is the source language; French translations live in FR below. Keys
without a translation fall back to English (and are listed so they can be added).
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI = ROOT / "Sources/PicshopUI"
OUT = UI / "Resources/Localizable.xcstrings"

FR = {
    "Photos, videos and PDFs. Just say it.": "Photos, vidéos et PDF. Dites-le, c'est fait.",
    "Photos": "Photos",
    "Videos": "Vidéos",
    "PDFs": "PDF",
    "Nothing here yet.": "Rien ici pour l'instant.",
    "Version “%@” saved": "Version « %@ » enregistrée",
    "No saved version yet. Say “save this version as …”.": "Aucune version enregistrée. Dites « enregistre cette version sous … ».",
    "No version named “%@”": "Aucune version nommée « %@ »",
    "Version “%@”": "Version « %@ »",
    "Reading the page…": "Lecture de la page…",
    "Edit text": "Modifier le texte",
    "Erase text": "Effacer le texte",
    "New text": "Nouveau texte",
    "New text, then tap where it goes": "Nouveau texte, puis touchez l'emplacement",
    "Replace": "Remplacer",
    "Tap any word on the page to change or erase it — scans included.": "Touchez n'importe quel mot de la page pour le modifier ou l'effacer, scans compris.",
    "Erase": "Effacer",
    "Add": "Ajouter",
    "Color": "Couleur",
    "Done.": "C'est fait.",
    "Magic": "Magie",
    "Mark up": "Annoter",
    "Retouch": "Retouche",
    "Add Shape": "Ajouter une forme",
    "Arrow": "Flèche",
    "Download large models automatically": "Télécharger les grands modèles automatiquement",
    "Ellipse": "Ellipse",
    "Filled": "Plein",
    "Horizontal": "Horizontal",
    "Installing AI models": "Installation des modèles IA",
    "Line": "Ligne",
    "Perspective": "Perspective",
    "PicShop always uses the most capable brain available on this iPhone. The instant grammar answers first; the language model steps in for complex or ambiguous requests. Everything runs on device.": "PicShop utilise toujours le cerveau le plus capable disponible sur cet iPhone. La grammaire instantanée répond en premier ; le modèle de langage intervient pour les demandes complexes ou ambiguës. Tout fonctionne sur l'appareil.",
    "Pick a shape, then tap the canvas to place it.": "Choisissez une forme, puis touchez l'image pour la placer.",
    "Rectangle": "Rectangle",
    "Rounded": "Arrondi",
    "Shapes": "Formes",
    "Tap the canvas to place a shape. Drag to move, pinch to resize, twist to rotate.": "Touchez l'image pour placer une forme. Glissez pour déplacer, pincez pour redimensionner, tournez pour pivoter.",
    "The eraser and the upscaler ship with the app. Generative Fill and the Pro Brain are large: they download by themselves over Wi‑Fi the first time, and everything runs on your iPhone.": "La gomme et l'upscaler sont livrés avec l'app. Le Remplissage génératif et le Pro Brain sont volumineux : ils se téléchargent seuls en Wi‑Fi la première fois, et tout fonctionne sur votre iPhone.",
    "Thickness": "Épaisseur",
    "Vertical": "Vertical",
    "AI brain": "Cerveau IA", "Activation": "Activation", "Add Music": "Ajouter une musique", "Add music": "Ajouter une musique",
    "Adjust": "Réglages", "All": "Tous", "Apple's on-device foundation model with guided generation.": "Le modèle Apple embarqué, avec génération guidée.",
    "Apply to all clips": "Appliquer à tous les clips", "Apply to all cuts": "Appliquer à toutes les coupes", "Audio": "Audio", "Auto": "Auto",
    "Auto level": "Niveau auto", "Automatic": "Automatique", "Background colour": "Couleur du fond", "Blend": "Fusion", "Blur amount": "Intensité du flou",
    "Blur background": "Flouter le fond", "Blurring the background…": "Flou de l'arrière-plan…", "Bottom": "Bas", "Brush size": "Taille du pinceau",
    "Cancel": "Annuler", "Cancelled.": "Annulé.", "Clear": "Effacer", "Clip volume": "Volume du clip", "Close": "Fermer", "Colour": "Couleur",
    "Control": "Contrôle", "Creating freeze frame…": "Création de l'arrêt sur image…", "Crop": "Recadrer", "Cut": "Couper",
    "Cut, clean up, grade": "Couper, nettoyer, étalonner", "Cutout": "Détourage", "Cutting out the subject…": "Détourage du sujet…", "Delete": "Supprimer",
    "Delete clip": "Supprimer le clip", "Detail": "Détail", "Deterministic grammar, instant, offline. Always on.": "Grammaire déterministe, instantanée, hors ligne. Toujours active.",
    "Done": "OK", "Double tap to reset zoom. Pinch to zoom.": "Touchez deux fois pour réinitialiser le zoom. Pincez pour zoomer.",
    "Download the Pro Brain model below to enable.": "Téléchargez le modèle Pro Brain ci-dessous pour l'activer.",
    "Drag the handles of the selected clip to trim, or say “coupe les 3 premières secondes”, “efface le passant”.": "Faites glisser les poignées du clip pour le raccourcir, ou dites « coupe les 3 premières secondes », « efface le passant ».",
    "Drag the text on the canvas to move it, or say “put the text at the top”.": "Déplacez le texte sur l'image, ou dites « mets le texte en haut ».",
    "Duplicate": "Dupliquer", "Duration": "Durée", "Effects": "Effets", "Erase": "Gomme", "Erase & cut out": "Gomme & détourage", "Erase painted area": "Effacer la zone peinte",
    "Erasing %@ across the clip…": "Suppression de %@ sur tout le clip…", "Erasing across the clip…": "Suppression sur tout le clip…", "Erasing…": "Suppression…",
    "Every brain runs entirely on your iPhone. The instant grammar always runs first; the language model is consulted only for ambiguous or complex requests.": "Chaque cerveau fonctionne entièrement sur votre iPhone. La grammaire instantanée s'exécute toujours en premier ; le modèle de langage n'intervient que pour les demandes ambiguës ou complexes.",
    "Export": "Exporter", "Export defaults": "Export par défaut", "Exported": "Exporté", "Exporting…": "Export en cours…", "Extract frame": "Extraire l'image",
    "Finding %@…": "Recherche de %@…", "Flip": "Retourner", "Format": "Format", "Frame": "Cadre", "Freeze frame": "Arrêt sur image", "Full resolution": "Pleine résolution",
    "Get": "Obtenir", "Gradient": "Dégradé", "Hands-free": "Mains libres", "Haptics": "Retours haptiques", "Help": "Aide", "Hold to talk": "Maintenir pour parler",
    "I didn't catch that.": "Je n'ai pas compris.", "Importing…": "Importation…", "Installed": "Installé", "Intensity": "Intensité", "Language": "Langue",
    "Layers": "Calques", "Levelling…": "Mise à niveau…", "Light": "Lumière", "Listening…": "Je vous écoute…", "Longest side 2048 px": "Grand côté 2048 px",
    "Looks": "Looks", "Microphone & speech": "Micro et reconnaissance vocale", "Middle": "Milieu", "Model server": "Serveur de modèles", "Music": "Musique", "Mute": "Couper le son",
    "Neural models improve object removal and upscaling. Without them, PicShop uses its built-in PatchMatch engine — see docs/MODELS.md to host the archives.": "Les modèles neuronaux améliorent la suppression d'objets et l'agrandissement. Sans eux, PicShop utilise son moteur PatchMatch intégré — voir docs/MODELS.md pour héberger les archives.",
    "New Photo": "Nouvelle photo", "New Video": "Nouvelle vidéo", "Next frame": "Image suivante", "OK": "OK", "On-device models": "Modèles embarqués",
    "Balanced": "Équilibré", "Small": "Léger", "Output": "Sortie",
    "Opacity": "Opacité", "Original": "Original", "Overlay": "Élément", "Pause": "Pause", "Photo": "Photo", "Photo canvas": "Zone de la photo", "Photo format": "Format photo",
    "Photos, videos and voice never leave your device. PicShop has no servers, no accounts and no tracking.": "Vos photos, vidéos et votre voix ne quittent jamais votre appareil. PicShop n'a ni serveur, ni compte, ni suivi.",
    "Pick a photo or video, then just say what you want.": "Choisissez une photo ou une vidéo, puis dites simplement ce que vous voulez.",
    "Play": "Lecture", "Previous frame": "Image précédente", "Privacy": "Confidentialité", "Private by design": "Privé par conception",
    "Pro tools, zero friction": "Outils pro, zéro friction", "Quality": "Qualité", "Qwen3 4B through MLX — best for long multi-step commands.": "Qwen3 4B via MLX — idéal pour les commandes longues en plusieurs étapes.",
    "Recent": "Récents", "Redo": "Rétablir", "Remove": "Retirer", "Remove background": "Supprimer le fond", "Remove music": "Retirer la musique",
    "Rendering portrait effect…": "Rendu de l'effet portrait…", "Replace music": "Remplacer la musique", "Replacing the background…": "Remplacement du fond…",
    "Requires Apple Intelligence.": "Nécessite Apple Intelligence.", "Reset": "Réinitialiser", "Retry": "Réessayer", "Reverse": "Inverser", "Reversing…": "Inversion…",
    "Rotate": "Pivoter", "Save to Photos": "Enregistrer dans Photos", "Saved to Photos": "Enregistré dans Photos", "Saving frame…": "Enregistrement de l'image…",
    "Say it": "Dites-le", "Say what to erase (“the pole on the right”), tap it, or paint over it.": "Dites quoi effacer (« le poteau à droite »), touchez-le, ou peignez dessus.",
    "Say what you want to change, for example: remove the dog.": "Dites ce que vous voulez changer, par exemple : efface le chien.",
    "Select": "Sélectionner", "Settings": "Réglages", "Share last export": "Partager le dernier export", "Show transcript": "Afficher la transcription",
    "Size": "Taille", "Slow motion keeps every frame; time-lapse drops them. Audio follows the speed.": "Le ralenti conserve chaque image ; l'accéléré en saute. L'audio suit la vitesse.",
    "Something went wrong": "Un problème est survenu", "Speak replies": "Lire les réponses", "Speed": "Vitesse", "Split here": "Couper ici",
    "Split the video first to add a transition between two clips.": "Coupez d'abord la vidéo pour ajouter une transition entre deux clips.",
    "Stabilize": "Stabiliser", "Stabilizing…": "Stabilisation…", "Start editing": "Commencer", "Stop listening": "Arrêter l'écoute", "Straighten": "Redresser",
    "Style": "Style", "Tap to talk": "Toucher pour parler", "Text": "Texte", "Text Duration": "Durée du texte", "Top": "Haut", "Transitions": "Transitions",
    "Trim": "Raccourcir", "Type or say “add text …”": "Écrivez ou dites « ajoute le texte … »", "Type or say “ajoute le texte …”": "Écrivez ou dites « ajoute le texte … »",
    "Undo": "Annuler", "Unmute": "Remettre le son", "Upscaling…": "Agrandissement…", "Version": "Version", "Video": "Vidéo", "Video quality": "Qualité vidéo",
    "Voice": "Voix", "Voice command": "Commande vocale", "Volume": "Volume", "Working…": "En cours…", "that": "ça", "object": "l'objet",
    "Retouch, erase, restyle": "Retoucher, effacer, restyler", "“Efface le chien” · “Make it warmer” · “Coupe les 3 premières secondes”": "« Efface le chien » · « Plus chaud » · « Coupe les 3 premières secondes »",
    "Just say it": "Dites-le, c'est tout", "“Efface le chien”, “make it warmer”, “coupe les 3 premières secondes”. PicShop understands French and English and edits instantly.": "« Efface le chien », « plus chaud », « coupe les 3 premières secondes ». PicShop comprend le français et l'anglais et retouche instantanément.",
    "Non-destructive layers, looks, cutouts, object removal, and a full video timeline — all on your iPhone.": "Calques non destructifs, looks, détourage, suppression d'objets et une vraie timeline vidéo — le tout sur votre iPhone.",
    "Recognition, language models and every pixel stay on device. Nothing is uploaded, ever.": "Reconnaissance, modèles de langage et chaque pixel restent sur l'appareil. Rien n'est jamais envoyé.",
    "Light & colour": "Lumière & couleur", "Use signature": "Utiliser la signature", "markups": "annotations", "pages": "pages",
    "Pages": "Pages", "Draw": "Dessiner", "Highlight": "Surligner", "Sign": "Signer", "Image": "Image", "New PDF": "Nouveau PDF", "Sign, mark up, reorder": "Signer, annoter, réorganiser",
    "Precise": "Précis", "Magic wand": "Baguette magique", "Lasso": "Lasso", "Generate": "Générer", "Pixel brush": "Pinceau pixel", "Clone": "Tampon",
    "Tolerance": "Tolérance", "Contiguous": "Contigu", "Tap a colour to select it. Pinch in for the pixel grid.": "Touchez une couleur pour la sélectionner. Pincez pour afficher la grille de pixels.",
    "Draw around the area, or tap corner by corner.": "Entourez la zone, ou touchez coin par coin.", "Close": "Fermer", "Describe what to generate…": "Décrivez ce qu'il faut générer…",
    "Select an area first (wand, lasso or tap), then describe the change.": "Sélectionnez d'abord une zone (baguette, lasso ou toucher), puis décrivez le changement.",
    "Selection ready. Say or type what should appear there.": "Sélection prête. Dites ou écrivez ce qui doit apparaître.", "Generative Fill model not installed — see Settings.": "Modèle Remplissage génératif non installé — voir Réglages.",
    "Apply paint": "Appliquer la peinture", "Tap the source area, then paint the destination.": "Touchez la zone source, puis peignez la destination.", "Paint to clone from the marked source.": "Peignez pour cloner depuis la source marquée.",
    "Apply": "Appliquer", "Erase selection": "Effacer la sélection", "Recolor": "Recolorer", "Paint": "Peinture", "Clone Stamp": "Tampon de duplication",
    "Install Generative Fill in Settings › On-device models to use prompts.": "Installez Remplissage génératif dans Réglages › Modèles embarqués pour utiliser les prompts.",
    "Generating “%@”…": "Génération de « %@ »…", "Generation failed.": "La génération a échoué.", "Recolouring…": "Recoloration…", "Source set. Now paint where to clone.": "Source définie. Peignez maintenant la destination.",
    "Drawing": "Dessin", "Signature": "Signature", "Merge": "Fusion", "Remove": "Retirer", "Page": "Page", "Add Text": "Ajouter du texte", "PDF ready to share": "PDF prêt à partager",
    "Undo stroke": "Annuler le trait", "Pen width": "Épaisseur", "Draw directly on the page.": "Dessinez directement sur la page.", "Tap a word to highlight it, or say “surligne « total »”.": "Touchez un mot pour le surligner, ou dites « surligne « total » ».",
    "Type text, then tap the page": "Écrivez le texte, puis touchez la page", "Place signature": "Placer la signature", "Redraw": "Redessiner", "Tap where to sign.": "Touchez l'endroit où signer.",
    "Insert photo": "Insérer une photo", "Merge PDF": "Fusionner un PDF", "Page numbers": "Numéros de page", "Save as photo": "Enregistrer en photo", "Blank page": "Page blanche", "Move": "Déplacer",
    "Sign with your finger": "Signez avec le doigt", "Share PDF": "Partager le PDF", "Save current page to Photos": "Enregistrer la page dans Photos", "PDF": "PDF",
    "This build was compiled without the Stable Diffusion runtime.": "Cette version a été compilée sans le moteur Stable Diffusion.", "Music Volume": "Volume de la musique", "Text": "Texte", "Erase & cut out": "Gomme & détourage",
    "Animals": "Animaux", "Banner": "Bandeau", "Clear strokes": "Effacer les traits",
    "Drag the text to move it, pinch to resize, twist to rotate.": "Glissez le texte pour le déplacer, pincez pour le redimensionner, tournez pour le faire pivoter.",
    "Hold the mic and say what to change": "Maintenez le micro et dites quoi changer", "Neon": "Néon", "Outline": "Contour", "Page %d of %d": "Page %d sur %d",
    "People": "Personnes", "Pick a look, then tune its intensity.": "Choisissez un look, puis réglez son intensité.", "Pill": "Pastille", "Plain": "Simple",
    "Portrait light": "Lumière portrait", "Shadow": "Ombre",
    "Tap an object to erase it, paint over it, or say “efface le poteau à droite”.": "Touchez un objet pour l'effacer, peignez dessus, ou dites « efface le poteau à droite ».",
    "Tap the mic and say what to change": "Touchez le micro et dites quoi changer", "Text & logos": "Texte & logos", "Vehicles": "Véhicules",
    "Voice unavailable — check microphone access in Settings.": "Voix indisponible — vérifiez l'accès au micro dans Réglages.",
    "This build was compiled without the MLX runtime.": "Cette version a été compilée sans le moteur MLX.",
    "animals": "les animaux", "people": "les personnes", "text": "le texte", "vehicles": "les véhicules",
    "Generative Fill": "Remplissage génératif", "Included in the app": "Inclus dans l'app",
    "LaMa network for clean object removal on complex backgrounds.": "Réseau LaMa pour une suppression d'objets propre sur les fonds complexes.",
    "Neural eraser": "Gomme neuronale", "Pro Brain": "Pro Brain",
    "Qwen3 4B language model for long, multi-step voice commands.": "Modèle de langage Qwen3 4B pour les commandes vocales longues, en plusieurs étapes.",
    "Ready": "Prêt", "Real-ESRGAN upscaler for sharp enlargements.": "Agrandisseur Real-ESRGAN pour des agrandissements nets.",
    "Stable Diffusion: “replace the sky with a sunset”, “add a hat”.": "Stable Diffusion : « remplace le ciel par un coucher de soleil », « ajoute un chapeau ».",
    "Super resolution ×4": "Super résolution ×4",
    # Performance / thermal budget and canvas compare (UI redesign)
    "Automatic follows the iPhone's temperature: previews shrink and glow effects pause before the frame rate drops, and heavy AI work waits until the phone cools down. Exports are always full quality.": "Automatique suit la température de l'iPhone : les aperçus rétrécissent et les effets lumineux se mettent en pause avant que la fluidité baisse, et les traitements IA lourds attendent que le téléphone refroidisse. Les exports sont toujours en pleine qualité.",
    "Before": "Avant", "Best quality": "Qualité maximale", "Compare with original": "Comparer avec l'original", "Cool": "Froid", "Cool & battery": "Fraîcheur & batterie",
    "Full quality previews at the display's refresh rate.": "Aperçus pleine qualité au rythme de l'écran.", "Hold to see the original photo.": "Maintenez pour voir la photo d'origine.",
    "Hot": "Chaud", "Lighter previews and no glow, to cool down.": "Aperçus allégés et sans halo, pour refroidir.", "Low Power Mode": "Mode économie d'énergie",
    "Minimal rendering until the iPhone cools down.": "Rendu minimal jusqu'à ce que l'iPhone refroidisse.", "Performance": "Performance",
    "PicShop is rendering lighter previews to keep your iPhone cool.": "PicShop affiche des aperçus allégés pour garder votre iPhone au frais.", "Rendering": "Rendu",
    "Slightly lighter previews; effects unchanged.": "Aperçus légèrement allégés ; effets inchangés.",
    "The iPhone is too hot for generation right now. Let it cool for a moment.": "L'iPhone est trop chaud pour générer maintenant. Laissez-le refroidir un instant.",
    "Very hot": "Très chaud", "Warm": "Tiède",
    "%d pages": "%d pages", "French or English, several requests in one breath.": "Français ou anglais, plusieurs demandes d'un trait.", "French or English. Tap an example to run it.": "Français ou anglais. Touchez un exemple pour le lancer.", "Small, Apple": "Léger, Apple", "Universal": "Universel", "Lossless": "Sans perte", "Goals": "Objectifs", "Follow-ups": "Suivis", "Portrait": "Portrait",

    "The eraser and the upscaler ship with the app. Generative Fill and the Pro Brain are large and download from Hugging Face on demand; everything runs on your iPhone.": "La gomme et l'agrandisseur sont livrés avec l'app. Le remplissage génératif et le Pro Brain sont volumineux et se téléchargent depuis Hugging Face à la demande ; tout fonctionne sur votre iPhone.",
}

def main():
    keys = set()
    for f in UI.rglob("*.swift"):
        for m in re.finditer(r'L\("((?:[^"\\]|\\.)*)"\)', f.read_text()):
            keys.add(m.group(1).replace('\\"', '"'))
    strings = {}
    missing = []
    for key in sorted(keys):
        entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
        if key in FR:
            entry["localizations"]["fr"] = {"stringUnit": {"state": "translated", "value": FR[key]}}
        else:
            missing.append(key)
        strings[key] = entry
    catalog = {"sourceLanguage": "en", "version": "1.0", "strings": strings}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(strings)} keys to {OUT.relative_to(ROOT)}")
    if missing:
        print("missing French translations:")
        for key in missing: print("  -", key)
    return 0

if __name__ == "__main__":
    sys.exit(main())
