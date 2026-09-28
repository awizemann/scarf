# S09-mcp — verdict: WORKS-WITH-ISSUES

All primary MCP journeys trace cleanly to Hermes v2026.9.24 (0.21.5). There is one secondary-surface defect (Clear Token). The reworked YAML reader, patcher and boolish code in HermesFileService (lines 430–2996) matches how Hermes reads `mcp_servers`: `_parse_boolish` with 0.21.5 numeric truthiness, `_normalize_name_filter` / `_make_tool_filter`, `transport == "sse"` only when `url` is present, `bool(strict_redirect_headers)`, `ssl_verify` passed straight to httpx, and `float(connect_timeout)`. It also matches the layout Hermes writes: ruamel round-trip with `indent(mapping=2, sequence=4, offset=2)` (utils.py:442-452) puts entries at 2, scalars at 4, list dashes at 6 and 8. Scarf reads both that layout and PyYAML's indentless layout.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | List servers (stdio / http / sse), enabled, tools filter, OAuth badge — local + SSH | WORKS | — |
| 2 | Add from preset (stdio `mcp add --command --env --args`, http OAuth → direct write) | WORKS | — |
| 3 | Add from catalog (OAuth entry → `mcp install -- <id>` with install-prompt stdin; fallback direct write) | WORKS | — |
| 4 | Add custom stdio / http (none/header) / sse (`mcp add --url` + `transport: sse` stamp) / OAuth direct write | WORKS | — |
| 5 | Edit (env, headers, include/exclude/resources/prompts, timeouts, enabled toggle, parallel, mTLS, ssl_verify, identity_header, strict_redirect_headers, cwd, oauth.flow) | WORKS | — |
| 6 | Remove (`mcp remove -- <name>`, output-judged) | WORKS | (t-62dee8aa is already addressed in code: three-way `removeFailureSummary`) |
| 7 | Test / Test All (`mcp test -- <name>`, output + exit judged, tool-list parse) | WORKS | — |
| 8 | OAuth login (browser + device flow, device prompt parse, paste fallback, verdict, remote reap) | WORKS | — |
| 9 | Clear token (unlink `mcp-tokens/<safe>.{json,client.json,meta.json,cimd-off}`) | DEGRADED | S09-F1 |
| 10 | Browse catalog (`mcp catalog` text) | WORKS | — |

## Findings

### S09-F1 · P2 · SOURCE · NEW
- Claim: after a successful "Clear Token" the editor keeps showing "Token on disk", the list/detail "oauth" badge stays stale, and the copy promises that Hermes will "re-authenticate next time the gateway connects". Hermes's non-interactive gateway does not do this; the user has to run Sign in (`hermes mcp login`).
- Scarf: scarf/scarf/Features/MCPServers/Views/MCPServerEditorView.swift:82-83 (section gated on the immutable `viewModel.server.hasOAuthToken`), :396-414 (copy; the success branch of `clearOAuthToken` does nothing); scarf/scarf/Features/MCPServers/ViewModels/MCPServerEditorViewModel.swift:563-571; Cancel → `finishEdit(reload: false)` at scarf/scarf/Features/MCPServers/ViewModels/MCPServersViewModel.swift:150-160 (no reload), so the MCPServerDetailView.swift:71 badge stays up.
- Hermes @v2026.9.24: tools/mcp_oauth_manager.py:316-319 — with no dashboard flow, not interactive and no cached tokens, `_build_provider` raises `OAuthNonInteractiveError` ("Run `hermes mcp login <name>` interactively first"). tools/mcp_oauth.py:333-339: `_is_interactive` is false for a service or gateway process.
- Failure scenario: the user clicks Clear Token on a working OAuth server. The files are deleted (correctly, the same set as `HermesTokenStorage.remove`, mcp_oauth.py:587-594), but the sheet still says "Token on disk" and offers Clear again, with no confirmation. After Cancel the row still carries the "oauth" badge. On the next gateway (re)connect the server fails with a non-interactive OAuth error instead of re-authenticating, and nothing in Scarf told the user that Sign in is the required next step.
- Evidence: Scarf copy reads "Token on disk. Clear to re-authenticate next time the gateway connects." Hermes: `if get_dashboard_oauth_flow() is None and not _is_interactive() and not storage.has_cached_tokens(): raise OAuthNonInteractiveError(...)`.
- Suggested fix: after a successful clear, reload the list (or report "changed" to `finishEdit`), hide or refresh the section, and change the copy to "Sign in again to reconnect (hermes mcp login)".

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `mcp_servers` block read (entries@2, keys@4, nested@6+, block & indentless lists) | config read | HermesFileService.swift:1516-1929 | utils.py:442-452 (ruamel indent), hermes_cli/mcp_config.py:209-214 | OK |
| `url` / `command` / `args` / `transport: sse` discrimination | config key | HermesFileService.swift:1626-1629 | tools/mcp_tool_transport.py:550; tools/mcp_tool_discovery.py:714 | OK |
| `enabled` (boolish, 0.21.5 numeric truthiness) | config key r/w | HermesFileService.swift:1637, 1345-1349, 2920-2939 | tools/mcp_tool_common.py:123-144 | OK |
| `tools.include` / `exclude` (null / str / list / `[]`), `resources`, `prompts` | config key r/w | HermesFileService.swift:1853-1901, 2695-2826, 2967-2982 | tools/mcp_tool_registration.py:155-156, 213-225; tools/mcp_tool_schema.py:231-240 | OK |
| `timeout`, `connect_timeout` (floats) | config key r/w | HermesFileService.swift:1642-1647, 1399-1428 | tools/mcp_tool_common.py:48; tools/mcp_tool_transport.py:359,547 | OK |
| `env` / `headers` sub-maps (quoted keys and values) | config key r/w | HermesFileService.swift:1845-1852, 1352-1377, 2558-2618 | tools/mcp_tool_transport.py:319,532 | OK |
| `supports_parallel_tool_calls` | config key r/w | HermesFileService.swift:1656, 995-1007 | tools/mcp_tool_discovery.py:347 | OK |
| `client_cert` / `client_key` / `ssl_verify` (bare bool vs quoted path) | config key r/w | HermesFileService.swift:1014-1083, 1664-1666 | tools/mcp_tool_transport.py:548; tools/mcp_tool_errors.py:195-196 | OK |
| `identity_header` {name, value_from, value} | config key r/w | HermesFileService.swift:1685-1702, 2627-2682 | tools/mcp_tool_errors.py:227; tools/mcp_tool_transport.py:310 | OK |
| `strict_redirect_headers` (Python truthiness) | config key r/w | HermesFileService.swift:1712-1721, 1143-1155 | tools/mcp_tool_transport.py:549 | OK |
| `cwd` (stdio) | config key r/w | HermesFileService.swift:1161-1178 | tools/mcp_tool_transport.py:326 | OK |
| `oauth.flow` (nested scalar; other oauth keys preserved) | config key r/w | HermesFileService.swift:1110-1134, 2452-2521 | tools/mcp_oauth_provider.py:634; hermes_cli/mcp_config.py:845-849 | OK |
| `command` re-point (registrar) | config key w | HermesFileService.swift:1189-1203 | tools/mcp_tool_transport.py:316 | OK |
| OAuth direct entry write `url`+`auth: oauth`(+`transport: sse`)+`enabled: true` | config write | HermesFileService.swift:723-986 | hermes_cli/mcp_config.py:538-561 (add --auth oauth needs TTY: tools/mcp_oauth_manager.py:316-319); :840 (login requires auth==oauth) | OK |
| `hermes mcp add <name> --command X [--env K=V…] [--args …]` + stdin `[y]\n\n` | argv | Parsing/HermesMCPAdd.swift:263-287; HermesFileService.swift:596-613 | hermes_cli/subcommands/mcp.py:27-42; hermes_cli/mcp_config.py:611-695, 579-608 | OK (LIVE: `hermes mcp add --help`) |
| `hermes mcp add <name> --url U [--auth header\|oauth]` + stdin (n / y+token / y) | argv | Parsing/HermesMCPAdd.swift:294-354; HermesFileService.swift:618-704 | hermes_cli/mcp_config.py:538-576; hermes_cli/cli_output.py:66-75; hermes_cli/secret_prompt.py:47-54 | OK |
| `mcp add` outcome parse (`Saved '<n>'`, `(disabled)`, `(a/b tools enabled)`, failure markers) | output parse | Parsing/HermesMCPAdd.swift:362-405 | hermes_cli/mcp_config.py:671-694, 252, 630-642 | OK |
| `MCP_<NAME>_API_KEY` key derivation + `.env` / env pre-check | file/env | Parsing/HermesMCPAdd.swift:179-186; HermesFileService.swift:522-545 | hermes_cli/mcp_config.py:304-307, 565-569 | OK |
| `hermes mcp install -- <id>` + install-prompt stdin; verdict | argv / output | HermesFileService.swift:739-777; HermesCLIOutcome.swift:2067-2105; OptionalMCPCatalog.swift:118-130 | hermes_cli/subcommands/mcp.py:74-76; hermes_cli/mcp_picker.py:209-220; hermes_cli/mcp_catalog.py:467-494, 721-790 | OK |
| `hermes mcp remove -- <name>`; verdict | argv / output | HermesFileService.swift:1213-1216; HermesCLIOutcome.swift:1978-1995, 1196-1206 | hermes_cli/mcp_config.py:698-715, 256-265 | OK |
| `hermes mcp test -- <name>`; verdict; timeout; tool parse | argv / output | HermesFileService.swift:1221-1313; HermesCLIOutcome.swift:2013-2041, 1210-1225 | hermes_cli/mcp_config.py:783-827, 203-206, 414-518 | OK |
| `hermes mcp login [--flow browser\|device] -- <name>` (merged stdout+stderr, PYTHONUNBUFFERED, stdin paste) | argv / process | MCPLoginController.swift:117-307, 443-492 | hermes_cli/subcommands/mcp.py:55-60; hermes_cli/mcp_config.py:830-923; tools/mcp_oauth.py:768, 880-898, 706-740 | OK (LIVE: `hermes mcp login --help`) |
| Login verdict (`Authenticated` / failure markers) | output parse | MCPLoginController.swift:562-573; HermesCLIOutcome.swift:669-688 | hermes_cli/mcp_config.py:836-916 | OK |
| Device prompt (`MCP OAuth: open <url> on any device.` / `Code:` / `Waiting for approval...`, stderr) | output parse | Parsing/HermesMCPDevicePrompt.swift:67-131 | tools/mcp_oauth_device.py:164-165 | OK |
| Remote login reap (`id -u`, `pkill -u <uid> -f 'mcp login .*-- <name>$'`) | remote process | MCPLoginController.swift:394-441 | — (the remote process runs the tools/mcp_oauth_device.py:170-201 poll loop) | OK |
| Remote profile pin for `env PYTHONUNBUFFERED=1 hermes …` | argv | MCPLoginController.swift:291-296; HermesProfileScope.swift:226-236 | hermes_cli/main.py (profile pre-parse) | OK |
| `~/.hermes/mcp-tokens/<_safe_filename>.json` presence (one listing) | file path | HermesFileService.swift:440-446; HermesMCPOAuthPaths.swift:77-147; HermesPathSet.swift:141 | tools/mcp_oauth.py:228-237, 410-430, 646-648 | OK |
| Clear token: unlink `.json` / `.client.json` / `.meta.json` / `.cimd-off` | file delete | HermesFileService.swift:1446-1459; HermesMCPOAuthPaths.swift:54, 151-155 | tools/mcp_oauth.py:587-594, 916-919 | FINDING-S09-F1 (UI/copy only; the file set is correct) |
| `hermes mcp catalog` (text) | argv | MCPServersViewModel.swift:639-655 | hermes_cli/mcp_picker.py:187-189 | OK |
| `hermes gateway restart` (banner) | argv | HermesFileService.swift:1492-1506 | (owned by the gateway section) | OK (not re-audited here) |
| Preset roster (npx/uvx args, linear OAuth URL) | data | MCPServerPreset.swift:52-203 | hermes_cli/mcp_config.py:611-695 | OK |
| Catalog roster (65 entries, auth kinds, tool defaults, install prompts) | data | OptionalMCPCatalog.swift | optional-mcps/*/manifest.yaml | UNVERIFIABLE (not diffed entry by entry; the repo's check script covers it) |

## Not audited / couldn't verify
- Live runs of add, test, login and remove were not performed: they are mutating or interactive. Everything above is SOURCE, apart from the `--help` probes of `mcp`, `mcp add`, `mcp remove`, `mcp test` and `mcp login`, which match `hermes_cli/subcommands/mcp.py` at the tag.
- The OptionalMCPCatalog roster was not diffed entry by entry against `optional-mcps/*/manifest.yaml`.
- Plugin-provided ("portable") MCP servers (`tools/mcp_tool_config.py:347-359`) are merged by Hermes at runtime but are not in config.yaml, so they never appear in Scarf's MCP list. This is a plugins-section concern and was not judged here.
- Hand-written flow-style values (`args: [a, b]`, `tools: {include: [...]}`) are outside the layouts Hermes writes. The reader shows them as empty, and a tools-filter edit on a flow-style `tools:` would add a second block. Treated as out of scope (unusual config).
- Minor, not filed: the `testMCPServer` comment (HermesFileService.swift:1230) still says `mcp test` always exits 0. At the tag it returns 1 or 3 (hermes_cli/mcp_config.py:783-827). The verdict judges output and exit code, so behaviour is correct.
