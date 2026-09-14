---
id: t-b24e5fba
title: Audit P57: YAML reader residue r6 — folded-scalar continuation holes, boolishValue trim, dotted-key isBlock
status: done
added: 2026-09-12
---

## Description

Round-6 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round6.md, settings/YAML section). Relates t-295ef4d2, t-38ae4f26, t-f655c541. No product decision needed.

- MED · PRE · `HermesYAML.swift:212,:215,:225`: the folded-scalar continuation join runs AFTER the comment skip and is gated on `!isListItem`. PyYAML's `yaml.dump` (no `width=`, `utils.py:262-271` @ v2026.9.7) folds at 80 columns, so a continuation line routinely begins with `- ` or `#`: `- ` → value truncated + phantom `lists[section]` entry; `#` → line dropped; a single-quoted fold loses its closing quote (unbalanced leading `'`, then `normalizedScalar` truncates at ` #`). 1450/4000 adversarial dumps hit it. Fix: hoist the `indent > lastScalarIndent` continuation test above the comment skip and `isListItem` (the `lastScalarIndent` doc already justifies it for every line shape). Oracle with PyYAML 6.0.3.
- MED · PRE · `boolishValue` (`HermesYAML.swift:825-831`) and `boolTrueDefault` (`HermesConfig+YAML.swift:58-61`) compare `normalizedScalar(raw)` whose quoted arm returns the body verbatim; Hermes `_bool_token` is `str(value).strip().lower()` (`gateway/config.py:29-32`). `" false"`, `"\tyes\t"`, `" 1"` → Hermes false/true, Scarf unrecognised → default (unsafe direction for `boolTrueDefault`). PyYAML also types `01`, `00`, `+1`, `-0`, `0x1`, `0b1` as ints (`"1"`/`"0"` to Hermes). 60 disagreements in 59 372 oracle docs. Fix: trim `.whitespacesAndNewlines` AFTER unquoting at both sites (P41b's `HermesApprovalMode.swift:105-107` lesson), plus an int-resolver pass (reuse P53b's `pyYAMLIntIsZero`).
- LOW · PRE · `HermesPlatformSharedKeys.isBlock` (`:108-113`) answers true for a flat dotted key `slack.enabled:` (PyYAML: independent top-level key, `platform_section` bridges from `platforms.slack`); Scarf's `bridgeSourcePrefix` returns `slack`, so the form reads from a section Hermes does not bridge and `resolved` writes there, creating the real block (t-f655c541 reached by a read). Hand-edited configs only. Fix: `ParsedYAML` surfaces `dottedLiteralPaths`, `isBlock` excludes them.

## Plan



## Artifacts

All three items fixed on `fix/whole-surface-audit-r6`.

**Commits**
- `ea83357d` — MED, the folded-scalar continuation hoist (`HermesYAML.parseNestedYAML`, new `isOpenQuotedScalar`) + `HermesP57FoldTests.swift`.
- `a3a6564b` — MED, the boolish trim inside the quotes + the int resolver (`HermesYAML.strippedScalar`, `isQuotedScalar`, `pyYAMLIntBoolToken`, `boolishValue`; `HermesConfig+YAML.boolTrueDefault`, `busyAckEnabled`, the `gateway_restart_notification` copy) + `HermesP57BoolTests.swift`.
- `27b17954` — LOW, `ParsedYAML.dottedLiteralPaths` surfaced and excluded from `HermesPlatformSharedKeys.isBlock` + `HermesP57DottedKeyTests.swift`.

**Attribution:** all three findings touch `HermesYAML.swift` and `ea83357d` committed that file whole, so it also carries the other two commits' changes to it. Each commit builds and passes its own suite in isolation; recorded in the P57 section of `decisions/hermes-v0-21-1-compatibility-decisions`.

**Hermes citations re-opened at `v2026.9.7`:** `utils.py:262-271` (`atomic_yaml_write` → `yaml.dump`, no `width=`), `gateway/config.py:25-32` (`_TRUTHY_STRINGS` / `_FALSY_STRINGS` / `_bool_token`), `gateway/config_loader.py:171-180` (`platform_section`).

**Oracle (PyYAML 6.0.3, harness under the scratchpad):** 572 folded `yaml.dump` documents 44 → 0; 2065 adversarial bool scalars 1041 → 0 for `boolishValue` and 525 → 0 for the true-by-default rule; the maintainer's real 657-line `config.yaml` (435 leaf keys) 0. No fourth class of disagreement surfaced, so nothing was filed as "found but not fixed".

**Tests:** ScarfCore `swift test` — 3231 tests in 272 suites, 2 issues, both `M4ACPIOSTests` `.requestTimeout` under full parallel load, 2/2 green with `--filter M4ACPIOSTests` (the `t-f3820038` flake family). 18 new tests in 3 suites, all green; watched failing against each reverted fix (10 issues / 25 / 3). `scarf` Debug BUILD SUCCEEDED. No Mac, iOS or `scripts/` source touched.

**Lesson-5 sweep** for bool-word comparisons: four readers fixed (all on the write path), two filed by appending to `t-295ef4d2` (`MCPServerEditorViewModel.boolishSSLVerify:116-121`, `RichChatViewModel.swift:1299`), the rest cleared and listed there.

**Memory:** `## Whole-surface remediation — P57` appended to `decisions/hermes-v0-21-1-compatibility-decisions`; `## P57` sections appended to `architecture/a-yaml-reader-is-opted-in-per-key-and-only-for-what-scarf` (source_paths extended) and `architecture/a-platform-s-shared-keys-are-bridged-from-one-section-so`. No new task created.

