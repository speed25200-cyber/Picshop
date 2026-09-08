# Changelog

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
- Core Image → CGImage conversion is probed once at launch; if the device rotates or flips that output, thumbnails, exports and the Vision analysis image are compensated so masks always land where the canvas shows them.
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
