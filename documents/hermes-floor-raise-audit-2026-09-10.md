# Hermes compatibility floor audit — should Scarf move to v0.20.0?

Date: 2026-09-10. Branch: fix/whole-surface-audit-r2. Source: `HermesCapabilities.swift` (1836 lines, 171 flags), swift-stats `version` property (530 installs).

## Fleet (swift-stats, installs)

| Floor candidate | Installs dropped | Share |
|---|---|---|
| < 0.18.0 (0.15.1, 0.16.0) | 9 | 1.7% |
| < 0.19.0 (+0.18.0, 0.18.2) | 26 | 4.9% |
| < 0.20.0 (+0.19.0, 0.19.1) | 51 | 9.6% |

90% of installs are on 0.20.0 or later; 0.20.x alone is 55%.

## Flags by floor (171 total)

| Floor | Flags | Cumulative below |
|---|---|---|
| 0.11–0.15 | 84 | 84 |
| 0.16–0.17 | 14 | 98 |
| 0.18–0.18.1 | 9 | 107 |
| 0.19–0.19.1 | 15 | 122 |
| 0.20.0–0.20.6 | 29 | — |
| 0.21.0–0.21.1 | 16 | — |
| windows (Tavily, web_extract, ignore_root_dm, flush_memories) | 4 | — |

Convenience predicates `isV011OrLater` … `isV0191OrLater`: 10, all deletable at a 0.20 floor.

## Usage

- 33 flags have zero production consumers (only the file itself + tests). 30 of those are pre-0.20.
- 3 predicates (`isV014OrLater`, `isV015OrLater`, `isV0203OrLater`) are used only by the Health capabilities panel.
- ~90 pre-0.20 flags are read at real UI/CLI decision points (biggest: `hasKanban` 9, `hasACPSetSessionModel` 10, `hasSessionEditAutoApproval` 8, gateway toggles 4 each). At a 0.20 floor each becomes constant `true`: delete the flag, the `if`, and the else/fallback path (e.g. piped `"y\n"` for skills uninstall pre-0.20.5 stays, since that is a 0.20.x floor).

## What a 0.20.0 floor would remove

- 122 of 171 flags (71%), 10 convenience predicates, the `hasFlushMemoriesAux` window (pre-0.12 only, dead).
- Roughly half of `HermesCapabilitiesTests.swift` (1261 lines, 111 tests): the per-release parse / all-on / prior-host-degradation groups for v0.12–v0.19.1.
- iOS `HermesVersionBanner` ("update to v0.12") — replace with a single below-floor banner.
- `README` claims (v0.6 through v0.20) and the `Hermes Version Compatibility Target` memory note (minimum v0.6.0).
- Comment-only references to the v0.6.0 minimum in `HermesConfig+YAML.swift`, `HermesConfig.swift`, `CronViewModel.swift`, `SettingsViewModel.swift`, `AdvancedTab.swift` — no logic.

## What it would NOT simplify

- **Detection machinery stays.** `parse`/`parseLine`, `SemVer`/`DateVersion`, `HermesVersionCache`, `HermesCapabilitiesStore`, the environment wiring — all still needed because the live range 0.20.0 → 0.21.1 has eight distinct floors (0.20.0/.2/.3/.4/.5/.6, 0.21.0, 0.21.1) plus three windows. The 0.20.x line is where the fleet lives AND where the patch-level fragmentation is.
- **Schema probes stay.** `messages.active` (0.16), `messages.compacted` (0.18), `_compressed_summary` (0.21) are PRAGMA/sqlite_master-detected per charter C4; a floor never lets Scarf assume a column.
- **Windows stay.** Tavily (gone only at 0.21.0), `auxiliary.web_extract` (< 0.20.6), `ignore_root_dm` (< 0.21.1) are all inside the supported range.

## Failure-mode change (design decision, not free)

Today an undetected host (`semver == nil`, `.empty`) resolves every floor flag to `false`, so a detection failure hides everything gated. Once pre-0.20 flags become unconditional, an undetected host shows those surfaces. That is probably the better default for a 90%-on-0.20 fleet, but it must be an explicit decision, and below-floor hosts need a hard "unsupported Hermes, update to 0.20" banner rather than silent degradation — charter C1's byte-identical rule no longer applies to hosts we no longer support, and that needs a charter task.

## Alternative floors

- **0.18.0** removes 98 flags (80% of the win) and drops 9 installs (1.7%). Keeps 0.18/0.19 surfaces gated (24 flags).
- **0.19.0** removes 107 flags, drops 26 installs (4.9%).
- **0.20.0** removes 122 flags, drops 51 installs (9.6%).

The flag count is heavily front-loaded (84 flags at ≤ 0.15, where only 9 installs live). Cost-per-flag is best at 0.18.

## Recommendation

Raise the floor to **0.18.0 now**, and to 0.20.0 in a later release once 0.19.x falls under ~2% (it is 4.7% today). Either way the work is a deletion pass plus one new below-floor banner, and the detection code itself does not change shape.
