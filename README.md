# PicShop

**Photo and video, magically — on iPhone.**
A Photoshop-grade photo editor and a Vegas-grade video editor in one app, designed like Apple's own:
system Liquid Glass, one edit-yellow accent, and an iridescent glow that appears only when the AI works.
Tap a Magic tool, type what you want, or just say it — *« efface le chien »*, *"add captions"*,
*« coupe sur le rythme »*. Editing runs on the device. **Picshop Live** turns the editor into a spoken
conversation that proposes ideas and edits as you talk — entirely on the iPhone, even in airplane mode.

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
      ─▶ local brain (MLX Qwen3.5) / Apple Foundation Model  for ambiguous requests, 6 s budget
      ─▶ EditPlan (typed intents) ─▶ PhotoCommandExecutor / VideoCommandExecutor
      ─▶ Vision grounding (instance masks · people · animals · text · embeddings)
      ─▶ CandidateSelector ("the one on the left", "the second", "all", or asks which)
      ─▶ EditOperation on the document ─▶ Core Image render ─▶ Metal canvas
```

Commands and Picshop Live are understood by three brains, all on the device:

1. **Instant** — a deterministic grammar covering hundreds of phrasings in French and English. It always runs first.
2. **Local brain** — Qwen3.5 4B (Max) or 2B (Rapide), 4-bit, through MLX. It talks, looks at the photo and calls
   the app's tools. A one-time download (3.06 GB or 1.75 GB) on iPhones with enough memory; the iPhone decides the tier.
3. **Apple Intelligence** — the system foundation model with guided generation (`@Generable`), constrained to the app's action schema.

Model output is validated against the app vocabulary before execution; hallucinated actions or values are dropped.

The grammar reads intent, not only words: everyday goals (*photo de profil*, *product photo for Vinted*, *restore this old
photo*), follow-ups on the last adjustment (*encore un peu*, *too much*), contrast clauses (*brighter but less saturated*),
corrections while PicShop is asking which object (*non, le chat*) and subjective adjectives (*dull*, *jaunâtre*, *harsh*).
See [docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md).

## Picshop Live

The orb in each editor starts a spoken conversation, **entirely on the iPhone** — no account, no key, no server, and it
works the same in airplane mode. Live listens with on-device speech recognition, looks at the photo, answers with the
best system voice installed, proposes three ideas as chips and edits as you talk.

Each turn goes to the best brain available, so Live never goes silent:

1. confident commands (« plus chaud », « annule ») go straight to the grammar, instantly;
2. the **local brain** — Qwen3.5 4B (Max) or 2B (Rapide), 4-bit, through MLX — talks, looks at the photo and calls
   the app's tools;
3. **Apple Intelligence** when the local brain isn't there (not downloaded, still loading, too hot, too little memory);
4. the grammar, which always answers.

The models act only through four validated tools (apply edits, undo, compare before/after, propose ideas); anything
they produce outside the app's vocabulary is dropped. Every failure is shown and said out loud, in French or English.

**Honest expectations.** This is a capable editing assistant that talks, looks at the photo, acts and proposes ideas,
all offline — not a cloud chatbot.

| | Picshop Live |
|---|---|
| Last word → first word heard | about 2 s with the local brain on an A18 Pro or A19 Pro; about 1.2 s for simple commands |
| An edit in words the grammar lacks | a short sentence, then 1.5–3 s more before the edit lands |
| Interrupting | loudspeaker: tap the orb, type, or say « stop ». Headphones, once the voice test has passed: just talk over it |
| Voice | the best voice installed; a Premium or Enhanced French voice (Settings › Accessibility) sounds much better |
| Understanding | short opinions, three ideas grounded in the photo, vague requests (« plus cinéma », « un peu moins ») — not general knowledge |
| Memory | about 15 exchanges, then a recap |

**Which iPhone gets which brain.** The iPhone decides, and Settings › Intelligence says why:

| iPhone | Local brain |
|---|---|
| 16 Pro, 16 Pro Max, 17, Air, 17 Pro, 17 Pro Max (A18 Pro, A19, A19 Pro) | Max · Qwen3.5 4B · 3.06 GB download |
| 15 Pro, 15 Pro Max, 16, 16 Plus, 16e (A17 Pro, A18) | Rapide · Qwen3.5 2B · 1.75 GB download |
| 15, 15 Plus and older (6 GB of memory or less) | none: Apple Intelligence when it is on, otherwise the commands |

The Max tier drops to Rapide in Low Power Mode, with little free memory, after a memory kill or when the speed test is
slow; Settings › Intelligence › Quality can pick Max or Rapide within the memory limits.

**Settings.** Settings › Intelligence: the model, its tier and why, download over Wi‑Fi (cellular only after a
confirmation that shows the size), cancel, delete, storage used, the speed test, Apple Intelligence, and « Préparer Live
à l'ouverture ». Settings › PicShop Live: auto-start, instant commands, duplex conversation with headphones, and
Diagnostic Live with a six-step voice test (permissions, speech model, voice, ear, headphones, brain) and a log to export
that holds no transcript.

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
App/                 iOS app target (entry point, Info.plist, assets, MLX runtime for the local brain)
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
- [docs/MODELS.md](docs/MODELS.md) — the neural models (LaMa, Real-ESRGAN, Stable Diffusion, the Qwen3.5 local brain) and how they are fetched

## Privacy

No servers, no accounts, no analytics. Speech recognition, Live's conversation, language models, segmentation and
rendering run on the device; your photos, videos, voice and words never leave the iPhone. The only network traffic is
the one-time download of large model weights (the local brain from Hugging Face at pinned revisions, Generative Fill),
which sends no user content. The privacy manifest (`App/PrivacyInfo.xcprivacy`) declares no tracking and no data
collection, and the App Store label is « Data Not Collected ».

## License

MIT — see [LICENSE](LICENSE).
