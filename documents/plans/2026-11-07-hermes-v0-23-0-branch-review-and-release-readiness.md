# feat/hermes-v0230-parity — review and release readiness

Date: 2026-11-07 · Branch head reviewed: `64ce114b` · Worktree: `../Scarf-v0230` · Hermes release: `v0.23.0` = `2bd378ed1b` (2026-11-05)

## What the branch does (13 commits on top of main `82d0b473`)
- **S1 flags:** v0.22.6 and v0.23.0 clusters in `HermesCapabilities` (most v0.23 surfaces actually ship at v0.22.6 and are floored there).
- **S2 Copilot left core (breaking):** Copilot provider ids, env vars and routable entries are offered on v0.22.6+ only when the `github-copilot` plugin is present. `check-hermes-tables.py` reports these as GATED instead of FAIL.
- **S3 Camofox left core (breaking):** the Camofox provider row and section, plus the removed `record_sessions` key, are gated on v0.22.6+.
- **S4 Chat:** reasoning-effort (v0.22.6) and service-tier (v0.23.0) chips driven by ACP `configOptions`, and "Reset to default model" (`/model reset`).
- **S5 Cron:** Stop Run (`cron cancel`), a per-job "Missed runs" picker (`--catch-up`), and a `cancelled` status.
- **S6 Plugins:** "Update All…" (dry-run preview, then `--yes`), a caution-verdict `--force` sheet, and an Auto-update switch (`plugins auto-update`).
- **S7:** "Refresh running sessions" (`sessions refresh-prompts`), a skill lock (`curator lock`), and the sessions "No session '" marker fix.
- **Test harness:** the fixture warms the gateway (`gateway ensure --timeout 180`) and kills leftover fixture-home processes. The approvals block is merged into the config rather than appended.

## Fresh-eyes audit (against the v0.23.0 tag, not the dev build)
Every argv, output marker and ACP field the branch uses exists **at the tag**. The Phase 0 probing ran on `v0.23.0+209.g90d6b98.dirty`, so the audit re-checked everything at the tag; nothing was dev-build-only. Provider tables: `check-hermes-tables.py --tag v0.23.0` reports lanes=8/8. No state.db writes (C3). No new spawns on the main actor; every new subprocess has a timeout (C10).

### Fixed today (uncommitted in the worktree)
1. **Pin:** `HERMES_TARGET_TAG` was still `v0.22.5`, so release.sh would have gated against the old Hermes. It is now `v0.23.0`.
2. **Copilot "installed" ignored enablement (medium).** Hermes's loader is opt-in: it skips a plugin that isn't in `plugins.enabled` or is in `plugins.disabled` (`hermes_cli/plugins.py:1337-1349` @ v0.23.0). `plugins install` asks "Enable now? [y/N]" (`plugins_cmd_install.py:628`), so "installed but not enabled" is an ordinary state. `HermesCopilotPlugin.isInstalled` now also requires the plugin to be enabled in `config.yaml`. Tests are updated, with not-enabled and disabled cases added.
3. **Camofox, same flaw:** BrowserTab now uses `isPluginReady("camofox")`. The "hermes plugins install camofox" hint only shows when the plugin is truly absent; the note already offers Enable for the installed-but-disabled case.
4. **`ultra` service-tier alias floor (low):** `ultra` first appears at v0.22.0 (`agent/fast_mode.py:33`), while `ultrafast` exists from v0.21.6. Added `hasServiceTierUltraAlias`. The test that encoded the old behaviour is corrected.
5. **New UI tests** (none existed for the new surfaces). Each skips below its Hermes floor via the new `requireHermes(atLeast:for:)`:
   - `CronKanbanJourneyUITests.testCronMissedRunPolicyReachesJobsJSON`: Skip on create → `catch_up=false`; Edit → "Run once on return" → `true`, checked in `cron/jobs.json`.
   - `ConfigJourneyUITests.testSkillLockWritesUsageSidecar`: lock and unlock `openhue`, checked in `skills/.usage.json` (fixture only).
   - `ConfigJourneyUITests.testPluginsAutoUpdateWritesConfigAndUpdateAllPreviews`: `plugins.auto_apply` flips both ways in config.yaml; the Update All preview ends in "nothing to update" or the confirm sheet, which the test always cancels.
   - `ConfigJourneyUITests.testBrowserTabGatesLeftCoreCamofox`: with `cloud_provider: camofox` stored and no plugin, the plugin note shows and neither the Camofox section nor Record Sessions does.
   - `ChatJourneyUITests.testReasoningEffortPickerRoundTripsAndModelResetIsOffered` (Live): the reasoning chip label changes only from Hermes's reply, and the model badge offers Reset.
   - New accessibility ids: `cron.contextMenu.edit`, `plugins.autoUpdate`, `plugins.updateAll`, `plugins.updateAll.{cancel,confirm}`, `chat.config.<id>`, `chat.model.badge`, `chat.model.reset`.

### Open: decisions for Alan
- **Update All drift (low-medium).** The confirm sheet shows the preview list, but `--yes` re-plans when it runs: a plugin that gained an update in between is applied without being shown. The `--force` sheet has the same gap for a newer upstream revision. Option: apply per name (`plugins update <name>` for each previewed row) instead of `--yes`.
- **`hasSessionsNonZeroExit` / `HermesSessionsCLI.isFailure` are unused** (tested but never wired in). Either wire them into the sessions verdicts or delete them. The "No session '" marker fix itself is live.
- **`knownOffered` before any probe (low).** On a v0.22.6+ host, a Copilot 401 isn't classed as expired OAuth until Chat has probed: Cron hints before Chat opens, and always on ScarfGo iOS.
- **Not covered by UI tests:** Cron Stop Run (a run needs the scheduler tick, which the sandboxed runner can't drive), the refresh-prompts hint, Update All apply and force (they touch the network and real plugins), and the service-tier chip (it needs a fast-mode model). These are unit-tested only, so check them by hand on a real v0.23.0 host.

## How we test (release gate)
1. ScarfCore: `swift test --package-path scarf/Packages/ScarfCore`. Baseline: 79 pre-existing env-dependent failures (t-3eed315b: ProjectDoctor scans the real ~/Projects; RealPyYAML is skipped when PyYAML is absent). Compare against that baseline.
2. scarfTests on the host: `scripts/ui-gate.sh --unit-only` (serial). Two pre-existing Bot failures (t-0922ddb6).
3. UI plans in the `scarf-ui` Tart VM: `scripts/ui-gate-vm.sh --hermes-tag v0.23.0 --plans Full,Live`. It builds on the host, installs the tag in the guest, seeds the fixture, and runs the tests there. The VM must be booted headless first (release.sh does this). This is exactly what `release.sh` runs by default, reading the pin.
4. `check-hermes-tables.py --tag v0.23.0` must exit 0 (it already does).

Status 2026-11-07: the builds were started, then killed by an external SIGTERM (other agent sessions on this Mac; load average ~500). Deferred until the machine is free. Nothing has been built or run on the edited tree beyond a `swiftc -parse` syntax check (all files OK).

## Before release
1. Machine free → run steps 1–3 above on the worktree and triage against the baselines.
2. Commit the fixes on the branch: the pin + the Copilot/Camofox enablement fix + the ultra floor + the UI tests, separate commits. Managed tiers stay uncommitted (C7).
3. Decide the two open items above (Update All drift; the dead sessions helper).
4. Manual check on a real v0.23.0 host (+ one v0.22.5 host for the byte-identical check): Cron Stop, refresh-prompts, service tier, a Copilot profile with the plugin installed / enabled / disabled.
5. Memory: `decisions/hermes-v0-23-compatibility-decisions`, `architecture/hermes-v0-23-wire-verification`; set `project/hermes-version-compatibility-target` → v0.23.0.
6. Merge to main (with Alan's OK), then `scarf-release-prep`: README "Current target" line (`test_readme_hermes_target.py` is red until then, as expected), release notes, wiki compatibility page; then `./scripts/release.sh` (its gate re-runs against the pinned v0.23.0).
