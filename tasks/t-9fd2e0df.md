---
id: t-9fd2e0df
title: Audit P23: Capability floors and gates
status: done
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

Commit `7644b37d` on `fix/whole-surface-audit-r2` (one logical unit: every finding is the same layer). All 13 findings verified against the tagged Hermes source first; **all 13 were real**, no NO-OPs.

Tag map re-derived from `pyproject.toml` at all 32 `v2026.*` tags before any floor was touched (line 5 only holds `version` from v2026.6.5 on, so the walk greps `^version` — noted for the next phase).

**Fixed**

1. HIGH `hasCompressCommand` INVERTED → flag deleted, `RichChatViewModel` hardcodes `compress`. `CommandDef("compress", …)` canonical at `hermes_cli/commands.py:57` @v2026.3.17 (0.3.0); `aliases=("compact",)` first at `:92` @v2026.7.7 (0.18.1); `/compact` @v2026.4.30 is `tui_gateway/server.py:3845` `_TUI_EXTRA` "Toggle compact display mode". Floor below the v0.6.0 minimum ⇒ no gate (P15 rule). Hazard noted in the doc comment.
2. `hasCronRuns` → `isV019OrLater`. `subcommands/cron.py:159` @v2026.7.20 (0.19.0); `cron_runs` in no file @v2026.7.7.2.
3. `hasCuratorAdopt` → `isV0191OrLater`. `curator.py:344` `_cmd_adopt` + `:748` `list-unmanaged` @v2026.7.30 (0.19.1); absent @v2026.7.20.
4. `hasApprovalsSuggest` → `isV0191OrLater`. `hermes_cli/approvals_suggest.py` exists @v2026.7.30, absent @v2026.7.20 (`git ls-tree`).
5. `hasSessionsExportFormats` → `isV0181OrLater`. `main.py:13546` `choices=["jsonl","md","qmd","html","trace"]` @v2026.7.7 (0.18.1); `qmd` nowhere under `hermes_cli/` @v2026.7.1.
6. `hasSessionsRename` → flag and `ChatSessionListPane` gate REMOVED. `add_parser("rename", …)` at `main.py:2373` @v2026.3.12 (0.2.0), present at all 32 tags. Test pins the consumer as capability-free.
7. `hasBuiltinPersonalitiesInCode` → new `isV0201OrLater`. `hermes_cli/personality.py` exists @v2026.8.13 (0.20.1), absent @v2026.8.3.
8. Five flags → `isV0203OrLater`: `hasCuratorLedger` (`curator.py:996`), `hasCuratorPurge` (`:1011`), `hasCuratorEntryRollback` (`:972`), `hasSkillsProjectTrust` (`subcommands/skills.py:22,33`), `hasSkillsUpdateForce` (`:164`) — all @v2026.8.16.2 (0.20.3), all absent @v2026.8.16 (0.20.2).
9. `parseLine` fails closed: `guard (0...9).contains(semverParts[0])` → `.empty` (decision 7). Tests for the date-only shape, a two-digit major, and every legitimate shape still parsing (incl. `v1.0.0`, `v9.300.4000` — the bound is on the MAJOR only).
10. `hasWebToolsBackendSplit` widen-for-current: new `WebToolsBackendRoster.editorStyle(_:searchBackend:extractBackend:)` mirroring `HermesServiceTier.editorStyle`; `WebToolsTab.split` routes through it.
11. Roster gating (decision 6) — **gated**: `whatsapp_cloud` 0.17, `buzz` 0.19.1, `ntfy` 0.15, `line`/`simplex` 0.14, `google_chat` 0.13, `teams`/`yuanbao` 0.12 (every row added in a parity cycle with a known floor; floors walked with `git ls-tree -r` over `gateway/platforms/<n>.py` + `plugins/platforms/<n>/` at all 32 tags). **Left ungated**: `bluebubbles` (pre-dates this cycle, shipped as `imessage`, no parity-cycle floor attribution — the standing exception) and the original core roster `cli`…`mattermost` (every adapter predates v0.6.0). Each floor is a shared `static let …PlatformFloor` so row and flag cannot drift. Also added `HermesToolPlatform.isVisible(on:isConfigured:)` — a CONFIGURED platform stays listed below its floor, so gating eight pre-existing rows cannot hide a user's own setup behind a failed probe; `PlatformsView` uses it and its now-redundant `google_chat` special case is gone.
12. `hasCronPauseMarkerGate` → `isV0201OrLater` (`cron/jobs.py:482` `_has_pause_marker` @v2026.8.13, absent @v2026.8.3) + the required **No consumer yet** note (confirmed: `HermesCronJob.withEnabled` clears the markers unconditionally).
13. LOW `buzz` "v0.20 additions" comment corrected to v0.19.1 (unavoidable — the row now carries that floor; P26 can drop the item).

Plus: nine consumer doc comments that said "v0.20+ / pre-0.20" for surfaces now floored at 0.18.1–0.19.1 (`CronView`, `CronViewModel`, `CuratorView`, `SecurityTab`, `SettingsViewModel`, `SessionsView`, `SessionsViewModel`), and `sessionRequiredCommandNames`' stale `hasCompressCommand` reference.

**Tests** — ScarfCore 2574 tests / 170 suites. New: `HermesP23RosterAndGateTests` (10 tests) + 12 in `HermesCapabilitiesTests`; updated `HermesV020ParityWaveC3Tests`, `M0dViewModelsTests`, `M9SlashCommandTests`, `SlashMenuLogicTests`, `HermesCapabilitiesTests`. Every floor test asserts floor-ON and floor-minus-one-OFF, so reverting a floor fails it. Only failures in the full run are the 4 known-flaky `ACPClientStartIdempotenceTests` (green in isolation; untouched by this phase). `xcodebuild` Debug build SUCCEEDED; `scarfTests/SessionExportRemoteDestinationTests` SUCCEEDED; `scripts/check-hermes-tables.py` exits OK (unchanged, its hardening is P27's).

**Fresh-eyes findings, resolved in-commit**: (a) gating eight long-visible rows could hide a configured platform on a failed probe → `isVisible` hatch + test; (b) `PlatformsView`'s `google_chat` special case became a second route to the same floor → removed; (c) `sessionRequiredCommandNames` doc still cited the deleted flag → rewritten (the `compact` member is correct and stays: a 0.18.1+ host advertises the alias over ACP); (d) `M0dViewModelsTests`' `supportsCompress == false` flipped — verified the compress BUTTON is still hidden because `showCompressButton` also needs `!hasBroaderCommandMenu`, which the multi-entry fallback list never satisfies.

**Task created**: `t-e92d3372` — `ToolsViewModel.loadPlatforms` (`ToolsViewModel.swift:115`) sets `availablePlatforms = KnownPlatforms.all` unfiltered, so the Tools tab now disagrees with `PlatformsView` about which channels a host has.

**Memory**: appended `## Whole-surface remediation — P23` to `scarf/decisions/hermes-v0-21-1-compatibility-decisions`.

