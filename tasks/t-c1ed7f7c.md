---
id: t-c1ed7f7c
title: Decide 0.18 update-nudge + prep v2.17 release (local models + session-layer)
status: done
added: 2026-07-14
---

## Description

Two open decisions from the 2026-07-14 close, awaiting Alan (release now planned — "a few tweaks" then cut). (1) 0.18 floor decision — UNDER ACTIVE INVESTIGATION (blast-radius scoping dispatched 2026-07-14); Alan leaning toward hard-stop to capture ACP data-loss fix + approval-race + aux-alias. See decision note decision-chat-transport-stays-acp-min-hermes-to-0-18. (2) v2.17 (or v3.0 if 0.18 floor) release prep: batch = local models end-to-end + session-layer overhaul (4 defect classes) + settings-parser fix + composer vision heads-up + banner Choose-model + 2 upstream contributions (issue #64144/PR #64146, comment on #56448). RELEASE-NOTES CAVEAT (must mention): local-model users on Hermes <0.18 (and until aux-alias PRs #56448/#62239 merge+release) get DEGRADED auxiliary features — title generation, compression, and vision routing fall back to cloud providers or fail, because Hermes's aux resolver lacks the local provider aliases its main resolver has. Frame honestly in notes. 23 app commits ahead of origin, unpushed.

## Plan



## Artifacts

Superseded by events: repo now tracks Hermes v0.21 (memory: hermes-v0-20/v0-20-4/v0-20-5 compatibility decisions, post-v2-24 backfill decisions) — the 0.18 floor decision and v2.17 release both resolved and shipped in intervening releases. Closing as stale; nothing left to execute.

