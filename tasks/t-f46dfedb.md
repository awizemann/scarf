---
id: t-f46dfedb
title: Fold ProjectSlashCommandService.yamlScalar onto YAMLScalar.quoteIfNeeded
status: todo
added: 2026-09-11
---

## Description

Found by P41's emitter sweep (round-4 whole-surface audit). After P41 folded `HermesFileService.yamlScalar` into `YAMLScalar.quoteIfNeeded`, exactly ONE hand-rolled YAML scalar emitter is left in the repo:

`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectSlashCommandService.swift:308` (`private static func yamlScalar`), emitted at `:284` (`description`), `:286` (`argumentHint`), `:289` (`model`) and `:294` (a `tags` bullet) into the Markdown frontmatter of `.hermes/commands/*.md`.

It has the same class of gap P41 just closed and then some:
- escapes only `"` (not even `\\`, so a backslash in a description round-trips doubled);
- no control-character / line-break arm at all — a raw C0/C1 control, DEL, NEL or U+2028/9 makes PyYAML's READER refuse the document;
- no tab arm;
- no implicit-resolver arm (`007`, `~`, `on`, `.inf`, `2026-09-09` all retype);
- quotes on a leading `[`/`{`/`>`/`|`/`-` only, so a leading `]`, `}`, `` ` ``, `!`, `%`, `@`, `*`, `&`, `?`, `=` or a trailing space goes out bare.

Fix: delete the body and forward to `YAMLScalar.quoteIfNeeded`, exactly as P41's `2fb7cc08` did for `HermesFileService.yamlScalar`; check the READER side of the same frontmatter (`ProjectSlashCommandService.swift:246` → `HermesYAML.parseNestedYAML`) and decide whether these keys want decision 10's per-key opt-in (`HermesYAML.scarfWrittenMapPaths`) so the pair is lossless. Verify the consequence against the Hermes tag before writing the doc comment: unlike config.yaml, a slash-command file that PyYAML refuses may fail differently (the command disappearing vs the whole layer being dropped) — cite it.

Out of P41's scope: decision 9/10 are scoped to config.yaml, and this is a different file family.

## Plan



## Artifacts



