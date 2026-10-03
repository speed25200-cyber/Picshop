# Operations

Generated from the Operation Catalog (`Sources/PicshopCore/Operations`); do not edit by hand. After changing an entry, run
`PICSHOP_WRITE_OPERATIONS_DOC=1 swift test --filter CardTests/testOperationsDocIsUpToDate`; CI fails while this file is stale.

106 operations: 51 photo, 59 video, 17 PDF. 13 run through a handler table (`IntentAction.operation`); the others lower to the IntentAction of the same name.

A step is `{"action": id, …params}`. Points are `[x, y]` and boxes `[x1, y1, x2, y2]`, 0–1000 with a top-left origin. On a card, `*` is required, `{a / b}` is a one-of group, and `key:…` lists its values on a `key:` line.

## Photo

| Operation | Title | Category | Core | Grammar | Fast lane | Panel |
|---|---|---|---|---|---|---|
| [`adjust`](#adjust) | Adjust / Réglage | light | yes | owned | yes | adjust |
| [`selectiveAdjust`](#selectiveadjust) | Local adjust / Réglage local | light | yes | owned |  | adjust |
| [`autoEnhance`](#autoenhance) | Auto enhance / Amélioration auto | light | yes | owned | yes | magic |
| [`relight`](#relight) | Relight / Rééclairer | light |  | owned |  | magic |
| [`curves`](#curves) | Curves / Courbes | light |  | none |  | curves |
| [`levels`](#levels) | Levels / Niveaux | light |  | none |  | levels |
| [`autoTone`](#autotone) | Auto tone / Tons auto | light |  | none |  | levels |
| [`applyLook`](#applylook) | Look / Filtre | color | yes | owned | yes | looks |
| [`matchColor`](#matchcolor) | Match colour / Harmoniser les couleurs | color |  | owned |  | color |
| [`recolor`](#recolor) | Recolour / Changer la couleur | color |  | owned |  | color |
| [`hsl`](#hsl) | Colour mixer / Mélangeur de couleurs | color |  | none |  | color |
| [`colorGrade`](#colorgrade) | Colour grade / Étalonnage | color |  | none |  | color |
| [`lutIntensity`](#lutintensity) | LUT intensity / Intensité du LUT | color |  | none |  | color |
| [`removeLUT`](#removelut) | Remove LUT / Retirer le LUT | color |  | none |  | color |
| [`removeObject`](#removeobject) | Remove object / Effacer un objet | objects | yes | owned |  | erase |
| [`cleanUp`](#cleanup) | Clean up / Nettoyer | objects |  | owned |  | erase |
| [`eraseRegion`](#eraseregion) | Erase area / Effacer une zone | retouch |  | keywordsOnly |  | erase |
| [`blurObject`](#blurobject) | Blur object / Flouter un élément | objects |  | owned |  | erase |
| [`moveObject`](#moveobject) | Move object / Déplacer un objet | objects |  | owned |  | magic |
| [`removeBackground`](#removebackground) | Remove background / Enlever le fond | background | yes | owned |  | cutout |
| [`replaceBackground`](#replacebackground) | Replace background / Changer le fond | background |  | owned |  | cutout |
| [`blurBackground`](#blurbackground) | Blur background / Flouter le fond | background | yes | owned |  | focus |
| [`generativeFill`](#generativefill) | Generative fill / Remplissage génératif | generative |  | owned |  | magic |
| [`expandCanvas`](#expandcanvas) | Expand / Agrandir le cadre | generative |  | owned |  | magic |
| [`upscale`](#upscale) | Upscale / Agrandir | detail |  | owned |  | magic |
| [`denoise`](#denoise) | Reduce noise / Réduire le bruit | detail |  | keywordsOnly |  | adjust |
| [`sharpen`](#sharpen) | Sharpen / Netteté | detail |  | keywordsOnly |  | adjust |
| [`lensFocus`](#lensfocus) | Lens focus / Mise au point | effects |  | none |  | focus |
| [`crop`](#crop) | Crop / Recadrer | geometry | yes | owned | yes | crop |
| [`setAspect`](#setaspect) | Aspect ratio / Format | geometry |  | owned | yes | crop |
| [`autoCrop`](#autocrop) | Best crop / Meilleur cadrage | geometry |  | owned |  | crop |
| [`rotate`](#rotate) | Rotate / Pivoter | geometry | yes | owned | yes | crop |
| [`straighten`](#straighten) | Straighten / Redresser | geometry |  | owned | yes | crop |
| [`flip`](#flip) | Flip / Miroir | geometry |  | owned | yes | crop |
| [`resetOrientation`](#resetorientation) | Right way up / Remettre à l'endroit | geometry |  | owned | yes | crop |
| [`perspective`](#perspective) | Perspective / Perspective | geometry |  | none |  | crop |
| [`addText`](#addtext) | Add text / Ajouter du texte | text | yes | owned |  | text |
| [`editText`](#edittext) | Edit text / Modifier le texte | text | yes | owned |  | text |
| [`removeText`](#removetext) | Remove text / Enlever le texte | text |  | owned |  | text |
| [`moveText`](#movetext) | Move text / Déplacer le texte | text |  | owned |  | text |
| [`textBehind`](#textbehind) | Text behind / Texte derrière | text |  | owned |  | text |
| [`fillCells`](#fillcells) | Fill cells / Remplir des cases | table | yes | owned | yes | text |
| [`clearCells`](#clearcells) | Clear cells / Vider des cases | table |  | owned | yes | text |
| [`highlightCells`](#highlightcells) | Highlight cells / Surligner des cases | table |  | owned | yes | text |
| [`selectLayer`](#selectlayer) | Select layer / Sélectionner un calque | layers |  | owned |  | layers |
| [`duplicateLayer`](#duplicatelayer) | Duplicate layer / Dupliquer le calque | layers |  | owned |  | layers |
| [`deleteLayer`](#deletelayer) | Delete layer / Supprimer le calque | layers |  | owned |  | layers |
| [`layerOpacity`](#layeropacity) | Layer opacity / Opacité du calque | layers |  | none |  | layers |
| [`layerBlend`](#layerblend) | Blend mode / Mode de fusion | layers |  | none |  | layers |
| [`layerVisibility`](#layervisibility) | Show or hide layer / Afficher ou masquer | layers |  | none |  | layers |
| [`layerOrder`](#layerorder) | Layer order / Ordre des calques | layers |  | none |  | layers |

## Video

| Operation | Title | Category | Core | Grammar | Fast lane | Panel |
|---|---|---|---|---|---|---|
| [`adjust`](#adjust) | Adjust / Réglage | light | yes | owned | yes | adjust |
| [`autoEnhance`](#autoenhance) | Auto enhance / Amélioration auto | light |  | owned | yes | magic |
| [`applyLook`](#applylook) | Look / Filtre | color | yes | owned | yes | looks |
| [`matchColor`](#matchcolor) | Match colour / Harmoniser les couleurs | color |  | owned |  | color |
| [`removeObject`](#removeobject) | Remove object / Effacer un objet | objects |  | owned |  | erase |
| [`removeBackground`](#removebackground) | Remove background / Enlever le fond | background |  | owned |  | cutout |
| [`replaceBackground`](#replacebackground) | Replace background / Changer le fond | background |  | owned |  | cutout |
| [`blurBackground`](#blurbackground) | Blur background / Flouter le fond | background |  | owned |  | focus |
| [`denoise`](#denoise) | Reduce noise / Réduire le bruit | detail |  | keywordsOnly |  | adjust |
| [`sharpen`](#sharpen) | Sharpen / Netteté | detail |  | keywordsOnly |  | adjust |
| [`crop`](#crop) | Crop / Recadrer | geometry | yes | owned | yes | crop |
| [`setAspect`](#setaspect) | Aspect ratio / Format | geometry |  | owned | yes | crop |
| [`rotate`](#rotate) | Rotate / Pivoter | geometry |  | owned | yes | crop |
| [`straighten`](#straighten) | Straighten / Redresser | geometry |  | owned | yes | crop |
| [`flip`](#flip) | Flip / Miroir | geometry |  | owned | yes | crop |
| [`resetOrientation`](#resetorientation) | Right way up / Remettre à l'endroit | geometry |  | owned | yes | crop |
| [`addText`](#addtext) | Add text / Ajouter du texte | text | yes | owned |  | text |
| [`editText`](#edittext) | Edit text / Modifier le texte | text |  | owned |  | text |
| [`removeText`](#removetext) | Remove text / Enlever le texte | text |  | owned |  | text |
| [`trim`](#trim) | Trim / Garder une partie | cut | yes | owned |  | cut |
| [`split`](#split) | Split / Couper en deux | cut | yes | owned |  | cut |
| [`deleteClip`](#deleteclip) | Delete clip / Supprimer le clip | cut |  | owned |  | cut |
| [`deleteRange`](#deleterange) | Cut a range / Couper un passage | cut | yes | owned |  | cut |
| [`setSpeed`](#setspeed) | Speed / Vitesse | speed | yes | owned | yes | speed |
| [`reverse`](#reverse) | Reverse / Lecture inversée | speed |  | owned |  | speed |
| [`freezeFrame`](#freezeframe) | Freeze frame / Arrêt sur image | speed |  | owned |  | speed |
| [`duplicateClip`](#duplicateclip) | Duplicate clip / Dupliquer le clip | cut |  | owned |  | cut |
| [`moveClip`](#moveclip) | Move clip / Déplacer le clip | cut |  | owned |  | cut |
| [`extractFrame`](#extractframe) | Extract frame / Extraire une image | export |  | owned |  | frame |
| [`addTransition`](#addtransition) | Transition / Transition | transitions | yes | owned |  | transitions |
| [`removeTransition`](#removetransition) | Remove transition / Enlever la transition | transitions |  | owned |  | transitions |
| [`stabilize`](#stabilize) | Stabilise / Stabiliser | motion |  | owned |  | motion |
| [`autoCaptions`](#autocaptions) | Captions / Sous-titres | captions | yes | owned |  | transcript |
| [`removeCaptions`](#removecaptions) | Remove captions / Enlever les sous-titres | captions |  | owned |  | transcript |
| [`translateCaptions`](#translatecaptions) | Translate captions / Traduire les sous-titres | captions |  | owned |  | transcript |
| [`removeSilences`](#removesilences) | Jump cuts / Couper les blancs | cut |  | owned |  | transcript |
| [`removeFillers`](#removefillers) | Remove fillers / Enlever les euh | cut |  | owned |  | transcript |
| [`cutWords`](#cutwords) | Cut words / Couper des mots | cut |  | owned |  | transcript |
| [`trackSubject`](#tracksubject) | Follow subject / Suivre le sujet | overlays |  | owned |  | overlay |
| [`splitScenes`](#splitscenes) | Split scenes / Couper aux changements de plan | cut |  | owned |  | cut |
| [`animateText`](#animatetext) | Animate title / Animer le titre | text |  | owned |  | text |
| [`highlights`](#highlights) | Highlights / Résumé | story |  | owned |  | magic |
| [`speedRamp`](#speedramp) | Speed ramp / Rampe de vitesse | speed |  | owned |  | speed |
| [`punchIns`](#punchins) | Zoom cuts / Zooms de coupe | motion |  | owned |  | motion |
| [`blurFaces`](#blurfaces) | Blur faces / Flouter les visages | effects |  | owned |  | magic |
| [`smartReframe`](#smartreframe) | Smart reframe / Recadrage intelligent | motion |  | owned |  | frame |
| [`kenBurns`](#kenburns) | Ken Burns / Zoom lent | motion |  | owned |  | motion |
| [`mute`](#mute) | Mute / Couper le son | audio |  | owned | yes | audio |
| [`unmute`](#unmute) | Unmute / Remettre le son | audio |  | owned | yes | audio |
| [`setVolume`](#setvolume) | Volume / Volume | audio | yes | owned | yes | audio |
| [`addMusic`](#addmusic) | Add sound / Ajouter du son | audio | yes | owned |  | audio |
| [`removeMusic`](#removemusic) | Remove sound track / Enlever la musique | audio |  | owned |  | audio |
| [`moveAudio`](#moveaudio) | Move sound / Déplacer le son | audio |  | owned |  | audio |
| [`fadeAudio`](#fadeaudio) | Fade sound / Fondu sonore | audio |  | owned |  | audio |
| [`autoDuck`](#autoduck) | Auto duck / Atténuation auto | audio |  | owned |  | audio |
| [`syncToBeat`](#synctobeat) | Cut to the beat / Couper au rythme | audio |  | owned |  | audio |
| [`fitMusic`](#fitmusic) | Fit the music / Ajuster la musique | audio |  | owned |  | audio |
| [`enhanceVoice`](#enhancevoice) | Enhance voice / Voix claire | audio |  | owned |  | audio |
| [`seek`](#seek) | Go to time / Aller à un instant | cut |  | owned | yes | cut |

## PDF

| Operation | Title | Category | Core | Grammar | Fast lane | Panel |
|---|---|---|---|---|---|---|
| [`addText`](#addtext) | Add text / Ajouter du texte | text | yes | owned |  | text |
| [`removeText`](#removetext) | Remove text / Enlever le texte | text |  | owned |  | text |
| [`goToPage`](#gotopage) | Go to page / Aller à la page | pages | yes | owned |  | pages |
| [`deletePage`](#deletepage) | Delete page / Supprimer la page | pages | yes | owned |  | pages |
| [`rotatePage`](#rotatepage) | Rotate page / Pivoter la page | pages | yes | owned |  | pages |
| [`movePage`](#movepage) | Move page / Déplacer la page | pages | yes | owned |  | pages |
| [`duplicatePage`](#duplicatepage) | Duplicate page / Dupliquer la page | pages |  | owned |  | pages |
| [`insertBlankPage`](#insertblankpage) | Insert blank page / Insérer une page blanche | pages | yes | owned |  | pages |
| [`extractPage`](#extractpage) | Extract page / Extraire la page | export | yes | owned |  | pages |
| [`highlightText`](#highlighttext) | Highlight / Surligner | annotate | yes | owned |  | highlight |
| [`underlineText`](#underlinetext) | Underline or strike / Souligner ou barrer | annotate |  | owned |  | highlight |
| [`redactText`](#redacttext) | Redact / Caviarder | annotate | yes | owned |  | redact |
| [`findText`](#findtext) | Find / Chercher | pdfText |  | owned |  | highlight |
| [`replaceText`](#replacetext) | Replace text / Remplacer le texte | pdfText | yes | owned |  | text |
| [`addSignature`](#addsignature) | Sign / Signer | sign | yes | owned |  | signature |
| [`addPageNumbers`](#addpagenumbers) | Page numbers / Numéros de page | document | yes | owned |  | pages |
| [`mergeDocument`](#mergedocument) | Merge / Fusionner | document |  | owned |  | image |

## Entries

### adjust

Adjust / Réglage. One tone or colour setting. *Un réglage de ton ou de couleur.*

- Domains: photo, video; core in: photo, video; category light; phase tone; runs as IntentAction.adjust.
- Card: `adjust: parameter*:…, amount -100..100 — One tone or colour setting « make it brighter »`
  - `parameter: exposure|brightness|contrast|highlights|shadows|whites|blacks|saturation|vibrance|temperature|tint|sharpness|clarity|noiseReduction|vignette|grain|fade|hue|skinTone`
- Params:
  - `parameter` one of `exposure`, `brightness`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `saturation`, `vibrance`, `temperature`, `tint`, `sharpness`, `clarity`, `noiseReduction`, `vignette`, `grain`, `fade`, `hue`, `skinTone`, required: the setting (also `param`, `setting`)
  - `amount` number -100…100 (signedPercent), optional: relative ±; a bit 10, a lot 40 (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « luminosité », « plus lumineux », « plus clair », « éclaircis », « assombris », « plus sombre », « exposition », « contraste », « saturation », « plus de couleurs », « désature », « vibrance », « réchauffe », « plus chaud », « plus froid », « chaleur », « ombres », « hautes lumières », « noirs », « blancs », « netteté », « plus net », « clarté », « grain », « vignettage », « teinte », « nuance », « bruit », « terne », « délavé »
- Triggers (en): « brighter », « darker », « brightness », « exposure », « contrast », « saturation », « more colour », « desaturate », « vibrance », « warmer », « cooler », « warmth », « shadows », « highlights », « blacks », « whites », « sharpness », « sharper », « clarity », « grain », « vignette », « tint », « hue », « noise », « dull », « washed out »
- Examples:
  - « plus lumineux » → `{"action":"adjust","amount":20,"parameter":"brightness"}`
  - « augmente le contraste de 20 » → `{"action":"adjust","amount":20,"parameter":"contrast"}`
  - « mets l'exposition à -20 » → `{"action":"adjust","amount":-20,"amountMode":"absolute","parameter":"exposure"}`
  - « réchauffe un peu » → `{"action":"adjust","amount":10,"parameter":"temperature"}`
  - « ajoute du grain » → `{"action":"adjust","amount":20,"parameter":"grain"}`
  - « make it brighter » → `{"action":"adjust","amount":20,"parameter":"brightness"}`
  - « less contrast » → `{"action":"adjust","amount":-20,"parameter":"contrast"}`
  - « rend la plus chaude » (paraphrase) → `{"action":"adjust","amount":20,"parameter":"temperature"}`
  - « désature les bleus » is not this: `hsl`
  - « courbe en S » is not this: `curves`
- Check: adjustment(parameter) changed.

### selectiveAdjust

Local adjust / Réglage local. A setting on one region only. *Un réglage sur une zone seulement.*

- Domains: photo; core in: photo; category light; phase tone; runs as IntentAction.selectiveAdjust.
- Card: `selectiveAdjust: target*:"…", parameter*:…, amount -100..100, point:[x,y] 0-1000 — A setting on one region only « whiten the teeth »`
  - `parameter: exposure|brightness|contrast|highlights|shadows|whites|blacks|saturation|vibrance|temperature|tint|sharpness|clarity|noiseReduction|vignette|grain|fade|hue|skinTone`
- Params:
  - `target` text ≤ 40, required: region: sky, face, eyes, teeth (also `object`, `subject`)
  - `parameter` one of `exposure`, `brightness`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `saturation`, `vibrance`, `temperature`, `tint`, `sharpness`, `clarity`, `noiseReduction`, `vignette`, `grain`, `fade`, `hue`, `skinTone`, required: the setting (also `param`, `setting`)
  - `amount` number -100…100 (signedPercent), optional: relative ± (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
  - `spatialHint` one of `left`, `right`, `top`, `bottom`, `center`, `foreground`, `background`, `largest`, `smallest`, `leftmost`, `rightmost`, `nearest`, `farthest`, optional: where it is in the frame; off the card
  - `point` point [x, y] 0–1000, optional: [x,y] where it is, 0-1000
- Triggers (fr): « le ciel plus bleu », « du visage », « le visage », « la peau », « lisse la peau », « les dents », « blanchis les dents », « les yeux », « éclaircis les yeux », « l'herbe », « sur le ciel », « seulement le ciel », « le fond plus sombre », « ombres du visage », « visage plus clair »
- Triggers (en): « the sky », « the face », « skin », « smooth the skin », « teeth », « whiten the teeth », « the eyes », « brighten the eyes », « only the sky »
- Examples:
  - « rends le ciel plus bleu » → `{"action":"selectiveAdjust","amount":20,"parameter":"saturation","target":"sky"}`
  - « lisse la peau » → `{"action":"selectiveAdjust","amount":50,"parameter":"noiseReduction","target":"face"}`
  - « éclaircis le visage » → `{"action":"selectiveAdjust","amount":15,"parameter":"brightness","target":"face"}`
  - « whiten the teeth » → `{"action":"selectiveAdjust","amount":20,"parameter":"brightness","target":"teeth"}`
  - « make the sky bluer » → `{"action":"selectiveAdjust","amount":20,"parameter":"saturation","target":"sky"}`
  - « rends les bleus plus saturés » is not this: `hsl`
- Check: unverifiable: a change on one region: the pixel check comes in W2.

### autoEnhance

Auto enhance / Amélioration auto. Balanced light and colour in one go. *Lumière et couleurs équilibrées d'un coup.*

- Domains: photo, video; core in: photo; category light; phase tone; runs as IntentAction.autoEnhance.
- Card: `autoEnhance: amount 0..100 — Balanced light and colour in one go « fix it »`
- Params:
  - `amount` number 0…100 (percent), optional: strength (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « améliore », « améliore la photo », « amélioration automatique », « rends-la plus belle », « c'est moche », « fais quelque chose », « retouche auto »
- Triggers (en): « enhance », « auto enhance », « improve », « fix it », « do your magic », « make it better »
- Examples:
  - « améliore la photo » → `{"action":"autoEnhance"}`
  - « rends-la plus belle » → `{"action":"autoEnhance","amount":70}`
  - « c'est moche, fais quelque chose » → `{"action":"autoEnhance"}`
  - « fix it » → `{"action":"autoEnhance"}`
  - « auto enhance at 50 » → `{"action":"autoEnhance","amount":50}`
  - « niveaux automatiques » is not this: `levels`
  - « auto tone » is not this: `autoTone`
- Check: unverifiable: several settings change at once.

### relight

Relight / Rééclairer. New light on the subject. *Une nouvelle lumière sur le sujet.*

- Domains: photo; core in: none; category light; phase tone; runs as IntentAction.relight.
- Needs: a subject, fast to run.
- Card: `relight: degrees 0..360 — New light on the subject « relight the portrait »`
- Params:
  - `degrees` number 0…360 (degrees), optional: light from: 0 right, 90 top (also `angle`)
  - `amount` number -100…100 (signedPercent), optional: strength (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « rééclaire », « change la lumière », « éclairage studio », « lumière de côté », « relight », « éclaire le sujet »
- Triggers (en): « relight », « studio light », « light from the side », « change the lighting »
- Examples:
  - « rééclaire le sujet » → `{"action":"relight"}`
  - « mets une lumière qui vient de la gauche » → `{"action":"relight","degrees":180}`
  - « relight the portrait » → `{"action":"relight"}`
- Check: unverifiable: the relit look is judged by eye.

### curves

Curves / Courbes. Tone curve per channel. *Courbe de tons par canal.*

- Domains: photo; core in: none; category light; phase tone; runs as handler (IntentAction.operation).
- Card: `curves: channel:rgb|red|green|blue=rgb, {preset:… / points:[[x,y]…] 0-1000 ≤16}*, amount 0..100=50 — Tone curve per channel « add an S curve »`
  - `preset: sCurve|strongS|matte|fade|invert|brighten|darken|linear`
- Params:
  - `channel` one of `rgb`, `red`, `green`, `blue`, default rgb: channel
  - `preset` one of `sCurve`, `strongS`, `matte`, `fade`, `invert`, `brighten`, `darken`, `linear`, one of group `shape`: a ready-made shape (also `shape`, `curve`)
  - `points` list of ≤ 16: point [x, y] 0–1000, one of group `shape`: [[in,out]…] 0-1000
  - `amount` number 0…100 (percent), default 50: strength (also `strength`, `intensity`)
- Triggers (fr): « courbe », « courbes », « courbe en S », « courbe de tons », « courbe des tons », « S léger », « contraste en S », « courbe mate », « inverse les tons »
- Triggers (en): « curve », « curves », « S curve », « tone curve », « S-curve », « S contrast », « curves adjustment »
- Examples:
  - « applique une courbe en S légère » → `{"action":"curves","amount":30,"preset":"sCurve"}`
  - « courbe en S » → `{"action":"curves","preset":"sCurve"}`
  - « une courbe mate sur le canal bleu » → `{"action":"curves","channel":"blue","preset":"matte"}`
  - « remonte le milieu de la courbe » → `{"action":"curves","points":[[0,0],[500,600],[1000,1000]]}`
  - « add an S curve » → `{"action":"curves","preset":"sCurve"}`
  - « strong S curve on the red channel » → `{"action":"curves","channel":"red","preset":"strongS"}`
  - « mets une petite courbe en S » (paraphrase) → `{"action":"curves","amount":25,"preset":"sCurve"}`
  - « courbe en esse » (paraphrase) → `{"action":"curves","preset":"sCurve"}`
  - « plus de contraste » is not this: `adjust`
- Check: toneCurve changed.

### levels

Levels / Niveaux. Black, white and gamma points. *Points noir, blanc et gamma.*

- Domains: photo; core in: none; category light; phase tone; runs as handler (IntentAction.operation).
- Card: `levels: channel:rgb|red|green|blue=rgb, {black 0..254 / white 1..255 / gamma 0.1..9.99 / auto:true|false}* — Black, white and gamma points « auto levels »`
- Params:
  - `channel` one of `rgb`, `red`, `green`, `blue`, default rgb: channel
  - `black` number 0…254 (level255), one of group `values`: input black (also `blackPoint`, `inBlack`)
  - `white` number 1…255 (level255), one of group `values`: input white (also `whitePoint`, `inWhite`)
  - `gamma` number 0.1…9.99 (none), one of group `values`: midtones, 1 neutral (also `midtones`)
  - `outBlack` number 0…254 (level255), one of group `values`: output black; off the card
  - `outWhite` number 1…255 (level255), one of group `values`: output white; off the card
  - `auto` true or false, one of group `values`: automatic levels
- Triggers (fr): « niveaux », « niveaux automatiques », « point noir », « point blanc », « gamma », « niveaux du rouge », « réglage des niveaux »
- Triggers (en): « levels », « auto levels », « black point », « white point », « gamma », « input levels », « output levels »
- Examples:
  - « niveaux automatiques » → `{"action":"levels","auto":true}`
  - « mets le point noir à 20 » → `{"action":"levels","black":20}`
  - « règle les niveaux : noir 15, blanc 240 » → `{"action":"levels","black":15,"white":240}`
  - « niveaux du rouge, blanc à 230 » → `{"action":"levels","channel":"red","white":230}`
  - « auto levels » → `{"action":"levels","auto":true}`
  - « set the levels gamma to 1.2 » → `{"action":"levels","gamma":1.2}`
  - « fais les niveaux tout seul » (paraphrase) → `{"action":"levels","auto":true}`
  - « plus de noirs » is not this: `adjust`
- Check: levels changed.

### autoTone

Auto tone / Tons auto. Levels from the histogram. *Niveaux tirés de l'histogramme.*

- Domains: photo; core in: none; category light; phase tone; runs as handler (IntentAction.operation).
- Card: `autoTone: amount 0..100=100 — Levels from the histogram « auto tone »`
- Params:
  - `amount` number 0…100 (percent), default 100: strength (also `strength`, `intensity`)
- Triggers (fr): « tons automatiques », « tonalité automatique », « ton auto », « tons auto », « corrige les tons », « étale l'histogramme »
- Triggers (en): « auto tone », « automatic tone », « auto contrast », « stretch the histogram »
- Examples:
  - « tonalité automatique » → `{"action":"autoTone"}`
  - « corrige les tons automatiquement » → `{"action":"autoTone","amount":100}`
  - « tons auto à moitié » → `{"action":"autoTone","amount":50}`
  - « auto tone » → `{"action":"autoTone"}`
  - « auto tone, but gently » → `{"action":"autoTone","amount":40}`
  - « améliore la photo » is not this: `autoEnhance`
- Check: levels changed.

### applyLook

Look / Filtre. A ready-made look. *Un look tout prêt.*

- Domains: photo, video; core in: photo, video; category color; phase color; runs as IntentAction.applyLook.
- Card: `applyLook: look*:…, amount 0..100 — A ready-made look « apply the cinematic look »`
  - `look: original|vivid|vividWarm|vividCool|dramatic|dramaticWarm|dramaticCool|cinematic|goldenHour|tealOrange|matte|vintage|film|mono|silvertone|noir|portrait|pastel|punch|fresh`
- Params:
  - `look` one of `original`, `vivid`, `vividWarm`, `vividCool`, `dramatic`, `dramaticWarm`, `dramaticCool`, `cinematic`, `goldenHour`, `tealOrange`, `matte`, `vintage`, `film`, `mono`, `silvertone`, `noir`, `portrait`, `pastel`, `punch`, `fresh`, required: the look (also `preset`, `filter`)
  - `amount` number 0…100 (percent), optional: intensity (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « filtre », « look », « noir et blanc », « heure dorée », « vintage », « cinéma », « ciné », « argentique », « rétro », « pastel », « dramatique », « teal orange »
- Triggers (en): « filter », « look », « black and white », « golden hour », « vintage », « cinematic », « film look », « retro », « pastel », « dramatic », « moody »
- Examples:
  - « noir et blanc » → `{"action":"applyLook","look":"mono"}`
  - « mets le filtre vintage » → `{"action":"applyLook","look":"vintage"}`
  - « un look plus cinéma » → `{"action":"applyLook","amount":70,"look":"cinematic"}`
  - « apply the cinematic look » → `{"action":"applyLook","look":"cinematic"}`
  - « black and white » → `{"action":"applyLook","look":"mono"}`
  - « met en noir est blanc » (paraphrase) → `{"action":"applyLook","look":"mono"}`
  - « ombres bleues » is not this: `colorGrade`
- Check: unverifiable: a look is judged by eye.

### matchColor

Match colour / Harmoniser les couleurs. Colours of another photo or clip. *Les couleurs d'une autre photo ou d'un clip.*

- Domains: photo, video; core in: none; category color; phase color; runs as IntentAction.matchColor.
- Needs: a image the user picks, fast to run.
- Card: `matchColor: clipNumber -1..999, scope:current|all|selection — Colours of another photo or clip « match the colours of another photo »`
- Params:
  - `clipNumber` integer -1…999, optional: video: the reference clip (also `clip`)
  - `scope` one of `current`, `all`, `selection`, optional: video: all clips
- Triggers (fr): « copie les couleurs », « les couleurs d'une autre photo », « mêmes couleurs que », « harmonise les couleurs », « transfert de couleur », « la couleur du clip », « couleur du clip », « comme le clip »
- Triggers (en): « match the colours », « match the colors », « colour transfer », « same colours as », « copy the colours », « match the clip »
- Examples:
  - « prends les couleurs d'une autre photo » → `{"action":"matchColor"}`
  - « mets la couleur du clip 1 sur tous les clips » → `{"action":"matchColor","clipNumber":1,"scope":"all"}`
  - « harmonise les couleurs avec le premier clip » → `{"action":"matchColor","clipNumber":1}`
  - « match the colours of another photo » → `{"action":"matchColor"}`
- Check: unverifiable: needs the reference picked by the user.

### recolor

Recolour / Changer la couleur. New colour for one object. *Une nouvelle couleur pour un objet.*

- Domains: photo; core in: none; category color; phase refDependent; runs as IntentAction.recolor.
- Needs: fast to run.
- Card: `recolor: target*:"…", color*:name|#hex, ref:o1, point:[x,y] 0-1000 — New colour for one object « make the car red »`
- Params:
  - `target` text ≤ 40, required: the object: car, shirt (also `object`, `subject`)
  - `color` colour name or #RRGGBB, required: colour name or #RRGGBB (also `colour`, `couleur`)
  - `ref` id on, optional: o1
  - `point` point [x, y] 0–1000, optional: [x,y] where it is, 0-1000
  - `amount` number 0…1 (fraction), optional: strength 0-1 (also `value`, `strength`, `intensity`); off the card
  - `spatialHint` one of `left`, `right`, `top`, `bottom`, `center`, `foreground`, `background`, `largest`, `smallest`, `leftmost`, `rightmost`, `nearest`, `farthest`, optional: where it is in the frame; off the card
  - `attributes` list of ≤ 3: text ≤ 24, optional: colour or clothing that tells it apart; off the card
- Triggers (fr): « rends la voiture rouge », « change la couleur de », « en rouge », « en bleu », « recolore », « repeins », « couleur du t-shirt »
- Triggers (en): « make the car red », « change the colour of », « recolour », « recolor », « paint it »
- Examples:
  - « rends la voiture rouge » → `{"action":"recolor","color":"red","target":"car"}`
  - « mets le t-shirt en bleu » → `{"action":"recolor","color":"blue","target":"shirt"}`
  - « make the car red » → `{"action":"recolor","color":"red","target":"car"}`
- Check: unverifiable: a change on one object: the pixel check comes in W2.

### hsl

Colour mixer / Mélangeur de couleurs. Hue, saturation, lightness of one colour. *Teinte, saturation, luminance d'une couleur.*

- Domains: photo; core in: none; category color; phase color; runs as handler (IntentAction.operation).
- Card: `hsl: band*:…, {hue -100..100 / saturation -100..100 / luminance -100..100}* — Hue, saturation, lightness of one colour « desaturate the blues »`
  - `band: red|orange|yellow|green|aqua|blue|purple|magenta`
- Params:
  - `band` one of `red`, `orange`, `yellow`, `green`, `aqua`, `blue`, `purple`, `magenta`, required: the colour (also `color`, `colour`)
  - `hue` number -100…100 (signedPercent), one of group `values`: shift toward the next colour
  - `saturation` number -100…100 (signedPercent), one of group `values`: less to more vivid
  - `luminance` number -100…100 (signedPercent), one of group `values`: darker to lighter (also `lightness`)
  - `amountMode` one of `relative`, `absolute`, default relative: relative adds; off the card
- Triggers (fr): « mélangeur de couleurs », « TSL », « teinte saturation luminance », « désature les bleus », « sature les rouges », « les verts plus jaunes », « teinte des verts », « luminance des bleus », « saturation des oranges », « tons chair », « couleur de peau »
- Triggers (en): « HSL », « colour mixer », « color mixer », « hue saturation luminance », « desaturate the blues », « the greens more yellow », « saturation of the reds », « skin tones », « skin tone »
- Examples:
  - « désature les bleus » → `{"action":"hsl","band":"blue","saturation":-40}`
  - « rends les verts plus jaunes » → `{"action":"hsl","band":"green","hue":-30}`
  - « éclaircis les oranges » → `{"action":"hsl","band":"orange","luminance":20}`
  - « sature un peu les rouges » → `{"action":"hsl","band":"red","saturation":20}`
  - « desaturate the blues » → `{"action":"hsl","band":"blue","saturation":-40}`
  - « make the greens more yellow » → `{"action":"hsl","band":"green","hue":-30}`
  - « baisse la sat des bleus » (paraphrase) → `{"action":"hsl","band":"blue","saturation":-30}`
  - « plus de saturation » is not this: `adjust`
- Check: colorMixer changed.

### colorGrade

Colour grade / Étalonnage. Tint shadows, midtones or highlights. *Teinte des ombres, tons moyens ou hautes lumières.*

- Domains: photo; core in: none; category color; phase color; runs as handler (IntentAction.operation).
- Card: `colorGrade: range*:shadows|midtones|highlights, {color:name|#hex / hue 0..360}*, amount 0..100=30, luminance -100..100 — Tint shadows, midtones or highlights`
- Params:
  - `range` one of `shadows`, `midtones`, `highlights`, required: tonal range
  - `color` colour name or #RRGGBB, one of group `tint`: tint colour name (also `colour`, `couleur`)
  - `hue` number 0…360 (degrees), one of group `tint`: tint hue, 0 red
  - `amount` number 0…100 (percent), default 30: tint strength
  - `luminance` number -100…100 (signedPercent), optional: darker to lighter
  - `balance` number -100…100 (signedPercent), optional: shadows ↔ highlights split; off the card
- Triggers (fr): « étalonnage », « ombres bleues », « ombres froides », « ombres chaudes », « hautes lumières orangées », « hautes lumières chaudes », « teinte les ombres », « virage partiel », « roues chromatiques », « étalonne »
- Triggers (en): « colour grade », « color grade », « color grading », « split toning », « teal shadows », « orange highlights », « warm highlights », « cool shadows », « colour wheels », « color wheels »
- Examples:
  - « ombres bleues » → `{"action":"colorGrade","amount":30,"color":"blue","range":"shadows"}`
  - « hautes lumières orangées » → `{"action":"colorGrade","amount":30,"color":"orange","range":"highlights"}`
  - « réchauffe les tons moyens à l'étalonnage » → `{"action":"colorGrade","amount":20,"color":"orange","range":"midtones"}`
  - « teal shadows » → `{"action":"colorGrade","amount":30,"color":"teal","range":"shadows"}`
  - « split toning with orange highlights » → `{"action":"colorGrade","amount":30,"color":"orange","range":"highlights"}`
  - « des ombres un peu froides » (paraphrase) → `{"action":"colorGrade","amount":20,"color":"blue","range":"shadows"}`
  - « teal and orange » is not this: `applyLook`
- Check: colorGrade changed.

### lutIntensity

LUT intensity / Intensité du LUT. How strongly the imported LUT applies. *La force du LUT importé.*

- Domains: photo; core in: none; category color; phase color; runs as handler (IntentAction.operation).
- Needs: an imported LUT.
- Card: `lutIntensity: amount* 0..100 — How strongly the imported LUT applies « LUT intensity 70 »`
- Params:
  - `amount` number 0…100 (percent), required: 0 none, 100 full (also `intensity`, `strength`)
- Triggers (fr): « LUT », « intensité du LUT », « force du LUT », « LUT à », « applique mon LUT », « dose du LUT »
- Triggers (en): « LUT », « LUT intensity », « LUT strength », « apply my LUT », « LUT at »
- Examples:
  - « mets le LUT à 50 % » → `{"action":"lutIntensity","amount":50}`
  - « baisse l'intensité du LUT » → `{"action":"lutIntensity","amount":40}`
  - « applique mon LUT à fond » → `{"action":"lutIntensity","amount":100}`
  - « LUT intensity 70 » → `{"action":"lutIntensity","amount":70}`
  - « mets un LUT » (paraphrase) → `{"action":"lutIntensity","amount":100}`
- Check: lutIntensity equals `amount`.

### removeLUT

Remove LUT / Retirer le LUT. Takes the imported LUT off. *Enlève le LUT importé.*

- Domains: photo; core in: none; category color; phase color; runs as handler (IntentAction.operation).
- Needs: an imported LUT.
- Card: `removeLUT: — Takes the imported LUT off « remove the LUT »`
- Triggers (fr): « enlève le LUT », « retire le LUT », « supprime le LUT », « sans LUT », « enlève la LUT »
- Triggers (en): « remove the LUT », « no LUT », « turn off the LUT », « delete the LUT »
- Examples:
  - « enlève le LUT » → `{"action":"removeLUT"}`
  - « retire la LUT » → `{"action":"removeLUT"}`
  - « remove the LUT » → `{"action":"removeLUT"}`
  - « enlève le filtre » is not this: `applyLook`
- Check: lutIntensity decreased.

### removeObject

Remove object / Effacer un objet. Erases a thing and fills the gap. *Efface une chose et comble le trou.*

- Domains: photo, video; core in: photo; category objects; phase refDependent; runs as IntentAction.removeObject.
- Needs: fast to run.
- Card: `removeObject: {target:"…" / point:[x,y] 0-1000}*, ref:o1 — Erases a thing and fills the gap « remove the dog »`
- Params:
  - `target` text ≤ 40, one of group `what`: English noun: person, car, sign (also `object`, `subject`)
  - `point` point [x, y] 0–1000, one of group `what`: [x,y] where it is, 0-1000
  - `ref` id on, optional: o1
  - `spatialHint` one of `left`, `right`, `top`, `bottom`, `center`, `foreground`, `background`, `largest`, `smallest`, `leftmost`, `rightmost`, `nearest`, `farthest`, optional: where it is in the frame; off the card
  - `ordinal` integer 1…20, optional: the second one → 2; off the card
  - `all` true or false, optional: every matching one; off the card
  - `attributes` list of ≤ 3: text ≤ 24, optional: colour or clothing that tells it apart; off the card
- Triggers (fr): « efface », « enlève », « supprime », « retire », « fais disparaître », « gomme », « le poteau », « les fils », « la poubelle », « enlève la personne », « efface la personne », « les gens »
- Triggers (en): « remove », « erase », « delete », « get rid of », « take out », « the power lines », « the pole », « remove the person », « the people »
- Examples:
  - « efface le chien à gauche » → `{"action":"removeObject","spatialHint":"left","target":"dog"}`
  - « enlève le poteau à droite » → `{"action":"removeObject","spatialHint":"right","target":"pole"}`
  - « supprime la deuxième voiture » → `{"action":"removeObject","ordinal":2,"target":"car"}`
  - « remove the dog » → `{"action":"removeObject","target":"dog"}`
  - « get rid of the power lines » → `{"action":"removeObject","all":true,"target":"wire"}`
  - « éfface le chien » (paraphrase) → `{"action":"removeObject","target":"dog"}`
  - « enlève le fond » is not this: `removeBackground`
- Check: pixels objectAbsent changed (from W2).

### cleanUp

Clean up / Nettoyer. Erases passers-by, keeps the subject. *Efface les passants, garde le sujet.*

- Domains: photo; core in: none; category objects; phase cleanup; runs as IntentAction.cleanUp.
- Needs: heavy to run.
- Card: `cleanUp: — Erases passers-by, keeps the subject « remove the tourists in the background »`
- Triggers (fr): « passants », « les passants », « touristes », « photobomb », « nettoie la photo », « les gens derrière », « les intrus », « ce qui dérange »
- Triggers (en): « passers-by », « tourists », « photobombers », « clean up », « clean the photo », « people behind », « distractions »
- Examples:
  - « enlève les passants » → `{"action":"cleanUp"}`
  - « nettoie la photo, il y a des touristes » → `{"action":"cleanUp"}`
  - « remove the tourists in the background » → `{"action":"cleanUp"}`
- Check: unverifiable: which people stay is judged by eye.

### eraseRegion

Erase area / Effacer une zone. Erases a box or a scene id. *Efface une zone ou un élément nommé.*

- Domains: photo; core in: none; category retouch; phase refDependent; runs as IntentAction.eraseRegion.
- Needs: fast to run.
- Card: `eraseRegion: {box:[x1,y1,x2,y2] 0-1000 / ref:t1|l1|o1|f1 / point:[x,y] 0-1000}* — Erases a box or a scene id « erase that block of text »`
- Params:
  - `box` box [x1, y1, x2, y2] 0–1000, one of group `where`: [x1,y1,x2,y2] 0-1000
  - `ref` id tn/ln/on/fn, one of group `where`: t3, l2, o1, f1
  - `point` point [x, y] 0–1000, one of group `where`: [x,y] where it is, 0-1000
- Triggers (fr): « efface cette zone », « efface la zone », « efface le texte imprimé », « efface ce bloc », « gomme ce coin »
- Triggers (en): « erase this area », « erase the box », « erase that block », « clear this region », « patch », « erase this spot »
- Examples:
  - « efface le bloc de texte t3 » → `{"action":"eraseRegion","ref":"t3"}`
  - « efface la zone en haut à gauche » → `{"action":"eraseRegion","box":[0,0,300,200]}`
  - « erase that block of text » → `{"action":"eraseRegion","ref":"t1"}`
- Check: unverifiable: the erased area is judged by eye.

### blurObject

Blur object / Flouter un élément. Privacy blur on faces, plates, screens. *Flou de confidentialité : visages, plaques, écrans.*

- Domains: photo; core in: none; category objects; phase refDependent; runs as IntentAction.blurObject.
- Needs: fast to run.
- Card: `blurObject: target:"…", ref:o1, point:[x,y] 0-1000 — Privacy blur on faces, plates, screens « blur the faces »`
- Params:
  - `target` text ≤ 40, optional: face (default), licence plate, screen (also `object`, `subject`)
  - `ref` id on, optional: o1
  - `point` point [x, y] 0–1000, optional: [x,y] where it is, 0-1000
  - `all` true or false, optional: every matching one; off the card
- Triggers (fr): « floute les visages », « floute la plaque », « pixelise », « pixellise », « anonymise », « cache les visages », « floute l'écran »
- Triggers (en): « blur the faces », « blur the licence plate », « pixelate », « pixelize », « anonymise », « hide the faces »
- Examples:
  - « floute les visages » → `{"action":"blurObject","all":true,"target":"face"}`
  - « pixelise la plaque d'immatriculation » → `{"action":"blurObject","target":"sign"}`
  - « blur the faces » → `{"action":"blurObject","all":true,"target":"face"}`
- Check: unverifiable: a privacy blur is judged by eye.

### moveObject

Move object / Déplacer un objet. Moves a thing, fills where it was. *Déplace un objet et comble sa place.*

- Domains: photo; core in: none; category objects; phase refDependent; runs as IntentAction.moveObject.
- Needs: heavy to run.
- Card: `moveObject: {target:"…" / point:[x,y] 0-1000}*, ref:o1, degrees -360..360, amount 0.05..0.5 — Moves a thing, fills where it was « move the person to the right »`
- Params:
  - `target` text ≤ 40, one of group `what`: the object (also `object`, `subject`)
  - `point` point [x, y] 0–1000, one of group `what`: [x,y] where it is, 0-1000
  - `ref` id on, optional: o1
  - `degrees` number -360…360 (degrees), optional: direction: 0 right, 90 up (also `angle`)
  - `amount` number 0.05…0.5 (fraction), optional: distance, part of the frame (also `value`, `strength`, `intensity`)
  - `placement` one of `top`, `center`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, optional: where on the frame (also `position`); off the card
- Triggers (fr): « déplace le », « déplace la », « bouge le », « décale », « pousse vers la gauche », « au centre de la photo »
- Triggers (en): « move the », « shift the », « reposition », « push to the left »
- Examples:
  - « déplace la voiture un peu vers la droite » → `{"action":"moveObject","amount":0.08,"degrees":0,"target":"car"}`
  - « décale le chien vers la gauche » → `{"action":"moveObject","amount":0.15,"degrees":180,"target":"dog"}`
  - « move the person to the right » → `{"action":"moveObject","amount":0.2,"degrees":0,"target":"person"}`
- Check: unverifiable: the new position is judged by eye.

### removeBackground

Remove background / Enlever le fond. Cuts the subject out. *Détoure le sujet.*

- Domains: photo, video; core in: photo; category background; phase composition; runs as IntentAction.removeBackground.
- Needs: a subject, fast to run.
- Card: `removeBackground: — Cuts the subject out « remove the background »`
- Triggers (fr): « enlève le fond », « supprime le fond », « détoure », « détourage », « fond transparent », « garde que le sujet »
- Triggers (en): « remove the background », « cut out », « cutout », « transparent background », « only the subject »
- Examples:
  - « enlève le fond » → `{"action":"removeBackground"}`
  - « détoure le sujet » → `{"action":"removeBackground"}`
  - « remove the background » → `{"action":"removeBackground"}`
- Check: pixels alphaCoverage decreased (from W2).

### replaceBackground

Replace background / Changer le fond. A colour, transparent or blur behind the subject. *Une couleur, du transparent ou du flou derrière le sujet.*

- Domains: photo, video; core in: none; category background; phase composition; runs as IntentAction.replaceBackground.
- Needs: a subject, fast to run.
- Card: `replaceBackground: background:"…" — A colour, transparent or blur behind the subject « change the background to light blue »`
- Params:
  - `background` text ≤ 40, optional: colour, transparent or blur
- Triggers (fr): « fond blanc », « mets un fond », « change le fond », « fond bleu », « fond noir », « fond vert », « fond uni », « fond coloré »
- Triggers (en): « white background », « change the background », « swap the background », « switch the background », « new background », « background to », « plain background », « green background »
- Examples:
  - « mets un fond blanc » → `{"action":"replaceBackground","background":"white"}`
  - « change le fond en bleu clair » → `{"action":"replaceBackground","background":"light blue"}`
  - « change the background to light blue » → `{"action":"replaceBackground","background":"light blue"}`
- Check: unverifiable: the new background is judged by eye.

### blurBackground

Blur background / Flouter le fond. Portrait-mode background blur. *Flou d'arrière-plan façon portrait.*

- Domains: photo, video; core in: photo; category background; phase effects; runs as IntentAction.blurBackground.
- Needs: a subject, fast to run.
- Card: `blurBackground: amount 0..100 — Portrait-mode background blur « blur the background »`
- Params:
  - `amount` number 0…100 (percent), optional: blur strength (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « floute l'arrière-plan », « floute le fond », « mode portrait », « bokeh », « flou d'arrière-plan », « arrière-plan flou »
- Triggers (en): « blur the background », « portrait mode », « bokeh », « background blur », « depth of field »
- Examples:
  - « floute l'arrière-plan » → `{"action":"blurBackground"}`
  - « mode portrait » → `{"action":"blurBackground","amount":60}`
  - « blur the background » → `{"action":"blurBackground","amount":60}`
  - « floute larrière plan » (paraphrase) → `{"action":"blurBackground"}`
  - « fais la mise au point sur le chien » is not this: `lensFocus`
- Check: unverifiable: the blur strength is judged by eye.

### generativeFill

Generative fill / Remplissage génératif. Invents new content in a region. *Invente un nouveau contenu dans une zone.*

- Domains: photo; core in: none; category generative; phase composition; runs as IntentAction.generativeFill.
- Needs: the generative engine, heavy to run.
- Card: `generativeFill: text*:"…", target:"…" — Invents new content in a region « the sky is boring, do something about it »`
- Params:
  - `text` text ≤ 200, required: what to generate, in English
  - `target` text ≤ 40, optional: region to replace: sky (also `object`, `subject`)
- Triggers (fr): « remplace le ciel par », « ajoute un chapeau », « rajoute », « rajoute un », « génère », « invente », « change le ciel », « mets un coucher de soleil »
- Triggers (en): « replace the sky with », « add a hat », « generate », « the sky is boring », « make a sunset sky »
- Examples:
  - « remplace le ciel par un coucher de soleil » → `{"action":"generativeFill","target":"sky","text":"a sunset sky with warm clouds"}`
  - « ajoute un chapeau à la personne » → `{"action":"generativeFill","target":"person","text":"a hat"}`
  - « the sky is boring, do something about it » → `{"action":"generativeFill","target":"sky","text":"a dramatic sky with golden sunset clouds"}`
- Check: unverifiable: generated content is judged by eye.

### expandCanvas

Expand / Agrandir le cadre. A bigger frame, the border invented. *Un cadre plus grand, le bord inventé.*

- Domains: photo; core in: none; category generative; phase geometry; runs as IntentAction.expandCanvas.
- Needs: the generative engine, heavy to run, changes the geometry.
- Card: `expandCanvas: aspect:… — A bigger frame, the border invented « expand the canvas to square »`
  - `aspect: original|free|square|ratio4x3|ratio3x4|ratio3x2|ratio2x3|ratio16x9|ratio9x16|ratio21x9|ratio5x4|ratio4x5`
- Params:
  - `aspect` one of `original`, `free`, `square`, `ratio4x3`, `ratio3x4`, `ratio3x2`, `ratio2x3`, `ratio16x9`, `ratio9x16`, `ratio21x9`, `ratio5x4`, `ratio4x5`, optional: the frame shape (also `ratio`, `format`)
- Triggers (fr): « agrandis la toile », « agrandis le cadre », « élargis la photo », « étends l'image », « dézoome », « outpainting », « sur les côtés », « plus de décor », « étends le décor »
- Triggers (en): « expand the canvas », « uncrop », « outpaint », « extend the photo », « zoom out the frame », « on the sides », « more scenery »
- Examples:
  - « agrandis la toile vers la gauche » → `{"action":"expandCanvas"}`
  - « élargis la photo en 16:9 » → `{"action":"expandCanvas","aspect":"ratio16x9"}`
  - « expand the canvas to square » → `{"action":"expandCanvas","aspect":"square"}`
- Check: unverifiable: the canvas grows; its shape changes only with an aspect.

### upscale

Upscale / Agrandir. More pixels, sharper detail. *Plus de pixels, plus de détails.*

- Domains: photo; core in: none; category detail; phase output; runs as IntentAction.upscale.
- Needs: heavy to run.
- Card: `upscale: amount 2..4 — More pixels, sharper detail « upscale it 3 times »`
- Params:
  - `amount` number 2…4 (multiplier), optional: factor 2-4 (also `value`, `strength`, `intensity`)
- Triggers (fr): « augmente la résolution », « agrandis la photo », « super résolution », « haute définition », « plus de pixels », « en 4K », « 4K », « 8K »
- Triggers (en): « upscale », « increase the resolution », « super resolution », « higher resolution », « 4K », « 8K », « in 4K »
- Examples:
  - « augmente la résolution » → `{"action":"upscale"}`
  - « agrandis la photo trois fois » → `{"action":"upscale","amount":3}`
  - « upscale it 3 times » → `{"action":"upscale","amount":3}`
- Check: unverifiable: the size is checked by the executor.

### denoise

Reduce noise / Réduire le bruit. Cleans grain and noise. *Nettoie le grain et le bruit.*

- Domains: photo, video; core in: none; category detail; phase cleanup; runs as IntentAction.denoise.
- Card: `denoise: amount 0..100 — Cleans grain and noise « denoise it »`
- Params:
  - `amount` number 0…100 (percent), optional: strength (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « réduis le bruit », « enlève le bruit », « débruite », « photo bruitée », « moins de bruit »
- Triggers (en): « denoise », « reduce the noise », « remove the noise », « noisy »
- Examples:
  - « réduis le bruit » → `{"action":"denoise","amount":40}`
  - « enlève le bruit de la photo » → `{"action":"denoise","amount":50}`
  - « denoise it » → `{"action":"denoise","amount":40}`
- Check: adjustment(noiseReduction) increased.

### sharpen

Sharpen / Netteté. Crisper detail. *Des détails plus nets.*

- Domains: photo, video; core in: none; category detail; phase effects; runs as IntentAction.sharpen.
- Card: `sharpen: amount 0..100 — Crisper detail « sharpen it a bit »`
- Params:
  - `amount` number 0…100 (percent), optional: strength (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
- Triggers (fr): « plus net », « accentue la netteté », « renforce les détails », « c'est flou »
- Triggers (en): « sharpen », « sharper », « crisper », « more detail »
- Examples:
  - « rends la photo plus nette » → `{"action":"sharpen","amount":30}`
  - « accentue la netteté » → `{"action":"sharpen","amount":40}`
  - « sharpen it a bit » → `{"action":"sharpen","amount":20}`
- Check: adjustment(sharpness) increased.

### lensFocus

Lens focus / Mise au point. Sharp where you say, lens blur elsewhere. *Net où tu dis, flou d'objectif ailleurs.*

- Domains: photo; core in: none; category effects; phase effects; runs as handler (IntentAction.operation).
- Card: `lensFocus: {ref:o1 / point:[x,y] 0-1000}*, aperture 0..100=60 — Sharp where you say, lens blur elsewhere « focus on the dog »`
- Params:
  - `ref` id on, one of group `where`: o1: what to focus on
  - `point` point [x, y] 0–1000, one of group `where`: [x,y] focus point 0-1000
  - `aperture` number 0…100 (percent), default 60: blur strength (also `amount`, `blur`)
- Triggers (fr): « mise au point », « mets au point », « fais le point », « fais la mise au point », « map », « la map », « ouverture », « profondeur de champ sur », « net sur »
- Triggers (en): « focus on », « focus point », « aperture », « rack focus », « sharp on »
- Examples:
  - « fais la mise au point sur le chien » → `{"action":"lensFocus","ref":"o1"}`
  - « mise au point au centre, ouverture 80 » → `{"action":"lensFocus","aperture":80,"point":[500,500]}`
  - « mets la personne de gauche nette et floute le reste » → `{"action":"lensFocus","ref":"o2"}`
  - « focus on the dog » → `{"action":"lensFocus","ref":"o1"}`
  - « set the focus point at the top, aperture 40 » → `{"action":"lensFocus","aperture":40,"point":[500,200]}`
  - « floute l'arrière-plan » is not this: `blurBackground`
- Check: lensBlur changed.

### crop

Crop / Recadrer. Crop to a frame shape. *Recadre selon un format.*

- Domains: photo, video; core in: photo, video; category geometry; phase geometry; runs as IntentAction.crop.
- Needs: changes the geometry.
- Card: `crop: aspect:… — Crop to a frame shape « crop to 16:9 »`
  - `aspect: original|free|square|ratio4x3|ratio3x4|ratio3x2|ratio2x3|ratio16x9|ratio9x16|ratio21x9|ratio5x4|ratio4x5`
- Params:
  - `aspect` one of `original`, `free`, `square`, `ratio4x3`, `ratio3x4`, `ratio3x2`, `ratio2x3`, `ratio16x9`, `ratio9x16`, `ratio21x9`, `ratio5x4`, `ratio4x5`, optional: the frame shape (also `ratio`, `format`)
  - `target` text ≤ 40, optional: crop around: face, dog (also `object`, `subject`); off the card
- Triggers (fr): « recadre », « recadrage », « rogne », « carré », « format », « 16:9 », « 9:16 », « 4:5 », « en portrait », « fond d'écran »
- Triggers (en): « crop », « square », « crop to », « aspect ratio », « 16:9 », « 9:16 », « 4:5 »
- Examples:
  - « recadre en carré » → `{"action":"crop","aspect":"square"}`
  - « format 4 par 5 » → `{"action":"crop","aspect":"ratio4x5"}`
  - « rogne la vidéo en 16:9 » → `{"action":"crop","aspect":"ratio16x9"}`
  - « crop to 16:9 » → `{"action":"crop","aspect":"ratio16x9"}`
  - « récadre en carré » (paraphrase) → `{"action":"crop","aspect":"square"}`
  - « recadre au mieux » is not this: `autoCrop`
- Check: canvasAspect equals `aspect`.

### setAspect

Aspect ratio / Format. Sets the frame shape. *Change la forme du cadre.*

- Domains: photo, video; core in: none; category geometry; phase geometry; runs as IntentAction.setAspect.
- Needs: changes the geometry.
- Card: `setAspect: aspect*:… — Sets the frame shape « set the aspect ratio to 4:3 »`
  - `aspect: original|free|square|ratio4x3|ratio3x4|ratio3x2|ratio2x3|ratio16x9|ratio9x16|ratio21x9|ratio5x4|ratio4x5`
- Params:
  - `aspect` one of `original`, `free`, `square`, `ratio4x3`, `ratio3x4`, `ratio3x2`, `ratio2x3`, `ratio16x9`, `ratio9x16`, `ratio21x9`, `ratio5x4`, `ratio4x5`, required: the frame shape (also `ratio`, `format`)
- Triggers (fr): « passe en », « format », « ratio », « en vertical », « en paysage », « pour une story »
- Triggers (en): « aspect ratio », « make it vertical », « landscape format », « for a story »
- Examples:
  - « passe en format 9:16 » → `{"action":"setAspect","aspect":"ratio9x16"}`
  - « mets-la au format paysage » → `{"action":"setAspect","aspect":"ratio16x9"}`
  - « set the aspect ratio to 4:3 » → `{"action":"setAspect","aspect":"ratio4x3"}`
- Check: canvasAspect equals `aspect`.

### autoCrop

Best crop / Meilleur cadrage. The framing an aesthetics model prefers. *Le cadrage préféré d'un modèle esthétique.*

- Domains: photo; core in: none; category geometry; phase geometry; runs as IntentAction.autoCrop.
- Needs: fast to run, changes the geometry.
- Card: `autoCrop: — The framing an aesthetics model prefers « improve the framing »`
- Triggers (fr): « recadre au mieux », « meilleur cadrage », « recadrage automatique », « améliore le cadrage », « cadre mieux »
- Triggers (en): « best crop », « auto crop », « smart crop », « improve the framing », « frame it better »
- Examples:
  - « recadre au mieux » → `{"action":"autoCrop"}`
  - « trouve le meilleur cadrage » → `{"action":"autoCrop"}`
  - « improve the framing » → `{"action":"autoCrop"}`
- Check: canvasAspect changed.

### rotate

Rotate / Pivoter. Turns by degrees. *Tourne de quelques degrés.*

- Domains: photo, video; core in: photo; category geometry; phase geometry; runs as IntentAction.rotate.
- Needs: changes the geometry.
- Card: `rotate: degrees -360..360 — Turns by degrees « rotate right »`
- Params:
  - `degrees` number -360…360 (degrees), optional: negative = counter-clockwise (also `angle`)
- Triggers (fr): « tourne », « pivote », « rotation », « quart de tour », « degrés », « vers la gauche », « vers la droite »
- Triggers (en): « rotate », « turn », « rotation », « quarter turn », « degrees »
- Examples:
  - « tourne de 90 degrés vers la gauche » → `{"action":"rotate","degrees":-90}`
  - « tourne de 15 degrés » → `{"action":"rotate","degrees":15}`
  - « rotate right » → `{"action":"rotate","degrees":90}`
  - « tourne la à droite » (paraphrase) → `{"action":"rotate","degrees":90}`
- Check: rotation changed.

### straighten

Straighten / Redresser. Levels the horizon. *Met l'horizon à niveau.*

- Domains: photo, video; core in: none; category geometry; phase geometry; runs as IntentAction.straighten.
- Needs: changes the geometry.
- Card: `straighten: degrees -45..45 — Levels the horizon « straighten the horizon »`
- Params:
  - `degrees` number -45…45 (degrees), optional: small tilt; omit to detect (also `angle`)
- Triggers (fr): « redresse l'horizon », « redresse », « horizon », « c'est penché », « penche », « de travers », « tordu », « pas droit », « mets à niveau », « remets droit »
- Triggers (en): « straighten », « level the horizon », « horizon », « it's tilted », « tilted », « crooked », « not level »
- Examples:
  - « redresse l'horizon » → `{"action":"straighten"}`
  - « redresse de 2 degrés » → `{"action":"straighten","degrees":2}`
  - « straighten the horizon » → `{"action":"straighten"}`
- Check: rotation changed.

### flip

Flip / Miroir. Mirrors horizontally or vertically. *Retourne en miroir.*

- Domains: photo, video; core in: none; category geometry; phase geometry; runs as IntentAction.flip.
- Needs: changes the geometry.
- Card: `flip: flipAxis:horizontal|vertical — Mirrors horizontally or vertically « flip it »`
- Params:
  - `flipAxis` one of `horizontal`, `vertical`, optional: mirror axis (also `axis`)
- Triggers (fr): « miroir », « retourne », « inverse gauche droite », « effet miroir », « retourne verticalement »
- Triggers (en): « flip », « mirror », « flip it », « flip vertically »
- Examples:
  - « effet miroir » → `{"action":"flip","flipAxis":"horizontal"}`
  - « retourne verticalement » → `{"action":"flip","flipAxis":"vertical"}`
  - « flip it » → `{"action":"flip","flipAxis":"horizontal"}`
- Check: unverifiable: a mirror keeps every measured value.

### resetOrientation

Right way up / Remettre à l'endroit. Undoes every turn and mirror. *Annule rotations et miroirs.*

- Domains: photo, video; core in: none; category geometry; phase geometry; runs as IntentAction.resetOrientation.
- Needs: changes the geometry.
- Card: `resetOrientation: — Undoes every turn and mirror « it's upside down »`
- Params:
  - `degrees` number -360…360 (degrees), optional: 180 when it shows upside down (also `angle`); off the card
  - `flipAxis` one of `horizontal`, `vertical`, optional: mirror axis (also `axis`); off the card
- Triggers (fr): « remets-la à l'endroit », « à l'endroit », « c'est à l'envers », « la tête en bas », « annule le miroir »
- Triggers (en): « right way up », « it's upside down », « upright », « undo the mirror »
- Examples:
  - « remets-la à l'endroit » → `{"action":"resetOrientation"}`
  - « c'est à l'envers » → `{"action":"resetOrientation","degrees":180}`
  - « it's upside down » → `{"action":"resetOrientation","degrees":180}`
- Check: rotation changed.

### perspective

Perspective / Perspective. Straightens converging lines. *Redresse les lignes fuyantes.*

- Domains: photo; core in: none; category geometry; phase geometry; runs as handler (IntentAction.operation).
- Needs: changes the geometry.
- Card: `perspective: {horizontal -100..100 / vertical -100..100}* — Straightens converging lines « fix the perspective »`
- Params:
  - `horizontal` number -100…100 (signedPercent), one of group `axes`: left ↔ right keystone
  - `vertical` number -100…100 (signedPercent), one of group `axes`: top ↔ bottom keystone
- Triggers (fr): « perspective », « corrige la perspective », « lignes fuyantes », « lignes de fuite », « redresse les verticales », « les verticales », « redresse les lignes », « trapèze », « bâtiment penché », « bâtiment droit », « immeuble droit », « façade droite », « façade », « tombe en arrière »
- Triggers (en): « perspective », « fix the perspective », « keystone », « converging lines », « straighten the verticals », « the verticals », « parallel verticals », « straight building », « leaning building »
- Examples:
  - « corrige la perspective » → `{"action":"perspective","vertical":25}`
  - « corrige la perspective verticale de 20 » → `{"action":"perspective","vertical":20}`
  - « redresse les verticales du bâtiment » → `{"action":"perspective","vertical":30}`
  - « fix the perspective » → `{"action":"perspective","vertical":25}`
  - « keystone correction, horizontal -15 » → `{"action":"perspective","horizontal":-15}`
  - « redresse l'horizon » is not this: `straighten`
- Check: perspective changed.

### addText

Add text / Ajouter du texte. Writes words on the picture or page. *Écrit des mots sur l'image ou la page.*

- Domains: pdf, photo, video; core in: pdf, photo, video; category text; phase text; runs as IntentAction.addText.
- Card: `addText: text*:"…", placement:…, color:name|#hex, ref:t1|l1|o1|f1, size:"…" — Writes words on the picture or page`
  - `placement: top|center|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing`
- Params:
  - `text` text ≤ 200, required: the words, verbatim
  - `placement` one of `top`, `center`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, optional: where on the frame (also `position`)
  - `color` colour name or #RRGGBB, optional: colour name or #RRGGBB (also `colour`, `couleur`)
  - `ref` id tn/ln/on/fn, optional: f1 inside, t1 under that text
  - `box` box [x1, y1, x2, y2] 0–1000, optional: [x1,y1,x2,y2] 0-1000; off the card
  - `size` text ≤ 12, optional: small|medium|large|title, x1.5
  - `weight` one of `regular`, `medium`, `semibold`, `bold`, optional: font weight; off the card
  - `align` one of `left`, `center`, `right`, optional: alignment; off the card
  - `font` one of `sans`, `serif`, `mono`, `rounded`, optional: font design; off the card
  - `match` text ≤ 8, optional: copy the style of: nearby or t3; off the card
- Triggers (fr): « ajoute le texte », « écris », « mets le texte », « ajoute un titre », « légende », « texte en haut », « texte en bas »
- Triggers (en): « add text », « write », « add a title », « caption », « text at the top », « text saying »
- Examples:
  - « ajoute le texte Été 2026 en haut en jaune » → `{"action":"addText","color":"yellow","placement":"top","text":"Été 2026"}`
  - « écris « Bon anniversaire » en bas » → `{"action":"addText","placement":"bottom","text":"Bon anniversaire"}`
  - « ajoute le texte Approuvé en haut » → `{"action":"addText","placement":"top","text":"Approuvé"}`
  - « add text saying Happy Birthday at the bottom » → `{"action":"addText","placement":"bottom","text":"Happy Birthday"}`
  - « write Summer 2026 at the top in yellow » → `{"action":"addText","color":"yellow","placement":"top","text":"Summer 2026"}`
- Check: textLayerCount increased.

### editText

Edit text / Modifier le texte. New words or style for a text, same look. *Nouveaux mots ou style pour un texte.*

- Domains: photo, video; core in: photo; category text; phase refDependent; runs as IntentAction.editText.
- Card: `editText: ref:t1|l1, text:"…", color:name|#hex, size:"…", weight:regular|medium|semibold|bold, placement:… — New words or style for a text, same look`
  - `placement: top|center|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing`
- Params:
  - `ref` id tn/ln, optional: t3 printed, l2 yours
  - `text` text ≤ 200, optional: the new words
  - `color` colour name or #RRGGBB, optional: colour name or #RRGGBB (also `colour`, `couleur`)
  - `size` text ≤ 12, optional: small|medium|large|title, x1.5
  - `weight` one of `regular`, `medium`, `semibold`, `bold`, optional: font weight
  - `font` one of `sans`, `serif`, `mono`, `rounded`, optional: font design; off the card
  - `align` one of `left`, `center`, `right`, optional: alignment; off the card
  - `placement` one of `top`, `center`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, optional: where on the frame (also `position`)
- Triggers (fr): « change le texte », « remplace le texte », « corrige le texte », « modifie le titre », « en gras », « plus gros », « police », « déplace le titre », « titre en haut », « titre en bas »
- Triggers (en): « change the text », « edit the text », « replace the text », « make the title bold », « bigger title », « move the title »
- Examples:
  - « change le texte en Hello » → `{"action":"editText","text":"Hello"}`
  - « mets le titre en gras » → `{"action":"editText","ref":"l1","weight":"bold"}`
  - « remplace « 2025 » par « 2026 » » → `{"action":"editText","ref":"t1","text":"2026"}`
  - « change the text to Hello » → `{"action":"editText","text":"Hello"}`
- Check: pixels textPresent changed (from W2).

### removeText

Remove text / Enlever le texte. Erases a text block or a layer. *Efface un bloc de texte ou un calque.*

- Domains: pdf, photo, video; core in: none; category text; phase refDependent; runs as IntentAction.removeText.
- Card: `removeText: ref:t1|l1 — Erases a text block or a layer « remove the text »`
- Params:
  - `ref` id tn/ln, optional: t3 printed, l2 yours
  - `text` text ≤ 200, optional: pdf: all or pageNumber; off the card
- Triggers (fr): « enlève le texte », « supprime le texte », « efface le titre », « enlève le titre », « efface le texte », « enlève la note », « efface la note »
- Triggers (en): « remove the text », « delete the text », « erase the title », « remove the caption », « remove the note »
- Examples:
  - « enlève le texte » → `{"action":"removeText"}`
  - « efface le titre » → `{"action":"removeText","ref":"l1"}`
  - « remove the text » → `{"action":"removeText"}`
- Check: pixels textAbsent changed (from W2).

### moveText

Move text / Déplacer le texte. Moves a text block. *Déplace un bloc de texte.*

- Domains: photo; core in: none; category text; phase refDependent; runs as IntentAction.moveText.
- Card: `moveText: ref:t1|l1, {placement:… / box:[x1,y1,x2,y2] 0-1000 / point:[x,y] 0-1000}* — Moves a text block « move the title to the bottom »`
  - `placement: top|center|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing`
- Params:
  - `ref` id tn/ln, optional: t3 or l2
  - `placement` one of `top`, `center`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, one of group `to`: where on the frame (also `position`)
  - `box` box [x1, y1, x2, y2] 0–1000, one of group `to`: [x1,y1,x2,y2] 0-1000
  - `point` point [x, y] 0–1000, one of group `to`: [x,y] where it is, 0-1000
  - `degrees` number -360…360 (degrees), one of group `to`: direction: 0 right, 90 up (also `angle`); off the card
  - `amount` number 0…1 (fraction), optional: distance (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « déplace le titre », « déplace le texte », « monte le texte », « descends le titre », « mets le texte en haut »
- Triggers (en): « move the title », « move the text », « move the caption up »
- Examples:
  - « déplace le titre en haut » → `{"action":"moveText","placement":"top","ref":"l1"}`
  - « mets ce texte en bas à droite » → `{"action":"moveText","placement":"bottomTrailing","ref":"t2"}`
  - « move the title to the bottom » → `{"action":"moveText","placement":"bottom","ref":"l1"}`
- Check: unverifiable: the new place is judged by eye.

### textBehind

Text behind / Texte derrière. A title behind the person. *Un titre derrière la personne.*

- Domains: photo; core in: none; category text; phase text; runs as IntentAction.textBehind.
- Needs: a subject, fast to run.
- Card: `textBehind: text:"…" — A title behind the person « put the title behind me »`
- Params:
  - `text` text ≤ 60, optional: the words
- Triggers (fr): « texte derrière », « derrière la personne », « effet profondeur », « titre derrière », « effet écran verrouillé »
- Triggers (en): « text behind », « behind the person », « depth effect », « lock screen effect », « title behind »
- Examples:
  - « écris « Paris » derrière la personne » → `{"action":"textBehind","text":"Paris"}`
  - « effet profondeur avec le mot Été » → `{"action":"textBehind","text":"Été"}`
  - « put the title behind me » → `{"action":"textBehind","text":"Summer"}`
- Check: textLayerCount increased.

### fillCells

Fill cells / Remplir des cases. Writes values in table cells, one step. *Écrit des valeurs dans les cases, en une étape.*

- Domains: photo; core in: photo; category table; phase refDependent; runs as IntentAction.fillCells.
- Needs: a table.
- Card: `fillCells: {text:"…" / values:random|sequence|plausible|list}*, cells:empty|all, row:"…", column:"…" — Writes values in table cells, one step`
- Params:
  - `text` text ≤ 200, one of group `content`: the value; list: a|b|c
  - `values` one of `random`, `sequence`, `plausible`, `list`, one of group `content`: generated values
  - `cells` one of `empty`, `all`, optional: empty cells (default) or all
  - `row` text ≤ 40, optional: row name or number, several with |
  - `column` text ≤ 40, optional: column name or number
  - `min` number -1000000000…1000000000 (none), optional: smallest value; off the card
  - `max` number -1000000000…1000000000 (none), optional: largest value; off the card
  - `decimals` integer 0…3, optional: decimal places; off the card
  - `color` colour name or #RRGGBB, one of group `content`: colour name or #RRGGBB (also `colour`, `couleur`); off the card
  - `weight` one of `regular`, `medium`, `semibold`, `bold`, one of group `content`: font weight; off the card
  - `size` text ≤ 12, one of group `content`: small|medium|large|title, x1.5; off the card
- Triggers (fr): « remplis », « remplis les cases », « cases vides », « le tableau », « la colonne », « la ligne », « au hasard », « des chiffres », « complète le tableau »
- Triggers (en): « fill », « fill the cells », « empty cells », « the table », « the column », « the row », « random numbers », « complete the table »
- Examples:
  - « remplis les cases vides avec des 1 » → `{"action":"fillCells","cells":"empty","text":"1"}`
  - « mets des nombres au hasard entre 50 et 90 » → `{"action":"fillCells","max":90,"min":50,"values":"random"}`
  - « remplis la colonne Prix avec 10 » → `{"action":"fillCells","column":"Prix","text":"10"}`
  - « fill the empty cells with zeros » → `{"action":"fillCells","cells":"empty","text":"0"}`
  - « put random numbers in the Score column » → `{"action":"fillCells","column":"Score","values":"random"}`
- Check: textLayerCount increased.

### clearCells

Clear cells / Vider des cases. Empties table cells. *Vide des cases du tableau.*

- Domains: photo; core in: none; category table; phase refDependent; runs as IntentAction.clearCells.
- Needs: a table.
- Card: `clearCells: {row:"…" / column:"…" / cells:empty|all}* — Empties table cells « clear the second column »`
- Params:
  - `row` text ≤ 40, one of group `cells`: row name or number, several with |
  - `column` text ≤ 40, one of group `cells`: column name or number
  - `cells` one of `empty`, `all`, one of group `cells`: empty cells (default) or all
- Triggers (fr): « vide la colonne », « vide la ligne », « efface la colonne », « vide les cases », « efface les valeurs »
- Triggers (en): « clear the column », « clear the row », « empty the cells », « clear the values »
- Examples:
  - « vide la colonne Total » → `{"action":"clearCells","column":"Total"}`
  - « efface toute la ligne 3 » → `{"action":"clearCells","cells":"all","row":"3"}`
  - « clear the second column » → `{"action":"clearCells","cells":"all","column":"2"}`
- Check: unverifiable: emptied cells are checked by OCR from W2.

### highlightCells

Highlight cells / Surligner des cases. A translucent box over rows or columns. *Un fond coloré sur des lignes ou colonnes.*

- Domains: photo; core in: none; category table; phase refDependent; runs as IntentAction.highlightCells.
- Needs: a table.
- Card: `highlightCells: {row:"…" / column:"…"}*, color:name|#hex — A translucent box over rows or columns « highlight the last row »`
- Params:
  - `row` text ≤ 40, one of group `cells`: row name or number, several with |
  - `column` text ≤ 40, one of group `cells`: column name or number
  - `color` colour name or #RRGGBB, optional: colour name or #RRGGBB (also `colour`, `couleur`)
- Triggers (fr): « surligne la colonne », « surligne la ligne », « colore la ligne », « mets en évidence la colonne »
- Triggers (en): « highlight the column », « highlight the row », « shade the row »
- Examples:
  - « surligne la colonne Total en jaune » → `{"action":"highlightCells","color":"yellow","column":"Total"}`
  - « colore la ligne 2 en vert » → `{"action":"highlightCells","color":"green","row":"2"}`
  - « highlight the last row » → `{"action":"highlightCells","row":"-1"}`
- Check: unverifiable: the highlight is judged by eye.

### selectLayer

Select layer / Sélectionner un calque. Picks the layer the next edits apply to. *Choisit le calque des prochaines retouches.*

- Domains: photo; core in: none; category layers; phase composition; runs as IntentAction.selectLayer.
- Card: `selectLayer: choiceIndex -1..99, text:text|image — Picks the layer the next edits apply to « select layer 2 »`
- Params:
  - `choiceIndex` integer -1…99, optional: layer number, -1 top
  - `text` one of `text`, `image`, optional: the text or the photo
- Triggers (fr): « sélectionne le calque », « choisis le calque », « prends le calque », « active le calque », « va au calque », « passe au calque », « sélectionne le texte », « sélectionne la photo »
- Triggers (en): « select the layer », « select layer », « go to layer », « take the layer », « select the text layer »
- Examples:
  - « sélectionne le calque 2 » → `{"action":"selectLayer","choiceIndex":2}`
  - « sélectionne le texte » → `{"action":"selectLayer","text":"text"}`
  - « select layer 2 » → `{"action":"selectLayer","choiceIndex":2}`
- Check: unverifiable: only the selection changes.

### duplicateLayer

Duplicate layer / Dupliquer le calque. Copies the selected layer. *Copie le calque sélectionné.*

- Domains: photo; core in: none; category layers; phase composition; runs as IntentAction.duplicateLayer.
- Card: `duplicateLayer: — Copies the selected layer « duplicate the layer »`
- Triggers (fr): « duplique le calque », « copie le calque », « duplique », « calque »
- Triggers (en): « duplicate the layer », « copy the layer », « duplicate », « layer »
- Examples:
  - « duplique le calque » → `{"action":"duplicateLayer"}`
  - « copie le calque » → `{"action":"duplicateLayer"}`
  - « duplicate the layer » → `{"action":"duplicateLayer"}`
- Check: layerCount increased.

### deleteLayer

Delete layer / Supprimer le calque. Removes the selected layer. *Supprime le calque sélectionné.*

- Domains: photo; core in: none; category layers; phase composition; runs as IntentAction.deleteLayer.
- Needs: a layer above the photo, destructive.
- Card: `deleteLayer: — Removes the selected layer « delete the layer »`
- Triggers (fr): « supprime le calque », « efface le calque », « enlève le calque », « calque »
- Triggers (en): « delete the layer », « remove the layer », « delete layer », « layer »
- Examples:
  - « supprime le calque » → `{"action":"deleteLayer"}`
  - « enlève le calque » → `{"action":"deleteLayer"}`
  - « delete the layer » → `{"action":"deleteLayer"}`
- Check: layerCount decreased.

### layerOpacity

Layer opacity / Opacité du calque. How see-through a layer is. *La transparence d'un calque.*

- Domains: photo; core in: none; category layers; phase composition; runs as handler (IntentAction.operation).
- Needs: a layer above the photo.
- Card: `layerOpacity: ref:l1|s1|i1, opacity* 0..100 — How see-through a layer is « set the layer opacity to 50 »`
- Params:
  - `ref` id ln/sn/in, optional: l2, s1, i1; none: selected (also `layer`)
  - `opacity` number 0…100 (percent), required: 0 invisible, 100 solid (also `amount`, `value`)
- Triggers (fr): « opacité », « opacité du calque », « transparence du calque », « calque transparent », « rends le calque transparent »
- Triggers (en): « opacity », « layer opacity », « transparency of the layer », « see-through »
- Examples:
  - « baisse l'opacité du calque à 50 % » → `{"action":"layerOpacity","opacity":50}`
  - « mets le calque l2 à 30 % d'opacité » → `{"action":"layerOpacity","opacity":30,"ref":"l2"}`
  - « rends le texte à moitié transparent » → `{"action":"layerOpacity","opacity":50,"ref":"l1"}`
  - « set the layer opacity to 50 » → `{"action":"layerOpacity","opacity":50}`
  - « opa du calque à 80 » (paraphrase) → `{"action":"layerOpacity","opacity":80}`
- Check: layerOpacity equals `opacity`.

### layerBlend

Blend mode / Mode de fusion. How a layer mixes with what is below. *Comment un calque se mêle au dessous.*

- Domains: photo; core in: none; category layers; phase composition; runs as handler (IntentAction.operation).
- Needs: a layer above the photo.
- Card: `layerBlend: ref:l1|s1|i1, mode*:… — How a layer mixes with what is below « set the blend mode to multiply »`
  - `mode: normal|multiply|screen|overlay|softLight|hardLight|darken|lighten|difference|luminosity|color|hue|colorBurn|colorDodge|linearBurn|linearDodge|linearLight|vividLight|pinLight|hardMix|exclusion|subtract|divide|saturation|darkerColor|lighterColor|dissolve`
- Params:
  - `ref` id ln/sn/in, optional: l2, s1, i1; none: selected (also `layer`)
  - `mode` one of `normal`, `multiply`, `screen`, `overlay`, `softLight`, `hardLight`, `darken`, `lighten`, `difference`, `luminosity`, `color`, `hue`, `colorBurn`, `colorDodge`, `linearBurn`, `linearDodge`, `linearLight`, `vividLight`, `pinLight`, `hardMix`, `exclusion`, `subtract`, `divide`, `saturation`, `darkerColor`, `lighterColor`, `dissolve`, required: blend mode (also `blendMode`, `blend`)
- Triggers (fr): « mode de fusion », « mode produit », « en mode produit », « mode superposition », « mode écran », « mode lumière tamisée », « mode incrustation », « mode différence », « fusion du calque », « calque en mode », « calque en produit », « calque en superposition », « calque en écran », « calque en éclaircir », « calque en obscurcir », « calque en incrustation », « calque en lumière tamisée »
- Triggers (en): « blend mode », « blending mode », « multiply mode », « screen mode », « overlay mode », « soft light », « set to multiply », « layer to multiply », « layer to screen », « layer to overlay », « layer to lighten », « layer to darken »
- Examples:
  - « mets le calque en mode produit » → `{"action":"layerBlend","mode":"multiply"}`
  - « mode de fusion superposition » → `{"action":"layerBlend","mode":"overlay"}`
  - « passe le texte en mode écran » → `{"action":"layerBlend","mode":"screen","ref":"l1"}`
  - « set the blend mode to multiply » → `{"action":"layerBlend","mode":"multiply"}`
  - « screen blend mode for the text layer » → `{"action":"layerBlend","mode":"screen","ref":"l1"}`
  - « calque en lumière tamisée » (paraphrase) → `{"action":"layerBlend","mode":"softLight"}`
  - « fusionne les calques » is not this: no operation yet
- Check: layerBlend equals `mode`.

### layerVisibility

Show or hide layer / Afficher ou masquer. Hides or shows a layer. *Masque ou affiche un calque.*

- Domains: photo; core in: none; category layers; phase composition; runs as handler (IntentAction.operation).
- Needs: a layer above the photo.
- Card: `layerVisibility: ref:l1|s1|i1, visible*:true|false — Hides or shows a layer « hide the layer »`
- Params:
  - `ref` id ln/sn/in, optional: l2, s1, i1; none: selected (also `layer`)
  - `visible` true or false, required: false hides it (also `shown`, `show`)
- Triggers (fr): « masque le calque », « cache le calque », « affiche le calque », « réaffiche le calque », « calque invisible », « calque visible », « éteins le calque », « allume le calque », « calque éteint », « calque allumé »
- Triggers (en): « hide the layer », « show the layer », « layer visibility », « make the layer invisible », « unhide the layer », « turn the layer off », « turn off the layer », « turn the layer on », « turn on the layer », « layer off »
- Examples:
  - « masque le calque » → `{"action":"layerVisibility","visible":false}`
  - « réaffiche le calque l1 » → `{"action":"layerVisibility","ref":"l1","visible":true}`
  - « cache le calque du texte » → `{"action":"layerVisibility","ref":"l1","visible":false}`
  - « hide the layer » → `{"action":"layerVisibility","visible":false}`
  - « supprime le calque » is not this: `deleteLayer`
- Check: layerVisibility equals `visible`.

### layerOrder

Layer order / Ordre des calques. Brings a layer forward or sends it back. *Avance ou recule un calque.*

- Domains: photo; core in: none; category layers; phase composition; runs as handler (IntentAction.operation).
- Needs: a layer above the photo.
- Card: `layerOrder: ref:l1|s1|i1, position*:front|back|forward|backward — Brings a layer forward or sends it back « bring the layer forward »`
- Params:
  - `ref` id ln/sn/in, optional: l2, s1, i1; none: selected (also `layer`)
  - `position` one of `front`, `back`, `forward`, `backward`, required: where it goes
- Triggers (fr): « ordre des calques », « calque au premier plan », « calque en arrière-plan », « passe devant », « passe derrière », « monte le calque », « descends le calque », « calque au-dessus », « calque en dessous », « derrière tout », « devant tout », « tout derrière », « tout devant », « en haut de la pile », « en bas de la pile », « haut de la pile »
- Triggers (en): « bring to front », « send to back », « bring forward », « send backward », « layer order », « move the layer up », « move the layer down », « behind everything », « in front of everything », « on top of everything », « top of the stack », « bottom of the stack »
- Examples:
  - « déplace le calque texte en arrière-plan » → `{"action":"layerOrder","position":"back","ref":"l1"}`
  - « mets ce calque au premier plan » → `{"action":"layerOrder","position":"front"}`
  - « passe le calque derrière » → `{"action":"layerOrder","position":"backward"}`
  - « bring the layer forward » → `{"action":"layerOrder","position":"forward"}`
  - « send the text layer to the back » → `{"action":"layerOrder","position":"back","ref":"l1"}`
  - « floute l'arrière-plan » is not this: `blurBackground`
- Check: layerOrder changed.

### trim

Trim / Garder une partie. Keeps only start…end. *Ne garde que début…fin.*

- Domains: video; core in: video; category cut; phase geometry; runs as IntentAction.trim.
- Card: `trim: startSeconds*:s, endSeconds*:s — Keeps only start…end « keep only from 5 to 20 seconds »`
- Params:
  - `startSeconds` number 0…36000 (seconds), required: range start (also `start`, `from`)
  - `endSeconds` number 0…36000 (seconds), required: range end (also `end`, `to`)
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
- Triggers (fr): « garde seulement », « garde de », « ne garde que », « raccourcis à », « garde le passage »
- Triggers (en): « keep only », « trim to », « keep from », « keep the part »
- Examples:
  - « garde seulement de 2 à 8 secondes » → `{"action":"trim","endSeconds":8,"startSeconds":2}`
  - « ne garde que les 10 premières secondes » → `{"action":"trim","endSeconds":10,"startSeconds":0}`
  - « keep only from 5 to 20 seconds » → `{"action":"trim","endSeconds":20,"startSeconds":5}`
- Check: timelineDuration decreased.

### split

Split / Couper en deux. Cuts the clip at a time. *Coupe le clip à un instant.*

- Domains: video; core in: video; category cut; phase geometry; runs as IntentAction.split.
- Card: `split: seconds:s — Cuts the clip at a time « split at 10 seconds »`
- Params:
  - `seconds` number 0…36000 (seconds), optional: where; omit = playhead (also `time`, `at`)
- Triggers (fr): « coupe ici », « coupe à », « scinde », « sépare le clip », « coupe le clip en deux »
- Triggers (en): « split », « cut here », « split at », « cut the clip in two »
- Examples:
  - « coupe ici » → `{"action":"split"}`
  - « coupe à 5 secondes » → `{"action":"split","seconds":5}`
  - « split at 10 seconds » → `{"action":"split","seconds":10}`
- Check: clipCount increased.

### deleteClip

Delete clip / Supprimer le clip. Removes a whole clip. *Enlève un clip entier.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.deleteClip.
- Needs: destructive.
- Card: `deleteClip: clipNumber -1..999 — Removes a whole clip « delete the last clip »`
- Params:
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last; omit = selected (also `clip`)
- Triggers (fr): « supprime le clip », « enlève le clip », « retire le clip », « efface ce clip », « supprime ce plan »
- Triggers (en): « delete the clip », « remove the clip », « delete clip »
- Examples:
  - « supprime le clip 2 » → `{"action":"deleteClip","clipNumber":2}`
  - « supprime ce clip » → `{"action":"deleteClip"}`
  - « supprime le dernier clip » → `{"action":"deleteClip","clipNumber":-1}`
  - « delete the last clip » → `{"action":"deleteClip","clipNumber":-1}`
- Check: clipCount decreased.

### deleteRange

Cut a range / Couper un passage. Removes start…end. *Enlève début…fin.*

- Domains: video; core in: video; category cut; phase geometry; runs as IntentAction.deleteRange.
- Card: `deleteRange: startSeconds*:s, endSeconds:s — Removes start…end « remove from 10 to 12 seconds »`
- Params:
  - `startSeconds` number 0…36000 (seconds), required: range start (also `start`, `from`)
  - `endSeconds` number 0…36000 (seconds), optional: range end (also `end`, `to`)
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
- Triggers (fr): « coupe les », « enlève les », « premières secondes », « dernières secondes », « coupe de », « supprime le passage »
- Triggers (en): « cut the first », « remove the last », « first seconds », « last seconds », « cut from », « delete the part »
- Examples:
  - « coupe les 3 premières secondes » → `{"action":"deleteRange","endSeconds":3,"startSeconds":0}`
  - « coupe le clip 2 de 3 à 5 secondes » → `{"action":"deleteRange","clipNumber":2,"endSeconds":5,"startSeconds":3}`
  - « remove from 10 to 12 seconds » → `{"action":"deleteRange","endSeconds":12,"startSeconds":10}`
  - « coupe les trois premières secondes » (paraphrase) → `{"action":"deleteRange","endSeconds":3,"startSeconds":0}`
- Check: timelineDuration decreased.

### setSpeed

Speed / Vitesse. Faster or slower playback. *Lecture plus rapide ou ralentie.*

- Domains: video; core in: video; category speed; phase geometry; runs as IntentAction.setSpeed.
- Card: `setSpeed: speed* 0.1..8 — Faster or slower playback « slow motion »`
- Params:
  - `speed` number 0.1…8 (multiplier), required: 0.5 slow motion, 2 fast (also `factor`, `rate`)
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
  - `scope` one of `current`, `all`, `selection`, optional: all for every clip; off the card
- Triggers (fr): « accélère », « ralentis », « ralenti », « vitesse », « x2 », « deux fois plus vite », « au ralenti »
- Triggers (en): « speed up », « slow down », « slow motion », « faster », « speed », « twice as fast »
- Examples:
  - « accélère x2 » → `{"action":"setSpeed","speed":2}`
  - « mets le clip 2 au ralenti » → `{"action":"setSpeed","clipNumber":2,"speed":0.5}`
  - « slow motion » → `{"action":"setSpeed","speed":0.5}`
  - « accélère deux fois » (paraphrase) → `{"action":"setSpeed","speed":2}`
- Check: timelineDuration changed.

### reverse

Reverse / Lecture inversée. Plays the clip backwards. *Lit le clip à l'envers.*

- Domains: video; core in: none; category speed; phase geometry; runs as IntentAction.reverse.
- Card: `reverse: — Plays the clip backwards « play it backwards »`
- Params:
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
- Triggers (fr): « inverse la vidéo », « à l'envers », « lecture inversée », « en arrière », « rembobine »
- Triggers (en): « reverse », « play backwards », « rewind effect », « backwards »
- Examples:
  - « inverse la vidéo » → `{"action":"reverse"}`
  - « joue le clip à l'envers » → `{"action":"reverse"}`
  - « play it backwards » → `{"action":"reverse"}`
  - « inverse les clips 1 et 2 » is not this: `moveClip`
- Check: unverifiable: the playback direction is judged by eye.

### freezeFrame

Freeze frame / Arrêt sur image. Holds one frame. *Fige une image.*

- Domains: video; core in: none; category speed; phase geometry; runs as IntentAction.freezeFrame.
- Card: `freezeFrame: seconds:s — Holds one frame « freeze frame at 3 seconds »`
- Params:
  - `seconds` number 0…36000 (seconds), optional: where; omit = playhead (also `time`, `at`)
  - `amount` number 0…100 (percent), optional: hold length (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « fige l'image », « arrêt sur image », « freeze », « image figée »
- Triggers (en): « freeze frame », « freeze the frame », « hold the frame »
- Examples:
  - « fige l'image à 4 secondes » → `{"action":"freezeFrame","seconds":4}`
  - « arrêt sur image ici » → `{"action":"freezeFrame"}`
  - « freeze frame at 3 seconds » → `{"action":"freezeFrame","seconds":3}`
- Check: timelineDuration increased.

### duplicateClip

Duplicate clip / Dupliquer le clip. Copies a clip after itself. *Copie un clip juste après.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.duplicateClip.
- Card: `duplicateClip: clipNumber -1..999 — Copies a clip after itself « duplicate the clip »`
- Params:
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`)
- Triggers (fr): « duplique le clip », « copie le clip », « double le clip », « duplique le plan », « copie le plan », « copie »
- Triggers (en): « duplicate the clip », « copy the clip »
- Examples:
  - « duplique le clip » → `{"action":"duplicateClip"}`
  - « duplique le clip 2 » → `{"action":"duplicateClip","clipNumber":2}`
  - « duplicate the clip » → `{"action":"duplicateClip"}`
- Check: clipCount increased.

### moveClip

Move clip / Déplacer le clip. Moves a clip to a new position. *Change la place d'un clip.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.moveClip.
- Card: `moveClip: clipNumber* -1..999, choiceIndex* 1..999 — Moves a clip to a new position « move clip 2 to the beginning »`
- Params:
  - `clipNumber` integer -1…999, required: the clip moved (also `clip`)
  - `choiceIndex` integer 1…999, required: its new position, 1-based
- Triggers (fr): « déplace le clip », « mets le clip », « au début », « à la fin », « inverse les clips », « échange les clips », « intervertis »
- Triggers (en): « move clip », « move the clip », « to the beginning », « to the end », « swap the clips »
- Examples:
  - « déplace le clip 2 au début » → `{"action":"moveClip","choiceIndex":1,"clipNumber":2}`
  - « inverse les clips 1 et 2 » → `{"action":"moveClip","choiceIndex":2,"clipNumber":1}`
  - « move clip 2 to the beginning » → `{"action":"moveClip","choiceIndex":1,"clipNumber":2}`
- Check: unverifiable: the order is checked by the executor.

### extractFrame

Extract frame / Extraire une image. Saves one frame as a photo. *Enregistre une image en photo.*

- Domains: video; core in: none; category export; phase output; runs as IntentAction.extractFrame.
- Card: `extractFrame: seconds:s — Saves one frame as a photo « grab this frame »`
- Params:
  - `seconds` number 0…36000 (seconds), optional: which frame; omit = playhead (also `time`, `at`)
- Triggers (fr): « extrais l'image », « capture d'écran », « fais une photo de », « enregistre cette image »
- Triggers (en): « extract a frame », « screenshot », « grab this frame », « save the frame »
- Examples:
  - « extrais l'image à 3 secondes » → `{"action":"extractFrame","seconds":3}`
  - « fais une capture d'écran » → `{"action":"extractFrame"}`
  - « grab this frame » → `{"action":"extractFrame"}`
- Check: unverifiable: the photo is saved outside the timeline.

### addTransition

Transition / Transition. A transition between clips. *Une transition entre les clips.*

- Domains: video; core in: video; category transitions; phase effects; runs as IntentAction.addTransition.
- Card: `addTransition: transition*:…, scope:current|all|selection — A transition between clips « add a fade to black between the clips »`
  - `transition: none|crossDissolve|fadeToBlack|fadeToWhite|slideLeft|slideRight|wipeLeft|zoom|blur`
- Params:
  - `transition` one of `none`, `crossDissolve`, `fadeToBlack`, `fadeToWhite`, `slideLeft`, `slideRight`, `wipeLeft`, `zoom`, `blur`, required: the transition (also `kind`, `type`)
  - `scope` one of `current`, `all`, `selection`, optional: all = every cut
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
- Triggers (fr): « transition », « fondu enchaîné », « fondu au noir », « fondu », « glissé », « entre les clips »
- Triggers (en): « transition », « crossfade », « cross dissolve », « fade to black », « slide », « between the clips »
- Examples:
  - « ajoute un fondu enchaîné entre tous les clips » → `{"action":"addTransition","scope":"all","transition":"crossDissolve"}`
  - « ajoute une transition glissée » → `{"action":"addTransition","transition":"slideLeft"}`
  - « add a fade to black between the clips » → `{"action":"addTransition","scope":"all","transition":"fadeToBlack"}`
- Check: unverifiable: transitions are checked by the executor.

### removeTransition

Remove transition / Enlever la transition. Back to a straight cut. *Revient à une coupe franche.*

- Domains: video; core in: none; category transitions; phase effects; runs as IntentAction.removeTransition.
- Card: `removeTransition: scope:current|all|selection — Back to a straight cut « remove the transitions »`
- Params:
  - `scope` one of `current`, `all`, `selection`, optional: all = every cut
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
- Triggers (fr): « enlève la transition », « supprime les transitions », « sans transition », « coupe franche »
- Triggers (en): « remove the transition », « no transition », « hard cut »
- Examples:
  - « enlève la transition » → `{"action":"removeTransition"}`
  - « supprime toutes les transitions » → `{"action":"removeTransition","scope":"all"}`
  - « remove the transitions » → `{"action":"removeTransition","scope":"all"}`
- Check: unverifiable: transitions are checked by the executor.

### stabilize

Stabilise / Stabiliser. Steadies shaky footage. *Calme les tremblements.*

- Domains: video; core in: none; category motion; phase cleanup; runs as IntentAction.stabilize.
- Needs: heavy to run.
- Card: `stabilize: — Steadies shaky footage « stabilize the video »`
- Params:
  - `clipNumber` integer -1…999, optional: clip 1.., -1 last (also `clip`); off the card
  - `scope` one of `current`, `all`, `selection`, optional: all clips; off the card
- Triggers (fr): « stabilise », « stabilisation », « ça tremble », « tremblements », « image qui bouge »
- Triggers (en): « stabilise », « stabilize », « shaky », « steady the shot »
- Examples:
  - « stabilise la vidéo » → `{"action":"stabilize"}`
  - « ça tremble, stabilise » → `{"action":"stabilize"}`
  - « stabilize the video » → `{"action":"stabilize"}`
- Check: unverifiable: stability is judged by eye.

### autoCaptions

Captions / Sous-titres. Subtitles from the speech, or a new style. *Sous-titres tirés de la voix, ou un style.*

- Domains: video; core in: video; category captions; phase text; runs as IntentAction.autoCaptions.
- Needs: heavy to run.
- Card: `autoCaptions: text:classic|karaoke|reveal|boxed|minimal — Subtitles from the speech, or a new style « add captions »`
- Params:
  - `text` one of `classic`, `karaoke`, `reveal`, `boxed`, `minimal`, optional: caption style
- Triggers (fr): « sous-titres », « sous-titre », « transcris », « karaoké », « légendes automatiques », « sous-titres karaoké »
- Triggers (en): « captions », « subtitles », « transcribe », « karaoke captions », « auto captions »
- Examples:
  - « ajoute des sous-titres » → `{"action":"autoCaptions"}`
  - « ajoute des sous-titres karaoké » → `{"action":"autoCaptions","text":"karaoke"}`
  - « passe les sous-titres en style encadré » → `{"action":"autoCaptions","text":"boxed"}`
  - « add captions » → `{"action":"autoCaptions"}`
  - « sous titres » (paraphrase) → `{"action":"autoCaptions"}`
  - « mets les sous-titres en haut » is not this: no operation yet
- Check: captions changed.

### removeCaptions

Remove captions / Enlever les sous-titres. Takes the subtitles off. *Retire les sous-titres.*

- Domains: video; core in: none; category captions; phase text; runs as IntentAction.removeCaptions.
- Needs: captions.
- Card: `removeCaptions: — Takes the subtitles off « remove the captions »`
- Triggers (fr): « enlève les sous-titres », « supprime les sous-titres », « sans sous-titres »
- Triggers (en): « remove the captions », « delete the subtitles », « no captions »
- Examples:
  - « enlève les sous-titres » → `{"action":"removeCaptions"}`
  - « supprime les sous-titres » → `{"action":"removeCaptions"}`
  - « remove the captions » → `{"action":"removeCaptions"}`
- Check: captions changed.

### translateCaptions

Translate captions / Traduire les sous-titres. Subtitles in another language. *Sous-titres dans une autre langue.*

- Domains: video; core in: none; category captions; phase text; runs as IntentAction.translateCaptions.
- Needs: captions, fast to run.
- Card: `translateCaptions: text*:en|fr|es|de|it|pt|ja|zh|ko — Subtitles in another language « translate the captions to French »`
- Params:
  - `text` one of `en`, `fr`, `es`, `de`, `it`, `pt`, `ja`, `zh`, `ko`, required: language code
- Triggers (fr): « traduis les sous-titres », « sous-titres en anglais », « traduction », « en espagnol »
- Triggers (en): « translate the captions », « captions in English », « translate the subtitles »
- Examples:
  - « traduis les sous-titres en anglais » → `{"action":"translateCaptions","text":"en"}`
  - « mets les sous-titres en espagnol » → `{"action":"translateCaptions","text":"es"}`
  - « translate the captions to French » → `{"action":"translateCaptions","text":"fr"}`
- Check: captions changed.

### removeSilences

Jump cuts / Couper les blancs. Removes the pauses in speech. *Enlève les pauses de la voix.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.removeSilences.
- Needs: fast to run.
- Card: `removeSilences: amount 0.2..0.45 — Removes the pauses in speech « remove the silences »`
- Params:
  - `amount` number 0.2…0.45 (fraction), optional: 0.2 gentle … 0.45 tight (also `value`, `strength`, `intensity`)
- Triggers (fr): « enlève les blancs », « supprime les blancs », « coupe les blancs », « les blancs », « coupe les silences », « temps morts », « jump cut », « enlève les pauses », « plus rythmé »
- Triggers (en): « remove the silences », « jump cuts », « cut the pauses », « snappier »
- Examples:
  - « enlève les blancs » → `{"action":"removeSilences"}`
  - « coupe les silences, serré » → `{"action":"removeSilences","amount":0.45}`
  - « remove the silences » → `{"action":"removeSilences"}`
- Check: timelineDuration decreased.

### removeFillers

Remove fillers / Enlever les euh. Cuts the ums and stutters. *Coupe les euh et les hésitations.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.removeFillers.
- Needs: fast to run.
- Card: `removeFillers: — Cuts the ums and stutters « remove the ums »`
- Triggers (fr): « enlève les euh », « les hésitations », « les euh », « les heu », « mots parasites »
- Triggers (en): « remove the ums », « filler words », « the ums », « hesitations »
- Examples:
  - « enlève les euh » → `{"action":"removeFillers"}`
  - « coupe les hésitations » → `{"action":"removeFillers"}`
  - « remove the ums » → `{"action":"removeFillers"}`
  - « enlève les heu » (paraphrase) → `{"action":"removeFillers"}`
- Check: timelineDuration decreased.

### cutWords

Cut words / Couper des mots. Cuts where these words are said. *Coupe là où ces mots sont dits.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.cutWords.
- Needs: fast to run.
- Card: `cutWords: text*:"…", scope:current|all — Cuts where these words are said « cut where I say basically »`
- Params:
  - `text` text ≤ 120, required: the exact words
  - `scope` one of `current`, `all`, optional: all = every time
  - `target` text ≤ 40, optional: sentence = the whole sentence (also `object`, `subject`); off the card
- Triggers (fr): « coupe le moment où je dis », « enlève le mot », « coupe quand je dis », « supprime la phrase »
- Triggers (en): « cut where I say », « remove the word », « cut the sentence »
- Examples:
  - « coupe le moment où je dis bref » → `{"action":"cutWords","text":"bref"}`
  - « enlève chaque fois que je dis genre » → `{"action":"cutWords","scope":"all","text":"genre"}`
  - « cut where I say basically » → `{"action":"cutWords","text":"basically"}`
- Check: timelineDuration decreased.

### trackSubject

Follow subject / Suivre le sujet. An overlay follows the moving subject. *Un élément suit le sujet qui bouge.*

- Domains: video; core in: none; category overlays; phase composition; runs as IntentAction.trackSubject.
- Needs: a subject, heavy to run.
- Card: `trackSubject: text:text|image|video|shape — An overlay follows the moving subject « make the title follow the person »`
- Params:
  - `text` one of `text`, `image`, `video`, `shape`, optional: which overlay (also `overlay`)
  - `amount` number 0…100 (percent), optional: 0 stops following (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « suit le visage », « fais suivre », « suivi », « suit la personne », « suis-le », « colle au sujet »
- Triggers (en): « follow the subject », « track », « track the subject », « track the person », « tracking », « follow the face », « pin to the person »
- Examples:
  - « fais suivre le titre au visage » → `{"action":"trackSubject","text":"text"}`
  - « le texte doit suivre la personne » → `{"action":"trackSubject","text":"text"}`
  - « make the title follow the person » → `{"action":"trackSubject","text":"text"}`
  - « track the cyclist » (paraphrase) → `{"action":"trackSubject"}`
- Check: unverifiable: tracking is judged by eye.

### splitScenes

Split scenes / Couper aux changements de plan. Cuts wherever the shot changes. *Coupe à chaque changement de plan.*

- Domains: video; core in: none; category cut; phase geometry; runs as IntentAction.splitScenes.
- Needs: fast to run.
- Card: `splitScenes: scope:current|all — Cuts wherever the shot changes « split at every scene change »`
- Params:
  - `scope` one of `current`, `all`, optional: all clips
  - `amount` number 0…1 (fraction), optional: sensitivity (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « coupe à chaque plan », « détecte les plans », « changements de plan », « découpe les scènes »
- Triggers (en): « split scenes », « detect the shots », « cut at every shot », « scene detection »
- Examples:
  - « coupe à chaque changement de plan » → `{"action":"splitScenes","scope":"all"}`
  - « détecte les plans » → `{"action":"splitScenes"}`
  - « split at every scene change » → `{"action":"splitScenes","scope":"all"}`
- Check: clipCount increased.

### animateText

Animate title / Animer le titre. How the title comes on screen. *Comment le titre apparaît.*

- Domains: video; core in: none; category text; phase text; runs as IntentAction.animateText.
- Card: `animateText: text*:pop|rise|wipe|focus|drift|none — How the title comes on screen « make the title pop in »`
- Params:
  - `text` one of `pop`, `rise`, `wipe`, `focus`, `drift`, `none`, required: the animation
- Triggers (fr): « anime le titre », « animation du texte », « fais apparaître le titre », « titre qui rebondit »
- Triggers (en): « animate the title », « text animation », « title pops in »
- Examples:
  - « anime le titre en pop » → `{"action":"animateText","text":"pop"}`
  - « fais monter le titre doucement » → `{"action":"animateText","text":"rise"}`
  - « make the title pop in » → `{"action":"animateText","text":"pop"}`
- Check: unverifiable: the motion is judged by eye.

### highlights

Highlights / Résumé. A recap of the best moments. *Un résumé des meilleurs moments.*

- Domains: video; core in: none; category story; phase geometry; runs as IntentAction.highlights.
- Needs: heavy to run.
- Card: `highlights: seconds:s — A recap of the best moments « make a 20 second recap »`
- Params:
  - `seconds` number 0…36000 (seconds), optional: recap length, 5-300 s (also `time`, `at`)
- Triggers (fr): « résumé », « fais un résumé », « meilleurs moments », « best of », « version courte »
- Triggers (en): « recap », « highlights », « best moments », « highlight reel », « short version »
- Examples:
  - « fais un résumé de 20 secondes » → `{"action":"highlights","seconds":20}`
  - « garde les meilleurs moments » → `{"action":"highlights"}`
  - « make a 20 second recap » → `{"action":"highlights","seconds":20}`
- Check: timelineDuration decreased.

### speedRamp

Speed ramp / Rampe de vitesse. Eases into slow motion and back. *Glisse vers le ralenti puis revient.*

- Domains: video; core in: none; category speed; phase geometry; runs as IntentAction.speedRamp.
- Card: `speedRamp: amount 0.1..1, seconds:s — Eases into slow motion and back « speed ramp into slow motion »`
- Params:
  - `amount` number 0.1…1 (multiplier), optional: slowest speed, 0.3 (also `value`, `strength`, `intensity`)
  - `seconds` number 0…36000 (seconds), optional: around; omit = playhead (also `time`, `at`)
- Triggers (fr): « rampe de vitesse », « ralenti progressif », « ralentis progressivement », « speed ramp »
- Triggers (en): « speed ramp », « ramp into slow motion », « slow-mo ramp »
- Examples:
  - « fais une rampe de vitesse » → `{"action":"speedRamp"}`
  - « ralenti progressif à 6 secondes » → `{"action":"speedRamp","amount":0.3,"seconds":6}`
  - « speed ramp into slow motion » → `{"action":"speedRamp","amount":0.3}`
- Check: timelineDuration increased.

### punchIns

Zoom cuts / Zooms de coupe. Every other segment framed tighter. *Un segment sur deux cadré plus serré.*

- Domains: video; core in: none; category motion; phase effects; runs as IntentAction.punchIns.
- Card: `punchIns: amount 1..1.5 — Every other segment framed tighter « add punch-ins »`
- Params:
  - `amount` number 1…1.5 (multiplier), optional: zoom 1-1.5, 0 removes (also `value`, `strength`, `intensity`)
- Triggers (fr): « zooms de coupe », « punch in », « zoom à chaque coupe », « recadre plus serré une fois sur deux »
- Triggers (en): « punch ins », « zoom cuts », « punch-in », « zoom on every cut »
- Examples:
  - « ajoute des zooms de coupe » → `{"action":"punchIns","amount":1.2}`
  - « zoom à chaque coupe » → `{"action":"punchIns"}`
  - « add punch-ins » → `{"action":"punchIns","amount":1.2}`
- Check: unverifiable: framing is judged by eye.

### blurFaces

Blur faces / Flouter les visages. Every face blurred through the clips. *Tous les visages floutés dans les clips.*

- Domains: video; core in: none; category effects; phase effects; runs as IntentAction.blurFaces.
- Needs: heavy to run.
- Card: `blurFaces: scope:current|all — Every face blurred through the clips « blur all the faces »`
- Params:
  - `scope` one of `current`, `all`, optional: all clips
  - `amount` number 0…100 (percent), optional: 0 shows them again (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « floute les visages », « anonymise », « cache les visages », « pixelise les visages »
- Triggers (en): « blur the faces », « anonymise », « hide the faces », « pixelate faces »
- Examples:
  - « floute les visages » → `{"action":"blurFaces","scope":"all"}`
  - « anonymise les gens » → `{"action":"blurFaces"}`
  - « blur all the faces » → `{"action":"blurFaces","scope":"all"}`
- Check: unverifiable: the blur is judged by eye.

### smartReframe

Smart reframe / Recadrage intelligent. New shape, following the subject. *Nouveau format qui suit le sujet.*

- Domains: video; core in: none; category motion; phase geometry; runs as IntentAction.smartReframe.
- Needs: a subject, heavy to run, changes the geometry.
- Card: `smartReframe: aspect*:… — New shape, following the subject « reframe for reels following the person »`
  - `aspect: original|free|square|ratio4x3|ratio3x4|ratio3x2|ratio2x3|ratio16x9|ratio9x16|ratio21x9|ratio5x4|ratio4x5`
- Params:
  - `aspect` one of `original`, `free`, `square`, `ratio4x3`, `ratio3x4`, `ratio3x2`, `ratio2x3`, `ratio16x9`, `ratio9x16`, `ratio21x9`, `ratio5x4`, `ratio4x5`, required: the frame shape (also `ratio`, `format`)
- Triggers (fr): « passe en vertical », « en vertical », « vertical », « en suivant le sujet », « suis le sujet », « suivre le sujet », « le cadre suit », « format TikTok », « recadre en suivant », « pour les reels »
- Triggers (en): « make it vertical », « vertical », « follow the subject », « reframe », « for TikTok », « for reels »
- Examples:
  - « passe en vertical en suivant le sujet » → `{"action":"smartReframe","aspect":"ratio9x16"}`
  - « c'est pour TikTok » → `{"action":"smartReframe","aspect":"ratio9x16"}`
  - « reframe for reels following the person » → `{"action":"smartReframe","aspect":"ratio9x16"}`
  - « met la en vertical » (paraphrase) → `{"action":"smartReframe","aspect":"ratio9x16"}`
- Check: canvasAspect equals `aspect`.

### kenBurns

Ken Burns / Zoom lent. A slow push-in or drift. *Un zoom ou travelling lent.*

- Domains: video; core in: none; category motion; phase effects; runs as IntentAction.kenBurns.
- Card: `kenBurns: scope:current|all — A slow push-in or drift « add a slow zoom »`
- Params:
  - `scope` one of `current`, `all`, optional: all clips
  - `amount` number 0…100 (percent), optional: 0 removes it (also `value`, `strength`, `intensity`); off the card
- Triggers (fr): « zoom lent », « zoom avant progressif », « zoom progressif », « travelling lent », « effet Ken Burns », « mouvement de caméra »
- Triggers (en): « ken burns », « slow zoom », « slow push-in », « gentle zoom », « camera move »
- Examples:
  - « ajoute un zoom lent » → `{"action":"kenBurns"}`
  - « ajoute un zoom avant progressif sur la personne » → `{"action":"kenBurns"}`
  - « effet Ken Burns sur tous les clips » → `{"action":"kenBurns","scope":"all"}`
  - « add a slow zoom » → `{"action":"kenBurns"}`
- Check: unverifiable: the move is judged by eye.

### mute

Mute / Couper le son. Silences a clip or a track. *Rend muet un clip ou une piste.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.mute.
- Card: `mute: clipNumber -1..999, scope:current|all|selection — Silences a clip or a track « mute the music »`
- Params:
  - `clipNumber` integer -1…999, optional: clip, or track with scope selection (also `clip`)
  - `scope` one of `current`, `all`, `selection`, optional: selection = a sound track
- Triggers (fr): « coupe le son », « enlève le son », « muet », « sans le son », « silence »
- Triggers (en): « mute », « no sound », « silence the clip », « turn off the sound »
- Examples:
  - « coupe le son » → `{"action":"mute"}`
  - « enlève le son du clip 3 » → `{"action":"mute","clipNumber":3}`
  - « mute the music » → `{"action":"mute","clipNumber":1,"scope":"selection"}`
- Check: unverifiable: sound is checked by the executor.

### unmute

Unmute / Remettre le son. Brings the sound back. *Remet le son.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.unmute.
- Card: `unmute: clipNumber -1..999, scope:current|all|selection — Brings the sound back « unmute it »`
- Params:
  - `clipNumber` integer -1…999, optional: clip, or track with scope selection (also `clip`)
  - `scope` one of `current`, `all`, `selection`, optional: selection = a sound track
- Triggers (fr): « remets le son », « réactive le son », « avec le son »
- Triggers (en): « unmute », « sound back on », « turn the sound on »
- Examples:
  - « remets le son » → `{"action":"unmute"}`
  - « réactive le son du clip 2 » → `{"action":"unmute","clipNumber":2}`
  - « unmute it » → `{"action":"unmute"}`
- Check: unverifiable: sound is checked by the executor.

### setVolume

Volume / Volume. Louder or quieter, 0-200 %. *Plus fort ou moins fort, 0-200 %.*

- Domains: video; core in: video; category audio; phase composition; runs as IntentAction.setVolume.
- Card: `setVolume: amount* 0..200, clipNumber -1..999, scope:current|all|selection — Louder or quieter, 0-200 % « turn the music down to 30 percent »`
- Params:
  - `amount` number 0…200 (percent), required: percent; relative ± (also `value`, `strength`, `intensity`)
  - `amountMode` one of `relative`, `absolute`, `multiplier`, optional: relative more/less, absolute set to; off the card
  - `clipNumber` integer -1…999, optional: clip, or track with scope selection (also `clip`)
  - `scope` one of `current`, `all`, `selection`, optional: selection = a sound track
- Triggers (fr): « volume », « baisse le son », « monte le son », « plus fort », « moins fort », « la musique à »
- Triggers (en): « volume », « louder », « quieter », « turn it down », « turn up the music »
- Examples:
  - « baisse le son de 20 % » → `{"action":"setVolume","amount":-20}`
  - « monte le volume de la musique à 80 % » → `{"action":"setVolume","amount":80,"amountMode":"absolute","clipNumber":1,"scope":"selection"}`
  - « mets la musique à 30 % » → `{"action":"setVolume","amount":30,"amountMode":"absolute","clipNumber":1,"scope":"selection"}`
  - « turn the music down to 30 percent » → `{"action":"setVolume","amount":30,"amountMode":"absolute","clipNumber":1,"scope":"selection"}`
- Check: unverifiable: sound is checked by the executor.

### addMusic

Add sound / Ajouter du son. Another sound track: music, voice-over. *Une autre piste : musique, voix off.*

- Domains: video; core in: video; category audio; phase composition; runs as IntentAction.addMusic.
- Needs: a audio the user picks.
- Card: `addMusic: text:"…", seconds:s, scope:current|selection — Another sound track: music, voice-over « add some calm music »`
- Params:
  - `text` text ≤ 60, optional: what kind: upbeat music
  - `seconds` number 0…36000 (seconds), optional: where it starts (also `time`, `at`)
  - `scope` one of `current`, `selection`, optional: selection replaces the music
- Triggers (fr): « ajoute de la musique », « mets une musique », « voix off », « ajoute un son », « bande son », « change la musique »
- Triggers (en): « add music », « add a song », « voice-over », « add a sound », « soundtrack », « change the music »
- Examples:
  - « ajoute de la musique entraînante » → `{"action":"addMusic","text":"upbeat"}`
  - « ajoute une voix off » → `{"action":"addMusic"}`
  - « ajoute un deuxième son à 10 secondes » → `{"action":"addMusic","seconds":10}`
  - « add some calm music » → `{"action":"addMusic","text":"calm"}`
- Check: unverifiable: the user picks the sound before a track is added.

### removeMusic

Remove sound track / Enlever la musique. Removes a sound track. *Enlève une piste son.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.removeMusic.
- Card: `removeMusic: clipNumber -1..999 — Removes a sound track « remove the music »`
- Params:
  - `clipNumber` integer -1…999, optional: track 1.., -1 last; omit = all (also `clip`)
- Triggers (fr): « enlève la musique », « supprime la musique », « sans musique », « supprime la piste »
- Triggers (en): « remove the music », « delete the soundtrack », « no music »
- Examples:
  - « enlève la musique » → `{"action":"removeMusic"}`
  - « supprime la deuxième piste son » → `{"action":"removeMusic","clipNumber":2}`
  - « remove the music » → `{"action":"removeMusic"}`
- Check: audioTrackCount decreased.

### moveAudio

Move sound / Déplacer le son. Moves a track to a time. *Déplace une piste à un instant.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.moveAudio.
- Card: `moveAudio: clipNumber -1..999, seconds*:s — Moves a track to a time « start the music at 3 seconds »`
- Params:
  - `clipNumber` integer -1…999, optional: track 1.. (also `clip`)
  - `seconds` number 0…36000 (seconds), required: new start (also `time`, `at`)
- Triggers (fr): « décale la musique », « fais commencer la musique », « déplace le son », « la musique commence à »
- Triggers (en): « move the music », « start the music at », « shift the sound »
- Examples:
  - « fais commencer la musique à 5 secondes » → `{"action":"moveAudio","clipNumber":1,"seconds":5}`
  - « décale la piste 2 à 12 secondes » → `{"action":"moveAudio","clipNumber":2,"seconds":12}`
  - « start the music at 3 seconds » → `{"action":"moveAudio","clipNumber":1,"seconds":3}`
- Check: unverifiable: sound is checked by the executor.

### fadeAudio

Fade sound / Fondu sonore. Fade-in or fade-out of a track. *Fondu d'entrée ou de sortie d'une piste.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.fadeAudio.
- Card: `fadeAudio: clipNumber -1..999, amount:s, text:in|out — Fade-in or fade-out of a track « fade out the music »`
- Params:
  - `clipNumber` integer -1…999, optional: track 1.. (also `clip`)
  - `amount` number 0…10 (seconds), optional: fade length, s (also `value`, `strength`, `intensity`)
  - `text` one of `in`, `out`, optional: omit for both
- Triggers (fr): « fondu de la musique », « fondu sonore », « fais un fondu », « fade out », « fondu à la fin »
- Triggers (en): « fade the music », « fade out », « fade in », « audio fade »
- Examples:
  - « fais un fondu de la musique à la fin » → `{"action":"fadeAudio","clipNumber":1,"text":"out"}`
  - « fondu sonore de 3 secondes au début » → `{"action":"fadeAudio","amount":3,"clipNumber":1,"text":"in"}`
  - « fade out the music » → `{"action":"fadeAudio","clipNumber":1,"text":"out"}`
- Check: unverifiable: sound is checked by the executor.

### autoDuck

Auto duck / Atténuation auto. Music dips under the voice. *La musique baisse sous la voix.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.autoDuck.
- Card: `autoDuck: amount 0..0.9 — Music dips under the voice « duck the music under the voice »`
- Params:
  - `amount` number 0…0.9 (fraction), optional: depth 0.3-0.9, 0 off (also `value`, `strength`, `intensity`)
- Triggers (fr): « baisse la musique quand je parle », « atténuation », « ducking », « musique sous la voix »
- Triggers (en): « duck the music », « ducking », « music under the voice », « lower the music when I talk »
- Examples:
  - « baisse la musique quand je parle » → `{"action":"autoDuck"}`
  - « atténuation forte de la musique » → `{"action":"autoDuck","amount":0.8}`
  - « duck the music under the voice » → `{"action":"autoDuck"}`
- Check: unverifiable: sound is checked by the executor.

### syncToBeat

Cut to the beat / Couper au rythme. Moves cuts onto the music's beat. *Place les coupes sur le temps.*

- Domains: video; core in: none; category audio; phase geometry; runs as IntentAction.syncToBeat.
- Needs: a audio the user picks, fast to run.
- Card: `syncToBeat: — Moves cuts onto the music's beat « cut to the beat »`
- Triggers (fr): « coupe au rythme », « sur le rythme », « sur le beat », « synchronise avec la musique »
- Triggers (en): « cut to the beat », « sync to the music », « on the beat », « beat sync »
- Examples:
  - « coupe au rythme de la musique » → `{"action":"syncToBeat"}`
  - « synchronise les coupes sur le beat » → `{"action":"syncToBeat"}`
  - « cut to the beat » → `{"action":"syncToBeat"}`
- Check: unverifiable: the beat match is judged by ear.

### fitMusic

Fit the music / Ajuster la musique. The song ends with the video. *La musique finit avec la vidéo.*

- Domains: video; core in: none; category audio; phase composition; runs as IntentAction.fitMusic.
- Needs: a audio the user picks, fast to run.
- Card: `fitMusic: — The song ends with the video « fit the music to the video »`
- Triggers (fr): « ajuste la musique », « la musique finit avec », « cale la musique », « fin de la musique »
- Triggers (en): « fit the music », « end the music with the video », « music ends »
- Examples:
  - « ajuste la musique à la durée » → `{"action":"fitMusic"}`
  - « fais finir la musique avec la vidéo » → `{"action":"fitMusic"}`
  - « fit the music to the video » → `{"action":"fitMusic"}`
- Check: unverifiable: sound is checked by the executor.

### enhanceVoice

Enhance voice / Voix claire. Removes background noise from speech. *Enlève le bruit autour de la voix.*

- Domains: video; core in: none; category audio; phase cleanup; runs as IntentAction.enhanceVoice.
- Needs: heavy to run.
- Card: `enhanceVoice: scope:current|all — Removes background noise from speech « clean up the audio »`
- Params:
  - `scope` one of `current`, `all`, optional: all clips
- Triggers (fr): « isole la voix », « voix plus claire », « améliore la voix », « ma voix », « voix », « enlève le bruit de fond », « le son est pourri », « nettoie le son »
- Triggers (en): « enhance the voice », « isolate the voice », « my voice », « voice », « remove the background noise », « clean the audio »
- Examples:
  - « isole la voix » → `{"action":"enhanceVoice"}`
  - « enlève le bruit de fond » → `{"action":"enhanceVoice","scope":"all"}`
  - « clean up the audio » → `{"action":"enhanceVoice"}`
- Check: unverifiable: voice clarity is judged by ear.

### goToPage

Go to page / Aller à la page. Shows a page. *Affiche une page.*

- Domains: pdf; core in: pdf; category pages; phase refDependent; runs as IntentAction.goToPage.
- Card: `goToPage: clipNumber* -1..9999 — Shows a page « go to page 2 »`
- Params:
  - `clipNumber` integer -1…9999, required: page 1.., -1 last (also `page`, `pageNumber`)
- Triggers (fr): « va à la page », « montre la page », « page suivante », « dernière page », « ouvre la page »
- Triggers (en): « go to page », « show page », « next page », « last page »
- Examples:
  - « va à la page 4 » → `{"action":"goToPage","clipNumber":4}`
  - « montre-moi la dernière page » → `{"action":"goToPage","clipNumber":-1}`
  - « go to page 2 » → `{"action":"goToPage","clipNumber":2}`
- Check: unverifiable: only the view changes.

### deletePage

Delete page / Supprimer la page. Removes a page. *Enlève une page.*

- Domains: pdf; core in: pdf; category pages; phase geometry; runs as IntentAction.deletePage.
- Needs: destructive.
- Card: `deletePage: clipNumber -1..9999 — Removes a page « delete page 2 »`
- Params:
  - `clipNumber` integer -1…9999, optional: page 1.., -1 last (also `page`, `pageNumber`)
- Triggers (fr): « supprime la page », « enlève la page », « efface la page », « retire la page »
- Triggers (en): « delete page », « remove the page », « delete the last page »
- Examples:
  - « supprime la page 3 » → `{"action":"deletePage","clipNumber":3}`
  - « enlève la dernière page » → `{"action":"deletePage","clipNumber":-1}`
  - « delete page 2 » → `{"action":"deletePage","clipNumber":2}`
- Check: pageCount changes by -1.

### rotatePage

Rotate page / Pivoter la page. Turns a page or every page. *Tourne une page ou toutes.*

- Domains: pdf; core in: pdf; category pages; phase geometry; runs as IntentAction.rotatePage.
- Card: `rotatePage: clipNumber -1..9999, degrees -270..270, scope:current|all — Turns a page or every page « rotate page 3 to the left »`
- Params:
  - `clipNumber` integer -1…9999, optional: page 1.., -1 last (also `page`, `pageNumber`)
  - `degrees` number -270…270 (degrees), optional: 90, 180, -90 (also `angle`)
  - `scope` one of `current`, `all`, optional: all = every page
- Triggers (fr): « pivote la page », « tourne la page », « pivote toutes les pages », « page à l'envers »
- Triggers (en): « rotate the page », « rotate page », « rotate all pages », « page is upside down »
- Examples:
  - « pivote toutes les pages » → `{"action":"rotatePage","degrees":90,"scope":"all"}`
  - « tourne la page 2 à l'envers » → `{"action":"rotatePage","clipNumber":2,"degrees":180}`
  - « rotate page 3 to the left » → `{"action":"rotatePage","clipNumber":3,"degrees":-90}`
- Check: unverifiable: the page rotation is checked by the executor.

### movePage

Move page / Déplacer la page. Moves a page to a new position. *Change la place d'une page.*

- Domains: pdf; core in: pdf; category pages; phase geometry; runs as IntentAction.movePage.
- Card: `movePage: clipNumber -1..9999, choiceIndex* -1..9999 — Moves a page to a new position « move page 3 to position 1 »`
- Params:
  - `clipNumber` integer -1…9999, optional: the page moved; omit = current (also `page`, `pageNumber`)
  - `choiceIndex` integer -1…9999, required: its new position, -1 the end
- Triggers (fr): « déplace la page », « mets la page », « à la fin », « au début », « en première position »
- Triggers (en): « move page », « move the page », « to the end », « to the beginning »
- Examples:
  - « déplace la page 2 à la fin » → `{"action":"movePage","choiceIndex":-1,"clipNumber":2}`
  - « mets la page 5 en première position » → `{"action":"movePage","choiceIndex":1,"clipNumber":5}`
  - « move page 3 to position 1 » → `{"action":"movePage","choiceIndex":1,"clipNumber":3}`
- Check: pageCount unchanged.

### duplicatePage

Duplicate page / Dupliquer la page. Copies a page after itself. *Copie une page juste après.*

- Domains: pdf; core in: none; category pages; phase geometry; runs as IntentAction.duplicatePage.
- Card: `duplicatePage: clipNumber -1..9999 — Copies a page after itself « duplicate page 2 »`
- Params:
  - `clipNumber` integer -1…9999, optional: page 1.., -1 last (also `page`, `pageNumber`)
- Triggers (fr): « duplique la page », « copie la page », « double la page »
- Triggers (en): « duplicate page », « copy the page »
- Examples:
  - « duplique la page 1 » → `{"action":"duplicatePage","clipNumber":1}`
  - « copie cette page » → `{"action":"duplicatePage"}`
  - « duplicate page 2 » → `{"action":"duplicatePage","clipNumber":2}`
- Check: pageCount changes by 1.

### insertBlankPage

Insert blank page / Insérer une page blanche. A blank page at a position. *Une page vierge à un endroit.*

- Domains: pdf; core in: pdf; category pages; phase geometry; runs as IntentAction.insertBlankPage.
- Card: `insertBlankPage: clipNumber -1..9999, scope:current|selection — A blank page at a position « insert a blank page after page 1 »`
- Params:
  - `clipNumber` integer -1…9999, optional: page; after it with scope selection (also `page`, `pageNumber`)
  - `scope` one of `current`, `selection`, optional: selection = after the page
- Triggers (fr): « page blanche », « insère une page », « ajoute une page vide », « page vierge »
- Triggers (en): « blank page », « insert a page », « add an empty page »
- Examples:
  - « insère une page blanche après la page 2 » → `{"action":"insertBlankPage","clipNumber":2,"scope":"selection"}`
  - « ajoute une page vide » → `{"action":"insertBlankPage"}`
  - « insert a blank page after page 1 » → `{"action":"insertBlankPage","clipNumber":1,"scope":"selection"}`
- Check: pageCount changes by 1.

### extractPage

Extract page / Extraire la page. Saves a page as its own PDF. *Enregistre une page dans un PDF à part.*

- Domains: pdf; core in: pdf; category export; phase output; runs as IntentAction.extractPage.
- Card: `extractPage: clipNumber -1..9999 — Saves a page as its own PDF « extract page 3 »`
- Params:
  - `clipNumber` integer -1…9999, optional: page 1.., -1 last (also `page`, `pageNumber`)
- Triggers (fr): « extrais la page », « sors la page », « exporte la page », « page à part »
- Triggers (en): « extract page », « save the page as a PDF », « export this page »
- Examples:
  - « extrais la page 2 » → `{"action":"extractPage","clipNumber":2}`
  - « exporte cette page à part » → `{"action":"extractPage"}`
  - « extract page 3 » → `{"action":"extractPage","clipNumber":3}`
- Check: unverifiable: the extracted file is saved outside the document.

### highlightText

Highlight / Surligner. Highlights the words where they appear. *Surligne les mots là où ils sont.*

- Domains: pdf; core in: pdf; category annotate; phase text; runs as IntentAction.highlightText.
- Card: `highlightText: text*:"…", color:name|#hex, scope:current|all — Highlights the words where they appear « highlight the word total »`
- Params:
  - `text` text ≤ 120, required: the words
  - `color` colour name or #RRGGBB, optional: colour name or #RRGGBB (also `colour`, `couleur`)
  - `scope` one of `current`, `all`, optional: all = whole document
- Triggers (fr): « surligne », « surligne le mot », « fluo », « mets en évidence »
- Triggers (en): « highlight », « highlight the word », « mark the word »
- Examples:
  - « surligne le mot contrat » → `{"action":"highlightText","text":"contrat"}`
  - « surligne « date limite » en vert partout » → `{"action":"highlightText","color":"green","scope":"all","text":"date limite"}`
  - « highlight the word total » → `{"action":"highlightText","text":"total"}`
- Check: markupCount increased.

### underlineText

Underline or strike / Souligner ou barrer. Underlines words; red strikes them out. *Souligne ; en rouge, barre les mots.*

- Domains: pdf; core in: none; category annotate; phase text; runs as IntentAction.underlineText.
- Card: `underlineText: text*:"…", color:name|#hex, scope:current|all — Underlines words; red strikes them out « underline the word deadline »`
- Params:
  - `text` text ≤ 120, required: the words
  - `color` colour name or #RRGGBB, optional: red strikes out (also `colour`, `couleur`)
  - `scope` one of `current`, `all`, optional: all = whole document
- Triggers (fr): « souligne », « souligne le mot », « trait sous », « trace un trait », « barre le mot », « rature »
- Triggers (en): « underline », « strike out », « strikethrough », « cross out »
- Examples:
  - « souligne le mot total en rouge » → `{"action":"underlineText","color":"red","text":"total"}`
  - « barre le mot brouillon » → `{"action":"underlineText","color":"red","text":"brouillon"}`
  - « underline the word deadline » → `{"action":"underlineText","text":"deadline"}`
- Check: markupCount increased.

### redactText

Redact / Caviarder. Blacks out words for good. *Noircit des mots définitivement.*

- Domains: pdf; core in: pdf; category annotate; phase text; runs as IntentAction.redactText.
- Needs: destructive.
- Card: `redactText: text*:"…", scope:current|all — Blacks out words for good « redact the name Smith »`
- Params:
  - `text` text ≤ 120, required: the words
  - `scope` one of `current`, `all`, optional: all = whole document
- Triggers (fr): « caviarde », « noircis », « masque le nom », « anonymise le document », « cache le numéro »
- Triggers (en): « redact », « black out », « hide the name », « censor »
- Examples:
  - « caviarde les numéros de téléphone » → `{"action":"redactText","text":"numéros de téléphone"}`
  - « noircis le nom Dupont partout » → `{"action":"redactText","scope":"all","text":"Dupont"}`
  - « redact the name Smith » → `{"action":"redactText","text":"Smith"}`
- Check: markupCount increased.

### findText

Find / Chercher. Finds words in the document. *Trouve des mots dans le document.*

- Domains: pdf; core in: none; category pdfText; phase refDependent; runs as IntentAction.findText.
- Card: `findText: text*:"…", scope:current|all — Finds words in the document « find the word invoice »`
- Params:
  - `text` text ≤ 120, required: the words
  - `scope` one of `current`, `all`, optional: all = whole document
- Triggers (fr): « cherche », « trouve le mot », « où est écrit », « recherche »
- Triggers (en): « find », « search for », « where does it say »
- Examples:
  - « cherche le mot facture » → `{"action":"findText","text":"facture"}`
  - « trouve « échéance » dans le document » → `{"action":"findText","scope":"all","text":"échéance"}`
  - « find the word invoice » → `{"action":"findText","text":"invoice"}`
- Check: unverifiable: a search changes nothing.

### replaceText

Replace text / Remplacer le texte. Replaces words; empty erases them. *Remplace des mots ; vide les efface.*

- Domains: pdf; core in: pdf; category pdfText; phase text; runs as IntentAction.replaceText.
- Card: `replaceText: text*:"…", replacement*:"…", scope:current|all — Replaces words; empty erases them « replace 2025 with 2026 everywhere »`
- Params:
  - `text` text ≤ 120, required: the words there now
  - `replacement` text ≤ 200, required: the new words, "" erases (also `with`, `newText`)
  - `scope` one of `current`, `all`, optional: all = whole document
- Triggers (fr): « remplace », « remplace par », « corrige le mot », « efface le mot », « change le mot »
- Triggers (en): « replace », « replace with », « change the word », « erase the word »
- Examples:
  - « remplace monsieur par madame » → `{"action":"replaceText","replacement":"madame","text":"monsieur"}`
  - « efface le mot brouillon » → `{"action":"replaceText","replacement":"","text":"brouillon"}`
  - « replace 2025 with 2026 everywhere » → `{"action":"replaceText","replacement":"2026","scope":"all","text":"2025"}`
- Check: pixels textAbsent changed (from W2).

### addSignature

Sign / Signer. Places your saved signature. *Place ta signature enregistrée.*

- Domains: pdf; core in: pdf; category sign; phase composition; runs as IntentAction.addSignature.
- Needs: a signature the user picks.
- Card: `addSignature: clipNumber -1..9999, placement:… — Places your saved signature « sign at the bottom »`
  - `placement: top|center|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing`
- Params:
  - `clipNumber` integer -1…9999, optional: page 1.., -1 last (also `page`, `pageNumber`)
  - `placement` one of `top`, `center`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, optional: where on the frame (also `position`)
- Triggers (fr): « signe », « ajoute ma signature », « signature », « signe en bas »
- Triggers (en): « sign », « add my signature », « signature », « sign at the bottom »
- Examples:
  - « signe en bas à droite » → `{"action":"addSignature","placement":"bottomTrailing"}`
  - « ajoute ma signature sur la dernière page » → `{"action":"addSignature","clipNumber":-1}`
  - « sign at the bottom » → `{"action":"addSignature","placement":"bottom"}`
- Check: markupCount increased.

### addPageNumbers

Page numbers / Numéros de page. Numbers every page. *Numérote toutes les pages.*

- Domains: pdf; core in: pdf; category document; phase text; runs as IntentAction.addPageNumbers.
- Card: `addPageNumbers: — Numbers every page « add page numbers »`
- Triggers (fr): « numérote les pages », « numéros de page », « pagination », « ajoute les numéros »
- Triggers (en): « page numbers », « number the pages », « add page numbers »
- Examples:
  - « numérote les pages » → `{"action":"addPageNumbers"}`
  - « ajoute les numéros de page » → `{"action":"addPageNumbers"}`
  - « add page numbers » → `{"action":"addPageNumbers"}`
- Check: markupCount increased.

### mergeDocument

Merge / Fusionner. Adds another PDF or an image. *Ajoute un autre PDF ou une image.*

- Domains: pdf; core in: none; category document; phase composition; runs as IntentAction.mergeDocument.
- Needs: a image the user picks.
- Card: `mergeDocument: text:pdf|image — Adds another PDF or an image « merge it with another PDF »`
- Params:
  - `text` one of `pdf`, `image`, optional: image to place a picture
- Triggers (fr): « fusionne avec », « ajoute un autre PDF », « combine les PDF », « ajoute une image », « insère une photo »
- Triggers (en): « merge with », « add another PDF », « combine the PDFs », « add an image »
- Examples:
  - « fusionne avec un autre PDF » → `{"action":"mergeDocument"}`
  - « ajoute une image » → `{"action":"mergeDocument","text":"image"}`
  - « merge it with another PDF » → `{"action":"mergeDocument"}`
- Check: unverifiable: needs the file picked by the user.

### seek

Go to time / Aller à un instant. Moves the playhead. *Déplace la tête de lecture.*

- Domains: video; core in: none; category cut; phase refDependent; runs as IntentAction.seek.
- Card: `seek: seconds*:s — Moves the playhead « jump to 30 seconds »`
- Params:
  - `seconds` number 0…36000 (seconds), required: the time (also `time`, `at`)
- Triggers (fr): « va à », « secondes », « reviens au début », « place la tête de lecture »
- Triggers (en): « go to », « jump to », « seconds », « back to the start »
- Examples:
  - « va à 10 secondes » → `{"action":"seek","seconds":10}`
  - « reviens au début » → `{"action":"seek","seconds":0}`
  - « jump to 30 seconds » → `{"action":"seek","seconds":30}`
- Check: unverifiable: only the playhead moves.
