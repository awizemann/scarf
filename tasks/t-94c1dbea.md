---
id: t-94c1dbea
title: v0205 P1: HermesCapabilities v0.20.5 flag group + capability test cluster
status: done
added: 2026-08-26
---

## Description

Branch feat/hermes-v0205-parity. Add `// MARK: v0.20.5 (v2026.8.19) flags` to HermesCapabilities.swift following the isV0204OrLater per-key semver-floor pattern: isV0205OrLater, hasVersionFlagFullOutput (hermes --version carries full output incl. "commits behind"; bare `version` subcommand removed at 0.20.5), hasCronReasoningEffort (cron create/edit --reasoning-effort). Add the standard test cluster mirroring v0.20.4's: parse-version-line, all-v0205-flags-on, v0.20.4-host-hides-v0205-flags (degradation), later-patch-still-on. Source: documents/hermes-v0.20.5-audit-report.md. Build + run ScarfCore tests + fresh-eye self-audit + commit.

## Plan



## Artifacts



