# S09-mcp — verdict: WORKS

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | List servers (config.yaml `mcp_servers` parse + token presence) | WORKS | — |
| 2 | Add stdio preset/custom (`mcp add NAME --command C [--env K=V…] --args …`, stdin plan) | WORKS | — |
| 3 | Add HTTP custom (none / header token / overwrite) | WORKS | — |
| 4 | Add OAuth (catalog `mcp install -- id` or direct YAML write) + SSE stamp | WORKS | — |
| 5 | Edit fields (env, headers, tools filter, timeouts, mTLS, identity_header, oauth.flow, cwd, parallel) | WORKS | — |
| 6 | Enable/disable toggle | WORKS | — |
| 7 | Remove (`mcp remove -- NAME`) | WORKS | TRACKED t-62dee8aa (UI two-way on 3-state verdict, low) |
| 8 | Test / Test all (`mcp test -- NAME`) incl. tool-list parse | WORKS | — |
| 9 | Login browser/device (`mcp login [--flow f] -- NAME`), device-code parse | WORKS | — |
| 10 | Clear token (delete mcp-tokens state files) | WORKS | — |
| 11 | Browse catalog (`mcp catalog`) | WORKS | — |

## Findings
None new. Verified against Hermes source:
- `mcp add` failure paths are bare `return` (exit 0) — hermes_cli/mcp_config.py:611-695; Scarf parses stdout for `Saved '<name>'`/`(disabled)`/failure markers (HermesMCPAdd.parseOutcome) and treats saved-disabled as not live. Stdin plan matches prompt order: overwrite `_confirm` (:644), `Does this server require authentication?` (:564), token via `prompt(password=True)` -> getpass falls back to stdin without a TTY (hermes_cli/secret_prompt.py:53-54), then `Enable all N tools? [Y/n/select]` / `Save config anyway` default False (:587, :673).
- `mcp remove` not-found returns exit 0 (:698-702, _lookup_server :256-265); confirm defaults True on EOF (:193-200). Scarf judges anchored `Removed '` vs `Server '` markers.
- `mcp test` returns 1/3 exit codes and `Connected (`/`Tools discovered:`/`Connection failed (` lines (:783-827); tool rows from `_print_tools` (:203-206) parsed after the count line.
- `mcp login` discards `_reauth_oauth_server` bool (exit 0 on failure, :919-923); Scarf requires `Authenticated` success line (MCPLoginController.swift:563) with failure markers matching :838-913. Device prompt printed on stderr (tools/mcp_oauth_device.py:164-165); Scarf merges stderr into stdout pipe (MCPLoginController.swift:170-171) and parses `MCP OAuth: open`/`Code:`/`Waiting for approval...`.
- `mcp install` exit 1 + `is not in the catalog` (hermes_cli/mcp_picker.py:209-220), success `Installed '<id>'` (hermes_cli/mcp_catalog.py:782) match HermesMCPInstallVerdict.
- Token filenames: `_safe_filename` (tools/mcp_oauth.py:235-237) ported in HermesMCPOAuthPaths.safeFilename; suffixes .json/.client.json/.meta.json/.cimd-off match storage `remove()` (:587-595).
- Config keys written by patcher are all read by the runtime: enabled via `mcp_server_enabled`/_parse_boolish (tools/mcp_tool_common.py:124-144, Scarf boolish mirrors word sets + numeric), tools.include/exclude/resources/prompts (tools/mcp_tool_registration.py:156,220-222), identity_header {name,value_from,value} (tools/mcp_tool_errors.py:223-260), transport/ssl_verify/strict_redirect_headers/connect_timeout/client_cert/client_key/cwd/supports_parallel_tool_calls/oauth.flow (tools/mcp_tool*.py, mcp_oauth_manager).
- All argv verified LIVE via `hermes mcp {add,test,remove,login} --help`.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| ScarfCore/Models/HermesMCPServer.swift | no (model) | NO-TOUCHPOINT |
| ScarfCore/Models/MCPServerPreset.swift | yes (preset argv inputs) | OK |
| ScarfCore/Models/OptionalMCPCatalog.swift | yes (mcp install ids/stdin) | OK |
| ScarfCore/Parsing/HermesMCPAdd.swift | yes | OK |
| ScarfCore/Parsing/HermesMCPDevicePrompt.swift | yes | OK |
| ScarfCore/Services/HermesMCPOAuthPaths.swift | yes | OK |
| ScarfProjectsMCPKit/ProjectMCPServer.swift | no (Scarf's own MCP server, JSON-RPC) | NO-TOUCHPOINT |
| MCPServers/ViewModels/MCPLoginController.swift | yes | OK |
| MCPServers/ViewModels/MCPServerEditorViewModel.swift | yes (via patcher) | OK |
| MCPServers/ViewModels/MCPServersViewModel.swift | yes | OK / TRACKED t-62dee8aa |
| Views/MCPLoginSheet.swift | no | NO-TOUCHPOINT |
| Views/MCPServerAddCustomView.swift | no | NO-TOUCHPOINT |
| Views/MCPServerDetailView.swift | no | NO-TOUCHPOINT |
| Views/MCPServerEditorView.swift | no | NO-TOUCHPOINT |
| Views/MCPServerPresetPickerView.swift | no | NO-TOUCHPOINT |
| Views/MCPServerTestResultView.swift | no | NO-TOUCHPOINT |
| Views/MCPServersView.swift | no | NO-TOUCHPOINT |
| Views/OptionalMCPCatalogPickerView.swift | no | NO-TOUCHPOINT |
| HermesFileService.swift 430-3091 | yes | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| mcp add … | argv+stdin | HermesMCPAdd.swift; HermesFileService.swift:485 | mcp_config.py:611; subcommands/mcp.py:27-40 | OK |
| mcp install -- id | argv | HermesCLIOutcome.swift:2092; HermesFileService.swift:740 | mcp_picker.py:209 | OK |
| mcp remove -- name | argv | HermesFileService.swift:1285 | mcp_config.py:698 | OK |
| mcp test -- name | argv | HermesFileService.swift:1293 | mcp_config.py:783 | OK |
| mcp login [--flow] -- name | argv | MCPLoginController.swift:128-134 | mcp_config.py:919 | OK |
| mcp catalog | argv | MCPServersViewModel.swift:648 | mcp_picker show_catalog | OK |
| config.yaml mcp_servers.* keys | config | HermesFileService.swift 995-1520, 1611-2950 | tools/mcp_tool*.py | OK |
| mcp-tokens/<safe>.{json,client.json,meta.json,cimd-off} | file | HermesMCPOAuthPaths.swift; HermesFileService.swift:1518 | tools/mcp_oauth.py:229-237,427-429,587 | OK |
| .env MCP_<NAME>_API_KEY read | file | HermesFileService.swift:522 | mcp_config.py:304,570 | OK |

## Not audited / couldn't verify
- Runtime GUI behaviour and actual SSH round-trips (read-only audit). Remote stdin forwarding and profile HERMES_HOME in runHermesCLI belong to S15.
- getpass stdin fallback assumes no controlling TTY (true for a Finder-launched app and non-`-t` SSH).
