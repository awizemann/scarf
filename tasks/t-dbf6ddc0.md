---
id: t-dbf6ddc0
title: B09 Servers & transport: scp quoting, Edit hints, removeServer main actor, iOS ~ paths, local env probe, git chip
status: done
added: 2026-09-27
---

## Description

Wave 3. Findings: S15-F1 (verify scp/SFTP quoting live first), S15-F2 (hints to non-existent Edit screen), S15-F3, S15-F4, S15-F5, S11-F3. Plan: documents/plans/hermes-v0215-blind-reaudit-remediation-plan.md.

## Plan

B09 (worktree Scarf-wt/b09, branch fix/hermes-v0215-blind-b09)
- S15-F1: verified LIVE locally (scp -S fake-ssh → /usr/libexec/sftp-server): quoted spec fails "dest open \"'My Projects/a.json'\"", unquoted works. Fix: pin SFTP (`-s`), pass remote path unquoted (keep `~/`); extract argv builder + test. Blast: every remote unguardedWriteFile (Mac).
- S15-F2: reword 6 hints (RemoteDiagnosticsViewModel x3, ConnectionStatusViewModel x2, HermesDataService) + ServerRegistry export comment to "remove and re-add with <field>". Mac + ScarfCore (iOS shares HermesDataService copy).
- S15-F3: ServerRegistry.removeServer → closeControlMaster via OffPool off-main.
- S15-F4: CitadelServerTransport.commandLine: `~/`-prefixed tokens → double-quoted $HOME/ form (mirror remotePathArg). ScarfIOS tests.
- S15-F5: env probe uses the user's login shell (pw_shell/$SHELL; zsh/bash/fish, else zsh); hermesBinaryPath falls back to harvested PATH (never blocks main before the probe is ready).
- S11-F3: GitBranchService local → resolve git on enriched PATH (+brew dirs), skip /usr/bin/git shim when no developer tools (avoid install dialog). ScarfCore tests.
Tests: ScarfCore TransportAtomicityParityTests update + new tests; ScarfIOS CitadelTransport tests; scarfTests pins (P52 citation) updated. Memory/wiki: search transport/scp, server edit, env probe, git chip notes.

## Artifacts

Merged into fix/hermes-v0215-blind (7 B09 commits; S15-F1 confirmed real by local scp+sftp-server repro). ScarfCore/ScarfIOS pass in phase; Mac build-for-testing + iOS build OK. App suites deferred to B10. Leftovers logged in plan.

