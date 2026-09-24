# On-device models

PicShop ships with everything it needs; nothing has to be configured.

| Capability | Built in | Shipped in the app | On demand |
|---|---|---|---|
| Speech → text | `SpeechAnalyzer` (iOS 26) / `SFSpeechRecognizer` on-device | — | — |
| Command planning and Live | Instant grammar + Apple Intelligence foundation model | — | **Local brain** — Qwen3.5 4B or 2B, 4-bit, via MLX (Hugging Face) |
| Segmentation & detection | Vision (instance masks, people, animals, text, saliency, classification) | — | — |
| Object removal | `PatchMatchCore` (exemplar-based, CPU) | **LaMa** large-mask inpainting (Core ML) | — |
| Upscaling | Lanczos + edge-aware sharpening | **Real-ESRGAN ×4** (Core ML) | — |
| Generative fill | — | — | **Stable Diffusion** compiled resources (Hugging Face) |

## Models shipped in the app

`Scripts/convert_models.py` downloads the public weights (Real-ESRGAN x4plus from its GitHub
release, big-lama as the TorchScript export of simple-lama-inpainting), converts them with
coremltools to fp16 ML programs and writes `App/Models/*.mlpackage`. XcodeGen lists those packages
as optional sources, Xcode compiles them into `<id>.mlmodelc`, and `ModelManager.bundledModelURL`
finds them at runtime. Both CI pipelines (GitHub Actions and Codemagic) run the script before
generating the project and cache the result in `~/Library/Caches/picshop-models`.

```bash
python3 -m pip install "torch==2.5.1" "coremltools==8.2"
python3 Scripts/convert_models.py all --out App/Models
```

A user-installed copy in `Application Support/Models/<id>/` takes precedence over the bundled one.

## Hosting your own archives (optional)

`ModelCatalog` still resolves `<PICSHOP_MODEL_BASE_URL>/<id>.zip` when that key is set in
`App/Info.plist` (stored zip archives, see `Scripts/package_models.sh`).

## Generative Fill (Stable Diffusion)

Generate the project with `xcodegen generate --spec project-pro.yml` (adds Apple's [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion) package). The app downloads the
`split_einsum/compiled` folder of `apple/coreml-stable-diffusion-v1-5` file by file from Hugging Face, by itself over Wi‑Fi on first launch (progress on the Home screen; Settings › On-device models can retry or delete it)
(`TextEncoder.mlmodelc`, `Unet.mlmodelc`, `VAEDecoder.mlmodelc`, `VAEEncoder.mlmodelc`, `merges.txt`, `vocab.json`). The engine runs masked image-to-image on a
512 px crop around the selection; the pipeline composites the result back inside the mask only.

## Local brain (MLX)

The standard app target links [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm), pinned to a
main revision (products `MLXVLM` and `MLXLMCommon`), and swift-transformers' `Tokenizers` (see
`project.yml`); building it needs Xcode's Metal Toolchain. `App/LocalBrain/MLXLocalRuntime.swift`
registers with `LocalBrainHub` in `PicshopApp.init`; PicshopKit itself never links MLX, and every
MLX call stays in `App/LocalBrain`.

One Qwen3.5 model is installed at a time, chosen by the iPhone's tier: `live-qwen35-4b`
(`mlx-community/Qwen3.5-4B-MLX-4bit`, ≈3.06 GB) or `live-qwen35-2b` (`mlx-community/Qwen3.5-2B-MLX-4bit`,
≈1.75 GB), both at pinned revisions. iPhones with 6 GB of memory or less, and the Simulator, get no
local model: Live then uses Apple Intelligence, or the grammar. The same weights answer Live and plan
push-to-talk commands. The app requests the `increased-memory-limit` entitlement for headroom.

`project-pro.yml` is `project.yml` plus Stable Diffusion.

## Picking a brain

The router always runs the grammar first. Only utterances it cannot resolve confidently reach the
language model, with a 6-second budget and the grammar's guess as a hint, so common commands stay
instant regardless of the brain selected.
