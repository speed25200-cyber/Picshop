#!/usr/bin/env bash
# Main-thread lint: no PDF search, PDF composition or CPU rasterisation in the
# @MainActor view and session files (Sources/PicshopUI and App). That work goes
# through a worker, an asynchronous API (beginFindString) or a detached task; a
# file that does it legitimately off the main thread is listed, with its reason,
# in Scripts/main-thread-allowlist.txt.
#
#   bash Scripts/lint-main-thread.sh           exit 1 on any call outside the allowlist (CI)
#   bash Scripts/lint-main-thread.sh --report  list the calls, always exit 0
set -euo pipefail
cd "$(dirname "$0")/.."

report=0
if [ "${1:-}" = "--report" ]; then report=1; fi

allowlist="Scripts/main-thread-allowlist.txt"
pattern='findString\(|PDFComposer\.compose\(|createCGImage\('

allowed() {
    [ -f "$allowlist" ] || return 1
    grep -v '^[[:space:]]*#' "$allowlist" | awk '{print $1}' | grep -qxF "$1"
}

found=0
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    if allowed "$file"; then
        echo "allowed  $hit"
    else
        echo "MAIN THREAD  $hit"
        found=$((found + 1))
    fi
done < <(grep -rnE "$pattern" Sources/PicshopUI App --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [ "$found" -gt 0 ]; then
    echo "$found call(s) to findString(, PDFComposer.compose( or createCGImage( in main-actor files."
    echo "Move them to a worker or a detached task (or list the file in $allowlist with the reason)."
    [ "$report" -eq 1 ] && exit 0
    exit 1
fi
echo "main-thread lint: clean"
