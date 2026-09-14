---
title: Proving a read means proving every file the surface reads, not the one that was audited
type: note
permalink: scarf/architecture/proving-a-read-means-proving-every-file-the-surface-reads
tags: [platforms, config, guarded-write, resilience, dataloss]
source_paths: [scarf/scarf/Core/Services/HermesFileService.swift, scarf/scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/GuardedTextFile.swift]
source_paths_inferred: false
source_sha: 698bee2966bf21228c03b00df7fe0105d7e61781
created: 2026-09-10
updated: 2026-09-10
reviewed: 2026-09-12
reviewed_by: claude-opus-5
---

P33 (round-3 whole-surface audit). P22 detached the 15 platform setup forms and proved the `.env` half of their load with `HermesEnvService.loadProven()`. The config.yaml half stayed tolerant — `HermesFileService.loadConfig()` returns `.empty` for an unreadable file exactly as for an absent one, and `EmailSetupViewModel` read `readText(path) ?? ""`. The hole P22 existed to close was therefore still open through the other file: a blipped read renders a blank form over live values and `saveForm` publishes the blanks.

This is the per-writer disease that `GuardedTextFile` exists to end, one layer up and on the READ side: the proof got applied to whichever FILE somebody happened to audit.

`whatsapp_cloud` was the worst case because it is config-only: access token, app secret and verify token all live in config.yaml, so one failed read plus one Save wrote ten empty `config set` pairs and `enabled: false`.

## Observations
- [invariant] A surface that reads N files and publishes a rewrite must prove all N; proving one is the per-writer disease moved to the read side #guarded-write
- [fact] `HermesFileService.loadConfigProven()` is config.yaml's twin of `HermesEnvService.loadProven()`, built on `GuardedTextFile.load`; `PlatformSetupForm.loadRefusal` latches either half's refusal and `commitSave` bounces off it #platforms
- [gotcha] `loadConfigResult()` is NOT a proof: it maps one `readFileResult`, so an ABSENT config.yaml and an unreadable one are both `.failure` — refusing to save on the former makes first-run setup impossible — and one dropped SSH round-trip reads as damage with no retry #config
- [constraint] A refused config read must leave `snapshot.config`/`rawConfigText` nil, not `.empty`/`""`: a form's `apply` then leaves its fields alone instead of resetting them to defaults over values it could not read #platforms

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[GuardedTextFile is the one guard for Scarf's non-JSON hand-authored files]]
- relates_to [[Setup forms write the resolved default; Settings treats absence as a sentinel]]
