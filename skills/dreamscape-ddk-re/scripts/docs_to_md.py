"""Convert carved Docusaurus HTML pages to markdown (article body only) plus an index.

Usage: python -I docs_to_md.py <docs_site_dir> <out_md_dir>
"""
import pathlib
import sys

import html2text
from bs4 import BeautifulSoup

site = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
conv = html2text.HTML2Text()
conv.body_width = 0
conv.ignore_images = False
conv.protect_links = True
index = []
for html in sorted(site.rglob("*.html")):
    soup = BeautifulSoup(html.read_text(encoding="utf-8", errors="replace"), "html.parser")
    body = soup.find("article") or soup.find("main")
    if body is None:
        continue
    for tag in body.select("nav, .theme-doc-footer, .pagination-nav, button"):
        tag.decompose()
    title = (soup.title.string if soup.title else html.stem) or html.stem
    md = conv.handle(str(body)).strip()
    rel = html.relative_to(site)
    name = "root" if str(rel.parent) == "." else str(rel.parent).replace("\\", "__").replace("/", "__")
    dest = out / f"{name}.md"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(f"<!-- source: docs_site/{rel.as_posix()} -->\n# {title}\n\n{md}\n", encoding="utf-8")
    index.append((name, title.strip(), len(md)))
(out / "_INDEX.md").write_text(
    "# Docs index\n\n" + "\n".join(f"- [{t}]({n}.md) ({c} chars)" for n, t, c in index) + "\n", encoding="utf-8")
print(f"pages={len(index)}")
for n, t, c in index:
    print(f"{c:>7}  {n}  |  {t}")
