# PicShop

**Photo and video, magically — on iPhone.**
A Photoshop-grade photo editor and a Vegas-grade video editor in one app, designed like Apple's own:
system Liquid Glass, one edit-yellow accent, and an iridescent glow that appears only when the AI works.
Tap a Magic tool, type what you want, or just say it — *« efface le chien »*, *"add captions"*,
*« coupe sur le rythme »*. Everything runs on the device.

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="PicShop icon">
</p>

## Magic

| Photo | Video |
|---|---|
| Erase people and objects by tap, brush or voice (LaMa + PatchMatch) | **Auto captions** from the voice, word-timed, five styles (karaoke, reveal…) |
| **Text behind the subject** (the Lock Screen depth effect) | **Jump cuts**: every pause removed, a breath kept |
| Cut out, replace or blur the background | **Cuts on the beat**: tempo and beats tracked, cuts moved onto them |
| **Match colours** from any reference picture (Lab transfer as a 3D LUT) | **Smart reframe** to 9:16 / 1:1 following faces, people or the salient subject |
| **Best looks** ranked by Vision's aesthetics model | **Clean voice**: Apple's sound isolation, offline |
| Generative fill (Stable Diffusion), relight, upscale (Real-ESRGAN), denoise | **Magic Movie**: clips + photos + a song → an edit cut on the beat, Ken Burns on stills |
| A prompt field and voice for anything else, FR/EN | **Colour match** across clips, Ken Burns moves, stabilisation, object removal across a clip |

## Pro

| Photo | Video |
|---|---|
| Photos-style adjustment dials (19 parameters), tone curves, 20 looks | Multi-lane timeline: centred playhead, pinch zoom, trim handles, captions lane, beat markers |
| **HSL mixer** (8 bands) and **three-way colour wheels**, baked into one GPU LUT | Per-clip adjustments, looks, **HSL mixer and colour wheels** |
| Layers: text, shapes, blend modes, opacity, masks | Several sound tracks with fades, ducking and a mixer |
| Magic wand, lasso, pixel brush, clone stamp, pixel grid | Split, trim, speed, reverse, freeze frame, transitions, text overlays |
| Crop with ratio presets, straighten, perspective | HEVC export in 9:16, 1:1, 16:9 … |

PDF editing (mark-up, signature, word replacement even on scans) comes along.
Everything is undoable, saved as a project package, and exportable to Photos.

## The voice pipeline

```
mic ─▶ SpeechAnalyzer (iOS 26, on-device) ─▶ transcript
      ─▶ RuleBasedIntentEngine  (FR/EN grammar, <1 ms, always on)
      ─▶ Apple Foundation Model / Pro Brain (MLX Qwen3 4B)  for ambiguous requests, 6 s budget
      ─▶ EditPlan (typed intents) ─▶ PhotoCommandExecutor / VideoCommandExecutor
      ─▶ Vision grounding (instance masks · people · animals · text · embeddings)
      ─▶ CandidateSelector ("the one on the left", "the second", "all", or asks which)
      ─▶ EditOperation on the document ─▶ Core Image render ─▶ Metal canvas
```

Three "brains" are available in Settings, all on device:

1. **Instant** — a deterministic grammar covering hundreds of phrasings in French and English. It always runs first.
2. **Apple Intelligence** — the system foundation model with guided generation (`@Generable`), constrained to the app's action schema.
3. **Pro Brain** — Qwen3 4B (4-bit) through MLX for long, multi-step requests. Optional download.

Model output is validated against the app vocabulary before execution; hallucinated actions or values are dropped.

The grammar reads intent, not only words: everyday goals (*photo de profil*, *product photo for Vinted*, *restore this old
photo*), follow-ups on the last adjustment (*encore un peu*, *too much*), contrast clauses (*brighter but less saturated*),
corrections while PicShop is asking which object (*non, le chat*) and subjective adjectives (*dull*, *jaunâtre*, *harsh*).
See [docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md).

## Fluidity and heat

A `PerformanceGovernor` turns the thermal state, Low Power Mode and the Settings › Performance preference into one render
budget: preview size, interactive size, settle delay, frame-rate cap, drawable scale, glow and shadow effects, and whether
heavy neural work may start. Previews are coalesced (one render in flight, latest state wins) and the Metal canvas only
redraws when its inputs change, so a hot phone renders smaller frames before it drops any.

## Requirements

- Xcode 26, iOS 26 SDK. Runs on iPhone 15 Pro and later; tuned for iPhone 17 Pro.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project.

```bash
brew install xcodegen
Scripts/bootstrap.sh          # generates Picshop.xcodeproj
open Picshop.xcodeproj        # set your team, run on device
```

The platform-independent engine (documents, timeline, intent parsing, PatchMatch) builds and tests anywhere Swift runs:

```bash
swift test                    # ~115 tests, ~1 s
```

## Project layout

```
App/                 iOS app target (entry point, Info.plist, assets, optional MLX engine)
Sources/PicshopCore      documents · layers · edit stack · undo history · timeline · intents · project store
  Magic/                 audio analysis (silences, beats) · captions · motion & smart reframe · Magic Movie planner ·
                         beat sync · colour transfer & .cube LUTs · HSL mixer & three-way grading
Sources/PicshopIntent    FR/EN grammar · LLM schema & normaliser · Foundation Models engine · router · executors
Sources/PicshopImaging   Core Image graph · Vision grounding · masks · PatchMatch & Core ML inpainting · export
Sources/PicshopVideo     AVComposition builder · custom compositor · transcoder · AI video services · export
Sources/PicshopSpeech    SpeechAnalyzer / SFSpeechRecognizer voice controller · spoken replies
Sources/PicshopPDF       PDFKit composer (real annotations) · search · signature · page extraction · merge
Sources/PicshopUI        Liquid Glass design system · intelligence glow · Home & Magic Movie · photo & video editors · settings
Tests/                   XCTest suites (core, intent, imaging)
Scripts/                 bootstrap, string catalogue, icon, model conversion & packaging, syntax gate
docs/                    ARCHITECTURE · VOICE_COMMANDS · MODELS
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — modules, data flow, rendering and concurrency model
- [docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md) — what you can say (FR/EN)
- [docs/MODELS.md](docs/MODELS.md) — optional neural models (LaMa, Real-ESRGAN, Qwen3) and how to host them

## Privacy

No servers, no accounts, no analytics. Speech recognition, language models, segmentation and rendering
run on the device. The privacy manifest (`App/PrivacyInfo.xcprivacy`) declares no tracking and no data collection.

## License

MIT — see [LICENSE](LICENSE).
