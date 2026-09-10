---
id: t-00d04dcc
title: Audit P24: MCP OAuth and transport correctness
status: todo
added: 2026-09-09
---

## Description

Round-2 whole-surface audit phase P24. Source: `documents/hermes-v0.21.1-whole-surface-audit-round2.md`; brief: `documents/hermes-v0.21.1-parity-agent-brief.md`. Opus agent, tests that fail without the fix, fresh-eyes review, memory note. No HIGH findings — medium priority.

- MED · OAuth-token detection and "Clear Token" use the RAW server name, but Hermes stores tokens under `re.sub(r"[^\w\-]","_",name).strip("_")[:128]` — any name with a `.` or space (e.g. `github.com`) shows no token section and the delete targets a nonexistent path · `scarf/scarf/Core/Services/HermesFileService.swift:318,1002` · `tools/mcp_oauth.py:104-106,278-284`
- MED · The "SSE read timeout" editor field writes a key no Hermes version in the supported range reads — `_sse_transport` hardcodes `"sse_read_timeout": 300.0` and Hermes's own test asserts it stays 300 · `scarf/scarf/Features/MCPServers/Views/MCPServerEditorView.swift:218-224`, `HermesFileService.swift:588-596,1121` · `tools/mcp_tool_transport.py:351-352`; `tests/tools/test_mcp_sse_transport.py:109`
- MED · The boolish reader models the WORD sets but not `_parse_boolish`'s type gate: a bare YAML int falls through to the DEFAULT in Hermes, not to true/false. `enabled: 0` is ENABLED on Hermes (Scarf shows off); `supports_parallel_tool_calls: 1` is OFF on Hermes (Scarf shows on). Correct for `ssl_verify`, which bypasses `_parse_boolish` into httpx · `HermesFileService.swift:2155-2168`, used `:1118,:1128` · `tools/mcp_tool_common.py:124-137`, `mcp_tool_discovery.py:44,254`, `mcp_tool_registration.py:77`
- LOW · The remote reap's ERE `mcp login .*-- <name>$` is anchored but not owner-scoped (no `-u`): a second Scarf window or another user signing into the same server is killed too, and the `bash -lc` wrapper matches as well (the doc at `:212-213` assumes otherwise). ERE escaping itself is complete · `scarf/scarf/Features/MCPServers/ViewModels/MCPLoginController.swift:215-224,241-248`
- LOW · Device-prompt parse is not CRLF-tolerant (`.whitespaces` does not strip `\r`, so "Copy" copies a trailing `\r`) and `guard lines.count > 1` + `removeLast()` drops an unterminated final line, so a stream ending on the sentinel with no newline never completes. Latent under the current `-T`/pipe transports · `scarf/Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesMCPDevicePrompt.swift:73-77,90-93`
- LOW · Transport discriminator is case-insensitive in Scarf, exact in Hermes — `transport: SSE` renders as SSE in Scarf while Hermes sends it down the Streamable-HTTP path · `HermesFileService.swift:1107` · `tools/mcp_tool_transport.py:412`
- LOW · "Clear Token" deletes only `<name>.json`, leaving `.client.json`, `.meta.json` and `.cimd-off`; Hermes's `remove_oauth_tokens` clears the whole state set, and a stale DCR client registration is precisely what must be dropped · `HermesFileService.swift:1001-1009` · `tools/mcp_oauth.py:284-290,690-693`; `mcp_oauth_manager.py:174`

## Plan



## Artifacts



