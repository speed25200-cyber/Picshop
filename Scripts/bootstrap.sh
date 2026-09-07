#!/usr/bin/env bash
# One-shot developer setup: generates the Xcode project and resolves packages.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi

python3 Scripts/generate_strings.py
python3 Scripts/generate_icon.py >/dev/null
xcodegen generate
echo "✓ Picshop.xcodeproj generated. Open it, pick your team, run on an iPhone 17 Pro (iOS 26)."
