---
id: t-8f0f7ac0
title: Hermes v0.17 — Tier 2: capability gates + tests + new platforms + config surfaces, bump target to v0.17
status: done
added: 2026-06-21
---

## Description

v0.17 additive catch-up. All surfaces source-verified (see [[Hermes v0.17.0 Audit Findings]]); all optional and capability-gated so pre-v0.17 hosts render byte-identical. GATED on the other ScarfCore session (see Tier 1 task). Note: v0.17 forced ZERO mandatory changes — schema/ACP/CLI/config/catalog all byte-stable — so this is a feature catch-up, not a correctness fix.

Phase 1 — gates + tests: add `// MARK: v0.17 (v2026.6.19) flags` to HermesCapabilities.swift + `isV017OrLater`; flags for the surfaces shipped below. Add HermesCapabilitiesTests cluster mirroring v0.16: parseV017ReleaseLine / v017FlagsAllOn / v016HostHidesV017Flags (degradation) / v017PatchStillOn. Bump version-target memory notes + the stale wiki/Hermes-Version-Compatibility.md (two cycles behind).

Phase 2 — gateway platforms (roster 23→26): add `photon` (iMessage via Photon Spectrum; form shells `hermes photon setup`, PHOTON_ALLOWED_USERS; Node-18 dep; do NOT merge with the existing BlueBubbles `imessage` case), `whatsapp_cloud` (Meta Business Cloud API; credential-heavy form under platforms.whatsapp_cloud.extra.*), and `raft` (niche wake-channel, single RAFT_PROFILE field — DEFER candidate). Add the missing SimpleX setup form (in roster since v0.14; 3 env keys). Fix the WhatsApp allow_from allowlist here (Tier 1 item 5). Telegram: add `rich_messages` (default-on→write only when false) + `status_indicator` toggles.

Phase 3 — config surfaces: `curator.consolidate` toggle (consolidation now default-OFF/opt-in — behavior changed under users); `max_concurrent_sessions` (Advanced); MCP per-server `keepalive_interval`. Lower-value/DEFER: `memory|skills.write_approval`, `terminal.home_mode`, `tts.gemini.*`, `hermes skills list-modified --json`/`diff`.

Phase 4 — verify + adversarial audit + hand to scarf-release-prep (coordinated v2.12.0 minor; or Tier 1 as v2.11.1 patch first then Tier 2 v2.12.0 — Alan wants them together → one v2.12.0). Manual capability check needs the local Hermes updated to v0.17.0 (Alan offered).

OPEN DECISIONS: (a) WhatsApp allowlist proper allow_from vs drop-from-editor; (b) include or defer `raft`; (c) include or defer write_approval/low-value config; (d) update local Hermes to 0.17 for manual verification; (e) release version (recommend v2.12.0).

Closed 2026-07-14: superseded by the v0.18 target (memory: decisions/hermes-v0-17-compatibility-decisions + hermes-v0-18-compatibility-decisions). Tier 2 SHIPPED in v2.12.0 (commits ea8566d/44b0ee7/f7a819f): gates+tests, whatsapp_cloud, SimpleX form, Telegram rich_messages/status_indicator, curator.consolidate, max_concurrent_sessions. Every remaining sub-item is tracked in its own open task: photon/iMessage → t-5ab57e6f, MCP keepalive_interval → t-07a9baa4, google-chat allowlist no-op → t-2d6888ea. raft was deferred by decision; nothing untracked remains open.

## Plan



## Artifacts



