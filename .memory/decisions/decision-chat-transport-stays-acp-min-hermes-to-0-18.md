---
title: Decision: chat transport stays ACP; min-hermes to 0.18 (proposed)
type: note
permalink: scarf/decisions/decision-chat-transport-stays-acp-min-hermes-to-0-18
created: 2026-07-13
updated: 2026-07-14
---

Status: PROPOSED (recommendation from the 2026-07-13 architecture review; awaiting Alan's confirmation).

## Observations
- [fact] There is NO new standalone Hermes API. What exists (verified in v2026.7.7.2 = 0.18.2 source via git tags at ~/.hermes/hermes-agent): `gateway/platforms/api_server.py` — an aiohttp OpenAI-compatible API that runs only inside a resident `hermes gateway`, requires API_SERVER_ENABLED + bearer API_SERVER_KEY, binds 127.0.0.1:8642, streams via SSE with NO replay (the run stream is destroyed on client disconnect — `_handle_run_events` finally-block pops the queue). Shares SessionDB (state.db) with ACP. #api
- [decision-input] Migrating chat to it would break Scarf's load-bearing "SSH is all you need" contract: every server would need a provisioned resident gateway + bearer secret + tunnel (ssh -L on Mac, Citadel direct-tcpip on iOS), and its no-replay SSE reproduces the exact disconnect-loses-deltas pain that motivated the question. Blast radius: ~6,500 LOC ACP stack (ACPClient, channels, RichChatViewModel, iOS SSHExecACPChannel) + permission/model/cancel flow remapping. #cost
- [decision-input] Two of three motivating pains are Scarf-side (ControlMaster staleness gh#123 class; the four session-layer defects in [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]). The third (in-flight turn dies with the process) is real for ACP but the API only half-fixes it (run survives; deltas still lost on disconnect). #whose-fault
- [decision-input] Hermes 0.18's ACP adapter contains a DATA-LOSS fix (acp_adapter/session.py replace_messages was deleting compression-archived history rows — including after model switch) and a concurrent-session approval-race fix (HERMES_INTERACTIVE → contextvar, GHSA-96vc-wcxf-jjff). A min-hermes 0.18 bump buys both with zero migration. #upstream
- [recommendation] Stay on ACP as the chat transport. Make the v3/breaking move a min-hermes >= 0.18.0 requirement (for the ACP fixes), fix the four Scarf-side defects, and treat the gateway API as a later optional capability-gated enhancement (e.g. attach-to-background-run where a gateway is detected — cheap because SessionDB is shared). #recommendation

## Relations
- relates_to [[Chat session layer — mechanism map and 2026-07-13 diagnosis (four confirmed defects)]]
- relates_to [[Multi-Server Architecture (Scarf 2.0+)]]


## 0.18 hard-floor — MEASURED blast radius (2026-07-14)
- [fact] The "big v0.6-back sweep" fear was WRONG on mechanism: oldest VERSION gate in HermesCapabilities.swift is v0.12; everything below is ONE inverse gate (hasFlushMemoriesAux) + schema self-detection. 97 capability accessors, version-bucketed (15@0.12, 25@0.13, 25@0.14, 15@0.15, 6@0.16, 6@0.17, 3@0.18). #inventory
- [fact] Floor's MANDATORY cost is small (~tens of lines: one connect gate + a "too old" UI). The "delete old gates" prize (~475 lines in HermesCapabilities.swift + 147 call sites across ~66 files) is LARGE but ENTIRELY OPTIONAL — gates work as always-true constants — and available TODAY without any floor. 32 accessors are already dead (zero call sites) regardless. #cost
- [fact] Floor saves ZERO work on the schema-detection data layer (messages.active/compacted + rewind_count, PRAGMA-probed in both SQLite backends, ~10 sites in HermesDataService) — that's the load-bearing "handle old Hermes" code and it self-adapts by design (even v0.18's own new column is schema-detected). #schema-detect
- [gotcha] THE REAL RISK is reliability, not LOC: version is a best-effort side-probe (hermes --version, Task.detached, 10s timeout, NOT persisted, failure→.empty→all flags false), the ACP handshake carries NO version (protocolVersion:1 only), and there are ≥4 uncached --version probes. Today unknown=hide-features (FAIL-SAFE). A hard connect-block INVERTS this to FAIL-DANGEROUS: a slow disk/PATH hiccup → nil semver → falsely blocks a working host OR fails open. A floor needs a reliable connect-time version read built FIRST (t-<version-read>). #reliability
- [decision] RECOMMENDATION (grounded, committed): do NOT hard-floor for this release. The floor does not FIX the upstream ACP data-loss/approval bugs (Scarf can't patch Hermes persistence — a floor only refuses old hosts; users get fixes by updating Hermes regardless), buys no cleanup that isn't already floor-independent, and its actual cost is inverting a fail-safe posture into fail-dangerous atop an unreliable probe. Address the user-visible pain (aux degradation/vision) with cheap targeted tweaks (vision detection t-d25e68cc + a fail-safe soft update-nudge) instead. Revisit a hard floor as a deliberate v3.0 AFTER building reliable connect-time version detection AND after aux-alias PRs ship — so it delivers "local models just work" not "…work IF you also updated." #recommendation
