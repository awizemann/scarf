---
title: Hermes Peer CLI Surface
type: note
permalink: scarf/architecture/hermes-peer-cli-surface
tags: [hermes, peer, bot-mode, cli, wire-format]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesPeerCLI.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesBotPeersYAML.swift]
source_paths_inferred: false
source_sha: 7f68d5296a4f01dd95b4aa3dcfa3d971370fd97e
created: 2026-09-01
updated: 2026-09-01
reviewed: 2026-09-01
reviewed_by: audit:claude-code (background)
---

Wire shapes of `hermes peer` (Hermes v0.21+, `hermes_cli/subcommands/peer.py`), as ported by `HermesPeerCLI`. A peer is another Hermes gateway running the `api_server` platform; the CLI adds no server surface of its own — it drives the peer's stock REST API. Targets are `<peer>` or `<peer>/<agent>`, the latter hitting the peer's `/p/<profile>/` multiplex mirror.

`dm` and `run` are the same remote turn, synchronous vs. asynchronous: both resolve the peer's canonical hidden "Bot Chat" session (exact-title + `include_hidden=1` lookup, created when missing), then either `POST /api/sessions/{id}/chat` (dm, 600s budget) or `POST /v1/runs` with an `Idempotency-Key` header (run). `status`/`stop` are `GET`/`POST` on `/v1/runs/{id}[/stop]`.

`--json` payloads:
- dm → `{peer, profile, session_id, reply}` (`profile` is JSON null for a bare target; `reply` may be `""`).
- run → `{peer, profile, session_id, run_id, status, idempotency_key, replayed}` — `idempotency_key` is echoed back and is generated as `peer-<uuid4hex>` when the caller omits `--idempotency-key`.
- status/stop → `{peer, profile}` merged over the peer's raw run body, so the key set is the peer's, not the CLI's; only `status`/`output`/`error` are contractual, and `status` defaults to `"unknown"` when absent.

## Observations
- [gotcha] `peer run` prints a restart-durability warning to STDERR on the ordinary success path (whenever the peer's /v1/capabilities omits features.runs_idempotency.durable, including every peer too old to have the endpoint) — success must be judged by exit code alone, never by empty stderr #hermes-v0-21
- [gotcha] The HTTP 400 from _ensure_bot_chat becomes a RuntimeError whose sentence IS the remedy (peer's hermes-agent too old; unhide via PATCH /api/sessions/<id>) and reaches callers only as stderr text, framed differently per verb — so peer failures must surface stderr verbatim, never paraphrased #hermes-v0-21
- [fact] Exit codes are 0 ok / 1 delivery-or-peer error / 2 usage; a run that FAILED remotely still exits 0 with {"status":"failed","error":…}, which is a successful invocation carrying a remote failure #hermes-v0-21
- [constraint] A peer's API_SERVER_KEY lives in ~/.hermes/.env as HERMES_PEER_<NAME>_KEY (uppercase, hyphens to underscores), never in config.yaml — so Scarf reads the registry from config.yaml's bot_peers: map and models only name/url/note, and registration stays a CLI act #security
- [fact] There is no verb to re-enumerate peer runs: the run_id returned by `peer run` is the only handle, so any UI tracking runs must persist them itself #hermes-v0-21

## Relations
- relates_to [[Hermes v0.21 Compatibility Decisions]]
- relates_to [[Hermes v0.21.0 Audit Findings]]
- implements [[Hermes Capability Gating Pattern]]
