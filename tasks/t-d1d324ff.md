---
id: t-d1d324ff
title: Audit P64: YAML writer/reader residue r7 — block-scalar writer corruption, anchors, duplicate sections, str() comments, nulls
status: todo
added: 2026-09-13
priority: high
---

## Description

Round-7 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round7.md, settings/YAML section). All PRE (N3 `+` chomp and N5 sweep needle were NEW and fixed in P60). Relates t-295ef4d2, t-f655c541. Needs round-7 product decisions 6–8. Oracle: PyYAML 6.0.3, harness shape under scratchpad r7-yaml (SwiftPM linking ScarfCore by path).

- HIGH · `GatewayConfigWriter.keyLineKind` (`:542-549`) classifies `key: |` as `.inlineValue`, so `setListChecked` replaces only the header and orphans the body → PyYAML ScannerError → `load_config` discards the whole config.yaml layer (`gateway/config.py:775-791` @ v2026.9.7). Input `slack:\n  allowed_channels: |\n    old\n  reply_to_mode: first`. `ProfileRoutesYAML.locate` gets it right (nil on a non-`[` scalar). Fix: a `.blockScalarHeader` kind via `HermesYAML.blockScalarHeader(rest)` routed to `.blockHeader`; the `endIdx` walk absorbs deeper lines. Every writer must consult `blockScalarHeader` (the cross-phase review's standing gap).
- MED · duplicate top-level section: writer edits the FIRST block (`firstIndex(of:headerLineEqualTo:)` `:768-786`), PyYAML reads the LAST; save says Saved, nothing changed. Decision 8: last-wins or refuse.
- MED · anchored key → dangling alias → ComposerError → layer discarded (`&ch` dropped, `*ch` survives); writer header claims "no anchors" but nothing refuses. Fix: `.refused` when the located block carries `&`/`*` at a token start.
- MED · reader: an anchored SECTION drops its subtree (`model: &m\n  default: a` → no `model.default`); `default: &m gpt-5` → `'&m gpt-5'`; `yaml.Dumper` emits `&id001`/`*id001` for shared objects. Decision 6: refuse a doc with anchors (read-only banner) or teach the reader.
- MED · blank line inside a folded quoted scalar is a NEWLINE (`'one\n\n    two'` → PyYAML `'one\ntwo'`, Scarf `'one two'`); `HermesYAML.swift:289` skips blanks before the continuation test, `:334` joins with " ". 41/2663 leaves; `yaml.dump` never emits block scalars so this is how every Hermes-written multi-line string arrives. Fix: count consecutive blanks, emit `"\n" * n`.
- MED · `str()` (`HermesConfig+YAML.swift:191-194`) keeps a trailing ` # comment` and `TerminalTab.swift:18` → `setSetting("terminal.cwd", …)` writes it back into the path. ~60 free-form keys. Decision 7: route through `normalizedScalar`'s comment rule or gate the write-back.
- LOW · explicit nulls (`~`, `null`, `Null`) read as their own text; a save writes the string.
- LOW · `ProfileRoutesWriter.swift:47-49` flips line endings wholesale (the thing `YAMLLineEndings.restore` was extracted to prevent); use it.
- LOW · `parseFlatFlowList` (`HermesYAML.swift:785`) has no nested-bracket guard (`[a, [b, c]]` → `['a','[b','c]']`); `parseFlatFlowMap` bails at `:756`.
- LOW · multi-document file (two `---`) renders in Scarf, ComposerError in Hermes; refuse like the tab-after-colon case.
- LOW · deleting a platform's last key leaves `slack:` (None) → `platform_section` falls to `platforms.slack` and un-bridged shared keys start bridging (t-f655c541 in reverse).
- Standing premise to re-argue: the per-KEY `unquote` opt-in leaves double-quoted escapes literal for non-opted keys (79 scalar + 207 list-item oracle cases); the doc's "backslash-n inside double quotes means two characters" is false about PyYAML.
- Report correction: `_SHARED_KEYS` is 27 keys, not 25.

## Plan



## Artifacts

## Release blockers (2026-09-13) — branch `fix/release-blockers`

**HIGH `GatewayConfigWriter.keyLineKind` block-scalar corruption — DONE.**
- `79d2fecb` fix(release): a block-scalar header is not an inline value
- `38593ebf` fix(release): the YAML suite obeys the test-host stability sweep

New `KeyLineKind.blockScalarHeader`, decided by `HermesYAML.blockScalarHeader(rest)`
(the same parse `isBlockScalarHeader` uses). Routed to a walk that absorbs EVERY
more-indented line — blanks and `#`-looking lines included, since inside a
literal/folded block those are text, not comments — so the body is replaced
together with its header. `BlockLocation.found` now carries `blockScalar`, so
`replaceBlock` / `setMapLF` know the block's interior was never comments.

Tests: `HermesReleaseBlockerYAMLTests` (ScarfCore, 9 tests), oracled against real
PyYAML 6.0.3 via `BotModeFixupTests.pyYAMLLoad`. 36 recorded issues without the
fix, 0 with. Covers the reviewer's input byte-exactly plus `>`, `|-`, `|+`, `>-`,
`>+`, `|2`, `| # comment`; `setMapChecked`; clearing a block-scalar key; and two
regression guards (a plain inline value and a plain block header's comments).
(`2|` was dropped from the header list: the indicator follows the `|`, so it is
not a block-scalar header at all and PyYAML agrees.)

**Sibling writers, one test each:**
- `PowerSettingsWriter` — delegates to `GatewayConfigWriter`, so it CARRIED the
  same defect and is fixed by the same change. Pinned via `setExcludedProviders`.
- `ProfileRoutesWriter` — does NOT carry it. `ProfileRoutesYAML.locate` returns
  nil for any non-`[` scalar after the colon, so the body is never orphaned; it
  falls through to the key-missing path, which appends a duplicate key PyYAML
  resolves last-wins. A no-op save, not a corrupt file. Pinned only as "still
  loads"; the duplicate-section behaviour is this task's separate MED item.

Every other item on this task is untouched and still open.

