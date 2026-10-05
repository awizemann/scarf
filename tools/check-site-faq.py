#!/usr/bin/env python3
"""
Check that the landing page's FAQ and its JSON-LD FAQPage say the same thing.

site/landing/index.html carries every FAQ twice: once as visible
<details><summary>Q</summary><div>A</div></details> markup, and once as a
schema.org FAQPage inside <script type="application/ld+json">. Search engines
read the second copy, people read the first, and the two drift whenever one is
edited without the other.

Checks, in order:

1. Every <script type="application/ld+json"> block parses as JSON.
2. Exactly one FAQPage exists, and every Question has a name and answer text.
3. The visible questions and the JSON-LD questions are the same set, in the
   same order.
4. Each JSON-LD answer equals the visible answer with tags stripped, entities
   decoded and whitespace collapsed. The visible text is canonical — fix the
   JSON-LD to match it.

Usage:
    python3 tools/check-site-faq.py [path/to/index.html]

Stdlib only. Exits 0 when everything matches, 1 on any mismatch or parse
error, with one line per problem.
"""
from __future__ import annotations

import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PAGE = REPO_ROOT / "site" / "landing" / "index.html"


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


class _PageParser(HTMLParser):
    """Collects visible FAQ pairs and raw ld+json script bodies."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.faqs: list[tuple[str, str]] = []
        self.ld_blocks: list[str] = []
        self._in_details = 0
        self._in_summary = False
        self._in_ld = False
        self._question: list[str] = []
        self._answer: list[str] = []
        self._ld_buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "details":
            self._in_details += 1
            self._question, self._answer = [], []
        elif tag == "summary" and self._in_details:
            self._in_summary = True
        elif tag == "script" and dict(attrs).get("type") == "application/ld+json":
            self._in_ld = True
            self._ld_buf = []

    def handle_endtag(self, tag):
        if tag == "summary" and self._in_summary:
            self._in_summary = False
        elif tag == "details" and self._in_details:
            self._in_details -= 1
            self.faqs.append(("".join(self._question), "".join(self._answer)))
        elif tag == "script" and self._in_ld:
            self._in_ld = False
            self.ld_blocks.append("".join(self._ld_buf))

    def handle_data(self, data):
        if self._in_ld:
            self._ld_buf.append(data)
        elif self._in_summary:
            self._question.append(data)
        elif self._in_details:
            self._answer.append(data)


def _find_faq_pages(node, found: list) -> None:
    if isinstance(node, dict):
        if node.get("@type") == "FAQPage":
            found.append(node)
        for value in node.values():
            _find_faq_pages(value, found)
    elif isinstance(node, list):
        for value in node:
            _find_faq_pages(value, found)


def check(page: Path) -> list[str]:
    errors: list[str] = []
    parser = _PageParser()
    parser.feed(page.read_text(encoding="utf-8"))
    parser.close()

    if not parser.ld_blocks:
        return [f"no <script type=\"application/ld+json\"> block found in {page}"]

    faq_pages: list = []
    for i, block in enumerate(parser.ld_blocks, 1):
        try:
            data = json.loads(block)
        except json.JSONDecodeError as exc:
            errors.append(f"ld+json block #{i} does not parse: {exc}")
            continue
        _find_faq_pages(data, faq_pages)
    if errors:
        return errors
    if len(faq_pages) != 1:
        return [f"expected exactly one FAQPage in ld+json, found {len(faq_pages)}"]

    ld: list[tuple[str, str]] = []
    for q in faq_pages[0].get("mainEntity", []):
        name = q.get("name")
        text = (q.get("acceptedAnswer") or {}).get("text")
        if not isinstance(name, str) or not isinstance(text, str):
            errors.append(f"JSON-LD Question missing name or acceptedAnswer.text: {q!r:.120}")
            continue
        ld.append((normalize(name), normalize(text)))

    visible = [(normalize(q), normalize(a)) for q, a in parser.faqs]
    if not visible:
        errors.append("no visible <details><summary> FAQ entries found")

    vis_q = [q for q, _ in visible]
    ld_q = [q for q, _ in ld]
    for q in vis_q:
        if q not in ld_q:
            errors.append(f"visible FAQ missing from JSON-LD: {q!r}")
    for q in ld_q:
        if q not in vis_q:
            errors.append(f"JSON-LD Question has no visible FAQ: {q!r}")
    if not errors and vis_q != ld_q:
        errors.append("FAQ order differs between visible markup and JSON-LD")

    ld_by_q = dict(ld)
    for q, answer in visible:
        if q in ld_by_q and ld_by_q[q] != answer:
            errors.append(
                f"answer mismatch for {q!r}:\n"
                f"    visible: {answer}\n"
                f"    JSON-LD: {ld_by_q[q]}"
            )
    return errors


def main(argv: list[str]) -> int:
    page = Path(argv[1]) if len(argv) > 1 else DEFAULT_PAGE
    if not page.is_file():
        print(f"check-site-faq: no such file: {page}", file=sys.stderr)
        return 1
    errors = check(page)
    if errors:
        print(f"check-site-faq: {len(errors)} problem(s) in {page}:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        if any("mismatch" in e or "missing" in e or "no visible" in e or "order" in e for e in errors):
            print("  The visible <details> text is canonical; update the JSON-LD FAQPage to match.",
                  file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
