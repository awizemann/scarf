---
id: t-9fd2e0df
title: Audit P23: Capability floors and gates
status: todo
added: 2026-09-09
priority: high
---

## Description

Round-2 whole-surface audit phase P23. Source: `documents/hermes-v0.21.1-whole-surface-audit-round2.md`; brief: `documents/hermes-v0.21.1-parity-agent-brief.md`. Opus agent, tests that fail without the fix, fresh-eyes review, memory note. See product decisions 6 (whatsapp_cloud gating) and 7 (parser degrade direction) in the report before scoping those two items.

The `isV020OrLater` cluster was never walked; P16 fixed only the seven flags it attributed to the v2026.7.30 misread. All flag paths are `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift`.

- HIGH · `hasCompressCommand` is INVERTED: `CommandDef("compress", …)` is canonical from v2026.3.17 (0.3.0) and `aliases=("compact",)` only appears at v2026.7.7 (0.18.1), so on every 0.12–0.18.0 host Scarf labels and sends `/compact` — which at v2026.4.30 is the TUI's "Toggle compact display mode", not a compression command · `scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift:738`, flag `:730` · `hermes_cli/commands.py`; `tui_gateway/server.py:3846`
- MED · `hasCronRuns` floors v0.20; `cron_runs` first ships v2026.7.20 = 0.19.0 · `:740` · consumer `scarf/scarf/Features/Cron/Views/CronView.swift:52`
- MED · `hasCuratorAdopt` floors v0.20; `curator adopt`/`list-unmanaged` first ship v2026.7.30 = 0.19.1 · `:735` · `hermes_cli/curator.py:344` · consumer `CuratorView.swift:41`
- MED · `hasApprovalsSuggest` floors v0.20; `hermes_cli/approvals_suggest.py` first ships v2026.7.30 = 0.19.1 · `:737` · consumer `SecurityTab.swift:13`
- MED · `hasSessionsExportFormats` floors v0.20; `sessions export --format` with those five choices first ships v2026.7.7 = 0.18.1 · `:744` · `main.py:13546` · consumer `SessionsView.swift:33`
- MED · `hasSessionsRename` floors v0.16; `sessions rename` exists at EVERY tag back to v2026.3.12 — the item is hidden on all 0.12–0.15 hosts · `:595`
- MED · `hasBuiltinPersonalitiesInCode` floors v0.20.4; `hermes_cli/personality.py` first exists v2026.8.13 = 0.20.1 · `:917` · consumers `SettingsView.swift:112`, `PersonalitiesView.swift:31`
- MED · Five 0.20.4-floored flags land at v2026.8.16.2 = 0.20.3 (absent at v2026.8.16): `hasCuratorLedger`, `hasCuratorPurge`, `hasCuratorEntryRollback`, `hasSkillsProjectTrust`, `hasSkillsUpdateForce` · `:921,925,929,933,938`
- MED · `parseLine` has no sanity bound on the major component: `Hermes Agent v2026.9.7` parses as `SemVer(2026,9,7)` and lights EVERY floor including write/argv gates — an unrecognised version degrades UNSAFELY · `:1583-1601`
- MED · `hasWebToolsBackendSplit == false` renders the combined `web.backend` picker with no widen-for-current escape hatch (unlike `HermesServiceTier.editorStyle`), so an undetected host with `web.search_backend` set shows "Automatic" and any pick silently does nothing · `scarf/scarf/Features/Settings/Views/Tabs/WebToolsTab.swift:15-17,94-102`
- MED · Roster gating inconsistent at the same floor: `photon` carries `photonPlatformFloor` (0.17), `whatsapp_cloud` (same v0.17 adapter) is ungated · `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesTool.swift:119` vs `:173`
- LOW · `hasCronPauseMarkerGate` is the only no-consumer flag missing the required "**No consumer yet**" note, and its "(v0.20.4+)" claim is wrong — `_has_pause_marker` first ships v2026.8.13 = 0.20.1 · `:899-909`

## Plan



## Artifacts



