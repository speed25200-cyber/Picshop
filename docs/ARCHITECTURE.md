# Architecture

PicShop is a Swift package (`PicshopKit`) with six modules plus a thin iOS app target.
The split keeps every piece of logic that does not need Apple frameworks buildable and
testable on Linux/CI, and isolates the Apple-only code behind clear protocols.

```
┌──────────────────────────────────────────────────────────────────────┐
│ App (SwiftUI)  PicshopApp · RootView · optional MLXIntentEngine      │
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

## Concurrency

- Documents and intents are `Sendable` values; `PhotoRenderer`, `ModelManager`, `VideoThumbnailer`
  and `HybridIntentRouter` are actors.
- UI state (`PhotoEditorSession`, `VideoEditorSession`, `VoiceController`) is `@MainActor @Observable`.
- `PicshopCore` and `PicshopIntent` compile in Swift 6 language mode; the Apple-framework modules use
  Swift 5 mode with strict-concurrency warnings, because many AVFoundation/Core Image types are not
  yet annotated.

## Testing

`swift test` runs 77 tests: geometry/colour, documents and undo, timeline maths (split, trim, speed,
transitions), the FR/EN grammar (≈150 utterances), LLM response parsing and normalisation, the router
(fallback, timeout), candidate selection, both executors with fake vision services, and PatchMatch on
synthetic textures and gradients. CI also runs a tree-sitter syntax gate over the Apple-only sources
and an Xcode build on macOS.
