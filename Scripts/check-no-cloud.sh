#!/usr/bin/env bash
# Live runs entirely on the iPhone: fails when a cloud assistant or network code
# comes back where it must not be.
#   1. "anthropic", "claude" or "sk-ant" (any case) in Sources, App, Scripts/strings,
#      README.md or docs;
#   2. URLSession, URLRequest, NWConnection or NWPathMonitor in Sources/PicshopIntent,
#      Sources/PicshopSpeech or Sources/PicshopUI/Live.
# Lines listed in Scripts/no-cloud-allowlist.txt are allowed.
#
#   Scripts/check-no-cloud.sh            exit 1 on any finding
#   Scripts/check-no-cloud.sh --report   list the findings, always exit 0
set -u
cd "$(dirname "$0")/.."

report=false
[ "${1:-}" = "--report" ] && report=true

allowlist="Scripts/no-cloud-allowlist.txt"
findings=0
files=""

# Whether an allowlist entry "path:fixed text" covers this line of this file.
allowed() {
  local file="$1" text="$2" entry path fixed
  [ -f "$allowlist" ] || return 1
  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in ''|'#'*) continue ;; esac
    path="${entry%%:*}"
    fixed="${entry#*:}"
    [ "$path" = "$file" ] || continue
    case "$text" in *"$fixed"*) return 0 ;; esac
  done < "$allowlist"
  return 1
}

# Prints each finding of `grep -rnIE $flags $pattern $paths` not allowed by the list.
scan() {
  local label="$1" flags="$2" pattern="$3"
  shift 3
  local existing=() path hit file rest text
  for path in "$@"; do [ -e "$path" ] && existing+=("$path"); done
  [ ${#existing[@]} -gt 0 ] || return 0
  while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    text="${rest#*:}"
    allowed "$file" "$text" && continue
    findings=$((findings + 1))
    case " $files " in *" $file "*) ;; *) files="$files $file" ;; esac
    printf '%s  %s:%s\n' "$label" "$file" "$(printf '%s' "${rest%%:*}: ${text}" | cut -c1-160)"
  done < <(grep -rnI $flags --exclude-dir=.build --exclude-dir=.git -E "$pattern" "${existing[@]}" 2>/dev/null)
}

scan "cloud  " "-i" "anthropic|claude|sk-ant|api\.anthropic" Sources App Scripts/strings README.md docs
scan "network" "" "URLSession|URLRequest|NWConnection|NWPathMonitor" Sources/PicshopIntent Sources/PicshopSpeech Sources/PicshopUI/Live

count=$(printf '%s\n' $files | grep -c . || true)
if [ "$findings" -eq 0 ]; then
  echo "no-cloud: clean"
  exit 0
fi
echo "no-cloud: $findings finding(s) in $count file(s):$files"
if $report; then
  echo "(report only)"
  exit 0
fi
exit 1
