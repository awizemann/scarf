---
id: t-4edfd804
title: Round-6 exit-0 family: webhook remove/test, backup, import, migrate xai, curator
status: done
added: 2026-09-12
---

## Description

Found in P47 (`t-a498595f`) while doing the addendum's lesson-2 sweep — grepping every `runHermesCLI(` / `runHermes(` caller across `scarf/scarf`, `scarf/Packages/ScarfCore/Sources` and `scarf/Scarf iOS` and judging each verb on its tagged output. These are the sites that survived the sweep as still exit-code-judged over a verb with a real exit-0 refusal arm. All citations at `v2026.9.7`, all re-opened.

## The structural reason there are so many

`_forward_command()` only surfaces a handler's return code when `forward_return=True` (`hermes_cli/main.py:1755-1772`, `return result if forward_return else None`; the dispatcher raises it at `main.py:3399`). Only `cron`, `kanban` and `project` pass it (`main.py:1779`, `:1781`, `:1783`). **`status`, `webhook`, `doctor`, `dump`, `import`, `mcp` all have their handler's return value DISCARDED**, so those verbs exit 0 unless the callee itself calls `sys.exit` / `raise SystemExit`. `curator` and `profile` are wired with `set_defaults(func=…)` directly, so their ints do propagate. This is the general answer to "why is this verb exit 0", and it should be checked before assuming a verb's return value means anything.

## Sites to fix (Scarf file:line, then the Hermes arm)

1. **`webhook remove`** — `WebhooksViewModel.remove` → `runAndReload` (`scarf/scarf/Features/Webhooks/ViewModels/WebhooksViewModel.swift:229`, judged at `:257`). Arms: `webhook_command`'s disabled-in-config gate prints `_setup_hint()` and bare-`return`s for EVERY subcommand (`hermes_cli/webhook.py:100-101`), and `remove` prints `  No subscription named '{name}'.` / `  Note: Static routes from config.yaml cannot be removed here.` (`:188-190`). Both exit 0; the pane says "Removed".
2. **`webhook test`** — same file, `:240-250`. Arms: the same global gate (`webhook.py:100-101`), `  No subscription named '{name}'.` (`:201-202`), and a caught `except Exception as e: print(f"  Error: {e}")` + `Is the gateway running?` (`:217-219`) — a POST that failed outright still reports "Test fired — check logs".
3. **`backup`** — `SettingsViewModel.runBackup` (`scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:1408`). Arms: `_run_backup_locked` prints `No files to back up.` and returns with no archive (`hermes_cli/backup.py:632-634`); `run_quick_backup`'s `No state files found to snapshot.` (`:1513-1521`); and `Backup incomplete: …` + `Warnings (N files skipped):` (`:666-670`, `:679`) all at exit 0. Note `extractZipPath` already gives a partial signal — a run with no zip path is one of these arms — so the fix may be as small as making that the verdict.
4. **`import <path>`** — `SettingsViewModel.runRestore` (`:1445`). Arm: `if not args.force and not _confirm_import_overwrite(hermes_root): return` (`backup.py:942-943`) with `_confirm_import_overwrite` printing `Aborted.` (`:842`) — nothing restored, exit 0, and Scarf says "Restore complete — restart Scarf". Partial restores print `Warnings (N files skipped)` (`:954-955`) at exit 0 too. Inconsistency worth citing in the fix: declining by typing `n` exits 0 while the EOF/Ctrl-C branch exits 1 (`:838-839`).
5. **`migrate xai --apply`** — `HealthViewModel.migrateXAI` (`scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift:920`). Arm: `if not result.config_changed: print("  ⚠ No changes written."); return 0` (`hermes_cli/migrate.py:73-75`) — reached only when `issues` is non-empty (`:43`), i.e. retired-model references WERE found and `--apply` WAS requested and nothing was rewritten. Real failures do exit 1 (`:65-66`, `:70-71`).
6. **`curator run` / `pin` / `unpin`** — `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/CuratorService.swift:77` (`run`), `:108` (`pin`), `:119` (`unpin`). Arms: `_cmd_run` prints `curator: consolidation is off — running prune-only …` and still `return 0` (`hermes_cli/curator.py:160-163`, `:186`) — the LLM half of the verb silently did not happen; `_set_pin` prints `pinned '{skill}' (recorded; this skill is unmanaged — auto-transitions never consider it …)` and `return 0` (`:230-231`, message at `:201-211`) — the pin is written but inert. Both are "success with a neutral note" candidates rather than failures.
7. **`kanban specify|decompose --all`** — `KanbanService`. `return 0 if (ok_count > 0 or not ids) else 1` (`hermes_cli/kanban.py:1200`): a PARTIAL failure and the empty-candidate case (`No triage tasks…`, `:1179-1180`) both exit 0. The core kanban mutators are sound — `_err` / `_ok_or_err` / `_bulk_apply` all return ≥1 (`kanban_output.py:56-58`, `:61-64`, `kanban.py:253-258`).

## Verified sound in the same sweep (do not re-check)

`cron run` (already output-judged through `CronViewModel.runOutcome` with `failureWins`), `cron incidents ack` (`ackOutcomeMessage` reads the `not found or already closed` marker), `webhook subscribe` (judged on the `Secret:` line), `cron remove`, `cron pause`, `cron tick`, `profile use` (`_die` → `sys.exit(1)`), the kanban core mutators. Read-only, exit code sufficient: `mcp catalog`, `proxy providers`, `secrets bitwarden status`, `dump`, `status`, `doctor` — though `doctor` always exits 0 even with findings (`hermes_cli/doctor.py:150-156`), and `--fix` reports `Fixed N … M require manual intervention.` at exit 0 (`:143-149`), which matters the day a Scarf surface keys on it.

Follows the same shape as P39/P40/P47: a named verdict type in `HermesCLIOutcome.swift` per verb, anchored markers, `failureWins` where a refusal and a success line can arrive in the same run, and a "nothing to do" arm rendered as a success with a neutral note where that is the honest answer.

## Plan



## Artifacts

**Superseded by P54 (`t-daf369c1`) and closed there.** Every item in this ticket was folded into that phase and shipped on `fix/whole-surface-audit-r6` in commits `018194b7`, `acefd89a`, `ccb1a8a4`.

Disposition of the seven items this ticket listed:

- `webhook remove` / `webhook test` — fixed. `HermesWebhookRemoveVerdict` / `HermesWebhookTestVerdict`, plus the shared `HermesWebhookGate` for the disabled-platform arm that returns before the handler dispatches.
- `backup` — fixed. `HermesBackupVerdict`: `Backup incomplete:` is a partial success carrying Hermes's own `Warnings (N files skipped):` line; `No files to back up.` is the house neutral note.
- `import <path>` — fixed, and it was worse than this ticket recorded: the verb was UNREACHABLE, not merely mis-judged. Without `--force`, `_confirm_import_overwrite`'s bare `input()` on a closed stdin made **every** restore into a live Hermes home exit 1. Round-6 decision 1.
- `migrate xai --apply` — **corrected**: the verb is already output-judged, so this was copy only. The copy was still wrong on one arm — `⚠ No changes written.` (`migrate.py:74`) rendered as "No retired xAI model to migrate.", the opposite of what happened. Fixed via `HealthViewModel.migrateXAISummary`.
- `curator run` — fixed, round-6 decision 2 (prune-only note beside the success, no `--consolidate` on Run Now).
- `curator pin|unpin` — **correction to this ticket's own correction**: they were NOT already `--`-separated. Neither were `restore`/`archive`. All four take the shared `_SKILL` positional (`curator.py:595`) and all four have the separator now.
- `kanban specify|decompose --all` partial-failure exit 0 — **no Scarf caller**, confirmed. Nothing to fix.

One item this ticket did not have and P54 added a correction for: `kanban purge` must NOT take a `--` (the report listed it as residue). `archive` carries both `task_ids` (`nargs="*"`) and `--rm` (`nargs="+"`), so a separator strips the destructive flag — exit 2, or a silent archive where the user asked for a delete. The absence is pinned by a test.

Full write-up: `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md`, section "Whole-surface remediation — P54".

