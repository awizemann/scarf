---
id: t-0c0b1aa7
title: v0.21 platform adapters not in Scarf roster + Discord allowlist gap
status: done
added: 2026-09-02
---

## Description

Flagged by the 2026-09-02 WS-verify sweep, out of that sweep's scope: Hermes v0.21 (tag v2026.8.31) plugins/platforms/ contains irc, sms, wecom, raft, a2a, photon adapters that Scarf's gateway platform list (ends at buzz, v0.20-era) does not surface. Decide support level per platform (photon/iMessage already tracked in t-5ab57e6f). Also the documented KNOWN GAP: Discord has a real discord.allowed_channels (adapter confirmed at v0.21) still excluded from GatewayAllowlistKind.

## Plan



## Artifacts

Absorbed and closed by **t-2d39ff83** (Hermes v0.21.1 parity Phase 2, findings B4/B5), commit **70c564c5** on `feat/hermes-v0211-parity`.

Both halves of this ticket are resolved there:
- **Platform roster:** irc, sms, wecom and photon (plus dingtalk, weixin, qqbot, msgraph_webhook, api_server) are now in `KnownPlatforms.all`; `a2a` and `raft` were verified at tag v2026.9.7 and deliberately kept out (a2a is agent-to-agent infrastructure with `requires_env: []`; raft's whole config surface is one env var). A new `HermesV0211GatewayParityTests` roster gate scans the tagged `Platform` enum plus `plugins/platforms/` in both directions so the next addition can't go unnoticed.
- **Discord allowlist KNOWN GAP:** `discord` → `.channels` in `GatewayAllowlistKind`, `DiscordSetupView` wired to `GatewayBehaviorSection`, and `HermesConfig+YAML` reads `discord.allowed_channels` so the list round-trips.

Photon/iMessage (t-5ab57e6f) note: Scarf's `imessage` row was the BlueBubbles adapter under a non-existent Hermes id and was renamed to `bluebubbles`; `photon` is now its own row without a setup form. Setup forms for the newly-rostered platforms are spun out as **t-1ca040c2**.

