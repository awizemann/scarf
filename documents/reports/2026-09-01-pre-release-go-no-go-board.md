# Pre-release go/no-go board — main @ 9b2c178 (v2.23.0 + Bot Mode merge), 2026-09-01

Five independent read-only audits. Mechanical gates: 1592/1592 ScarfCore tests, Debug build clean.

| Audit | Verdict |
|---|---|
| 1. Bot Mode (concurrency/lifecycle/UX/perf) | GO-WITH-CONDITIONS — prior blocker fixes all verified correct; no new blockers |
| 2. Two-release regression span (v2.21.0→main) | GO-WITH-CONDITIONS — two functional seams + a11y/l10n bar slippage |
| 3. Chat surface | GO-WITH-CONDITIONS — main chat byte-identical to v2.23.0; one honesty condition |
| 4. Bots surface (product) | GO-WITH-CONDITIONS — strong honesty posture; 4 pre-ship items |
| 5. Settings surface | GO-WITH-CONDITIONS — one silent no-op save; two dead rows |

**Overall: GO-WITH-CONDITIONS. No NO-GO. One fixup package closes the blocking set.**

## Blocking conditions (fix before cut)

1. **Routine failure shown as green success, auto-clearing** — BotRoutinesView renders CronViewModel's shared message channel in success color (A1-M1/A4-C1). Color by outcome; don't auto-clear failures.
2. **"Remove from Bots" only hides** — demote() sets hidden but keeps bot-managed; label over-promises (A4-C2). Rename the affordance or make demote clear the hermes-bots block.
3. **Bot Chat rename story is triply wrong** (A2-F8 + A3-F1 + A4-C3): Scarf-created Bot Chats are visible ⇒ Hermes's rename guard never fires ⇒ a rename SUCCEEDS and orphans the transcript; the docstring promises a UI warning that doesn't exist; the conversation pane's Sessions note is wrong for the common case (bot's chat lives in the bot profile's state.db, not the window's Sessions). Fix: warn on rename of a session titled "Bot Chat" (any profile), correct the pane copy, correct the docstring.
4. **Verify the DM-creation CLI flags at v0.20.3** (A4-C4) — `chat -c/--create-if-missing/--query-file` confirmed at v0.21 only; hasBotMode floor is v0.20.3. Verify at tag v2026.8.16.2 or floor the creation path.
5. **Bot conversations never receive the capabilities store** (A2-F1) — slash menu permanently degraded in every bot chat. One line in BotConversationView/VM.
6. **ScarfDesign components are unlocalizable** (A2-F2) — ScarfPageHeader/SectionHeader/TextField/Badge take String and bind Text's verbatim overload; ~68 call sites can never extract. Change to LocalizedStringKey (source-compatible).
7. **Settings: `gateway.platforms.<p>.gateway_restart_notification` writes the wrong path** (A5-HIGH) — Hermes reads top-level `<p>.gateway_restart_notification`; toggle is a silent no-op that Scarf's own reader contradicts.
8. **Dead Settings rows**: `redaction.enabled` (real key is security.redact_secrets, already surfaced) and `tts.xai.model` (no such key at v0.21); confirm `agent.verbose` then remove/gate (A5).
9. **A11y bar** (A2-F3/F4): PeersView has zero accessibility labels; prompt TextEditors in CronView/BotRoutinesView unlabeled beside visible labels. Label them (Bots itself already exceeds the bar).

## Queued follow-ups (not blocking)

- Dual PeersViewModel instances drift async-run handles between Peers and Bots▸Remote (A2-F5) — share the coordinator-cached instance.
- Batched SSH profile scan + avatar caching + no avatar re-read on metadata saves (A1-M3/M4).
- routinesViewModel capability mirroring inside @ViewBuilder (A1-M2) → move to onAppear/onChange; prefer named flag over raw isV0206OrLater (A2-F7).
- Checkpoints display defaults stale (true/50 vs v0.21's false/20) — needs a capability-aware resolver; same class: delegation defaults pre-v0.20.4 (A5).
- `hermes memory off` save path swallows exit code (A5); generic "Failed…" strings at 4 call sites could reuse saveFailureMessage.
- Widen the config-parity test gate beyond SettingsViewModel.swift (A5) — it's how the restart-notification bug survived.
- Routine delete affordance missing in the bot pane; empty-prompt routine creatable; NUL guard absent (A1-L7/L8).
- Streaming fence-split cosmetic mid-stream artifact (A3-F2); pendingPermission single slot (A3-F3, pre-existing); ACPClient half-open start footgun (A3-F5, unreachable today).
- Avatar too-large silently falls back (A1-L9); canSave allows "default" (A1-L10); Create sheet fixed 460pt no ScrollView dynamic-type hazard (A4).
- Release notes must: except Bots/Peers from the "fully localized" claim (until item 6 + extraction pass), acknowledge Profiles/Bots and Peers/Bots▸Remote surface duplication, and carry the honest competitive delta (missing vs Hermes desktop: per-bot model pin, SOUL.md editing, per-skill/toolset/MCP enablement, @mention autocomplete, roster search/presence, group chats).

## Notable clean verifications
Main chat byte-identical for non-bot use (two-way verification); streaming throttle drops no final delta; reconnect semantics correct; W6 preview SQL × hidden Bot Chats clean; gating matrix consistent across all sampled flags; W8 escaping adopted everywhere; commit hygiene clean across both cycles.
