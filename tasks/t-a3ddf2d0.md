---
id: t-a3ddf2d0
title: R01 MCP: tools blocklist round-trip, OAuth add, timeouts, remote login
status: done
added: 2026-09-26
priority: urgent
---

## Description

Findings S09-F1 (P0), S09-F2 (P0), S09-F3, S09-F4, S09-F5, S09-F6. Wave 1. Branch fix/hermes-v0215-audit-r01, worktree Scarf-wt/r01.

## Plan

R01 MCP (worktree Scarf-wt/r01, branch fix/hermes-v0215-audit-r01)
- S09-F1: fix tools.include/exclude parser (sibling keys at indent 6 re-dispatch to tools); writer omits empty include half. Tests: Scarf write→Scarf read→Hermes parse round-trip (run Hermes mcp_tool_registration filter via v0215 .venv on scratch HERMES_HOME).
- S09-F2: catalog entries → `hermes mcp install <id>` gated on true floor (git tag --contains); custom/preset OAuth → direct YAML write of url+auth: oauth (+ transport), then offer `mcp login`. Older hosts keep old path (C1).
- S09-F3: parse timeout/connect_timeout as Double, preserve untouched keys on editor save.
- S09-F4: remote login defaults to device flow when server allows; add paste-URL path writing redirect to the login process stdin.
- S09-F5: force reload after sign-in success.
- S09-F6: mcp test timeout = max(30, connect_timeout)+20.
Blast radius: HermesFileService MCP region, HermesMCPAdd, MCPServersViewModel, MCPServerEditorViewModel, MCPLoginController/Sheet, MCPServersView (Mac only; no iOS MCP surface), local+remote.
Tests: ScarfCore/app MCP suites incl. round-trip; update tests pinning wrong behaviour.
Memory/wiki: MCP notes (tools filter, add flow, oauth login, catalog), wiki MCP pages.

## Artifacts

Merged into fix/hermes-v0215-audit as 5e46e862 (034666e9..325c8f14, 8 commits). Orchestrator audit: diff reviewed (OAuth add path off-main, failure guarded before sign-in offer, C1 gates hasMCPOAuthAddNeedsDirectWrite@0.17.0 / hasMCPEmptyIncludeWhitelist@0.20.6); ScarfCore 3788/3788 on integration. Full scarfTests 1621 green (agent). Two fresh-eyes reviews, 13 items fixed. Residual: pre-0.20.6 detail view shows "(all)" for a blank include item (display only).

