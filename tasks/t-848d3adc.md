---
id: t-848d3adc
title: Fleet cron-copy: faithfully copy no_agent/pre_run_script jobs (replicate the script file to the target)
status: ideas
added: 2026-06-28
priority: low
---

## Description

**RECOMMENDATION (assessed 2026-06-28): DEFER indefinitely — build only on demand.** Niche: only helps users who keep script-only watchdog (`no_agent`) cron jobs in a project AND want them fleet-replicated — a narrow intersection. The current behavior (skip + surface "N script-only skipped", shipped in t-69ccb849) is honest and safe — no broken no-ops. A faithful copy requires cross-transport script-FILE replication (read source `pre_run_script` → write to target, path-rewritten, dir-created) — real work for a rare pattern. Don't build unless a user actually hits the wall.

---

Surfaced by the t-69ccb849 fresh-eyes audit (2026-06-28). FleetApplyExecutor.applyCron now SKIPS `no_agent` (script-only watchdog) `[proj:]` cron jobs with a surfaced "N script-only skipped" message — because a faithful copy needs the pre-run script FILE replicated to the target, which fleet-apply doesn't do. Before this, such jobs were silently created as empty-prompt no-ops reported as "created". (Verified: `HermesCronJob.preRunScript` is a host-local script PATH — CronView "Script path" field, "Python script whose stdout is injected".)

To faithfully copy a no_agent job: (1) read the source `pre_run_script` file via the source transport, (2) write it to an equivalent path on the target transport (path-rewritten source→target root, dir-created), (3) forward `--script <rewritten path>` + `--no-agent` (gated on target caps.hasCronNoAgent v0.13+; pre-v0.13 target can't run no-agent → keep skipping). Also covers the lesser case: an AGENT job that ALSO carries a pre_run_script is currently copied WITHOUT the script (degraded-but-functional, keeps its prompt) — same script-replication mechanism would restore it. Scope this as a deliberate "replicate cron script assets across the fleet" feature, not a one-liner. Pairs with t-69ccb849.

## Plan



## Artifacts

**P50 (2026-09-12) narrowed but did not close this.** Round-5 decision 12 shipped the *lesser case* named in the description — an AGENT job that also carries a `pre_run_script` — as a **surfaced downgrade**, not a silent loss: `HermesCronJob.hasPreRunScript` + a caveat in `FleetApplyViewModel`'s apply preview and a count on `FleetApplyExecutor`'s success arm ("N w/o their pre-run script"). Commit `39b888d1` on `fix/whole-surface-audit-r5`.

What P50 established while deciding, which sharpens this ticket:

- **There is no `--pre-run-script` flag; the setter is `cron create --script`** (`hermes_cli/subcommands/cron.py:41-46` @ `v2026.9.7`), mapped onto the record's `script` key by `_JOB_ARG_FIELDS` (`hermes_cli/cron.py:540`). So the argv half of this feature is a one-liner — the flag exists and is accepted on create.
- **And `cron create` validates nothing**: the only existence check on the path is `cron doctor`'s `_script_health_issue` (`hermes_cli/cron.py:453-465`), run on demand, which resolves against `HERMES_HOME/scripts` and reports `script not found` / `script resolves outside HERMES_HOME/scripts`. A forwarded `--script` therefore lands a green "created" job that injects nothing, and the user finds out days later. That is the whole reason this ticket is file replication and not a flag.
- So the remaining work is exactly steps (1) and (2) of the description — read the source `script` through the source transport, write it under the TARGET's `~/.hermes/scripts/` (`_scripts_dir_for_cron` is `CRON_DIR.parent / "scripts"`, `hermes_cli/cron.py:447-450`), dir-created — plus forwarding `--script` (and `--no-agent` for the `no_agent` case, still gated on `caps.hasCronNoAgent`).

Recommendation is unchanged: **DEFER**. The honest-note behaviour now covers both shapes (script-only jobs are declined and counted; scripted agent jobs are copied and counted), so nothing is silent any more.

