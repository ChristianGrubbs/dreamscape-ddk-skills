"""Recover embedded Dart source text from a Flutter debug kernel_blob.bin (.dill).

Kernel SourceInfo records are: List<Byte> uri, List<Byte> source, List<UInt> lineStarts, List<Byte> importUri.
List lengths use kernel UInt encoding: 0xxxxxxx | 10xxxxxx xxxxxxxx | 11xxxxxx x3 (big endian, 30 bits).
We scan for UInt-prefixed URI strings ending in '.dart', then read the following UInt-prefixed source blob.

Usage: python -I dill_sources.py <kernel_blob.bin> <out_dir> [uri_filter_substring ...]
"""
import pathlib
import re
import sys


def read_uint(buf: bytes, pos: int):
    b0 = buf[pos]
    if b0 & 0x80 == 0:
        return b0, pos + 1
    if b0 & 0xC0 == 0x80:
        return ((b0 & 0x3F) << 8) | buf[pos + 1], pos + 2
    return ((b0 & 0x3F) << 24) | (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3], pos + 4


def encode_uint(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    if n < 0x4000:
        return bytes([0x80 | (n >> 8), n & 0xFF])
    return bytes([0xC0 | (n >> 24), (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF])


blob = pathlib.Path(sys.argv[1]).read_bytes()
out_dir = pathlib.Path(sys.argv[2])
filters = sys.argv[3:]
uri_re = re.compile(rb"(?:file|package|org-dartlang-[a-z]+|dart):[\x21-\x7e]{1,400}?\.dart")
seen = {}
for m in uri_re.finditer(blob):
    uri = m.group(0)
    start = m.start()
    # The UInt length prefix must sit immediately before the URI and equal its length.
    prefix = encode_uint(len(uri))
    if blob[start - len(prefix):start] != prefix:
        continue
    pos = m.end()
    try:
        src_len, src_pos = read_uint(blob, pos)
    except IndexError:
        continue
    if src_len == 0 or src_pos + src_len > len(blob):
        continue
    raw = blob[src_pos:src_pos + src_len]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        continue
    if not re.search(r"\b(import|library|part|class|void|final|enum|mixin|extension|typedef)\b", text[:4000]):
        continue
    u = uri.decode()
    if filters and not any(f in u for f in filters):
        continue
    if u in seen and len(seen[u]) >= len(text):
        continue
    seen[u] = text

for u, text in sorted(seen.items()):
    rel = re.sub(r"^[a-z\-]+:/*", "", u)
    rel = rel.replace(":", "_")
    dest = out_dir / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
    print(f"{len(text):>8}  {u}")
print(f"TOTAL {len(seen)} sources")
