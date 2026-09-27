# Hermes v0.21.5 audit remediation — close-out

Date: 2026-09-27 · Parent task: t-a1cb2b18 · Merged to `main` locally as 3a9da0b8 (not pushed).
Audit: `documents/audits/hermes-v0.21.5-full-app-audit.md`. Plan: `documents/plans/hermes-v0215-audit-remediation-plan.md`.

## Outcome
- All 72 audit findings resolved (2 P0, 12 P1, 40 P2, 18 P3). One partial refutation (S06-F7 xai rows); one refuted add-on (R09 Bot CLI notePromptWire).
- Orchestrator audit (R14) found 13 cross-phase follow-ups (incl. a security gap: profile auth.json in "no auth" backups) → fixed in R16a/b/c.
- Touched-surface re-audit (R15, 171 files, 8 areas) found 4 P1 + ~11 P2 + ~12 P3 → all fixed in R18a/b/c; a combined R18 review found silent backup data loss (unanchored excludes) → fixed in R19.
- Final gate at c26ad8f9 (== main tree): ScarfCore 4086 · ScarfIOS 117 · scarfTests 1795 serial, no host restart · scripts + check-hermes-tables lanes=7/7 · catalog validator · iOS build · Smoke UI PASS.
- Linux verification of backup/restore scripts on Debian 13, Ubuntu 24.04, Alpine 3.24 (GNU + BusyBox tar) and macOS bsdtar.

## Decisions by Alan
Quick commands out of the chat menu; personality relabelled (upstream note: documents/upstream/2026-09-27-acp-personality-overlay.md, unfiled); `.hermes/` shadow detector deleted; mini-apps keep project cwd (docs corrected); C3 exception for user-initiated Server Restore swap (charter task t-b4cfc798 — Alan to edit the charter); "Include auth" off keeps Hermes behaviour (.env/vault ship); Template Author template bumped to 1.0.1.

## Phases
R01 MCP · R02 profile pinning · R03 config/models · R04 cron · R05 data safety · R06 skills/plugins · R07 gateway/platforms · R08 transport · R09 chat pipeline · R10 chat controllers · R11 sessions data · R12 projects/templates · R13/R13b i18n · R14 orchestrator audit · R15 touched-surface re-audit · R16a/b/c R14 follow-ups · R17 gate fixes + leftovers · R18a/b/c R15 fixes · R19 final leftovers + i18n.

## Release-note items
- Server Backup: read-only snapshots of every Hermes database; scope now matches `hermes backup` (no Hermes install/runtimes/caches/browser profiles); manifest v2 (older Scarf refuses new archives cleanly); Restore refuses while Hermes holds a database; per-profile cron pause.
- Gateway Restart refuses a hand-run (no service) gateway and points to `hermes gateway install`.
- Custom remote home users: gateway service name follows Hermes's per-home name.
- Fetch MCP preset now needs `uv` on the host. Honcho Eager Init toggle removed (Hermes never read it from config.yaml).
- OAuth MCP servers can be added again (catalog via `hermes mcp install`, with install settings).

## Left for you
- Commit the managed tiers via Memophant (.memory, wiki, documents, tasks, TASKS.md, templates — incl. the rebuilt Template Author 1.0.1 and catalog.json).
- Edit the charter per t-b4cfc798.
- Push when ready.
- Open follow-ups: t-14157321 (Bot Chat Stop control + 3 minors), t-55229e05 (profile excludes under GNU tar; move backup matrix harness into repo).
- Known accepted limits: csh `!`/newline args; Asana secret prompt under a controlling terminal; streamScriptCommand PATH scope; autostart's first queued prompt if its client dies before load; plugin rewrite that neither repeats nor reuses an id.

## Evidence
`documents/audits/hermes-v0.21.5-full-app-audit/` (section reports, VERDICTS.md, r14-remediation-audit/, r15-touched-surface-audit/). Per-phase artifacts on each R task.
