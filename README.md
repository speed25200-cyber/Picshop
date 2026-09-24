# PicShop

**Photo and video, magically — on iPhone.**
A Photoshop-grade photo editor and a Vegas-grade video editor in one app, designed like Apple's own:
system Liquid Glass, one edit-yellow accent, and an iridescent glow that appears only when the AI works.
Tap a Magic tool, type what you want, or just say it — *« efface le chien »*, *"add captions"*,
*« coupe sur le rythme »*. Editing runs on the device. **Picshop Live** turns the editor into a spoken
conversation that proposes ideas and edits as you talk: with your own Claude key, once you agree, it talks with
Claude (the text of the conversation and, if you allow it, a reduced picture go to Anthropic — never the audio);
otherwise it stays on the iPhone.

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="PicShop icon">
</p>

## Magic

| Photo | Video |
|---|---|
| **Clean Up**: passers-by erased, the subject kept; erase anything by tap, brush or voice (LaMa + PatchMatch) | **Auto captions** from the voice, word-timed, five styles (karaoke, reveal…) |
| **Magic move**: tap an object, move it — the hole is filled, it lands where you say | **Edit by text**: strike words in the transcript and they leave the video |
| **Generative expand** to any shape: the border is invented (Stable Diffusion or LaMa) | **No more "euh"**: hesitations, stutters and unwritten fillers cut |
| **Focus after the shot**: lens blur from the depth map, or the subject | **Jump cuts**: every pause removed, a breath kept |
| **Text behind the subject** (the Lock Screen depth effect) | **Cuts on the beat**: tempo and beats tracked, cuts moved onto them |
| Cut out, replace or blur the background | **Smart reframe** to 9:16 / 1:1 following faces, people or the salient subject |
| **Match colours** from any reference picture (Lab transfer as a 3D LUT) | **Subject tracking**: titles and stickers stick to a face or a moving object |
| **Best looks** ranked by Vision's aesthetics model | **Automatic ducking**: the music dips under every sentence |
| Generative fill (Stable Diffusion), relight, upscale (Real-ESRGAN), denoise | **Highlights** and **scene detection**: a 30 s recap of the best moments, or a split at every shot |
| A prompt field and voice for anything else, FR/EN | **Clean voice**, **colour match** across clips, **Magic Movie**, animated titles |

## Pro

| Photo | Video |
|---|---|
| Photos-style adjustment dials (19 parameters), tone curves, 20 looks, History (hold Undo) | Multi-lane timeline: centred playhead, pinch zoom, trim handles, captions lane, beat markers |
| **HSL mixer** (8 bands), **three-way colour wheels** and **.cube LUT import**, on the GPU | Per-clip adjustments, looks, **HSL mixer and colour wheels** |
| Layers: text, shapes, blend modes, opacity, masks | Several sound tracks with fades, automatic ducking drawn on the lanes, a mixer |
| Magic wand, lasso, pixel brush, clone stamp, pixel grid | Split, trim, speed, reverse, freeze frame, transitions, titles, **keyframes** on overlays |
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

Outside Picshop Live, commands are understood by three brains, all on the device:

1. **Instant** — a deterministic grammar covering hundreds of phrasings in French and English. It always runs first.
2. **Apple Intelligence** — the system foundation model with guided generation (`@Generable`), constrained to the app's action schema.
3. **Pro Brain** — Qwen3 4B (4-bit) through MLX for long, multi-step requests. Optional download.

Model output is validated against the app vocabulary before execution; hallucinated actions or values are dropped.

**Picshop Live** (the orb in each editor) is a real-time conversation: on-device speech recognition with active
listening and barge-in, a natural system voice, and ideas proposed as chips. Each turn goes to the best brain
available — Claude (`claude-opus-5`, with your own API key, kept in this iPhone's Keychain), then Apple Intelligence,
then the grammar — so Live never goes silent. Claude acts only through four validated tools (apply edits, undo,
compare, propose ideas).

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

No servers, no accounts, no analytics. Everything stays on the iPhone except Picshop Live with Claude: speech
recognition, segmentation and rendering always run on the device, and so does Live without a Claude key. With your
own key, and only after a one-time consent, Live mode sends Anthropic the text of the conversation (what you say or
type during Live), a description of your edits and of the picture, and, if you allow it, a reduced copy (1024 px) of
the photo or video frame without location or camera data. Audio never leaves the device; outside Live mode, nothing
is sent. The privacy manifest (`App/PrivacyInfo.xcprivacy`) declares photos or videos and other user content, used
for app functionality only, not linked to you and never for tracking.

## License

MIT — see [LICENSE](LICENSE).
