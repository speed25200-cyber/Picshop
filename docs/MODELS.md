# On-device models

PicShop ships with everything it needs; nothing has to be configured.

| Capability | Built in | Shipped in the app | On demand |
|---|---|---|---|
| Speech → text | `SpeechAnalyzer` (iOS 26) / `SFSpeechRecognizer` on-device | — | — |
| Command planning | Instant grammar + Apple Intelligence foundation model | — | **Pro Brain** — Qwen3 4B 4-bit via MLX (Hugging Face) |
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

## Pro Brain (MLX)

The app target links [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) (see
`project.yml`). `App/ProBrain/MLXIntentEngine.swift` downloads `mlx-community/Qwen3-4B-4bit` through
the MLX hub client on first use (≈2.5 GB) and plans commands with the same JSON schema as the other
engines. To ship without it, generate with `project.yml` instead of `project-pro.yml`; the file is
compiled out automatically (`#if canImport(MLXLLM)`).

Qwen3 4B in 4-bit runs comfortably in the iPhone 17 Pro's memory; the app requests the
`increased-memory-limit` entitlement for headroom during video renders.

## Picking a brain

The router always runs the grammar first. Only utterances it cannot resolve confidently reach the
language model, with a 6-second budget and the grammar's guess as a hint, so common commands stay
instant regardless of the brain selected.
