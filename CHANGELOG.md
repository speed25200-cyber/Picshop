# Changelog

## Unreleased — polish loop

- Fluidity: the editors no longer repaint whole screens for per-frame state. The video transport, the timeline's playhead follow, the player's clip label, the progress and toast overlays and the library's thumbnails each observe their own state, so a playhead tick or a progress fraction repaints one row instead of the canvas, the filmstrip, the panel and the dock.
- Fluidity: the renderer's operation cache and the library's decoded-thumbnail cache evict oldest-first instead of growing for the life of the session; the ambient background flattens its gradients into one layer and gains a studio falloff.
- LLM retouching: the instructions are stable per editor and everything that changes between two requests (clip count, playhead, current page, pending question, last adjustment) travels with the request, which both fixes a reused session answering from stale numbers and lets the model read the instructions once. Sessions recycle after eight requests and are dropped on error; the grammar's reading is handed to the engine instead of parsed twice; identical requests in an identical state are answered from a small cache; and the model's time budget is short when the grammar already has a usable plan.
- Editing screens: the video filmstrip sits under the picture with the transport as the last row, comparing with the original is available while a panel is open, the photo canvas carries a hairline edge, and the Home video/PDF actions are one line each so the library starts higher.
- Reduce Motion is respected by everything that moves on its own: the voice meter, the microphone ring and the level rim hold still.

- The library grid no longer decodes JPEGs on the main thread: `thumbnail(for:)` was read from a SwiftUI body for every visible card and hit the disk each time. Thumbnails are now decoded once off the main thread, kept in memory, and refreshed when an editor rewrites one; the previous image stays on screen while a newer one loads.

- The editor draws before the models load: `MLModel(contentsOf:)` ran synchronously on the main actor inside `configure()`, so opening a photo froze on a black canvas for as long as the Neural Engine took to prepare the eraser. The pipeline is now built empty, the first frame is requested immediately, and the engines are attached off the main thread; a fill that arrives while they load waits for them instead of silently using the patch-based fallback. The canvas shows the photo's frame with a spinner rather than black.

- Build stamp: every CI build carries its git commit, branch and date (Home eyebrow, Settings identity card), so a screenshot always says which code produced it.
- Export sheets share one design across photo, video and PDF: a preview of the result, illustrated format / quality segments, size estimate, anchored primary action, inline progress with an animated percentage; the PDF is re-exported each time the sheet opens.
- Home: rename, duplicate and delete (with confirmation) from a long press with a larger preview; illustrated empty tile for an empty filter.
- Video timeline: zoom-aware time ruler, capped playhead, glow on the selected clip, duration chips; speed rail with the resulting clip length; illustrated, localised transition chips; Looks panel with filmstrip thumbnails of the selected clip through every look.
- Photo canvas: double-tap zooms 2.5× around the finger and back; live zoom badge that resets the view; crop frame with a pixel-size readout and a fine grid while dragging or levelling.
- Eraser lists the objects found in the picture as one-tap targets with a crop of each; clarification chips show a crop of each candidate.
- Voice strip: level meter bars while listening, rim and glow that follow the input; toasts offer Undo in place after an applied edit.
- PDF: paper reconstructed under a replaced word on scans (ink filled from the surrounding paper, no flat block); stroke-based face estimation (weight from thickness, serif from stroke variation, sans by default); trailing punctuation kept; the edit sheet previews the replacement in the detected face with a one-tap face override; pages strip lifts the current page.
- Settings: identity header on the mesh tile, performance tier dots, illustrated rendering segments; help sheet with tappable example commands.

## 1.1.0 — fluid UI, thermal budget, deeper understanding

- Design system rebuilt around Apple's rhythm: system-blue accent, concentric radii, one motion vocabulary (`PSMotion`), press feedback on every control, SF Symbols with hierarchical rendering.
- Editor chrome: the dock's active pill and the panel segments slide between entries; tool panels get a grabber and close with a swipe down; hold-to-compare button on the canvas; Dynamic-Island-shaped toasts; ring progress HUD.
- Home: mesh-gradient hero card (no blur passes), sliding filter capsules, thermal banner; onboarding icons on the same mesh.
- Adjust panel: Light / Colour / Detail / Effects families with a sliding segment and a dot on families that were touched.
- Performance governor: thermal state, Low Power Mode and a Settings › Performance preference drive preview size, interactive size, settle delay, frame-rate cap, drawable scale, glow/shadow effects and whether heavy neural work may start.
- Preview rendering is coalesced: one render in flight, latest state wins, sharp frame after the interaction settles; the Metal canvas only redraws when its inputs change. Look thumbnails are cached per photo state.
- Grammar: everyday goals (profile picture, product photo, ID photo, wallpaper, restore, night, backlit, HDR), follow-ups on the last adjustment (encore, a bit more, trop), "but / mais" contrast clauses, corrections during a clarification ("non, le chat"), skin smoothing / teeth / eyes, subjective adjectives (dull, harsh, jaunâtre, muddy…), default sky swap, vague dissatisfaction ("c'est moche").
- Language models receive a retoucher's interpretation guide, the last-adjustment memory and twelve few-shot examples.
- Grounding: an object merged with the person touching it (a laptop and the man typing on it) is separated — the person segmentation is cut out, the remainder split into connected pieces and each piece classified on its own — so "efface le pc portable" erases the laptop, not the user.
- Core Image → CGImage conversion (thumbnails, exports, the Vision analysis image, model outputs) goes through the same bitmap path as the inpainting composite, so every mask lands where the canvas shows it.
- PDF replacements keep the typeface: the text layer's font when there is one, an estimate (family, weight, size, baseline) on scans, drawn as vector text instead of a Times fallback.
- Object removal no longer takes the person along: Vision's foreground instances merge an object with whoever touches it, so non-person targets have the person segmentation subtracted before the mask is used.
- PDF word replacement keeps the typeface: the text layer's font (mapped to an installed face) or, on scans, a face estimated from the glyph proportions and ink density; the new word is drawn as vector text at the original size and baseline instead of a free-text annotation that fell back to Times.

## 1.0.0 (build 10) — redesign

- Editors rebuilt on a shared shell: full-bleed canvas, top bar and controls in the safe area (window insets as fallback), OLED black.
- Voice bar (mic, live transcript, replies, clarification choices) replaces the floating orb.
- Photo: on-canvas crop frame with handles, thirds grid, ratio lock and live straighten; Photos-style ruler dials with haptics; text drag / pinch / rotate; one-tap erase of people, text, animals, vehicles; brush cursor.
- Erase quality: sharp full-resolution composite (no halo), PatchMatch at 1024 px, and the LaMa neural eraser ships in the app.
- Real-ESRGAN ×4 upscaler ships in the app; Generative Fill (Stable Diffusion) and Pro Brain (Qwen3 4B via MLX) download from Hugging Face on demand — no model server.
- Home: prominent photo card, video/PDF pair, two-column recents with dates.
- TestFlight builds now use the Pro project (MLX + Stable Diffusion runtimes).

## 1.0.0 (build 1) — TestFlight candidate

- Voice-driven photo editing (FR/EN): object removal, background cutout/blur/replace, adjustments, looks, crop, text, layers.
- Precision tools: magic wand, lasso, pixel brush, clone stamp, pixel grid, recolor, generative fill (optional Stable Diffusion runtime).
- Video editing: cuts, speed, audio, looks, transitions, text overlays, object removal across clips, stabilisation, reverse, freeze frame.
- PDF editing: page management, markup, signature, search, redaction, export.
- On-device AI brains: instant grammar, Apple Intelligence (Foundation Models), optional MLX Pro Brain.
- Codemagic workflows: TestFlight (signed) and unsigned check.
