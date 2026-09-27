# T4-mcp — verdict: WORKS-WITH-ISSUES

Hermes ref: `~/.hermes/hermes-agent-v0215` @ v2026.9.24 (live `hermes --version` = 0.21.5). Scarf: integration worktree.
`HFS` = `scarf/scarf/Core/Services/HermesFileService.swift` (MCP region 430-2816 audited in full). `H:` = Hermes worktree.
All six S09 findings from the v0.21.5 audit (F1 tools-block misread, F2 OAuth add, F3 float timeouts, F4 remote paste, F5 reload after sign-in, F6 test timeout) are fixed in the current code. I re-traced each one and found no regression. The two findings below are new and are both about stale static data, not the Hermes wiring.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List servers (stdio/http/sse, enabled, oauth badge, tools filters, float timeouts) | WORKS | — |
| 2 | Add a stdio preset (`mcp add N --command npx [--env ..] --args ..`, stdin `\n\n`) | WORKS (except the Fetch preset) | F2 |
| 3 | Add the Linear preset (HTTP OAuth → direct `url`+`auth: oauth` write → sign-in offer) | WORKS | — |
| 4 | Add a custom stdio server | WORKS | — |
| 5 | Add a custom http/sse server with auth none/header (stdin `n` / `y\ntoken`, SSE stamp) | WORKS | — |
| 6 | Add a custom OAuth server (direct write, managed-install check, verify+restore) | WORKS | — |
| 7 | Add from the catalog (OAuth → `mcp install -- <id>`; none/api_key → `mcp add` + tool defaults) | DEGRADED | F1 |
| 8 | Edit (env/headers/tools/timeouts/TLS/identity_header/strict_redirect/oauth.flow/cwd) | WORKS | — |
| 9 | Enable/disable toggle | WORKS | — |
| 10 | Remove (`mcp remove -- N`, output-judged) | WORKS | — |
| 11 | Test / Test All (`mcp test -- N`, anchored verdict, tool parse, `max(30,ct)+20` timeout) | WORKS | — |
| 12 | Local login, browser + device (`mcp login [--flow] -- N`) | WORKS | — |
| 13 | Remote login (device prompt on stderr, paste field → stdin, pkill reap) | WORKS | — |
| 14 | Clear token (4 state files under `_safe_filename`) | WORKS | — |
| 15 | Browse catalog (`mcp catalog`, raw text) | WORKS | — |

## Findings

### T4-mcp-F1 · P2 · SOURCE · NEW
- Claim: Scarf's static catalog snapshot (v0.21.0) no longer matches the v0.21.5 catalog. **Asana** points at a retired endpoint, and Scarf's install of it always fails. **n8n** is a retired stdio bridge. The new **n8n-official** entry is missing.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/OptionalMCPCatalog.swift:132-138` (asana `url: "https://mcp.asana.com/sse"`, no env) and `:404-411` (`n8n`, `.apiKey`, bridge tool allow-list). The OAuth routing is at `MCPServerAddCustomView.swift:160, 297` → `MCPServersViewModel.runOAuthAdd` → `HFS:738-766` (`mcp install -- asana`).
- Hermes @v2026.9.24:
  - `optional-mcps/asana/manifest.yaml`: `url: https://mcp.asana.com/v2/mcp`. The comment says "The V1 beta endpoint https://mcp.asana.com/sse is retired". The manifest also carries required `auth.env` `ASANA_CLIENT_ID`/`ASANA_CLIENT_SECRET` and a pre-registered `oauth:` block.
  - `hermes_cli/mcp_catalog.py:32-37`: `EnvVarSpec.required` defaults to True.
  - `mcp_catalog.py:487-493`: an empty prompt answer on a required var raises `CatalogError("… is required but no value was provided")`.
  - `cli_output.py:66-75`: EOF on stdin is read as "".
  - `mcp_picker.py:103-110`: the error prints `✗ install failed: …`.
  - `optional-mcps/n8n-official/manifest.yaml` replaces the old `n8n` directory.
- Failure scenario (Asana): the user picks Asana in "Browse Catalog…" and clicks Add. `mcp install -- asana` runs without stdin and prints `✗ install failed: ASANA_CLIENT_ID is required but no value was provided`. Scarf reports "Add failed" correctly, but Asana can never be added from Scarf. If the user edits the form instead, it becomes a custom OAuth server, and the direct write stores the retired `/sse` URL, so sign-in and test fail.
- Failure scenario (n8n): the picker offers the retired bridge with its tool allow-list. The official OAuth connector is absent.
- Evidence: a script diff of all 65 `optional-mcps/*/manifest.yaml` files against Scarf's 65 entries. The only differences are `asana` (url and env) and `n8n` ↔ `n8n-official`. Every other name, transport, url, auth kind and `default_enabled`/`default_excluded` list matches exactly. The mismatch is not tracked in TASKS/tasks/documents.
- Suggested fix: refresh the snapshot to v2026.9.24. For OAuth entries that declare `auth.env` (asana, n8n-official), collect the values in the form and feed them to `mcp install` on stdin, or say that they need a terminal.

### T4-mcp-F2 · P3 · PLAUSIBLE · NEW
- Claim: the "Fetch" preset launches `npx -y @modelcontextprotocol/server-fetch`. The official fetch server is the Python package `mcp-server-fetch` (run through `uvx`), not an npm package, so this preset can never be added.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MCPServerPreset.swift:184-199`.
- Hermes @v2026.9.24: not a Hermes touchpoint. Hermes's own tests use `uvx mcp-server-fetch` (`tests/tools/test_osv_check.py:150-154`).
- Failure scenario: Add → Fetch. The `mcp add` probe fails (npm 404), and Scarf correctly shows "Add failed: Failed to connect: …". The preset looks available but can never be added. The project's own wiki says as much (`wiki/Troubleshooting-Slow-Chat-Startup.md:64`: "The official MCP fetch server is the **Python** package `mcp-server-fetch`, not an npm one").
- Evidence: PLAUSIBLE only because I did not query the npm registry (network is outside the allowed probes).
- Suggested fix: `command: uvx`, `args: ["mcp-server-fetch"]`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `mcp add N --command C [--connect-timeout] [--env K=V..] [--args ..]` + stdin `[y\n]\n\n` | argv+stdin | HermesMCPAdd.swift:263-287; HFS:596-613 | subcommands/mcp.py:27-42; mcp_config.py:611-695 | OK |
| `mcp add N --url U [--auth header]` + stdin `n\n` / `y\n<tok>\n` / `y\n` (key already set) | argv+stdin | HermesMCPAdd.swift:294-354; HFS:618-639 | mcp_config.py:538-576; cli_output.py:66-75; secret_prompt.py:47-54 | OK |
| Overwrite pre-check → `y\n` only on an explicit confirm | stdin | HermesMCPAdd.swift:191-199; HFS:502-512 | mcp_config.py:644-648 | OK |
| `MCP_<NAME>_API_KEY` derivation + `.env`/env check | env | HermesMCPAdd.swift:179-186; HFS:522-545 | mcp_config.py:304-307, 565-569 | OK |
| add outcome parse (`Saved 'N' … (a/b tools enabled)`, `(disabled)`, failure markers) | stdout | HermesMCPAdd.swift:362-392 | mcp_config.py:252, 671-695 | OK |
| `transport: sse` stamp after the url add | config key | HFS:690-702 | mcp_tool_transport.py:550; mcp_tool_discovery.py:714 | OK |
| `mcp install -- <id>` + verdict (`Installed '<id>'`, `not in the catalog`, `install failed:`) | argv/stdout | HermesCLIOutcome.swift:2032-2070; HFS:738-766 | mcp_picker.py:103-110, 209-220; mcp_catalog.py:721-790 | OK (F1 for asana data) |
| Direct OAuth entry (`url`, `auth: oauth`, `[transport: sse]`, `enabled: true`) + managed check | YAML write | HFS:768-976 | mcp_config.py:549, 836-843; mcp_tool_transport.py:455 | OK |
| `mcp remove -- N` + verdict | argv/stdout | HFS:1203-1206; HermesCLIOutcome.swift:1943-1976 | mcp_config.py:698-715, 193-200 (EOF → default yes) | OK |
| `mcp test -- N` + verdict + tool rows (4-space, bounded by `Tools discovered: N`) + timeout | argv/stdout | HFS:1211-1303; HermesCLIOutcome.swift:1978-2003 | mcp_config.py:203-206, 414-518, 783-827 | OK |
| `mcp login [--flow browser\|device] -- N` + verdict | argv/stdout | MCPLoginController.swift:117-156, 562-573; HermesCLIOutcome.swift:664-688 | subcommands/mcp.py:55-60; mcp_config.py:830-923 | OK |
| Device prompt (`MCP OAuth: open <url> on any device.` / `Code:` / sentinel, stderr) | stderr | HermesMCPDevicePrompt.swift:67-117 | tools/mcp_oauth_device.py:164-165 | OK |
| Browser paste (`paste the redirect URL here` → one stdin line with `code=`/`error=`) | stdin | MCPLoginController.swift:448-492; MCPLoginSheet.swift:121-150 | tools/mcp_oauth.py:706-738, 889-894 | OK |
| Remote login spawn (`env PYTHONUNBUFFERED=1 <hermes> …`, HERMES_HOME prefix) + reap (`id -u`, `pkill -u -f`) | ssh argv | MCPLoginController.swift:288-307, 394-428; SSHTransport.swift:669-705 | — | OK |
| `mcp catalog` (text) | argv | MCPServersViewModel.swift:629-645 | mcp_config.py:1094-1101; mcp_picker.py:163-190 | OK |
| `mcp_servers` block extraction / entry names (ruamel `indent(mapping=2, sequence=4, offset=2)`, no fold) | YAML | HFS:1471-1517, 2232-2249 | utils.py:443-451; config.py:2016-2025 | OK |
| `url`/`command`/`args`/`env`/`headers`/`auth` | config keys | HFS:1678-1686, 1776-1807, 1341-1367 | mcp_tool_transport.py:316-326, 532, 455 | OK |
| `enabled` (boolish) | config key | HFS:1592, 1335-1339 | mcp_tool_common.py:144 | OK |
| `tools.include`/`exclude`/`resources`/`prompts` read + write (S09-F1 fix) | config keys | HFS:1808-1856, 2650-2781 | mcp_tool_registration.py:155, 213 | OK |
| `timeout`/`connect_timeout` (float read, delta-gated write; S09-F3 fix) | config keys | HFS:1597-1602, 1401-1418; EditorVM:320-327, 502-509 | mcp_tool_common.py:48; mcp_tool_transport.py:359, 547 | OK |
| `supports_parallel_tool_calls` | config key | HFS:1611-1612, 985-997 | mcp_tool_discovery.py:347 | OK |
| `client_cert`/`client_key`/`ssl_verify` (bare bool vs quoted path) | config keys | HFS:1004-1073, 1619-1621 | mcp_tool_errors.py:191-221; mcp_tool_transport.py:548 | OK |
| `identity_header{name,value_from,value}` | config keys | HFS:1084-1088, 1640-1657, 2582-2637 | mcp_tool_errors.py:223-265 | OK |
| `strict_redirect_headers` | config key | HFS:1133-1145, 1667-1676 | mcp_tool_transport.py:549 | OK |
| `oauth.flow` (nested scalar; the rest of the `oauth:` block is preserved) | config key | HFS:1100-1124, 2407-2476 | mcp_config.py:845-849 | OK |
| `cwd` (stdio) | config key | HFS:1151-1168 | mcp_tool_transport.py:326 | OK |
| Patcher gate / lock / per-launch backup / read-back verify + restore | YAML write | HFS:1912-2075, 2131-2301 | — | OK |
| `mcp-tokens/<_safe_filename>.{json,client.json,meta.json,cimd-off}` detect + clear | files | HermesMCPOAuthPaths.swift:54-155; HFS:440-447, 1436-1449 | tools/mcp_oauth.py:228-237, 411-430, 587-595, 646-648 | OK |
| `gateway restart` (restart banner) | argv | HFS:1456-1461 | (T5) | OK (T5 owns it) |
| Catalog roster (65 entries) | static data | OptionalMCPCatalog.swift | optional-mcps/*/manifest.yaml | FINDING-F1 |
| Preset gallery (8 entries) | static data | MCPServerPreset.swift:51-200 | — | FINDING-F2 (fetch) |
| Capability gates (`hasMCPOAuthAddNeedsDirectWrite` 0.17, `hasMCPReauth` 0.18, `hasMCPOAuthFlow` 0.21.1, `hasMCPCatalog` 0.15, `hasMCPSSETransport` 0.13) | gate | HermesCapabilities.swift:397, 875, 1020, 1051, 2145 | — | OK (all true at 0.21.5) |

## Not audited / couldn't verify
- I did not run `mcp add/install/test/login/remove` (brief forbids). Only `--help` probes were run: `mcp install`, `mcp login` (with `--flow {browser,device}`) and `mcp test` match the argparse above. The `--` handling before the positional was accepted from earlier execution-verified decisions.
- I did not query the npm registry for F2.
- Named-profile scoping of LOCAL spawns (`LocalTransport.runProcess` / `makeProcess` set no HERMES_HOME) belongs to T6 (transport/profiles). Remote spawns carry the `HERMES_HOME=` prefix (`SSHTransport.swift:669-705`).
- `get_env_value` resolving `MCP_<NAME>_API_KEY` from a remote login-shell export that Scarf cannot see (the header plan would then misalign) needs an unusual setup. It was noted in S09 and not re-traced.
- A hand-edited flow-style `args: [..]` shows as empty args in the detail pane (display only; the patcher never rewrites args). I judged this out of scope as a rare hand-edit.
- There is no iOS MCP surface (ScarfGo has none).
