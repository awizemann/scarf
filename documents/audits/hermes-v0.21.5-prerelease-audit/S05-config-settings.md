# S05-config-settings — verdict: WORKS

## Journeys
| # | Journey | Verdict | Findings |
|---|---|---|---|
| 1 | Toggle/stepper/picker in any Mac Settings tab -> `hermes config set -- <key> <value>` -> reload | WORKS | — |
| 2 | Clear to host default (approvals.mode, browser.cloud_provider, stt.provider, aux max_concurrency, database.*) -> `hermes config unset -- <key>` | WORKS | — |
| 3 | Managed install (nix/brew etc.): pane read-only, writes refused honestly (Hermes exits 0 on refusal) | WORKS | — |
| 4 | Direct-YAML power settings (agent.reasoning_overrides, model_catalog.excluded_providers, profile_routes) via GuardedTextFile | WORKS | — |
| 5 | Auxiliary tab: per-task provider/model/base_url/api_key/timeout/reasoning_effort/max_concurrency, title_generation, background_review | WORKS | — |
| 6 | Approvals (mode manual/smart/off, timeout, smart_policy) + Terminal backend/docker/modal settings | WORKS | — |
| 7 | Secrets tab (Bitwarden / command secrets config keys; `hermes secrets bitwarden status`) | WORKS | — |
| 8 | iOS ScarfGo settings editor: `/bin/sh -c "PATH=… hermes [-p default ]config set|unset -- …"` over SSH | WORKS | — |
| 9 | Config read (config.yaml parse; iOS fallback `hermes config path` / `config show` Model line) | WORKS | — |

## Findings
None. No P0–P3 defects found.

## Verification highlights
- Every literal config key Scarf writes from the Mac Settings VM, tabs, and iOS editor (179 extracted) was run through Hermes's own `_validate_config_key` at the tag (Hermes imported with a throwaway HERMES_HOME in the scratchpad, nothing written to a real home). All are known except: `agent.reasoning_effort` (unseeded, but read at hermes_cli/cli_commands_mixin.py:2619-2623 and cli_model_switch_mixin.py:228; `config set` saves it with only a notice, exit 0 with "✓ Set" printed), plus `browser.cloud_provider` and `stt.provider`, which Hermes documents as deliberately unseeded (hermes_cli/config.py get_config_value comment, ~3640). None triggers the wrong-prefix refusal (`_is_wrong_prefix_suggestion` returned False for all).
- Aux task keys: vision/compression/skills_hub/approval/mcp/curator/title_generation/background_review are all known at the tag (hermes_cli/config_defaults.py:715-790). session_search/web_extract/flush_memories are unknown at the tag, but Scarf shows them only on hosts older than 0.15.0/0.20.6/0.12 (HermesCapabilities.swift:122,140,1970; AuxiliaryTab.swift:80-101).
- Verdicts: `set_config_value`/`unset_config_value` bare-`return` on managed hosts (hermes_cli/config.py:3486-3488, 3658-3660 → exit 0). Scarf judges by output (HermesCLIOutcome.swift:1532-1552, markers :432/:493), also bounces up front via managedBannerText (SettingsViewModel.swift:405-413, IOSSettingsViewModel.swift:192). Wrong-prefix and invalid-key refusals `sys.exit(1)` (config.py:3440-3442).
- Coercion: `_coerce_config_set_value` (config.py:3248) keeps str-defaulted enums (approvals.mode "off", human_delay.mode "off", tool_use_enforcement "true"/"false" read via `_model_gate` string words, agent/system_prompt.py:41-52) verbatim. Bools are sent as "true"/"false" and ints/doubles as numbers.
- argv: `hermes config set --help` (LIVE) shows `[--force] [key] [value]`. Scarf sends `config set -- key value` without --force. `hermes -p <profile>` is a valid global (LIVE `hermes --help`). The iOS script adds HERMES_HOME through CitadelServerTransport.swift:824.
- Enums checked against Hermes: approvals modes (tools/approval_context.py:197-214), busy_input_mode interrupt/queue/steer (cli_init_mixin.py:58), resume_display (:47), modal modes, terminal backends.
- Off-main: every write runs through a serialized `writeChain` with Task.detached plus a timeout (SettingsViewModel.swift:400-438). The iOS write uses asyncRunProcess with timeout 15.

## File coverage
| File | Hermes touchpoints? | Status |
|---|---|---|
| Models/HermesApprovalMode.swift | yes (approvals.mode) | OK |
| Models/HermesConfig.swift | yes (key reads) | OK (spot-checked) |
| Models/JSONValue.swift | no | NO-TOUCHPOINT |
| Parsing/HermesConfig+YAML.swift | yes (config.yaml key paths) | OK (spot-checked) |
| Parsing/HermesYAML.swift | yes (config.yaml parse) | OK (spot-checked) |
| Parsing/YAMLLineEndings.swift | no | NO-TOUCHPOINT |
| Parsing/YAMLScalar.swift | yes (scalar semantics) | OK (skimmed) |
| Services/ConfigDottedKeySegment.swift | yes (key segments) | OK (skimmed) |
| Services/GuardedJSONStore.swift | indirect (~/.hermes JSON files) | OK (skimmed) |
| Services/GuardedTextFile.swift | yes (config.yaml guarded write) | OK |
| Services/HermesConfigReader.swift | yes (config path, config show) | OK |
| ViewModels/IOSSettingsViewModel.swift | yes (config set/unset) | OK |
| Scarf iOS/Settings/ScarfMonDiagnosticsView.swift | no | NO-TOUCHPOINT |
| Scarf iOS/Settings/SettingEditorSheet.swift | yes (key specs) | OK |
| Scarf iOS/Settings/SettingsView.swift | yes (display of keys, env settings) | OK (skimmed) |
| Scarf iOS/Settings/V013FeaturesSheet.swift | no | NO-TOUCHPOINT |
| Settings/ViewModels/SettingsViewModel.swift | yes (all writes, memory off, backup/import, config check, secrets status) | OK |
| Components/ScarfMonDiagnosticsSection.swift | no | NO-TOUCHPOINT |
| Components/SettingsComponents.swift | minor (personality) | OK |
| Components/UpdatesSection.swift | no | NO-TOUCHPOINT |
| Settings/Views/SettingsView.swift | yes (managed gating, config edit/check) | OK |
| Tabs/AdvancedTab.swift | yes | OK |
| Tabs/AgentTab.swift | yes | OK |
| Tabs/AuxiliaryTab.swift | yes | OK |
| Tabs/BrowserTab.swift | yes | OK |
| Tabs/DisplayTab.swift | yes | OK |
| Tabs/GeneralTab.swift | yes | OK |
| Tabs/SecretsTab.swift | yes | OK |
| Tabs/SecurityTab.swift | yes | OK |
| Tabs/TerminalTab.swift | yes | OK |
| Tabs/WebToolsTab.swift | yes (web.*) | OK |
| HermesFileService.swift 26-154 | yes (config.yaml read, proven load) | OK |

## Touchpoint inventory
| Touchpoint | Kind | Scarf | Hermes | Status |
|---|---|---|---|---|
| `config set -- k v` | argv | HermesCLIOutcome.swift:1533 | hermes_cli/config.py:3479 | OK |
| `config unset -- k` | argv | HermesCLIOutcome.swift (HermesConfigUnset) | config.py:3656 | OK |
| managed refusal at exit 0 | verdict | SettingsViewModel.swift:405; HermesCLIOutcome.swift:493 | config.py:3486,3658 | OK |
| 179 dotted keys (display/agent/approvals/terminal/browser/web/tts/stt/memory/security/secrets/telemetry/database/compression/checkpoints/logging/aux…) | config key | SettingsViewModel.swift:632-1430 | _validate_config_key | OK (3 unseeded-but-read, see above) |
| auxiliary.<task>.* | config key | SettingsViewModel.swift:974-1056 | config_defaults.py:715-790 | OK |
| agent.reasoning_overrides / model_catalog.excluded_providers / profile_routes | direct YAML | SettingsViewModel.swift:1224-1420 | config.py:3292; gateway/config_loader.py | OK |
| memory off | argv | SettingsViewModel.swift:966 | main_agent_cmds.py | OK |
| secrets bitwarden status | argv | SettingsViewModel.swift:1201 | hermes_cli/secrets_cli.py | OK (not probed live) |
| config check | argv | SettingsViewModel.swift:1461 | config.py _cmd_config_check | OK |
| backup [--keep 0] / import --force -- path | argv | SettingsViewModel.swift:1488,1578 | LIVE --help matches | OK (verdict owned by data-safety section) |
| config path / config show Model line | argv+parse | HermesConfigReader.swift:78,95,190 | config.py:2869-2871 | OK |
| ~/.hermes/config.yaml | file | HermesFileService.swift:47,121 | get_config_path | OK |

## Not audited / couldn't verify
- HermesConfig.swift, HermesConfig+YAML.swift, and HermesYAML.swift (about 5k lines) were spot-checked, not read line by line. Read-side key parity has its own parity tests (SettingsWriteReadParityTests), which I did not run.
- The backup/import verdict internals and the remote backup location are owned by the data-safety section. Remote backup lands on the host, and the UI says so honestly. Related work is on the board: t-d2000dc5 and t-55229e05.
- `secrets bitwarden status` output was not probed (probing needs the verb, not --help).
