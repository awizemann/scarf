---
title: Hermes v0.21.4/v0.21.5 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-4-v0-21-5-compatibility-decisions
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelCatalogService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPreflight.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/WebToolsBackendRoster.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/scarf/Core/Services/HermesFileService.swift, scarf/scarf/Features/Platforms/Views/PlatformSetup/WhatsAppSetupView.swift, scripts/check-hermes-tables.py]
source_paths_inferred: false
source_sha: 70efa831cb229c14ceafbcddfbf611856e610c30
created: 2026-09-26
updated: 2026-09-27
reviewed: 2026-09-26
reviewed_by: audit:claude-code (background)
---
Scarf's v0.21.4 (v2026.9.21) + v0.21.5 (v2026.9.24) parity cycle, branch `feat/hermes-v0215-parity` (2026-09-26), shipping as Scarf 3.4.0. Plan + audit: `documents/plans/2026-09-26-hermes-v0-21-5-release-plan.md`, `documents/plans/2026-09-26-p6-surface-audit-findings-and-fix-plan.md`. Verdict: state.db columns Scarf reads unchanged; one new ACP event (approval closes); the big themes were multiplex-by-default gateways, CLI output/exit-code changes, and the FTS redesign.

## Observations
- [decision] Flags. v0.21.4 group: hasMultiplexByDefault, hasOpenCodeFreeProvider (window v0.20.5 ≤ v < v0.21.4; undetected hosts stay true to keep the `.empty` invariant), hasChatGPTCodexAliases, hasOpenAINativeWebSearchBackend, hasCompressionThresholdTokensDefault256K, hasWhatsAppUnauthorizedDMDecline, hasSessionsOptimizeForce, hasBackupPartialExitNonZero, hasCronModelPin, hasCronIncidentResolvedState, hasPeerDMNoResendOutcomes. v0.21.5 group: hasMultiplexOptOutRewrite, hasGatewayStandaloneProfiles, hasGatewayProfileParking, hasMCPBoolishNumericTruthiness, hasCronJobDefinitionFields, hasGatewayStandaloneStatusBox. Window flag: hasMultiplexProfileAllowlist (v0.20.1 ≤ v < v0.21.3 — the key's reader is gone at v0.21.3) #capabilities
- [decision] Deliberately UNGATED (behaviour-preserving on old hosts, verified): ignore `tool_call_update` for ids never started (≤v0.21.3 only ever updated started ids); tolerant kanban `diagnostics --json` decode (throws on a drifted per-task row, skips the v0.21.4 home-scope row); FTS aligned-layout detection via sqlite_master `messages_fts_src`; `session/cancel` as a JSON-RPC NOTIFICATION (acp 0.8.1–0.9.0 never accepted it as a request — Stop was inert before this) #acp
- [decision] Provider removals are modelled as `legacy*` tables consulted below the floor, because `check-hermes-tables.py` diffs mirror tables literally against the target tag with no version windows; capability-threaded catalog APIs default `capabilities: .empty` = old behaviour, so every production caller must pass real capabilities (audited) and every VM reload must reuse them #provider-removal-pattern
- [gotcha] Config-default flips only apply to ABSENT keys: `compression.threshold_tokens` (None→256_000 at v0.21.4) is `Int?` in Scarf and an explicit 0/null means ratio-only; parse like Python `int()` (underscores, float truncation). WhatsApp `unauthorized_dm_decline_message` is a GLOBAL GatewayConfig key (top-level or `gateway.`), never `whatsapp.` #config
- [gotcha] A git/fork Hermes install can print `v0.21.4+4142.g<sha> (2026.9.24)` while carrying v0.21.5 code; Scarf reads the semver before `+` and so treats it as v0.21.4 (safe direction). For live testing use the official tag (e.g. a worktree at the tag + its own venv) #testing

## P9 final-review fixes (2026-09-26)
- [gotcha] Typing a config.yaml number: decide the PyYAML type FIRST, then apply Python `int()`. PyYAML 6.0.3's float resolver needs a `.` AND a signed exponent, so bare `1e30`, `1.5e3`, `nan`, `inf` are `str` (→ `_positive_int` None), while `.inf`/`1.0e+30`/`1.5e+3` are floats; `010` is octal 8, `0x10`=16, `1:30`=90, `true`=1; a quoted `"256_000"` is str and `int()` accepts it (PEP 515) but `"300000.0"` is rejected. `Int(Double(x))` traps on nan/inf/out-of-range — never use it on config text (`HermesConfig.pythonIntCoerce`). #yaml #crash
- [decision] `hermes doctor` completion = one of `_print_summary`'s three lines (`All checks passed!` / `Found N issue(s) to address:` / `Fixed N issue(s).`, doctor.py:142-163@v2026.9.24, wording identical at every tag since v2026.3.12). Parsed sections + exit 1 is NOT completion (the DOCTOR_CHECKS loop is unguarded). `runHermesCLI`'s `-1` is timeout only when the last line is `Command timed out after Ns.`. #health
- [decision] `peer run` keeps its `--idempotency-key` only when the run may exist: Scarf's own timeout or the CLI's `Could not reach peer '…'` arm (where the POST's own urllib timeout lands). HTTP rejections drop it — a kept key after a 409 `idempotency_key_conflict` (fingerprint = body incl. Bot Chat session_id) would 409 forever. #peers
- [gotcha] iOS ChatController: `.active` must skip only when a reconnect ladder is RUNNING (`reconnectTask != nil`); `pauseInBackground` leaves `.reconnecting` with no ladder, which stranded every background round-trip. #ios

## R18c fixes (2026-09-27)
- [decision] Honcho "Eager Init" toggle REMOVED: Hermes reads `initOnSessionStart` only from the honcho.json host block (`plugins/memory/honcho/client.py:108-118,323` @ v2026.9.24, since d9f53dba4c), never config.yaml; Scarf's write was inert. Hermes's dashboard edits the block. #honcho
- [decision] Nous `/v1/models` bearer = `providers.nous.agent_key` (fallback `access_token`; separate opaque key before v2026.5.28), skipped when `agent_key_expires_at`/`expires_at`/JWT `exp` is within 60 s (key lives ~1 h, Hermes renews before each run); `inference_base_url` honoured when https. Scarf never refreshes (would rotate the refresh token under Hermes). #nous
- [decision] `TransportError.classifySSHFailure`: generic "permission denied"/"authentication failed"/unreachable phrases count only at exit 255; ssh-only forms (`Permission denied (publickey|password|…`, host-key banners, `ssh: `, `Connection closed by … port 22`) at any exit (legacy `scp -O` exits 1). A remote `cat`'s own Permission denied is `.commandFailed`. #transport
- [decision] Fetch MCP preset = `uvx mcp-server-fetch` (npm `@modelcontextprotocol/server-fetch` is a 404); its description says the Hermes host needs uv (R19). #mcp

## R19 fixes (2026-09-27)
- [decision] Parked named profile: `gateway status` early-returns with only the parked line (`gateway_profile_lifecycle.py:82-88`, `gateway.py:5020-5023` @ v2026.9.24) and `gateway restart` for a parked profile the host doesn't serve falls through (`:52-55`) to `run_gateway` in the foreground. Scarf refuses restart there (stop+start allowed — its start unparks). When the home's profile name is known, only a parked line naming it counts. #gateway
- [decision] v0.21.4+ external-supervisor restart drains (60 s floor, `_get_restart_exit_wait_budget`) then waits 15 s for a new PID; Platforms/MCP restart now waits 60 s and a timeout on that path is "still restarting" (.unconfirmed); `✓ Gateway relaunched by its supervisor` is a success marker. #gateway



## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Aggregator providers must skip the model/provider mismatch preflight]]
- relates_to [[Hermes gateway multiplex-by-default and parked profiles (v0.21.4 / v0.21.5)]]
- relates_to [[Hermes v0.21.4 non-zero exits that are NOT failures (backup, profile delete, peer dm) and the optimize holder refusal]]
