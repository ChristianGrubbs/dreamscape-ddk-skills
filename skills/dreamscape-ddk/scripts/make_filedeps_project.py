"""Create a Unity project from a DDK template with every Dreamscape package resolved from local tarballs
through UPM `file:` references. No Verdaccio, no scoped registry, no installer needed.

Inputs work on any machine that has the DDK tarballs:
  --template  a template .tgz (e.g. %ProgramData%\\Dreamscape Developer Kit\\Unity Templates\\template.<hash>.tgz)
              or an unpacked template folder containing package/ProjectData~ (or ProjectData~ directly)
  --cache     folder with com.dreamscape-learn.<name>-<version>.tgz (e.g. %ProgramData%\\Dreamscape Developer Kit\\Package Cache)
  --project   new project folder (must not exist)
Steps: compute the transitive com.dreamscape-learn.* closure of the template manifest from each tarball's own
package.json (fail before creating anything if a tarball is missing); copy ProjectData~ -> project; copy the
closure's tarballs to <project>/DDK-Tarballs; rewrite Packages/manifest.json with "file:../DDK-Tarballs/<tgz>";
drop scopedRegistries and packages-lock.json. JSONL log: <project parent>/make_filedeps_project.jsonl.

Usage: python -I make_filedeps_project.py --template <tgz|dir> --cache <dir> --project <dir>
Exit: 0 ok, 1 project exists / bad input, 2 missing tarballs.
"""
import argparse
import datetime
import json
import pathlib
import shutil
import sys
import tarfile
import tempfile
import uuid

ap = argparse.ArgumentParser()
ap.add_argument("--template", required=True)
ap.add_argument("--cache", required=True)
ap.add_argument("--project", required=True)
args = ap.parse_args()

run_id = uuid.uuid4().hex[:8]
project = pathlib.Path(args.project).resolve()
log_path = project.parent / "make_filedeps_project.jsonl"


def log(level, event, **ctx):
    rec = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), "run_id": run_id, "level": level,
           "event": event, "loc": "make_filedeps_project.py", "ctx": ctx}
    project.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(f"[{level}] {event} {ctx if ctx else ''}")


def safe_extract(tgz: pathlib.Path, dest: pathlib.Path):
    with tarfile.open(tgz, "r:gz") as tf:
        for m in tf.getmembers():
            target = (dest / m.name).resolve()
            if not str(target).startswith(str(dest.resolve())):
                raise ValueError(f"unsafe path in {tgz.name}: {m.name}")
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            tf.extractall(dest)


def find_project_data(root: pathlib.Path) -> pathlib.Path:
    for cand in (root / "package" / "ProjectData~", root / "ProjectData~"):
        if (cand / "Packages" / "manifest.json").exists():
            return cand
    hits = list(root.rglob("ProjectData~"))
    if hits:
        return hits[0]
    raise FileNotFoundError(f"no ProjectData~ under {root}")


if project.exists():
    log("error", "project_exists", path=str(project))
    sys.exit(1)

# Inventory tarballs and read each one's package.json without extracting the whole archive.
cache = pathlib.Path(args.cache)
meta, tgz_by_name = {}, {}
for tgz in sorted(cache.glob("com.dreamscape-learn.*.tgz")):
    try:
        with tarfile.open(tgz, "r:gz") as tf:
            member = next(m for m in tf.getmembers() if m.name.rstrip("/").endswith("package/package.json") and m.name.count("/") <= 2)
            pj = json.loads(tf.extractfile(member).read().decode("utf-8-sig"))
    except (StopIteration, tarfile.TarError, json.JSONDecodeError, OSError) as exc:
        log("warn", "tarball_unreadable", file=tgz.name, error=str(exc))
        continue
    if "name" not in pj:
        log("warn", "tarball_unnamed", file=tgz.name)
        continue
    meta[pj["name"]] = pj
    tgz_by_name[pj["name"]] = tgz
log("info", "inventory", tarballs=len(tgz_by_name), cache=str(cache))
if not tgz_by_name:
    log("error", "no_tarballs", cache=str(cache))
    sys.exit(1)

tmp = None
template = pathlib.Path(args.template)
if template.is_file():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="ddk-template-"))
    safe_extract(template, tmp)
    template_root = tmp
else:
    template_root = template
src = find_project_data(template_root)

# Resolve the closure from the template manifest BEFORE creating the project, so a failure leaves nothing behind.
template_manifest = json.loads((src / "Packages" / "manifest.json").read_text(encoding="utf-8-sig"))
todo = [n for n in template_manifest["dependencies"] if n.startswith("com.dreamscape-learn.")]
closure = set()
while todo:
    n = todo.pop()
    if n in closure:
        continue
    closure.add(n)
    todo.extend(d for d in (meta.get(n, {}).get("dependencies") or {}) if d.startswith("com.dreamscape-learn."))
missing = sorted(n for n in closure if n not in tgz_by_name)
log("info", "closure", size=len(closure), added_indirect=sorted(closure - set(template_manifest["dependencies"])),
    missing_tarballs=missing)
if missing:
    log("error", "missing_tarballs", names=missing)
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(2)

shutil.copytree(src, project)
if tmp:
    shutil.rmtree(tmp, ignore_errors=True)
log("info", "template_copied", src=str(src), dst=str(project))

manifest_path = project / "Packages" / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
deps = manifest["dependencies"]

tar_dir = project / "DDK-Tarballs"
tar_dir.mkdir()
for n in sorted(closure):
    shutil.copy2(tgz_by_name[n], tar_dir / tgz_by_name[n].name)
    deps[n] = f"file:../DDK-Tarballs/{tgz_by_name[n].name}"

removed = manifest.pop("scopedRegistries", None)
manifest["dependencies"] = dict(sorted(deps.items()))
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
lock = project / "Packages" / "packages-lock.json"
lock_removed = lock.exists()
if lock_removed:
    lock.unlink()
log("info", "manifest_rewritten", file_deps=len(closure), removed_scoped_registries=len(removed or []), lock_removed=lock_removed)
log("info", "done", project=str(project))
