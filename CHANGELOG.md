# Changelog

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
