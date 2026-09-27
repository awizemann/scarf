# T3-config-models-creds — verdict: WORKS-WITH-ISSUES

Scope: Settings config writes/reads, HermesCapabilities parse/flags, model preflight + catalog tables, local models,
credential pools + root auth fallback, Nous flows, credential hint, check-hermes-tables.py, iOS settings.
Reference: Hermes worktree `~/.hermes/hermes-agent-v0215` (v2026.9.24 / 0.21.5). Scarf: integration worktree.
Primary paths all trace clean. No P0/P1. Three P2s, one P3.

## Journeys
| # | Journey | Verdict | Findings |
|---|---------|---------|----------|
| 1 | Settings toggle/picker/stepper → `hermes config set -- k v` → verdict → reload | WORKS | — (all 172 literal keys resolve in Hermes; coercion checked) |
| 2 | Settings "clear" rows → `config unset` (floor + isStored guard) | WORKS | — |
| 3 | Reasoning effort (top-level `false` for "none" on ≥0.21.1; aux keeps `none`; per-model overrides direct YAML) | WORKS | — |
| 4 | Model picker remote save → LocalModelConfigPlan remote ops | WORKS | — |
| 5 | Model picker Local tab (ollama/lmstudio/vllm/llama.cpp/custom) → base_url…, provider last | WORKS | — (Hermes `drop_stale_model_route` keeps the URL: ollama→custom, vllm/llamacpp→local, both "own" it) |
| 6 | Chat preflight + mismatch banner (aggregator table incl. nous) | WORKS | — |
| 7 | Credential Pools: list (auth.json + root fallback), add API key, remove, reset, priority, refresh, strategy | WORKS | F4 (P3, provider-swap sheet) |
| 8 | Credential Pools OAuth (anthropic PKCE; others routed to CLI) | WORKS | — |
| 9 | Nous sign-in (`auth add nous --no-browser`, device code parse, subscription-required) | WORKS | — |
| 10 | Nous model catalog fetch (`/v1/models` with providers.nous.access_token) | DEGRADED | F3 |
| 11 | Nous subscription status (picker badge, Health "Tool Gateway") | DEGRADED | F2 |
| 12 | Memory tab "Honcho Eager Init" toggle | BROKEN | F1 |
| 13 | Version probe → HermesCapabilities.parse | WORKS | — (`Hermes Agent v0.21.5 (2026.9.24) · upstream …` parses) |
| 14 | iOS Settings read (direct / `config path` / `config show` fallback) + quick-edit writes | WORKS | — |
| 15 | Chat "no provider credentials" hint | WORKS | — (lane 6 in sync) |
| 16 | `scripts/check-hermes-tables.py` | WORKS | — (ran it read-only with `--worktree` on v0215: OK, 6/6 lanes, only warns) |

## Findings

### T3-F1 · P2 · SOURCE · NEW
- Claim: The Memory tab's "Honcho Eager Init" toggle writes `honcho.initOnSessionStart` to config.yaml, which Hermes never reads. Honcho reads that flag only from `honcho.json`.
- Scarf: `scarf/scarf/Features/Settings/ViewModels/SettingsViewModel.swift:945` (`setSetting("honcho.initOnSessionStart", …)`); read back at `Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesConfig+YAML.swift:992`; UI `scarf/scarf/Features/Settings/Views/Tabs/MemoryTab.swift:31`.
- Hermes @v2026.9.24: `plugins/memory/honcho/client.py:323` (`look.flag("initOnSessionStart")` on the honcho.json lookup) ← `from_global_config` `:436-458` ← `resolve_config_path` `:108-118` (`$HERMES_HOME/honcho.json` → default profile's honcho.json → `~/.honcho/config.json`). The only config.yaml `honcho:` keys Hermes reads are `base_url`/`timeout`/`request_timeout` (`client.py:641-649`). `hermes_cli/config_defaults.py:1500-1502` says honcho.json is the source of truth and the `honcho: {}` block holds "hermes-specific overrides only". `{}` is an empty dict, so `config set` accepts the key without the unknown-key notice (`hermes_cli/config.py:3148-3151`).
- Failure scenario: A user turns on Eager Init. Scarf shows "Saved honcho.initOnSessionStart" and the toggle reads back ON, because Scarf reads its own write. Honcho still initializes lazily.
- Evidence: `grep initOnSessionStart` in the Hermes tree returns only `client.py:323` and `config_schema.py:116`. The schema declares `storage=STORAGE_HONCHO_HOST_BLOCK` (`plugins/memory/honcho/config_schema.py:33`).
- Ledger: the earlier audit (S05 inventory row "memory.* / honcho.initOnSessionStart … DEFAULT_CONFIG … OK") only checked that the key exists in DEFAULT_CONFIG, not that anything reads it. There is no task or decision for it.
- Suggested fix: Remove the toggle, or write the flag into the honcho.json host block. Hermes's own panel uses `STORAGE_HONCHO_HOST_BLOCK`.

### T3-F2 · P2 · SOURCE · NEW
- Claim: Scarf decides "Nous subscription active / tools route through the gateway" from `auth.json.active_provider == "nous"`. Current Hermes routes Tool Gateway traffic based on the Portal entitlement alone, not on the active provider, so Scarf's status and its advice can both be wrong.
- Scarf: `scarf/scarf/Core/Services/NousSubscriptionService.swift:13-18,29` (doc: "The Tool Gateway only routes tools when this is true — auth alone isn't enough"; `subscribed = present && providerIsNous`) and `:105-106`. Consumers: `scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift:438-457` ("Signed in, but Nous isn't the active provider … pick Nous Portal to route tools through the gateway", `.warning`); `ModelPickerSheet.swift:652-661`.
- Hermes @v2026.9.24: `tools/tool_backend_helpers.py:18-28`: `managed_nous_tools_enabled` = `account_info.logged_in and tool_gateway_entitled`, with no provider check. In `hermes_cli/nous_subscription.py:441-455`, per-feature `managed` depends on entitlement and selection only. `provider_is_nous` comes from config.yaml `model.provider` (`:154-155`), not from auth.json `active_provider`. It gates only the setup-time defaults and offers (`:494`, `:557`). Hermes's own `subscribed` is `provider_is_nous or nous_auth_present` (`:482`). `hermes model` sets `active_provider` to None when picking a non-OAuth provider (`hermes_cli/model_setup_flows_common.py:90` → `auth.py:1241-1246`).
- Failure scenario 1: The user signs in to Nous and then picks OpenRouter with `hermes model`, so `active_provider` becomes None. Health shows a warning telling them to switch inference to Nous "to route tools through the gateway". Their entitled web/image/TTS tools already route through Nous.
- Failure scenario 2: The user switches `model.provider` away from Nous in Scarf's picker, so auth.json keeps `active_provider: nous`. The picker still says "Subscription active — active provider is Nous", which is false for inference.
- Suggested fix: Base "tools route through Nous" on sign-in (plus the entitlement, if Scarf can get it). Base "active provider" on config `model.provider`, not auth.json. Drop the "pick Nous to route tools" advice.

### T3-F3 · P2 · PLAUSIBLE · NEW (S06 recorded the bearer question as UNVERIFIABLE)
- Claim: The Nous model catalog sends the stored `providers.nous.access_token` without refreshing it. That JWT is short-lived, so a once-a-day fetch will often hit an expired token, and Scarf then tells the user to "Sign in again" even though Hermes refreshes the token on its own.
- Scarf: `Packages/ScarfCore/Sources/ScarfCore/Services/NousModelCatalogService.swift` `bearerToken()` (reads `providers.nous.access_token` raw) → `fetchModels()` → `NousModelCatalogError.http(401).userMessage` = "Nous rejected the saved token (401). Sign in again." Shown by `ModelPickerSheet.swift:502,1324-1331`. Cache TTL is 24h (`cacheTTL`), so a fetch happens at most daily. The base URL is hardcoded to `inference-api.nousresearch.com` and ignores `providers.nous.inference_base_url`.
- Hermes @v2026.9.24: The token type is correct: `agent_key` *is* the access token (`hermes_cli/auth_nous.py:285-302`, `agent_key=access_token`). Hermes's own `/models` call goes through `resolve_nous_runtime_credentials`, which runs `ensure_usable_access_token` (refresh) first (`hermes_cli/models.py:1362-1368`, `auth_nous.py:1060-1095`). The key "lives ~1 h" (`agent/agent_init.py` comment at the Nous keepalive block, ~`:444`).
- Failure scenario: A Nous user who has no gateway running (so no keepalive) opens the model picker more than an hour after the last Hermes run. The fetch gets 401 and the picker shows "Sign in again". Their sign-in is fine, and the next chat refreshes the token silently.
- Missing to confirm: a live request with an expired token, to confirm the inference API returns 401 rather than serving the listing.
- Suggested fix: Check the JWT `exp` (or `expires_at`) before fetching. If it is expired, keep the cached or fallback list and say the list refreshes after the next Hermes run, not "Sign in again".

### T3-F4 · P3 · SOURCE · NEW
- Claim: The "Switch to <provider>" button on the post-OAuth provider-swap sheet discards the write result. A refused write just closes the sheet with no message.
- Scarf: `scarf/scarf/Features/CredentialPools/Views/CredentialPoolsView.swift:1204-1215` (`_ = !ops.isEmpty && svc.applyModelConfigPlan(ops)`, then `onDismiss()`). The sheet also passes `capabilities` from the store here, so the older residual about `.empty` caps is resolved at this site.
- Hermes: any `config set` refusal, e.g. the managed-install arm at `hermes_cli/config.py:3486-3488` (exit 0, caught by Scarf's verdict), or the empty plan `[]` for a local provider with no base URL.
- Failure scenario: The switch fails. The sheet closes as if it worked, and the user finds the mismatch banner at the next chat.

## Touchpoint inventory
| Touchpoint | Kind | Scarf path:line | Hermes path:line | Status |
|---|---|---|---|---|
| `config set -- <key> <value>` (172 literal keys) | argv/config | SettingsViewModel.swift:264, 606-1017, 1185-1253 | hermes_cli/config.py:3479-3598 (set_config_value), subcommands/config.py:24-31 | OK |
| value coercion (`none`/`off`/ints, `_SCALAR_WORDS`) for keys with non-str defaults | config | SettingsViewModel.swift (all bool/int setters) | config.py:3240-3278, config_defaults (types checked for every key) | OK |
| `agent.reasoning_effort` none→`false` on ≥0.21.1 | config | PowerSettingsWriter.swift:147-152; SettingsViewModel.swift:721 | hermes_constants.py:1303-1327, 1414-1438 | OK |
| `auxiliary.<task>.reasoning_effort none` (string default "") | config | SettingsViewModel.swift:963,1011 | config.py:3253-3254 | OK |
| `config unset <key>` (floor + isStored) | argv | SettingsViewModel.swift:311-331 | config.py (unset_config_value) | OK |
| `agent.reasoning_overrides` direct YAML | config file | PowerSettingsWriter.swift setReasoningOverrides; SettingsViewModel.swift:1197 | hermes_constants.py:1366-1399, 1428 | OK |
| `model_catalog.excluded_providers` direct YAML | config file | PowerSettingsWriter.swift setExcludedProviders | hermes_cli/inventory.py:54-59 | OK |
| `honcho.initOnSessionStart` | config key | SettingsViewModel.swift:945 | plugins/memory/honcho/client.py:323, 641-649 | FINDING-F1 |
| `credential_pool_strategies.<p>` (fill_first/round_robin/least_used/random) | config key | CredentialPoolsViewModel.swift:337-362 | agent/credential_pool.py:119-122, 602 | OK |
| model.default/provider/base_url/api_key/api_mode/context_length plan | argv/config | LocalModelConfigPlan.swift; SettingsViewModel.swift:608-660 | config.py:3535-3568 (drop_stale_model_route), route_identity.py:47-103, providers.py:134-135 | OK |
| local descriptor provider ids / llama.cpp → custom | config | LocalModelProviders.swift | auth.py:1296-1336 aliases; providers.py:134-135 | OK |
| `hermes --version` parse | argv/output | HermesCapabilities.swift:2777-2840; HermesVersionCache.swift subprocessProbe (timeout 10) | live: `Hermes Agent v0.21.5 (2026.9.24) · upstream d0288be5` | OK (LIVE) |
| models_dev_cache.json path + decode | file | ModelCatalogService.swift:117, 681-727 | agent/models_dev.py:212-217 | OK (every field type in the live cache validated against the decoder) |
| aggregator / alias / overlay / env-var tables | tables | ModelPreflight.swift; ModelCatalogService.swift; HermesProviderCredentials.swift | model_normalize.py:31-32, providers.py, auth.py | OK (check-hermes-tables OK 6/6) |
| mismatch skip for aggregators incl. nous | logic | ModelPreflight.swift aggregatorProviders | agent/agent_init.py:455-462 | OK |
| auth.json `credential_pool` decode | file | CredentialPoolsViewModel.swift:668-739 | agent/credential_pool.py:210-286 | OK |
| auth.json `providers.<p>` decode | file | CredentialPoolsViewModel.swift:161-205 | auth.py:786-796 | OK |
| root auth.json fallback (pools + provider state) | file | HermesAuthFallback.swift | auth.py:748-766, 870-893 | OK |
| `auth add <p> --type api-key --api-key K [--label]` | argv | CredentialPoolsViewModel.swift:382-405 | subcommands/auth.py:12-35; auth_commands.py:359-406 | OK |
| `auth remove -- <p> <target>` | argv | :441-458, 691-694 | auth_commands.py:562-588 (SystemExit on miss) | OK |
| `auth logout -- <p>` (3-state verdict) | argv | :477-488 | auth.py logout_command | OK |
| `auth reset -- <p> [target]` | argv | :520-535, 598-627, 684-688 | auth_commands.py:591-605 | OK |
| `auth priority -- <p> <target> <n>` / `auth refresh -- <p> <target>` | argv | :553-596, 665-679 | subcommands/auth.py:49-58; auth_commands.py:483-494, 608-660 | OK |
| target encoding (id → label → 1-based index) | argv | CredentialPoolsViewModel.swift:651-654 | agent/credential_pool_admin.py resolve_target | OK |
| `auth add <p> --type oauth --no-browser [--label]` + "Authorization code:" | argv/output | OAuthFlowController.swift start/handleOutputChunk | agent/anthropic_credentials.py:752-802; auth_commands.py:201-206 | OK (anthropic also opens its own browser tab, which is cosmetic) |
| OAuth gate (non-anthropic → CLI) | logic | CredentialPoolsOAuthGate.swift:47-61 | auth_commands.py:29-32 | OK |
| `auth add nous --no-browser` + device-code block | argv/output | NousAuthFlow.swift:114-126, 274-285 | auth_device_flow.py:289-300; auth_nous.py:1340-1362 | OK |
| subscription-required markers | output | NousAuthFlow.swift:304-316 | auth_nous.py:1386-1393 | OK |
| Nous success = access_token + active_provider | file | NousAuthFlow.swift:217-241; NousSubscriptionService.swift:93-106 | auth_nous.py:810-827; auth.py:786-796 | OK (for the sign-in verdict) |
| Nous "subscribed" semantics for gateway/status | logic | NousSubscriptionService.swift:13-29 | tools/tool_backend_helpers.py:18-28; nous_subscription.py:437-483 | FINDING-F2 |
| Nous `/v1/models` fetch (bearer, base URL, filter) | HTTP | NousModelCatalogService.swift bearerToken/fetchModels/agenticModels | auth_nous.py:285-302, 702-729; models.py:1362-1368 | FINDING-F3 (filter OK) |
| `~/.hermes/scarf/nous_models_cache.json`, `model_presets.json` | Scarf files | NousModelCatalogService.swift; ModelPresetService.swift | — | OK |
| project preset → `session/set_model` `<provider>:<model>` | ACP | ProjectModelPresetApplier.swift:40-50 | acp_adapter/server.py:1015-1040 | OK (chat-side details belong to T1) |
| iOS `config set`/`unset` via `/bin/sh -c` with root pin | argv | IOSSettingsViewModel.swift saveValue/unsetValue (timeout 15) | as above | OK; csh/tcsh PATH is TRACKED (t-9b5f147f leftovers) |
| iOS/remote `config path`, `config show` Model line parse | argv/output | HermesConfigReader.swift:26-120 | config.py:2869-2871 (`Model: {dict repr}`) | OK |
| managed-host lock (`.managed`) | file | SettingsViewModel.swift:204-247; IOSSettingsViewModel | config.py:3486-3488 | OK |
| credential hint env-var list / keyless / aliases | table | HermesProviderCredentials.swift | main.py _has_any_provider_configured; auth.py:1296-1336 | OK (R14 F3 alias gap now fixed) |
| Aux task rows (vision, compression, skills_hub, approval, mcp, curator, title_generation, background_review) | config | AuxiliaryTab.swift:65-100 | config_defaults.py auxiliary block | OK (newer tasks such as goal_judge, monitor and moa_* are unsurfaced but still listed under "Other tasks" when present) |
| `auxiliary.<task>.max_concurrency` | config | SettingsViewModel.swift:979-981 | agent/auxiliary_client.py:6285-6291 | OK |
| post-OAuth provider swap write | argv | CredentialPoolsView.swift:1193-1215 | config.py:3479+ | FINDING-F4 |

## Not audited / couldn't verify
- F3: whether `inference-api.nousresearch.com/v1/models` returns 401 for an expired invoke JWT. Confirming it needs a live call.
- Nous access-token TTL: taken from the Hermes source comment ("lives ~1 h"); not measured.
- Every non-literal settings write in tabs outside this manifest (Voice, Advanced, Memory beyond F1). They share the same VM setters, so the per-key scan covered their keys.
- Profile `-p` pinning of `ctx.runHermes` for pool mutations under a named profile belongs to the cross-cutting PROFILE ROOT CAUSE item (T6/S13), so it is not re-audited here.
- The scalar `model: <id>` shorthand in config.yaml reads as "unknown" in Scarf, which would give a false preflight prompt. Hermes accepts the shorthand, but Hermes's own setup never writes it, so I treated it as a rare hand edit and did not report it.
