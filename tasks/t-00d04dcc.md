---
id: t-00d04dcc
title: Audit P24: MCP OAuth and transport correctness
status: done
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

Shipped as one commit on `fix/whole-surface-audit-r2`: **e4bf9653** `fix(mcp): find the OAuth token where Hermes actually puts it, and stop offering a knob that does nothing`.

## Per finding

**MED · OAuth token path — FIXED.** New `ScarfCore/Services/HermesMCPOAuthPaths.swift` ports `_safe_filename` (`tools/mcp_oauth.py:104-106` @ v2026.9.7) over **unicode scalars**, not Characters: Python's `\w` in str mode is `L* ∪ N* ∪ _` (CPython `SRE_UNI_IS_WORD` = `Py_UNICODE_ISALNUM || '_'`), and both the substitution and `[:128]` count code points. Expectations captured by running the real expression under CPython (20-row table in the ScarfCore suite) — the decomposed `cafe` + U+0301 row is the one a Character-based port gets wrong. Tag walk: `_safe_filename` present from **v2026.4.8 (v0.8.0)**, below every floor Scarf models, so no capability gate; v0.7.0 and older stored RAW, so detection probes BOTH spellings (sanitized first) per C1, and the legacy spelling is dropped when it carries `/`/`\`/`.`/`..` so a DELETE can never escape `mcp-tokens/`.

**LOW · Clear Token — FIXED.** `deleteMCPOAuthToken` now unlinks the whole state set `remove_oauth_tokens` → `HermesTokenStorage.remove` unlinks (`mcp_oauth.py:690-693`, `:391-394`, suffixes at `:284-287`): `.json`, `.client.json`, `.meta.json`, `.cimd-off`, tokens first. Tag walk for each sidecar: `.client.json` from v2026.4.8 (v0.8.0), `.meta.json` from v2026.6.19 (v0.16.0), `.cimd-off` from v2026.8.19 (v0.20.5). No gate needed — both transports' `removeFile` is already `rm -f`-shaped (`LocalTransport.swift:207-214` has a `fileExists` guard; `SSHTransport.swift:636` literally runs `rm -f`), so a sidecar an older Hermes never wrote is a no-op.

**MED · SSE read timeout — FIXED (removed).** Walked all 32 `v2026.*` tags: `sse_read_timeout` appears from v2026.5.7 and is a hard-coded literal `300.0` at every single one (`tools/mcp_tool.py:1323` → `mcp_tool_transport.py:352` after the v0.21.1 modularisation); there is **no** `config.get("sse_read_timeout")` in any tag, and Hermes's own suite pins it (`tests/tools/test_mcp_sse_transport.py:109,140`). Removed the editor field, the add-custom field, the detail row, `setMCPServerSSETimeout`, and the `sseReadTimeout:` parameter on `addMCPServerSSE`/`addCustomSSE`. The **parse is kept** (documented as inert on `HermesMCPServer.sseReadTimeout`) so an existing key is never rewritten — note the old writer's nil arm actively `removeScalar`'d it from the user's file.

**MED · `_parse_boolish` type gate — FIXED.** `boolishOptional` now gates on the raw scalar BEFORE unquoting: anything PyYAML retypes to non-`str`/non-`bool` returns nil → per-key default, per `tools/mcp_tool_common.py:124-137`. So `enabled: 0` is ENABLED, `supports_parallel_tool_calls: 1` is nil/"Hermes decides", and `tools.resources/prompts: 0` stay true; quoted `"0"`/`'off'` are still false. Implemented by splitting PyYAML's bool resolver out of `YAMLScalar.resolvesToNonString` into a new `YAMLScalar.resolvesToBool` (writer behaviour unchanged — `resolvesToNonString` consults both). `ssl_verify` untouched: it never reaches `_parse_boolish` and stays a `String?` (pinned by a test).

**LOW · Transport discriminator — FIXED.** Now `unquote(fields["transport"]) == "sse"`, exact-case, matching `mcp_tool_transport.py:412`. Side benefit found while testing: the old `.lowercased()` compare also failed to match `"sse"` / `'sse'`, which PyYAML loads as the same string — both now work.

**LOW · Remote reap ERE — PARTIALLY FIXED, one half is a NO-OP with evidence.**
- *Owner scoping: FIXED.* `pkill -u <uid> -f <pattern>`, uid from an `id -u` probe over the same transport (not a guess at the SSH username — `~/.ssh/config` `User` can rewrite it), and the reap is ABANDONED rather than run unscoped if the probe fails. `-u` is an effective-uid restriction on both platforms Scarf reaches (macOS `pkill(1)` "`-u euid` … effective user ID", verified from the local man page; Linux procps `-u, --euid`), so one argv is correct on either.
- *"the `bash -lc` wrapper matches as well": **NO-OP — the finding is WRONG.*** `SSHTransport.composedRemoteCommand` runs every token through `remotePathArg`, which double-quotes **unconditionally** (`SSHTransport.swift:303-322`), so the wrapper's command line ends `… "--" "github.com"` — a literal `"` after the name — while the `env`/`hermes` it execs has had the quotes removed by the shell. The existing `$` anchor already excludes the wrapper. Rather than "fixing" a non-bug I pinned it: `reapPatternDoesNotMatchTheBashWrapper` runs the pattern against the real composed wrapper string with the real `grep -E` (not `NSRegularExpression`), so if `remotePathArg` ever stops quoting, the test says so. ERE escaping was already complete and is also now pinned (`a.c` must not match `abc`, `github` must not match `github-enterprise`).

**LOW · Device prompt — FIXED, plus a bug the finding did not reach.** `.whitespaces` → `.whitespacesAndNewlines` everywhere, and an unterminated final line that IS the sentinel now completes the block. The finding's CRLF half was *understated*: trimming alone would not have fixed it, because Swift treats `\r\n` as a SINGLE grapheme cluster, so `split(separator: "\n")` does not see a CRLF break **at all** — a CRLF stream came through as one line and nothing matched. CRLF is now normalised before the split (same trap `YAMLScalar.containsLineBreak` documents from P19). Partial-block latching is re-pinned in both line endings.

## Tests

New: `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/HermesP24MCPOAuthAndPromptTests.swift` (12 tests / 47 cases) and `scarf/scarfTests/MCPOAuthAndTransportP24Tests.swift` (18 tests / 51 cases, incl. one source-scan guard for the owner-scoped reap per the repo's `unguarded-write-seam` convention, since it needs a live remote host to drive).

Revert-check: with the four production changes reverted in place, 7 of the Mac tests fail with 15 issues (token detection, clear-token sidecars, both boolish directions, `tools:` defaults, and transport case BOTH ways). Restored and green.

Updated one EXISTING test that encoded the old wrong belief: `HermesMCPServerV0204RegressionTests.boolishHelperMirrorsHermesWordSets` asserted bare `1` → true and bare `0` → false. It now asserts the quoted spellings for the word sets and the default-wins behaviour for bare digits. `ConfigYAMLScalarQuotingTests.transportStampFailureIsObservable` used `setMCPServerSSETimeout` purely as a stand-in for "the patcher returns false"; re-pointed at `setMCPServerTimeouts` on the same seam.

Full runs: ScarfCore 2586/2586 pass (one run had 4 `ACPClientStartIdempotenceTests` issues under full parallel load — green in isolation, and a second full run was clean). scarfTests: ~18 known-flaky parallel-load failures in the ACP/chat/bot suites, every one green when the suite is run in isolation; all MCP/YAML/config suites clean in both modes.

## Out of phase
Created **t-1d25d4d5** — stale Hermes citations in `HermesMCPDevicePrompt.swift`, `MCPLoginController.swift` and `GatewayViewModel.swift` (audit round-2 line 102, unassigned).

