#!/usr/bin/env python3
"""Converts the neural models PicShop ships into Core ML packages.

  python3 Scripts/convert_models.py all --out App/Models --cache ~/Library/Caches/picshop-models

Runs on macOS (CI or a Mac) with Python 3.10+; installs nothing itself — the
caller provides torch and coremltools (see .github/workflows/ci.yml). Weights
are fetched from their public releases the first time and cached.

Produced packages (compiled by Xcode into the app bundle):
  lama-inpainting.mlpackage  inputs image (512×512 RGB) + mask (512×512 gray) → output image
  realesrgan-x4.mlpackage    input  image (256×256 RGB)                         → output image (×4)
`CoreMLImageModel` discovers names and sizes from the model description, so
other resolutions work too.
"""
import argparse, hashlib, pathlib, shutil, sys, urllib.request

LAMA_URL = "https://github.com/enesmsahin/simple-lama-inpainting/releases/download/v0.1.0/big-lama.pt"
ESRGAN_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
VERSION = "3"  # bump to invalidate caches when the conversion changes


def fetch(url: str, into: pathlib.Path) -> pathlib.Path:
    into.mkdir(parents=True, exist_ok=True)
    target = into / url.rsplit("/", 1)[-1]
    if target.exists() and target.stat().st_size > 1_000_000:
        print(f"  cached {target.name}")
        return target
    print(f"  downloading {url}")
    tmp = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(url, timeout=120) as response, open(tmp, "wb") as out:
        shutil.copyfileobj(response, out, length=1 << 20)
    tmp.rename(target)
    return target


# --- Real-ESRGAN ------------------------------------------------------------------------------

def build_rrdbnet():
    """RRDBNet (x4) as in xinntao/Real-ESRGAN, inlined to avoid the basicsr dependency."""
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    class ResidualDenseBlock(nn.Module):
        def __init__(self, num_feat=64, num_grow_ch=32):
            super().__init__()
            self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
            self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
            self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
            self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
            self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
            self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

        def forward(self, x):
            x1 = self.lrelu(self.conv1(x))
            x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
            x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
            x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
            x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
            return x5 * 0.2 + x

    class RRDB(nn.Module):
        def __init__(self, num_feat, num_grow_ch=32):
            super().__init__()
            self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
            self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
            self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

        def forward(self, x):
            out = self.rdb1(x)
            out = self.rdb2(out)
            out = self.rdb3(out)
            return out * 0.2 + x

    class RRDBNet(nn.Module):
        def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32):
            super().__init__()
            self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
            self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
            self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
            self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
            self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
            self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
            self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
            self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

        def forward(self, x):
            feat = self.conv_first(x)
            body_feat = self.conv_body(self.body(feat))
            feat = feat + body_feat
            feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
            feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
            out = self.conv_last(self.lrelu(self.conv_hr(feat)))
            return out

    return RRDBNet()


def convert_esrgan(weights: pathlib.Path, out: pathlib.Path, tile: int) -> pathlib.Path:
    import torch, coremltools as ct

    model = build_rrdbnet()
    state = torch.load(str(weights), map_location="cpu", weights_only=False)
    state = state.get("params_ema", state.get("params", state))
    model.load_state_dict(state, strict=True)
    model.eval()

    class Wrapper(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image):
            return torch.clamp(self.inner(image), 0, 1) * 255.0

    traced = torch.jit.trace(Wrapper(model), torch.rand(1, 3, tile, tile))
    package = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name="image", shape=(1, 3, tile, tile), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    package.short_description = "Real-ESRGAN ×4 super resolution"
    package.version = VERSION
    target = out / "realesrgan-x4.mlpackage"
    shutil.rmtree(target, ignore_errors=True)
    package.save(str(target))
    return target


# --- LaMa -------------------------------------------------------------------------------------

def convert_lama(weights: pathlib.Path, out: pathlib.Path, size: int) -> pathlib.Path:
    import torch, coremltools as ct

    jit = torch.jit.load(str(weights), map_location="cpu").eval()

    class Wrapper(torch.nn.Module):
        """LaMa (TorchScript, simple-lama-inpainting export): image 0…1, mask 1 = hole → image 0…1."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image, mask):
            hard = (mask > 0.5).to(image.dtype)
            filled = self.inner(image, hard)
            # Keep the untouched pixels bit-exact, the network only owns the hole.
            composed = filled * hard + image * (1 - hard)
            return torch.clamp(composed, 0, 1) * 255.0

    example = (torch.rand(1, 3, size, size), torch.rand(1, 1, size, size))
    traced = torch.jit.trace(Wrapper(jit), example, check_trace=False)
    package = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
                ct.ImageType(name="mask", shape=(1, 1, size, size), scale=1 / 255.0, color_layout=ct.colorlayout.GRAYSCALE)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    package.short_description = "LaMa large-mask inpainting"
    package.version = VERSION
    target = out / "lama-inpainting.mlpackage"
    shutil.rmtree(target, ignore_errors=True)
    package.save(str(target))
    return target


# --- driver -----------------------------------------------------------------------------------

def cache_key(name: str) -> str:
    source = pathlib.Path(__file__).read_text()
    return hashlib.sha256((VERSION + name + source).encode()).hexdigest()[:12]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", choices=["all", "lama", "esrgan"])
    parser.add_argument("--out", default="App/Models")
    parser.add_argument("--cache", default=str(pathlib.Path.home() / "Library/Caches/picshop-models"))
    parser.add_argument("--size", type=int, default=512, help="LaMa working size")
    parser.add_argument("--tile", type=int, default=256, help="ESRGAN tile size")
    parser.add_argument("--weights", help="Local weights file (skips the download)")
    args = parser.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cache = pathlib.Path(args.cache)
    weights_dir = cache / "weights"
    packages_dir = cache / "packages"
    wanted = ["lama", "esrgan"] if args.model == "all" else [args.model]
    failures = []

    for name in wanted:
        package_name = "lama-inpainting.mlpackage" if name == "lama" else "realesrgan-x4.mlpackage"
        cached = packages_dir / cache_key(name) / package_name
        destination = out / package_name
        if cached.exists():
            print(f"[{name}] using cached package")
            shutil.rmtree(destination, ignore_errors=True)
            shutil.copytree(cached, destination)
            continue
        try:
            print(f"[{name}] converting…")
            weights = pathlib.Path(args.weights) if args.weights else fetch(LAMA_URL if name == "lama" else ESRGAN_URL, weights_dir)
            produced = convert_lama(weights, out, args.size) if name == "lama" else convert_esrgan(weights, out, args.tile)
            cached.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(cached, ignore_errors=True)
            shutil.copytree(produced, cached)
            print(f"[{name}] → {produced}")
        except Exception as error:  # keep going: the app works without either model
            failures.append(name)
            print(f"[{name}] FAILED: {error!r}", file=sys.stderr)
            shutil.rmtree(destination, ignore_errors=True)

    if failures:
        print("failed:", ", ".join(failures), file=sys.stderr)
        return 1 if args.model != "all" else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
