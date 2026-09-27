# S09-mcp — verdict: WORKS-WITH-ISSUES

Hermes reference: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (installed `hermes` 0.21.5, Python 3.11).
Paths below: `HFS` = `scarf/scarf/Core/Services/HermesFileService.swift`; `H:` = Hermes worktree.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List servers (stdio / http / sse; enabled, OAuth badge) | DEGRADED | F1 (tools filters misread), F3 (float connect_timeout shows blank) |
| 2 | Add from catalog (OptionalMCPCatalog → add-custom form) | BROKEN for OAuth entries (54 of 67) | F2 |
| 3 | Add preset (stdio presets / Linear http+oauth preset) | WORKS for stdio; BROKEN for Linear | F2 |
| 4 | Add custom stdio (`mcp add NAME --command C [--env ..] --args ..`) | WORKS | — |
| 5 | Add custom http/sse, auth none / header | WORKS (SSE: Hermes auto-falls back to SSE during the probe, `H:tools/mcp_tool_transport.py:556-590`, then Scarf stamps `transport: sse`) | — |
| 6 | Add custom http/sse, auth OAuth | BROKEN | F2 |
| 7 | Edit (env, headers, timeouts, include/exclude, resources/prompts, enabled, TLS, identity header, oauth.flow, cwd) | BROKEN for tool filters; DEGRADED for timeouts | F1, F3 |
| 8 | Enable/disable toggle | WORKS | — |
| 9 | Remove (`mcp remove -- NAME`) | WORKS | — |
| 10 | Test (`mcp test -- NAME`, output/tool parse) | WORKS (slow servers may false-fail) | F6 |
| 11 | OAuth login local (browser / device, prompt parse, verdict) | WORKS (list not refreshed after success) | F5 |
| 12 | OAuth login remote (device prompt, reap on stop) | DEGRADED (browser flow cannot complete) | F4 |
| 13 | Clear OAuth token (4 state files, sanitized names) | WORKS | — |

## Findings

### S09-mcp-F1 · P0 · SOURCE · NEW
- Claim: Scarf's own tool-filter writer emits `include:` before `exclude:`/`resources:`/`prompts:`, and Scarf's parser never leaves the `tools.include` sub-state. So every excluded tool reads back as an INCLUDED tool, `resources/prompts: false` read back as `true`, and the editor's next save (which always rewrites the tools block) turns a blacklist into a whitelist of exactly the tools the user blocked.
- Scarf: writer `HFS:2273-2280` (`tools:` → `include:` + items → `exclude:` + items → `resources:` → `prompts:`); parser `HFS:1451-1464`: in `case "tools.include"` only `- ` lines are handled, so the sibling `exclude:` / `resources:` / `prompts:` lines at indent 6 are dropped and the following `- x` exclude items are appended to `includeList`. `subSection` only resets on an indent-4 line (`HFS:1417-1427`). The editor calls `updateMCPToolFilters` on EVERY save (`MCPServerEditorViewModel.swift:433-439`), seeded from the misread model (`:67-70`). The same misread hits catalog installs: `MCPServersViewModel.applyCatalogToolDefaults` (`:377-391`) writes `include: []`-then-`exclude: [...]` right after add.
- Hermes @v2026.9.24: `H:tools/mcp_tool_registration.py:209-225`. `include:` null is not a list, so the exclude blacklist applies (the first write is correct on the host). A non-null `include` list is a whitelist that "wins over exclude". `resources`/`prompts` are read with `_parse_boolish(..., default=True)` at `:156`.
- Failure scenario: the user adds an exclude of `delete_repo` (or installs a catalog entry that ships `default_excluded`). The file holds `include:` (null) and `exclude: [delete_repo]`, which Hermes treats correctly. Scarf's detail view then shows "Include: delete_repo" and "Exclude: —". The user opens Edit to change, say, a timeout and saves. The file now holds `include: [delete_repo]` and `exclude: []`, and Hermes registers ONLY `delete_repo`. Every intended tool disappears and the blocked one is exposed. Separately, `resources: false` / `prompts: false` set in Scarf silently flip back to `true` on the next save.
- Evidence: no test covers read-back of a block that has both `include:` and `exclude:` (or `include:` followed by `resources:`). `ProjectsMCPRegistrarTests` has an exclude-only fixture, and `HermesMCPServerV0204RegressionTests` has a resources/prompts-only fixture.
- Suggested fix (one line): in the `tools.include` / `tools.exclude` cases, treat a non-`- ` indent-6 line as a `tools` sibling (re-dispatch it to `case "tools"`). Also, omit the empty half when writing.

### S09-mcp-F2 · P0 · SOURCE · NEW
- Claim: Adding any OAuth MCP server through Scarf never produces a working OAuth entry. This covers custom OAuth, the Linear preset, and 54 of 67 catalog entries. `hermes mcp add --auth oauth` refuses to build the OAuth provider when stdin is not a TTY, silently drops to "no auth", and the unauthenticated probe then fails. Nothing is saved, and the add is reported as failed.
- Scarf: `HermesMCPAdd.urlPlan` `.oauth` arm (`HermesMCPAdd.swift`, the `case .oauth:` branch) assumes "the CLI runs its own OAuth manager and asks no credential question" and feeds only `"\n\n"`. Callers: `HFS:580-611` (`addMCPServerHTTP`), `HFS:614-667` (SSE), `MCPServersViewModel.addCustom`/`addFromPreset` (`:294-459`). Catalog prefill maps `authKind .oauth` → `auth = "oauth"` (`MCPServerAddCustomView.swift:146-148`). The Linear preset is `auth: "oauth"` (`MCPServerPreset.swift:117-127`).
- Hermes @v2026.9.24: `_configure_http_auth` (`H:hermes_cli/mcp_config.py:538-561`) → `get_manager().get_or_build_provider` → `_build_provider` raises `OAuthNonInteractiveError` when `not _is_interactive() and not storage.has_cached_tokens()` (`H:tools/mcp_oauth_manager.py:316-319`). `_is_interactive` is false for a piped stdin (`H:tools/mcp_oauth.py:333-339`, `_stdin_is_console`). Only `mcp login` forces interactivity (`mcp_config.py:879`), and `mcp add` does not. The exception is caught and printed as `⚠ OAuth error: …`, and `auth: oauth` is never set (`:548-561`). `Continue without authentication?` defaults to yes, which consumes Scarf's first blank line. The probe without auth then fails (`Failed to connect:`), and `Save config anyway?` defaults to No, which consumes the second blank line, so nothing is saved (`:668-678`).
- Failure scenario: the user picks "Linear" (preset), or Atlassian/Asana/… from "Browse Catalog…", and clicks Add. Scarf shows "Add failed: ⚠ OAuth error: MCP OAuth for 'linear': non-interactive environment and no cached tokens found… ✗ Failed to connect: …401…". The server can never be added from Scarf, locally or remotely. For a server that answers `tools/list` without auth, the entry IS saved but without `auth: oauth`, and Scarf reports "Added". A later "Sign In" then fails with `is not configured for OAuth`.
- Evidence: see the `mcp_oauth_manager.py:316-319` quote above. `hermes mcp install --help` confirms `install <identifier>` exists (LIVE). Its `_install` writes `auth: oauth` plus the manifest's pre-registered `oauth:` client block before probing, and tolerates a probe failure (`H:hermes_cli/mcp_catalog.py:525-528, 620-649`). Scarf's catalog path also never writes that pre-registered `oauth:` block.
- Suggested fix (one line): use `hermes mcp install <name>` (gated on `hasMCPCatalog`) for catalog entries. For custom/preset OAuth servers, write the `url` + `auth: oauth` entry without the CLI probe, then offer `hermes mcp login`.

### S09-mcp-F3 · P2 · SOURCE · NEW
- Claim: Hermes stores `connect_timeout` as a float, which Scarf reads as "absent". The editor then deletes the key on any save.
- Scarf: `HFS:1248-1249` (`fields["timeout"/"connect_timeout"].flatMap(Int.init)`); editor seeds `""` (`MCPServerEditorViewModel.swift:71-72`) and `setMCPServerTimeouts(... connectTimeout: nil)` → `removeScalar` (`HFS:1063-1075`, `Editor VM:380,440`).
- Hermes @v2026.9.24: `--connect-timeout` is `type=float` (`H:hermes_cli/subcommands/mcp.py:38-40`) and is stored raw (`H:hermes_cli/mcp_config.py:660-661`), so PyYAML writes `connect_timeout: 45.0`. The runtime reads it with `float(...)` (`H:tools/mcp_tool_transport.py:359,547`).
- Failure scenario: a server was added in a terminal with `hermes mcp add x --url … --connect-timeout 90`. Scarf shows the connect timeout as empty. Editing any other field in Scarf drops the key, and the server falls back to the 60 s default.
- Suggested fix: parse with `Double(...)` and round-trip the original spelling (or keep the key untouched unless the field changed).

### S09-mcp-F4 · P2 · SOURCE · NEW
- Claim: On a remote host, the login sheet defaults to the browser flow, which cannot complete from Scarf. Hermes tells the user to paste the redirect URL "at the prompt below", but Scarf's login process has no stdin to paste into.
- Scarf: default flow is `"browser"` unless `oauth.flow: device` (`MCPLoginSheet.swift:45`). The remote process wraps `env PYTHONUNBUFFERED=1 hermes mcp login …` with no `standardInput` (`MCPLoginController.swift:147-158, 270-274`).
- Hermes @v2026.9.24: the remote-session hint (`SSH_CLIENT` is set by sshd even without a pty) prints `_SSH_HINT_LOOPBACK` and asks for a paste (`H:tools/mcp_oauth.py:747-781`). The paste reader reads stdin (`:706-740`), which reaches EOF here. The callback listener binds on the REMOTE 127.0.0.1 (`:813-825`).
- Failure scenario: the user signs in to an OAuth MCP server on an SSH host and opens the printed URL on the Mac. After approval, the redirect to `127.0.0.1:<port>` fails in the Mac browser, and the sheet waits until `oauth.timeout` and then shows "Authentication failed". Device flow works, but only for providers that support RFC 8628, which most DCR/PKCE servers do not.
- Suggested fix: on a remote context, default to device when available, and add a paste field that writes the redirect URL to the process's stdin.

### S09-mcp-F5 · P3 · SOURCE · NEW
- Claim: After a successful sign-in, the list is not reloaded, so the "oauth" badge and the Clear Token control stay stale.
- Scarf: `MCPServersView.swift:105` calls `viewModel.load(capabilities:)` without `force: true`. `load` returns immediately when `hasLoaded` is set (`MCPServersViewModel.swift:115-118`).
- Hermes: n/a (UI state).
- Failure scenario: the sheet shows "Signed in", but the server still shows no `oauth` badge until the user presses Reload or switches sections.

### S09-mcp-F6 · P3 · SOURCE · NEW
- Claim: `hermes mcp test` is killed after 30 s. That is less than Hermes's own probe budget, so slow-starting or long-`connect_timeout` servers report a failure that Hermes would not.
- Scarf: `HFS:898-903` (`timeout: 30`).
- Hermes @v2026.9.24: the probe waits `connect_timeout` (default 30 s, or the per-server value) plus 10 s (`H:hermes_cli/mcp_config.py:431-443, 506`), on top of Python/CLI startup.
- Failure scenario: a cold `npx -y` server that takes ~28 s to answer, or any server configured with `connect_timeout: 60`, shows "Test failed" in Scarf, while `hermes mcp test` in a terminal reports ✓ Connected.
- Suggested fix: use a timeout of `max(30, connect_timeout) + 20`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `mcp add NAME --command C [--connect-timeout] [--env K=V..] [--args ..]` | argv | HermesMCPAdd.stdioPlan; HFS:558-576 | subcommands/mcp.py:27-42; mcp_config.py:611-695 | OK |
| `mcp add NAME --url U [--auth header]` + stdin `n`/`y\ntoken` + `\n\n` | argv+stdin | HermesMCPAdd.urlPlan; HFS:580-611 | mcp_config.py:538-577, 579-609; cli_output.py:66-75; secret_prompt.py:47-54 | OK |
| `mcp add NAME --url U --auth oauth` | argv | HermesMCPAdd.urlPlan `.oauth`; HFS:580-667 | mcp_config.py:543-561; mcp_oauth_manager.py:316-319 | FINDING-F2 |
| Overwrite prompt pre-check (`name in _get_mcp_servers()`) | stdin | HermesMCPAdd.overwritePrefix; HFS:464-474 | mcp_config.py:644-648 | OK |
| `MCP_<NAME>_API_KEY` key derivation / `.env` pre-check | env/.env | HermesMCPAdd.envKeyForServer; HFS:484-506 | mcp_config.py:304-307, 565-569 | OK |
| add outcome parse (`Saved '<n>' … (a/b tools enabled)`, `(disabled)`, `Failed to connect:`, `was NOT saved`, `Must specify`, `--env is only`, `Cancelled`, `No tools selected`) | stdout | HermesMCPAdd.parseOutcome | mcp_config.py:252, 604, 630-695 | OK |
| `transport: sse` stamp after add | config key | HFS:652-666 | mcp_tool_transport.py:550; discovery.py:714 | OK |
| `mcp remove -- NAME` + judge (`Removed '`, `Server '`, `Cancelled.`) | argv/stdout | HFS:893-896; HermesCLIOutcome.swift:1943-1976 | mcp_config.py:698-715, 256-265 | OK |
| `mcp test -- NAME` + judge + tool list parse (`Tools discovered: N`, 4-space rows) | argv/stdout | HFS:898-992; HermesCLIOutcome.swift:1978-1995 | mcp_config.py:783-827, 203-206 (exit 0/1/3) | OK (F6 timeout) |
| `mcp login [--flow browser\|device] -- NAME`, judge (`Authenticated`, refusals) | argv/stdout | MCPLoginController.swift:104-143, 483-494 | subcommands/mcp.py:55-60; mcp_config.py:830-923 | OK |
| Device prompt (`MCP OAuth: open <url> on any device.` / `Code:` / `Waiting for approval...`, stderr) | stderr | HermesMCPDevicePrompt.parse | tools/mcp_oauth_device.py:164-165 | OK |
| Remote browser-flow paste / loopback | stdin | MCPLoginSheet.swift:45; MCPLoginController.swift:270-274 | tools/mcp_oauth.py:706-781 | FINDING-F4 |
| Remote login reap (`id -u`, `pkill -u uid -f 'mcp login .*-- NAME$'`) | ssh argv | MCPLoginController.swift:371-405 | n/a | OK |
| `mcp catalog` (text) | argv | MCPServersViewModel.swift:520-536 | mcp_config.py:1096-1099 | OK |
| `mcp install` (not used) | argv | — | mcp_picker.py:209-219; mcp_catalog.py:525-528 | FINDING-F2 (suggested fix) |
| `gateway restart` | argv | HFS:1114-1119 | (S07) | OK (owned by S07) |
| config `mcp_servers.<n>` block extraction/entry names (indent 2/4/6, IndentDumper indented lists) | YAML | HFS:1129-1175, 1177-1496 | utils.py:403-430 | OK except below |
| `url` / `command` / `args` / `env` / `headers` / `auth` | config keys | HFS:1318-1330, 1435-1449 | mcp_config.py:650-661; mcp_tool_config.py:283-385 | OK |
| `enabled` (boolish, v0.21.5 numeric truthiness) | config key | HFS:1242, 2347-2415 | mcp_tool_common.py:121-144 | OK |
| `tools.include` / `tools.exclude` read | config keys | HFS:1451-1468 | mcp_tool_registration.py:209-225 | FINDING-F1 |
| `tools.resources` / `tools.prompts` read | config keys | HFS:1456-1459 | mcp_tool_registration.py:156 | FINDING-F1 (lost after include:) |
| tools block write | config keys | HFS:2251-2297 | mcp_tool_registration.py:209-225 | FINDING-F1 |
| `timeout` / `connect_timeout` read/write | config keys | HFS:1248-1249, 1063-1076 | mcp_tool_common.py:48; mcp_tool_transport.py:359,547; subcommands/mcp.py:38-40 | FINDING-F3 |
| `supports_parallel_tool_calls` | config key | HFS:1257-1258, 675-689 | mcp_tool_discovery.py:347 | OK |
| `client_cert` / `client_key` / `ssl_verify` | config keys | HFS:694-760, 1265-1267 | mcp_tool_transport.py:548 | OK |
| `identity_header{name,value_from,value}` | config keys | HFS:774-779, 1284-1300, 2194-2249 | mcp_tool_transport.py:542 (`_apply_identity_header`) | OK |
| `strict_redirect_headers` | config key | HFS:823-837, 1310-1318 | mcp_tool_transport.py:549 (`bool(...)`) | OK |
| `oauth.flow` (nested scalar, preserves client_id/secret) | config key | HFS:790-818, 2019-2088 | mcp_config.py:845-849 | OK |
| `cwd` | config key | HFS:841-859 | (stdio params) | OK |
| `command` re-point (registrar) | config key | HFS:869-885 | mcp_config.py:650-655 | OK |
| patcher fail-closed gate / backup / verify / lock | YAML write | HFS:1524-1687, 1743-1923 | — | OK |
| `~/.hermes/mcp-tokens/<_safe_filename>.{json,client.json,meta.json,cimd-off}` detect + clear | files | HermesMCPOAuthPaths.swift; HFS:403-410, 1094-1108 | tools/mcp_oauth.py:228-237, 412-430, 587-595 | OK |
| `HERMES_HOME/config.yaml`, `.env` (profile via `context.paths`) | files | HFS:396, 490 | mcp_oauth.py:228-232 | OK (profile routing owned by S15) |

## Not audited / couldn't verify
- Did not execute `mcp add/test/login` (brief forbids). The argparse handling of `--` before the positional in `mcp test/remove/login -- NAME`, and `--args -y …` under REMAINDER on the installed Python 3.11, is accepted based on prior execution-verified decisions (`.memory/decisions/section-audit-remediation-2026-09.md:62-69`) and not re-probed.
- Whether Linear's `/sse` URL connects: Hermes's streamable→SSE fallback should handle it (`mcp_tool_transport.py:556-590`), but the OAuth add fails first (F2). Third-party behaviour is unverified.
- The case where `get_env_value` resolves `MCP_<NAME>_API_KEY` from an external secret source that Scarf cannot see (the header plan would then feed the token to "Enable all N tools?"). This needs an unusual config and was not traced further.
- Named-profile HERMES_HOME routing for `runHermesCLI` and `context.paths` (owned by S15). No iOS MCP surface exists.
