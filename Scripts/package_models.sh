#!/usr/bin/env bash
# Packages converted Core ML models as *stored* (uncompressed) zip archives the
# app's built-in reader can unpack:  Scripts/package_models.sh build/models out/
set -euo pipefail
SRC="${1:-build/models}"
OUT="${2:-out}"
mkdir -p "$OUT"
for package in "$SRC"/*.mlpackage; do
  name="$(basename "${package%.mlpackage}")"
  (cd "$SRC" && rm -f "../../$OUT/$name.zip" && zip -0 -r "../../$OUT/$name.zip" "$name.mlpackage" >/dev/null)
  echo "→ $OUT/$name.zip"
done
echo "Upload the archives to your static host and set PICSHOP_MODEL_BASE_URL (Info.plist) or Settings › Model server."
