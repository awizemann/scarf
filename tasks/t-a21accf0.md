---
id: t-a21accf0
title: Low-risk consolidation: 3× semverCompare and 6× shell-quoting copies → shared utils
status: todo
added: 2026-07-14
---

## Description

Drift-audit lower-risk findings (2026-07-14), batchable cleanup — no live bug, defensible to defer. (1) THREE byte-identical version-compare impls: SkillBootstrapService.semverCompare:212, SlashCommandBootstrapService.semverCompare:167, InstalledTemplatesIndex.isVersionNewer:125 — extract one SemVer.compare (ScarfCore already has version parsing in HermesCapabilities.parse). (2) SIX hand-rolled shell-arg quoters in two POSIX-correct styles: escapeShellArg (Scarf iOS/Chat/ChatView.swift:1487), shellEscape (IOSSettingsViewModel:129), shellQuote (SSHTransport:258, RemoteRestoreService:487, RemoteBackupService:447), HermesProfileScope.shellQuotePath:149 — extract one ShellQuoting util. (ProjectHermesShadowDetector:152 dropped from this list — that file was deleted in R12/S11-F1 2026-09-26, the shadow-detector premise was wrong.) Both correct today; risk is a future fix landing in one copy only (injection blast for the quoters). (3) LOW/leave-with-note: provider-ID string literals in ModelPickerSheet:790/878-879/1038 keyed to LocalModelProvider IDs. Risk: LOW.

## Plan



## Artifacts



