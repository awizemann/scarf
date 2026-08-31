---
title: Localization Workflow
type: note
permalink: scarf/ops/localization-workflow
tags: [i18n, localization]
created: 2026-05-29
updated: 2026-08-31
---

## Observations
- [catalog] Localizable.xcstrings is the source of truth; per-locale JSONs live in tools/translations/<locale>.json (key = English source string, value = translation). Omitted keys fall back to English at runtime — use that for proper nouns (Scarf, Hermes, Anthropic, OAuth, SSH) and technical terms #catalog
- [merge] tools/merge-translations.py merges JSON files into Localizable.xcstrings; LOCALES list in that script gates which locales are processed #tooling
- [rule] Preserve format specifiers exactly: %@, %lld, %d. Use positional forms (%1$@, %2$lld) when word order needs to change #rule
- [step] Adding a locale: add to knownRegions in project.pbxproj, add JSON in tools/translations/, add to LOCALES in merge script, translate InfoPlist.xcstrings (mic permission), spot-check Dashboard/Chat/Settings in Xcode App Language #howto
- [gotcha] English stem+suffix plural-hack keys (any key with a letter directly before %@, e.g. "%lld skill%@", "%lld entr%@" — code substitutes English suffixes like "s"/"y"/"ies" into %@; 10 such keys as of v2.22.0) must NOT be translated; leave them out of the locale JSONs so they fall back to English #rule
- [gotcha] Headless xcodebuild never merges newly extracted keys into Localizable.xcstrings — only an interactive Xcode IDE build does; run one before translating new strings #tooling
- [reference] Deeper context: scarf/docs/I18N.md #docs
