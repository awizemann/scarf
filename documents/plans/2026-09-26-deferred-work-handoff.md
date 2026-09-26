# Deferred work from the Hermes v0.21.5 / Scarf 3.4.0 session (2026-09-26)

Context: branch `feat/hermes-v0215-parity` (not pushed) carries Hermes v0.21.4/v0.21.5 parity, the P6 whole-surface audit fixes (P7a–f) and the final-review fixes (P9). Plans: `documents/plans/2026-09-26-hermes-v0-21-5-release-plan.md`, `documents/plans/2026-09-26-p6-surface-audit-findings-and-fix-plan.md`. Decisions: memory `decisions/hermes-v0-21-4-v0-21-5-compatibility-decisions`.

## Next release (3.4.1) — security
- **t-93ddfdc4 ScarfGo accepts any SSH host key** (`hostKeyValidator: .acceptAnything()` in `ACPClient+iOS.swift:161`, `CitadelServerTransport.swift:1170`, `CitadelSSHService.swift:147`). Design trust-on-first-use pinning in the Keychain, first-connect fingerprint confirmation, clear mismatch error with a deliberate re-trust, silent pin on next connect for existing servers.

## GitHub issues / PRs (need Alan's go-ahead for any public comment)
- **#146** resuming a hermes-webui session spawns new chats: Hermes ACP `session/load` only restores `source == "acp"` sessions (`acp_adapter/session.py:428`, `server.py:616-624`); Scarf silently falls back to a new session while showing the old transcript. Fix: check source before resume (Bot Chat does, `BotConversationViewModel.swift:209`), say "continues as a new session without context" or resume via CLI transport; resolve `compressionTip`; handle `_meta.hermes.sessionProvenance` rotation. Second spawn needs a live repro. Related t-e875803c.
- **#145** branch/fork: working timer SHIPPED in 3.4.0. Remaining: mark branched sessions (parent_session_id / `_branched_from`) in the session list; fork action deferred (ACP `session/fork` writes no lineage — file upstream).
- **#142 / PR #144** HERMES_ENVIRONMENT_HINT: decision = maintainer rework. Gate on v0.16.0 (reader first at v2026.6.5), compose with the user's existing hint instead of overriding, keep Kanban tenant + slash-marker + secrets rules reachable, cron context, Cockpit preview, Scaffolder seed, tests (ProjectUpgradeServiceTests). Credit the contributor.
- **#140** CPU during chat: Alan believes fixed — ask reporter to retest on 3.4.0 and close if quiet.
- **#141** ScarfGo sqlite3 missing: friendly message shipped; Python `sqlite3` fallback deferred.
- **#139** TestFlight: resolved by App Store release — close.

## Feature gaps found in audits
- Permission sheets drop `toolCall.content` (no diff for edit approvals); diff content blocks ignored (`ACPMessages.swift:455-475,506-514`).
- Parallel tools: second tool's exit status lost.
- Filter `model_catalog.excluded_providers` in Scarf's own pickers (help text reworded for now).
- Show the v0.21.5 STANDALONE reason in Profile Routes too (Gateway pane has it).
- Consider disabling the model badge mid-turn on ≥0.21.4 (Hermes refuses set_model while busy).

## Smaller follow-ups logged on tasks
- `OutcomeMessageBar.swift:73` dismiss label says "failure" for unconfirmed messages (~20 surfaces).
- ScarfMiniAppBridge forwards stray approval `tool_call_update`s to mini-apps.
- `loadEarlier` lacks a post-await session re-check; iOS ladder retrying from `.failed` replaces the old client without stopping it.
- ModelPresetEditSheet may share the alias-blank-open bug.
- Bots roster lists marker-less/tombstoned profile dirs Hermes now hides.
- `cron status` output changed 0.21.3→0.21.4 (unaudited).
- Mac dashboard snapshot error shows a generic message; humanize labels CANTOPEN as "Hermes state not found".
- ScarfCore-only catalog keys have no guard test against Mac-scheme extraction pruning; ScarfGo has no string catalog of its own; pre-existing unlocalized HealthSection titles, cron "Agent started…"/"Run failed to queue…", `ACPClient.swift:279`.
- Legacy pre-v23 FTS + stale-index recovery edge case (under-scan below marker).
- Pre-existing flaky test: `MainActorSpawnDisciplineP22Tests.cancelLoadStopsTheRemainingProbes` fails on main; full scarfTests has ~180 timing failures under parallel load on main (t-e3926f86 family).

## Local test environment to restore (Alan's Mac)
- `hermes` launcher points at official v0.21.5 (`~/.hermes/hermes-agent-v0215`). Restore fork: `mv ~/.local/bin/hermes.fork-backup ~/.local/bin/hermes`, then `hermes gateway install --force` from the fork.
- Duplicate Telegram tokens disabled in `~/.hermes/profiles/{gateway,scarfbox-test}/.env` (backups: `.env.scarf-test-backup`).
- Hermes wrote `gateway.multiplex_profiles: true` to `~/.hermes/config.yaml`; gateway now multiplexes 6 profiles.
