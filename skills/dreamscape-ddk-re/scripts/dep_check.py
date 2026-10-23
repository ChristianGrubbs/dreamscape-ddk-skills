"""Cross-check every declared dependency (packages + template manifests) against shipped package versions.

Reports: missing Dreamscape packages, version mismatches (exact pins), Unity-registry deps with their
requested versions (aggregated to find conflicts), and template manifest scopedRegistries.

Usage: python -I dep_check.py <packages_root> <out_json>
"""
import collections
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
shipped = {}
pkg_deps = {}
for pj in root.glob("*/package/package.json"):
    meta = json.loads(pj.read_text(encoding="utf-8-sig"))
    shipped[meta["name"]] = meta["version"]
    pkg_deps[meta["name"]] = meta.get("dependencies", {}) or {}

templates = {}
for tdir in (root / "_templates").glob("*/package"):
    tmeta = json.loads((tdir / "package.json").read_text(encoding="utf-8-sig"))
    manifest = json.loads((tdir / "ProjectData~" / "Packages" / "manifest.json").read_text(encoding="utf-8-sig"))
    templates[tmeta["name"] + "@" + tmeta["version"]] = {"package_json": tmeta, "manifest": manifest}

def vtuple(v):
    parts = []
    for p in v.split("-")[0].split("."):
        parts.append(int(p) if p.isdigit() else 0)
    return tuple(parts)

problems = []
unity_reqs = collections.defaultdict(lambda: collections.defaultdict(list))
def check(owner, deps):
    for name, ver in deps.items():
        if name.startswith("com.dreamscape-learn"):
            if name not in shipped:
                problems.append({"type": "MISSING", "owner": owner, "dep": name, "requested": ver})
            elif ver.startswith(("file:", "http", "git")):
                problems.append({"type": "NON_REGISTRY_REF", "owner": owner, "dep": name, "requested": ver})
            elif vtuple(ver) > vtuple(shipped[name]):
                problems.append({"type": "NEWER_THAN_SHIPPED", "owner": owner, "dep": name, "requested": ver, "shipped": shipped[name]})
            elif ver != shipped[name]:
                problems.append({"type": "OLDER_PIN(UPM picks highest)", "owner": owner, "dep": name, "requested": ver, "shipped": shipped[name]})
        else:
            unity_reqs[name][ver].append(owner)

for name, deps in pkg_deps.items():
    check(name, deps)
for tname, t in templates.items():
    check("TEMPLATE " + tname, t["manifest"].get("dependencies", {}))

unity_summary = {n: {v: owners for v, owners in vs.items()} for n, vs in sorted(unity_reqs.items())}
result = {
    "shipped": shipped,
    "problems": problems,
    "unity_registry_requests": unity_summary,
    "template_scopedRegistries": {t: v["manifest"].get("scopedRegistries") for t, v in templates.items()},
    "template_testables_and_other_keys": {t: [k for k in v["manifest"] if k not in ("dependencies",)] for t, v in templates.items()},
}
out.write_text(json.dumps(result, indent=2), encoding="utf-8")
by_type = collections.Counter(p["type"] for p in problems)
print("problem counts:", dict(by_type))
for p in problems:
    if p["type"] != "OLDER_PIN(UPM picks highest)":
        print(p)
print("--- Unity registry deps requested at >1 version:")
for n, vs in unity_summary.items():
    if len(vs) > 1:
        print(f"  {n}: " + "; ".join(f"{v} <- {len(o)}" for v, o in vs.items()))
print("--- scopedRegistries:", json.dumps(result["template_scopedRegistries"], indent=1))
