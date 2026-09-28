---
title: Hermes Peer CLI Surface
type: note
permalink: scarf/architecture/hermes-peer-cli-surface
tags: [hermes, peer, bot-mode, cli, wire-format]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPeerCLI.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesBotPeersYAML.swift]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-01
updated: 2026-09-26
reviewed: 2026-09-27
reviewed_by: audit:claude-code (background)
---

Wire shapes of `hermes peer` (Hermes v0.21+, `hermes_cli/subcommands/peer.py`), as ported by `HermesPeerCLI`. A peer is another Hermes gateway running the `api_server` platform; the CLI adds no server surface of its own — it drives the peer's stock REST API. Targets are `<peer>` or `<peer>/<agent>`, the latter hitting the peer's `/p/<profile>/` multiplex mirror.

`dm` and `run` are the same remote turn, synchronous vs. asynchronous: both resolve the peer's canonical hidden "Bot Chat" session (exact-title + `include_hidden=1` lookup, created when missing), then either `POST /api/sessions/{id}/chat` (dm, 600s budget) or `POST /v1/runs` with an `Idempotency-Key` header (run). `status`/`stop` are `GET`/`POST` on `/v1/runs/{id}[/stop]`.

`--json` payloads:
- dm → `{peer, profile, session_id, reply, delivery}` where `delivery` indicates the outcome: `replied` (turn completed), `queued(status:)` (v0.21.4+, peer's Bot Chat open in Desktop, message queued), or `stillRunning(notice:)` (v0.21.4+, peer accepted but turn exceeded timeout). On pre-v0.21.4, delivery is always `replied`. The `reply` field is empty unless delivery is `replied`.
- run → `{peer, profile, session_id, run_id, status, idempotency_key, replayed}` — Scarf generates `idempotency_key` as `scarf-<uuid>` via `HermesPeerCLI.newIdempotencyKey()` if the caller omits `--idempotency-key`.
- status/stop → `{peer, profile}` merged over the peer's raw run body, so the key set is the peer's, not the CLI's; only `status`/`output`/`error` are contractual, and `status` defaults to `"unknown"` when absent.

## Observations
- [gotcha] `peer run` prints a restart-durability warning to STDERR on the ordinary success path (whenever the peer's /v1/capabilities omits features.runs_idempotency.durable, including every peer too old to have the endpoint) — success must be judged by exit code alone, never by empty stderr #hermes-v0-21
- [gotcha] The HTTP 400 from _ensure_bot_chat becomes a RuntimeError whose sentence IS the remedy (peer's hermes-agent too old; unhide via PATCH /api/sessions/<id>) and reaches callers only as stderr text, framed differently per verb — so peer failures must surface stderr verbatim, never paraphrased #hermes-v0-21
- [fact] Exit codes are 0 ok / 1 delivery-or-peer error / 2 usage; a run that FAILED remotely still exits 0 with {"status":"failed","error":…}, which is a successful invocation carrying a remote failure #hermes-v0-21
- [constraint] A peer's API_SERVER_KEY lives in ~/.hermes/.env as HERMES_PEER_<NAME>_KEY (uppercase, hyphens to underscores), never in config.yaml — so Scarf reads the registry from config.yaml's bot_peers: map and models only name/url/note, and registration stays a CLI act #security
- [fact] There is no verb to re-enumerate peer runs: the run_id returned by `peer run` is the only handle, so any UI tracking runs must persist them itself #hermes-v0-21

- [gotcha] `peer dm`'s 600 s DM_TIMEOUT_S is a per-socket read timeout that starts only AFTER up to two 30 s LIST_TIMEOUT_S requests (Bot Chat lookup + optional create POST, peer.py:29,111,123-125 @ v2026.9.21) plus Python/SSH startup — so any Scarf process cap can still fire after the peer accepted the message. On v0.21.4+ Scarf uses `HermesPeerCLI.dmProcessTimeout()` which returns 720 s for peers with `HermesCapabilities/hasPeerDMNoResendOutcomes`, and treats its OWN `TransportError.timeout` (exit -1, detected via `HermesPeerCLI.isLocalDMTimeout()`) as "may already be delivered — check Bot Chat, don't resend" with `DMResult.Delivery.stillRunning(notice:)`; pre-v0.21.4 keeps the failure and uses 600 s #hermes-v0-21-4
- [gotcha] `peer run` may outlast its process cap (120 s at peer.py:65-67 @ v2026.9.21, four sequential LIST_TIMEOUT_S requests + POST, plus Python/SSH startup) without creating a run, but may also create one before Scarf's cap fires. When a run fails, use `HermesPeerCLI.runFailureMayHaveCreatedRun(exitCode:stderr:)` to decide whether the `--idempotency-key` is safe to reuse on retry: true only for Scarf's own timeout (via `isLocalDMTimeout()`) or the peer's unreachability message, which are the only ambiguous cases #hermes-v0-21-4

## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
- implements [[Hermes Capability Gating Pattern]]
