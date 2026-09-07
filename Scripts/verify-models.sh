#!/usr/bin/env bash
# Build-phase sanity check: warns when neural models are expected but no server is configured.
set -u
if [ -z "${PICSHOP_MODEL_BASE_URL:-}" ]; then
  echo "note: PICSHOP_MODEL_BASE_URL not set — neural models can be added later from Settings (PatchMatch eraser is built in)."
fi
exit 0
