# S05-config-settings — verdict: WORKS-WITH-ISSUES

Reference: Hermes worktree `~/.hermes/hermes-agent-v0215` at tag `v2026.9.24` (0.21.5). Probes run: `hermes config --help`,
`hermes approvals suggest --help`, `hermes secrets bitwarden --help` (all LIVE, match Scarf argv).

Method note: I dumped Hermes `DEFAULT_CONFIG` (`hermes_cli/config_defaults.py`, a pure-data module) flattened to
1,086 leaf paths and mechanically diffed it against (a) every literal key Scarf passes to `setSetting`/`unsetSetting`
(178 keys across the macOS VM, iOS VM and iOS editor) and (b) every `boolish/int/double/str/strEnum/intOpt/boolishOpt`
read in `HermesConfig+YAML.swift` (with its Scarf default next to Hermes' default). Every key missing from
DEFAULT_CONFIG and every default mismatch was then traced by hand (results below).

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Open Settings (macOS): config.yaml read off-main, parse, managed-marker probe, all tabs render | WORKS | F3 (rare marker value) |
| 2 | Change a scalar in any tab → `hermes config set -- <key> <value>` → output verdict → re-read | WORKS | — |
| 3 | Clear-to-default rows → `hermes config unset -- <key>` (approvals.mode, browser.cloud_provider, stt.provider, aux max_concurrency, database.*) | WORKS | — |
| 4 | Terminal tab (backend, container limits, per-backend image/mode) | DEGRADED | F1, F2 |
| 5 | Agent / Security tabs (approvals mode/timeout, smart policy, redaction, tirith, blocklist, human delay, allowlist suggestions `approvals suggest --json` / `--apply N --json`) | WORKS | — |
| 6 | Voice tab (TTS/STT providers + per-provider keys, voice_chat_mode, wake word) | WORKS | — |
| 7 | Aux Models tab (auxiliary.<task>.*, title_generation, image_gen.model, openrouter.response_cache) | WORKS | — |
| 8 | Secrets tab (secrets.bitwarden.*, encrypted_cache, secrets.command.*, `secrets bitwarden status`) | WORKS | — |
| 9 | Advanced tab (network, compression, checkpoints, logging, delegation, database journal/WAL pragmas, telemetry, prompt caching, `config check`) | WORKS | — |
| 10 | Managed (NixOS) host: pane read-only + write refusal | WORKS | F3 |
| 11 | iOS Settings: read (direct / `config path` / `config show` fallback), curated editor `config set`/`config unset` via `/bin/sh -c` with `-p default` pin + transport HERMES_HOME | WORKS | — |

Key results of the mechanical diff (all verified OK, no finding):
- Every written key either exists in DEFAULT_CONFIG at the same path, or is a deliberately unseeded runtime-read key
  whose reader I located: `agent.reasoning_effort` (`hermes_constants.py:1433`), `browser.cloud_provider`
  (`tools/browser_tool_cloud.py:127-129`), `stt.provider`, `image_gen.model` (`tools/image_generation_tool.py:156-172`;
  `image_gen` is in `_EXTRA_KNOWN_ROOT_KEYS`, `hermes_cli/config.py:972`), `model.streaming` (`agent/agent_init.py:1203`),
  `secrets.command.*` (`agent/secret_sources/command.py:160-180`), `auxiliary.*.max_concurrency`
  (`agent/auxiliary_client.py:6285`), `multiplex_profiles` (top-level form, `hermes_cli/config.py:983`). None of these
  hit the new pre-write wrong-prefix refusal (`_is_wrong_prefix_suggestion`, `config.py:3179-3196`) — the sibling
  suggestion is never a shorter suffix — so they write with the post-write "not a recognized key" notice, which
  Scarf correctly does not treat as failure.
- Value types survive `_coerce_config_set_value` (`config.py:3248-3276`): string-typed defaults are preserved verbatim
  (so `approvals.mode=off`, `tool_use_enforcement=true` stay strings, and both readers accept the string forms —
  `_normalize_approval_mode` `tools/approval_context.py:200-214`, `_model_gate` `agent/system_prompt.py:41-52`);
  bool/int/float keys get `true/false`, `String(Int)`, `String(Double)`; negative values (`-40.0`, `-1.0`) are safe
  behind the `--`; `agent.reasoning_effort` "none" is written as `false` on v0.21.1+ so the new `none→null`
  coercion (`config.py:3242-3245`) cannot erase it; `terminal.docker_extra_args` is sent as a JSON-style list literal
  and parsed as a list (`_looks_structured_value`/`_refuse_container_type_mismatch`).
- Read defaults match Hermes for every key where Scarf uses a literal default; every mismatch is an intentional
  sentinel resolved per host in a `display…(capabilities:)` helper (checkpoints, delegation max_*, approvals.timeout,
  gateway_notify_interval, gateway_turn_lease_timeout, show_reasoning, max_turns, approvals.mode "host default"),
  or an empty text field shown as "—" meaning "unset" (docker/modal/daytona/singularity image, elevenlabs/xai voice id,
  neutts model) — cosmetic, not reported.
- Write verdict (`HermesConfigSet`/`HermesConfigUnset`, `HermesCLIOutcome.swift:1522-1661`) matches every arm of
  `set_config_value`/`unset_config_value` at the tag (`config.py:3479-3605`, `3656-3703`): success line
  `✓ Set <key> = … in …/config.yaml` / `✓ Unset …`; managed arm prints `Cannot set/unset configuration values` to
  stderr at exit 0 (`config.py:3485-3487`, `3658-3660`, `managed_error` `:381-383`) and is caught by the anchored
  `Cannot set/Cannot unset` markers with `failureWins`; terminal `.env` mirror partial-write handled.

## Findings

### S05-F1 · P2 · SOURCE · NEW
- Claim: the Terminal tab's Modal "Mode" picker offers `always`/`never`, which Hermes does not accept (silently coerced to `auto`), and omits the two real values `direct`/`managed`.
- Scarf: `scarf/scarf/Features/Settings/Views/Tabs/TerminalTab.swift:62` (options `["auto", "always", "never"]`) → `scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:791` (`setSetting("terminal.modal_mode", …)`); read back verbatim by `HermesConfig+YAML.swift:306`.
- Hermes @v2026.9.24: `tools/tool_backend_helpers.py:14-15` (`_DEFAULT_MODAL_MODE = "auto"`, `_VALID_MODAL_MODES = {"auto", "direct", "managed"}`), `:54-57` (`coerce_modal_mode` returns the default for anything else), consumed by `resolve_modal_backend_state` `:75-91` and `tools/terminal_tool_backends.py:169,290`.
- Failure scenario: user on the modal backend picks "never" (intending "don't use Nous-managed Modal") → `config set` succeeds, banner "Saved terminal.modal_mode", picker shows "never" — but Hermes runs `auto` (prefers managed Modal when available). A user who needs `direct` or `managed` cannot select either from Scarf; a config already holding `direct`/`managed` renders a blank picker (PickerRow does not append unknown values, `SettingsComponents.swift:212-219`).
- Evidence: `mode = str(value or _DEFAULT_MODAL_MODE).strip().lower(); return mode if mode in _VALID_MODAL_MODES else _DEFAULT_MODAL_MODE`.
- Suggested fix: options `["auto", "direct", "managed"]` (append a stored unknown value like the busy-input picker does).

### S05-F2 · P3 · SOURCE · NEW
- Claim: the Terminal "Backend" picker omits `vercel_sandbox`, a built-in backend at the tag, so a host configured with it shows a blank Backend picker and no container-limits section.
- Scarf: `scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:36-40` (comment says Vercel Sandbox "was removed as a terminal backend in v0.15"; list is `local, docker, singularity, modal, daytona, ssh`), `TerminalTab.swift:17` (PickerRow), `TerminalTab.swift:78-80` (`isContainerBackend` excludes it).
- Hermes @v2026.9.24: `tools/terminal_tool_backends.py:180-185,197,231-233` (`vercel_sandbox` in `_SANDBOX_ROWS` and `_ENV_BUILDERS`), `hermes_cli/doctor_tools.py:146` (`_BUILTIN_TERMINAL_BACKENDS` includes it), `hermes_cli/config_defaults.py:337-338` (`terminal.vercel_runtime`, container limits apply to vercel_sandbox).
- Failure scenario: `terminal.backend: vercel_sandbox` on the host → Settings ▸ Terminal renders an empty Backend picker (stale/incorrect state), CPU/memory/disk limits Hermes honours for that backend are hidden, and the user cannot select the backend from Scarf.
- Suggested fix: add `vercel_sandbox` to `terminalBackends` and `isContainerBackend`; append an unknown stored backend (plugin backends are also legal, `_build_plugin_env`).

### S05-F3 · P3 · SOURCE · NEW
- Claim: Scarf's `.managed` marker parser lacks Hermes' explicit-opt-out set, so a marker containing `false`/`0`/`no`/`off` locks the whole Settings pane as "managed by false" while Hermes itself treats the host as unmanaged and accepts writes.
- Scarf: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesManagedInstall.swift:58,70,88-95` (only `trueValues` and `ignoredValues`; any other non-empty string is returned as the system name).
- Hermes @v2026.9.24: `hermes_constants.py:1089` (`_MANAGED_FALSE_VALUES = frozenset({"false", "0", "no", "off"})`), `:1108-1109` (`if marker is None or marker in _IGNORED_MANAGED_VALUES or marker in _MANAGED_FALSE_VALUES: return None`).
- Failure scenario: a host whose `$HERMES_HOME/.managed` reads `false` (an operator's explicit opt-out) → every Settings tab disabled with "This Hermes is managed by false…" and every write refused client-side, although `hermes config set` would succeed. Rare (the NixOS module writes a system name), hence P3.
- Suggested fix: return nil for `["false","0","no","off"]` alongside `ignoredValues`.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `config set -- <key> <value>` (all Settings scalars, 178 keys) | argv | Services/HermesCLIOutcome.swift:1522-1540; SettingsViewModel.swift:264-270 | subcommands/config.py (LIVE `--help`); config.py:3479-3605 | OK |
| `config set` output verdict incl. exit-0 managed refusal, `.env` mirror partial write | parse | HermesCLIOutcome.swift:413-495,1421-1515 | config.py:381-383,3485-3487,3582-3591 | OK |
| `config unset -- <key>` (6 clear rows + approvals.mode) | argv | HermesCLIOutcome.swift:1628-1661; SettingsViewModel.swift:311-335 | config.py:3656-3703 | OK |
| `memory off` (memory provider "none") | argv | SettingsViewModel.swift:927-946 | main_agent_cmds.py (memory off → save_config) | OK |
| `config check` | argv | SettingsViewModel.swift:1432-1436 | LIVE `config --help` | OK |
| `config path` / `config show` (iOS fallback read, Model: line) | argv/parse | HermesConfigReader.swift:37-66,150-170 | config.py:2871 | OK |
| `approvals suggest --json` / `--apply N --json` | argv/parse | HermesApprovalsSuggestParser.swift:47-119; SettingsViewModel.swift:1654-1720 | approvals_suggest.py:313-364 (LIVE `--help`) | OK |
| `secrets bitwarden status` | argv | SettingsViewModel.swift:1173-1176 | subcommands/secrets.py:16 (LIVE `--help`) | OK |
| iOS `sh -c` config set/unset (+`-p default`, transport HERMES_HOME) | argv | IOSSettingsViewModel.swift:158-280; CitadelServerTransport.swift:822-826 | config.py:3479,3656 | OK |
| `$HERMES_HOME/.managed` marker | file | HermesManagedInstall.swift:88-95 | hermes_constants.py:1092-1112 | FINDING-F3 |
| `~/.hermes/config.yaml` read (Mac/iOS) | file | HermesFileService.swift:28-51,121-139; IOSSettingsViewModel.swift:58-120 | config.py:2028-2040 | OK |
| Direct YAML writes (agent.reasoning_overrides, model_catalog.excluded_providers, profile_routes) via GuardedTextFile, managed-refused | file | SettingsViewModel.swift:1198-1400; PowerSettingsWriter.swift:330-460 | hermes_constants.py:1303-1327 (reader) | OK (writer internals owned by S06/S07/S13) |
| terminal.modal_mode | config key W/R | TerminalTab.swift:62; SettingsViewModel.swift:791 | tools/tool_backend_helpers.py:14-15,54-57 | FINDING-F1 |
| terminal.backend | config key W/R | SettingsViewModel.swift:40,768 | tools/terminal_tool_backends.py:231-233 | FINDING-F2 |
| terminal.* other (cwd, timeout, persistent_shell, docker_*, container_*, images) | config keys | SettingsViewModel.swift:768-793; +YAML.swift:283-308 | config_defaults.py (terminal block) | OK |
| display.* (15 keys incl. personality, language, skin, busy_input_mode, runtime_footer) | config keys | SettingsViewModel.swift:662-704; +YAML.swift:265-279,866,907,923,948,991,1045 | config_defaults.py display block; personality.py:80-115; agent/i18n.py:128 | OK |
| agent.* (max_turns, reasoning_effort, service_tier, fast_auto_seconds, gateway_*, cron_drain_timeout, tool_use_enforcement) | config keys | SettingsViewModel.swift:708-732 | config.py:1856-1880; hermes_constants.py:1433; system_prompt.py:41-52 | OK |
| approvals.mode / timeout / smart_policy | config keys | SettingsViewModel.swift:746-764; HermesApprovalMode.swift | tools/approval_context.py:197-214 | OK |
| browser.* (cloud_provider incl. unset, timeouts, record, private URLs, camofox) | config keys | SettingsViewModel.swift:41-66,802-817 | tools/browser_tool_cloud.py:76-150; plugins/browser/browser_use/provider.py:63 | OK |
| web.backend / search_backend / extract_backend | config keys | SettingsViewModel.swift:830-832; WebToolsTab.swift | config_defaults.py:370-373; plugins/web/* | OK |
| voice.*, tts.*, stt.*, wake_word.capture | config keys | SettingsViewModel.swift:836-909 | tools/transcription_common.py:48; tools/tts_command_provider.py:269; tools/voice_live.py:107; tools/wake_word.py:194 | OK |
| memory.* (enabled, limits, nudge, provider) | config keys | SettingsViewModel.swift:913-946 | config_defaults.py memory block; plugins/memory/__init__.py | OK |
| auxiliary.<task>.{provider,model,base_url,api_key,timeout,reasoning_effort,max_concurrency}, background_review.enabled, title_generation.* | config keys | SettingsViewModel.swift:948-1025; AuxiliaryTab.swift:65-100 | config_defaults.py auxiliary block; agent/auxiliary_client.py:6285 | OK |
| image_gen.model, openrouter.response_cache | config keys | SettingsViewModel.swift:1035,1044 | tools/image_generation_tool.py:156-172; config_defaults.py | OK |
| security.* / privacy.redact_pii / human_delay.* | config keys | SettingsViewModel.swift:1050-1059 | config_defaults.py; gateway/run_config_loaders.py:300-320 | OK |
| secrets.bitwarden.* (+encrypted_cache), secrets.command.* | config keys | SettingsViewModel.swift:1063-1087 | config_defaults.py secrets block; agent/secret_sources/command.py:160-180 | OK |
| telemetry.shared_metrics.enabled/send | config keys | SettingsViewModel.swift:1094,1104 | config_defaults.py | OK |
| database.journal_mode / wal_autocheckpoint / journal_size_limit | config keys | SettingsViewModel.swift:1112-1137 | hermes_state_wal.py:157-165,622-645 | OK |
| network.force_ipv4, file_read_max_chars, compression.*, checkpoints.*, logging.*, delegation.*, cron.wrap_response, curator.consolidate, max_concurrent_sessions, prompt_caching.cache_ttl, updates.check, gateway.trust_env, tool_loop_guardrails.* | config keys | SettingsViewModel.swift:1180-1192,1400-1425; AdvancedTab.swift:539,555 | config_defaults.py; active_sessions.py:32-55 | OK |
| model.default / model.provider / model.streaming | config keys | SettingsViewModel.swift:606-607,684 | agent/agent_init.py:1203 | OK (selection logic is S06) |
| gateway.multiplex_profiles / multiplex_profiles | config keys | SettingsViewModel.swift:1255-1266 | hermes_cli/gateway_multiplex_mode.py | TRACKED to S07/S13 scope (not audited here) |
| JSONValue, GuardedJSONStore, GuardedTextFile, YAMLLineEndings, YAMLScalar, HermesYAML | engine | Parsing/*, Services/* | PyYAML load semantics | OK (spot-checked; no defect found) |
| ConfigDottedKeySegment (`\.` escape) | key encoding | Services/ConfigDottedKeySegment.swift | config.py:608-630 | OK (callers outside S05) |
| iOS editor curated keys (model.default, model.provider, approvals.mode, agent.max_turns, display.show_cost/show_reasoning/streaming) | config keys | SettingEditorSheet.swift:300-416; Settings/SettingsView.swift:208-230 | as above | OK |
| V013FeaturesSheet | static copy | Scarf iOS/Settings/V013FeaturesSheet.swift | — | OK (no Hermes touchpoint) |

## Not audited / couldn't verify
- Internals of `GatewayConfigWriter` (setMapChecked/setListChecked) used by the direct-YAML writers — owned by S07; only the S05-side guards (managed refusal, serialization on the write chain, control-char/oversize key refusal) were checked.
- `HermesYAML.parseNestedYAML` was spot-checked (PyYAML indentless lists, block scalars, line folding are explicitly handled), not exhaustively fuzzed against PyYAML.
- `HERMES_MANAGED` env-var-only managed hosts are invisible to Scarf's transport by design (documented in SettingsViewModel.swift:182-197); the exit-0 verdicts still catch their refusals.
- Minor roster gaps judged not worth findings (stored values are preserved or harmless): STT picker lacks `xai`/`local_command`; OpenAI TTS voice picker lacks newer voices (ash/coral/sage…); Secrets tab has no 1Password (`secrets.onepassword`) section; empty-image/voice-id fields show "—" instead of Hermes' default value.
- Backup/restore rows on the Advanced tab (owned by S14) and model/provider picker logic (S06) were not audited.
