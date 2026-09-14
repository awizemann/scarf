---
id: t-daf369c1
title: Audit P54: CLI verdict residue r6 — import --force, backup/webhook/curator/debug-share verdicts
status: done
added: 2026-09-12
priority: high
---

## Description

Round-6 whole-surface audit (documents/hermes-v0.21.1-whole-surface-audit-round6.md, CLI-verdicts section). Supersedes t-4edfd804 (fold it in; three of its items are corrected there). Needs round-6 product decisions 1–2.

- HIGH · PRE · `hermes import <path>` is shelled without `--force` (`SettingsViewModel.swift:1445`); `run_import` calls `_confirm_import_overwrite` → bare `input()` (`hermes_cli/backup.py:830-839,:942-943` @ v2026.9.7); the GUI child inherits `/dev/null`/EOF stdin → `EOFError` → `Aborted.` exit 1. Every restore into a live Hermes home fails with a bare "Restore failed". Fix: pass `--force` (`subcommands/import_cmd.py:17-18`; Scarf's own restore sheet is the consent) and judge on `Import complete:` (`:948`), `Warnings (N files skipped):` (`:954-955`, partial at exit 0), `⚠ Session data replaced by older backup contents:` (`:958-959`). Decision 1.
- MED · PRE · `backup` judged by exit code (`SettingsViewModel.swift:1408-1432`); `Backup incomplete: <path>` + `Warnings (N files skipped):` at exit 0 (`backup.py:666-670,:679`) renders "Backup saved". `No files to back up.` (`:632-634`) → neutral note. Fix: `HermesBackupVerdict` on `Backup complete: ` vs `Backup incomplete: `.
- MED · PRE · `webhook remove|test` exit-code judged (`WebhooksViewModel.swift:229-258`); `webhook` is `_forward_command` without `forward_return`; disabled-in-config gate prints `_setup_hint()` and returns (`webhook.py:99-101`); `No subscription named` (`:184-187,:197-198`); test's `except Exception` prints `Error:` + `Is the gateway running?` (`:213-215`) at exit 0. Fix: verdicts on `  Removed webhook subscription: ` (`:189`) and `  Response (` (`:209`).
- MED · PRE · `curator run` (`CuratorService.swift:75-79`, `CuratorViewModel.swift:279-286`): `consolidation is off — running prune-only` at return 0 (`curator.py:159-163,:186`). Fix: the pin/unpin note shape; point at `curator.consolidate` or offer `--consolidate` (`:620-623`). Decision 2.
- MED · PRE · `debug share` (`HealthViewModel.swift:774-780`): `(failed to upload: …)` after the URL block at exit 0 (`debug.py:493-494`; byte-identical @ v2026.6.19). Fix: judge on `Debug report uploaded:` (`:490`), carry the failure as a warning.
- LOW · PRE · `--` sweep residue: `profile use|show|import` (`ProfilesViewModel.swift:47,63,88,214` vs `:175`), `curator pin|unpin|restore|archive` (`CuratorService.swift:108,119,136,146`), `kanban purge` (`KanbanService.swift:519-520` vs `:428`).
- LOW · PRE · `mcp test` collapses `.unconfirmed` into a bool (`HermesFileService.swift:912`).
- LOW · PRE · unlocalized banners in `WebhooksViewModel` (`:230,:250,:257`) and `ProfilesViewModel.runAndReload`.
- LOW · PRE · iOS judged spawns get no `COLUMNS=400` (`CitadelServerTransport.swift:140-145`, `MemoryListView.swift:96`).
- LOW · PRE · `migrate xai --apply`: `⚠ No changes written.` (`migrate.py:73-75`, retired refs found but rewrite failed) rendered as "No retired xAI model to migrate." (`HealthViewModel.swift:958-984`); separate from `nothing to migrate` (`:44-46`).
- Corrections to t-4edfd804: `curator pin/unpin` already fixed (`CuratorService.swift:104-135`); `kanban specify|decompose` has no Scarf caller; `migrate xai` is output-judged (copy only).

## Plan



## Artifacts

Shipped on `fix/whole-surface-audit-r6` in three commits. **Not pushed.**

- `018194b7` — the five verdicts + `MCPTestResult.confidence` (ScarfCore) + 37 tests in 7 suites
- `acefd89a` — the call sites, the three-state rendering, the separators, the localized banners (+ the P47 sibling test followed to the argv's new home) + 37 tests in 5 suites
- `ccb1a8a4` — the iOS `COLUMNS` on both spawn sites + 2 tests in 1 suite

**Per finding.** All fixed except one, which was fixed the other way round:

| finding | outcome |
|---|---|
| HIGH `import --force` | fixed — `HermesImportVerdict`, decision 1, no stdin pipe |
| MED `backup` verdict | fixed — `HermesBackupVerdict` |
| MED `webhook remove\|test` | fixed — two verdicts + shared `HermesWebhookGate` |
| MED `curator run` prune-only | fixed — decision 2, pin/unpin note shape, no `--consolidate` |
| MED `debug share` partial | fixed — `HermesDebugShareVerdict` |
| LOW `--` residue | fixed for `profile use\|show\|import` and all four `curator` skill verbs; **`kanban purge` deliberately NOT fixed** — see below |
| LOW `mcp test` bool collapse | fixed — `confidence` carried, both views render three states |
| LOW unlocalized banners | fixed in Webhooks and Profiles; `messageIsError` set on the `runAndReload` path, which it never was |
| LOW iOS `COLUMNS` | fixed on both named sites |
| LOW `migrate xai` `No changes written` | fixed — `HealthViewModel.migrateXAISummary` |

**Corrections to the task and the round-6 report.**

1. `curator pin/unpin` were NOT already `--`-separated (nor `restore`/`archive`); all four fixed.
2. **`kanban purge` must not take `--`.** `archive` carries both `task_ids` (`nargs="*"`) and `--rm`/`purge_ids` (`nargs="+"`) — `kanban_parser.py:335-338` @ `v2026.9.7` — so `archive --rm -- a b` hands the ids to the positional and leaves the destructive flag empty: exit 2, or a **silent archive where the user asked for a permanent delete**. Documented and pinned by a test asserting the absence.
3. The `import` finding understated itself: the verb was unreachable on every live home, not mis-judged.

**Fresh-eyes audit of my own diff** (adversarial pass, 8 findings, 5 real and fixed before commit):

- **Real, MED-HIGH:** all five new summary helpers gated `.unconfirmed` on `confidence == .unconfirmed && detail.isEmpty`, but `judge` fills `detail` with `lines.last` on every arm — so a run printing only `Scanning ~/.hermes ...` rendered "Backup failed: Scanning ~/.hermes ...". Every unconfirmed fixture in my suite was the empty string, so it passed its own three-branch tests. Guard keys on confidence alone now; a six-test suite feeds exit 0 WITH output, and it was watched failing against the reverted guard.
- **Real, MED:** `Response (500)` is unreachable — `urllib.request`'s `HTTPErrorProcessor` raises for any non-2xx. I had fabricated a fixture in an enum whose header promises verbatim transcription, and built the whole `detail`-on-success rationale on it. Fixture and rationale replaced with the real `except` arm.
- **Real, MED:** `runBackup`'s doc claimed the Finder reveal is gated on a confirmed-complete backup; it is not, deliberately. Comment corrected to say what the code does and why.
- **Real, LOW-MED:** eight wrong `file:line` citations inside `v2026.9.7` (the four-tag walks themselves checked out). All re-opened with `awk NR==` and corrected.
- **Real, LOW:** a dead `local` arm in `debugShareSummary`, and a `prefix(600)` window in the purge test that a longer body could slide out of. Both fixed.
- Filed rather than fixed (out of scope): `t-fc4d3a6f` (webhook subscribe/list on the same gate), `t-62dee8aa` (`deleteServer`'s two-way if on a pre-existing verdict).

**Tests.** ScarfCore 3165/259 (main runs 3128/252); ScarfIOS 60/12; Mac full serial `-only-testing:scarfTests` **1374 in 200 suites, 0 failures**, twice. `scarf` Debug and `scarf mobile` build clean. Two ScarfCore wall-clock tests flake under full-suite load — **reproduced on a `main` worktree in 3 of 5 runs**, filed as `t-46f089cf`.

**Memory.** Edited `architecture/judging-a-hermes-verb-by-its-output-the-exit-0-refusal` (round-6 section: the unreachable-verb tell, the `.unconfirmed` gating invariant, the `urllib` lesson, the `--` exception, the detail-on-success convention) and `architecture/columns-400-rides-the-judged-spawns-only-rich-wraps-at-80` (the third spawn family and the twin that stays without). No new note — both durable contracts belonged in existing ones. Full write-up in `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md` § "Whole-surface remediation — P54".

Supersedes `t-4edfd804`, moved to done with its own disposition note.

