"""Turn an original vendor file and your patched copy into a minimal patch.json entry (find/replace hunks).

The spec carries only the changed lines plus enough context to make each `find` unique (overlapping matches
count), so no vendor file is redistributed. Change regions whose context windows overlap are merged into one
hunk. Before writing, the hunks are replayed in order exactly as apply_ddk_patches.py applies them, and the
spec is refused unless the replay reproduces the patched file. Re-running replaces the entry for that file.

Usage: python -I make_patch_spec.py --spec patches/<package>@<version>/patch.json --package <name> --version <ver>
                                    --file <path inside package> --original <orig file> --patched <patched file> --id <defect id>
Exit: 0 spec written, 1 no unique hunk possible or replay mismatch.
"""
import argparse
import difflib
import json
import pathlib
import sys


def occurrences(text: str, sub: str) -> int:
    """Count matches including overlapping ones (str.count skips overlaps and can call a repeated find unique)."""
    n, i = 0, text.find(sub)
    while i != -1:
        n += 1
        i = text.find(sub, i + 1)
    return n


ap = argparse.ArgumentParser()
for k in ("spec", "package", "version", "file", "original", "patched", "id"):
    ap.add_argument(f"--{k}", required=True)
a = ap.parse_args()

orig = pathlib.Path(a.original).read_bytes().decode("utf-8-sig")
new = pathlib.Path(a.patched).read_bytes().decode("utf-8-sig")
nl = "\r\n" if "\r\n" in orig else "\n"
o_lines, n_lines = orig.split(nl), new.replace("\r\n", "\n").split("\n")
expected = nl.join(n_lines)


def window(i1, i2):
    """Smallest context window [s, e) around original lines [i1, i2) whose text is unique in the original."""
    ctx = 0
    while True:
        s, e = max(0, i1 - ctx), min(len(o_lines), i2 + ctx)
        find = nl.join(o_lines[s:e])
        if find and occurrences(orig, find) == 1:
            return s, e
        if s == 0 and e == len(o_lines):
            sys.exit(f"cannot make a unique hunk for original lines {i1 + 1}-{i2}")
        ctx += 1


regions = []  # [i1, i2, j1, j2, s, e]
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=o_lines, b=n_lines, autojunk=False).get_opcodes():
    if tag == "equal":
        continue
    s, e = window(i1, i2)
    while regions and s < regions[-1][5]:  # overlaps the previous hunk's window: merge the two change regions
        prev = regions.pop()
        i1, j1 = prev[0], prev[2]
        s, e = window(i1, i2)
    regions.append([i1, i2, j1, j2, s, e])

hunks = [{"find": nl.join(o_lines[s:e]), "replace": nl.join(o_lines[s:i1] + n_lines[j1:j2] + o_lines[i2:e])}
         for i1, i2, j1, j2, s, e in regions]

# Replay with apply_ddk_patches.py semantics: each find must match exactly once in the text patched so far.
text = orig
for n, h in enumerate(hunks, 1):
    c = occurrences(text, h["find"])
    if c != 1:
        sys.exit(f"replay failed at hunk {n}: find matches {c} times after earlier hunks")
    text = text.replace(h["find"], h["replace"], 1)
if text != expected:
    sys.exit("replay failed: hunks do not reproduce the patched file")

spec_path = pathlib.Path(a.spec)
spec = json.loads(spec_path.read_text(encoding="utf-8")) if spec_path.exists() else {"package": a.package, "version": a.version, "files": []}
spec["files"] = [f for f in spec["files"] if f["file"] != a.file] + [{"file": a.file, "id": a.id, "hunks": hunks}]
spec_path.parent.mkdir(parents=True, exist_ok=True)
spec_path.write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
print(f"{a.file}: {len(hunks)} hunk(s), replay ok -> {spec_path}")
