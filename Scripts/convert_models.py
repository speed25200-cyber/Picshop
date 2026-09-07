#!/usr/bin/env python3
"""Converts the neural models Picshop can use into Core ML packages.

  python3 Scripts/convert_models.py lama --weights big-lama.pt --out build/models
  python3 Scripts/convert_models.py esrgan --weights RealESRGAN_x4plus.pth --out build/models

Requirements (macOS, Python 3.10+): torch, coremltools>=8, and the model
repositories' code on PYTHONPATH (advimman/lama, xinntao/Real-ESRGAN).
The produced .mlpackage files are expected to expose:
  lama:   inputs  image (512×512 RGB), mask (512×512 grayscale) → output image
  esrgan: input   image (tile×tile RGB)                         → output image (×4)
`CoreMLImageModel` discovers names and sizes from the model description, so
other resolutions work too.
"""
import argparse, pathlib, sys

def convert_lama(weights: str, out: pathlib.Path, size: int) -> None:
    import torch, coremltools as ct
    from saicinpainting.training.trainers import load_checkpoint  # from advimman/lama
    from omegaconf import OmegaConf

    config = OmegaConf.load(pathlib.Path(weights).parent / "config.yaml")
    config.training_model.predict_only = True
    model = load_checkpoint(config, weights, strict=False, map_location="cpu").eval()

    class Wrapper(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner
        def forward(self, image, mask):
            batch = {"image": image, "mask": (mask > 0.5).float()}
            return self.inner(batch)["inpainted"]

    wrapper = Wrapper(model)
    example = (torch.rand(1, 3, size, size), torch.rand(1, 1, size, size))
    traced = torch.jit.trace(wrapper, example)
    package = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
                ct.ImageType(name="mask", shape=(1, 1, size, size), scale=1 / 255.0, color_layout=ct.colorlayout.GRAYSCALE)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS18,
    )
    package.short_description = "LaMa large-mask inpainting"
    package.save(str(out / "lama-inpainting.mlpackage"))

def convert_esrgan(weights: str, out: pathlib.Path, tile: int) -> None:
    import torch, coremltools as ct
    from basicsr.archs.rrdbnet_arch import RRDBNet  # from xinntao/Real-ESRGAN

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
    state = torch.load(weights, map_location="cpu")
    model.load_state_dict(state.get("params_ema", state.get("params", state)), strict=True)
    model.eval()
    traced = torch.jit.trace(model, torch.rand(1, 3, tile, tile))
    package = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, tile, tile), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS18,
    )
    package.short_description = "Real-ESRGAN ×4 super resolution"
    package.save(str(out / "realesrgan-x4.mlpackage"))

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", choices=["lama", "esrgan"])
    parser.add_argument("--weights", required=True)
    parser.add_argument("--out", default="build/models")
    parser.add_argument("--size", type=int, default=512, help="LaMa working size / ESRGAN tile size")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.model == "lama":
        convert_lama(args.weights, out, args.size)
    else:
        convert_esrgan(args.weights, out, min(args.size, 256))
    print("done →", out)
    return 0

if __name__ == "__main__":
    sys.exit(main())
