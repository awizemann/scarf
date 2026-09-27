---
id: t-6f1caea2
title: R02 Profile pinning: -p default helper, default bot chat, remote profiles
status: done
added: 2026-09-26
priority: high
---

## Description

Findings S13-F2, S13-F1, S01-F1 (merged), S13-F3, S13-F4, S13-F6. Wave 1. Branch fix/hermes-v0215-audit-r02, worktree Scarf-wt/r02.

## Plan

R02 profile pinning (S13-F2, S13-F1, S01-F1, S13-F3, S13-F4, S13-F6).
- Shared helper: move BotAgentConfigService.profileFlag into HermesProfileScope (profileFlag(_:) always emits -p <name|default>) + root-pin helpers (rootPinArguments / pinnedHermesArguments for a root-home remote context, shell-text variant for /bin/sh -c scripts).
- S13-F2/S01-F1: createCanonicalBotChat + ACPClient.acpArguments use profileFlag (default bot -> -p default). isAddressableProfile guard kept.
- S13-F1: remote transports (SSHTransport.composedRemoteCommand, CitadelServerTransport.asyncRunProcessImpl, ACPClient+iOS.buildACPCommand) prepend -p default to hermes argv when the context's home is the root and argv has no leading profile flag; skip bare --version probes (fast path). Script callers that embed hermes in sh -c text (iOS ChatView, MemoryListView, IOSSettingsViewModel x2, HermesConfigReader x2) get the flag in script text for remote root contexts. Local transport unchanged (local files follow active_profile too).
- Floor (C1): -p/--profile and -p default -> root since v2026.3.30 (0.6.0, Scarf's supported floor) -> unfloored; note 0.6-0.8 Docker custom-root caveat.
- S13-F3: remote Profiles derives isActive from <root>/active_profile (the marker follows the process home), local keeps marker.
- S13-F4: move Mac parseProfileList to ScarfCore, reuse on iOS; iOS checks exit code.
- S13-F6: Mac load() keeps previous list + shows error on non-zero exit.
Blast radius: every remote hermes spawn on a root-home window (Mac SSH + iOS Citadel); bots Mac local+remote; Profiles Mac+iOS.
Tests: HermesProfileScopeTests (flag/pin helpers), SSHTransport composed command tests, ACPCommandBuilder (iOS), ACP args test, BotConversationTests, profile list parser tests (ScarfCore), ProfilesViewModel load failure/active tests. Round-trip against Hermes _scan_profile_flag/_apply_profile_override from reference .venv with scratch HERMES_HOME.
Memory/wiki: profile/HERMES_HOME resolution note, decision-scarfgo-profile-switching-via-per-connection, transport notes, bots notes.

## Artifacts

Merged into fix/hermes-v0215-audit as de95a398 (cc5e0c2d, 9e116086, a969e4ae). Orchestrator audit: diff reviewed (profileFlag/pinnedRemoteArguments/rootPinShellFragment; Mac remote ACP goes through composedRemoteCommand), 63 ScarfCore tests re-run green on integration. Full scarfTests 1602 (1 unrelated temp-dir race). Fresh-eyes: 5 found, 4 fixed, 1 accepted (0.6–0.8 Docker custom root). Open for R15: local default-bot context drift when host sticky profile changes (pre-existing).

