---
id: t-bcdef737
title: v0.21.1 P1: Settings — fast mode picker, telemetry, new config keys
status: done
added: 2026-09-08
priority: high
---

## Description

Phase 1 of the Hermes v0.21.1 parity plan (brief: documents/hermes-v0.21.1-parity-agent-brief.md; findings: documents/hermes-v0.21.1-audit-report.md). Depends on P0 (flags exist).

Scope:
1. Finding A4: replace the Bool "Fast Mode" toggle at AgentTab.swift:46-48 with a picker over the values Hermes's `_parse_service_tier_config` accepts (cli.py:274-284 at v2026.9.7): Off (write ""), Always (write "fast" — keep the value Scarf already writes for continuity), Auto, Cold. Gate Auto/Cold rows on `hasServiceTierBoundedModes`; on older hosts render the picker with only Off/Always so pre-target hosts stay byte-identical in behavior (a toggle and a 2-way picker must round-trip the same values; if you keep the toggle on old hosts that is fine too — choose the simpler code). Add `agent.fast_auto_seconds` (int, default 60) stepper, shown only when Auto/Cold selected and gated. Reading: map "priority"/"on"/"fast" → Always, ""/normal/default/standard/off/none → Off, so a config written by the CLI reads correctly.
2. Finding A5: fix AdvancedTab.swift:205,220 telemetry copy (no longer claim there is no remote sink). Add `telemetry.shared_metrics.send` toggle (default false) gated on `hasSharedMetricsTelemetry`, disabled unless `telemetry.enabled` is on, with copy stating the endpoint host and that only data collected inside an opt-in window is sent (verify wording against hermes_cli/config_defaults.py telemetry block and the telemetry sender module at v2026.9.7).
3. Finding C9 config-key batch, each gated on isV0211OrLater and verified against config_defaults.py at v2026.9.7 for path, type, default: `updates.check` (Advanced), `display.bell_on_prompt` (Display, beside bell_on_complete at DisplayTab.swift:67), `model.streaming` (label it clearly as provider request streaming, distinct from display.streaming), `gateway.trust_env`, `tool_loop_guardrails.non_interactive_hard_stop_enabled`, `display.resume_last_session`, `delegation.independent_completions`, `delegation.compression_threshold_tokens`. Skip `delegation.fallback_providers` and `agent.budget_warning_ratio` unless trivially fits an existing row type.
4. Finding A11 verification only (no UI): confirm nothing in Scarf assumes unbounded session history now that `sessions.auto_prune` defaults true with 90-day retention at v0.21.1; record the answer in artifacts.
5. Extend the config-parity test (scarf/scarfTests/HermesFileServiceConfigParityTests.swift) and HermesConfig+YAML round-trip tests for every new key. Run the ScarfCore tests and the scarf app test target that covers Settings.

Out of scope: sessions retention UI (user declined), Web Tools pickers (P0).

## Plan



## Artifacts

Commit `15014d80` on `feat/hermes-v0211-parity` — "feat(settings): v0.21.1 fast-mode picker, split telemetry opt-ins, new config keys".

## Shipped
- **A4** — new `ScarfCore/Models/HermesServiceTier.swift` mirrors `_parse_service_tier_config` (cli.py:274-284 @ v2026.9.7) + `agent/fast_mode.py:16`. `AgentTab` "Fast Mode" is now a PickerRow (Off / Always / Auto / Cold), gated: `hasServiceTierBoundedModes` adds Auto/Cold, older hosts get the two values the Bool toggle wrote, and a bounded value already on disk is kept in the option list rather than silently overwritten. New `agent.fast_auto_seconds` stepper (default 60) shows only when a bounded mode is selected on a host that has them.
- **A5** — `TelemetrySettings` gains `sharedMetricsSend` + `sharedMetricsEndpoint` (+ `sharedMetricsEndpointHost` for copy). `AdvancedTab` telemetry section adds a "Send metrics to Nous" toggle gated on `hasSharedMetricsSend`, disabled while collection is off; footnote is now per host generation — pre-v0.21.1 keeps the original "no remote sink" wording verbatim, v0.21.1+ states the two opt-ins and names the endpoint host read from config.
- **C9** — all eight keys, each verified absent at v2026.8.31 / present at v2026.9.7, all gated on `isV0211OrLater` (no new capability flags needed): `updates.check` + `tool_loop_guardrails.non_interactive_hard_stop_enabled` (new Advanced "Updates & Guardrails" section), `gateway.trust_env` (Advanced → Network), `display.bell_on_prompt` (Display → Feedback), `display.resume_last_session` (Display → Layout), `model.streaming` (Display → Output, labelled "Provider Request Streaming"), `delegation.independent_completions` + `delegation.compression_threshold_tokens` (Advanced → Delegation).
- **A11 (verify only, no UI)** — nothing in Scarf assumes unbounded session history. Sessions are read live from state.db on every view (`SessionsViewModel`), no session id is persisted across launches (no `@AppStorage` for one; Projects/MiniApp hold theirs in memory only), and `ChatViewModel` already handles "session not found in ACP" by creating a new one. `sessions.auto_prune` → true with 90-day retention needs no change.

## Deliberate deviations / NO-OPs
- Off writes `"normal"`, not `""` as the ticket said: `""` and `normal` are exact synonyms in `_parse_service_tier_config` on every supported host, and keeping `normal` (the value the Bool toggle already wrote) means the picker round-trips byte-identically on upgrade with zero config churn. Same rationale the ticket gave for keeping `fast` over the canonical `priority`.
- `model.streaming` default is **true**, not false — it is not in `config_defaults.py` at all; its default lives in its only reader, `agent/agent_init.py:1184`.
- `delegation.fallback_providers` and `agent.budget_warning_ratio` skipped per ticket (neither fits an existing row type).
- Sessions retention UI and Web Tools pickers untouched (out of scope).

## Tests
- New `ScarfCore/Tests/ScarfCoreTests/HermesV0211ConfigTests.swift` (25 tests): service-tier alias drift alarms (verbatim from the tagged parser), capability-gated option lists incl. unknown-host and unsupported-current-value cases, fast_auto_seconds, the two telemetry opt-ins + endpoint-host fallback, the true-by-default five (absent / explicit false / every falsy spelling), and `model.streaming` vs `display.streaming` independence.
- `scarfTests/HermesFileServiceConfigParityTests.swift` fixture extended with every new key set to its NON-default value + new `v0211KeysRoundTrip` test.
- ScarfCore `swift test`: 2306 tests pass (4 issues in `ACPClientStartIdempotenceTests` under full parallel load only — pre-existing flake, passes 5/5 in isolation with `--filter`).
- `xcodebuild test -only-testing:scarfTests`: 812 tests, 107 suites, all pass. The app test target DOES run headless on `platform=macOS`.
- macOS Debug build and the `scarf mobile` iOS-simulator build both succeed.

## Fresh-eyes audit findings (fixed before commit)
- The five true-by-default keys were originally read with `bool(key, default: true)`, which returns `false` for any present value other than the literal `"true"` — a hand-edited `no`/`off`/`0`/`False` would have rendered the toggle ON-side wrong. Replaced with a `boolTrueDefault` helper whose falsy set mirrors `model.streaming`'s own reader. Covered by a parameterized test.
- `delegation.compression_threshold_tokens` has a dead band (Hermes ignores 1…15999); the stepper steps by the 16,000 floor so it can never land there.
- `tool_loop_guardrails` is top-level, not under `agent.` — confirmed by AST-walking `DEFAULT_CONFIG` at the tag rather than reading indentation.

## Memory
Edited `scarf/decisions/hermes-v0-21-1-compatibility-decisions` (6 new observations: the `bool()` true-default trap, `model.streaming`'s reader-side default, the nine service_tier spellings, the compaction dead band, the top-level guardrails block, and the A11 verification). No new note — the existing v0.21.1 decisions note is the right home.

