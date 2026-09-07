#!/usr/bin/env python3
"""Lightweight Swift syntax gate for environments without a Swift toolchain.

Parses every .swift file with tree-sitter-swift and reports files whose parse
tree contains ERROR/MISSING nodes. It is not a type checker — it only catches
structural mistakes (unbalanced braces, malformed declarations, etc.).
"""
import sys, re, pathlib
import tree_sitter_swift
from tree_sitter import Language, Parser

LANG = Language(tree_sitter_swift.language())
parser = Parser(LANG)

def find_errors(node, out, depth=0):
    if node.type == "ERROR" or node.is_missing:
        out.append(node)
        return
    for c in node.children:
        find_errors(c, out, depth + 1)

COND_RE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")

def eval_condition(expr: str) -> bool:
    """Approximate evaluation of a Swift build condition, biased toward Apple platforms."""
    e = expr.strip()
    e = re.sub(r"canImport\(\s*\w+\s*\)", "True", e)
    e = re.sub(r"os\(\s*(Linux|Windows|Android)\s*\)", "False", e)
    e = re.sub(r"os\(\s*\w+\s*\)", "True", e)
    e = re.sub(r"targetEnvironment\(\s*\w+\s*\)", "False", e)
    e = re.sub(r"(arch|swift|compiler|hasFeature)\([^)]*\)", "True", e)
    e = e.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
    e = re.sub(r"\b(?!True\b|False\b|and\b|or\b|not\b)[A-Za-z_][A-Za-z0-9_]*", "True", e)
    try:
        return bool(eval(e, {"__builtins__": {}}, {}))
    except Exception:
        return True

def preprocess(src: bytes) -> bytes:
    """Blank out inactive #if branches so tree-sitter sees one concrete program."""
    out = []
    stack = []  # entries: [active_now, any_branch_taken, parent_active]
    for line in src.decode("utf8", "replace").split("\n"):
        m = COND_RE.match(line)
        if m:
            kind, rest = m.group(1), m.group(2)
            parent_active = stack[-1][0] if stack else True
            if kind == "if":
                taken = parent_active and eval_condition(rest)
                stack.append([taken, taken, parent_active])
            elif kind == "elseif" and stack:
                taken = stack[-1][2] and not stack[-1][1] and eval_condition(rest)
                stack[-1][0] = taken; stack[-1][1] = stack[-1][1] or taken
            elif kind == "else" and stack:
                taken = stack[-1][2] and not stack[-1][1]
                stack[-1][0] = taken; stack[-1][1] = True
            elif kind == "endif" and stack:
                stack.pop()
            out.append("")
            continue
        active = stack[-1][0] if stack else True
        out.append(line if active else "")
    return "\n".join(out).encode("utf8")

def check(path: pathlib.Path):
    src = preprocess(path.read_bytes())
    tree = parser.parse(src)
    errs = []
    find_errors(tree.root_node, errs)
    return errs, src

def main(argv):
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("Sources"), pathlib.Path("Tests"), pathlib.Path("App")]
    files = []
    for r in roots:
        if r.is_file(): files.append(r)
        else: files += sorted(r.rglob("*.swift"))
    bad = 0
    for f in files:
        errs, src = check(f)
        if errs:
            bad += 1
            for e in errs[:5]:
                line = e.start_point[0] + 1
                snippet = src[e.start_byte:e.end_byte][:80].decode("utf8", "replace").replace("\n", "\\n")
                print(f"{f}:{line}: {'MISSING' if e.is_missing else 'ERROR'} near: {snippet}")
    print(f"checked {len(files)} files, {bad} with syntax problems")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
