#!/usr/bin/env python3
"""Re-embed the design system sources into the self-contained UI-kit bundle.

design/static-site/ui-kit/index.html is a single-file bundle produced by an external
bundler (there is no generator in this repo). It opens offline because it carries
everything inline, in three <script> blocks:

  __bundler/template   the page HTML as a JSON string. Its first <style> is
                       design/static-site/colors_and_type.css, with the Google Fonts
                       @import swapped for inlined @font-face rules.
  __bundler/manifest   {uuid: {mime, compressed, data}}: gzip+base64 copies of React,
                       Lucide, the fonts and each ui-kit/*.jsx (no file names).
  __bundler/ext_resources

The ui-kit/*.jsx files and colors_and_type.css are the sources; the bundle is a copy.
Run this after editing either, so the bundle matches:

    python3 tools/refresh-ui-kit-bundle.py [--repo PATH]

It replaces the template's token CSS (keeping the inlined @font-face block) and every
embedded .jsx whose source changed. Embedded modules are matched to sources by their
first line (each ui-kit file opens with a unique header comment); if a module can't be
matched, it stops rather than guess. Serialization reproduces the bundler's own
encoding byte-for-byte, so an unchanged source leaves the file unchanged.
tools/check-design-tokens.py fails when the bundle is stale.

Stdlib only. Exit 0 on success (prints what changed), 2 on a bundle it can't parse.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import re
import sys
from pathlib import Path

BUNDLE = "design/static-site/ui-kit/index.html"
TOKENS_CSS = "design/static-site/colors_and_type.css"
JSX_DIR = "design/static-site/ui-kit"
FONT_IMPORT = re.compile(r"^@import url\('https://fonts\.googleapis\.com[^\n]*$", re.M)


class BundleError(Exception):
    pass


def _block(html: str, kind: str) -> re.Match:
    m = re.search(rf'(<script type="__bundler/{kind}">\n)(.*?)(\n\s*</script>)', html, re.S)
    if not m:
        raise BundleError(f"{BUNDLE}: no __bundler/{kind} block")
    return m


def load(repo: Path) -> dict:
    """Decode the bundle: its token CSS (font swap undone), embedded jsx by source name."""
    html = (repo / BUNDLE).read_text()
    template = json.loads(_block(html, "template").group(2))
    manifest = json.loads(_block(html, "manifest").group(2))
    i = template.index("<style>") + len("<style>")
    j = template.index("</style>", i)
    css = template[i:j]
    try:
        a = css.index("/* cyrillic-ext")
        last = css.rfind("@font-face")
        b = css.index("}", last) + 1
    except ValueError:
        raise BundleError(f"{BUNDLE}: embedded CSS has no inlined @font-face block")
    sources = {p.name: p.read_text() for p in sorted((repo / JSX_DIR).glob("*.jsx"))}
    by_header: dict[str, str] = {}
    for name, text in sources.items():
        head = text.split("\n", 1)[0]
        if head in by_header:
            raise BundleError(f"{name} and {by_header[head]} share a first line; can't map modules")
        by_header[head] = name
    modules = {}
    for key, entry in manifest.items():
        if entry.get("mime") != "application/javascript":
            continue
        raw = base64.b64decode(entry["data"])
        text = (gzip.decompress(raw) if entry.get("compressed") else raw).decode()
        name = by_header.get(text.split("\n", 1)[0])
        if not name:
            raise BundleError(f"embedded module {key} matches no {JSX_DIR}/*.jsx by first line "
                              f"(was a header comment changed?)")
        modules[name] = (key, text)
    return {"html": html, "template": template, "manifest": manifest, "style": (i, j),
            "fonts": css[a:b], "css_unswapped": css[:a] + "<<FONTS>>" + css[b:],
            "modules": modules, "sources": sources}


def source_css_unswapped(repo: Path) -> str:
    css = (repo / TOKENS_CSS).read_text()
    if not FONT_IMPORT.search(css):
        raise BundleError(f"{TOKENS_CSS}: no Google Fonts @import line to swap")
    return FONT_IMPORT.sub("<<FONTS>>", css, count=1)


def stale_parts(repo: Path) -> list[str]:
    """Names of the bundle parts that differ from their sources ([] when fresh)."""
    b = load(repo)
    out = []
    if b["css_unswapped"] != source_css_unswapped(repo):
        out.append("colors_and_type.css")
    for name, (_, text) in sorted(b["modules"].items()):
        if text != b["sources"][name]:
            out.append(name)
    return out


def refresh(repo: Path) -> list[str]:
    b = load(repo)
    changed = []
    for name, (key, text) in b["modules"].items():
        src = b["sources"][name]
        if text != src:
            entry = b["manifest"][key]
            data = gzip.compress(src.encode(), mtime=0) if entry.get("compressed") else src.encode()
            entry["data"] = base64.b64encode(data).decode()
            changed.append(name)
    new_css = source_css_unswapped(repo).replace("<<FONTS>>", b["fonts"])
    i, j = b["style"]
    if b["template"][i:j] != new_css:
        changed.append("colors_and_type.css")
    template = b["template"][:i] + new_css + b["template"][j:]
    html = b["html"]
    m = _block(html, "manifest")
    html = html[:m.start(2)] + json.dumps(b["manifest"], separators=(",", ":")) + html[m.end(2):]
    m = _block(html, "template")
    # The bundler writes the template with raw UTF-8 and "</" escaped as </.
    html = html[:m.start(2)] + json.dumps(template, ensure_ascii=False).replace("</", "<\\u002F") + html[m.end(2):]
    if html != b["html"]:
        (repo / BUNDLE).write_text(html)
    return sorted(changed)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()
    try:
        changed = refresh(args.repo.resolve())
    except (BundleError, ValueError, KeyError, OSError) as e:
        print(f"refresh-ui-kit-bundle: {e}", file=sys.stderr)
        return 2
    print("refresh-ui-kit-bundle: " + (f"re-embedded {', '.join(changed)}" if changed else "already fresh"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
