---
id: t-88eec9a9
title: Translate the 238 new string-catalog keys (6 locales)
status: done
added: 2026-08-31
---

## Description

The 2026-08-31 Xcode build synced Localizable.xcstrings from 1383 to 1621 keys (commit 8b3bed3): ~30 accessibility labels plus the extraction backlog since the last IDE build. New keys are en-only; only 583/1621 entries carry translations. Run the ops/Localization Workflow to fill de, es, fr, ja, pt-BR, zh-Hans for the new keys.

## Plan



## Artifacts

Done in 4b10dd3. Six parallel locale translators filled tools/translations/*.json (583 -> 816-820 entries each); independent verification: no existing entries altered, zero format-specifier mismatches across all locales. Deliberate English fallbacks: /path/to/project, alice, discord, X-User-Id, and the stem+suffix plural hacks "%lld entr%@" / "%lld field%@ drifted" (untranslatable — app substitutes English suffixes into %@; stripped from locales that had translated them). Merged via tools/merge-translations.py; build green.

