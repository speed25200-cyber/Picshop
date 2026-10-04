#!/usr/bin/env bash
# Downloads the pinned mask models (W2: SAM 2.1 tiny and Depth Anything V2 Small, Apache-2.0) for the macOS CI
# tests, file by file at their pinned revisions, and checks every file against its pinned SHA-256.
#
#   bash Scripts/fetch-mask-models.sh "$HOME/Library/Caches/picshop-mask-models"
#
# The pins are read from Sources/PicshopCore/Models/MaskModelCatalog.swift (the one source of truth, also used
# by the app's ModelManager). The folder ends up holding the .mlpackage directories as the repositories lay them
# out (<folder>/<Package>.mlpackage/...); the tests compile them with Core ML and run them on the CPU. A file
# already there with the right digest is kept, so a restored cache costs nothing. CI only: the app downloads its
# copy itself, over Wi-Fi, on request.
set -euo pipefail

DEST="${1:?usage: fetch-mask-models.sh <destination folder>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/Sources/PicshopCore/Models/MaskModelCatalog.swift"
mkdir -p "$DEST"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# One line per file: repository revision path size sha256.
PINS="$(python3 - "$CATALOG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sets = re.split(r"PinnedModelPackageSet\(", text)[1:]
for block in sets:
    repo = re.search(r'repository:\s*"([^"]+)"', block)
    rev = re.search(r'revision:\s*"([0-9a-f]{40})"', block)
    if not repo or not rev:
        continue
    for path, size, digest in re.findall(r'PinnedModelFile\(path:\s*"([^"]+)",\s*size:\s*([0-9_]+),\s*sha256:\s*"([0-9a-f]{64})"\)', block):
        print(repo.group(1), rev.group(1), path, size.replace("_", ""), digest)
PY
)"
if [ -z "$PINS" ]; then
  echo "error: no pinned files found in $CATALOG" >&2
  exit 1
fi

count=0
total=0
while read -r repo rev path size digest; do
  count=$((count + 1))
  total=$((total + size))
  target="$DEST/$path"
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$digest" ]; then
    echo "kept     $path"
    continue
  fi
  url="https://huggingface.co/$repo/resolve/$rev/$path"
  echo "fetching $path ($size bytes)"
  curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors -o "$target.part" "$url"
  got_size="$(wc -c < "$target.part" | tr -d ' ')"
  got_digest="$(sha256_of "$target.part")"
  if [ "$got_size" != "$size" ] || [ "$got_digest" != "$digest" ]; then
    rm -f "$target.part"
    echo "error: $path does not match its pin (size $got_size, sha256 $got_digest; pinned $size, $digest)" >&2
    exit 1
  fi
  mv "$target.part" "$target"
done <<< "$PINS"

echo "mask models ready in $DEST: $count files, $total bytes, every SHA-256 checked"
