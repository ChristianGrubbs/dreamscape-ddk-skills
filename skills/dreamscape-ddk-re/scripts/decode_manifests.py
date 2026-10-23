"""Decode every base64 JSON manifest property found in the decompiled MSI .wxs files.

Usage: python -I decode_manifests.py <msi_extract_root> <out_json>
"""
import base64
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
prop_re = re.compile(r'<Property Id="(?P<id>[^"]+)" Value="(?P<val>ew0K[A-Za-z0-9+/=]+)"')
results = []
for wxs in sorted(root.rglob("_decompiled.wxs")):
    text = wxs.read_text(encoding="utf-8", errors="replace")
    for m in prop_re.finditer(text):
        try:
            decoded = json.loads(base64.b64decode(m.group("val")).decode("utf-8"))
        except Exception as exc:  # keep going; record the failure
            decoded = {"_decode_error": str(exc)}
        results.append({"msi": wxs.parent.name, "property": m.group("id"), "manifest": decoded})
out.write_text(json.dumps(results, indent=2), encoding="utf-8")
for r in results:
    mf = r["manifest"]
    print(f'{r["msi"]} | {r["property"]} | ver={mf.get("unityEditorVersion")} cs={mf.get("unityEditorChangeset")} '
          f'mod={mf.get("unityModules")}/{mf.get("unityModuleId")} tmpl={mf.get("unityManifestTemplateName")}@{mf.get("unityManifestTemplateVersion")} '
          f'winget={mf.get("winGetIdentifier")} detect={json.dumps(mf.get("detection"))[:120]}')
