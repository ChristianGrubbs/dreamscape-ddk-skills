"""Embed and patch DDK packages in a Unity project from patches/<package>@<version>/patch.json specs.

For each spec: find <package>-<version>.tgz (project DDK-Tarballs or --tarballs), extract its package/ into
<project>/Packages/<package>/ (embedded packages win over manifest entries), apply each find/replace hunk
(every `find` must occur exactly once, overlapping matches included, else nothing is written and the run fails), and write DDK-PATCHED.json
with the spec's sha256. Hunks are matched in the file's own line-ending style; UTF-8 BOMs are preserved.

Idempotent: a package whose DDK-PATCHED.json carries the same spec hash is skipped. A changed spec, or a
Packages/<package>/ folder this script did not create, is reported and left untouched unless --force is given.
JSONL log: <project parent>/apply_ddk_patches.jsonl.

Usage: python -I apply_ddk_patches.py --project <dir> [--tarballs <dir>] [--only <package>] [--patches <dir>] [--force]
Exit: 0 all applied or already applied, 1 a hunk did not match / tarball or file missing / embed needs --force.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import shutil
import sys
import tarfile
import tempfile
import uuid

ap = argparse.ArgumentParser()
ap.add_argument("--project", required=True)
ap.add_argument("--tarballs")
ap.add_argument("--only")
ap.add_argument("--patches", default=str(pathlib.Path(__file__).resolve().parent.parent / "patches"))
ap.add_argument("--force", action="store_true", help="replace an existing embed (changed spec or not made by this script)")
a = ap.parse_args()
project = pathlib.Path(a.project).resolve()
tarballs = pathlib.Path(a.tarballs) if a.tarballs else project / "DDK-Tarballs"
run_id = uuid.uuid4().hex[:8]
log_path = project.parent / "apply_ddk_patches.jsonl"
counts = {"applied": 0, "skipped": 0, "failed": 0}


def log(level, event, **ctx):
    rec = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), "run_id": run_id, "level": level,
           "event": event, "loc": "apply_ddk_patches.py", "ctx": ctx}
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(f"[{level}] {event} {ctx}")


def occurrences(text, sub):
    """Count matches including overlapping ones (str.count skips overlaps and can call a repeated find unique)."""
    n, i = 0, text.find(sub)
    while i != -1:
        n += 1
        i = text.find(sub, i + 1)
    return n


def fail(event, **ctx):
    counts["failed"] += 1
    log("error", event, **ctx)


if not (project / "Packages").is_dir():
    log("error", "not_a_unity_project", project=str(project))
    sys.exit(1)

specs = sorted(pathlib.Path(a.patches).glob("*/patch.json"))
log("info", "start", project=str(project), tarballs=str(tarballs), specs=len(specs), only=a.only, force=a.force)
for spec_file in specs:
    spec_bytes = spec_file.read_bytes()
    spec_sha = hashlib.sha256(spec_bytes).hexdigest()
    spec = json.loads(spec_bytes.decode("utf-8"))
    name, ver = spec["package"], spec["version"]
    if a.only and name != a.only:
        continue
    embed = project / "Packages" / name
    marker = embed / "DDK-PATCHED.json"
    if marker.exists():
        prev = json.loads(marker.read_text(encoding="utf-8"))
        if prev.get("spec_sha256") in (None, spec_sha) and not a.force:
            counts["skipped"] += 1
            log("info", "already_patched", package=name, spec_sha256=prev.get("spec_sha256", "legacy-marker"))
            continue
        if not a.force:
            fail("spec_changed", package=name, hint="re-run with --force to re-embed from the tarball")
            continue
    elif embed.exists() and not a.force:
        fail("embedded_unmanaged", package=name, path=str(embed),
             hint="Packages/<name>/ exists without DDK-PATCHED.json; move it away or pass --force")
        continue
    tgz = tarballs / f"{name}-{ver}.tgz"
    if not tgz.exists():
        fail("tarball_missing", package=name, version=ver, expected=str(tgz))
        continue
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="ddk-embed-"))
    try:
        with tarfile.open(tgz, "r:gz") as tf:
            if hasattr(tarfile, "data_filter"):
                tf.extractall(tmp, filter="data")
            else:
                tf.extractall(tmp)
        staged = tmp / "package"
        ok, applied = True, []
        for entry in spec["files"]:
            target = staged / entry["file"]
            if not target.is_file():
                fail("file_missing", package=name, file=entry["file"])
                ok = False
                break
            raw = target.read_bytes()
            bom = raw.startswith(b"\xef\xbb\xbf")
            text = raw.decode("utf-8-sig")
            nl = "\r\n" if "\r\n" in text else "\n"
            for h in entry["hunks"]:
                find = h["find"].replace("\r\n", "\n").replace("\n", nl)
                replace = h["replace"].replace("\r\n", "\n").replace("\n", nl)
                n = occurrences(text, find)
                if n != 1:
                    fail("hunk_mismatch", package=name, file=entry["file"], id=entry.get("id"), count=n)
                    ok = False
                    break
                text = text.replace(find, replace, 1)
            if not ok:
                break
            target.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))
            applied.append({"file": entry["file"], "id": entry["id"], "hunks": len(entry["hunks"]),
                            "newline": "crlf" if nl == "\r\n" else "lf"})
        if ok:
            if embed.exists():
                shutil.rmtree(embed)
            shutil.copytree(staged, embed)
            marker.write_text(json.dumps({"package": name, "version": ver, "spec_sha256": spec_sha, "applied": applied,
                                          "patched": datetime.datetime.now().isoformat(timespec="seconds")}, indent=2),
                              encoding="utf-8")
            counts["applied"] += 1
            log("info", "embedded_patched", package=name, files=len(applied), ids=[x["id"] for x in applied])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
log("info" if not counts["failed"] else "error", "done", **counts)
sys.exit(1 if counts["failed"] else 0)
