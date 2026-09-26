---
title: Hermes gateway multiplex-by-default and parked profiles (v0.21.4 / v0.21.5)
type: note
permalink: scarf/architecture/hermes-gateway-multiplex-by-default-and-parked-profiles-v0
tags: [hermes, gateway, v0.21.5]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesProfileRoutes.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift, scarf/scarf/Features/Gateway/ViewModels/GatewayViewModel.swift, scarf/scarf/Features/Settings/Views/Components/ProfileRoutesSection.swift]
source_paths_inferred: false
source_sha: a06dc2054fd23e1601c621f9a42ca9d37f7bf3dd
created: 2026-09-26
updated: 2026-09-26
---

Source-verified at v2026.9.21 / v2026.9.24 (hermes_cli/gateway_multiplex_mode.py, gateway_profile_lifecycle.py, profiles.py). Scarf reads these through HermesProfileRoutes.multiplexStatus(capabilities:), HermesGatewayParkedStatus and HermesGatewayServiceVerdict's profile-lifecycle arm.

## Observations
- [fact] From v0.21.4 an unset OR explicit-false gateway.multiplex_profiles means multiplex by default, but only if implicit_multiplex_blocker finds nothing (single profile, s6 host, a profile still running its own gateway, duplicate bot token); explicit true skips that check, so never offer 'Enable' as a harmless button #hermes #gateway
- [fact] v0.21.5 persist_resolved_default rewrites a retired false to true in the DEFAULT profile's config.yaml (never on a guard refusal) and drops .multiplex_opt_out_rewritten; gateway.standalone: true (named profiles only, gateway: section only) keeps a profile out of the host gateway #hermes #gateway
- [gotcha] v0.21.5 gateway status on a parked named profile prints ONLY 'Profile '<n>': parked (hermes -p <n> gateway start)' with no check/cross; the default profile prints the same line shape for satellites and then continues, so only a whole-output parked line means THIS profile is parked #hermes #gateway
- [fact] v0.21.5 start/stop/restart on a host-served named profile print unglyphed exit-0 lines ('served by the host gateway.', 'parked; its bots and cron are stopped.', 'restarted by the host gateway.') plus '...was not confirmed: <reason>' arms, which Scarf judges .unconfirmed (C5) #hermes #gateway
- [fact] The parked marker is <HERMES_HOME>/gateway.parked (profiles.parked_marker_path); gateway.auto_migrate was renamed auto_multiplex_migration at v0.21.4 and Scarf never referenced either #hermes #gateway

## Relations
- relates_to [[Hermes v0.21.1 Compatibility Decisions]]
- relates_to [[Judging a Hermes verb by its output: the exit-0 refusal FAMILY and the anchored-prefix rule]]



## P7e — allowlist window, and the v0.21.5 boxed STANDALONE warning

- [gotcha] **`gateway.multiplex_profile_allowlist` is a WINDOW, not the audit's guessed `≥0.20.4` floor.** `gateway/config.py`'s `_normalize_multiplex_profile_allowlist` (plus the `profiles.py`/`gateway.py` readers) all land together in commit `c8f235a106`, first tagged at `v2026.8.13` (`0.20.1`) — `git tag --contains` that commit lists no earlier numbered tag. Migration 43 (`hermes_cli/config_migrations.py:640-649` @ `v2026.9.14`) deletes the key on load, and `git grep multiplex_profile_allowlist v2026.9.14 -- 'gateway/*.py' hermes_cli/gateway.py hermes_cli/profiles.py` is empty — every reader is gone in that SAME release, whose `pyproject.toml` reads `0.21.3`. So the key is live for `0.20.1 – 0.21.2` only (`HermesCapabilities.hasMultiplexProfileAllowlist`); `SettingsViewModel.multiplexProfileAllowlistWarning` must stay silent outside that window even when a stale config.yaml still carries the key. #hermes #gateway #capability-gating
- [fact] **v0.21.5's `gateway status` prints a BOXED "this gateway is STANDALONE" warning that v0.21.4 does not** — `standalone_warning_lines`/`recorded_standalone_warning_lines` (`hermes_cli/gateway_multiplex_mode.py:299-335` @ `v2026.9.24`), hooked into `_cmd_status` at `hermes_cli/gateway.py:5051,5059`. At `v2026.9.21` the SAME boot guard instead prints one unboxed line — `⚠ Serving the default profile only: {reason}` (`hermes_cli/gateway.py:1542-1548` @ that tag) — with no unserved-profile list and no fix command. `HermesGatewayStandaloneWarning.parse` (new, `Parsing/HermesGatewayStandaloneWarning.swift`) only reads the box, gated on `hasGatewayStandaloneStatusBox` (`isV0215OrLater`); it does not read the v0.21.4 one-liner. Box fields: unserved profiles (`Profiles NOT served (their bots stay silent): …`), the boot guard's reason (`Why: …`), and the literal fix (`Fix: hermes gateway migrate --multiplex`, `MIGRATE_COMMAND` at `hermes_cli/gateway_migrate.py:38`). Surfaced in `GatewayView`'s standalone banner (fix command shown as selectable text, never a button — it's a real topology mutation). #hermes #gateway #capability-gating
