---
id: t-6bb11cb0
title: Audit P12: skills hub identifier/updates, MCP login stream, mcp test rows
status: todo
added: 2026-09-08
priority: high
---

## Description

From documents/hermes-v0.21.1-whole-surface-audit.md (class 4). Brief: documents/hermes-v0.21.1-parity-agent-brief.md. Fixtures must come from the tagged Hermes emitters (skills_hub.py, mcp_config.py, mcp_oauth_device.py at v2026.9.7), rendered through Rich where the emitter is a Rich table.
1. HermesSkillsHubParser.swift:70-83: browse installs by Name; read the Identifier column (cells[6], `_ident_col` overflow="fold" so merge continuation rows) as the identifier, keep Name for display. skills_hub.py::_render_browse_page.
2. HermesSkillsHubParser.swift:162-185 parseUpdateList hunts for `→` arrows; `skills check` prints Name | Source | Status with status ∈ update_available/up_to_date/orphaned/unavailable/invalid_install (tools/skills_hub_install.py::check_for_skill_updates). Parse the Status column.
3. SkillsViewModel.swift:555,582: `--` before identifier/url on install (flags before `--`).
4. HermesMCPDevicePrompt.swift:47,60-63 + MCPLoginController.swift:176-178: only consider newline-terminated lines; keep re-parsing until the `Waiting for approval...` sentinel; fix the false doc claim at :41-43.
5. MCPLoginController.swift:109-112: call `decoder.flush()` at EOF and append. :146-159: on remote contexts allocate a TTY (`ssh -tt`) or wrap so the remote `hermes mcp login` dies with the connection; verify SSHTransport supports it.
6. HermesFileService.swift:817-830 parseToolListFromTestOutput: rows are `    {name:36s} {short}` with ANSI (mcp_config.py:49-52); strip ANSI and parse, or read `Tools discovered: N`.
7. HermesFileService.swift:987-988,1161-1164: boolish parse for `enabled`/`tools.resources`/`tools.prompts` per mcp_tool_common.py:120-137 (_TRUE_WORDS/_FALSE_WORDS).
8. MCPServersView.swift:244, MCPServerDetailView.swift:56: SSE glyph (`== .stdio ? "terminal" : "network"`). MCPServerEditorView.swift:414: route Clear Token failure into saveError. HermesFileService.swift:801 stale citation → mcp_config.py:36.

## Plan



## Artifacts



