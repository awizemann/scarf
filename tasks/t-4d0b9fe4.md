---
id: t-4d0b9fe4
title: Audit P31: pairing/plugins/skills verdicts and argv residue
status: done
added: 2026-09-10
priority: high
---

## Description

Round-3 whole-surface audit (`documents/hermes-v0.21.1-whole-surface-audit-round3.md`, CLI-verdict section). Needs product decisions 2 (skills update quote) and 3 (pairing presentation) from the report.

- HIGH · PRE · A refused `pairing revoke` still deletes the row: `_cmd_revoke` is `-> None`, prints `User <id> not found in approved list for <platform>.` at exit 0 (`hermes_cli/pairing.py:84-90` @ v2026.9.7); Scarf removes on `exitCode == 0` (`GatewayViewModel.swift:533-556`). Success marker `Revoked access for user <id> on <platform>.` (`:88`).
- HIGH · PRE · A refused `pairing approve` reports nothing: not-found/expired (`pairing.py:80-81`) and lockout (`:76-78`) both exit 0; Scarf posts no message (`GatewayViewModel.swift:510-531`). Success marker `Approved! User … can now use the bot~` (`:68`).
- MED · NEW(P21) · `parseUpdateReport.failureDetail` is poisoned on every real update: `do_install` prints `Warning: '<name>' is already installed at …` unconditionally before the `force` check (`skills_hub.py:680-685`, called from `:868`), and that string is in `skillsInstallFailure`, so "Update attempted — …" quotes the warning, not `Installation blocked:` · `HermesSkillsHubParser.swift:295-298`, `SkillsViewModel.swift:1005-1007`; P21 fixtures omit the line.
- LOW · PRE · Missing `--` on five argv sites whose siblings have it: `plugins update|remove|enable|disable <name>` (`PluginsViewModel.swift:334,340,366,390`), `skills update <name> --force` (`SkillsViewModel.swift:793-795`), `pairing approve|revoke` (`GatewayViewModel.swift:517,540`); positionals verified at `subcommands/plugins.py:52-85`, `subcommands/skills.py:79-83`, `subcommands/pairing.py:17-26`. Related: t-ff609789 (cron `--`).
- LOW · PRE · `HermesPluginList.swift:5-16,44-53` quotes a `_plugin_status` shape from v2026.8.31 that no longer exists (now a one-line ternary at `plugins_cmd.py:1290-1293`).
- LOW · PRE · `dashboardListenerPID` waits before draining the pipe (`HealthViewModel.swift:1193-1206`).

## Plan



## Artifacts

Shipped on `fix/whole-surface-audit-r3`:

- `45ec3777` fix(p31): judge pairing and skills-update by what Hermes printed, and end options with `--`
  - `HermesPairingVerdict.approve/revoke` (ScarfCore/Services/HermesCLIOutcome.swift) judged by the anchored success markers (`Approved! User …` pairing.py:68, `Revoked access for user …` :88), `fallbackDetail: false`.
  - Refused revoke KEEPS the row; refused approve reports. Both quote Hermes verbatim into a new dismissable sticky `pairingError` banner in GatewayView's pairing section, lockout countdown (`Lockout clears in ~N minute(s).` :77) appended verbatim (decision 3).
  - Pairing feedback no longer flips `actionMessage`/`actionFailed` (service-row state).
  - `HermesCLIMarkers.skillsUpdateFailure` = install set minus `is already installed at` and `Use --force to reinstall.` (decision 2); `parseUpdateReport` uses it.
  - `--` added to the five argv sites; `--force` before the `--` on `skills update` (argparse reads everything after `--` as positional).
  - Tests: `HermesCLIVerdictP31Tests` (14, ScarfCore), `GatewayPairingVerdictP31Tests` (5, scarfTests); two existing argv assertions updated.
- `7abf07c1` fix(p31): re-anchor the `_plugin_status` quote at v2026.9.7 and drain lsof before waiting
  - `HermesPluginList`'s `_plugin_status` AND `cmd_list` doc blocks were both paraphrases of v2026.8.31 presented as verbatim Python; now the real v2026.9.7 source (`plugins_cmd.py:1290-1293`, `:1324-1331`).
  - `dashboardListenerPID` drains the pipe on a background queue concurrently with the wait, with its own bounded EOF grace.

NO-OPs, deliberate:
- No `HermesCapabilities` flag for the pairing verdict: both markers are byte-identical at all 32 `v2026.*` tags, so no host renders differently (C1).
- No behavioural test for the lsof drain: `dashboardListenerPID` is a private static with a hardcoded `/usr/sbin/lsof` path and no injection seam; adding one would have exceeded "contained".
- `Use --force to reinstall.` left in `skillsInstallFailure` (load-bearing there) and dropped from the update set as unreachable under `force=True`.

Tests: ScarfCore 2631/2631 (ACPClientStartIdempotenceTests failed under full parallel load, green in isolation — known t-f3820038). Mac serial 1027/1027. Build green.

