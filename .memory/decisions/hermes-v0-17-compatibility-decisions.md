---
title: Hermes v0.17 Compatibility Decisions
type: note
permalink: scarf/decisions/hermes-v0-17-compatibility-decisions
tags: [hermes, v017, compatibility, capabilities, decisions]
created: 2026-06-21
updated: 2026-09-11
reviewed: 2026-09-11
reviewed_by: claude-opus-5
---

Implemented on branch `feat/hermes-v017-parity` (6 commits, 2026-06-21), built on top of the Hermes v0.17.0 audit findings (never written up as its own note). Merged + SHIPPED in v2.12.0 (the Hermes v0.17 catch-up release; task t-b2b590c6) — main is now at v2.13.0. [corrected 2026-06-27] Verified each phase: Debug build + ScarfCore tests green (641/642; the 1 failure is the known flaky RemoteSQLiteBackend subprocess race (task `t-aud32`), not these changes).

## Observations
- [tier1] Fixed 5 PRE-EXISTING bugs the v0.17 argv-vs-argparse audit surfaced (broken on v0.16 too, missed by prior cycles): `hermes audit`→`security audit` (bare audit routed to an agent turn); `migrate xai` needs `--apply` (was dry-run → silent no-op + false success); `acp --setup-browser` flag is `--yes` not `--assume-yes` (argparse exit 2); WhatsApp allowlist wrote a no-op `whatsapp.allowed_chats` (Hermes reads `allow_from`) — dropped from the chat-id editor; Settings now surfaces the real `config set` failure reason (managed-scope etc.). Commit 0d9e026. #tier1
- [curator] `hermes curator prune` was mislabeled + broken since v0.13: Scarf's UI claimed "permanently delete archived skills from disk" but the verb BULK-ARCHIVES idle ACTIVE skills (reversible via Restore; no delete-from-disk verb exists), and Scarf called it with a phantom `--json` + no `-y` (hung). Repurposed to "Archive idle skills" — `curator prune --days N {--dry-run|-y}`, text parser, idle-age model, reframed reversible confirm sheet, header submenu (30/60/90/180d). Commit 0ee1b0a. #curator
- [tier2] v0.17 surfaces shipped, all capability-gated (`isV017OrLater` + flags) so pre-v0.17 hosts render byte-identical: `curator.consolidate` toggle (consolidation is now OPT-IN — behavior changed under users), `max_concurrent_sessions` cap (0=unbounded), Telegram `rich_messages`/`status_indicator` (`platforms.telegram.extra.*`), the `whatsapp_cloud` platform (Meta Business Cloud API, 25th; full WhatsAppCloudSettings model), and a SimpleX setup form (22nd platform — had none since v0.14). Also backfilled the MISSING v0.16 capability test cluster (the v0.16 cycle shipped flags without tests). Commits ea8566d, 44b0ee7, f7a819f. #tier2
- [gotcha] **Built-in gateway platforms need `platforms.<name>.enabled: true` written explicitly** — they parse as `enabled=False` by default (`gateway/config.py` PlatformConfig.from_dict). PLUGIN platforms (ntfy, simplex) auto-enable from their env trigger, so a form that only writes creds works; but a BUILT-IN like `whatsapp_cloud` stayed configured-but-OFF until save() also wrote `enabled`. Caught by the fresh-eyes audit as a HIGH bug; WhatsAppCloudSetupViewModel now writes `enabled` based on whether required creds are present. Generalize this for future platform forms. Commit f62ba0a. #gotcha
- [deferred] (1) **photon/iMessage** — held: iMessage protocols keep changing upstream; defer the support-level decision ([[t-5ab57e6f]]). Its auth IS a reusable device-code flow (same shape as NousAuthFlow), but `hermes photon setup` also does interactive project/user registration + a Node sidecar `npm install`. (2) **MCP per-server `keepalive_interval`** editor — low value, deferred ([[t-07a9baa4]]). (3) **google-chat allowlist no-op + `google_chat` id rename** — pre-existing, same bug class as the WhatsApp fix; broader, tracked ([[t-2d6888ea]]). #deferred
- [migrate-nuance] `migrate xai --apply` exits 0 even when nothing to migrate / no changes written — Scarf now checks the output sentinels before claiming success (the button is gated on retired-model detection, so usually benign). #migrate
- [fact] Built on v0.17.0 audit findings (never documented as separate note); shipped in v2.12.0 as Hermes v0.17 catch-up release #hermes-v017

## Relations
- supersedes [[Hermes v0.16 Compatibility Decisions]]
- implements [[Hermes Capability Gating Pattern]]
- (no relation: a "Hermes v0.17.0 Audit Findings" note was never written — this decisions note is the surviving record of that audit)
- relates_to [[Hermes Release Audit Process]]
<!-- `t-aud32` is a TASK id, not a note; the `[[t-aud32]]` relation was dangling and is removed
     (round-4 memory audit, 2026-09-11). The flaky RemoteSQLiteBackend subprocess race it names is
     tracked in tasks, not in memory. -->
