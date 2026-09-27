# S05-config-settings — verdict: WORKS-WITH-ISSUES

Method note: besides reading both sides, every config key Scarf WRITES (245 literal/dynamic keys from
`SettingsViewModel.swift`, the Settings tab views, and the iOS editor) was run through Hermes's own
`_validate_config_key`, `_default_value_for_key`, `_is_wrong_prefix_suggestion`, env-routing checks and
`_coerce_config_set_value` by importing `hermes_cli.config` from the v2026.9.24 worktree's `.venv`, with
`HERMES_HOME` pointed at a scratch dir (no real config touched). Every key Scarf READS with a default
(194 `bool/int/double/str/strEnum/boolishOpt/intOpt` calls in `HermesConfig+YAML.swift`) was diffed against
`DEFAULT_CONFIG`. Every divergence was then checked by hand. All but the two findings below are deliberate
absent-key sentinels that the display layer resolves per capability (for example `approvals.timeout`,
`agent.gateway_turn_lease_timeout`, `delegation.max_*`, `checkpoints.*`, `agent.max_turns`), or they are
out-of-section platform keys.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Open Settings: `loadConfig`/`loadConfigProven` off-main, managed probe, all tabs render parsed values | WORKS | — |
| 2 | Change a scalar (toggle/stepper/picker) → `hermes config set -- <key> <value>` → output-judged verdict → reload | WORKS | — |
| 3 | Agent tab: reasoning effort, max turns, service tier, timeouts, tool-use enforcement | DEGRADED | S05-F2 |
| 4 | Security tab: approvals mode (incl. host-default via `config unset`), timeout, smart policy, tirith, redaction, blocklist, human delay, allowlist suggestions | WORKS | — |
| 5 | Secrets tab: `secrets.bitwarden.*`, `secrets.command.*`, `hermes secrets bitwarden status` | WORKS | — |
| 6 | Voice tab: TTS/STT providers and per-provider keys, `voice.*`, `voice_chat_mode`, wake word | WORKS | — |
| 7 | Auxiliary tab: per-task provider/model/base_url/api_key/timeout/reasoning_effort, title generation, max_concurrency | DEGRADED | S05-F1 |
| 8 | Advanced tab: compression, logging, checkpoints, delegation, database (journal_mode, WAL autocheckpoint, journal_size_limit), prompt cache TTL, telemetry, config check | WORKS | — |
| 9 | Direct-YAML writers (`saveDirectYAML`: reasoning overrides, excluded providers, profile routes): guarded load, lock, managed bounce, write chain | WORKS | — |
| 10 | iOS: read (direct, then `cat "$(hermes config path)"`, then `config show` probe), quick-edit `config set`/`config unset`, sentinel rules, HERMES_HOME scoping via Citadel | WORKS | — |
| 11 | Managed install: every write path refuses before spawning; Hermes's exit-0 refusal is matched by output | WORKS | — |

## Findings

### S05-F1 · P2 · SOURCE · NEW
- **Claim:** The Auxiliary tab always shows a "Session Search" task. Hermes has not read `auxiliary.session_search.*` since v2026.5.28, so every edit in that row is saved to a key nothing reads, and Scarf reports "Saved".
- **Scarf:** `scarf/scarf/Features/Settings/Views/Tabs/AuxiliaryTab.swift:61` (`("session_search", "Session Search", …)` in the unconditional `baseTasks`), written via `SettingsViewModel.swift:935-949` (`auxiliary.\(task).\(field)`).
- **Hermes @v2026.9.24:** `hermes_cli/config_defaults.py:737-738` ("web_extract and session_search no longer use an aux LLM; leftover blocks in user config are ignored") and `:754-756` ("The old `auxiliary.session_search.*` block was removed … ignored"). `DEFAULT_CONFIG['auxiliary']` has no `session_search`. There is no non-test `task="session_search"` call site. The block was removed by commit abf1af5401 (#27590), first released in v2026.5.28.
- **Failure scenario:** A user sets Session Search → Provider `openrouter`, Model `x`. `config set` writes the value, prints `✓ Set …` and `⚠ 'auxiliary.session_search.provider' is not a recognized config key — it was saved anyway, but Hermes may not read it` (`config.py:3453`, `:3599`), and exits 0. Scarf shows "Saved auxiliary.session_search.provider". The setting has no effect. Unlike its siblings, the row sits in `baseTasks`: `web_extract` (`hasWebExtractAux`, pre-0.20.6) and `flush_memories` (`hasFlushMemoriesAux`, pre-0.12) are capability-gated out on current hosts.
- **Evidence:** the Hermes-side validator run returned `UNKNOWN auxiliary.session_search.{provider,model,base_url,api_key,timeout,reasoning_effort}`. The ledger has no entry (only an unrelated mention in `.memory/project/hermes-version-targeting-strategy.md:22`).
- **Suggested fix:** Gate `session_search` behind a `hasSessionSearchAux` (below v2026.5.28) the same way as `web_extract`. On newer hosts a stale block still lands in the existing "Other tasks in config.yaml" section.

### S05-F2 · P1 · SOURCE · NEW
- **Claim:** Choosing Reasoning Effort **none** (reasoning off) in the Agent tab does not turn reasoning off. `hermes config set agent.reasoning_effort none` coerces `none` to YAML null, which Hermes reads as "use the default". Scarf still shows "Saved", and the picker falls back to "Hermes default".
- **Scarf:** `scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:708` (`setSetting("agent.reasoning_effort", value: value)`). The option comes from `Packages/ScarfCore/Sources/ScarfCore/Services/PowerSettingsWriter.swift:19` (`baseLevels = ["none", …]`) and is offered at `scarf/scarf/Features/Settings/Views/Tabs/AgentTab.swift:66`.
- **Hermes @v2026.9.24:**
  - `agent.reasoning_effort` is not in `DEFAULT_CONFIG` (the `agent` block at `config_defaults.py:53ff` has no such key), so `_default_value_for_key` returns `None`. The str-preserving arm at `config.py:3253` therefore does not apply.
  - Next, `config.py:3257` checks `lower in _SCALAR_WORDS`, and `:3245` maps `'none': None`, so the value stored is Python `None`.
  - ruamel round-trip then writes `reasoning_effort:` with an empty value (verified with the worktree's ruamel).
  - `hermes_constants.py:1433-1434` → `parse_reasoning_effort(None)` returns `None` (`:1316-1317`). That means "caller uses the default", not `{"enabled": False}`, which only the strings `none`/`false`/`disabled` or YAML `False` produce (`:1324-1325`).
- **Failure scenario:** On a local default-profile host with a reasoning model, the user picks `none` to disable thinking. Hermes prints `✓ Set agent.reasoning_effort = None in …/config.yaml` plus the unknown-key notice and exits 0. `HermesConfigSet.judge` reports success, and the banner says "Saved agent.reasoning_effort". The re-read shows an empty scalar, so the picker renders "Hermes default". Reasoning stays on at the provider default, and the user keeps paying for thinking tokens.
- **Evidence:** calling Hermes's own `_coerce_config_set_value('agent.reasoning_effort','none')` returns `None`, while `'high'` returns `'high'`. The auxiliary per-task `reasoning_effort` keys have a `''` str default, so `none` stays a string there and those rows are **not** affected. Direct-YAML per-model overrides write bare `none`, which PyYAML loads as the string, so they are not affected either. The ledger discusses only `off` and quoting (round-6 decision 4, `.memory/decisions/hermes-v0-21-1-compatibility-decisions.md:5175`), not this CLI coercion.
- **Suggested fix:** For the disable choice, write a spelling that survives coercion, for example `false` (coerced to YAML `False`, which disables at every tag) or `disabled` on `hasReasoningDisableAliases` hosts. Keep displaying it as "none".

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `config set -- <key> <value>` argv | CLI | `ScarfCore/Services/HermesCLIOutcome.swift:1514-1516` | `hermes_cli/subcommands/config.py` (`hermes config set --help`: `[--force] [key] [value]`) | OK (LIVE) |
| `config set` verdict (success `Set `, failures anchored, failureWins, .env-mirror partial) | parser | `HermesCLIOutcome.swift:432,494,1518-1531,1450-1486` | `config.py:3479-3600` (new exit-1 arms `_exit_invalid`/container-type/wrong-prefix all exit 1) | OK |
| `config unset -- <key>` argv and verdict | CLI | `HermesCLIOutcome.swift:1619-1644` | `config.py:3656ff` | OK (LIVE help) |
| managed-install bounce (Mac/iOS/direct-YAML) | guard | `SettingsViewModel.swift:385`, `:1266`; `IOSSettingsViewModel.swift:158-166` | `config.py:219`, `:381`, `:3485-3487` | OK |
| `config check` | CLI | `SettingsViewModel.swift:1419-1423` | subcommand `check` exists | OK (LIVE) |
| `config path` / `config show` fallback (iOS/remote) | CLI + parser | `HermesConfigReader.swift` (`readViaConfigPath`, `probeModelConfig`, `parseModelShowLine`) | `config.py:2869-2871` (`  Model:        {…}`) | OK |
| `secrets bitwarden status` (raw display) | CLI | `SettingsViewModel.swift:~1160` | `hermes_cli/secrets_cli.py:248` | OK (LIVE help) |
| `approvals suggest --json` / `--apply N --json` | CLI + JSON | `HermesApprovalsSuggestParser.swift:47-61`; `SettingsViewModel.swift:654-720` | `hermes_cli/approvals_suggest.py:316-362` | OK (LIVE help; UI disabled when managed) |
| backup / import (Advanced tab) | CLI | `SettingsViewModel.swift:1430-1590` | — | UNVERIFIABLE here (verdict types owned by S14) |
| config.yaml direct read (`loadConfig`, `loadConfigProven`, `GuardedTextFile`) | file | `HermesFileService.swift:28-137` | `atomic_config_write` `config.py:2016` (ruamel, wide width → no folding) | OK |
| Direct-YAML writers (reasoning_overrides, excluded_providers, profile routes) | file write | `SettingsViewModel.swift:1185-1390` | `hermes_constants.py:1367-1398`; `_KNOWN_CONTAINER_TYPES` `config.py` | OK (routes/providers logic → S06) |
| `agent.reasoning_effort` write | key | `SettingsViewModel.swift:708` | `config.py:3245,3253,3257`; `hermes_constants.py:1316,1433` | FINDING-S05-F2 |
| `auxiliary.session_search.*` write | key | `AuxiliaryTab.swift:61` | `config_defaults.py:737,754` | FINDING-S05-F1 |
| `auxiliary.{vision,compression,skills_hub,approval,mcp,curator,title_generation}.*` incl. `reasoning_effort`, `timeout`, `enabled`, `language` | keys | `SettingsViewModel.swift:935-1010` | `config_defaults.py:736-770`; `max_concurrency` read at `agent/auxiliary_client.py:6285-6291` | OK |
| `auxiliary.background_review.enabled` | key | `SettingsViewModel.swift:976` | DEFAULT_CONFIG | OK |
| `auxiliary.web_extract.*`, `auxiliary.flush_memories.*` | keys | `AuxiliaryTab.swift:70-77` | removed upstream; capability-gated to old hosts | OK |
| display.* (streaming, show_reasoning, show_cost, interim, skin, compact, resume_display, bells, resume_last_session, inline_diffs, tool_progress_command, tool_preview_length, busy_input_mode, language, timestamps, personality, runtime_footer.enabled) | keys | `SettingsViewModel.swift:658-696`, `DisplayTab.swift` | DEFAULT_CONFIG (all known; enums match `config_defaults.py:799,808`) | OK |
| agent.* (max_turns, service_tier, fast_auto_seconds, gateway_notify_interval, gateway_timeout, cron_drain_timeout, gateway_turn_lease_timeout, tool_use_enforcement) | keys | `SettingsViewModel.swift:700-718` | DEFAULT_CONFIG; `agent/system_prompt.py:41-52` (string "true"/"false" honored) | OK |
| approvals.mode / timeout / smart_policy | keys | `SettingsViewModel.swift:732-750`; `HermesApprovalMode.swift:130` | `tools/approval_context.py:197-214`; `config_defaults.py:1663` | OK |
| security.* / privacy.redact_pii / human_delay.* | keys | `SettingsViewModel.swift:1037-1046` | DEFAULT_CONFIG (`human_delay` `config_defaults.py:1273`) | OK |
| secrets.bitwarden.* (incl. encrypted_cache.*) / secrets.command.* | keys | `SettingsViewModel.swift:1050-1074` | `agent/secret_sources/bitwarden.py:450-471`, `command.py:160-180` (open top-level `secrets`) | OK |
| voice.* / tts.* / stt.* / wake_word.capture | keys | `SettingsViewModel.swift:822-895` | DEFAULT_CONFIG; `stt.provider` unseeded but read; `voice_live.py:107` | OK |
| memory.* / honcho.initOnSessionStart | keys | `SettingsViewModel.swift:899-931` | DEFAULT_CONFIG | OK |
| compression.*, logging.*, checkpoints.*, delegation.*, cron.wrap_response, curator.consolidate, max_concurrent_sessions, file_read_max_chars, network.force_ipv4, gateway.trust_env, updates.check, tool_loop_guardrails.*, telemetry.shared_metrics.*, openrouter.response_cache, image_gen.model, prompt_caching.cache_ttl | keys | `SettingsViewModel.swift:1030-1180,1387-1412`; `AdvancedTab.swift:539` | DEFAULT_CONFIG (all known) | OK |
| database.journal_mode / wal_autocheckpoint / journal_size_limit (unset on empty) | keys | `SettingsViewModel.swift:1099-1125` | `config_defaults.py:31-34` | OK |
| multiplex_profiles vs gateway.multiplex_profiles | keys | `SettingsViewModel.swift:1242-1253` | DEFAULT_CONFIG | OK (semantics → S07/S13) |
| terminal.*, browser.*, web.* (tabs outside manifest, same VM) | keys | `SettingsViewModel.swift:754-818` | all known | OK |
| iOS quick-edit keys: model.default, model.provider, approvals.mode, agent.max_turns, display.show_cost/show_reasoning/streaming, voice.voice_chat_mode | keys | `Scarf iOS/Settings/SettingEditorSheet.swift:366-414`; `IOSSettingsViewModel.swift:158-272` | as above; HERMES_HOME via `CitadelServerTransport.swift:814` | OK |
| Reader defaults (194 calls) | read | `HermesConfig+YAML.swift` | DEFAULT_CONFIG | OK (divergences are documented sentinels) |
| YAML subset parser: quotes (`''` undoubling), block scalars, flow lists, trailing comments, CRLF | parser | `HermesYAML.swift`, `YAMLScalar.swift`, `YAMLLineEndings.swift` | ruamel round-trip writer | OK |
| `ConfigDottedKeySegment`, `GuardedJSONStore`, `JSONValue` | helpers | manifest files | — | OK (no Hermes contract beyond the above) |
| Model picker sheet (`ModelPickerSheet.swift`) | model/provider | — | — | out of scope → S06 |

## Not audited / couldn't verify
- No live `config set` was run (it mutates config). Coercion and validation results come from calling Hermes's own functions against a scratch `HERMES_HOME`, which is stronger than reading the source but is not an end-to-end CLI run.
- Backup/restore verdict internals (`HermesBackupVerdict`, `HermesImportVerdict`) belong to S14. Only the call sites were checked.
- Model/provider selection (`ModelPickerSheet`, `model.*` routing) → S06. Platform/gateway keys → S07.
- `approvals suggest --apply` on a non-managed host whose `save_config` raises: `tools/approval.py:478-479` swallows the error and still prints success JSON at exit 0. This needs an unreadable config.yaml, so it counts as a rare edge case under the brief and is not raised.
