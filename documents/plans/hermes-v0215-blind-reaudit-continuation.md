# Continue: blind re-run of the whole-app Hermes v0.21.5 audit (after compaction)

## Context
- The whole-app audit (2026-09-26) and its full remediation (R01–R19) are DONE and merged to `main` locally as 3a9da0b8 (not pushed). Close-out: `documents/audits/hermes-v0.21.5-remediation-closeout.md`.
- Alan (2026-09-27) wants the FIRST audit re-run exactly as before, **blind to our fixes**: same method, same sections, fresh agents, no edge-case hunting, "works / OK" is a good and expected result. Output: a new ranked report so we can compare against the original.

## What "blind" means for the auditors
- Do NOT read: `documents/audits/hermes-v0.21.5-*` (the original report, its section reports, r14/r15 folders, close-out), `documents/plans/hermes-v0215-*`, or the remediation task tickets (R01–R19, t-8565a7f4, t-a1cb2b18). Don't mention the remediation in prompts.
- They MAY use memory notes and `.memory/decisions/` (that's normal project knowledge) and TASKS.md/tasks for the known-issue ledger — excluding the remediation tickets above. Accepted-limit follow-ups t-14157321, t-55229e05, t-b4cfc798 count as TRACKED.

## Steps
1. Read the charter (memophant `read_charter`). Code under audit: MAIN checkout `/Users/awizemann/Developer/Scarf` on `main` (confirm HEAD ≥ 3a9da0b8, tree clean apart from managed tiers). Hermes reference: `~/.hermes/hermes-agent-v0215` (tag v2026.9.24, 0.21.5) — confirm it still exists.
2. Rebuild the inventory exactly as the first time (files changed since): in the scratchpad `audit2/`, recompute the five greps (CLI `runHermes…`, SQL, ACP, YAML/config, `~/.hermes` files) over `scarf`, `Packages/ScarfCore/Sources`, `Packages/ScarfIOS/Sources`, `Scarf iOS` (run from `scarf/`), then assign with the same regex rules as `scratchpad/audit/assign.py` (S01–S15; reuse it if the scratchpad survived — else the rules are: S01 ACP transport, S02 RichChatViewModel/ChatViewModel, S03 chat surfaces/voice/personalities/quick cmds/slash, S04 sessions data, S05 config/settings, S06 models/providers/creds/Nous/proxy, S07 gateway/platforms/webhooks, S08 cron, S09 MCP, S10 skills/plugins/curator/tools, S11 projects core, S12 templates/miniapps/projects MCP, S13 kanban/bots/peers/profiles, S14 health/logs/memory/backup, S15 servers/transport/iOS deltas; HermesFileService split by its `// MARK:` regions; iOS files to their feature section). Coverage gate: 0 unassigned. Prefix paths with `scarf/`.
3. Brief: reuse `scratchpad/audit/BRIEF.md` verbatim if present (else recreate from the first audit's brief: read-only; ground truth tag v2026.9.24 with file:line; safe `--help`/`--version` probes only; scope = current Hermes, local + remote, iOS deltas; journeys-first trace; touchpoint inventory with OK/FINDING/TRACKED/UNVERIFIABLE; known-issue ledger; self-disprove; severity P0–P3; confidence LIVE/SOURCE/PLAUSIBLE; report file + ≤25-line summary). Add the blind-rule paragraph above. Write reports to `scratchpad/audit2/results/`.
4. Launch 15 section auditors in one message (general-purpose, opus, background), same section focus notes as the first run (Chat ×3: transport, events, surfaces; Projects ×2: core, templates/MCP/miniapps). Tell them not to spawn sub-agents.
5. As they report: log each; send every P0/P1 to an independent verifier (VERIFY-BRIEF style, try to disprove), record verdicts.
6. Write `documents/audits/hermes-v0.21.5-blind-reaudit.md` (via write_tier_file): section verdict table, ranked findings, method/coverage — and ONLY THEN add a comparison section vs the original audit (counts by severity, which original findings recur, what's new). Create Memophant tasks for confirmed findings only after Alan reviews.
7. Report to Alan in plain English, concise; ask before any fixing.

## Saved kit (survives compaction)
`documents/plans/hermes-v0215-blind-reaudit-kit/`: `BRIEF.md` (the original auditor brief — note it tells auditors to search `documents/reports/`, `documents/*audit*`, `documents/audits/` for the ledger: replace that with the blind rule), `VERIFY-BRIEF.md`, `assign.py` (the section rules; it reads a file list and writes JSON — paths are relative to `scarf/`).

## Notes from the run
- Other projects (Herald, Orchestric) run xcodebuild UI tests on this Mac; audits are read-only so it doesn't matter, but never start `xcodebuild test`.
- Agents sometimes "hand back" before background children finish — tell auditors not to spawn sub-agents, and verifiers to work alone.
