#!/usr/bin/env bash
# Packages models as *stored* (uncompressed) zip archives the app's built-in
# reader can unpack:
#   Scripts/package_models.sh build/models out
# Handles Core ML packages (*.mlpackage → <name>.zip) and a Stable Diffusion
# resources folder (build/models/sd-generative-fill/ → sd-generative-fill.zip).
set -euo pipefail
SRC="${1:-build/models}"
OUT="${2:-out}"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
for package in "$SRC"/*.mlpackage; do
  [ -e "$package" ] || continue
  name="$(basename "${package%.mlpackage}")"
  (cd "$SRC" && rm -f "$OUT_ABS/$name.zip" && zip -0 -r "$OUT_ABS/$name.zip" "$name.mlpackage" >/dev/null)
  echo "→ $OUT/$name.zip"
done
if [ -d "$SRC/sd-generative-fill" ]; then
  (cd "$SRC" && rm -f "$OUT_ABS/sd-generative-fill.zip" && zip -0 -r "$OUT_ABS/sd-generative-fill.zip" "sd-generative-fill" >/dev/null)
  echo "→ $OUT/sd-generative-fill.zip"
fi
echo "Upload the archives to your static host and set PICSHOP_MODEL_BASE_URL (Info.plist) or Settings › Model server."
