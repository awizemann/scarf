---
title: Contributing to hermes-agent: dev env, test-runner traps, and how ACP _meta is delivered
type: note
permalink: scarf/operations/contributing-to-hermes-agent-dev-env-test-runner-traps-and
tags: [hermes, upstream, testing, acp]
created: 2026-09-21
updated: 2026-09-21
---

Learned 2026-09-21 while re-implementing PR #45958 (ACP per-session toolset scoping) in the hermes-agent fork clone. Complements the submission-contract note, which covers mechanics/attribution but not the local environment or the ACP wire details.

## Observations
- [gotcha] Two concurrent `scripts/run_tests.sh` runs on ONE checkout corrupt each other: a tests/hermes_cli file rewrites the repo venv and pytest vanished mid-run ('No module named pytest'), producing phantom FAILEDs. Run one slice at a time; reinstall dev extras if pytest disappears. #test-runner
- [fact] Working dev env for the clone: `uv venv .venv` then `uv pip install -e '.[dev,acp]'`; run_tests.sh probes $REPO_ROOT/.venv and requires pytest IMPORTABLE (an existence-only venv is skipped). CI lint parity: `ruff check` (blocking) plus `ty check` (advisory diff vs base, so keep the per-file diagnostic count from rising). #dev-env
- [gotcha] ACP `_meta` is NOT a handler kwarg: acp/router.py::_make_func splats every `_meta` key into the handler's **kwargs, so `_meta.toolsets` arrives as kwargs['toolsets']. A top-level field of the same name is DROPPED by the pydantic request model (no extra=allow), so spec `_meta` is the only usable extension channel. #acp-wire
- [convention] hermes-agent namespaces its OWN ACP `_meta` output under `_meta.hermes` (acp_adapter/provenance.py -> `_meta.hermes.sessionProvenance`). A new INBOUND `_meta` extension should follow it (`_meta.hermes.<key>`, arriving as kwargs['hermes']['<key>']) — a bare `_meta.<key>` splats into the handler's kwargs at top level and can collide with a real handler parameter or a future spec field. #acp-wire
- [gotcha] ACP session construction runs off the event loop on purpose (#58083 + tests/acp_adapter/test_session_construction_off_loop.py). Anything you add IN FRONT of it in a session/new|load|resume handler — validation, config reads, plugin discovery — runs ON the loop unless you also wrap it in `asyncio.to_thread`. `toolsets.validate_toolset` and `hermes_cli.plugins.discover_plugins` are both blocking. #acp-loop
- [convention] Upstream rejects the "fall back to the default when the request is empty or unparseable" pattern: it defeats an explicit contract and silently WIDENS capability (maintainer review on PR #70326). For a present-but-unusable parameter, raise invalid_params; only an ABSENT key may mean "no selection". #acp-errors
- [gotcha] `hermes acp`'s `-t/--toolsets` must use `default=SUPPRESS` (like the `chat` subparser) because hermes_cli/main.py reads a TOP-LEVEL `args.toolsets` (default=None) to set the MCP server spawn filter; a non-SUPPRESS subparser default would clobber `hermes -t … acp`. #toolsets
- [convention] ACP handlers report a bad parameter as RequestError.invalid_params({'details': ...}) (-32602); that is the established upstream shape (see set_session_model, #72439). #acp-errors
- [fact] `hermes chat --toolsets` does NOT validate names (cli.py comma-splits and passes through); only `-z/--oneshot` validates via toolsets.validate_toolset. Match the sibling surface rather than inventing validation for a CLI flag. #toolsets

## Relations
- relates_to [[Hermes upstream submission pattern — clean issue/PR contract]]
