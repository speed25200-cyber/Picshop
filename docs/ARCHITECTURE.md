# Architecture

PicShop is a Swift package (`PicshopKit`) with six modules plus a thin iOS app target.
The split keeps every piece of logic that does not need Apple frameworks buildable and
testable on Linux/CI, and isolates the Apple-only code behind clear protocols.

```
┌──────────────────────────────────────────────────────────────────────┐
│ App (SwiftUI)  PicshopApp · RootView · MLXLocalRuntime (local brain) │
├──────────────────────────────────────────────────────────────────────┤
│ PicshopUI      AppEnvironment · ProjectLibrary · PhotoEditorSession  │
│                VideoEditorSession · canvas · timeline · voice orb     │
├───────────────┬───────────────┬───────────────┬──────────────────────┤
│ PicshopPDF    │               │               │                      │
│ PDFKit compose│               │               │                      │
│ search·export │               │               │                      │
├───────────────┼───────────────┼───────────────┼──────────────────────┤
│ PicshopSpeech │ PicshopImaging│ PicshopVideo  │ PicshopIntent        │
│ SpeechAnalyzer│ CI graph      │ AVComposition │ grammar · LLM · router│
│ SFSpeech      │ Vision ground │ compositor    │ executors · selector │
│               │ PatchMatch/ML │ transcoder    │                      │
├───────────────┴───────────────┴───────────────┴──────────────────────┤
│ PicshopCore    PhotoDocument · Layer · EditStack · EditHistory       │
│                VideoTimeline · EditIntent/EditPlan · ProjectStore    │
└──────────────────────────────────────────────────────────────────────┘
```

## Documents are values

`PhotoDocument` and `VideoTimeline` are `Codable`, `Hashable` value types. Pixels are never
inside them — layers and clips reference media by path inside the project package. This makes
undo trivial (`EditHistory` stores whole snapshots), persistence a JSON write, and rendering a
pure function of the document.

A photo layer carries an `EditStack`: an ordered list of `EditOperation`s. Adjustment operations
are flattened (`resolvedAdjustments`), geometric ones are replayed in order, and pixel-synthesis
operations (`removeObject`, `heal`, `upscale`) are cached by operation id and render size.

A project package on disk:

```
<uuid>.picshop/
  project.json      Project { photo | video }
  media/            originals + AI-rendered derivatives (erased clips, stabilised clips…)
  masks/            8-bit PNG masks referenced by MaskReference.relativePath
  thumbnail.jpg
```

## From speech to pixels

1. **`VoiceController`** captures audio with `AVAudioEngine` and streams it into `SpeechAnalyzer`
   (iOS 26) or `SFSpeechRecognizer` (on-device mode). It publishes the input level for the orb,
   detects the end of an utterance (silence after speech) and delivers the final transcript.
2. **`HybridIntentRouter`** runs `RuleBasedIntentEngine` first. The grammar segments the utterance
   ("… et …", "… puis …"), recognises hundreds of FR/EN phrasings, numbers, times, colours, spatial
   hints and ordinals, and produces `EditIntent`s with a confidence. If the result is not confident
   (unknown noun, unusual phrasing), the preferred language model is asked with a 6 s budget and the
   grammar's guess as a hint. `IntentNormalizer` validates every model field against the vocabulary
   (`IntentAction`, `AdjustmentParameter`, `FilterPreset`, `AspectPreset`, `TransitionKind`…).
   The budget is tiered: a short slot when the grammar already has a usable plan and the model is
   only being asked to do better, the full one when the grammar came up empty. Identical requests in
   an identical editor state are answered from a small cache instead of running inference again.
   **The prompt is split on purpose.** `IntentPrompt.systemInstructions(mode:)` holds only what stays
   true for the whole editing session, so there is one model session per editor whose instructions the
   model reads once; everything that changes between two requests — clip count, playhead, page number,
   the pending clarification, the last adjustment — goes in `IntentPrompt.userPrompt`. Putting any of
   those back in the instructions reintroduces the bug where a cached session planned "split here"
   from a stale playhead. Sessions recycle after a few requests so their transcript cannot grow into
   the context window, and are dropped on error.
3. **Executors** (`PhotoCommandExecutor`, `VideoCommandExecutor`) turn intents into document
   mutations. Anything that needs vision goes through the `PhotoAIServices` / `VideoAIServices`
   protocols, so the executors are fully unit-tested with fakes.
4. **Grounding** (`VisionGrounding`) finds candidates for a target:
   people via `VNDetectHumanRectanglesRequest` + person segmentation, faces, animals
   (`VNRecognizeAnimalsRequest`), text (`VNRecognizeTextRequest`), and everything else via
   foreground instance masks classified with `VNClassifyImageRequest` and matched against the
   vocabulary — or, for unknown nouns, against `NLEmbedding` word similarity. Colour adjectives
   re-rank candidates by mean colour.
5. **`CandidateSelector`** applies "the left one", "the second", "the biggest", "all", tap points,
   or asks the user when several equally likely matches remain. The question is answered by voice
   ("celle de droite"), by tapping the numbered box, or by the chips under the canvas.
6. **Rendering**: `PhotoRenderer` (an actor) replays the edit stack with Core Image, applying
   `AdjustmentPipeline` (the same mapping used for video), and hands a `CIImage` to
   `MetalCanvasView`. Previews render at ≤2048 px (1280 px while dragging), exports at full size.

## Inpainting

`InpaintingPipeline` crops a context window around the mask, resamples it to the inpainter's
working size, runs the inpainter, upsamples the fill and composites it back **only inside the
feathered mask**, so untouched pixels stay bit-exact at full resolution.

- `PatchMatchInpainter` (`PatchMatchCore`, pure Swift, unit-tested): coarse-to-fine nearest-neighbour
  field search with propagation + random search, weighted voting, and a structure/texture fusion step
  that keeps the diffusion prior's low frequencies where the surroundings are smooth (skies, skin,
  gradients) and pure patch synthesis where they are textured.
- `CoreMLInpainter` runs a converted LaMa network through `CoreMLImageModel`, which discovers input
  names/sizes from the model description. When installed it becomes the neural path automatically.

## Precision tools & generative fill

`Selection` (pure Swift) implements the magic wand (colour-tolerance flood fill with despeckling) and lasso
(scanline polygon fill); `VisionGrounding.magicWandMask/lassoMask` persist them as `MaskReference`s that any
operation can consume: `removeObject` (erase), `recolor` (luminance-preserving tint), `generativeFill`
(prompt), `selectiveAdjust`. `pixelPaint` and `cloneStamp` are stroke-based operations rendered by the
same Core Image graph; the canvas shows a pixel grid once zoomed past 6×.

`InpaintingPipeline.generate` reuses the crop → work-size → composite-inside-mask strategy with a
`GenerativeFillEngine`. The app target provides `StableDiffusionFillEngine` (Apple's Core ML Stable
Diffusion runtime, masked image-to-image) when the optional package and resources are present. Voice
commands such as *« remplace le ciel par un coucher de soleil »* become `generativeFill(target: sky,
text: …)`; *"make the car red"* becomes `recolor`, which works offline.

## PDF

`PDFDocumentModel` is a page list referencing the original file (never modified) plus rotation and
`PDFMarkup`s stored in each page's *base* normalised space (`PDFGeometry` converts to/from the rotated
display space and PDF points). `PDFComposer` rebuilds a PDFKit document with real annotations (ink,
highlight/underline/strike-out quads, redaction squares, free text, image/signature stamps) for display
and export. `PDFEditingService` implements `PDFAIServices` (search via `findString`, page → photo,
signature store) and import/merge; `PDFCommandExecutor` handles the voice grammar in
`RuleBasedIntentEngine+PDF.swift`.

## Video

`CompositionBuilder` lays clips on two alternating video tracks (A/B roll) so transitions can overlap,
scales time ranges for speed changes, and builds an `AVMutableAudioMix` (clip volume, mute, transition
fades, music ducking/fades). `PicshopCompositor` (`AVVideoCompositing`) renders every frame with Core
Image: orientation, crop, rotation, framing (fit/fill), adjustments & looks, transitions, text overlays.

AI operations that change pixels over time render a new file through `VideoTranscoder`
(AVAssetReader → transform → AVAssetWriter, audio carried over):

- **Object removal**: `VNTrackObjectRequest` follows each candidate forward from the seed frame and
  backward via random access; every frame's mask is refined with foreground instance masks, inpainted
  with the same pipeline as photos and temporally smoothed against the previous fill.
- **Stabilisation**: `VNTranslationalImageRegistrationRequest` between consecutive frames, smoothed
  trajectory, corrective translation with a 6 % zoom.
- **Reverse**, **freeze frame**, **portrait blur** (per-frame person segmentation).

The rendered file replaces the clip's `renderAsset`; the original stays in the package for undo.

## Magic

The automatic tools are split the same way as the rest of the app: the algorithms are pure Swift in
`PicshopCore/Magic` (tested on Linux), the Apple back ends only decode, look and listen.

- **Audio analysis** (`AudioAnalysis.swift`): short-term loudness; `SilenceDetector` places its threshold between the
  recording's noise floor (10th percentile) and speech level (95th), so jump cuts adapt to each file and keep 120 ms of
  breath; a radix-2 FFT feeds `BeatTracker` — spectral-flux onsets, tempo by autocorrelation weighted with a
  log-Gaussian prior around 120 BPM, beats by dynamic programming (Ellis 2007), downbeat phase by onset energy.
- **Captions** (`Captions.swift`): word-timed cues broken at sentence ends, pauses, the style's line length and on-screen
  time. The video module transcribes the timeline's own mixed sound (`AudioDecoder.timelineSound`, so trims, speed and
  fades are already applied) with `SpeechAnalyzer` + `SpeechTranscriber` and the audio-time-range attribute, falling back to
  `SFSpeechRecognizer` segments. `CaptionRasterizer` draws each cue per spoken word; the compositor caches it.
- **Motion** (`Motion.swift`): a clip's framing is keyframed focus + zoom (geometric zoom easing).
  `SmartReframe` turns per-frame subject positions (`SubjectFinder`: faces, then people, then attention saliency) into a
  camera-operator path — dead zone, zero-phase smoothing, speed limit, Ramer–Douglas–Peucker simplification. Ken Burns is
  the same description. The compositor crops the window of the source the virtual camera sees and scales it to fill.
- **Magic Movie** (`MagicMovie.swift`): shot boundaries follow a beat pattern per pace (or fixed lengths without music);
  sources are used in order and each shot takes the most interesting unused window. Photos become short clips
  (`VideoTranscoder.writeStill`) with a Ken Burns move.
- **Colour** (`ColorTransfer.swift`, `ColorGrading.swift`): Reinhard statistics transfer in CIE Lab, an eight-band HSL
  mixer (a partition of unity between the two nearest bands, scaled by the pixel's saturation) and three-way grading.
  Each bakes into a 32³/33³ LUT (`ColorCube`, cached) applied with `CIColorCubeWithColorSpace`, for photos and clips alike.
  `.cube` files parse into the same LUT format.
- **Voice** (`VoiceIsolator`): offline `AVAudioEngine` manual rendering through Apple's sound-isolation audio unit when
  present, else a dialogue EQ and dynamics chain. The composition plays the cleaned file instead of the clip's sound.
- **Aesthetics** (`AestheticsRanker`): Vision's `CalculateImageAestheticsScoresRequest` scores each look's thumbnail.
- **Edit by text** (`TextEditing.swift`): struck words become timeline ranges that take the pause after them (capped) and
  keep the one before; neighbouring words merge into one cut. Fillers are the words a recogniser wrote (euh, um…), the
  first of a stuttered pair (with grammatical repeats like « nous nous » excluded), and the voiced runs between two
  recognised words that it left out, found on the loudness envelope. Phrases are matched as one run of letters, so
  tokenisation differences (« l'image » / « l' » + « image ») do not matter.
- **Ducking** (`Ducking.swift`): speech regions (caption words, else the complement of the pauses) are bridged over
  short gaps and turned into volume breakpoints — attack 250 ms before the voice, release 600 ms after — multiplied by
  the track's fades and handed to `AVMutableAudioMixInputParameters` as linear ramps. Speech is stored per clip in
  source time (`VideoClip.speech`) so any edit keeps it aligned.
- **Tracking** (`Tracking.swift`, `SubjectTracker`): Vision's `VNTrackObjectRequest` runs forwards and backwards from the
  playhead on the finished picture without overlays (the composition through `AVAssetImageGenerator`), starting from the
  nearest face, person or objectness-salient box; the path is smoothed with a centred moving average and the overlay
  moves by the offset from its anchor time.
- **Scenes** (`SceneDetection.swift`): each frame's fingerprint is a 64-bin joint RGB histogram and a 16 × 9 luma grid;
  a cut is a local peak above an absolute floor and well above the neighbourhood's median change. The service samples
  eight frames a second and then pins every cut to the exact frame.
- **Highlights** (`Highlights.swift`): per-second moment scores (aesthetics, faces, loudness, moderate motion) drive a
  greedy window picker that avoids straddling shot changes, spreads picks across the recording and restores their order.
  Magic Movie reuses the same scores.
- **Zoom cuts** (`PunchIn.swift`): a jump cut is the same file continuing later in time; runs of them alternate
  between the wide frame and a still, tighter one centred on the median face position of the segment.
- **Clean Up** (`Distractions.swift`): the largest person and anyone as prominent standing with them are the subject;
  much smaller figures, those apart from them and those cut by the frame edge are erased together in one fill.
- **Face blur** (`FaceBlur.swift`): faces sampled ten times a second per clip and stored by source time; the compositor
  blurs soft ellipses on the upright frame before any crop or move. Photos blur named regions (`.blurRegion`).
- **Music fit** (`MusicFit` in `AudioAnalysis.swift`): the song is cut on the last bar line that leaves at most two bars of
  picture, with a fade over that bar.
- **Best crop** (`CropCandidates.swift`): shapes × sizes × thirds around the subject, never cutting it, each scored by
  Vision's aesthetics model; kept only when clearly better than the original.
- **Keyframes** (`OverlayKeyframe`): recorded centre and size per time, eased between; applied by the compositor between
  an overlay's entrance animation and its tracking.
- **Translation**: caption lines through `TranslationSession` on device; each line keeps its time and its words share it.
- **Colour LUTs** (`LUTReference`): `.cube` files copied into the project, parsed once into the shared cube cache, applied
  as the last grading node with an intensity (photo edit step, per-clip field).
- **Titles** (`TextAnimation.swift`): pop, rise, wipe, focus and drift are states (scale, lift, blur, reveal, opacity)
  computed from time; the compositor applies them to any overlay.
- **Photo geometry magic**: generative expand places the picture in a larger canvas and fills the border (Stable
  Diffusion when installed, LaMa otherwise) seeded with stretched edges; magic move lifts an object by its mask, fills the
  hole and composites it at the offset; face parts (eyes, teeth, lips, skin) are filled from Vision's face landmarks by
  `PolygonRaster`.

## Visual language

Three colour roles only: neutrals and system Liquid Glass for chrome; the edit yellow for values that differ from
neutral, the playhead and "Done"; the intelligence spectrum (blue → violet → pink → amber) for what the AI does.
Selected controls are a lit glass thumb, never a coloured pill. While PicShop listens or works, `IntelligenceGlow` turns
around the screen edge (three blurred strokes in one Metal pass), the status shimmers and the microphone's ring turns —
all still under Reduce Motion and dropped first when the phone runs hot.

## Fluidity and thermal budget

`PerformanceGovernor` (`PicshopUI/App`) observes `ProcessInfo.thermalState`, Low Power Mode and Reduce Motion, combines
them with the user's Settings › Performance preference into a `Tier` (full · balanced · conserve · critical), and derives the
render budget every screen reads: preview and interactive preview sizes, the settle delay before the sharp frame, the
interactive render interval, the Metal canvas frame-rate cap and drawable scale, and a `PSEffectsLevel` environment value
that removes glow and drop shadows (and finally glass) before any layout changes. `PhotoEditorSession.requestPreview`
coalesces interactive renders (at most one in flight, latest state wins) and `MetalCanvasRepresentable` only redraws when
the image, overlay or frame changed. Heavy neural work (generative fill, upscaling, automatic model installs) waits while
the tier is critical.

**High-frequency state belongs in a leaf view.** Anything that changes many times a second — the playhead, the rendered
preview, the microphone level, a progress fraction — must be read by the smallest view that needs it, never by an editor's
own `body`, or SwiftUI re-evaluates the canvas, the filmstrip, the open panel and the dock on every tick. `TransportBar`,
`PlayheadFollower`, `CanvasSurface`, `LevelBars` and `EditorStatusOverlay` exist for that reason, and the session stores
`previewAspectRatio` and `hasRenderedPreview` so a layout can size itself without depending on each frame.

**Nothing that loads a model may sit on the first-frame path.** `MLModel(contentsOf:)` is synchronous and takes seconds on
device, so `configure()` builds the renderer with an empty `InpaintingPipeline`, asks for the preview immediately, and
attaches the engines from a detached task; a fill that arrives first waits for them through `InpaintingPipeline.setLoading`
rather than silently falling back to the patch-based eraser. Caches are bounded (the renderer's operation cache, the
library's decoded thumbnails) so a long session does not drift into memory pressure.

## Picshop Live

Live is a spoken conversation in each editor, entirely on the iPhone: no server, no key, no network code.

```
orb tap ─▶ LiveSession (PicshopUI/Live, @MainActor)
             voice path: simple (VoiceController + AVSpeechSynthesizer.speak, half-duplex, the default)
                         duplex (LiveAudioStack, echo-cancelling; headphones, after the self-test)
             LiveTurnMachine (PicshopIntent/Live, pure reducer: deadlines, echo gate, only words cancel)
             each turn ─▶ LiveTurnRouter fast lane (grammar, instant)
                       ─▶ BrainSelector: model ─▶ onDevice ─▶ local
                            model    LocalModelLiveBrain over LocalChatEngine (Qwen3.5 4B/2B, MLX, sees the photo)
                            onDevice FoundationModelsLiveBrain (Apple Intelligence)
                            local    LocalLiveBrain (the rules-only grammar, never waits)
                       ─▶ four validated tools: apply_edits · undo · compare_before_after · propose_ideas
```

- **The local brain** is pure Swift behind `LocalChatEngine` (PicshopIntent/LocalBrain), so the whole turn logic
  (tool calls, pictures, timeouts, fallback, compaction) is tested on Linux with a fake engine. The app target plugs in
  MLX (`App/LocalBrain`, mlx-swift-lm `ChatSession`) through `LocalBrainHub.shared.runtime`; PicshopKit never links MLX.
- **`LocalBrainHub`** decides the tier from the iPhone (`LocalModelTiering`: 4B on A18 Pro and newer, 2B on A17 Pro and
  A18, none with 6 GB of memory or less), downloads the weights through `ModelManager` (pinned Hugging Face revisions,
  Wi‑Fi unless the person confirms cellular, checked by size and SHA-256), loads them off the main actor when memory,
  heat and power allow, and releases them on memory warnings, in the background, before Stable Diffusion and a minute
  after the last editor closes. Push-to-talk uses the same weights through its planner.
- **Never silent**: every state has a deadline, a failure before any output re-runs the turn on the next brain, and every
  problem is shown and spoken (`LiveLines`) — none of them mentions a key or the network.
- **The UI**: the brain pill in the studio's top bar (which brain answers; the download offer, its progress and
  « Chargement du cerveau… »), Settings › Intelligence (model, tier, download, quality, storage, speed test) and
  Settings › PicShop Live (duplex with headphones, Diagnostic Live and its six-step voice self-test). Only leaf views
  read `LocalBrainHub.status`, the meter and the captions.

## Concurrency

- Documents and intents are `Sendable` values; `PhotoRenderer`, `ModelManager`, `VideoThumbnailer`
  and `HybridIntentRouter` are actors.
- UI state (`PhotoEditorSession`, `VideoEditorSession`, `VoiceController`) is `@MainActor @Observable`.
- `PicshopCore` and `PicshopIntent` compile in Swift 6 language mode; the Apple-framework modules use
  Swift 5 mode with strict-concurrency warnings, because many AVFoundation/Core Image types are not
  yet annotated.

## Testing

`swift test` runs 162 tests: geometry/colour, documents and undo, timeline maths (split, trim, speed,
transitions), the FR/EN grammar (≈150 utterances), LLM response parsing and normalisation, the router
(fallback, timeout), candidate selection, both executors with fake vision services, and PatchMatch on
synthetic textures and gradients. CI also runs a tree-sitter syntax gate over the Apple-only sources
and an Xcode build on macOS.
