"""Inventory every unpacked UPM package: manifest fields, deps, file-type counts, asmdefs.

Usage: python -I package_inventory.py <packages_root> <out_json>
"""
import collections
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
rows = []
for pkg_dir in sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith("_")):
    # Prefer the UPM root manifest; rglob alone can return a nested package.json (Samples~, node payloads) first.
    pj = pkg_dir / "package" / "package.json"
    if not pj.is_file():
        pj = next(pkg_dir.rglob("package.json"), None)
    if pj is None:
        rows.append({"dir": pkg_dir.name, "error": "no package.json"})
        continue
    meta = json.loads(pj.read_text(encoding="utf-8-sig"))
    exts = collections.Counter(f.suffix.lower() for f in pkg_dir.rglob("*") if f.is_file())
    asmdefs = []
    for a in pkg_dir.rglob("*.asmdef"):
        try:
            ad = json.loads(a.read_text(encoding="utf-8-sig"))
        except Exception:
            ad = {}
        asmdefs.append({
            "name": ad.get("name"),
            "path": str(a.relative_to(pkg_dir)),
            "includePlatforms": ad.get("includePlatforms"),
            "excludePlatforms": ad.get("excludePlatforms"),
            "defineConstraints": ad.get("defineConstraints"),
            "references": ad.get("references"),
            "precompiledReferences": ad.get("precompiledReferences"),
            "versionDefines": ad.get("versionDefines"),
            "allowUnsafeCode": ad.get("allowUnsafeCode"),
        })
    dlls = [str(f.relative_to(pkg_dir)) for f in pkg_dir.rglob("*.dll")]
    rows.append({
        "dir": pkg_dir.name,
        "name": meta.get("name"),
        "version": meta.get("version"),
        "displayName": meta.get("displayName"),
        "unity": meta.get("unity"),
        "unityRelease": meta.get("unityRelease"),
        "description": meta.get("description"),
        "dependencies": meta.get("dependencies", {}),
        "samples": [s.get("displayName") for s in meta.get("samples", [])],
        "ext_counts": dict(exts.most_common()),
        "cs_files": exts.get(".cs", 0),
        "dll_files": dlls,
        "asmdefs": asmdefs,
    })
out.write_text(json.dumps(rows, indent=2), encoding="utf-8")
for r in rows:
    if "error" in r:
        print(r["dir"], r["error"])
        continue
    deps = [d for d in r["dependencies"] if d.startswith("com.dreamscape")]
    ext = {k: v for k, v in r["ext_counts"].items() if k in (".cs", ".dll", ".prefab", ".unity", ".asset", ".shader", ".so", ".exe", ".zip")}
    print(f'{r["name"]}@{r["version"]} unity={r["unity"]} cs={r["cs_files"]} dll={len(r["dll_files"])} asm={len(r["asmdefs"])} '
          f'dsdeps={len(deps)} other_deps={[d for d in r["dependencies"] if not d.startswith("com.dreamscape")]} ext={ext}')
