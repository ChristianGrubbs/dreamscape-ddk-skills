"""Carve embedded frontend assets out of a Tauri (tauri-codegen) Windows executable.

tauri-codegen emits a phf map whose entries are (&'static str, &'static [u8]) = 4 little-endian u64:
(path_ptr, path_len, data_ptr, data_len). Pointers are virtual addresses. Data is brotli-compressed
in release builds (falls back to raw bytes when decompression fails).

Usage: python -I tauri_assets.py <exe> <out_dir>
"""
import pathlib
import re
import struct
import sys

import brotli
import pefile

exe_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
pe = pefile.PE(str(exe_path), fast_load=True)
data = exe_path.read_bytes()
base = pe.OPTIONAL_HEADER.ImageBase
sections = [(base + s.VirtualAddress, s.Misc_VirtualSize, s.PointerToRawData, s.SizeOfRawData) for s in pe.sections]


def va_to_off(va):
    for vstart, vsize, raw, rsize in sections:
        if vstart <= va < vstart + max(vsize, rsize):
            off = raw + (va - vstart)
            return off if off < raw + rsize else None
    return None


def off_to_va(off):
    for vstart, _vsize, raw, rsize in sections:
        if raw <= off < raw + rsize:
            return vstart + (off - raw)
    return None


# Candidate asset path strings: "/something.ext" printable runs.
path_re = re.compile(rb"/[A-Za-z0-9_\-./@~%+]{1,300}?\.(?:html|js|css|json|svg|png|jpg|jpeg|gif|webp|ico|woff2?|ttf|txt|xml|map|md|wasm)")
path_by_va = {}
for m in path_re.finditer(data):
    va = off_to_va(m.start())
    if va is not None:
        path_by_va.setdefault(va, set()).add(m.group(0))

entries = {}
# Scan 8-byte aligned qwords for pointers to candidate path strings.
for off in range(0, len(data) - 32, 8):
    p_ptr, p_len, d_ptr, d_len = struct.unpack_from("<QQQQ", data, off)
    if p_ptr not in path_by_va or not (1 < p_len < 400):
        continue
    poff = va_to_off(p_ptr)
    if poff is None:
        continue
    path = data[poff:poff + p_len]
    if not path.startswith(b"/"):
        continue
    doff = va_to_off(d_ptr)
    if doff is None or d_len == 0 or doff + d_len > len(data):
        continue
    entries[path.decode("utf-8", "replace")] = (doff, d_len)

ok = raw_count = 0
for path, (doff, dlen) in sorted(entries.items()):
    blob = data[doff:doff + dlen]
    try:
        content = brotli.decompress(blob)
        ok += 1
    except brotli.error:
        content = blob
        raw_count += 1
    dest = out_dir / path.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(content)
print(f"entries={len(entries)} brotli_ok={ok} raw={raw_count}")
for p in sorted(entries)[:25]:
    print("  ", p)
