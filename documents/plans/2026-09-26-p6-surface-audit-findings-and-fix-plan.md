# P6 whole-surface audit — findings & proposed fix phases (2026-09-26)

Branch `feat/hermes-v0215-parity` @ 42d9257f (+ localization in flight). Three read-only Opus audits over every surface the branch touched, old code included. "Pre" = pre-existing on main; "Branch" = introduced/widened by this branch. Orchestrator re-verified the two items marked ✔.

## P7a — ACP client (Opus)
- **HIGH ✔ Pre** `ACPClient.swift:599-605` sends `session/cancel` as a REQUEST; acp 0.9.0 routes it only as a NOTIFICATION (`acp/agent/router.py` `route_notification(session_cancel…)`) → -32601, swallowed by `try?`. Stop, voice barge-in and iOS cancel have never stopped a Hermes turn. Fix: send without `id`. Memory note S4 "Fixed" is wrong — correct it.
- MED Pre `ACPClient.swift:297-329` failed `initialize` leaves channel/readTask live; retry reports `.running` uninitialised; `MiniAppAgentSession.swift:187` leaks the process.
- MED Pre `ACPClient.swift:932-950` after EOF, `session/prompt` (no timeout) can hang until stop → guard `isConnected` in `sendRequest`.

## P7b — Chat view models (Opus)
- HIGH Pre reconnect ladder has no currency check after awaits (Mac `ChatViewModel.swift:2268-2310`, iOS `ChatView.swift:~2756-2815`) → a stale attempt overwrites the newer session/client and transcript.
- HIGH Pre `RichChatViewModel.reconcileWithDB` (:2730-2770) doesn't update `oldestLoadedMessageID`/`hasMoreHistory`/cutoff nor re-check sessionId → duplicated or skipped history on "Load earlier".
- MED Pre `addUserMessage` mid-turn (:1965-1981) drops streaming text/tool card without finalising.
- MED Branch `openToolCallIds` never cleared at turn end/disconnect → on <0.21.4 a late update finalises the next turn mid-stream.
- MED Pre iOS `runPrompt` (:2356-2415) no `client ===` guard / no CancellationError arm → fresh chat shows the old turn's failure.
- LOW Pre `stopReason:"cancelled"` from an intentional voice barge-in shows a failure banner.
- LOW Branch `workingSince` starts at attach time on a resumed running turn / can reset on poll flicker → seed from the last user message time.
- LOW Branch `AgentThinkingRow` stole `PermissionWrapper`'s doc comment (iOS ChatView ~3195).

## P7c — Data layer (Opus)
- **HIGH ✔-plausible Pre, charter C3** `LocalSQLiteBackend.swift:152-171` / `RemoteSQLiteBackend.swift:683-692` query_only fallback opens READWRITE; as the last connection on a WAL db it checkpoints into state.db (reproduced in scratch DBs). Fix: `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`; remote `.dbconfig no_ckpt_on_close on` with output suppressed.
- MED Pre search returns `[]` on any error (`HermesDataService.swift:870-874`) → "No matches"; iOS dashboard fetch failure after a good open → "No sessions yet"; concurrent `.task` + `.refreshable` loads can close the service under each other.
- LOW Pre deep-tool LIKE fallback keeps `"` in terms → quoted searches miss; runs on almost every search at ≥0.21.4.
- LOW Pre Health: remote optimize refusal naming Scarf's own transient `sqlite3` reader → say "Scarf's own read was in progress — retry".

## P7d — Settings / catalog (Sonnet)
- **MED ✔ Branch** WhatsApp Decline Message written to `whatsapp.unauthorized_dm_decline_message`; Hermes reads only top-level/`gateway.` (`gateway/config.py:789`, `config_loader.py:103`, `run_inbound.py:140`). Write the global key, label it global. Also case-insensitive `decline` read; below 0.21.4 show "not supported — behaves as pair" instead of a working choice.
- LOW Branch threshold_tokens `256_000` / `300000.0` parse to 0 (Python `int()` accepts them).
- LOW Branch model picker opens blank for alias providers (`chatgpt`, `kimi`, `moonshot`) → canonicalise when no row matches.
- LOW Branch MCP gated parse stale after capability re-detect → reload on capabilities change.
- LOW Pre `opencode-free` offered below v0.20.5 (first shipped v2026.8.19) → `isV0205OrLater && !isV0214OrLater`.
- LOW Pre MCP test-result icon lacks a VoiceOver label; Excluded Providers help text claims Scarf's picker hides them (it doesn't — filter or reword).

## P7e — Gateway / profiles / health / skills (Sonnet)
- MED Pre+Branch Profile Routes allowlist warning fires on ≥0.21.3 where Hermes no longer reads `gateway.multiplex_profile_allowlist` (only migration 43 deletes it) — branch widened it to the common case → gate `isV0204OrLater && !isV0213OrLater`.
- MED Pre Skills "Check for updates" ignores exit code → timeout/traceback reads as "No updates available" and wipes the list.
- MED Pre Health Doctor: failed/timed-out run shows an empty/truncated grid; stray `Key: value` lines count as passing; 60 s cap reachable.
- LOW-MED Pre security audit: any exit 1 shows "Advisories found" even for a traceback → require a parsed finding count.
- LOW Branch Bots settlement-pending note auto-clears in 3 s; LOW Pre Profiles note can be wiped by an earlier action's timer.

## P7f — Cron / peers (Opus)
- **HIGH Pre** Cron "Run now" runs synchronously (`hermes_cli/cron.py:779` `_SESSION_ASYNC_DELIVERY=False`) but Scarf caps it at 30 s → any agent job >30 s is killed mid-LLM-call (stale claim locally) and shown failed; the comment claiming it only marks the job due is wrong.
- MED Pre Run now on a paused/missing job shows green "Agent started" (Hermes exits 0 with an execution_skipped sentence).
- MED Pre cron selection race: load/selectJob results land on a different selection.
- MED Branch duplicate still copies `manual_run_at`, `manual_run_prompt`, `preflight_alerted`, `last_delivery_queued` → copy's first fire can inject the source's pending prompt.
- LOW-MED Pre `peer run` can time out after creating the run; retry double-runs (no `--idempotency-key`).
- LOW Pre/Branch finished DM/run clears a draft typed meanwhile; compose editor's a11y label is "Send"; `--pin` with no main model is a silent no-op.

## Not in these phases (proposed separately)
- **Security, Pre:** ScarfGo accepts any SSH host key (`hostKeyValidator: .acceptAnything()` in `ACPClient+iOS.swift:161`, `CitadelServerTransport.swift:1170`, `CitadelSSHService.swift:147`) → MITM. Needs a trust-on-first-use known-hosts design + UI; its own task.
- Feature gaps: permission sheets drop `toolCall.content` (no diff for edit approvals), diff content blocks ignored; parallel tools lose the second exit status.
