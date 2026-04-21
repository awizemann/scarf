#!/usr/bin/env python3
"""
Merge per-locale translation JSON files into Localizable.xcstrings.

Each JSON under tools/translations/<locale>.json is a flat
{ "English source key": "Translation" } map. Keys absent from the JSON
fall through to English at runtime — that's the desired behavior for
proper nouns, format-only strings, and technical terminology.

Usage:
    python3 tools/merge-translations.py

Re-runnable: rewrites the per-locale stringUnit entries each time, so
translators can iterate on a JSON and re-merge.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "scarf" / "scarf" / "Localizable.xcstrings"
TRANSLATIONS_DIR = REPO_ROOT / "tools" / "translations"

LOCALES = ["zh-Hans", "de", "fr", "es", "ja", "pt-BR"]


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def main() -> int:
    catalog = load_json(CATALOG)
    source_keys = set(catalog.get("strings", {}).keys())

    applied: dict[str, int] = {}
    skipped_unknown: dict[str, list[str]] = {}

    for locale in LOCALES:
        path = TRANSLATIONS_DIR / f"{locale}.json"
        if not path.exists():
            print(f"[skip] {locale}: no file at {path}")
            continue

        translations = load_json(path)
        applied[locale] = 0
        skipped_unknown[locale] = []

        for source, target in translations.items():
            if source not in source_keys:
                skipped_unknown[locale].append(source)
                continue
            entry = catalog["strings"].setdefault(source, {})
            entry.setdefault("localizations", {})
            entry["localizations"][locale] = {
                "stringUnit": {
                    "state": "translated",
                    "value": target,
                }
            }
            applied[locale] += 1

    save_json(CATALOG, catalog)

    # Summary
    print("Merge summary:")
    for locale in LOCALES:
        if locale in applied:
            extras = len(skipped_unknown.get(locale, []))
            print(f"  {locale:8} applied={applied[locale]:4}  unknown-keys-skipped={extras}")
    any_unknown = any(skipped_unknown.values())
    if any_unknown:
        print("\nKeys present in translation files but missing from the catalog:")
        for locale, unknowns in skipped_unknown.items():
            for k in unknowns:
                print(f"  [{locale}] {k!r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
