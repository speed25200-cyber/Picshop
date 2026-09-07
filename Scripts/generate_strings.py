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
    "Neural models improve object removal and upscaling. Without them, Picshop uses its built-in PatchMatch engine — see docs/MODELS.md to host the archives.": "Les modèles neuronaux améliorent la suppression d'objets et l'agrandissement. Sans eux, Picshop utilise son moteur PatchMatch intégré — voir docs/MODELS.md pour héberger les archives.",
    "New Photo": "Nouvelle photo", "New Video": "Nouvelle vidéo", "Next frame": "Image suivante", "OK": "OK", "On-device models": "Modèles embarqués",
    "Opacity": "Opacité", "Original": "Original", "Overlay": "Élément", "Pause": "Pause", "Photo": "Photo", "Photo canvas": "Zone de la photo", "Photo format": "Format photo",
    "Photos, videos and voice never leave your device. Picshop has no servers, no accounts and no tracking.": "Vos photos, vidéos et votre voix ne quittent jamais votre appareil. Picshop n'a ni serveur, ni compte, ni suivi.",
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
    "Just say it": "Dites-le, c'est tout", "“Efface le chien”, “make it warmer”, “coupe les 3 premières secondes”. Picshop understands French and English and edits instantly.": "« Efface le chien », « plus chaud », « coupe les 3 premières secondes ». Picshop comprend le français et l'anglais et retouche instantanément.",
    "Non-destructive layers, looks, cutouts, object removal, and a full video timeline — all on your iPhone.": "Calques non destructifs, looks, détourage, suppression d'objets et une vraie timeline vidéo — le tout sur votre iPhone.",
    "Recognition, language models and every pixel stay on device. Nothing is uploaded, ever.": "Reconnaissance, modèles de langage et chaque pixel restent sur l'appareil. Rien n'est jamais envoyé.",
    "Light & colour": "Lumière & couleur", "Music Volume": "Volume de la musique", "Text": "Texte", "Erase & cut out": "Gomme & détourage",
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
