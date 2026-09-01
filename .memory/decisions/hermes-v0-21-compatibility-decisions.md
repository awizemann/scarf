---
title: Hermes v0.21 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-compatibility-decisions
tags: [hermes, capability-gating, config, versioning, settings]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift, scarf/scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift]
source_paths_inferred: false
source_sha: 07620fa86c785262ff7ebef43f12a48bb732b957
created: 2026-09-01
updated: 2026-09-01
---

Forced config-parity decisions for the v0.21.0 ("Pantheon", v2026.8.31) cycle, work package W1. Tag map: v2026.8.19 = 0.20.5, v2026.8.27 = 0.20.6, v2026.8.31 = 0.21.0.

The recurring shape this cycle: the v0.21 release notes advertise changes that actually shipped in the intermediate v0.20.6 tag. W0 hit this on four capability flags; W1 hit it again on two of six config items. Deciding the floor by grepping only the newest tag would have mis-gated both.

Removal flags use INVERSE semantics (`true` = still show it) and differ deliberately in their unknown-version policy: a whole sub-editor (`hasWebExtractAux`) hides on unknown, matching `hasFlushMemoriesAux`; one entry in a picker (`hasTavilyWebBackend`) is kept on unknown, because hiding a list entry the user's config currently selects strands them on an invisible selection.

## Observations
- [gotcha] `auxiliary.web_extract.*` was deleted at v2026.8.27 (0.20.6), NOT v0.21 as the release notes imply — present at v2026.8.19, gone at v2026.8.27 with a tombstone comment in config_defaults.py; hence hasWebExtractAux uses a v0.20.6 floor #verification
- [decision] Removing a config key upstream never means dropping its PARSE — HermesConfig+YAML keeps reading auxiliary.web_extract because pre-v0.20.6 hosts still use it; only the UI row is capability-gated, so older hosts render byte-identically #capability-gating
- [gotcha] `agent.gateway_turn_lease_timeout` default flipped 1800 -> 5 at v0.21.0, so it parses to the 0 key-absent sentinel and resolves via displayGatewayTurnLeaseTimeout(capabilities:) — same pattern as displayMaxTurns; a stepper floor/step of 60 could not express 5 and silently snapped a v0.21 host's default up 12x #config
- [gotcha] v0.21's phantom-sibling guard raises a bare ValueError from _set_nested that `hermes config set` does NOT catch (its handler only catches RuntimeError), so config-write failures reach Scarf as a raw Python traceback — error extraction must skip traceback frames and strip the exception-class label #settings
- [fact] `display.interim_assistant_messages` absent-on-disk still means TRUE: the v14->15 migration that materialised it was deleted at v2026.8.27 because runtime merging supplies the schema default without a write, so absence is now the expected state #config

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
- relates_to [[Hermes Version Compatibility Target]]
- extends [[Hermes v0.20.5 Compatibility Decisions]]

- [gotcha] `hermes gateway status` never prints \"service is loaded\" anywhere — GatewayViewModel.swift's old `contains(\"service is loaded\")` could never match (that string exists only as a Python code comment in gateway.py); `contains(\"stale\")` matched by accident against unrelated log noise. Verified against real print statements in hermes_cli/gateway.py, identical at v2026.8.19 (0.20.5) and v2026.8.31 (0.21.0) #verification
- [decision] Re-anchored `MessagingGatewayInfo.isLoaded` on \"(Running manually, not as a system service)\" (`MessagingGatewayViewModel.isServiceLoaded(pid:statusOutput:)`) — that phrase is the ONE marker unique to gateway.py's manual/no-service branch; every service-managed branch (systemd_status/launchd_status/Windows) prints different text and never it, so its absence while a PID is known reliably means service-managed. Dropped `isStale` entirely rather than fake it: launchd's \"Service definition is stale…\" and systemd's \"…definition is outdated\" are two different strings, neither reachable from the manual branch Scarf actually parses #capability-gating
- [decision] HealthViewModel's update-status line match switched from `.contains(\"commits behind\")` to `.hasPrefix(\"Update available\")` — Hermes's `_startup_fast.py` prints three shapes (plural \"N commits behind\", singular \"1 commit behind\", count-less \"Update available — run …\"); the old substring missed the last two. Added `HealthViewModel.UpdateStatus`/`parseUpdateStatus(lines:)` as the shared parse used by load(), loadVersion(), and shouldFallBackToBareVersionSubcommand #config
- [gotcha] Offline `hermes --version`/`version` (failed git fetch) prints NEITHER an \"Update available…\" line NOR \"Up to date\" at all (banner.py's check_for_updates() returns None on fetch failure, and _startup_fast.py has no branch for None) — HealthViewModel now surfaces this as `updateStatusUnknown = true`, distinct from a confirmed-current host, so an offline user is never told they're up to date #gotcha
