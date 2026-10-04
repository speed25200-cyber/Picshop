#!/usr/bin/env python3
"""Design-token lint: literal styling may only shrink.

Counts, per Swift file under Sources/PicshopUI and App (Sources/PicshopUI/Theme,
where the tokens live, is exempt):
- radius:  a literal corner radius (`cornerRadius: 16`, `.cornerRadius(12)`);
- opacity: a white or black opacity literal (`Color.white.opacity(0.4)`,
           `.black.opacity(0.35)`);
- font:    a fixed-size system font (`.system(size: 17` …);
- scheme:  a `.preferredColorScheme(` modifier (W2: none anywhere, Theme included; Info.plist's
           UIUserInterfaceStyle = Dark sets the whole app's appearance once).

A count above the file's entry in Scripts/design-token-baseline.json fails the
run (a file missing from the baseline is allowed none). Use the tokens instead:
PSRadius, the ShapeStyle roles (.psTextSecondary, .psFillControl …), PSFont,
PSFontRole and PSGlyph.

The report also lists colour-role suspects for the W2 cleanup (never failing):
yellow used as a fill or a tint (white is the only action colour), and white
text next to a yellow fill (about 1.5:1).

    python3 Scripts/lint-design-tokens.py                    exit 1 on any growth (CI)
    python3 Scripts/lint-design-tokens.py --report           list the counts and colour-role suspects, exit 0
    python3 Scripts/lint-design-tokens.py --update-baseline  write the current counts as the baseline
                                                             (only ever after a cleanup)
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Scripts/design-token-baseline.json"
SCAN = [ROOT / "Sources/PicshopUI", ROOT / "App"]
EXEMPT = [ROOT / "Sources/PicshopUI/Theme"]

PATTERNS = {
    "radius": re.compile(r"cornerRadius:\s*-?\d|\.cornerRadius\(\s*-?\d"),
    "opacity": re.compile(r"(?:Color)?\.(?:white|black)\.opacity\(\s*-?\.?\d"),
    "font": re.compile(r"\.system\(\s*size:\s*-?\.?\d"),
    "scheme": re.compile(r"\.preferredColorScheme\("),
}
KINDS = list(PATTERNS)
# Counted in every scanned file, Theme included, with a baseline of zero everywhere.
EVERYWHERE = {"scheme"}


def strip_comments(line: str) -> str:
    """Drops a trailing // comment (not inside a string literal)."""
    in_string = False
    i = 0
    while i < len(line) - 1:
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_string = not in_string
        elif not in_string and c == "/" and line[i + 1] == "/":
            return line[:i]
        i += 1
    return line


def count(path: pathlib.Path, kinds=KINDS) -> dict:
    counts = {kind: 0 for kind in KINDS}
    in_block = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw
        if in_block:
            if "*/" not in line:
                continue
            line = line.split("*/", 1)[1]
            in_block = False
        if "/*" in line and "*/" not in line.split("/*", 1)[1]:
            line = line.split("/*", 1)[0]
            in_block = True
        line = strip_comments(line)
        for kind in kinds:
            counts[kind] += len(PATTERNS[kind].findall(line))
    return counts


def scan() -> dict:
    result = {}
    for base in SCAN:
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            exempt = any(exempt in path.parents for exempt in EXEMPT)
            counts = count(path, sorted(EVERYWHERE) if exempt else KINDS)
            if any(counts.values()):
                result[str(path.relative_to(ROOT))] = counts
    return result


YELLOW = re.compile(r"PSTheme\.accent(?:Gradient)?\b|psValueAccent\b|PSTheme\.accentGradient")
FILL = re.compile(r"\.(?:fill|tint|background)\(|psAccentFill|glassProminent")
WHITE_TEXT = re.compile(r"(?:foregroundStyle|foregroundColor)\([^)]*(?:Color\.white|\.white)\b(?!\.opacity)")


def colour_roles() -> list:
    """Lines where yellow fills or tints something, and white text within four lines of such a fill."""
    suspects = []
    for base in SCAN:
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            if any(exempt in path.parents for exempt in EXEMPT):
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                code = strip_comments(line)
                if YELLOW.search(code) and FILL.search(code):
                    rel = path.relative_to(ROOT)
                    near = lines[max(0, index - 4): index + 5]
                    kind = "white text on yellow" if any(WHITE_TEXT.search(strip_comments(other)) for other in near) else "yellow fill/tint"
                    suspects.append(f"{rel}:{index + 1}: {kind}: {code.strip()[:110]}")
    return suspects


def totals(counts: dict) -> dict:
    return {kind: sum(entry.get(kind, 0) for entry in counts.values()) for kind in KINDS}


def main(argv) -> int:
    current = scan()
    if "--update-baseline" in argv:
        BASELINE.write_text(json.dumps({"totals": totals(current), "files": current}, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"wrote {BASELINE.relative_to(ROOT)}: {totals(current)}")
        return 0
    baseline = {}
    if BASELINE.exists():
        baseline = json.loads(BASELINE.read_text(encoding="utf-8")).get("files", {})
    report = "--report" in argv
    growth = []
    for file, counts in sorted(current.items()):
        allowed = baseline.get(file, {})
        for kind in KINDS:
            limit = 0 if kind in EVERYWHERE else allowed.get(kind, 0)
            if counts[kind] > limit:
                growth.append(f"{file}: {kind} {counts[kind]} > baseline {limit}")
    shrunk = [
        file for file, allowed in baseline.items()
        if any(current.get(file, {}).get(kind, 0) < allowed.get(kind, 0) for kind in KINDS)
    ]
    print(f"design tokens: {totals(current)} literal uses outside Theme (baseline {totals(baseline) if baseline else 'none'})")
    for line in growth:
        print(f"  grew  {line}")
    if shrunk:
        print(f"  {len(shrunk)} file(s) below their baseline: run --update-baseline to lock the gain in")
    if report:
        for file, counts in sorted(current.items()):
            print(f"  {file}: " + ", ".join(f"{kind} {counts[kind]}" for kind in KINDS if counts[kind]))
        suspects = colour_roles()
        if suspects:
            print(f"colour roles to review (W2): {len(suspects)}")
            for line in suspects:
                print(f"  {line}")
        return 0
    if growth:
        print("Use PSRadius, the .ps colour roles, PSFont/PSFontRole/PSGlyph instead of literals; never .preferredColorScheme (Info.plist sets Dark).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
