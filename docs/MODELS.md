# On-device models

PicShop works out of the box with Apple's built-in models:

| Capability | Built in | Optional upgrade |
|---|---|---|
| Speech → text | `SpeechAnalyzer` (iOS 26) / `SFSpeechRecognizer` on-device | — |
| Command planning | Instant grammar + Apple Intelligence foundation model | **Pro Brain** — Qwen3 4B 4-bit via MLX |
| Segmentation & detection | Vision (instance masks, people, animals, text, saliency, classification) | — |
| Object removal | `PatchMatchCore` (exemplar-based, CPU) | **LaMa** large-mask inpainting (Core ML) |
| Upscaling | Lanczos + edge-aware sharpening | **Real-ESRGAN ×4** (Core ML) |

Optional models are downloaded from **Settings › On-device models** and stored in
`Application Support/Models/<id>/`. They are never bundled with the app, keeping the download small.

## Hosting the Core ML archives

1. Convert the networks on a Mac (needs `torch`, `coremltools>=8`, and the upstream repositories):

   ```bash
   python3 Scripts/convert_models.py lama   --weights path/to/big-lama/models/best.ckpt --out build/models
   python3 Scripts/convert_models.py esrgan --weights path/to/RealESRGAN_x4plus.pth         --out build/models
   ```

2. Package them as *stored* zip archives (the app ships a dependency-free zip reader that supports
   stored and deflated entries):

   ```bash
   Scripts/package_models.sh build/models out
   # → out/lama-inpainting.zip, out/realesrgan-x4.zip
   ```

3. Upload `out/*.zip` to any static host and point the app at it, either in `App/Info.plist`
   (`PICSHOP_MODEL_BASE_URL`) or at runtime in **Settings › Model server**. The catalogue
   (`ModelCatalog`) resolves `<base>/<id>.zip`.

`CoreMLImageModel` reads input names, sizes and pixel formats from the model description, so models
converted at other resolutions or with different feature names work without code changes. Inputs may be
`ImageType` or `MultiArray (1,C,H,W)`; outputs may be images or float arrays in 0…1 or 0…255.

## Generative Fill (Stable Diffusion)

Link Apple's [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion) package (already in
`project.yml`) and host the compiled resources as `sd-generative-fill.zip`: a zip of a folder containing
`TextEncoder.mlmodelc`, `Unet.mlmodelc` (or `UnetChunk1/2.mlmodelc`), `VAEDecoder.mlmodelc`,
`VAEEncoder.mlmodelc`, `merges.txt`, `vocab.json` — e.g. the `split_einsum/compiled` folder of
`apple/coreml-stable-diffusion-2-1-base` on Hugging Face. The engine runs masked image-to-image on a
512 px crop around the selection; the pipeline composites the result back inside the mask only.

## Pro Brain (MLX)

The app target links [`mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) (see
`project.yml`). `App/ProBrain/MLXIntentEngine.swift` downloads `mlx-community/Qwen3-4B-4bit` through
the MLX hub client on first use (≈2.5 GB) and plans commands with the same JSON schema as the other
engines. To ship without it, delete the `MLXSwiftExamples` package from `project.yml`; the file is
compiled out automatically (`#if canImport(MLXLLM)`).

Qwen3 4B in 4-bit runs comfortably in the iPhone 17 Pro's memory; the app requests the
`increased-memory-limit` entitlement for headroom during video renders.

## Picking a brain

The router always runs the grammar first. Only utterances it cannot resolve confidently reach the
language model, with a 6-second budget and the grammar's guess as a hint, so common commands stay
instant regardless of the brain selected.
