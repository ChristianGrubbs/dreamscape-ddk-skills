"""Lint a skill folder: frontmatter, non-ASCII characters, secret-shaped strings, broken relative links, missing
scripts, and reference files that SKILL.md never links (orphans).

--public adds release checks: machine-specific absolute paths (drive-letter paths, user profiles) and e-mail
addresses, which must not ship in a public repository.

Usage: python -I lint_skill.py [--public] <skill dir> [<skill dir> ...]
Exit 0 clean, 1 findings.
"""
import argparse
import pathlib
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--public", action="store_true", help="also flag local absolute paths and e-mail addresses")
ap.add_argument("skills", nargs="+")
a = ap.parse_args()

secret_res = [
    re.compile(r"gitlab-ci-token:(?!<)[A-Za-z0-9_\-]{6,}"),
    re.compile(r"glcbt-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"glpat-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)x-api-key['\"]?\s*[:=]\s*['\"][A-Za-z0-9]{12,}"),
    re.compile(r"(?i)(password|credential|secret)['\"]?\s*[:=]\s*['\"][^<'\"\s]{6,}['\"]"),
]
public_res = [
    # A user profile or this analysis workspace; vendor install folders under Program Files are generic and allowed.
    ("LOCALPATH", re.compile(r"(?i)\b[A-Z]:[\\/](?:Users[\\/][^\\/\s`'\"|)]+|dreamscape-developer-kit)[^\s`'\"|)]*")),
    ("EMAIL", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
]
public_ok = re.compile(r"(?i)[A-Z]:[\\/]Users[\\/](?:<[^>]+>|Public)")
link_re = re.compile(r"\]\(([^)#\s]+)(?:#[^)]*)?\)")
script_re = re.compile(r"scripts/[A-Za-z0-9_\-./]+\.(?:ps1|py|cs|asmdef)")
fm_re = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.S)
findings = 0


def report(kind, where, msg):
    global findings
    findings += 1
    print(f"{kind:<9} {where}: {msg}")


for root in map(pathlib.Path, a.skills):
    skill_md = root / "SKILL.md"
    if not skill_md.is_file():
        report("FRONTMAT", root.name, "SKILL.md missing")
    else:
        body = skill_md.read_text(encoding="utf-8", errors="replace")
        fm = fm_re.match(body)
        meta = dict(re.findall(r"^([A-Za-z_-]+):\s*(.*)$", fm.group(1), re.M)) if fm else {}
        if meta.get("name") != root.name:
            report("FRONTMAT", f"{root.name}/SKILL.md", f"name '{meta.get('name')}' != folder '{root.name}'")
        desc = meta.get("description", "").strip()
        if not desc or len(desc) > 1024:
            report("FRONTMAT", f"{root.name}/SKILL.md", f"description length {len(desc)} (need 1..1024)")
        linked = {(skill_md.parent / m.group(1)).resolve() for m in link_re.finditer(body)}
        for ref in sorted((root / "references").glob("*.md")):
            if ref.resolve() not in linked:
                report("ORPHAN", f"{root.name}/SKILL.md", f"does not link {ref.relative_to(root).as_posix()}")
    for f in sorted(root.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in (".md", ".ps1", ".py", ".cs", ".asmdef", ".json"):
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        rel = f"{root.name}/{f.relative_to(root).as_posix()}"
        for i, line in enumerate(text.splitlines(), 1):
            bad = [c for c in line if ord(c) > 126 or (ord(c) < 32 and c != "\t")]
            if bad:
                report("NONASCII", f"{rel}:{i}", repr("".join(sorted(set(bad)))))
            for sr in secret_res:
                if sr.search(line):
                    report("SECRET?", f"{rel}:{i}", sr.pattern)
            if a.public:
                for kind, pr in public_res:
                    for m in pr.finditer(line):
                        if not public_ok.match(m.group(0)):
                            report(kind, f"{rel}:{i}", m.group(0)[:90])
        if f.suffix == ".md":
            for m in link_re.finditer(text):
                target = m.group(1)
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                if not (f.parent / target).exists():
                    report("LINK", rel, f"missing {target}")
            for m in sorted(set(script_re.findall(text))):
                if not (root / m).exists():
                    report("SCRIPT", rel, f"missing {m}")
print(f"findings={findings}")
sys.exit(1 if findings else 0)
