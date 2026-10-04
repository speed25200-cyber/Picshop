#!/usr/bin/env python3
"""Opens every PSD PicShop's tests wrote with psd-tools, an independent reader (W3, D16a, CI's psd-validate job).

    python3 Scripts/validate_psd.py <folder> [<folder> ...]

For each `<name>.psd` in the folders:
- psd-tools must open it, read its size and depth, iterate every layer, and composite it (`PSDImage.composite()`).
- When a sidecar `<name>.json` sits next to it (Core's PSDFixtureExportTests writes one), the structure psd-tools reads
  must match it field by field: size, depth, then per layer, bottom to top and nested under their groups: the name,
  pixel layer or group, the blend key (4 characters, "pass" for a pass-through group), opacity and fill opacity
  (0…255), clipping, visibility, mask presence, and for groups whether they are collapsed and their children.

Sidecar schema (one object per PSD):
  {"file": "<name>.psd", "width": Int, "height": Int, "depth": 8 | 16, "layers": [Layer]}
  Layer = {"name": String, "kind": "pixel" | "group", "blend_key": String, "opacity": Int, "fill_opacity": Int,
           "clipped": Bool, "visible": Bool, "has_mask": Bool, "collapsed": Bool (groups), "children": [Layer] (groups)}

Exit status 1 on any mismatch or unreadable file, or when a folder holds no PSD at all; 0 otherwise. The report lists
every finding, not only the first.
"""
import json
import pathlib
import sys
import warnings as python_warnings

# psd-tools 1.10 deprecates `clipping_layer` in favour of `clipping`; this script reads whichever exists.
python_warnings.filterwarnings("ignore", category=DeprecationWarning)

# Reported, never failing (an unreadable embedded ICC profile in a test fixture).
warnings = []

try:
    from psd_tools import PSDImage
    from psd_tools.constants import Tag
except ImportError:  # pragma: no cover - CI installs it
    sys.stderr.write("psd-tools is not installed: pip install 'psd-tools==1.10.*'\n")
    sys.exit(2)


def blend_key(layer):
    """The 4-character key of a layer's blend mode (psd-tools' BlendMode values are the keys as bytes)."""
    mode = getattr(layer, "blend_mode", None)
    value = getattr(mode, "value", mode)
    if isinstance(value, bytes):
        return value.decode("latin-1")
    return str(value)


def fill_opacity(layer):
    """`iOpa`, 255 when the record has none."""
    value = getattr(layer, "fill_opacity", None)
    if isinstance(value, (int, float)):
        return int(value)
    blocks = getattr(layer, "tagged_blocks", None)
    if blocks is not None:
        try:
            data = blocks.get_data(Tag.BLEND_FILL_OPACITY)
        except Exception:  # noqa: BLE001 - an unknown layout is "absent"
            data = None
        if data is not None:
            return int(getattr(data, "value", data))
    return 255


def has_mask(layer):
    method = getattr(layer, "has_mask", None)
    if callable(method):
        return bool(method())
    return getattr(layer, "mask", None) is not None


def clipped(layer):
    value = getattr(layer, "clipping", None)
    if value is None or callable(value):
        value = getattr(layer, "clipping_layer", False)
    return bool(value)


def collapsed(layer):
    """Whether a group is closed (`lsct` kind 2); None when psd-tools does not say."""
    setting = getattr(layer, "_setting", None)
    kind = getattr(setting, "kind", None)
    if kind is None:
        return None
    return int(getattr(kind, "value", kind)) == 2


def is_group(layer):
    method = getattr(layer, "is_group", None)
    return bool(method()) if callable(method) else layer.kind == "group"


def compare_layers(actual, expected, path, findings):
    if len(actual) != len(expected):
        findings.append(f"{path}: {len(actual)} layers, expected {len(expected)} "
                        f"(read {[layer.name for layer in actual]}, expected {[layer['name'] for layer in expected]})")
        return
    for index, (layer, want) in enumerate(zip(actual, expected)):
        here = f"{path}/{index}:{want['name']}"
        group = is_group(layer)
        checks = [
            ("name", layer.name, want["name"]),
            ("kind", "group" if group else "pixel", want["kind"]),
            ("blend key", blend_key(layer), want["blend_key"]),
            ("opacity", int(layer.opacity), int(want["opacity"])),
            ("clipping", clipped(layer), bool(want["clipped"])),
            ("visibility", bool(layer.visible), bool(want["visible"])),
            ("mask", has_mask(layer), bool(want["has_mask"])),
        ]
        if not group:
            checks.append(("fill opacity", fill_opacity(layer), int(want["fill_opacity"])))
        for label, got, expect in checks:
            if got != expect:
                findings.append(f"{here}: {label} {got!r}, expected {expect!r}")
        if group:
            state = collapsed(layer)
            if state is not None and "collapsed" in want and state != bool(want["collapsed"]):
                findings.append(f"{here}: collapsed {state!r}, expected {want['collapsed']!r}")
            compare_layers(list(layer), want.get("children", []), here, findings)


def validate(psd_path, findings):
    try:
        psd = PSDImage.open(psd_path)
    except Exception as error:  # noqa: BLE001 - any failure to read is a finding
        findings.append(f"{psd_path.name}: psd-tools cannot open it: {error}")
        return
    layers = list(psd)
    total = len(list(psd.descendants()))
    print(f"{psd_path.name}: {psd.width}×{psd.height}, {psd.depth}-bit, {len(layers)} top-level layers, {total} in all")
    for layer in psd.descendants():
        # Touch every field the comparison reads: a malformed record raises here.
        try:
            _ = (layer.name, blend_key(layer), layer.opacity, layer.visible, has_mask(layer), clipped(layer))
        except Exception as error:  # noqa: BLE001
            findings.append(f"{psd_path.name}: layer unreadable: {error}")
    image = None
    try:
        image = psd.composite()
    except Exception as error:  # noqa: BLE001
        # An embedded profile Pillow cannot open (a test fixture's placeholder bytes) is reported, not fatal: the
        # layers must still composite without the conversion. Real exports embed CGColorSpace's own ICC data.
        try:
            image = psd.composite(apply_icc=False)
            warnings.append(f"{psd_path.name}: the embedded ICC profile was not applied ({error})")
        except Exception as retry:  # noqa: BLE001
            findings.append(f"{psd_path.name}: composite() failed: {retry}")
    if image is None and not any(psd_path.name in finding for finding in findings):
        findings.append(f"{psd_path.name}: composite() returned nothing")
    elif image is not None and image.size != (psd.width, psd.height):
        findings.append(f"{psd_path.name}: composite is {image.size}, the document {psd.width}×{psd.height}")

    sidecar = psd_path.with_suffix(".json")
    if not sidecar.exists():
        return
    try:
        spec = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        findings.append(f"{sidecar.name}: unreadable sidecar: {error}")
        return
    for label, got, expect in [("width", psd.width, spec.get("width")), ("height", psd.height, spec.get("height")),
                               ("depth", psd.depth, spec.get("depth"))]:
        if got != expect:
            findings.append(f"{psd_path.name}: {label} {got}, expected {expect}")
    compare_layers(layers, spec.get("layers", []), psd_path.stem, findings)


def main(arguments):
    if not arguments:
        sys.stderr.write(__doc__)
        return 2
    findings = []
    seen = 0
    for folder in map(pathlib.Path, arguments):
        files = sorted(folder.glob("*.psd"))
        if not files:
            findings.append(f"{folder}: no PSD to validate")
        for psd_path in files:
            seen += 1
            validate(psd_path, findings)
    for warning in warnings:
        print(f"  ! {warning}")
    if findings:
        print(f"\n{len(findings)} finding(s) in {seen} PSD file(s):")
        for finding in findings:
            print(f"  ✗ {finding}")
        return 1
    print(f"\n{seen} PSD file(s): psd-tools agrees.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
