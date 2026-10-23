"""Compare two ddk-extract.ps1 output trees (old vs new DDK bundle) and report what changed.

Reports: bundle payloads (WixAttachedContainer file names and sizes), orchestrator manifests (Unity version,
changeset, modules; keyed by MSI + property), UPM package versions (added/removed/bumped), per-package file
changes (every file, .meta GUIDs and binaries included, by sha256), template manifest dependency changes, and
docs pages added/removed. The last line is `TOTAL changes: N`.

Usage: python -I ddk_diff.py <old_out> <new_out> [--json report.json] [--max-files 40] [--fail-on-change]
Exit: 0 report written (with --fail-on-change: only when N == 0), 1 changes found under --fail-on-change, 2 bad tree.
"""
import argparse
import hashlib
import json
import pathlib
import sys

ap = argparse.ArgumentParser()
ap.add_argument("old")
ap.add_argument("new")
ap.add_argument("--json")
ap.add_argument("--max-files", type=int, default=40)
ap.add_argument("--fail-on-change", action="store_true")
a = ap.parse_args()
old, new = pathlib.Path(a.old), pathlib.Path(a.new)
for root in (old, new):
    if not (root / "extract" / "packages").is_dir():
        print(f"not a ddk-extract tree (no extract/packages): {root}", file=sys.stderr)
        sys.exit(2)


def sha256(f):
    h = hashlib.sha256()
    with f.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def packages(root):
    out = {}
    for pj in (root / "extract" / "packages").glob("*/package/package.json"):
        m = json.loads(pj.read_text(encoding="utf-8-sig"))
        out[m["name"]] = {"version": m.get("version"), "dir": pj.parent}
    return out


def digest_tree(d):
    return {str(f.relative_to(d)).replace("\\", "/"): sha256(f) for f in d.rglob("*") if f.is_file()}


def manifests(root):
    p = root / "notes" / "orchestrator-manifests.json"
    if not p.exists():
        return {}
    return {f"{r['msi']}|{r.get('property', '')}": r["manifest"] for r in json.loads(p.read_text(encoding="utf-8"))}


def payloads(root):
    c = root / "extract" / "bundle" / "WixAttachedContainer"
    return {f.name: f.stat().st_size for f in c.iterdir() if f.is_file()} if c.is_dir() else {}


def template_deps(root):
    out = {}
    for mf in (root / "extract" / "packages" / "_templates").glob("*/package/ProjectData~/Packages/manifest.json"):
        tname = json.loads((mf.parents[2] / "package.json").read_text(encoding="utf-8-sig"))["name"]
        out[tname] = json.loads(mf.read_text(encoding="utf-8-sig")).get("dependencies", {})
    return out


report = {"payloads": {}, "packages": {"added": [], "removed": [], "changed": []}, "manifests": {}, "templates": {}, "docs": {}}
bo, bn = payloads(old), payloads(new)
report["payloads"] = {"added": sorted(bn.keys() - bo.keys()), "removed": sorted(bo.keys() - bn.keys()),
                      "resized": sorted(k for k in bo.keys() & bn.keys() if bo[k] != bn[k])}
po, pn = packages(old), packages(new)
report["packages"]["added"] = sorted(f"{n}@{pn[n]['version']}" for n in pn.keys() - po.keys())
report["packages"]["removed"] = sorted(f"{n}@{po[n]['version']}" for n in po.keys() - pn.keys())
for n in sorted(po.keys() & pn.keys()):
    a_files, b_files = digest_tree(po[n]["dir"]), digest_tree(pn[n]["dir"])
    added = sorted(b_files.keys() - a_files.keys())
    removed = sorted(a_files.keys() - b_files.keys())
    modified = sorted(k for k in a_files.keys() & b_files.keys() if a_files[k] != b_files[k])
    if po[n]["version"] != pn[n]["version"] or added or removed or modified:
        report["packages"]["changed"].append({
            "name": n, "from": po[n]["version"], "to": pn[n]["version"],
            "added": added[: a.max_files], "removed": removed[: a.max_files], "modified": modified[: a.max_files],
            "counts": {"added": len(added), "removed": len(removed), "modified": len(modified)}})
mo, mn = manifests(old), manifests(new)
for k in sorted(mo.keys() | mn.keys()):
    if mo.get(k) != mn.get(k):
        report["manifests"][k] = {"old": mo.get(k), "new": mn.get(k)}
to, tn = template_deps(old), template_deps(new)
for k in sorted(to.keys() | tn.keys()):
    a_d, b_d = to.get(k, {}), tn.get(k, {})
    delta = {d: [a_d.get(d), b_d.get(d)] for d in sorted(a_d.keys() | b_d.keys()) if a_d.get(d) != b_d.get(d)}
    if delta:
        report["templates"][k] = delta
do = {p.name for p in (old / "extract" / "docs_md").glob("*.md")}
dn = {p.name for p in (new / "extract" / "docs_md").glob("*.md")}
report["docs"] = {"added": sorted(dn - do), "removed": sorted(do - dn)}
total = (sum(len(v) for v in report["payloads"].values()) + len(report["packages"]["added"]) + len(report["packages"]["removed"])
         + len(report["packages"]["changed"]) + len(report["manifests"]) + sum(len(v) for v in report["templates"].values())
         + len(report["docs"]["added"]) + len(report["docs"]["removed"]))
report["total_changes"] = total

if a.json:
    pathlib.Path(a.json).write_text(json.dumps(report, indent=2), encoding="utf-8")
pl = report["payloads"]
print(f"bundle payloads: +{len(pl['added'])} -{len(pl['removed'])} ~{len(pl['resized'])} (of {len(bn)})")
for k in ("added", "removed", "resized"):
    for x in pl[k]:
        print(f"  {k[0]} {x}")
print(f"packages: +{len(report['packages']['added'])} -{len(report['packages']['removed'])} ~{len(report['packages']['changed'])} (of {len(pn)})")
for x in report["packages"]["added"]:
    print("  + " + x)
for x in report["packages"]["removed"]:
    print("  - " + x)
for c in report["packages"]["changed"]:
    print(f"  ~ {c['name']} {c['from']} -> {c['to']}  files +{c['counts']['added']} -{c['counts']['removed']} ~{c['counts']['modified']}")
print(f"orchestrator manifests changed: {len(report['manifests'])} (of {len(mn)})")
for k, v in report["manifests"].items():
    o, n_ = v["old"] or {}, v["new"] or {}
    print(f"  {k}: editor {o.get('unityEditorVersion')}/{o.get('unityEditorChangeset')} -> {n_.get('unityEditorVersion')}/{n_.get('unityEditorChangeset')}")
print(f"template dependency changes: {sum(len(v) for v in report['templates'].values())} (templates {len(tn)})")
print(f"docs pages: +{len(report['docs']['added'])} -{len(report['docs']['removed'])} (of {len(dn)})")
print(f"TOTAL changes: {total}")
sys.exit(1 if (a.fail_on_change and total) else 0)
