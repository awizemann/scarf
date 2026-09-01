---
id: t-f25aa0b3
title: v0.21 W4: MCP catalog regeneration
status: done
added: 2026-09-01
priority: high
---

## Description

Regenerate OptionalMCPCatalog.swift:73-214 from v2026.8.31 optional-mcps/*/manifest.yaml (20→65 entries; 45 new, all transport http). Fix dead Atlassian URL (/v1/sse → https://mcp.atlassian.com/v1/mcp/authv2). Model new manifest key tools.default_excluded (mutually exclusive with default_enabled; 25 entries use it) — HermesMCPServer.toolsExclude already exists, wire catalog→install path. Keep Blender excluded. Update catalog tests. Source: ~/.hermes/hermes-agent-v0.21.0-audit/optional-mcps/ and hermes_cli/mcp_catalog.py:116-124,291-306,689-701.

## Plan



## Artifacts



