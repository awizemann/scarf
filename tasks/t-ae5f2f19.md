---
id: t-ae5f2f19
title: Audit P16: capabilities/roster hygiene and small dead-code cleanups
status: done
added: 2026-09-08
---

## Description

From documents/hermes-v0.21.1-whole-surface-audit.md. Brief: documents/hermes-v0.21.1-parity-agent-brief.md.
1. HermesCapabilities.swift:646,652,658,671,680,691,698: v2026.7.30 is 0.19.1 (pyproject.toml), a numbered release; those seven surfaces exist there. Add `isV0191OrLater` and repoint; fix the doc reasoning; tests for a 0.19.1 host.
2. WebToolsBackendRoster.swift:38,51,61: prepend `""` (inherit; config_defaults.py:350-352 defaults) so a stock config doesn't render blank; :65-70 generalise "widen with selected" to every backend, not only tavily.
3. AgentTab.swift:101-109 + HermesServiceTier.swift:102-104: when the probe failed but the stored value is bounded (`auto`/`cold`), fall through to the picker path so the toggle never clobbers it; delete or wire the unreachable old-host branch.
4. HermesCapabilities.swift:751,762,797,808,833,852,858,865,900: re-pin citations past EOF of the modularised main.py (browser → subcommands/browser.py:19; _BUILTIN_SUBCOMMANDS main.py:2595; cron doctor :184, incidents :165, resume flags :146-147, --deliver :31, --reasoning-effort :72,135; is_job_runnable jobs.py:482-485; BUILTIN_PERSONALITIES personality.py:17). Fix :223 (transform_llm_output is not surfaced) and :811 (no cron --reasoning-effort path). Annotate the 32 consumer-less flags "no consumer yet". Truncate the header narrative (:8-23) to a pointer at the MARK sections. HermesTool.swift:171 reference hasPhotonPlatform.
5. HealthViewModel.swift: delete dead loadVersion/parseOutput/splitCheck/iconForSection/runHermes (:528,628,691,707,903-906) and the two doc mentions (:915,:993); add a `screen_recording_capturable` tri-state row (:296-318).
6. PluginsView.swift:33-39,229: hoist compatBanner above the isLoading/isEmpty/list branch.
7. GatewayView.swift:145-149: gate PID on isRunning && !servedByMultiplexer. GatewayViewModel.swift:93,240,311 + GatewayView.swift:72: fix `--json` claim, :6133 citation, target tag. HermesGatewayListService.swift:48-81: remove unreachable platform clauses/empty branch. PlatformsView.swift:187-188 + PlatformsViewModel.swift:142: drop dead `imessage` arms.
8. CredentialPoolsViewModel.swift:413,535-551: send `internalID` as the target when non-empty (credential_pool_admin.py:87-111 resolves id → label → index; a label "2" collides). FleetApplyExecutor.swift:382: all-script-only → `.skipped`, not `.applied`.

## Plan



## Artifacts

Shipped in commit **bd59bd9c** on `fix/whole-surface-audit` (single phase commit).

## Item 1 — `isV0191OrLater` re-floor (VERIFIED, all seven)
`git show v2026.7.30:pyproject.toml | sed -n 5p` → `version = "0.19.1"`.
Full walk: v2026.7.1=0.18.0, v2026.7.7=0.18.1, v2026.7.7.2=0.18.2,
v2026.7.20=0.19.0, **v2026.7.30=0.19.1**, v2026.8.3=0.20.0, v2026.8.13=0.20.1,
v2026.8.16=0.20.2, v2026.8.16.2=0.20.3, v2026.8.18=0.20.4, v2026.8.19=0.20.5,
v2026.8.27=0.20.6, v2026.8.31=0.21.0, v2026.9.7=0.21.1.

All seven confirmed present AT v2026.7.30 (line shown in each doc comment):
- `approvals.smart_policy` — config_defaults.py:1945 `"smart_policy": ""` (block opens :1935)
- `secrets.bitwarden.encrypted_cache` — :2792/:2793/:2794
- `secrets.command.*` — NOT in config_defaults.py on ANY tag; the source
  declares its own schema: `agent/secret_sources/command.py:416`
  `"enabled": {..., "default": False}`, `:436` `command = str(cfg.get("command") or "").strip()`;
  registered `agent/secret_sources/registry.py:179-181`. File absent at v2026.7.20, present at v2026.7.30.
- `telemetry.shared_metrics.enabled` — :2627/:2628/:2629
- `database.{journal_mode,wal_autocheckpoint,journal_size_limit}` — :16/:17/:20/:21
- `stt.language` + `stt.groq.*` — :1408 `"stt": {`, :1420 `"language": "en"`, :1432-1435
- `stt.local.{vad,...}` — :1427/:1428/:1429/:1430

Re-floored DOWN only. Nothing moved up. New `// MARK: v0.19.x re-floored flags`
group; `hasGatewayProfileRoutes` (already v0.19) folded into it. New
`HermesCapabilitiesTests` cluster in the standard four shapes: `parseV0191ReleaseLine`,
`v0191FlagsAllOnForV0191Host`, `v0190HostHidesV0191Flags`,
`v0_19_1_patchAndMinorReleasesStillEnableAllFlags`, `isV0191OrLater_emptyFalse`.
Updated `v019HostHidesV020Flags` and the two STTTTSExpansionTests boundary tests
(which asserted the old, wrong floor).

## Item 2 — roster
`""` prepended to all three rosters (`config_defaults.py:350-352` at v2026.9.7).
`pruningTavily` → `finalize`: tavily window pruned in place, then widened with
`selected` for EVERY backend, then `""` prepended. WebToolsTab passes
`optionLabel` — "Inherit (web.backend)" for the two override keys, "Automatic"
for the shared `web.backend` (nothing above it to inherit).
Tests: `inheritRowIsAlwaysOffered` (5 host generations × 3 capabilities, and
exactly one `""` even when `""` is also selected),
`unknownVersionHostWithPerplexitySelectedIsNotBlank` (replaces the old
`selectedNeverInventsABackend`, which pinned the bug).

## Item 3 — fast mode
`editorStyle(capabilities:current:)`; `.picker` when the stored value is bounded
even on a false floor. Makes `options()`'s widening branch reachable (it was dead).
Tests: `probeFailedButBoundedStoredValueRendersThePickerNotTheToggle`,
`boundedStoredValueSurvivesOnAnUndetectedHost`. C1 preserved for `off`/`always`
on `.empty` and v0.21.0 — asserted explicitly.

## Item 4 — citations + annotations
Re-pinned, each verified at v2026.9.7:
`subcommands/browser.py:10` (parser) + `:18-19` (close-profile) and
`main.py:2595` (`_BUILTIN_SUBCOMMANDS`, "browser" 16th entry);
cron `doctor` :184, `incidents` :165-167, resume `--at` :146 / `--run-now` :147,
`--deliver` :29 (edit :93), `--reasoning-effort` create :72 / edit :135;
`cron/jobs.py:482-485` `is_job_runnable` (+ `:477` `_has_pause_marker`, claim gate `:2509`);
`hermes_cli/personality.py:17` `BUILTIN_PERSONALITIES`;
`peer.py:432-434` (`_remote("run"/"status"/"stop")`, dispatch `:361`);
`--version` → `hermes_cli/_parser.py:112`, banner `banner.py:267`.

**DISPUTED (not changed, already correct):** the brief said to fix the `:6133`
citation in GatewayViewModel. `git grep -n` at v2026.9.7 confirms
`hermes_cli/gateway.py:6127` = "✓ Gateway is running (PID: …)", `:6128` =
"(Running manually…)", `:6133` = "✗ Gateway is not running", `:6114` = the
multiplexer marker. All four citations in the file are correct as written; the
tag references are `v2026.9.7` throughout except one deliberate "verified at
v2026.8.31" on a claim that was verified there.

False claims fixed: `transform_llm_output` is NOT surfaced by PluginsView
(grep: nothing in Scarf mentions it outside HermesCapabilities.swift);
`hasCronReasoningEffort` now says there is no `cron --reasoning-effort` at the
parser level, only the two subverbs.

Consumer-less flags: grepped every `has*`/`is*`/`supports*` in
HermesCapabilities.swift against the app + ScarfCore, excluding the file itself
and all tests → 34 hits, minus `isV0191OrLater` (consumed by the seven flags
above) and `hasPhotonPlatform` (given a consumer this phase) = **32**, matching
the audit. Each annotated "**No consumer yet**". `hasKanbanGoalMode` carries the
specific reason (its surface was deleted in P14, commit 7f504738).
`hasPhotonPlatform` and the `HermesToolPlatform` photon row now share
`HermesCapabilities.photonPlatformFloor`.
Header narrative (stale at v0.16) replaced by a pointer at the MARK sections
plus the floor-vs-removal-window distinction and the tag-walk rule.

## Item 5 — HealthViewModel
Deleted `loadVersion`, `parseOutput`, `splitCheck`, `iconForSection`, `runHermes`
(~150 lines) and both stale doc mentions. Added the tri-state
`screen_recording_capturable` row — modelled on the Computer Use permission card
(`nil` = could not ask → warning carrying the probe's own reason). Grounded in
`tools/computer_use/doctor.py:204-207`, where granted-but-not-capturable is a
FAIL that outranks the plain pass. Only rendered when the grant is `true`.
Four tests in HealthComputerUseSectionTests.

## Item 6 — PluginsView
`compatBanner` hoisted above the isLoading/isEmpty/list branch; the empty-roster
case (every plugin failed to load) is exactly when the banner is needed and was
exactly when it was unreachable.

## Item 7 — Gateway / Platforms
PID gated on `isRunning && !servedByMultiplexer`. Two `gateway list --json`
claims corrected (`subcommands/gateway.py:108` registers `list` with no args).
`GatewayListSnapshot.ProfileEntry.platforms` REMOVED entirely rather than left
with dead guards — the only producer always built it `[]` and there is no
`--json` to fill it from. Dead `"imessage"` arms removed from PlatformsView
(`selected` can only be a `KnownPlatforms` row, and `imessage` is not one) and
PlatformsViewModel. `KnownPlatforms.icon(for:)`'s defensive `"imessage"` arm is
left alone — it is a pure string mapper with a test.

## Item 8 — credential pools / fleet
`credentialTarget(index:internalID:)` sends the stable auth.json id when
non-empty, 1-based index otherwise; threaded through all four argv builders
(priority/refresh/reset + a new `removeArgv`) and their view call sites.
Verified `resolve_target` is id-first back to the pool's FIRST tag (v2026.4.30),
so no capability gate is needed. `auth remove <provider> <target>` are plain
positionals (`subcommands/auth.py:38-39`) so the added `--` is safe and matches
the other three.
`FleetApplyExecutor.cronFieldStatus(created:failed:scriptOnlySkipped:)` extracted
as a pure function and tested; all-script-only now `.skipped`.

## Tests
- ScarfCore: **2477 passed, 0 failed** (164 suites) + 42 in 3 suites.
- App target `scarfTests`: **910 passed, 0 failed** (118 suites).
- No flakes hit; no reruns needed.
- Build: `xcodebuild … scheme scarf` BUILD SUCCEEDED.

## Fresh-eyes audit of own diff
- `PickerRow` already renders `""` as "(none)"; supplied `optionLabel` so the
  three web rows say what "" means instead. `compatBanner` on the empty branch
  is a `@ViewBuilder` EmptyView inside a `VStack(spacing: 0)` — no phantom gap.
- Checked `setSetting` vs `unsetSetting` for the `""` rows: Hermes's own default
  for all three web keys IS a present-and-empty scalar, so `config set … ""`
  (not `unset`) is correct here, unlike `browser.cloud_provider`.
- Confirmed `internalID` is read verbatim from auth.json's `credential_pool[..].id`
  — the same field `resolve_target` compares — not a display-shortened form.
- Confirmed the PID gate and the `""` roster row are deliberate pre-target
  behaviour changes: both are audit-listed PRE bugs where the old rendering was
  wrong (a stale PID beside "not running"; a blank picker with no way back).
  Called out rather than smuggled.

## Deliberate no-ops
- The `:6133`/`:6127`/`:6114` gateway citations (see DISPUTED above).
- `KnownPlatforms.icon(for: "imessage")` kept.
- The extra P16 line items in the audit report's roll-up (audit tooltip,
  LocalSQLiteBackend flags, inliner nan) are not in this task's eight-item list
  and were left for whoever owns them.

## Memory
Edited `scarf/decisions/hermes-v0-21-1-compatibility-decisions`: corrected the
header's wrong tag map (`v2026.7.30 = 0.20.2` → 0.19.1) and appended
`## Whole-surface remediation — P16` with the full tag table and five durable
gotchas (read pyproject.toml AT the tag; not every config key is in
config_defaults.py; `gateway list` has no `--json`; `auth` target resolves
id→label→index; `.empty` means probe-failed, not old-host). No new note — none
of it was a standalone contract.

## Tasks created
None — nothing out of scope surfaced.

