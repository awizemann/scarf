---
title: Hermes v0.15 Capability Gating Decisions
type: note
permalink: scarf/decisions/hermes-v0.15-capability-gating-decisions
tags: [hermes, capabilities, v015]
created: 2026-05-29
updated: 2026-09-04
---

## Observations

- [decision] t-05f33e75 builds on the set_mode surface two ways: a per-project "auto-accept edits" setting that issues `session/set_mode accept_edits` after every `session/new` / `session/load` (and after autostart + reconnect, since the mode is scoped to the ACP session and each of those is a fresh one), and an "Allow edits for this session" third button on the tool-approval dialog. Both gate on the SAME `hasSessionEditAutoApproval` flag the header picker uses; both leave enforcement Hermes-side. The setting's trust placement is documented in [[Integrity is not authenticity: agent-writable Scarf sidecars need a Keychain-held MAC]] #safety
- [gotcha] Edit-shape on a permission request is `toolCall.kind == "edit"` — the same field the dialog's pencil icon already keys off, verified against `acp_adapter/edit_approval.py` which builds every file-edit approval as `kind="edit"` with exactly `allow_once` + `deny`. Scarf renders Hermes's own options and only APPENDS its button when exactly one option reads as an affirmative allow, so a reduced or deny-only option set (v0.20 generic parsing) grows nothing #safety

- [decision] Vercel AI Gateway + Sandbox removed from Hermes in v0.15 — Scarf drops `vercel` from demotedProviders, modelAliases, and terminalBackends (unconditional, no flag) #providers
- [decision] OpenAI is now a first-class provider with wire ID `openai-api` (distinct from `openai-codex`). Bare `openai` is a Hermes alias for `openrouter` so Scarf does not register it #providers
- [decision] xAI May-15 retired Grok model IDs (grok-4-0709, grok-4-fast-*, grok-3, grok-code-fast-1, grok-imagine-image-pro, etc.) resolve forward to grok-4.3 / grok-imagine-image-quality in modelAliases — mirrors hermes_cli/xai_retirement.py #providers
- [decision] Kanban chat-scope: Hermes now stamps ACP session_id on tasks via HERMES_SESSION_ID env around run_conversation — `hermes kanban list --session <id>` filters server-side. Removed the old client-side sessionStartedAt/filterBySessionStart approximation; chat chip + handoff now gated on hasKanbanSessionFilter (>= 0.15). Global Kanban sidebar + per-project tab stay on hasKanban (v0.12+) #kanban
- [decision] /handoff is NOT a model handoff — it's cli_only=True and hands a session to a messaging platform (Telegram, Discord). Scarf intentionally does not add it to the ACP slash menu. Mid-chat model switching uses session/set_model RPC under hasACPSetSessionModel (v0.13) #chat
- [decision] Per-session edit-approval modes (Default/Accept Edits/Don't Ask) via ACP session/set_mode are distinct from global approvals.mode/YOLO — sensitive paths always still prompt regardless #safety
- [decision] Hermes Proxy (v0.14+) is local-only in v1 — SSH remote contexts show explanatory notice (would need port-forward wiring) #proxy
- [sync-target] Keep these in sync on each Hermes bump: overlayOnlyProviders / modelAliases / demotedProviders / imageGenModels (vs hermes_cli/providers.py + models.py + xai_retirement.py); platform roster (vs plugins/platforms/ + gateway/platforms/); search/TTS backend lists #maintenance

## Relations
- implements [[Hermes Integration]]
