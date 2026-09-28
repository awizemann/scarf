---
id: t-c2cbb8d4
title: B07 Health, memory, voice & settings: Python discovery, iOS memory conflict, log filters, terminal settings, managed marker
status: done
added: 2026-09-27
priority: high
---

## Description

Wave 2. Findings: S14-F1 (+S03-F1: bash launcher discovery; don't silently fall back to system voice), S14-F2 (iOS memory save conflict guard), S14-F3 (log component prefixes per hermes_logging.py), S05-F1 (modal mode auto/direct/managed), S05-F2 (vercel_sandbox backend), S05-F3 (.managed opt-out values). Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

B07 (worktree Scarf-wt/b07, branch fix/hermes-v0215-blind-b07)
- S14-F1/S03-F1: HermesPythonDiscovery reads the launcher's first absolute `exec` line (installer bash launcher → venv python; exec'd console script followed one level) before the sibling search; `$`/relative targets skipped. Version-independent (host layout), old working layouts unchanged. Blast radius: Hermes Voice TTS (Mac/iOS via HermesSpeechService) + Live Voice, local + remote. MessageSpeechService: surface an honest notice when Hermes Voice falls back to the system voice. Tests: HermesPythonDiscoveryTests (real /bin/sh), goldens updated.
- S14-F2: IOSMemoryViewModel.save compares loaded bytes to originalText inside mutate; conflict → reload/overwrite prompt (iOS MemoryEditor view). Tests in ScarfCore.
- S14-F3: LogComponent prefixes mirror hermes_logging.py COMPONENT_PREFIXES, dotted-segment match. Check older bands.
- S05-F1: Modal mode options auto/direct/managed (+ append unknown stored value); check floors of modal_mode values, gate if differ.
- S05-F2: add vercel_sandbox at its true floor (capability flag), isContainerBackend, fix stale comment.
- S05-F3: HermesManagedInstall honours false/0/no/off (check floor).
Memory/wiki: search voice/python discovery, memory editor, logs, terminal settings, managed install notes.

## Artifacts

Merged into fix/hermes-v0215-blind (B07 commits 923f8237, 7d0b3acc, 96378931, 5c31520c, 30c969c9). ScarfCore 4117 pass in phase; Mac build-for-testing + iOS build OK. App suites deferred to B10.

