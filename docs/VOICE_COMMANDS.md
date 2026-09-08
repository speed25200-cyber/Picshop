# Voice commands

PicShop listens in French and English (auto-detected, or fixed in Settings). Commands can be chained:
*« efface le chien et rends l'image plus lumineuse, puis recadre en carré »*.

## Erase & cut out

| Say | Does |
|---|---|
| Efface le chien · Remove the dog · Get rid of the power lines · Enlève le poteau à droite | Removes the object (asks which one if several match) |
| Supprime toutes les personnes en arrière-plan · Remove all the people in the background | Removes every match |
| Remove the second person from the left · Efface la deuxième voiture | Ordinals |
| Efface ça · Remove this (after tapping) · Clean up the pimple | Uses the tap point |
| Enlève le fond · Remove the background · Détoure le sujet · Make a sticker | Transparent background |
| Mets un fond blanc · Change the background to light blue · Fond dégradé | Replaces the background |
| Floute l'arrière-plan · Blur the background · Mode portrait · Bokeh | Portrait blur |

When PicShop asks *"Which one?"*, answer with **« celle de gauche »**, **"the second one"**, **"number 2"**,
**"both" / « toutes »**, tap the numbered box, or say **"cancel"**.

## Light & colour

| Say | Parameter |
|---|---|
| Plus lumineux · Make it brighter · Trop sombre · Éclaircis un peu | Brightness |
| Augmente le contraste de 20 · Less contrast · Way too much contrast | Contrast |
| Réchauffe · Warmer · Cooler · Trop jaune | Warmth |
| Plus de couleurs · Desaturate · Saturation à fond · Make the colors pop | Saturation / vibrance |
| Débouche les ombres · Recover the highlights · Deeper blacks | Shadows / highlights / blacks |
| Plus net · Sharpen · Adoucis · Reduce the noise · Ajoute du grain · Enlève la vignette | Detail & effects |
| Mets l'exposition à -20 · Set brightness to 50 · Reset the contrast | Absolute values & resets |
| Rends le ciel plus bleu · Make the sky bluer · Éclaircis le visage · Brighten the background | Selective adjustments (masked to the named region) |

Amounts: **un peu / a bit** (±10), default (±20), **beaucoup / a lot** (±40), **à fond / max**, numbers in
percent, **+15**, **-20**.

## Looks

*Noir et blanc · Black and white · Apply the cinematic look · Filtre heure dorée · Vintage · Teal and orange ·
Un look dramatique subtil · Enlève le filtre.* Looks: Vivid, Fresh, Punch, Golden Hour, Teal & Orange,
Cinematic, Dramatic, Matte, Pastel, Portrait, Film, Vintage, Mono, Silvertone, Noir.

## Frame

*Recadre en carré · Crop to 16:9 · Crop for Instagram story · Format 4 par 5 · Tourne de 90 degrés vers la
gauche · Rotate right · Mets-la à l'envers · Redresse l'horizon · Straighten by 2 degrees · Flip it ·
Retourne verticalement · Recadre sur le visage · Zoom sur le visage · Zoom out · Fit to screen.*

## Text

*Ajoute le texte « Été 2026 » en haut en jaune · Add text saying Happy Birthday at the bottom · Écris Bonjour
Paris au centre · Make the text bigger · Change le texte en Hello · Mets le texte en rouge · Remove the text.*

## Video

| Say | Does |
|---|---|
| Coupe ici · Split here · Split at 10 seconds | Split at the playhead / time |
| Coupe les 3 premières secondes · Remove the last 2 seconds · Supprime de 5 à 12 secondes · Delete the beginning | Delete ranges |
| Garde seulement de 2 à 8 secondes · Raccourcis la vidéo à 15 secondes · Shorten to 20 seconds | Trim (keep) |
| Supprime le clip 2 · Delete this clip · Duplique le clip · Move clip 2 to the beginning | Clip management |
| Accélère x2 · Slow motion · Ralenti deux fois · Vitesse normale · Speed up a lot | Speed |
| Inverse la vidéo · Play it backwards | Reverse |
| Coupe le son · Mute · Remets le son · Baisse le son de 20 % · Louder | Audio |
| Ajoute une musique · Add music lo-fi · Enlève la musique | Music (opens the picker) |
| Ajoute un fondu enchaîné entre tous les clips · Add a fade to black of 1 second · Enlève les transitions | Transitions |
| Efface le passant · Remove the car in the background | Object removal across the clip |
| Stabilise la vidéo · Freeze frame · Extrais cette image · Screenshot | Stabilise / freeze / extract |
| Va à 10 secondes · Go to the beginning · Avance de 5 secondes · Lecture · Pause | Navigation |
| Mets en 9:16 · Crop for TikTok · Filtre cinéma · Plus lumineux · Ajoute le texte Vacances pendant 3 secondes | Shared commands |

## Generative & recolor

*Remplace le ciel par un coucher de soleil · Turn the car into a boat · Ajoute un chapeau sur la personne · Génère un dragon
(after tapping where) · Change the shirt to red · Rends la voiture bleue.* Generative prompts need the optional Stable Diffusion
model (Settings › On-device models); recolouring works offline.

## PDF

| Say | Does |
|---|---|
| Va à la page 3 · Next page · Dernière page | Navigation |
| Supprime la page 3 · Delete this page · Supprime les pages 2 à 4 | Delete |
| Tourne la page · Rotate page 2 left · Rotate all pages | Rotate |
| Déplace la page 4 au début · Move this page to the end · Duplique la page · Insère une page blanche | Reorder / duplicate / insert |
| Surligne « total » · Highlight the word invoice everywhere · Souligne « date » · Caviarde le nom · Cherche facture | Text markup & search (scanned pages are read with on-device OCR) |
| Remplace monsieur par madame · Change « total » en « montant » partout · Replace invoice with receipt | Replace words (covers the original, writes the new text in place) |
| Efface le mot brouillon · Supprime « confidentiel » partout · Remove the word draft | Erase words (covers them with the paper colour) |
| Signe en bas à droite · Add my signature · Ajoute le texte « Approuvé » en haut | Signature & text |
| Extrais la page en photo · Ajoute des numéros de page · Fusionne avec un autre PDF | Page tools |

## Control

*Annule · Undo · Rétablis · Redo · Reviens à l'original · Revert · Montre l'original · Compare · Enregistre ·
Export · Partage · Share · Aide · What can you do.*

Hold the orb to compare before/after; long-press the canvas does the same.

| Enregistre cette version sous brouillon · Reviens à la version brouillon · Save this version as v1 | Named versions (any editor) |
| Décris la photo · What do you see | Spoken description of the photo |
| Enregistre ce style sous plage · Applique le style plage · Applique les mêmes réglages que la dernière photo | Named styles: the tone of one photo replayed on another |
| Qu'est-ce que j'ai modifié ? · What did I change | Spoken recap of the edits (any editor) |
| Lis la page · De quoi parle cette page · Read this page | Reads a PDF page aloud (OCR on scans) |
