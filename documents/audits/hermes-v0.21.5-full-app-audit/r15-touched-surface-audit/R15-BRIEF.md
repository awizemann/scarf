# R15 touched-surface re-audit — section auditor brief

You are one of 15 read-only auditors. Each owns one section of Scarf (a native macOS/iOS client for the
Hermes AI agent). Goal: confirm that the PRIMARY functionality of your section works against the current
Hermes release, and report only real, source-proven defects. "Everything works" is a valid, expected,
and welcome answer. Do NOT invent issues or exotic edge cases to have something to report.

## Why this audit exists
Past audits were release-diff-scoped (what changed between two Hermes tags) or file-scoped (files a branch
touched). Features nobody touched recently were never re-read end to end against current Hermes, and
bugs that existed for months surfaced during later upgrades. Typical classes found before: Hermes exits 0 on
failure and Scarf reports success; Hermes output shape no longer matches Scarf's parser; a config key Scarf
writes is no longer read (or read at a different path); a CLI flag/verb that doesn't exist; a remote (SSH)
path that differs from local.

## Ground truth
- Hermes source: `~/.hermes/hermes-agent-v0215` — a detached worktree at tag `v2026.9.24` (semver 0.21.5).
  This is THE reference. Do NOT read `~/.hermes/hermes-agent` (its working tree is on main, ahead of the tag).
  Cite every Hermes claim as `path/file.py:line` in that worktree. Release notes are not evidence.
- Code under audit: the integration worktree `/Users/awizemann/Developer/Scarf-wt/integration` (branch fix/hermes-v0215-audit, ALL remediation merged). Cite `path:line` there. Memory/wiki/documents: read from the MAIN checkout `/Users/awizemann/Developer/Scarf`.
- Context: this code just went through a 72-finding remediation (report: MAIN documents/audits/hermes-v0.21.5-full-app-audit.md; per-phase evidence under that folder incl. r14-remediation-audit/). Your job is NOT to re-check those fixes one by one — it is to audit the WHOLE current content of every file in your manifest (not just the diff lines) for real defects, new or old, including ones the remediation introduced or left. Treat already-known accepted limits recorded in the remediation evidence/memory as TRACKED.
- Installed binary `hermes` is 0.21.5. You MAY run only: `hermes --version`, `hermes --help`,
  `hermes <verb> [<sub>] --help`. Never run a bare/unknown verb (routes to the agent), never anything that
  mutates, downloads, logs in, or starts chat/gateway/cron. Never read or print secrets (.env, auth.json values).
- READ-ONLY: no edits to the repo, no builds, no git commands that change state, no Memophant writes.
- Project charter rules relevant to judging: Scarf never writes state.db (reads only; mutations via CLI/ACP);
  schema is detected by PRAGMA/sqlite_master, not SCHEMA_VERSION; every hermes argv must match the tagged
  argparse and unknown-verb/failure output must never be parsed as success; Export lands on the user's Mac;
  no subprocess/SSH/state.db work on the main actor, every subprocess has a timeout.

## Scope
IN: current Hermes (0.21.5) only; local AND remote (SSH) hosts; default and non-default profiles where the
feature supports profiles; iOS counterparts of your section's files (listed in your manifest).
OUT: degradation on older Hermes versions (v0.6–v0.21.4) — do not audit capability-gate floors; code style,
refactors, naming; rare edge cases requiring unusual config; performance unless it blocks the main actor on a
primary path; localization.

## Method
1. Read your section manifest (file list). It lists every file in your section that touches Hermes. Follow
   imports/callers beyond it as needed. A line range on HermesFileService.swift means you own that range.
2. Name the section's primary user journeys (typically 5–10; what a normal user does most). For each, trace:
   UI action → view model → service → exact argv / SQL / ACP message / config key / file path →
   the Hermes code that handles it (file:line at the tag) → what Hermes actually returns/prints/writes
   (including failure paths: bare `return`, `return None`, sys.exit codes, stderr vs stdout, rich/ANSI
   formatting, TTY-dependent behaviour) → Scarf's parser/judge → what the UI shows.
3. Per journey check: verb/flag exists; success vs failure is judged correctly (incl. exit-0 failures);
   output parse matches the real current format; config key is read by Hermes at the path Scarf writes,
   with the value types Hermes accepts; file paths/shapes (JSON/YAML) match; remote path behaves like local
   (quoting, home dir, profile HERMES_HOME, timeouts); the UI state after success AND failure is honest.
4. Touchpoint inventory: list every Hermes touchpoint in your files (argv, SQL statement/table/column, ACP
   method/notification, config key read or written, ~/.hermes file) with a one-word status:
   OK / FINDING-<id> / TRACKED / UNVERIFIABLE. Nothing in your manifest may be left unaccounted for.
5. Known-issue ledger: before reporting a finding, search `TASKS.md`, `tasks/`, `documents/reports/`,
   `documents/*audit*`, `documents/audits/`, and `.memory/decisions/` (grep the symbol/key/verb). If it is
   already tracked or was a deliberate decision, mark it TRACKED with the reference instead of a new finding.
6. Before finalizing each finding, try to disprove it yourself (is there a guard elsewhere? does Hermes
   normalize the value? is the path unreachable?). Drop it if you can.

## Severity (user impact on primary functionality)
- P0: a primary feature is broken, silently reports success on failure, or loses/corrupts user data in a
  common setup (local, default profile, mainstream provider).
- P1: a primary feature is broken in a common-but-non-default setup (remote SSH host, named profile,
  non-default provider/platform), or a destructive action is mis-reported.
- P2: secondary feature wrong, misleading UI state, or stale/incorrect information shown.
- P3: cosmetic / hygiene with a real (not hypothetical) user-visible effect.
Confidence: LIVE (confirmed with a safe --help probe), SOURCE (both sides cited and traced), PLAUSIBLE
(cannot fully trace — say what is missing). Prefer fewer, solid findings.

## Output
Write your full report to `<SCRATCH>/r15results/<SECTION>.md` (create the directory if needed) with:

```
# <SECTION> — verdict: WORKS | WORKS-WITH-ISSUES | BROKEN
## Journeys
| # | Journey | Verdict (WORKS/DEGRADED/BROKEN/UNVERIFIABLE) | Findings |
## Findings
### <SECTION>-F1 · P? · confidence · NEW|TRACKED(ref)
- Claim: one sentence.
- Scarf: path:line (+ path:line)
- Hermes @v2026.9.24: path:line
- Failure scenario: concrete input/state → what the user sees vs what actually happened.
- Evidence: short quotes / probe output.
- Suggested fix (one line, optional).
## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
## Not audited / couldn't verify
```

Then return to the orchestrator ONLY a short summary: verdict, count of findings by severity, and one line
per P0/P1 finding (id · claim · Scarf file:line). Keep it under 25 lines.
