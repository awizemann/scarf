---
title: Hermes v0.21 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-21-compatibility-decisions
tags: [hermes, capability-gating, config, versioning, settings]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesConfig.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ConfigDottedKeySegment.swift, scarf/scarf/Navigation/SidebarView.swift, scarf/scarf/Features/Settings/Views/Tabs/DisplayTab.swift, scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-09-01
updated: 2026-09-10
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations

**NOTE: This decision record documents v0.21 compatibility work (2026-09-01 to 2026-09-12). Subsequent fixes (P55, P56b, P57b, P59) have refined implementations without invalidating the core decisions. See Relations below.**

Forced config-parity decisions for the v0.21.0 ("Pantheon", v2026.8.31) cycle, work package W1. Tag map: v2026.8.19 = 0.20.5, v2026.8.27 = 0.20.6, v2026.8.31 = 0.21.0.

The recurring shape this cycle: the v0.21 release notes advertise changes that actually shipped in the intermediate v0.20.6 tag. W0 hit this on four capability flags; W1 hit it again on two of six config items. Deciding the floor by grepping only the newest tag would have mis-gated both.

Removal flags use INVERSE semantics (`true` = still show it) and differ deliberately in their unknown-version policy: a whole sub-editor (`hasWebExtractAux`) hides on unknown, matching `hasFlushMemoriesAux`; one entry in a picker (`hasTavilyWebBackend`) is kept on unknown, because hiding a list entry the user's config currently selects strands them on an invisible selection.
- [decision] Removal flags use INVERSE semantics: `true` means "keep showing", `false` means "hide" #config
- [gotcha] v0.21 release notes advertise changes shipped in v0.20.6 (W0: 4 flags, W1: 2 config items); grepping newest tag only would mis-gate; must check intermediate versions for accurate floor #versioning
- [decision] Removal flag unknown-version policies differ: sub-editors hide (`hasFlushMemoriesAux` pattern); list entries stay visible to prevent stranding user selections (`hasTavilyWebBackend` pattern) #config

## Compatibility Decisions (W1–W9)

- [gotcha] `auxiliary.web_extract.*` was deleted at v2026.8.27 (0.20.6), NOT v0.21 as the release notes imply — present at v2026.8.19, gone at v2026.8.27 with a tombstone comment in config_defaults.py; hence hasWebExtractAux uses a v0.20.6 floor #verification
- [decision] Removing a config key upstream never means dropping its PARSE — HermesConfig+YAML keeps reading auxiliary.web_extract because pre-v0.20.6 hosts still use it; only the UI row is capability-gated, so older hosts render byte-identically #capability-gating
- [gotcha] `agent.gateway_turn_lease_timeout` default flipped 1800 -> 5 at v0.21.0, so it parses to the 0 key-absent sentinel and resolves via displayGatewayTurnLeaseTimeout(capabilities:) — same pattern as displayMaxTurns; a stepper floor/step of 60 could not express 5 and silently snapped a v0.21 host's default up 12x #config
- [gotcha] v0.21's phantom-sibling guard raises a bare ValueError from _set_nested that `hermes config set` does NOT catch (its handler only catches RuntimeError), so config-write failures reach Scarf as a raw Python traceback — error extraction must skip traceback frames and strip the exception-class label #settings
- [fact] `display.interim_assistant_messages` absent-on-disk still means TRUE: the v14->15 migration that materialised it was deleted at v2026.8.27 because runtime merging supplies the schema default without a write, so absence is now the expected state #config

### Gateway Status Detection & Restart Notification (W6 follow-on fixes)

- [gotcha] `hermes gateway status` never prints "service is loaded" anywhere — the old `contains("service is loaded")` substring could never match. Verified against real print statements in hermes_cli/gateway.py, identical at v0.20.5 and v0.21.0. **P55 refined:** Re-anchored on "(Running manually, not as a system service)" as the ONE unique marker #verification
- [decision] `gateway_restart_notification` is a TOP-LEVEL `<platform>.` key, never nested under `gateway.platforms.<p>.` (P55 re-verified the path precedence; no-op migration necessary) #fixup #go-no-go #verified

### Boolean Config Parsing (P57b refinements)

- [fact] **P57b refined boolean parsing** (2026-09-18) to handle quoted vs unquoted YAML scalars correctly. `boolTrueDefault` now uses `HermesYAML.boolishValue()` instead of manual lowercased comparison, properly handling whitespace-padded quoted strings (`" false"` now reads as false, not true). `busyAckEnabled()` is now quote-aware: quoted `'true'` means exactly that string; bare `true`/`yes`/`on`/`True` all enable; bare `1` disables (it's an int, not the string "true"). Same care applied to `gateway_restart_notification` and `mattermost.require_mention` — each key's own reader logic now shadows the universal boolish set where it must. #config #boolean-parsing
- [gotcha] No `.strip()` on the Hermes side for `display.busy_ack_enabled` — it stringifies and compares lowercased; quoted whitespace survives, so `' true'` reads as DISABLED on the host. P57b's quote-aware logic now mirrors this. #gotcha

### Curator, Skills, & Cron (W3, W7)

- [fact] `curator pin/unpin` diagnostic behavior — floor v0.20.6, not v0.21. `HermesCapabilities.hasEssentialHermesAgentSkill` (v0.20.6+) strips "hermes-agent" from disabled lists so stale config can't render it as OFF. #hermes-v0-21
- [fact] `hermes cron doctor` exits 1 on the normal "found issues" path. Any Scarf caller must parse stdout regardless of exit code; gating the parse on `exitCode == 0` would silently show zero findings exactly when there are some. #gotcha #cron
- [fact] `supportsCronDeliver(_:)` fixed with explicit `bot-chat` / `bot-chat:` prefix branch on `hasCronBotChatDelivery` (v0.20.6+) to avoid forwarding unsupported delivery modes to older hosts. #cron #fixup

### Session Preview SQL (W6)

- [fact] Ported Hermes's two-SQL session preview logic (`_PREVIEW_ELIGIBLE_SQL` + `_PREVIEW_RAW_SELECT`) to Swift as `SessionPreviewSQL`, byte-identical to Python for drift-detection. In-place compaction rewrite means the earliest user row is often a carrier; eligibility must detect and strip it by content markers. #sql #session
- [gotcha] Eligibility must live INSIDE the `MIN(id)` aggregate, not as an outer filter — otherwise a pure-carrier session loses its preview entirely. Also: SQL `SUBSTR` counts code points like Python's `len`, but Swift's `String.count` counts grapheme clusters — use `String.unicodeScalars.count` for window sizing or em-dashes in future prefixes will misalign. #sql #gotcha
- [decision] `messages._compressed_summary` (v0.21) is DETECTED but deliberately unused — Scarf already classifies carriers from content, which works on pre-v0.21 hosts where the column does not exist. Consulting it adds a schema dependency without new information. #decision

### Dotted-Key Escaping (W8)

- [decision] User text interpolated into `hermes config` dotted keys (quick commands, credential-pool providers) could corrupt config.yaml if containing `.`. Hermes v0.21 semantics: `_split_key_path` treats `\.` as literal dot, unescaped dots split. `ConfigDottedKeySegment.escaped(_:capabilities:)` backslash-escapes `.` → `\.` on v0.21+ hosts; on older/undetected hosts, strips dots (only safe option pre-escape syntax). #config #fixup
- [fact] Read-side fix paired with write: `QuickCommandsViewModel.loadQuickCommands` now peels known `.type`/`.command` suffixes instead of positional splitting, recovering names with literal dots from both pre-v0.21 corrupted (nested) entries and fresh writes. #read-write-parity

### Peers Surface (W9)

- [decision] The Peers surface is gated on `hasPeerRunCommands` (v0.21 floor) and reads peer registry from `config.yaml` `bot_peers:` via `HermesConfigReader`, NOT from the no-JSON `hermes peer list` (which would require credential resolution). `HermesBotPeer` exposes only `name`/`url`/`note` and safe `keyEnvName` for env-var configuration. #peers #decision
- [gotcha] `hermes peer run` writes to stderr on success paths (durability warnings). Judge by exit code only; `HermesPeerCLI.durabilityWarning(inStderr:)` separates warnings from real errors. #peers #gotcha

### Dead Config Keys (Pre-release go/no-go, 2026-09-09)

- [fact] **`agent.verbose` is DEAD** — not a config key at all. It is argparse-only (`hermes_cli/main.py:3429`), independent of `display.tool_progress: verbose`. Removed from DisplayTab and iOS settings. #go-no-go #verified
- [fact] **`redaction.enabled` is DEAD;** the real switch is `security.redact_secrets` (which Scarf's Security tab already surfaces). Row + hint removed. #go-no-go #verified  
- [fact] **`tts.xai.model` is DEAD for synthesis** — no xAI reader consumes it. Only reader is a staleness WARNING pass, so the key only produces spurious notices. Row + setter + parse removed. #go-no-go #verified

## Relations
- implements [[Hermes Capability Gating Pattern]]
- related_to [[Hermes v0.21.0 Audit Findings]]
- related_to [[Hermes Version Management]]
- extends [[Hermes v0.20.5 Compatibility Decisions]]
- **REFINED BY (P55):** Capability floor re-walk; `hasKanban` moved from v0.12 to v0.13 floor (archive: [[Hermes Kanban Command Floor]]) — Scarf's gate is current
- **REFINED BY (P57b):** Boolean parsing logic rewrite for quoted-scalar handling; `boolTrueDefault`, `busyAckEnabled()`, `mattermostRequireMention()` now quote-aware
- **REFINED BY (P59):** Gate group reorganization; follow-on flag corrections
