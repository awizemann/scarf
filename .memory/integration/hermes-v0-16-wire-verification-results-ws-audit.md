---
title: Hermes v0.16 wire-verification results (WS-* audit)
type: note
permalink: scarf/integration/hermes-v0-16-wire-verification-results-ws-audit
tags: [hermes, v016, verification, wire-format, gotcha]
created: 2026-06-14
updated: 2026-09-09
---

Verified the WS-* "verify against a live host" audit TODOs against the live Hermes v0.16 source (`~/.hermes/hermes-agent`, 2026.6.5) on 2026-06-14. Summary below; verified TODOs were dropped, mismatches captured as follow-up work.

> **UPDATE 2026-06-15 — ALL MISMATCHES RESOLVED** on branch `fix/v016-mismatches` (commits `9bc39b7` gateway allowlist-path + gateway-list text parsing; `6786e66` kanban `verify` verb, curator `list-archived --json`, `openrouter.response_cache` scalar, `addMCPServerSSE` → `--url`+YAML, ACP `/goal`/`/subgoal` de-advertised). Each was re-verified against live v0.16 before fixing. The "MISMATCHES" notes below are kept for the audit trail.

## VERIFIED (assumption matches v0.16 — TODOs dropped)
- ACP `/queue <text>` and `/steer <text>` ARE advertised + handled by the ACP adapter (server.py `_ADVERTISED_COMMANDS`).
- `tts.xai.voice_id` and `tts.xai.auto_speech_tags` are the real xAI TTS keys (tools/tts_tool.py).
- Kanban: `failure_count` is task-level only (tolerant decode fine); diagnostics live on the task not the envelope; diagnostic `kind` strings backstopped by `.unknown` (safe).
- Curator: `prune --dry-run` exists; sync-run timeout is caller-owned (no CLI flag).
- MCP: `transport: sse` scalar + `sse_read_timeout` default 300.0s confirmed (tools/mcp_tool.py + its test).
- Cron: `--agent` toggles `--no-agent` off; empty-prompt-positional with `--no-agent` is correct (subcommands/cron.py).
- `web_tools.backend` fallback is conservative; profile `--clone-all`/`--no-skills` are independent flags.

## MISMATCHES (real, pre-existing — tracked as follow-up, NOT fixed in the wrap-up)
- [behavior] ACP `/goal` + `/subgoal` are **gateway-only** in v0.16 — NOT in the ACP adapter's advertised/handled commands (they're in gateway/slash_commands.py). Scarf surfaces `/goal` in the ACP chat menu (gated `hasGoals`) where it does nothing useful; goal-state read-back has no ACP path either. Fix: drop `/goal`/`/subgoal`/goal-state from the ACP surface.
- [CRITICAL — RE-VERIFY FIRST] Gateway allowlists: Scarf reads/writes `gateway.platforms.<platform>.*`; v0.16 reads top-level `slack:` / `telegram:` / `matrix:` / `dingtalk:` (`allowed_channels`/`allowed_chats`/`allowed_rooms`) per gateway/config.py. Agent flagged "silent fail" BUT also noted `gateway.platforms` may be a runtime override layer — RE-VERIFY whether Scarf's path is honored before changing anything.
- [CRITICAL — RE-VERIFY FIRST] `hermes gateway list --json` does NOT exist in v0.16 (text output only, hermes_cli/gateway.py). Scarf's HermesGatewayListService assumes `--json`. Verify Scarf's actual runtime behavior/fallback before fixing.
- [bug] `hermes kanban verify <id>` verb does not exist — KanbanService.verify()/rejectHallucinated() assumed it. SUPERSEDED 2026-09: the whole hallucination-gate surface was DELETED — no Hermes tag ever emitted `hallucination_gate_status`/`auto_blocked_reason`, so the gate never rendered; `rejectHallucinated` is gone too. See decisions/hermes-v0-21-1-compatibility-decisions § "Whole-surface remediation — P14".
- [bug] `curator list-archived --json` flag doesn't exist — Scarf retries-without-flag every call (works, wasteful).
- [bug] `openrouter.response_cache` is a SCALAR bool in v0.16 (config.py default `True`), not nested `.enabled`. Scarf writes nested — likely "works" only because a truthy dict reads as enabled. RE-VERIFY the nuance before changing.
- [bug] `addMCPServerSSE` passes `--transport`/`--sse-read-timeout` flags that `hermes mcp add` does NOT define (subcommands/mcp.py); SSE config is written to YAML post-add. Dead function.
- [minor] `tts.xai.model` is not a real xAI TTS key; ACP compression-count is NOT on the `session/prompt` usage blob (comes via a separate UsageUpdate notification); kanban `max_retries` default is dispatcher `kanban.failure_limit` config, not 3.
- [keep] google-chat platform spelling (plugin-defined, not yet shipped) and the gateway notice-TTL field (absent in v0.16 config) remain unverifiable — TODOs kept.

## Observations
- [done] Verified the WS-* "verify against a live host" audit TODOs against live Hermes v0.16 source (2026.6.5) on 2026-06-14; all mismatches resolved on branch fix/v016-mismatches (commits 9bc39b7, 6786e66) by 2026-06-15 #hermes #v016
- [gotcha] ACP /goal and /subgoal are gateway-only in v0.16 (gateway/slash_commands.py), NOT in the ACP adapter's advertised/handled commands — de-advertised from Scarf's ACP surface #hermes #v016
- [gotcha] `hermes gateway list --json` does not exist in v0.16 (text output only), `hermes kanban verify <id>` verb does not exist, and `curator list-archived --json` flag doesn't exist #hermes #v016
- [gotcha] openrouter.response_cache is a SCALAR bool in v0.16 (default True), not nested `.enabled`; addMCPServerSSE's --transport/--sse-read-timeout flags don't exist (SSE config is written to YAML post-add) #hermes #v016
- [convention] Gateway allowlists live at top-level slack/telegram/matrix/dingtalk keys in v0.16 (allowed_channels/allowed_chats/allowed_rooms), not gateway.platforms.<platform>.* — flagged CRITICAL and re-verified before fixing #hermes #v016

## Relations
- relates_to [[Hermes Integration]]
- relates_to [[Hermes v0.16 Compatibility Decisions]]
