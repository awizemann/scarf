---
title: Localization Workflow
type: note
permalink: scarf/ops/localization-workflow
tags: [i18n, localization]
source_paths: [tools/validate-catalog.py]
source_paths_inferred: true
source_sha: 7ccb6d6d5feb78ddf9809429181d313a1db31775
created: 2026-05-29
updated: 2026-09-02
---

## Observations
- [catalog] Localizable.xcstrings is the source of truth; per-locale JSONs live in tools/translations/<locale>.json (key = English source string, value = translation). Omitted keys fall back to English at runtime — use that for proper nouns (Scarf, Hermes, Anthropic, OAuth, SSH) and technical terms #catalog
- [merge] tools/merge-translations.py merges JSON files into Localizable.xcstrings; LOCALES list in that script gates which locales are processed #tooling
- [rule] Preserve format specifiers exactly: %@, %lld, %d. Use positional forms (%1$@, %2$lld) when word order needs to change #rule
- [step] Adding a locale: add to knownRegions in project.pbxproj, add JSON in tools/translations/, add to LOCALES in merge script, translate InfoPlist.xcstrings (mic permission), spot-check Dashboard/Chat/Settings in Xcode App Language #howto
- [gotcha] English stem+suffix plural-hack keys (any key with a letter directly before %@, e.g. "%lld skill%@", "%lld entr%@" — code substitutes English suffixes like "s"/"y"/"ies" into %@; 10 such keys as of v2.22.0) must NOT be translated; leave them out of the locale JSONs so they fall back to English #rule
- [gotcha] Headless xcodebuild never merges newly extracted keys into Localizable.xcstrings — only an interactive Xcode IDE build does; run one before translating new strings #tooling
- [reference] Deeper context: scarf/docs/I18N.md #docs

- [rule] **Shared components must take `LocalizedStringKey`, never `String`.** A `String` property binds `Text`'s VERBATIM overload, so nothing routed through the component is ever extracted — that silently made ~146 call sites of `ScarfPageHeader`/`ScarfSectionHeader`/`ScarfTextField`/`ScarfBadge` unlocalizable (go/no-go blocking condition 6, fixed in be4f27d). Take `LocalizedStringKey` and add an explicit `verbatim:` initializer for runtime-computed text (`init(verbatim:)`, `init(verbatim:verbatimSubtitle:)`); literal call sites are source-compatible, and only genuinely dynamic ones need the label. Same trap as `.accessibilityLabel(someStringVariable)` #rule #i18n
- [gotcha] `subtitle.map(Text.init)` does NOT compile for a `LocalizedStringKey?` — overload resolution picks `Text.init<S: StringProtocol>`. Write `subtitle.map { Text($0) }` #gotcha


- [tooling] Under headless xcodebuild, `.stringsdata` build intermediates are the authoritative extraction oracle: JSON per source file (Build/Intermediates.noindex/<target>.build/<config>/.../Objects-normal/<arch>/) listing every extractable key with file:line. Diff their union (both app targets) against Localizable.xcstrings to find missing keys mechanically — then add keys to the catalog JSON directly (since headless builds never merge). Used for the post-v2.24 backfill (+489 keys) #tooling
- [rule] Two plural-hack keys are deliberately translated ("%lld delivery failure%@", "Applied to %lld host%@") — allow-listed in scarfTests/LocalizationCatalogTests.swift, which also pins specifier parity, untranslated hack keys, and no-empty-translations. Do not grow the allow-list; they're the first candidates for real .stringsdict plurals #rule
- [gotcha] Use the curly apostrophe (U+2019, "Couldn’t…") in catalog keys — a straight-apostrophe variant of the same sentence creates a duplicate key with 6 duplicated translations (happened with "Couldn't save %@: %@", deduped post-v2.24) #gotcha


- [rule] "Zero missing localizations" is the WRONG target — the catalog is designed so omitted keys fall back to English, and ~108 keys (of 2165) are deliberately English in some or all locales. Three legitimate hole categories, and only three: (1) the 18 English stem+suffix plural-hack keys, (2) keys with no translatable words once specifiers are stripped (`"—"`, `"%@: %@"`, `"×%lld"`; 31 keys), (3) an explicit 59-key English-fallback list — proper nouns/product names (Docker, Daytona, Singularity, OAuth, SOUL.md, MCP), CLI/config literals the user types verbatim (`npx`, `oauth`, `supports_parallel_tool_calls`), sample values and URL placeholders. Anything else missing a locale is a real gap #rule
- [tooling] `tools/validate-catalog.py` is the mechanical gate: schema round-trip, specifier parity, `state: "translated"` + non-empty, and coverage against those three categories. `--list-fallbacks` prints category 3, which must stay identical to `englishFallbackKeys` in scarfTests/LocalizationCatalogTests.swift (`everyTranslatableKeyIsLocalized` + `fallbackListIsCurrent` pin both directions, so a fallback key that later gets translated fails the build rather than silently hiding a gap) #tooling
- [gotcha] Deciding whether a partly-missing key is a gap or a fallback: look at what the OTHER locales already do for that key. If every sibling value is byte-identical to the English source, it's a fallback — leave it. If siblings genuinely translated it, the missing locale is a real gap. This diff also catches mistranslated proper nouns: `Singularity` (the container runtime, TerminalTab.swift beside Docker/Daytona) had been rendered "Singularidad"/"Singularidade" in es/pt-BR; both were dropped so it falls back like its siblings #gotcha
- [tooling] `.stringsdata` extraction needs BOTH app targets built, and a headless incremental `xcodebuild` will NOT refresh them for files it didn't recompile. Build `-scheme scarf` (macOS) and `-scheme "scarf mobile" -destination 'generic/platform=iOS Simulator'` before diffing, or iOS-only strings silently look "missing" #tooling



- [rule] The `LocalizedStringKey` component rule is now **app-wide, not just ScarfDesign** (section-audit F7, 2026-09-02). Same trap, three more shapes: (a) a `String` param on any shared row/card component — SettingsComponents alone made 133/155 Settings labels unextractable; (b) a `String`-returning property on a **ScarfCore** type, which can NEVER be extracted because that package has no catalog (localize app-side, one sentence per enum case, and mark the ScarfCore property as an English token in its doc comment); (c) an English noun interpolated into a localized frame (`"Allowed \(kind.pluralNoun)"` → `"Allowed %@"`), unusable in any inflecting language. Escape hatches: `init(verbatim:)`, `verbatimLabel:`, `verbatimReason:` — put the escaped param FIRST so a call site can't drift back onto the localized init #rule #i18n
- [rule] Plural hacks are retired via **automatic grammar agreement** (`^[\(n) incident](inflect: true)`), not String Catalog plural variations: the catalog has zero `variations` entries, tools/translations is flat key→string, and validate-catalog.py assumes `stringUnit`. Keep the markup for de/es/fr/pt-BR; DROP it for ja/zh-Hans (no plural agreement). Delete the old hack key from the catalog — an unused stale key reads as translated while the live site renders the new one. 18 → 11 hack keys after F7; the two deliberate exceptions are unchanged #rule
- [gotcha] `.stringsdata` lives under the DerivedData directory for THIS project path — find it with `xcodebuild -showBuildSettings | grep OBJROOT`. A sibling worktree's DerivedData holds identically-named files whose `source` points elsewhere; diffing those reports "0 missing" and looks like success #tooling
- [gotcha] `tools/merge-translations.py` only writes keys that ALREADY exist in Localizable.xcstrings. Insert new keys into the catalog FIRST, then merge — otherwise everything lands in `unknown-keys-skipped` and the script exits 1 #tooling
