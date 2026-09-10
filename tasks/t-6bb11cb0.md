---
id: t-6bb11cb0
title: Audit P12: skills hub identifier/updates, MCP login stream, mcp test rows
status: done
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

Commit `7e8e5c41` on `fix/whole-surface-audit` (15 files, +901/-202).
Fixture provenance: `documents/audits/hermes-v0.21.1-p12-fixture-provenance.md`.
Memory: `scarf/decisions/hermes-v0-21-1-compatibility-decisions` → new H2
"Whole-surface remediation — P12".

All eight findings were REAL and all eight are PRE-existing. Every Hermes
shape touched is byte-identical back to `v2026.6.19` (v0.17), so no
capability flag was needed and no pre-target host changes rendering (C1).
No disputed findings.

## Shipped

1. **browse Identifier column** — `HermesSkillsHubParser.parseHubList` now
   requires the browse table's 8 split fields and reads `cells[6]` as the
   install identifier, keeping Name for display. `_ident_col` is
   `overflow="fold"` (`skills_hub.py:64-69`), a HARD character wrap, so
   Identifier continuation cells are CONCATENATED while Description
   continuation cells stay space-joined. A row with an empty Identifier is
   dropped rather than installed by Name. The `skills search` table (7
   fields, no `#`) still yields nothing, as its own drift test pins.
2. **Updates tab** — `parseUpdateList` rewritten around the real
   `Name | Source | Status` table (`skills_hub.py:806-808`). New
   `HermesSkillUpdateStatus` enum for the five words
   (`skills_hub_install.py:277-302`); the Status cell is the row key, so
   header/title/continuation rows are rejected and an UNKNOWN status word is
   dropped, never badged. `HermesSkillUpdate` now carries `source` + `status`
   instead of the two version strings Hermes has never printed (it compares
   content hashes). `SkillsViewModel.updates` holds only `update_available`;
   new `updateFaults` holds orphaned/unavailable/invalid_install, rendered as
   a faults section with Hermes's own remedy per status. Both Mac
   (`SkillsView`) and iOS (`UpdatesView`) updated.
3. **install `--`** — new `SkillsViewModel.installArgs(_:category:name:)`:
   flags first, then `--`, then the positional. Both call sites (hub install,
   URL install) go through it.
4. **device-prompt partial line** — `HermesMCPDevicePrompt.parse` drops
   everything after the LAST newline and requires the block's own trailing
   `Waiting for approval...` sentinel (`completionSentinel`). Hermes writes
   all three lines in ONE `print` (`mcp_oauth_device.py:125-126`), so the
   sentinel makes the block atomic. The false doc claim at the old :41-43
   ("a partial read returns nil rather than a half-built prompt") is replaced
   with the real rule and the failure it hid.
5. **flush + remote stop** — `decoder.flush()` is appended at EOF in
   `MCPLoginController`'s readabilityHandler. For remote stop: verified
   `SSHTransport.makeProcess` hard-codes `-T` for every consumer and that
   `composedRemoteCommand` quotes every token through `remotePathArg`, so
   NEITHER `ssh -tt` nor a shell wrapper is safely available (see the
   DELIBERATE NO-OP note below). Chosen fallback: `reapRemoteLogin` runs a
   best-effort `pkill -f "mcp login .*-- <escaped server>$"` over the same
   transport, off-main with a 10 s timeout (C10), logged and never surfaced.
   `regexEscaped` escapes every ERE metacharacter in the user-chosen server
   name. `runningServer` is cleared in `finish()` so a natural exit costs no
   SSH round trip.
6. **mcp test tool rows** — `parseToolListFromTestOutput` anchors on
   `Tools discovered: N` (`mcp_config.py:616`) and reads the
   `    {name:36s} {desc}` rows below it (`:49-52`, width/desc_max from
   `:619`). The count bounds the block; anchoring BELOW the count excludes
   the four-space-indented masked auth-header line at `:605`. ANSI is
   stripped defensively (CSI + OSC).
7. **boolish** — new `HermesFileService.boolish` / `boolishOptional` mirror
   `_parse_boolish` ({true,1,yes,on}/{false,0,no,off}, unquote +
   inline-comment strip first). Applied to `enabled`,
   `supports_parallel_tool_calls`, `tools.resources`, `tools.prompts`.
   **Also fixed the DEFAULT**: resources/prompts default to TRUE when absent
   (`mcp_tool_registration.py:77`); defaulting them to false made the editor
   show two toggles off for every server that had never set them, and one
   save then wrote the `false` the user never chose.
8. **SSE glyph / clear token / citation** — both glyph sites are now
   `== .stdio ? "terminal" : "network"`; a failed "Clear Token" routes into
   `saveError`; `mcp_config.py:56` → `:36`, tag `v2026.8.31` → `v2026.9.7`.

## Deliberate NO-OP (documented, not guessed)

`ssh -tt` was NOT adopted for finding 5. Two blockers, both verified:
`SSHTransport.makeProcess` (`SSHTransport.swift:693-716`) inserts `-T`
unconditionally for every consumer (ACP JSON-RPC, log tails) which need a
binary-clean stream; and a pty would flip
`hermes_cli/colors.py::should_use_color()` (= `sys.stdout.isatty()`) ON for
the remote command, adding ANSI to every `✓`/`✗` line and making Rich wrap at
the pty's 80 columns — folding the verification URL the sheet exists to show.
That is a user-visible change on a remote host for a stop-path fix, which C1
forbids. A shell wrapper watching stdin EOF is impossible by construction:
`composedRemoteCommand` quotes every token, so no caller can inject a shell
operator (by design, and worth keeping). Residual gap: `pkill` may be absent
on a minimal remote (exit 127, logged only), and the pattern would also match
a `hermes mcp login` for the SAME server started by hand on that host.

## Tests (all new ones fail without their fix)

New: 8 in `SkillsHubParserTests` (verbatim browse + check fixtures rendered
from the tagged column specs through Hermes's own Rich at width 80 — the
width at which the Identifier column folds), 1 in
`HermesV0204SkillsParityTests` (install argv), 3 in `HermesMCPOAuthFlowTests`
(unterminated code line, byte-wise accumulation, regex escaping), 5 in
`SectionAuditF5ManageAppTests` (mcp test rows, masked-header exclusion, zero
tools, count bound, ANSI), 3 in `HermesMCPServerV0204RegressionTests`
(boolish enabled, boolish + default-true resources/prompts, helper).

Results: ScarfCore `swift test` **2427 passed / 0 failed**; app target
`-only-testing:scarfTests` **886 passed / 0 failed**. No flaky reruns were
needed — `ACPClientStartIdempotenceTests`, `ScarfMiniAppBridgeTests` and the
`BotConversationTests` fallback test all passed in the full parallel runs.
Builds: macOS `scarf` and iOS `scarf mobile` both BUILD SUCCEEDED.

## Fresh-eyes audit of own diff — found and fixed

* `checkTableHeaderRowIsNotAnUpdate` originally used `┃` (the header glyph),
  which the parser rejects for the wrong reason — a checkbox test. Rewritten
  to also assert the `│` form and an empty-status continuation row.
* The `installArgs` doc comment was spliced between `updateAllArgs`'s
  existing doc and its declaration, orphaning it. Reordered.
* `HermesMCPDevicePrompt`'s type-level doc still repeated the parse rules it
  no longer describes; deduped, and the stale
  `HermesMCPDevicePromptTests` reference corrected to `HermesMCPOAuthFlowTests`
  (the suite that actually pins the fixture).
* `stop()` would have paid an SSH round trip reaping an already-exited
  process, because `process` is not cleared in `finish()`; `runningServer` is
  cleared there instead.
* First cut of `stripANSI` carried a `pending` variable that was always nil.

## Notes for the next cycle

* `mcp list`'s own renderer uses a NARROWER bool set ({true,1,yes},
  `mcp_config.py:575-577`) than `_parse_boolish`. A client models the
  GATEWAY's behaviour, not the list renderer's.
* `parseToolListFromTestOutput` was made internal (from private) to give the
  drift test a seam, matching `mcpTestReportsFailure` next to it.

